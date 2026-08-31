type lifecycle =
  | Ready
  | Fatal of Error.t
  | Closed

type write_target =
  | Snapshot_write_target of { token : Graph_types.Uuid.t }
  | Native_write_target of { sidecars : Derived_sidecars.t }
  | Synced_local_first_target

type active_write_session =
  | Snapshot_write_session of Snapshot.write_session
  | Native_write_session

type t =
  { session : Storage_session.t
  ; owner : Ownership.t
  ; catalog : Snapshot.catalog
  ; write_target : write_target
  ; backup : Backup.t option
  ; mutable write_session : active_write_session option
  ; mutable graph_info : Graph_types.graph_info
  ; mutable sync_metadata : Sync_checkpoint.t option
  ; mutable sync_outbox : string list
  ; mutable projected_db : Datascript.db
  ; mutable mutation_cache :
      (Graph_types.Uuid.t * string * Logseq_db_types.Mutation.success) list
  ; epoch_ms : unit -> int64
  ; cursor_authentication_key : bytes
  ; response_budget_bytes : int
  ; mutable lifecycle : lifecycle
  ; engine_instance : int
  ; mutable sync_revision : int64
  }

let next_engine_instance = Atomic.make 1

type clocks =
  { epoch_ms : unit -> int64
  ; monotonic_ns : unit -> int64
  }

type dependencies =
  { clocks : clocks
  ; cursor_authentication_key : bytes
  }

exception Fatal_storage_error of Error.t

let error code message =
  match Error.create ~code ~message ~details:[] with
  | Ok error -> error
  | Error validation -> invalid_arg validation
;;

let error_with_details code message details =
  match Error.create ~code ~message ~details with
  | Ok error -> error
  | Error validation -> invalid_arg validation
;;

let lower_cause ~component ~operation ~code message =
  Error.create_cause_or_fallback
    ~component
    ~operation
    ~code:(Some code)
    ~message
    ~fallback_message:"The lower operation returned a display-unsafe failure."
;;

let error_with_origin code message ~component ~operation ~origin_code ~origin_message =
  let origin = lower_cause ~component ~operation ~code:origin_code origin_message in
  Error.create_with_origin ~code ~message ~details:[] ~origin |> Result.get_ok
;;

let graph_not_found () = error Error.Graph_not_found "The graph target does not exist."

let corrupt_storage () =
  error Error.Corrupt_storage "The graph storage is corrupt or incomplete."
;;

let unsupported_semantics message = error Error.Unsupported_semantics message

let snapshot_error error =
  let worker_code, message, origin_code, origin_message =
    match error with
    | Snapshot.Token_unknown ->
      ( Error.Graph_not_found
      , "The graph target does not exist."
      , "tokenUnknown"
      , "The snapshot token is unknown." )
    | Source_missing ->
      ( Error.Graph_not_found
      , "The graph target does not exist."
      , "sourceMissing"
      , "The snapshot source is missing." )
    | Invalid_catalog_root ->
      ( Error.Corrupt_storage
      , "The graph storage is corrupt or incomplete."
      , "invalidCatalogRoot"
      , "The snapshot catalog root is invalid." )
    | Invalid_inbox_entry ->
      ( Error.Corrupt_storage
      , "The graph storage is corrupt or incomplete."
      , "invalidInboxEntry"
      , "The snapshot inbox entry is invalid." )
    | Path_escape ->
      ( Error.Corrupt_storage
      , "The graph storage is corrupt or incomplete."
      , "pathEscape"
      , "The snapshot path escapes its catalog." )
    | Symlink_rejected ->
      ( Error.Corrupt_storage
      , "The graph storage is corrupt or incomplete."
      , "symlinkRejected"
      , "The snapshot path contains a symbolic link." )
    | Hard_link_rejected ->
      ( Error.Corrupt_storage
      , "The graph storage is corrupt or incomplete."
      , "hardLinkRejected"
      , "The snapshot database contains a hard link." )
    | Manifest_mismatch ->
      ( Error.Corrupt_storage
      , "The graph storage is corrupt or incomplete."
      , "manifestMismatch"
      , "The snapshot manifest does not match its database." )
    | Publish_failed lower ->
      ( Error.Corrupt_storage
      , "The graph storage is corrupt or incomplete."
      , "publishFailed"
      , lower )
  in
  error_with_origin
    worker_code
    message
    ~component:Error.Snapshot
    ~operation:"snapshotOperation"
    ~origin_code
    ~origin_message
;;

let ownership_error ownership =
  let worker_code, message =
    match ownership with
    | Ownership.Already_owned ->
      Error.Graph_locked, "The graph is owned by another writer."
    | Ambiguous_stale_lock | Identity_changed | Not_owner | Invalid_sentinel ->
      ( Error.Ownership_recovery
      , "Ownership recovery could not be verified. Reset the local graph copy to delete \
         the mirror and download a fresh snapshot." )
  in
  let origin_code, origin_message =
    match ownership with
    | Ownership.Already_owned -> "alreadyOwned", "The graph already has an active owner."
    | Ambiguous_stale_lock ->
      "ambiguousStaleLock", "The existing ownership lock cannot be safely recovered."
    | Identity_changed ->
      "identityChanged", "The graph directory or ownership database identity changed."
    | Not_owner -> "notOwner", "The worker no longer owns the graph."
    | Invalid_sentinel -> "invalidSentinel", "The ownership sentinel is invalid."
  in
  error_with_origin
    worker_code
    message
    ~component:Error.Ownership
    ~operation:"verifyOwnership"
    ~origin_code
    ~origin_message
;;

let admission_error admission =
  let code, message, origin_code, origin_message =
    match admission with
    | Admission.Unsupported_schema ->
      ( Error.Unsupported_schema
      , "App upgrade required. This graph uses a schema that Logseq Journal cannot open."
      , "unsupportedSchema"
      , "The storage schema is not supported." )
    | Remote_graph ->
      ( Error.Remote_graph
      , "Remote graphs are not supported."
      , "remoteGraph"
      , "The admission target is remote." )
    | Ambiguous_sync_state ->
      ( Error.Ambiguous_sync_state
      , "The graph has contradictory sync identity state."
      , "ambiguousSyncState"
      , "The storage sync identity is contradictory." )
    | Unsupported_value ->
      ( Error.Unsupported_value
      , "The graph contains an unsupported storage value."
      , "unsupportedValue"
      , "The storage contains a value unsupported by the worker." )
    | Corrupt_storage ->
      ( Error.Corrupt_storage
      , "The graph storage is corrupt or incomplete."
      , "corruptStorage"
      , "Admission found corrupt or incomplete storage." )
  in
  error_with_origin
    code
    message
    ~component:Error.Storage
    ~operation:"admitGraph"
    ~origin_code
    ~origin_message
;;

let seq_to_list sequence = List.of_seq sequence

let datoms_for db ?e ~a ?v () =
  Datascript.datoms db Datascript.Eavt ?e ~a ?v () |> seq_to_list
;;

type structural_violation =
  | Invalid_parent_value of int
  | Multiple_parents of int
  | Invalid_name_value of int
  | Invalid_page_value of int
  | Multiple_page_targets of int
  | Invalid_order_value of int
  | Duplicate_sibling_order of int * string * int list
  | Invalid_named_page_target of int * int
  | Parent_cycle of int list

module Structural_violation_set = Set.Make (struct
    type t = structural_violation

    let compare = Stdlib.compare
  end)

let tree_structural_violations db =
  let parents = Hashtbl.create 256 in
  let named_pages = Hashtbl.create 256 in
  let page_targets = Hashtbl.create 256 in
  let orders = Hashtbl.create 256 in
  let violations = ref Structural_violation_set.empty in
  let add violation = violations := Structural_violation_set.add violation !violations in
  datoms_for db ~a:"block/parent" ()
  |> List.iter (fun datom ->
    match datom.Datascript.v with
    | Datascript.Ref parent ->
      if Hashtbl.mem parents datom.e
      then add (Multiple_parents datom.e)
      else Hashtbl.add parents datom.e parent
    | _ -> add (Invalid_parent_value datom.e));
  datoms_for db ~a:"block/name" ()
  |> List.iter (fun datom ->
    match datom.Datascript.v with
    | Datascript.String _ -> Hashtbl.replace named_pages datom.e ()
    | _ -> add (Invalid_name_value datom.e));
  datoms_for db ~a:"block/page" ()
  |> List.iter (fun datom ->
    match datom.Datascript.v with
    | Datascript.Ref page ->
      if Hashtbl.mem page_targets datom.e
      then add (Multiple_page_targets datom.e)
      else Hashtbl.add page_targets datom.e page
    | _ -> add (Invalid_page_value datom.e));
  datoms_for db ~a:"block/order" ()
  |> List.iter (fun datom ->
    match datom.Datascript.v with
    | Datascript.String order -> Hashtbl.replace orders datom.e order
    | _ -> add (Invalid_order_value datom.e));
  let sibling_orders = Hashtbl.create 256 in
  Hashtbl.iter
    (fun entity parent ->
       match Hashtbl.find_opt orders entity with
       | _ when entity = parent -> ()
       | None -> ()
       | Some order ->
         let key = parent, order in
         let siblings = Option.value (Hashtbl.find_opt sibling_orders key) ~default:[] in
         Hashtbl.replace sibling_orders key (entity :: siblings))
    parents;
  Hashtbl.iter
    (fun (parent, order) siblings ->
       match siblings with
       | [] | [ _ ] -> ()
       | _ ->
         add (Duplicate_sibling_order (parent, order, List.sort Int.compare siblings)))
    sibling_orders;
  let state = Hashtbl.create 256 in
  let rec cycle_nodes entity acc = function
    | [] -> entity :: acc
    | current :: rest ->
      let acc = current :: acc in
      if current = entity then acc else cycle_nodes entity acc rest
  in
  let rec visit path entity =
    match Hashtbl.find_opt state entity with
    | Some `Done -> ()
    | Some `Visiting ->
      add (Parent_cycle (cycle_nodes entity [] path |> List.sort_uniq Int.compare))
    | None ->
      Hashtbl.replace state entity `Visiting;
      (match Hashtbl.find_opt parents entity with
       | Some parent when parent = entity && Hashtbl.mem named_pages entity ->
         (match Hashtbl.find_opt page_targets entity with
          | None -> ()
          | Some page when page = entity -> ()
          | Some page -> add (Invalid_named_page_target (entity, page)))
       | Some parent -> visit (entity :: path) parent
       | None -> ());
      Hashtbl.replace state entity `Done
  in
  Hashtbl.iter (fun entity _ -> visit [] entity) parents;
  !violations
;;

let db_basis db = db.Datascript.max_tx |> Int64.of_int

let close_partial owner connection =
  ignore
    (Logseq_sqlite_storage.close (Logseq_sqlite_storage.connection_callbacks connection));
  ignore (Ownership.release owner)
;;

let remove_obsolete_pending_intents graph_dir =
  let path = Filename.concat graph_dir "pending-intents-v1.json" in
  try
    Unix.unlink path;
    Ok ()
  with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok ()
  | Unix.Unix_error _ -> Error (corrupt_storage ())
;;

type resolved_target =
  { graph_name : string
  ; graph_dir : string
  ; database_path : string
  ; catalog : Snapshot.catalog
  ; kind : [ `Snapshot of Graph_types.Uuid.t | `Native | `Synced of Sync_checkpoint.t ]
  }

let graph_locator_error locator =
  let origin_code, origin_message =
    match locator with
    | Graph_locator.Invalid_graph_name _ ->
      "invalidGraphName", "The graph name is invalid."
    | Invalid_utf8 -> "invalidUtf8", "The graph name is not valid UTF-8."
    | Path_escape -> "pathEscape", "The graph path escapes the platform graph root."
    | Symlink_escape -> "symlinkEscape", "The graph path escapes through a symbolic link."
    | Basename_mismatch ->
      "basenameMismatch", "The graph directory basename does not match the graph name."
    | Graph_directory_missing ->
      "graphDirectoryMissing", "The graph directory is missing."
    | Database_missing -> "databaseMissing", "The graph database is missing."
  in
  error_with_origin
    Error.Graph_not_found
    "The graph target does not exist."
    ~component:Error.Graph_locator
    ~operation:"validateNativeGraph"
    ~origin_code
    ~origin_message
;;

let sqlite_error ~operation ~worker_code ~public_message storage_error =
  let origin_code, origin_message =
    match storage_error with
    | Logseq_sqlite_storage.Pragma_mismatch message -> "pragmaMismatch", message
    | Corrupt_storage message -> "corruptStorage", message
    | Begin_failed message -> "beginFailed", message
    | Write_failed { message; _ } -> "writeFailed", message
    | Commit_failed message -> "commitFailed", message
    | Checkpoint_failed message -> "checkpointFailed", message
    | Close_failed message -> "closeFailed", message
  in
  error_with_origin
    worker_code
    public_message
    ~component:Error.Sqlite
    ~operation
    ~origin_code
    ~origin_message
;;

let storage_string_error ~operation ~origin_code ~worker_code ~public_message message =
  error_with_origin
    worker_code
    public_message
    ~component:Error.Storage
    ~operation
    ~origin_code
    ~origin_message:message
;;

let resolve_target config =
  match
    Snapshot.create_catalog
      ~application_support_directory:config.Config.application_support_directory
  with
  | Error error -> Error (snapshot_error error)
  | Ok catalog ->
    (match config.target with
     | Config.Managed_sync _ ->
       Error
         (error
            Error.Invalid_request
            "Managed sync startup must be opened by the managed sync service.")
     | Config.Snapshot { token } ->
       (match Snapshot.resolve catalog token with
        | Ok resolved ->
          Ok
            { graph_name = resolved.Snapshot.graph_name
            ; graph_dir = resolved.graph_dir
            ; database_path = Filename.concat resolved.graph_dir "db.sqlite"
            ; catalog
            ; kind = `Snapshot token
            }
        | Error error -> Error (snapshot_error error))
     | Config.Import_snapshot { inbox_entry } ->
       (match Snapshot.import catalog ~inbox_entry with
        | Error error -> Error (snapshot_error error)
        | Ok token ->
          (match Snapshot.resolve catalog token with
           | Ok resolved ->
             Ok
               { graph_name = resolved.Snapshot.graph_name
               ; graph_dir = resolved.graph_dir
               ; database_path = Filename.concat resolved.graph_dir "db.sqlite"
               ; catalog
               ; kind = `Snapshot token
               }
           | Error error -> Error (snapshot_error error)))
     | Config.Synced_mirror { graph_name; graph_dir; database_path; checkpoint; _ } ->
       Ok { graph_name; graph_dir; database_path; catalog; kind = `Synced checkpoint }
     | Config.Native_local_graph { graph_name; graph_dir } ->
       (match Graph_locator.validate_native ~graph_name ~graph_dir with
        | Error locator -> Error (graph_locator_error locator)
        | Ok resolved ->
          Ok
            { graph_name = resolved.Graph_locator.graph_name
            ; graph_dir = resolved.graph_dir
            ; database_path = resolved.database_path
            ; catalog
            ; kind = `Native
            }))
;;

let client_history_error () =
  unsupported_semantics "Native graph client-operation history is not supported."
;;

let sqlite_scalar_int db sql =
  let statement = Sqlite3.prepare db sql in
  Fun.protect
    ~finally:(fun () -> ignore (Sqlite3.finalize statement))
    (fun () ->
       match Sqlite3.step statement with
       | Sqlite3.Rc.ROW -> Ok (Sqlite3.column_int statement 0)
       | _ -> Error ())
;;

let client_history_table_nonempty db table =
  let table_exists =
    sqlite_scalar_int
      db
      (Printf.sprintf
         "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = '%s')"
         table)
  in
  match table_exists with
  | Error () -> Error ()
  | Ok 0 -> Ok false
  | Ok _ ->
    (match
       sqlite_scalar_int
         db
         (Printf.sprintf "SELECT EXISTS(SELECT 1 FROM %s LIMIT 1)" table)
     with
     | Ok value -> Ok (value <> 0)
     | Error () -> Error ())
;;

type native_client_history =
  | Empty_client_history
  | Client_rtc_identity
  | Unsupported_client_history

type inspected_path =
  | Missing_path
  | Existing_path of Unix.file_kind
  | Unreadable_path

let inspect_path path =
  try Existing_path (Unix.lstat path).Unix.st_kind with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> Missing_path
  | Unix.Unix_error _ -> Unreadable_path
;;

let client_history_has_rtc_identity db =
  match
    sqlite_scalar_int
      db
      "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = \
       'sync_meta')"
  with
  | Error () -> Error ()
  | Ok 0 -> Ok false
  | Ok _ ->
    (match
       sqlite_scalar_int
         db
         "SELECT EXISTS(SELECT 1 FROM sync_meta WHERE key = 'graph-uuid' AND value IS \
          NOT NULL LIMIT 1)"
     with
     | Ok value -> Ok (value <> 0)
     | Error () -> Error ())
;;

let sqlite_file_uri path =
  let buffer = Buffer.create (String.length path + 24) in
  String.iter
    (fun character ->
       match character with
       | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '.' | '_' | '~' | '/' ->
         Buffer.add_char buffer character
       | _ -> Buffer.add_string buffer (Printf.sprintf "%%%02X" (Char.code character)))
    path;
  "file:" ^ Buffer.contents buffer ^ "?immutable=1"
;;

let classify_native_client_history graph_dir =
  let directory = Filename.concat graph_dir "client-ops-" in
  let path = Filename.concat directory "db.sqlite" in
  match inspect_path directory with
  | Missing_path -> Empty_client_history
  | Unreadable_path | Existing_path (S_LNK | S_REG | S_CHR | S_BLK | S_FIFO | S_SOCK) ->
    Unsupported_client_history
  | Existing_path S_DIR ->
    (match inspect_path path with
     | Missing_path -> Empty_client_history
     | Unreadable_path | Existing_path (S_LNK | S_DIR | S_CHR | S_BLK | S_FIFO | S_SOCK)
       -> Unsupported_client_history
     | Existing_path S_REG ->
       (try
          let db = Sqlite3.db_open ~mode:`READONLY ~uri:true (sqlite_file_uri path) in
          Fun.protect
            ~finally:(fun () -> ignore (Sqlite3.db_close db))
            (fun () ->
               match client_history_has_rtc_identity db with
               | Ok true -> Client_rtc_identity
               | Error () -> Unsupported_client_history
               | Ok false ->
                 let rec inspect = function
                   | [] -> Empty_client_history
                   | table :: rest ->
                     (match client_history_table_nonempty db table with
                      | Ok false -> inspect rest
                      | Ok true | Error () -> Unsupported_client_history)
                 in
                 inspect [ "client_ops"; "sync_conflicts"; "sync_meta" ])
        with
        | Sqlite3.SqliteError _ -> Unsupported_client_history))
;;

let build_engine dependencies config target owner connection db storage =
  let fail error =
    close_partial owner connection;
    Error error
  in
  match Logseq_sqlite_storage.startup_metadata connection with
  | Error storage_error ->
    fail
      (sqlite_error
         ~operation:"readStartupMetadata"
         ~worker_code:Error.Corrupt_storage
         ~public_message:"The graph storage is corrupt or incomplete."
         storage_error)
  | Ok startup_metadata ->
    let sync_metadata_matches =
      match target.kind with
      | `Snapshot _ | `Native -> true
      | `Synced expected ->
        (match Logseq_sqlite_storage.sync_metadata connection with
         | Ok actual -> actual = expected
         | Error _ -> false)
    in
    if not sync_metadata_matches
    then fail (corrupt_storage ())
    else (
      let admission_target =
        match target.kind with
        | `Snapshot _ | `Native -> Admission.Local_target
        | `Synced metadata -> Synced_target metadata.graph_id
      in
      match
        Admission.inspect
          ~target:admission_target
          ~db
          ~storage_schema:startup_metadata.schema
      with
      | Error admission -> fail (admission_error admission)
      | Ok admitted ->
        let metadata_matches =
          match target.kind with
          | `Snapshot _ | `Native -> true
          | `Synced metadata -> metadata.schema = admitted.schema
        in
        if not metadata_matches
        then fail (corrupt_storage ())
        else (
          let session =
            Storage_session.create
              ~db
              ~tail:(Datascript.Storage.restore_tail_groups storage)
              ~callbacks:(Logseq_sqlite_storage.connection_callbacks connection)
          in
          let target_resources =
            match target.kind with
            | `Snapshot token ->
              Ok
                ( Snapshot_write_target { token }
                , Some (Backup.create ~catalog:target.catalog ~source_token:token)
                , Graph_types.Snapshot )
            | `Native ->
              (match Derived_sidecars.create ~graph_dir:target.graph_dir ~owner with
               | Error _ -> Error (corrupt_storage ())
               | Ok sidecars ->
                 Ok
                   ( Native_write_target { sidecars }
                   , Some
                       (Backup.create_native
                          ~catalog:target.catalog
                          ~source_graph_dir:target.graph_dir
                          ~owner)
                   , Graph_types.Native_read_write ))
            | `Synced _ ->
              Ok (Synced_local_first_target, None, Graph_types.Synced_local_first)
          in
          match target_resources with
          | Error error -> fail error
          | Ok (write_target, backup, mode) ->
            let sync_outbox =
              match target.kind with
              | `Synced _ ->
                Storage_session.load_sync_outbox session
                |> Result.map_error (fun _ -> corrupt_storage ())
              | `Snapshot _ | `Native -> Ok []
            in
            (match sync_outbox with
             | Error error -> fail error
             | Ok sync_outbox ->
               Ok
                 { session
                 ; owner
                 ; catalog = target.catalog
                 ; write_target
                 ; backup
                 ; write_session = None
                 ; mutation_cache = []
                 ; graph_info =
                     { local_graph_uuid = admitted.local_graph_uuid
                     ; graph_name = target.graph_name
                     ; graph_dir = target.graph_dir
                     ; schema = admitted.schema
                     ; basis = db_basis db
                     ; mode
                     ; admission_facts =
                         admitted.admission_facts @ [ Graph_types.Ownership_verified ]
                     }
                 ; sync_metadata =
                     (match target.kind with
                      | `Synced metadata -> Some metadata
                      | `Snapshot _ | `Native -> None)
                 ; sync_outbox
                 ; projected_db = db
                 ; epoch_ms = dependencies.clocks.epoch_ms
                 ; cursor_authentication_key =
                     Bytes.copy dependencies.cursor_authentication_key
                 ; response_budget_bytes = config.Config.response_budget_bytes
                 ; lifecycle = Ready
                 ; engine_instance = Atomic.fetch_and_add next_engine_instance 1
                 ; sync_revision = 0L
                 })))
;;

let open_owned dependencies config target owner =
  let fail_before_open error =
    ignore (Ownership.release owner);
    Error error
  in
  match Ownership.revalidate owner with
  | Error ownership -> fail_before_open (ownership_error ownership)
  | Ok () ->
    let cleanup =
      match target.kind with
      | `Synced _ -> remove_obsolete_pending_intents target.graph_dir
      | `Snapshot _ | `Native -> Ok ()
    in
    (match cleanup with
     | Error error -> fail_before_open error
     | Ok () ->
       let database_path = target.database_path in
       let identity_before =
         try Some (Unix.stat database_path) with
         | Unix.Unix_error _ -> None
       in
       (match identity_before with
        | None -> fail_before_open (graph_not_found ())
        | Some identity_before ->
          (match Logseq_sqlite_storage.open_database database_path with
           | Error storage_error ->
             fail_before_open
               (sqlite_error
                  ~operation:"openDatabase"
                  ~worker_code:Error.Storage_busy
                  ~public_message:
                    "The graph database could not be opened for exclusive writing."
                  storage_error)
           | Ok connection ->
             let fail error =
               close_partial owner connection;
               Error error
             in
             let identity_after =
               try Some (Unix.stat database_path) with
               | Unix.Unix_error _ -> None
             in
             let identity_matches =
               match identity_after with
               | Some identity_after ->
                 identity_before.Unix.st_dev = identity_after.Unix.st_dev
                 && identity_before.st_ino = identity_after.st_ino
               | None -> false
             in
             if not identity_matches
             then fail (corrupt_storage ())
             else (
               match Ownership.revalidate owner with
               | Error ownership -> fail (ownership_error ownership)
               | Ok () ->
                 let outbox_initialized =
                   match target.kind with
                   | `Synced _ -> Logseq_sqlite_storage.initialize_sync_outbox connection
                   | `Snapshot _ | `Native -> Ok ()
                 in
                 (match outbox_initialized with
                  | Error message ->
                    fail
                      (storage_string_error
                         ~operation:"initializeSyncOutbox"
                         ~origin_code:"initializeSyncOutboxFailed"
                         ~worker_code:Error.Corrupt_storage
                         ~public_message:"The graph storage is corrupt or incomplete."
                         message)
                  | Ok () ->
                    let storage = Logseq_sqlite_storage.datascript_storage connection in
                    (match Logseq_sqlite_storage.restore_database connection with
                     | Error storage_error ->
                       fail
                         (sqlite_error
                            ~operation:"restoreDatabase"
                            ~worker_code:Error.Corrupt_storage
                            ~public_message:"The graph storage is corrupt or incomplete."
                            storage_error)
                     | Ok db ->
                       build_engine dependencies config target owner connection db storage))))))
;;

let open_once ~dependencies config =
  if Bytes.length dependencies.cursor_authentication_key < 32
  then Error (error Error.Invalid_request "The cursor authentication key is too short.")
  else (
    match resolve_target config with
    | Error _ as error -> error
    | Ok target ->
      let ownership_target =
        match target.kind with
        | `Snapshot _ -> Ownership.Snapshot_target
        | `Native -> Ownership.Native_target
        | `Synced _ -> Ownership.Synced_target
      in
      (match Ownership.acquire ~target:ownership_target ~graph_dir:target.graph_dir with
       | Error ownership -> Error (ownership_error ownership)
       | Ok owner ->
         (match target.kind with
          | `Native ->
            (match classify_native_client_history target.graph_dir with
             | Empty_client_history -> open_owned dependencies config target owner
             | Client_rtc_identity ->
               ignore (Ownership.release owner);
               Error (admission_error Admission.Ambiguous_sync_state)
             | Unsupported_client_history ->
               ignore (Ownership.release owner);
               Error (client_history_error ()))
          | `Snapshot _ | `Synced _ -> open_owned dependencies config target owner)))
;;

let ios_native_fallback config =
  match config.Config.target with
  | Native_local_graph { graph_name; graph_dir } ->
    let expected =
      Filename.concat
        (Filename.concat config.application_support_directory "graphs")
        graph_name
    in
    if String.equal graph_dir expected then Some (graph_name, graph_dir) else None
  | Managed_sync _ | Snapshot _ | Import_snapshot _ | Synced_mirror _ -> None
;;

let eligible_native_fallback_error error =
  match Error.code error with
  | Graph_not_found | Corrupt_storage -> true
  | Invalid_request
  | Unsupported_api_version
  | Graph_locked
  | Ownership_recovery
  | Unsupported_schema
  | Remote_graph
  | Ambiguous_sync_state
  | Unsupported_value
  | Unsupported_semantics
  | Not_found
  | Ambiguous_selector
  | Duplicate_selector
  | Built_in_protected
  | Invalid_tree
  | Invalid_order
  | Invalid_position
  | Conflict
  | Response_too_large
  | Storage_busy
  | Closed_session -> false
;;

let open_ ~dependencies config =
  match open_once ~dependencies config with
  | Ok _ as opened -> opened
  | Error original_error ->
    (match ios_native_fallback config with
     | None -> Error original_error
     | Some _ when not (eligible_native_fallback_error original_error) ->
       Error original_error
     | Some (inbox_entry, destination_graph_dir) ->
       (match
          Snapshot.create_catalog
            ~application_support_directory:config.application_support_directory
        with
        | Error _ -> Error original_error
        | Ok catalog ->
          (match Snapshot.import_native catalog ~inbox_entry ~destination_graph_dir with
           | Error _ -> Error original_error
           | Ok () -> open_once ~dependencies config)))
;;

let session_error_message = function
  | Storage_session.Closed -> "storage session is closed"
  | Storage_session.Fatal message
  | Storage_session.Stage_failed message
  | Storage_session.Persistence_failed message -> message
  | Storage_session.Already_consumed -> "staged transaction was already consumed"
;;

let rec find_cached_mutation mutation_id = function
  | [] -> None
  | (cached_id, fingerprint, result) :: rest ->
    if Graph_types.Uuid.equal mutation_id cached_id
    then Some (fingerprint, result)
    else find_cached_mutation mutation_id rest
;;

let take limit values =
  let rec loop remaining acc = function
    | _ when remaining = 0 -> List.rev acc
    | [] -> List.rev acc
    | value :: rest -> loop (remaining - 1) (value :: acc) rest
  in
  loop limit [] values
;;

let remember_mutation t mutation_id fingerprint result =
  t.mutation_cache
  <- take
       256
       ((mutation_id, fingerprint, result)
        :: List.filter
             (fun (cached_id, _, _) -> not (Graph_types.Uuid.equal mutation_id cached_id))
             t.mutation_cache)
;;

let planner_error planner =
  let code, message, origin_code, origin_message =
    match planner with
    | Mutation_plan.Unsupported_semantics message ->
      Error.Unsupported_semantics, message, "unsupportedSemantics", message
    | Invalid_selection message -> Error.Not_found, message, "invalidSelection", message
    | Invalid_tree message -> Error.Invalid_tree, message, "invalidTree", message
    | Invalid_order message -> Error.Invalid_order, message, "invalidOrder", message
    | Invalid_position message ->
      Error.Invalid_position, message, "invalidPosition", message
    | Conflict message -> Error.Conflict, message, "conflict", message
    | Built_in_protected ->
      ( Error.Built_in_protected
      , "Built-in graph entities cannot be modified."
      , "builtInProtected"
      , "The mutation targets a built-in graph entity." )
  in
  error_with_origin
    code
    message
    ~component:Error.Mutation_planner
    ~operation:"planMutation"
    ~origin_code
    ~origin_message
;;

let fatal_error message =
  error_with_origin
    Error.Corrupt_storage
    "The graph storage session encountered a fatal error."
    ~component:Error.Engine
    ~operation:"terminalStorageFailure"
    ~origin_code:"fatalStorage"
    ~origin_message:message
;;

let terminalize t message =
  let error = fatal_error message in
  ignore (Storage_session.close t.session);
  ignore (Ownership.release t.owner);
  t.lifecycle <- Fatal error;
  raise (Fatal_storage_error error)
;;

let require_ownership t message =
  match Ownership.revalidate t.owner with
  | Ok () -> ()
  | Error _ -> terminalize t message
;;

let ensure_write_session t mutation_id =
  match t.write_session with
  | Some _ -> Ok ()
  | None ->
    require_ownership t "graph ownership changed before mutation preparation";
    (match t.backup with
     | None ->
       Error (unsupported_semantics "Synced graphs do not commit direct mutations.")
     | Some backup ->
       (match Backup.ensure_verified backup with
        | Error (Backup.Snapshot_error error) -> Error (snapshot_error error)
        | Error (Backup.Ownership_error _) ->
          terminalize t "graph ownership changed while creating the recovery backup"
        | Ok recovery_token ->
          require_ownership t "graph ownership changed after creating the recovery backup";
          (match t.write_target with
           | Snapshot_write_target { token } ->
             (match
                Snapshot.begin_write_session t.catalog token ~recovery_token ~mutation_id
              with
              | Error error -> Error (snapshot_error error)
              | Ok write_session ->
                t.write_session <- Some (Snapshot_write_session write_session);
                Ok ())
           | Native_write_target { sidecars } ->
             (match Derived_sidecars.invalidate sidecars with
              | Ok _ ->
                require_ownership t "graph ownership changed after sidecar invalidation";
                t.write_session <- Some Native_write_session;
                Ok ()
              | Error (Derived_sidecars.Ownership_error _) ->
                terminalize t "graph ownership changed during sidecar invalidation"
              | Error (Invalid_marker | Io_error) -> Error (corrupt_storage ()))
           | Synced_local_first_target ->
             Error (unsupported_semantics "Synced graphs do not commit direct mutations."))))
;;

let collect_garbage_if_needed t =
  match Storage_session.garbage_collection_needed t.session with
  | Error error -> terminalize t (session_error_message error)
  | Ok false -> Ok ()
  | Ok true ->
    (match t.backup with
     | None -> Error (unsupported_semantics "Synced graphs do not run local write GC.")
     | Some backup ->
       (match Backup.ensure_verified backup with
        | Error (Backup.Snapshot_error error) -> Error (snapshot_error error)
        | Error (Backup.Ownership_error _) ->
          terminalize t "graph ownership changed while verifying the GC recovery backup"
        | Ok _recovery_token ->
          require_ownership t "graph ownership changed before reachability GC";
          (match Storage_session.collect_garbage t.session with
           | Ok () -> Ok ()
           | Error error -> terminalize t (session_error_message error))))
;;

let add_backup_fact graph_info =
  if List.mem Graph_types.Backup_verified graph_info.Graph_types.admission_facts
  then graph_info
  else
    { graph_info with
      admission_facts = graph_info.admission_facts @ [ Graph_types.Backup_verified ]
    }
;;

let mutation_requires_full_structure_validation = function
  | Logseq_db_types.Mutation.Structural (Save_block _) -> false
  | Structural
      ( Insert_blocks _
      | Move_blocks _
      | Move_up_down _
      | Indent_outdent _
      | Delete_blocks _ )
  | Page _ -> true
  | Property _ -> false
;;

let validate_tree_for_mutation mutation ~before ~after =
  if not (mutation_requires_full_structure_validation mutation)
  then true
  else (
    let existing = tree_structural_violations before in
    tree_structural_violations after
    |> Structural_violation_set.for_all (fun violation ->
      Structural_violation_set.mem violation existing))
;;

let execute_local_mutation t request_id mutation =
  let basis_before = t.graph_info.basis in
  let context = Mutation.context mutation in
  let identity = Mutation.identify mutation in
  let fingerprint = Mutation.identity_fingerprint identity in
  let succeeded result =
    Protocol.Succeeded
      { request_id
      ; basis = t.graph_info.basis
      ; success = Protocol.Mutation_result result
      }
  in
  match find_cached_mutation context.mutation_id t.mutation_cache with
  | Some (cached_fingerprint, result) ->
    if String.equal fingerprint cached_fingerprint
    then succeeded result
    else
      Protocol.failed
        ~request_id
        ~phase:Execute
        ~basis:(Some basis_before)
        (error Error.Conflict "The mutation ID was already used for a different command.")
  | None ->
    if context.expected_basis <> basis_before
    then
      Protocol.failed
        ~request_id
        ~phase:Execute
        ~basis:(Some basis_before)
        (error_with_details
           Error.Conflict
           "The graph basis changed."
           [ { name = "expectedBasis"; value = Detail_int context.expected_basis }
           ; { name = "actualBasis"; value = Detail_int basis_before }
           ])
    else (
      let database = Storage_session.current_db t.session in
      match Mutation_plan.plan ~now_ms:(t.epoch_ms ()) database mutation with
      | Error planner ->
        Protocol.failed
          ~request_id
          ~phase:Execute
          ~basis:(Some basis_before)
          (planner_error planner)
      | Ok plan when plan.tx_ops = [] ->
        let result =
          Mutation.
            { status = plan.status
            ; basis_before
            ; basis_after = basis_before
            ; changed_uuids = []
            ; changed_uuids_truncated = false
            }
        in
        remember_mutation t context.mutation_id fingerprint result;
        succeeded result
      | Ok plan ->
        (match
           Storage_session.stage_transact ~tx_meta:plan.tx_meta t.session plan.tx_ops
         with
         | Error (Storage_session.Fatal message | Persistence_failed message) ->
           terminalize t message
         | Error stage_error ->
           Protocol.failed
             ~request_id
             ~phase:Execute
             ~basis:(Some basis_before)
             (unsupported_semantics (session_error_message stage_error))
         | Ok staged ->
           if
             not
               (validate_tree_for_mutation
                  mutation
                  ~before:database
                  ~after:(Storage_session.staged_db_after staged))
           then
             Protocol.failed
               ~request_id
               ~phase:Execute
               ~basis:(Some basis_before)
               (error Error.Invalid_tree "The mutation would violate graph structure.")
           else (
             match ensure_write_session t context.mutation_id with
             | Error backup_error ->
               Protocol.failed
                 ~request_id
                 ~phase:Execute
                 ~basis:(Some basis_before)
                 backup_error
             | Ok () ->
               (match collect_garbage_if_needed t with
                | Error backup_error ->
                  Protocol.failed
                    ~request_id
                    ~phase:Execute
                    ~basis:(Some basis_before)
                    backup_error
                | Ok () ->
                  (match Ownership.revalidate t.owner with
                   | Error _ ->
                     terminalize t "graph ownership changed before mutation commit"
                   | Ok () ->
                     (match Storage_session.commit_staged t.session staged with
                      | Error persistence ->
                        terminalize t (session_error_message persistence)
                      | Ok () ->
                        (match t.write_session with
                         | None -> terminalize t "write session disappeared after commit"
                         | Some Native_write_session ->
                           (match Ownership.revalidate t.owner with
                            | Error _ ->
                              terminalize
                                t
                                "graph ownership changed after mutation commit"
                            | Ok () -> ())
                         | Some (Snapshot_write_session write_session) ->
                           (match Ownership.revalidate t.owner with
                            | Error _ ->
                              terminalize
                                t
                                "graph ownership changed after mutation commit"
                            | Ok () ->
                              (match
                                 Snapshot.record_committed_write t.catalog write_session
                               with
                               | Ok () -> ()
                               | Error _ ->
                                 terminalize
                                   t
                                   "unable to authenticate committed snapshot write")));
                        let basis_after = Int64.succ basis_before in
                        let changed_uuids =
                          take Protocol.maximum_changed_uuids plan.changed_uuids
                        in
                        let result =
                          Mutation.
                            { status = Applied
                            ; basis_before
                            ; basis_after
                            ; changed_uuids
                            ; changed_uuids_truncated =
                                List.length plan.changed_uuids
                                > Protocol.maximum_changed_uuids
                            }
                        in
                        t.projected_db <- Storage_session.current_db t.session;
                        t.graph_info
                        <- add_backup_fact { t.graph_info with basis = basis_after };
                        remember_mutation t context.mutation_id fingerprint result;
                        succeeded result))))))
;;

let managed_outliner_op = function
  | Logseq_db_types.Mutation.Structural (Save_block _) -> Some "save-block"
  | Structural (Insert_blocks _) -> Some "insert-blocks"
  | Structural (Delete_blocks _) -> Some "delete-blocks"
  | Page (Create_page { kind = Create_journal_page _; _ }) -> Some "create-page"
  | Property
      ( Set_property { property = Property_by_ident "logseq.property/status"; _ }
      | Remove_property { property = Property_by_ident "logseq.property/status"; _ } ) ->
    Some "save-block"
  | Structural (Move_blocks _ | Move_up_down _ | Indent_outdent _)
  | Page (Create_page { kind = Create_ordinary_page _; _ })
  | Page (Create_page { kind = Create_class_page _; _ })
  | Page (Rename_page _)
  | Page (Delete_page _)
  | Page (Restore_recycled_page _)
  | Page (Permanently_delete_recycled_page _)
  | Property _ -> None
;;

let execute_mutation t request_id mutation =
  match t.write_target with
  | Synced_local_first_target ->
    Protocol.failed
      ~request_id
      ~phase:Execute
      ~basis:(Some t.graph_info.basis)
      (unsupported_semantics
         "Managed graph mutations must enter through Logseq_sync_pure_reducer.Core.")
  | Snapshot_write_target _ | Native_write_target _ ->
    execute_local_mutation t request_id mutation
;;

let ensure_managed_target t =
  match t.write_target, t.sync_metadata with
  | Synced_local_first_target, Some checkpoint -> Ok checkpoint
  | Snapshot_write_target _, _ | Native_write_target _, _ | _, None ->
    Error "The active graph is not a managed sync mirror."
;;

let authoritative_precondition_value t =
  Printf.sprintf "%d:%Ld" t.engine_instance t.sync_revision
;;

let authoritative_precondition t =
  Result.map (fun _ -> authoritative_precondition_value t) (ensure_managed_target t)
;;

let advance_sync_revision t = t.sync_revision <- Int64.succ t.sync_revision
let sync_checkpoint t = ensure_managed_target t

let authoritative_database t =
  Result.map (fun _ -> Storage_session.current_db t.session) (ensure_managed_target t)
;;

let projected_database t = Result.map (fun _ -> t.projected_db) (ensure_managed_target t)

let duplicate_managed_mutation t _mutation =
  Result.map
    (fun _ ->
       let basis = t.graph_info.basis in
       Mutation.
         { status = Already_applied
         ; basis_before = basis
         ; basis_after = basis
         ; changed_uuids = []
         ; changed_uuids_truncated = false
         })
    (ensure_managed_target t)
;;

type prepared_managed_mutation =
  { mutation_id : Graph_types.Uuid.t
  ; mutation_fingerprint : string
  ; mutation_payload : string
  ; outliner_op : string
  ; database : Datascript.db
  ; operations : Datascript.tx_op list
  ; projected : Datascript.db
  ; result : Logseq_db_types.Mutation.success
  ; required_basis : int64
  }

let prepared_mutation_payload prepared = prepared.mutation_payload
let prepared_mutation_outliner_op prepared = prepared.outliner_op
let prepared_mutation_database prepared = prepared.database
let prepared_mutation_operations prepared = prepared.operations

type managed_replan =
  { status : Logseq_db_types.Mutation.status
  ; outliner_op : string
  ; operations : Datascript.tx_op list
  ; projected_database : Datascript.db
  }

let replan_managed_mutation t ~database mutation =
  match ensure_managed_target t, managed_outliner_op mutation with
  | Error message, _ -> Error message
  | Ok _, None -> Error "This mutation is outside the managed sync allowlist."
  | Ok _, Some outliner_op ->
    (match Mutation_plan.plan ~now_ms:(t.epoch_ms ()) database mutation with
     | Error planner -> Error (Error.message (planner_error planner))
     | Ok plan ->
       (try
          let projected_database = Datascript.db_with plan.tx_ops database in
          if
            not
              (validate_tree_for_mutation
                 mutation
                 ~before:database
                 ~after:projected_database)
          then Error "The replanned mutation would violate graph structure."
          else
            Ok
              { status = plan.status
              ; outliner_op
              ; operations = plan.tx_ops
              ; projected_database
              }
        with
        | _ -> Error "The replanned mutation cannot be projected."))
;;

let prepare_managed_mutation t ~identity mutation =
  let context = Logseq_db_types.Mutation.context mutation in
  let basis_before = t.graph_info.basis in
  match ensure_managed_target t, managed_outliner_op mutation with
  | Error message, _ -> Error message
  | Ok _, None -> Error "This mutation is outside the managed sync allowlist."
  | Ok _, Some _ when context.expected_basis <> basis_before ->
    Error
      (Printf.sprintf
         "The projected graph basis changed (expected %Ld, actual %Ld)."
         context.expected_basis
         basis_before)
  | Ok _, Some outliner_op ->
    (match Mutation_plan.plan ~now_ms:(t.epoch_ms ()) t.projected_db mutation with
     | Error planner -> Error (Error.message (planner_error planner))
     | Ok plan ->
       let projected =
         try Ok (Datascript.db_with plan.tx_ops t.projected_db) with
         | _ -> Error "The mutation cannot be projected."
       in
       (match projected with
        | Error _ as error -> error
        | Ok projected
          when not
                 (validate_tree_for_mutation
                    mutation
                    ~before:t.projected_db
                    ~after:projected) ->
          Error "The mutation would violate graph structure."
        | Ok projected ->
          let basis_after = db_basis projected in
          let changed_uuids = take Protocol.maximum_changed_uuids plan.changed_uuids in
          let result =
            Mutation.
              { status = plan.status
              ; basis_before
              ; basis_after
              ; changed_uuids
              ; changed_uuids_truncated =
                  List.length plan.changed_uuids > Protocol.maximum_changed_uuids
              }
          in
          Ok
            { mutation_id = context.mutation_id
            ; mutation_fingerprint = Mutation.identity_fingerprint identity
            ; mutation_payload = Mutation.identity_payload identity
            ; outliner_op
            ; database = t.projected_db
            ; operations = plan.tx_ops
            ; projected
            ; result
            ; required_basis = basis_before
            }))
;;

let commit_managed_mutation t prepared ~outbox_records =
  match ensure_managed_target t with
  | Error _ as error -> error
  | Ok _ when t.graph_info.basis <> prepared.required_basis ->
    Error "The projected graph basis changed before publication."
  | Ok _ ->
    require_ownership t "graph ownership changed before managed mutation commit";
    (match Storage_session.commit_sync_outbox_insert t.session outbox_records with
     | Error persistence_error -> Error (session_error_message persistence_error)
     | Ok () ->
       t.sync_outbox <- outbox_records;
       t.projected_db <- prepared.projected;
       t.graph_info <- { t.graph_info with basis = prepared.result.basis_after };
       advance_sync_revision t;
       remember_mutation
         t
         prepared.mutation_id
         prepared.mutation_fingerprint
         prepared.result;
       Ok prepared.result)
;;

let managed_outbox_records t =
  Result.map (fun _ -> t.sync_outbox) (ensure_managed_target t)
;;

let commit_outbox_transition t ~expected records =
  match ensure_managed_target t with
  | Error _ as error -> error
  | Ok _ when t.sync_outbox <> expected -> Error "The durable outbox changed."
  | Ok _ ->
    require_ownership t "graph ownership changed before outbox transition";
    (match Storage_session.commit_sync_outbox_insert t.session records with
     | Error persistence_error -> Error (session_error_message persistence_error)
     | Ok () ->
       t.sync_outbox <- records;
       advance_sync_revision t;
       Ok ())
;;

let uuid_at db entity =
  Datascript.datoms db Datascript.Eavt ~e:entity ~a:"block/uuid" ()
  |> Seq.find_map (fun datom ->
    match datom.Datascript.v with
    | Datascript.Uuid value -> Graph_types.Uuid.of_string value |> Result.to_option
    | _ -> None)
;;

let changed_uuids ~db_before ~db_after datoms =
  let add values = function
    | None -> values
    | Some uuid ->
      if List.exists (Graph_types.Uuid.equal uuid) values then values else uuid :: values
  in
  datoms
  |> List.fold_left
       (fun values datom ->
          let values = add values (uuid_at db_before datom.Datascript.e) in
          let values = add values (uuid_at db_after datom.e) in
          if String.equal datom.a "block/uuid"
          then (
            match datom.v with
            | Datascript.Uuid value ->
              add values (Graph_types.Uuid.of_string value |> Result.to_option)
            | _ -> values)
          else values)
       []
  |> List.rev
;;

type authoritative_apply_error =
  | Authoritative_conflict
  | Authoritative_apply_failed of string

let apply_authoritative
      t
      ~expected_precondition
      transactions
      ~projection_transactions
      ~checkpoint
      ~outbox_records
  =
  match ensure_managed_target t with
  | Error message -> Error (Authoritative_apply_failed message)
  | Ok _
    when not (String.equal expected_precondition (authoritative_precondition_value t)) ->
    Error Authoritative_conflict
  | Ok _ ->
    require_ownership t "graph ownership changed before sync staging";
    let db_before = Storage_session.current_db t.session in
    (match
       Storage_session.stage_transact_batch
         ~tx_meta:[ "rtc-tx?", Datascript.Bool true ]
         t.session
         transactions
     with
     | Error stage_error ->
       Error (Authoritative_apply_failed (session_error_message stage_error))
     | Ok staged ->
       let database = Storage_session.staged_db_after staged in
       let projection =
         try
           Ok
             (List.fold_left
                (fun database operations -> Datascript.db_with operations database)
                database
                projection_transactions)
         with
         | _ -> Error "The replanned durable outbox cannot be projected."
       in
       let basis_before = db_basis db_before in
       let basis_after = db_basis (Result.value ~default:database projection) in
       let changed_uuids =
         changed_uuids
           ~db_before
           ~db_after:database
           (Storage_session.staged_tx_data staged)
       in
       (match projection with
        | Error message -> Error (Authoritative_apply_failed message)
        | Ok projected ->
          (match Ownership.revalidate t.owner with
           | Error _ ->
             Error
               (Authoritative_apply_failed "Graph ownership changed before sync commit.")
           | Ok ()
             when not
                    (String.equal
                       expected_precondition
                       (authoritative_precondition_value t)) ->
             Error Authoritative_conflict
           | Ok () ->
             (match
                Storage_session.commit_staged_with_sync_metadata_and_outbox
                  t.session
                  staged
                  checkpoint
                  outbox_records
              with
              | Error commit_error ->
                Error (Authoritative_apply_failed (session_error_message commit_error))
              | Ok () ->
                t.sync_metadata <- Some checkpoint;
                t.sync_outbox <- outbox_records;
                t.projected_db <- projected;
                t.graph_info <- { t.graph_info with basis = basis_after };
                advance_sync_revision t;
                Ok (basis_before, basis_after, changed_uuids, projected)))))
;;

let execute t (request : Protocol.request) =
  let basis = t.graph_info.basis in
  let failed code message =
    Protocol.failed
      ~request_id:request.request_id
      ~phase:Execute
      ~basis:(Some basis)
      (error code message)
  in
  let failed_error error =
    Protocol.failed
      ~request_id:request.request_id
      ~phase:Execute
      ~basis:(Some basis)
      error
  in
  match t.lifecycle with
  | Closed -> failed Error.Closed_session "The graph session is closed."
  | Fatal error -> raise (Fatal_storage_error error)
  | Ready ->
    if request.api_version <> Protocol.api_version
    then failed Error.Unsupported_api_version "The request API version is unsupported."
    else (
      let response =
        match request.command with
        | Protocol.Read Protocol.Graph_info ->
          Protocol.Succeeded
            { request_id = request.request_id
            ; basis
            ; success = Protocol.Graph_info_result t.graph_info
            }
        | Protocol.Read command ->
          (match
             Read_model.execute
               { db = t.projected_db
               ; basis
               ; now_ms = t.epoch_ms ()
               ; cursor_key = t.cursor_authentication_key
               }
               command
           with
           | Ok success ->
             Protocol.Succeeded { request_id = request.request_id; basis; success }
           | Error error -> failed_error error)
        | Protocol.Mutate mutation -> execute_mutation t request.request_id mutation
      in
      if Protocol.encoded_response_bytes response <= t.response_budget_bytes
      then response
      else
        failed Error.Response_too_large "The response exceeds the configured byte budget.")
;;

let close (t : t) =
  match t.lifecycle with
  | Closed -> Ok ()
  | Fatal error -> Error (Error.message error)
  | Ready ->
    (match Ownership.revalidate t.owner with
     | Error _ ->
       let message = "graph ownership changed before close" in
       ignore (Storage_session.close t.session);
       ignore (Ownership.release t.owner);
       t.lifecycle <- Fatal (fatal_error message);
       Error message
     | Ok () ->
       (match Storage_session.close t.session with
        | Error error ->
          let message = session_error_message error in
          ignore (Ownership.release t.owner);
          t.lifecycle <- Fatal (fatal_error message);
          Error message
        | Ok () ->
          let finalize =
            match t.write_session with
            | None -> Ok ()
            | Some Native_write_session ->
              t.write_session <- None;
              Ok ()
            | Some (Snapshot_write_session write_session) ->
              (match Snapshot.finish_write_session t.catalog write_session with
               | Ok () ->
                 t.write_session <- None;
                 Ok ()
               | Error _ -> Error "snapshot write-session finalization failed")
          in
          (match finalize with
           | Error message ->
             ignore (Ownership.release t.owner);
             t.lifecycle <- Fatal (fatal_error message);
             Error message
           | Ok () ->
             (match Ownership.release t.owner with
              | Error _ ->
                let message = "graph ownership release failed" in
                t.lifecycle <- Fatal (fatal_error message);
                Error message
              | Ok () ->
                t.lifecycle <- Closed;
                Ok ()))))
;;

let basis t =
  match t.lifecycle with
  | Ready -> Some t.graph_info.basis
  | Fatal _ | Closed -> None
;;
