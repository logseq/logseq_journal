module Graph_service = Logseq_db_worker_lui.Logseq_db_worker_lui_service

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
  | Deleting_local
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
  | Local_deletion

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

let startup_error ~awaiting_e2ee_password stage message =
  let owner, recovery =
    match stage with
    | Graph_service.During_authentication -> Authentication, Some Sign_in
    | During_catalog -> Catalog, Some Refresh_catalog
    | During_local_restore -> Local_restore, Some Begin_online_recovery
    | During_bootstrap -> Bootstrap, Some Begin_online_recovery
    | During_e2ee ->
      E2ee, Some (if awaiting_e2ee_password then Submit_e2ee_password
                  else Begin_online_recovery)
  in
  { owner; message; recovery }
;;

let graph_matches snapshot (graph : Logseq_db_worker.graph_state) =
  graph.generation = snapshot.Graph_service.startup.graph_generation
  && Option.equal
       Logseq_db_types.Graph_types.Uuid.equal
       graph.graph_id
       snapshot.selected_graph
;;

let derive ~snapshot ~(graph : Logseq_db_worker.graph_state) =
  let facts = snapshot.Graph_service.startup in
  let graph_is_current = graph_matches snapshot graph in
  let ready =
    (facts.authenticated || facts.local_access=Graph_service.Local_available)
    && graph_is_current
    && graph.phase = Logseq_db_worker.Graph_open
    && not snapshot.timeline_presentation_pending
  in
  if Option.is_some snapshot.local_deletion && not ready
  then (
    match snapshot.local_deletion with
    | Some (Graph_service.Deletion_in_progress _) ->
      { phase = Deleting_local; error = None }
    | Some (Graph_service.Deletion_failed _) ->
      { phase = Failed
      ; error =
          Some
            { owner = Local_deletion
            ; message =
                Option.value snapshot.last_error ~default:"Local graph deletion failed."
            ; recovery = None
            }
      }
    | None -> assert false)
  else if ready
  then { phase = Ready; error = None }
  else if facts.local_access=Graph_service.Local_unavailable Graph_service.No_local_account
  then {phase=Signed_out;error=None}
  else if facts.awaiting_selection then {phase=Awaiting_selection;error=None}
  else if facts.awaiting_e2ee_password then
    (match facts.failure with
     | None -> {phase=Awaiting_e2ee_password;error=None}
     | Some stage -> {phase=Failed;error=Some(startup_error ~awaiting_e2ee_password:true stage
         (Option.value snapshot.last_error ~default:"Unable to unlock the graph."))})
  else if (match facts.local_access with Graph_service.Local_unavailable _ -> true | _ -> false)
  then
    let error=startup_error ~awaiting_e2ee_password:false
      (Option.value facts.failure ~default:Graph_service.During_local_restore)
      (Option.value snapshot.last_error ~default:"Local graph data is unavailable.") in
    let error=if facts.local_access=Graph_service.Local_unavailable Graph_service.Local_restore_failed
      then {error with recovery=Some Retry_graph_open} else error in
    {phase=Failed;error=Some error}
  else if not facts.authenticated
  then
    (match facts.failure with
     | Some stage -> { phase = Failed; error = Some (startup_error ~awaiting_e2ee_password:facts.awaiting_e2ee_password stage
         (Option.value snapshot.last_error ~default:"Startup failed.")) }
     | None when facts.restoring_local -> { phase = Restoring_local; error = None }
     | None -> { phase = Signed_out; error = None })
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
               ~awaiting_e2ee_password:facts.awaiting_e2ee_password
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

module Presentation = struct
  type ticket = int64
  type observation =
    { manager : Graph_service.snapshot option
    ; graph : Logseq_db_worker.graph_state
    ; graph_ready : bool
    ; feed_loaded : bool
    ; password_pending : bool
    ; graph_error : bool
    }
  type account_result = Local | No_local | User | No_user
  type screen = Waiting | Timeline | Interaction of startup_state | Account_failure
  type account = Discovering | Local_available | User_available | User_required
  type t =
    { screen : screen
    ; serial : int64
    ; account_serial : int64
    ; indicator : bool
    ; foreground : bool
    ; account : account
    ; local_available : bool
    ; account_failed : bool
    ; observed : observation option
    }
  type event =
    | Observe of observation
    | Account of ticket * account_result
    | Account_error of ticket
    | Retry
    | Signed_out
    | Foreground of bool
    | Elapsed of ticket * float

  let create () =
    { screen = Waiting; serial = 0L; account_serial = 0L; indicator = false
    ; foreground = true; account = Discovering; local_available = false
    ; account_failed = false; observed = None }
  let foreground t = t.foreground
  let screen t = t.screen
  let loading_indicator t = t.foreground && t.screen = Waiting && t.indicator
  let loading_request t =
    if t.foreground && t.screen = Waiting && not t.indicator then Some t.serial else None
  let account_ticket t = t.account_serial
  let initial_attempt t = t.serial = 0L
  let equal_presentation left right =
    left.screen = right.screen
    && (left.screen <> Waiting ||
        (loading_indicator left = loading_indicator right
         && initial_attempt left = initial_attempt right
         && left.foreground = right.foreground))

  let required phase = Interaction {phase;error=None}
  let classify t =
    if t.account = User_required then required Signed_out
    else match t.observed with
    | Some o when o.password_pending -> required Awaiting_e2ee_password
    | Some o ->
      (match o.manager with
       | Some manager when o.graph_ready && o.feed_loaded && not o.graph_error
           && (manager.startup.authenticated || manager.startup.local_access=Graph_service.Local_available)
           && o.graph.phase = Logseq_db_worker.Graph_open && graph_matches manager o.graph -> Timeline
       | Some manager ->
         let startup = derive ~snapshot:manager ~graph:o.graph in
         (match startup.phase with
          | Signed_out when manager.startup.local_access=Graph_service.Local_unavailable Graph_service.No_local_account -> Interaction startup
          | Awaiting_selection | Awaiting_e2ee_password | Failed -> Interaction startup
          | _ when o.graph_error -> required Failed
          | _ when t.account_failed && not t.local_available -> Account_failure
          | _ -> Waiting)
       | None -> if t.account_failed && not t.local_available then Account_failure else Waiting)
    | None -> if t.account_failed && not t.local_available then Account_failure else Waiting

  let project t =
    let next = classify t in
    if next = t.screen then t
    else if next = Waiting then
      {t with screen=next;serial=Int64.succ t.serial;indicator=false}
    else {t with screen=next;indicator=false}

  let step t event =
    let next = match event with
    | Observe o ->
      let previous = Option.bind t.observed (fun o -> o.manager) in
      let changed_account = match previous,o.manager with
        | Some previous,Some next -> previous.startup.account_generation <> 0
          && previous.startup.account_generation <> next.startup.account_generation
        | _ -> false in
      let account = match o.manager with
        | Some manager when changed_account && not manager.startup.authenticated
            && not manager.startup.restoring_local && manager.startup.local_access=Graph_service.Local_pending -> User_required
        | Some manager when manager.startup.authenticated && t.account <> User_required -> User_available
        | _ -> t.account in
      project {t with observed=Some o;account;
        account_serial=(if changed_account then Int64.succ t.account_serial else t.account_serial)}
    | Account (key,result) when key=t.account_serial ->
      let account,local_available=match result with
        | Local -> Local_available,true
        | No_local -> (if t.account=Local_available then Discovering else t.account),false
        | User -> User_available,t.local_available
        | No_user -> User_required,false in
      project {t with account;local_available;account_failed=false}
    | Account_error key when key=t.account_serial -> project {t with account_failed=true}
    | Retry ->
      {t with screen=Waiting;serial=Int64.succ t.serial;account_serial=Int64.succ t.account_serial;
        indicator=false;account=Discovering;local_available=false;account_failed=false;observed=None}
    | Signed_out ->
      {t with screen=required Signed_out;indicator=false;account=User_required;
        account_serial=Int64.succ t.account_serial;local_available=false;account_failed=false}
    | Foreground active when active<>t.foreground ->
      {t with foreground=active;indicator=false;
        serial=(if active && t.screen=Waiting then Int64.succ t.serial else t.serial)}
    | Elapsed (key,elapsed) when key=t.serial && t.foreground && t.screen=Waiting
        && elapsed>=0.1 && not t.indicator -> {t with indicator=true}
    | Account _ | Account_error _ | Foreground _ | Elapsed _ -> t
    in
    if next=t then t else next
end
