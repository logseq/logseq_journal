module Error = struct
  type t = Invalid of string

  let to_string (Invalid message) = message
end

type startup_phase =
  | Signed_out
  | Loading_catalog
  | Awaiting_selection
  | Restoring_local
  | Bootstrapping
  | Awaiting_e2ee_password
  | Ready
  | Failed

type startup_error_owner =
  | Authentication
  | Catalog
  | Local_restore
  | Bootstrap
  | E2ee
  | Graph

type startup_recovery =
  | Sign_in
  | Refresh_catalog
  | Begin_online_recovery
  | Submit_e2ee_password
  | Retry_graph_open

type startup_error =
  { owner : startup_error_owner
  ; message : string
  ; recovery : startup_recovery option
  }

type startup_state =
  { phase : startup_phase
  ; error : startup_error option
  }

let startup_error stage message =
  let owner, recovery =
    match stage with
    | Logseq_sync_pure_reducer.Core.During_authentication -> Authentication, Some Sign_in
    | During_catalog -> Catalog, Some Refresh_catalog
    | During_local_restore -> Local_restore, Some Begin_online_recovery
    | During_bootstrap -> Bootstrap, Some Begin_online_recovery
    | During_e2ee -> E2ee, Some Submit_e2ee_password
  in
  { owner; message; recovery }
;;

let graph_matches snapshot (graph : Logseq_db_worker.graph_state) =
  graph.generation = snapshot.Logseq_sync_pure_reducer.Core.startup.graph_generation
  && Option.equal
       Logseq_db_types.Graph_types.Uuid.equal
       graph.graph_id
       snapshot.selected_graph
;;

let derive ~snapshot ~(graph : Logseq_db_worker.graph_state) =
  let facts = snapshot.Logseq_sync_pure_reducer.Core.startup in
  let graph_is_current = graph_matches snapshot graph in
  let ready =
    facts.authenticated
    && graph_is_current
    && graph.phase = Logseq_db_worker.Graph_open
    && not snapshot.timeline_presentation_pending
  in
  if ready
  then { phase = Ready; error = None }
  else if not facts.authenticated
  then { phase = Signed_out; error = None }
  else if graph_is_current && graph.phase = Graph_failed
  then
    { phase = Failed
    ; error =
        Some
          { owner = Graph
          ; message =
              Option.fold
                ~none:"Graph open failed."
                ~some:Logseq_db_worker.Error.message
                graph.error
          ; recovery = Some Retry_graph_open
          }
    }
  else (
    match facts.failure with
    | Some stage ->
      { phase = Failed
      ; error =
          Some
            (startup_error
               stage
               (Option.value snapshot.last_error ~default:"Startup failed."))
      }
    | None when facts.catalog_loading -> { phase = Loading_catalog; error = None }
    | None when facts.awaiting_selection -> { phase = Awaiting_selection; error = None }
    | None when facts.awaiting_e2ee_password ->
      { phase = Awaiting_e2ee_password; error = None }
    | None when facts.bootstrapping -> { phase = Bootstrapping; error = None }
    | None -> { phase = Restoring_local; error = None })
;;

type t = Logseq_db_worker.Config.t

let magic = "LDB1"
let header_size = 8
let maximum_payload_bytes = 1024 * 1024
let error format = Printf.ksprintf (fun message -> Error (Error.Invalid message)) format

let encode value =
  let json = Logseq_db_worker.Config.to_yojson value |> Yojson.Safe.to_string in
  let size = header_size + String.length json in
  if size > maximum_payload_bytes
  then error "startup payload exceeds 1 MiB"
  else (
    let bytes = Bytes.create size in
    Bytes.blit_string magic 0 bytes 0 4;
    Bytes.set_int32_le bytes 4 (Int32.of_int (String.length json));
    Bytes.blit_string json 0 bytes header_size (String.length json);
    Ok bytes)
;;

let decode bytes =
  let length = Bytes.length bytes in
  if length < header_size
  then error "startup payload is truncated"
  else if length > maximum_payload_bytes
  then error "startup payload exceeds 1 MiB"
  else if not (String.equal (Bytes.sub_string bytes 0 4) magic)
  then error "invalid startup magic"
  else (
    let encoded_length = Bytes.get_int32_le bytes 4 in
    if Int32.compare encoded_length 0l < 0
    then error "startup configuration length is invalid"
    else if Int32.to_int encoded_length <> length - header_size
    then error "startup payload has trailing or missing bytes"
    else (
      let json = Bytes.sub_string bytes header_size (length - header_size) in
      try
        match Yojson.Safe.from_string json |> Logseq_db_worker.Config.of_yojson with
        | Ok config -> Ok config
        | Error message -> error "invalid startup configuration: %s" message
      with
      | Yojson.Json_error _ -> error "startup configuration must be valid UTF-8 JSON"))
;;
