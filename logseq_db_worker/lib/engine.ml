type lifecycle =
  | Ready
  | Fatal of string
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
  ; mutable sync_metadata : Sync_meta.t option
  ; graph_key : string option
  ; crypto : Sync_e2ee.crypto
  ; pending : Sync_pending.t option
  ; mutable projected_db : Datascript.db
  ; mutable mutation_cache :
      (Graph_types.Uuid.t * string * Protocol.mutation_success) list
  ; epoch_ms : unit -> int64
  ; cursor_authentication_key : bytes
  ; response_budget_bytes : int
  ; mutable lifecycle : lifecycle
  }

type clocks =
  { epoch_ms : unit -> int64
  ; monotonic_ns : unit -> int64
  }

type dependencies =
  { clocks : clocks
  ; cursor_authentication_key : bytes
  ; crypto : Sync_e2ee.crypto
  ; unlock_graph_key :
      user_id:string -> encrypted_graph_key:string -> (string, string) result
  }

exception Fatal_storage_error of string

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

let graph_not_found () = error Error.Graph_not_found "The graph target does not exist."
let graph_locked () = error Error.Graph_locked "The graph is owned by another writer."

let corrupt_storage () =
  error Error.Corrupt_storage "The graph storage is corrupt or incomplete."
;;

let storage_busy () =
  error Error.Storage_busy "The graph database could not be opened for exclusive writing."
;;

let unsupported_semantics message = error Error.Unsupported_semantics message

let snapshot_error = function
  | Snapshot.Token_unknown | Source_missing -> graph_not_found ()
  | Invalid_catalog_root
  | Invalid_inbox_entry
  | Path_escape
  | Symlink_rejected
  | Hard_link_rejected
  | Manifest_mismatch
  | Publish_failed _ -> corrupt_storage ()
;;

let ownership_error = function
  | Ownership.Already_owned -> graph_locked ()
  | Ambiguous_stale_lock | Identity_changed | Not_owner | Invalid_sentinel ->
    error
      Error.Ownership_recovery
      "Ownership recovery could not be verified. Reset the local graph copy to delete \
       the mirror and download a fresh snapshot."
;;

let admission_error = function
  | Admission.Unsupported_schema ->
    error
      Error.Unsupported_schema
      "App upgrade required. This graph uses a schema that Logseq Journal cannot open."
  | Remote_graph -> error Error.Remote_graph "Remote graphs are not supported."
  | Ambiguous_sync_state ->
    error Error.Ambiguous_sync_state "The graph has contradictory sync identity state."
  | Unsupported_value ->
    error Error.Unsupported_value "The graph contains an unsupported storage value."
  | Corrupt_storage -> corrupt_storage ()
;;

let seq_to_list sequence = List.of_seq sequence

let datoms_for db ?e ~a ?v () =
  Datascript.datoms db Datascript.Eavt ?e ~a ?v () |> seq_to_list
;;

let tree_structurally_valid db =
  let parents = Hashtbl.create 256 in
  let named_pages = Hashtbl.create 256 in
  let page_targets = Hashtbl.create 256 in
  let orders = Hashtbl.create 256 in
  let valid = ref true in
  datoms_for db ~a:"block/parent" ()
  |> List.iter (fun datom ->
    match datom.Datascript.v with
    | Datascript.Ref parent ->
      if Hashtbl.mem parents datom.e then valid := false;
      Hashtbl.replace parents datom.e parent
    | _ -> valid := false);
  datoms_for db ~a:"block/name" ()
  |> List.iter (fun datom ->
    match datom.Datascript.v with
    | Datascript.String _ -> Hashtbl.replace named_pages datom.e ()
    | _ -> valid := false);
  datoms_for db ~a:"block/page" ()
  |> List.iter (fun datom ->
    match datom.Datascript.v with
    | Datascript.Ref page ->
      if Hashtbl.mem page_targets datom.e then valid := false;
      Hashtbl.replace page_targets datom.e page
    | _ -> valid := false);
  datoms_for db ~a:"block/order" ()
  |> List.iter (fun datom ->
    match datom.Datascript.v with
    | Datascript.String order -> Hashtbl.replace orders datom.e order
    | _ -> valid := false);
  let sibling_orders = Hashtbl.create 256 in
  Hashtbl.iter
    (fun entity parent ->
       match Hashtbl.find_opt orders entity with
       | _ when entity = parent -> ()
       | None -> ()
       | Some order ->
         let key = parent, order in
         if Hashtbl.mem sibling_orders key then valid := false;
         Hashtbl.replace sibling_orders key entity)
    parents;
  let state = Hashtbl.create 256 in
  let rec visit entity =
    match Hashtbl.find_opt state entity with
    | Some `Done -> ()
    | Some `Visiting -> valid := false
    | None ->
      Hashtbl.replace state entity `Visiting;
      (match Hashtbl.find_opt parents entity with
       | Some parent when parent = entity && Hashtbl.mem named_pages entity ->
         (match Hashtbl.find_opt page_targets entity with
          | None -> ()
          | Some page when page = entity -> ()
          | Some _ -> valid := false)
       | Some parent -> visit parent
       | None -> ());
      Hashtbl.replace state entity `Done
  in
  Hashtbl.iter (fun entity _ -> visit entity) parents;
  !valid
;;

let db_basis db = db.Datascript.max_tx |> Int64.of_int

let decrypt_protected crypto graph_key =
  Option.map
    (fun graph_key ~attribute:_ ciphertext ->
       Sync_e2ee.decrypt_value ~crypto ~graph_key ciphertext)
    graph_key
;;

let project_pending crypto graph_key db entries =
  let rec loop db = function
    | [] -> Ok db
    | (entry : Sync_pending.entry) :: rest ->
      (match
         Sync_tx.decode
           ?decrypt_protected:(decrypt_protected crypto graph_key)
           ~db
           entry.tx
       with
       | Error _ -> Error "durable pending transaction cannot be decoded"
       | Ok operations ->
         (try loop (Datascript.db_with operations db) rest with
          | _ -> Error "durable pending transaction cannot be projected"))
  in
  loop db entries
;;

let close_partial owner connection =
  ignore
    (Logseq_sqlite_storage.close (Logseq_sqlite_storage.connection_callbacks connection));
  ignore (Ownership.release owner)
;;

type resolved_target =
  { graph_name : string
  ; graph_dir : string
  ; database_path : string
  ; catalog : Snapshot.catalog
  ; kind : [ `Snapshot of Graph_types.Uuid.t | `Native | `Synced of Sync_mirror.metadata ]
  ; graph_key : string option
  }

let sync_mirror_error = function
  | Sync_mirror.Mirror_missing -> graph_not_found ()
  | Admission_failed admission -> admission_error admission
  | Invalid_root
  | Mirror_exists
  | Invalid_snapshot _
  | Invalid_metadata _
  | Activation_failed _
  | Deletion_failed _ -> corrupt_storage ()
;;

let resolve_target dependencies config =
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
            "Managed sync startup must be opened by Sync_manager.")
     | Config.Snapshot { token } ->
       (match Snapshot.resolve catalog token with
        | Ok resolved ->
          Ok
            { graph_name = resolved.Snapshot.graph_name
            ; graph_dir = resolved.graph_dir
            ; database_path = Filename.concat resolved.graph_dir "db.sqlite"
            ; catalog
            ; kind = `Snapshot token
            ; graph_key = None
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
               ; graph_key = None
               }
           | Error error -> Error (snapshot_error error)))
     | Config.Synced_graph { graph_id; graph_name; e2ee; bootstrap } ->
       let graph_key =
         match e2ee with
         | None -> Ok None
         | Some e2ee ->
           (match
              dependencies.unlock_graph_key
                ~user_id:e2ee.user_id
                ~encrypted_graph_key:e2ee.encrypted_graph_key
            with
            | Ok key when String.length key = 32 -> Ok (Some key)
            | Ok _ | Error _ ->
              Error
                (error
                   Error.Invalid_request
                   "The encrypted graph key is unavailable or invalid."))
       in
       Result.bind graph_key (fun graph_key ->
         let resolved =
           match
             ( Sync_mirror.resolve
                 ~application_support_directory:config.application_support_directory
                 ~graph_id
             , bootstrap )
           with
           | Error Sync_mirror.Mirror_missing, Some bootstrap ->
             Fun.protect
               ~finally:(fun () ->
                 try
                   if (Unix.lstat bootstrap.snapshot_path).st_kind = Unix.S_REG
                   then Sys.remove bootstrap.snapshot_path
                 with
                 | Unix.Unix_error _ -> ())
               (fun () ->
                  Sync_mirror.bootstrap
                    ~application_support_directory:config.application_support_directory
                    ~graph_id
                    ~applied_server_t:bootstrap.applied_server_t
                    ?checksum:bootstrap.checksum
                    ~expected_rows:bootstrap.expected_rows
                    ~snapshot_path:bootstrap.snapshot_path
                    ?decrypt_protected:
                      (Option.map
                         (fun graph_key ciphertext ->
                            Result.bind
                              (Sync_e2ee.decrypt_value
                                 ~crypto:dependencies.crypto
                                 ~graph_key
                                 ciphertext)
                              (function
                              | Transit_core.Json.String plaintext -> Ok plaintext
                              | _ -> Error "decrypted protected value must be a string"))
                         graph_key)
                    ())
           | result, _ -> result
         in
         match resolved with
         | Error error -> Error (sync_mirror_error error)
         | Ok resolved ->
           Ok
             { graph_name
             ; graph_dir = resolved.graph_dir
             ; database_path = resolved.database_path
             ; catalog
             ; kind = `Synced resolved.metadata
             ; graph_key
             })
     | Config.Native_local_graph { graph_name; graph_dir } ->
       (match Graph_locator.validate_native ~graph_name ~graph_dir with
        | Error _ -> Error (graph_not_found ())
        | Ok resolved ->
          Ok
            { graph_name = resolved.Graph_locator.graph_name
            ; graph_dir = resolved.graph_dir
            ; database_path = resolved.database_path
            ; catalog
            ; kind = `Native
            ; graph_key = None
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
  | Error _ -> fail (corrupt_storage ())
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
            let pending =
              match target.kind with
              | `Snapshot _ | `Native -> Ok None
              | `Synced _ ->
                Result.bind
                  (Sync_pending.open_ ~graph_dir:target.graph_dir)
                  (fun pending ->
                     let entries = Sync_pending.entries pending in
                     let recovered =
                       List.map
                         (fun (entry : Sync_pending.entry) ->
                            match entry.state with
                            | Submitted -> { entry with state = Queued }
                            | Queued | Accepted _ | Blocked _ -> entry)
                         entries
                     in
                     if recovered = entries
                     then Ok (Some pending)
                     else
                       Result.map
                         (fun () -> Some pending)
                         (Sync_pending.replace pending recovered))
                |> Result.map_error (fun _ -> corrupt_storage ())
            in
            Result.bind pending (fun pending ->
              let projected_db =
                match pending with
                | None -> Ok db
                | Some pending ->
                  project_pending
                    dependencies.crypto
                    target.graph_key
                    db
                    (Sync_pending.entries pending)
                  |> Result.map_error (fun _ -> corrupt_storage ())
              in
              Result.bind projected_db (fun projected_db ->
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
                      ; basis = db_basis projected_db
                      ; mode
                      ; admission_facts =
                          admitted.admission_facts @ [ Graph_types.Ownership_verified ]
                      }
                  ; sync_metadata =
                      (match target.kind with
                       | `Synced metadata -> Some metadata
                       | `Snapshot _ | `Native -> None)
                  ; graph_key = target.graph_key
                  ; crypto = dependencies.crypto
                  ; pending
                  ; projected_db
                  ; epoch_ms = dependencies.clocks.epoch_ms
                  ; cursor_authentication_key =
                      Bytes.copy dependencies.cursor_authentication_key
                  ; response_budget_bytes = config.Config.response_budget_bytes
                  ; lifecycle = Ready
                  }))))
;;

let open_owned dependencies config target owner =
  let fail_before_open error =
    ignore (Ownership.release owner);
    Error error
  in
  match Ownership.revalidate owner with
  | Error ownership -> fail_before_open (ownership_error ownership)
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
        | Error _ -> fail_before_open (storage_busy ())
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
              let storage = Logseq_sqlite_storage.datascript_storage connection in
              (match Logseq_sqlite_storage.restore_database connection with
               | Error _ -> fail (corrupt_storage ())
               | Ok db ->
                 build_engine dependencies config target owner connection db storage))))
;;

let open_once ~dependencies config =
  if Bytes.length dependencies.cursor_authentication_key < 32
  then Error (error Error.Invalid_request "The cursor authentication key is too short.")
  else (
    match resolve_target dependencies config with
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
  | Managed_sync _ | Snapshot _ | Import_snapshot _ | Synced_graph _ -> None
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

let mutation_fingerprint mutation =
  mutation
  |> (fun value -> Marshal.to_string value [ Marshal.No_sharing ])
  |> Digestif.SHA256.digest_string
  |> Digestif.SHA256.to_hex
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

let planner_error = function
  | Mutation_plan.Unsupported_semantics message -> unsupported_semantics message
  | Invalid_selection message -> error Error.Not_found message
  | Invalid_tree message -> error Error.Invalid_tree message
  | Invalid_order message -> error Error.Invalid_order message
  | Invalid_position message -> error Error.Invalid_position message
  | Conflict message -> error Error.Conflict message
  | Built_in_protected ->
    error Error.Built_in_protected "Built-in graph entities cannot be modified."
;;

let terminalize t message =
  ignore (Storage_session.close t.session);
  ignore (Ownership.release t.owner);
  t.lifecycle <- Fatal message;
  raise (Fatal_storage_error message)
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
  | Protocol.Structural (Save_block _) -> false
  | Structural
      ( Insert_blocks _
      | Move_blocks _
      | Move_up_down _
      | Indent_outdent _
      | Delete_blocks _ )
  | Page _ -> true
  | Property _ -> false
;;

let validate_tree_for_mutation mutation db =
  (not (mutation_requires_full_structure_validation mutation))
  || tree_structurally_valid db
;;

let execute_local_mutation t request_id mutation =
  let basis_before = t.graph_info.basis in
  let context = Protocol.mutation_context mutation in
  let fingerprint = mutation_fingerprint mutation in
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
      match
        Mutation_plan.plan
          ~now_ms:(t.epoch_ms ())
          (Storage_session.current_db t.session)
          mutation
      with
      | Error planner ->
        Protocol.failed
          ~request_id
          ~phase:Execute
          ~basis:(Some basis_before)
          (planner_error planner)
      | Ok plan when plan.tx_ops = [] ->
        let result =
          Protocol.
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
                  (Storage_session.staged_db_after staged))
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
                          Protocol.
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

let synced_outliner_op = function
  | Protocol.Structural (Save_block _) -> Some "save-block"
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

let pending_entry_by_id pending mutation_id =
  Sync_pending.entries pending
  |> List.find_opt (fun (entry : Sync_pending.entry) ->
    Graph_types.Uuid.equal entry.mutation_id mutation_id)
;;

let execute_synced_mutation t request_id mutation =
  let basis_before = t.graph_info.basis in
  let context = Protocol.mutation_context mutation in
  let succeeded result =
    Protocol.Succeeded
      { request_id
      ; basis = t.graph_info.basis
      ; success = Protocol.Mutation_result result
      }
  in
  let failed error =
    Protocol.failed ~request_id ~phase:Execute ~basis:(Some basis_before) error
  in
  match t.pending, synced_outliner_op mutation with
  | None, _ -> failed (corrupt_storage ())
  | Some _, None ->
    failed
      (unsupported_semantics
         "This mutation is outside the synced graph mutation allowlist.")
  | Some pending, Some outliner_op ->
    (match pending_entry_by_id pending context.mutation_id with
     | Some existing ->
       let same =
         match existing.request.command with
         | Protocol.Mutate existing ->
           String.equal (mutation_fingerprint existing) (mutation_fingerprint mutation)
         | Read _ | Sync_receive _ -> false
       in
       if same
       then
         succeeded
           Protocol.
             { status = Already_applied
             ; basis_before
             ; basis_after = basis_before
             ; changed_uuids = []
             ; changed_uuids_truncated = false
             }
       else
         failed
           (error
              Error.Conflict
              "The mutation ID is already used by another pending intent.")
     | None ->
       if context.expected_basis <> basis_before
       then
         failed
           (error_with_details
              Error.Conflict
              "The projected graph basis changed."
              [ { name = "expectedBasis"; value = Detail_int context.expected_basis }
              ; { name = "actualBasis"; value = Detail_int basis_before }
              ])
       else (
         match Mutation_plan.plan ~now_ms:(t.epoch_ms ()) t.projected_db mutation with
         | Error planner -> failed (planner_error planner)
         | Ok plan when plan.tx_ops = [] ->
           succeeded
             Protocol.
               { status = plan.status
               ; basis_before
               ; basis_after = basis_before
               ; changed_uuids = []
               ; changed_uuids_truncated = false
               }
         | Ok plan ->
           let projected =
             try Ok (Datascript.db_with plan.tx_ops t.projected_db) with
             | _ -> Error ()
           in
           (match projected with
            | Error () ->
              failed (error Error.Invalid_tree "The mutation cannot be projected.")
            | Ok projected when not (validate_tree_for_mutation mutation projected) ->
              failed
                (error Error.Invalid_tree "The mutation would violate graph structure.")
            | Ok projected ->
              let encrypt_protected =
                Option.map
                  (fun graph_key plaintext ->
                     Sync_e2ee.encrypt_value
                       ~crypto:t.crypto
                       ~graph_key
                       (Transit_core.Json.String plaintext))
                  t.graph_key
              in
              (match
                 Sync_tx_encoder.encode ?encrypt_protected t.projected_db plan.tx_ops
               with
               | Error _ ->
                 failed
                   (unsupported_semantics
                      "The mutation cannot be encoded for upstream sync.")
               | Ok tx ->
                 let request =
                   Protocol.{ api_version; request_id; command = Mutate mutation }
                 in
                 let entry =
                   Sync_pending.
                     { mutation_id = context.mutation_id
                     ; request
                     ; tx
                     ; outliner_op
                     ; state = Queued
                     }
                 in
                 (match Sync_pending.append pending entry with
                  | Error _ ->
                    failed
                      (error
                         Error.Storage_busy
                         "The pending mutation could not be persisted.")
                  | Ok () ->
                    t.projected_db <- projected;
                    let basis_after = db_basis projected in
                    t.graph_info <- { t.graph_info with basis = basis_after };
                    let changed_uuids =
                      take Protocol.maximum_changed_uuids plan.changed_uuids
                    in
                    succeeded
                      Protocol.
                        { status = Applied
                        ; basis_before
                        ; basis_after
                        ; changed_uuids
                        ; changed_uuids_truncated =
                            List.length plan.changed_uuids
                            > Protocol.maximum_changed_uuids
                        })))))
;;

let execute_mutation t request_id mutation =
  match t.write_target with
  | Synced_local_first_target -> execute_synced_mutation t request_id mutation
  | Snapshot_write_target _ | Native_write_target _ ->
    execute_local_mutation t request_id mutation
;;

let protocol_sync_state (metadata : Sync_meta.t) =
  match metadata.status with
  | Active -> Protocol.Sync_active
  | Paused -> Sync_paused_state
;;

let protocol_sync_status (metadata : Sync_meta.t) =
  Protocol.
    { state = protocol_sync_state metadata
    ; applied_server_t = metadata.applied_server_t
    ; checksum = metadata.checksum
    ; last_error = metadata.last_error
    }
;;

let protocol_sync_success ?last_error activity mutation (metadata : Sync_meta.t) =
  Protocol.
    { activity
    ; state = protocol_sync_state metadata
    ; applied_server_t = metadata.applied_server_t
    ; checksum = metadata.checksum
    ; last_error =
        (match last_error with
         | Some _ -> last_error
         | None -> metadata.last_error)
    ; mutation
    }
;;

let encode_synced_tx (t : t) db operations =
  let encrypt_protected =
    Option.map
      (fun graph_key plaintext ->
         Sync_e2ee.encrypt_value
           ~crypto:t.crypto
           ~graph_key
           (Transit_core.Json.String plaintext))
      t.graph_key
  in
  Sync_tx_encoder.encode ?encrypt_protected db operations
;;

let replace_pending_or_terminalize t pending entries =
  match Sync_pending.replace pending entries with
  | Ok () -> ()
  | Error _ -> terminalize t "durable pending intent persistence failed"
;;

let rebase_pending t applied_server_t =
  match t.pending with
  | None -> ()
  | Some pending ->
    let authoritative = Storage_session.current_db t.session in
    let rec loop db rebased = function
      | [] -> Ok (db, List.rev rebased)
      | (entry : Sync_pending.entry) :: rest ->
        (match entry.state with
         | Accepted accepted_t when accepted_t <= applied_server_t -> loop db rebased rest
         | Queued ->
           (match entry.request.command with
            | Protocol.Mutate mutation ->
              (match Mutation_plan.plan ~now_ms:(t.epoch_ms ()) db mutation with
               | Error _ ->
                 let blocked =
                   { entry with state = Blocked "Pending intent could not be rebased." }
                 in
                 loop db (blocked :: rebased) rest
               | Ok plan when plan.tx_ops = [] -> loop db rebased rest
               | Ok plan ->
                 (match encode_synced_tx t db plan.tx_ops with
                  | Error _ ->
                    let blocked =
                      { entry with
                        state = Blocked "Pending intent could not be encoded."
                      }
                    in
                    loop db (blocked :: rebased) rest
                  | Ok tx ->
                    (try
                       let db = Datascript.db_with plan.tx_ops db in
                       loop db ({ entry with tx; state = Queued } :: rebased) rest
                     with
                     | _ ->
                       let blocked =
                         { entry with
                           state = Blocked "Pending intent could not be projected."
                         }
                       in
                       loop db (blocked :: rebased) rest)))
            | Read _ | Sync_receive _ -> Error "pending intent is not a mutation")
         | Submitted | Accepted _ | Blocked _ ->
           (match
              Sync_tx.decode
                ?decrypt_protected:(decrypt_protected t.crypto t.graph_key)
                ~db
                entry.tx
            with
            | Error _ -> Error "pending transaction cannot be decoded"
            | Ok operations ->
              (try loop (Datascript.db_with operations db) (entry :: rebased) rest with
               | _ -> Error "pending transaction cannot be projected")))
    in
    (match loop authoritative [] (Sync_pending.entries pending) with
     | Error _ -> terminalize t "durable pending intent rebase failed"
     | Ok (projected_db, entries) ->
       replace_pending_or_terminalize t pending entries;
       t.projected_db <- projected_db;
       t.graph_info <- { t.graph_info with basis = db_basis projected_db })
;;

let requeue_submitted t ~mutation_ids =
  if mutation_ids = []
  then Error "submitted recovery requires at least one transaction ID"
  else if
    List.length mutation_ids
    <> List.length (List.sort_uniq Graph_types.Uuid.compare mutation_ids)
  then Error "submitted recovery contains duplicate transaction IDs"
  else (
    match t.pending, t.sync_metadata with
    | None, _ | _, None -> Error "submitted recovery requires a synced mirror"
    | Some pending, Some metadata ->
      let entries = Sync_pending.entries pending in
      let recoverable mutation_id =
        List.exists
          (fun (entry : Sync_pending.entry) ->
             Graph_types.Uuid.equal entry.mutation_id mutation_id
             && entry.state = Sync_pending.Submitted)
          entries
      in
      if not (List.for_all recoverable mutation_ids)
      then Error "submitted recovery contains an unknown or non-submitted transaction ID"
      else (
        let recovered =
          List.map
            (fun (entry : Sync_pending.entry) ->
               if List.exists (Graph_types.Uuid.equal entry.mutation_id) mutation_ids
               then { entry with state = Queued }
               else entry)
            entries
        in
        Result.map
          (fun () -> rebase_pending t metadata.applied_server_t)
          (Sync_pending.replace pending recovered)))
;;

let execute_sync_pending t request_id =
  let basis = t.graph_info.basis in
  let success result =
    Protocol.Succeeded
      { request_id; basis; success = Protocol.Sync_pending_result result }
  in
  match t.pending, t.sync_metadata with
  | None, _ | _, None ->
    Protocol.failed
      ~request_id
      ~phase:Execute
      ~basis:(Some basis)
      (unsupported_semantics "The active graph is not a synced mirror.")
  | Some pending, Some metadata ->
    let entries = Sync_pending.entries pending in
    let blocked_error =
      List.find_map
        (fun (entry : Sync_pending.entry) ->
           match entry.state with
           | Blocked message -> Some message
           | Queued | Submitted | Accepted _ -> None)
        entries
    in
    (match blocked_error with
     | Some blocked_error ->
       success
         { payload = None
         ; count = List.length entries
         ; blocked_error = Some blocked_error
         }
     | None ->
       let outgoing =
         entries
         |> List.filter (fun (entry : Sync_pending.entry) ->
           match entry.state with
           | Queued -> true
           | Submitted | Accepted _ | Blocked _ -> false)
         |> take 32
       in
       if outgoing = []
       then success { payload = None; count = List.length entries; blocked_error = None }
       else (
         let txs =
           List.map
             (fun (entry : Sync_pending.entry) ->
                Sync_protocol.
                  { tx = entry.tx
                  ; tx_id = Graph_types.Uuid.to_string entry.mutation_id
                  ; outliner_op = Some entry.outliner_op
                  })
             outgoing
         in
         match Sync_protocol.encode_tx_batch ~t_before:metadata.applied_server_t txs with
         | Error message ->
           Protocol.failed
             ~request_id
             ~phase:Execute
             ~basis:(Some basis)
             (error Error.Invalid_request message)
         | Ok payload when String.length payload > Protocol.maximum_response_bytes - 4096
           ->
           Protocol.failed
             ~request_id
             ~phase:Execute
             ~basis:(Some basis)
             (error Error.Response_too_large "The pending sync batch is too large.")
         | Ok payload ->
           let outgoing_ids =
             List.map (fun entry -> entry.Sync_pending.mutation_id) outgoing
           in
           let entries =
             List.map
               (fun (entry : Sync_pending.entry) ->
                  if List.exists (Graph_types.Uuid.equal entry.mutation_id) outgoing_ids
                  then { entry with state = Submitted }
                  else entry)
               entries
           in
           replace_pending_or_terminalize t pending entries;
           success
             { payload = Some payload; count = List.length entries; blocked_error = None }))
;;

let sync_reject_reason_text = function
  | Sync_protocol.Stale -> "stale"
  | Db_transact_failed -> "db transact failed"
  | Empty_tx_data -> "empty tx data"
  | Invalid_tx -> "invalid tx"
  | Invalid_t_before -> "invalid t-before"
  | Snapshot_upload_in_progress -> "snapshot upload in progress"
;;

let sync_reject_server_reason reason data =
  match data with
  | Some detail when String.length detail > 0 ->
    Printf.sprintf "%s: %s" (sync_reject_reason_text reason) detail
  | Some _ | None -> sync_reject_reason_text reason
;;

let execute_sync_receive t request_id transport payload =
  let basis = t.graph_info.basis in
  let failed message =
    Protocol.failed
      ~request_id
      ~phase:Execute
      ~basis:(Some basis)
      (error Error.Invalid_request message)
  in
  match t.sync_metadata with
  | None ->
    Protocol.failed
      ~request_id
      ~phase:Execute
      ~basis:(Some basis)
      (unsupported_semantics "The active graph is not a synced mirror.")
  | Some metadata ->
    let decoded =
      match transport with
      | Protocol.Websocket -> Sync_protocol.decode_server_message payload
      | Http_pull -> Sync_protocol.decode_http_pull_response payload
    in
    (match decoded with
     | Error message -> failed message
     | Ok (Sync_protocol.Pull_ok _ as message) ->
       require_ownership t "graph ownership changed before sync replay";
       (match
          Sync_replay.apply_pull
            ?decrypt_protected:
              (Option.map
                 (fun graph_key ~attribute:_ ciphertext ->
                    Sync_e2ee.decrypt_value ~crypto:t.crypto ~graph_key ciphertext)
                 t.graph_key)
            ~before_commit:(fun () ->
              match Ownership.revalidate t.owner with
              | Ok () -> Ok ()
              | Error _ -> Error "graph ownership changed before sync commit")
            ~session:t.session
            ~metadata
            message
        with
        | Error replay_error ->
          let message = Sync_replay.error_message replay_error in
          if Storage_session.is_fatal t.session
          then terminalize t message
          else failed message
        | Ok (Sync_replay.Applied applied) ->
          require_ownership t "graph ownership changed after sync replay";
          t.sync_metadata <- Some applied.metadata;
          rebase_pending t applied.metadata.applied_server_t;
          let changed_uuids = take Protocol.maximum_changed_uuids applied.changed_uuids in
          let mutation =
            Protocol.
              { status = Applied
              ; basis_before = basis
              ; basis_after = t.graph_info.basis
              ; changed_uuids
              ; changed_uuids_truncated =
                  List.length changed_uuids < List.length applied.changed_uuids
              }
          in
          Protocol.Succeeded
            { request_id
            ; basis = t.graph_info.basis
            ; success =
                Protocol.Sync_result
                  (protocol_sync_success Pull_applied (Some mutation) applied.metadata)
            }
        | Ok (Duplicate duplicate) ->
          t.sync_metadata <- Some duplicate.metadata;
          rebase_pending t duplicate.metadata.applied_server_t;
          Protocol.Succeeded
            { request_id
            ; basis = t.graph_info.basis
            ; success =
                Protocol.Sync_result
                  (protocol_sync_success Pull_duplicate None duplicate.metadata)
            }
        | Ok (Paused paused) ->
          t.sync_metadata <- Some paused.metadata;
          Protocol.Succeeded
            { request_id
            ; basis = paused.basis
            ; success =
                Protocol.Sync_result
                  (protocol_sync_success Sync_paused None paused.metadata)
            })
     | Ok (Hello { t = remote_t; _ } | Changed { t = remote_t }) ->
       let activity =
         if remote_t > metadata.applied_server_t
         then Protocol.Pull_required
         else Pull_duplicate
       in
       Protocol.Succeeded
         { request_id
         ; basis
         ; success = Protocol.Sync_result (protocol_sync_success activity None metadata)
         }
     | Ok (Tx_batch_ok { t = accepted_t; _ }) ->
       (match t.pending with
        | None -> failed "pending intent storage is unavailable"
        | Some pending ->
          let entries =
            List.map
              (fun (entry : Sync_pending.entry) ->
                 match entry.state with
                 | Submitted -> { entry with state = Accepted accepted_t }
                 | Queued | Accepted _ | Blocked _ -> entry)
              (Sync_pending.entries pending)
          in
          replace_pending_or_terminalize t pending entries;
          Protocol.Succeeded
            { request_id
            ; basis
            ; success =
                Protocol.Sync_result (protocol_sync_success Pull_required None metadata)
            })
     | Ok (Tx_reject { reason = Stale; _ }) ->
       (match t.pending with
        | None -> failed "pending intent storage is unavailable"
        | Some pending ->
          let entries =
            List.map
              (fun (entry : Sync_pending.entry) ->
                 match entry.state with
                 | Submitted -> { entry with state = Queued }
                 | Queued | Accepted _ | Blocked _ -> entry)
              (Sync_pending.entries pending)
          in
          replace_pending_or_terminalize t pending entries;
          Protocol.Succeeded
            { request_id
            ; basis
            ; success =
                Protocol.Sync_result (protocol_sync_success Pull_required None metadata)
            })
     | Ok
         (Tx_reject
            { reason = Db_transact_failed
            ; t = Some accepted_t
            ; success_tx_ids
            ; failed_tx_id
            ; data
            }) ->
       (match t.pending with
        | None -> failed "pending intent storage is unavailable"
        | Some pending ->
          let success_ids =
            List.filter_map
              (fun value -> Graph_types.Uuid.of_string value |> Result.to_option)
              success_tx_ids
          in
          let failed_id =
            Option.bind failed_tx_id (fun value ->
              Graph_types.Uuid.of_string value |> Result.to_option)
          in
          let message =
            Printf.sprintf
              "Sync transaction batch partially rejected; accepted tx IDs: [%s]; failed \
               tx ID: %s; server reason: %s"
              (String.concat ", " success_tx_ids)
              (Option.value ~default:"unknown" failed_tx_id)
              (sync_reject_server_reason Db_transact_failed data)
          in
          let entries =
            List.map
              (fun (entry : Sync_pending.entry) ->
                 if List.exists (Graph_types.Uuid.equal entry.mutation_id) success_ids
                 then { entry with state = Accepted accepted_t }
                 else if
                   match failed_id with
                   | Some failed_id -> Graph_types.Uuid.equal entry.mutation_id failed_id
                   | None -> false
                 then { entry with state = Blocked message }
                 else entry)
              (Sync_pending.entries pending)
          in
          replace_pending_or_terminalize t pending entries;
          Protocol.Succeeded
            { request_id
            ; basis
            ; success =
                Protocol.Sync_result
                  (protocol_sync_success
                     ~last_error:message
                     Sync_submission_blocked
                     None
                     metadata)
            })
     | Ok (Tx_reject { reason; data; _ }) ->
       (match t.pending with
        | None -> failed "pending intent storage is unavailable"
        | Some pending ->
          let message =
            Printf.sprintf
              "Sync service rejected the transaction (%s)%s"
              (sync_reject_reason_text reason)
              (match data with
               | Some detail when String.length detail > 0 -> ": " ^ detail
               | Some _ | None -> "")
          in
          let entries =
            List.map
              (fun (entry : Sync_pending.entry) ->
                 match entry.state with
                 | Submitted -> { entry with state = Blocked message }
                 | Queued | Accepted _ | Blocked _ -> entry)
              (Sync_pending.entries pending)
          in
          replace_pending_or_terminalize t pending entries;
          Protocol.Succeeded
            { request_id
            ; basis
            ; success =
                Protocol.Sync_result
                  (protocol_sync_success
                     ~last_error:message
                     Sync_submission_blocked
                     None
                     metadata)
            })
     | Ok (Server_error _ | Pong) ->
       failed "unsupported sync server message for this envelope")
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
  | Fatal message -> raise (Fatal_storage_error message)
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
        | Protocol.Read Protocol.Sync_status ->
          (match t.sync_metadata with
           | Some metadata ->
             Protocol.Succeeded
               { request_id = request.request_id
               ; basis
               ; success = Protocol.Sync_status_result (protocol_sync_status metadata)
               }
           | None ->
             failed_error
               (unsupported_semantics "The active graph is not a synced mirror."))
        | Protocol.Read Protocol.Sync_pending -> execute_sync_pending t request.request_id
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
        | Protocol.Sync_receive { transport; payload } ->
          execute_sync_receive t request.request_id transport payload
      in
      if Protocol.encoded_response_bytes response <= t.response_budget_bytes
      then response
      else
        failed Error.Response_too_large "The response exceeds the configured byte budget.")
;;

let close t =
  match t.lifecycle with
  | Closed -> Ok ()
  | Fatal message -> Error message
  | Ready ->
    (match Ownership.revalidate t.owner with
     | Error _ ->
       let message = "graph ownership changed before close" in
       ignore (Storage_session.close t.session);
       ignore (Ownership.release t.owner);
       t.lifecycle <- Fatal message;
       Error message
     | Ok () ->
       (match Storage_session.close t.session with
        | Error error ->
          let message = session_error_message error in
          ignore (Ownership.release t.owner);
          t.lifecycle <- Fatal message;
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
             t.lifecycle <- Fatal message;
             Error message
           | Ok () ->
             (match Ownership.release t.owner with
              | Error _ ->
                let message = "graph ownership release failed" in
                t.lifecycle <- Fatal message;
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
