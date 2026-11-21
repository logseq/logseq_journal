module Dsl = Sync_dsl.Core
module Native = Logseq_sync_native_transport
module Http = Native.Http
module Cursor = Logseq_overlay_db.Types.Server_cursor

let ( let* ) = Result.bind

type artifact =
  { snapshot : Dsl.snapshot
  ; directory : string
  ; source : Execute.Core.snapshot_source
  ; reservation : int64
  ; mutable handed : bool
  }

type t =
  { root : string
  ; identity : Dsl.identity
  ; limits : Dsl.limits
  ; encrypted : bool
  ; verify : Native.Snapshot_checksum.verifier
  ; http : Http_client.t
  ; mutable artifacts : artifact list
  ; mutable pending_cleanup : (string * int64) list
  ; mutable released : Dsl.snapshot Weak.t list
  ; mutable reserved : int64
  ; mutable acquiring : bool
  ; mutable closed : bool
  }

let create ~verify ~root ~identity ~limits ~encrypted ~http =
  try
    if Filename.is_relative root || (Unix.lstat root).st_kind <> Unix.S_DIR
    then Error (Dsl.Invalid_input "Snapshot staging directory")
    else
      Ok
        { root
        ; identity
        ; limits
        ; encrypted
        ; verify
        ; http
        ; artifacts = []
        ; pending_cleanup = []
        ; released = []
        ; reserved = 0L
        ; acquiring = false
        ; closed = false
        }
  with
  | Unix.Unix_error _ ->
    Error (Dsl.Storage_failure "Snapshot staging directory unavailable")
;;

let find t snapshot =
  match List.find_opt (fun artifact -> artifact.snapshot == snapshot) t.artifacts with
  | Some artifact -> Ok artifact
  | None -> Error Dsl.Stale_context
;;

let source t snapshot =
  let* artifact = find t snapshot in
  Ok artifact.source
;;

let validate_resource t = function
  | Dsl.Snapshot_reference snapshot -> Result.map (fun _ -> ()) (find t snapshot)
  | _ -> Error (Dsl.Invalid_input "Not a snapshot resource")
;;

let cleanup directory =
  try
    Native.Snapshot_verify.remove_tree directory;
    Ok ()
  with
  | _ -> Error (Dsl.Storage_failure "Snapshot staging cleanup failed")
;;

let release t ~identity snapshot =
  if identity <> t.identity
  then Error Dsl.Stale_context
  else (
    match find t snapshot with
    | Error error ->
      if
        List.exists
          (fun weak ->
             match Weak.get weak 0 with
             | Some original -> original == snapshot
             | None -> false)
          t.released
      then Ok ()
      else Error error
    | Ok artifact ->
      let* () = cleanup artifact.directory in
      t.reserved <- Int64.sub t.reserved artifact.reservation;
      t.artifacts <- List.filter (fun item -> item != artifact) t.artifacts;
      let weak = Weak.create 1 in
      Weak.set weak 0 (Some snapshot);
      t.released <- weak :: List.filter (fun item -> Weak.check item 0) t.released;
      Ok ())
;;

let drain t =
  if t.acquiring
  then Error (Dsl.Capacity_exceeded "Snapshot acquisition still active")
  else (
    let errors =
      List.filter_map
        (fun artifact ->
           if artifact.handed
           then None
           else (
             match release t ~identity:t.identity artifact.snapshot with
             | Ok () -> None
             | Error error -> Some error))
        t.artifacts
    in
    let pending = t.pending_cleanup in
    let failures =
      List.filter_map
        (fun (directory, reservation) ->
           match cleanup directory with
           | Error error -> Some error
           | Ok () ->
             t.pending_cleanup
             <- List.filter (fun (path, _) -> path <> directory) t.pending_cleanup;
             t.reserved <- Int64.sub t.reserved reservation;
             None)
        pending
    in
    match errors @ failures with
    | [] -> Ok ()
    | failures ->
      Error (Dsl.Cleanup_failure { primary = None; failures = Rrbvec.of_list failures }))
;;

let close t =
  t.closed <- true;
  let* () = drain t in
  let errors =
    List.filter_map
      (fun artifact ->
         match release t ~identity:t.identity artifact.snapshot with
         | Ok () -> None
         | Error error -> Some error)
      t.artifacts
  in
  match errors with
  | [] -> Ok ()
  | failures ->
    Error (Dsl.Cleanup_failure { primary = None; failures = Rrbvec.of_list failures })
;;

let metadata body =
  let invalid () = Error (Dsl.Protocol_failure "Invalid snapshot metadata") in
  try
    match Yojson.Safe.from_string body with
    | `Assoc fields ->
      (match
         ( List.assoc_opt "ok" fields
         , List.assoc_opt "url" fields
         , List.assoc_opt "t" fields )
       with
       | Some (`Bool true), Some (`String url), Some (`Int value)
         when value >= 0 && Int64.of_int value <= 9007199254740991L ->
         let uri = Uri.of_string url in
         if not (Http.valid_artifact uri)
         then invalid ()
         else
           Result.map (fun through -> uri, through) (Cursor.of_int64 (Int64.of_int value))
           |> Result.map_error (fun _ -> Dsl.Protocol_failure "Invalid snapshot cursor")
       | _ -> invalid ())
    | _ -> invalid ()
  with
  | Yojson.Json_error _ | Invalid_argument _ -> invalid ()
;;

let acquire t ~scope ~epoch ~handoff () =
  let* () = scope.Http_client.check_current () in
  if t.closed
  then Error Dsl.Network_closed
  else if
    t.acquiring
    || t.pending_cleanup <> []
    || List.length t.artifacts >= t.limits.maximum_resources
  then Error (Dsl.Capacity_exceeded "Snapshot producers")
  else (
    let maximum64 =
      min
        t.limits.snapshot_maximum_artifact_bytes
        (Int64.div t.limits.snapshot_staging_budget_bytes 3L)
    in
    let reservation = Int64.mul maximum64 3L in
    if
      maximum64 <= 0L
      || maximum64 > Int64.of_int max_int
      || t.reserved > Int64.sub t.limits.snapshot_staging_budget_bytes reservation
    then Error (Dsl.Capacity_exceeded "Snapshot staging budget")
    else (
      let maximum_bytes = Int64.to_int maximum64 in
      t.acquiring <- true;
      t.reserved <- Int64.add t.reserved reservation;
      let directory = ref None
      and retained = ref false
      and result = ref None in
      let work () =
        let base_url = Uri.of_string t.identity.origin in
        let* graph_id =
          Logseq_db_types.Graph_types.Uuid.of_string t.identity.graph
          |> Result.map_error (fun _ -> Dsl.Invalid_input "Snapshot graph identity")
        in
        let* response =
          Http_client.perform t.http ~scope ~epoch ~authenticated:true (fun token ->
            Http.snapshot_metadata ~base_url ~graph_id ~token:(Option.get token))
        in
        let* uri, baseline = metadata response.body in
        let* () = scope.check_current () in
        let path = Filename.temp_file ~temp_dir:t.root "snapshot-" "" in
        Sys.remove path;
        Unix.mkdir path 0o700;
        directory := Some path;
        let raw = Filename.concat path "download"
        and artifact = Filename.concat path "artifact" in
        let temporary_paths =
          [ Filename.concat path "gzip-1"; Filename.concat path "gzip-2" ]
        in
        let* response =
          Http_client.download
            t.http
            ~scope
            ~epoch
            ~authenticated:(Http.same_origin base_url uri)
            ~destination:raw
            ~maximum_bytes
            (fun token -> Http.artifact ~base_url ~uri ~token)
        in
        let* () =
          if response.status >= 200 && response.status < 300
          then Ok ()
          else Error (Dsl.Protocol_failure "Snapshot artifact unavailable")
        in
        let* expected_rows =
          Native.Snapshot_artifact.artifact_row_count response.headers
          |> Result.map_error (fun _ -> Dsl.Protocol_failure "Invalid snapshot row count")
        in
        let* () =
          if expected_rows <= maximum_bytes
          then Ok ()
          else Error (Dsl.Capacity_exceeded "Snapshot rows")
        in
        let* () = scope.check_current () in
        let* () =
          Native.Snapshot_artifact.peel_gzip_layers
            ~decompress_gzip:Native.Artifact_decoder.decompress_gzip
            ~maximum_bytes
            ~source:raw
            ~destination:artifact
            ~temporary_paths
          |> Result.map_error (fun _ ->
            Dsl.Protocol_failure "Invalid snapshot compression")
        in
        List.iter
          (fun file -> if Sys.file_exists file then Sys.remove file)
          (raw :: temporary_paths);
        let* checksum =
          Native.Snapshot_verify.inspect
            ~verify:t.verify
            ~check_current:(fun () ->
              Eio.Fiber.yield ();
              Eio.Fiber.check ())
            ~scratch_bytes:t.limits.snapshot_scratch_budget_bytes
            ~maximum_frame_bytes:(min maximum_bytes (64 * 1024 * 1024))
            ~directory:path
            ~encrypted:t.encrypted
            ~path:artifact
            ~expected_rows
          |> Result.map_error (fun _ ->
            Dsl.Protocol_failure "Invalid snapshot framing, storage or encryption")
        in
        let* () = scope.check_current () in
        let* resource = Dsl.resource ~owner:t.identity ~token:(Filename.basename path) in
        let* snapshot =
          Dsl.snapshot
            ~resource
            ~through:baseline
            ~checksum:(Logseq_overlay_db.Types.Checksum.to_string checksum)
            ~encrypted:t.encrypted
        in
        let size = Int64.of_int (Unix.stat artifact).st_size in
        let entry =
          { snapshot
          ; directory = path
          ; source = { path = artifact; expected_rows }
          ; reservation = size
          ; handed = false
          }
        in
        t.reserved <- Int64.sub t.reserved (Int64.sub reservation size);
        t.artifacts <- entry :: t.artifacts;
        retained := true;
        let transferred =
          Eio.Cancel.protect (fun () ->
            handoff (Rrbvec.singleton (Dsl.Snapshot_reference snapshot)))
        in
        match transferred with
        | Ok () ->
          entry.handed <- true;
          Ok snapshot
        | Error error ->
          (match release t ~identity:t.identity snapshot with
           | Ok () -> Error error
           | Error cleanup ->
             Error
               (Dsl.Cleanup_failure
                  { primary = Some error; failures = Rrbvec.singleton cleanup }))
      in
      let finish () =
        t.acquiring <- false;
        if not !retained
        then (
          match !directory with
          | None -> t.reserved <- Int64.sub t.reserved reservation
          | Some path ->
            (match cleanup path with
             | Ok () -> t.reserved <- Int64.sub t.reserved reservation
             | Error error ->
               t.pending_cleanup <- (path, reservation) :: t.pending_cleanup;
               result
               := Some
                    (Error
                       (Dsl.Cleanup_failure
                          { primary =
                              (match !result with
                               | Some (Error primary) -> Some primary
                               | _ -> None)
                          ; failures = Rrbvec.singleton error
                          }))))
      in
      Fun.protect ~finally:finish (fun () ->
        result
        := Some
             (try work () with
              | Eio.Cancel.Cancelled _ as cancelled -> raise cancelled
              | _ -> Error (Dsl.Storage_failure "Snapshot acquisition failed")));
      Option.get !result))
;;
