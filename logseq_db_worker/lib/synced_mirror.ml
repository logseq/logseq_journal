module Core = Logseq_sync_pure_reducer.Core
module Snapshot = Synced_snapshot_parser
module Admission = Logseq_db_storage.Admission

let protected_attributes = [ "block/title"; "block/name" ]

type metadata = Sync_checkpoint.t

type resolved =
  { graph_dir : string
  ; database_path : string
  ; metadata : metadata
  }

type error =
  | Invalid_root
  | Mirror_missing
  | Mirror_exists
  | Invalid_snapshot of string
  | Invalid_metadata of string
  | Admission_failed of Admission.error
  | Activation_failed of string
  | Deletion_failed of string

let bind result f =
  match result with
  | Ok value -> f value
  | Error _ as error -> error
;;

let error_message = function
  | Invalid_root -> "the synced mirror root is invalid"
  | Mirror_missing -> "the synced mirror does not exist"
  | Mirror_exists -> "the synced mirror already exists"
  | Invalid_snapshot message -> "invalid synced snapshot: " ^ message
  | Invalid_metadata message -> "invalid sync metadata: " ^ message
  | Admission_failed Admission.Unsupported_schema ->
    "the synced graph schema is unsupported"
  | Admission_failed Remote_graph -> "the synced graph has an invalid remote flag"
  | Admission_failed Ambiguous_sync_state -> "the synced graph identity is ambiguous"
  | Admission_failed Unsupported_value -> "the synced graph contains an unsupported value"
  | Admission_failed Corrupt_storage -> "the synced graph storage is corrupt"
  | Activation_failed message -> "unable to activate synced mirror: " ^ message
  | Deletion_failed message -> "unable to delete synced mirror: " ^ message
;;

let worker_root application_support_directory =
  Filename.concat application_support_directory "logseq-db-worker"
;;

let mirror_root application_support_directory =
  Filename.concat (worker_root application_support_directory) "synced-graphs"
;;

let graph_directory ~application_support_directory ~graph_id =
  Filename.concat
    (mirror_root application_support_directory)
    (Graph_types.Uuid.to_string graph_id)
;;

let is_directory path =
  try (Unix.lstat path).Unix.st_kind = Unix.S_DIR with
  | Unix.Unix_error _ -> false
;;

let is_regular path =
  try
    let stat = Unix.lstat path in
    stat.st_kind = Unix.S_REG && stat.st_nlink = 1
  with
  | Unix.Unix_error _ -> false
;;

let ensure_directory path =
  if Sys.file_exists path
  then is_directory path
  else (
    try
      Unix.mkdir path 0o700;
      true
    with
    | Unix.Unix_error _ -> false)
;;

let ensure_root application_support_directory =
  if
    Filename.is_relative application_support_directory
    || not (is_directory application_support_directory)
  then Error Invalid_root
  else (
    let worker = worker_root application_support_directory in
    let root = mirror_root application_support_directory in
    if ensure_directory worker && ensure_directory root
    then Ok root
    else Error Invalid_root)
;;

let resolve ~application_support_directory ~graph_id =
  match ensure_root application_support_directory with
  | Error _ as error -> error
  | Ok _ ->
    let graph_dir = graph_directory ~application_support_directory ~graph_id in
    let database_path = Filename.concat graph_dir "db.sqlite" in
    if not (is_directory graph_dir && is_regular database_path)
    then Error Mirror_missing
    else (
      match Sync_checkpoint_store.read_path database_path with
      | Error message -> Error (Invalid_metadata message)
      | Ok metadata ->
        if Graph_types.Uuid.equal metadata.graph_id graph_id
        then Ok { graph_dir; database_path; metadata }
        else Error (Invalid_metadata "graph id does not match the mirror directory"))
;;

let rec remove_tree path =
  match Unix.lstat path with
  | { st_kind = Unix.S_DIR; _ } ->
    Sys.readdir path |> Array.iter (fun name -> remove_tree (Filename.concat path name));
    Unix.rmdir path
  | _ -> Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
;;

let delete ~application_support_directory ~graph_id =
  match ensure_root application_support_directory with
  | Error _ as error -> error
  | Ok root ->
    let graph_dir = graph_directory ~application_support_directory ~graph_id in
    if not (Sys.file_exists graph_dir)
    then Ok ()
    else if not (is_directory graph_dir)
    then Error (Deletion_failed "mirror path is not a directory")
    else (
      try
        remove_tree graph_dir;
        let fd = Unix.openfile root [ Unix.O_RDONLY ] 0 in
        Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> Unix.fsync fd);
        Ok ()
      with
      | exception_ -> Error (Deletion_failed (Printexc.to_string exception_)))
;;

let rc_result db rc =
  if Sqlite3.Rc.is_success rc then Ok () else Error (Sqlite3.errmsg db)
;;

let insert_row statement (row : Snapshot.row) =
  Sqlite3.Rc.check (Sqlite3.reset statement);
  Sqlite3.Rc.check (Sqlite3.bind_int statement 1 row.addr);
  Sqlite3.Rc.check (Sqlite3.bind_text statement 2 row.content);
  Sqlite3.Rc.check
    (Sqlite3.bind
       statement
       3
       (match row.addresses with
        | None -> Sqlite3.Data.NULL
        | Some addresses -> TEXT addresses));
  match Sqlite3.step statement with
  | Sqlite3.Rc.DONE -> Ok ()
  | rc -> Error (Sqlite3.Rc.to_string rc)
;;

let import_snapshot_rows database_path snapshot_path expected_rows =
  if not (is_regular snapshot_path)
  then Error (Invalid_snapshot "snapshot file is missing or unsafe")
  else (
    let db = Sqlite3.db_open database_path in
    let rollback () = ignore (Sqlite3.exec db "ROLLBACK") in
    let close () = ignore (Sqlite3.db_close db) in
    let fail message =
      rollback ();
      close ();
      Error (Invalid_snapshot message)
    in
    try
      Sqlite3.Rc.check (Sqlite3.exec db "PRAGMA journal_mode=DELETE");
      Sqlite3.Rc.check (Sqlite3.exec db "PRAGMA synchronous=FULL");
      Sqlite3.Rc.check
        (Sqlite3.exec
           db
           "CREATE TABLE kvs (addr INTEGER PRIMARY KEY, content TEXT, addresses JSON)");
      Sqlite3.Rc.check (Sqlite3.exec db "BEGIN IMMEDIATE");
      let statement =
        Sqlite3.prepare db "INSERT INTO kvs(addr, content, addresses) VALUES(?, ?, ?)"
      in
      let parser = Snapshot.create_parser ~max_frame_bytes:(64 * 1024 * 1024) in
      let state = Snapshot.create_import ~expected_rows in
      let channel = open_in_bin snapshot_path in
      let buffer = Bytes.create 65_536 in
      let rec read () =
        match input channel buffer 0 (Bytes.length buffer) with
        | 0 -> Ok ()
        | count ->
          (match Snapshot.feed parser (Bytes.sub_string buffer 0 count) with
           | Error message -> Error message
           | Ok rows ->
             (match Snapshot.accept_rows state rows with
              | Error _ as error -> error
              | Ok () ->
                let rec insert = function
                  | [] -> read ()
                  | row :: rest ->
                    (match insert_row statement row with
                     | Error _ as error -> error
                     | Ok () -> insert rest)
                in
                insert rows))
      in
      let imported =
        Fun.protect
          ~finally:(fun () ->
            close_in_noerr channel;
            ignore (Sqlite3.finalize statement))
          (fun () ->
             match read () with
             | Error _ as error -> error
             | Ok () ->
               (match Snapshot.finish parser with
                | Error _ as error -> error
                | Ok () -> Snapshot.finish_import state |> Result.map (fun _ -> ())))
      in
      match imported with
      | Error message -> fail message
      | Ok () ->
        (match rc_result db (Sqlite3.exec db "COMMIT") with
         | Error message -> fail message
         | Ok () ->
           close ();
           Ok ())
    with
    | exn -> fail (Printexc.to_string exn))
;;

let plaintext_snapshot_db decrypt db =
  let rec loop datoms = function
    | [] ->
      (try Ok (Datascript.init_db ~schema:db.Datascript.schema (List.rev datoms)) with
       | error -> Error (Printexc.to_string error))
    | datom :: rest when List.mem datom.Datascript.a protected_attributes ->
      (match datom.v with
       | Datascript.String ciphertext ->
         (match decrypt ciphertext with
          | Ok plaintext ->
            loop
              ({ datom with Datascript.v = Datascript.String plaintext } :: datoms)
              rest
          | Error _ -> Error "protected snapshot value could not be decrypted")
       | _ -> Error "protected snapshot attributes must contain encrypted strings")
    | datom :: rest -> loop (datom :: datoms) rest
  in
  loop [] (Datascript.datoms db Datascript.Eavt () |> List.of_seq)
;;

let materialize_plaintext_snapshot database_path decrypt =
  match Logseq_sqlite_storage.open_database database_path with
  | Error _ -> Error (Invalid_snapshot "encrypted snapshot could not be reopened")
  | Ok connection ->
    let callbacks = Logseq_sqlite_storage.connection_callbacks connection in
    let finish result =
      match Logseq_sqlite_storage.close callbacks, result with
      | Ok (), result -> result
      | Error _, Ok () -> Error (Invalid_snapshot "plaintext snapshot could not close")
      | Error _, (Error _ as error) -> error
    in
    (match Logseq_sqlite_storage.restore_database connection with
     | Error _ -> finish (Error (Invalid_snapshot "encrypted snapshot could not restore"))
     | Ok encrypted_db ->
       (match plaintext_snapshot_db decrypt encrypted_db with
        | Error message -> finish (Error (Invalid_snapshot message))
        | Ok plaintext_db ->
          (match callbacks.begin_staging () with
           | Error _ -> finish (Error (Invalid_snapshot "plaintext staging failed"))
           | Ok () ->
             (try
                let storage = Logseq_sqlite_storage.datascript_storage connection in
                Datascript.store ~storage plaintext_db;
                match callbacks.finish_staging None [] with
                | Error _ ->
                  callbacks.abort_staging ();
                  finish (Error (Invalid_snapshot "plaintext staging failed"))
                | Ok batch ->
                  (match Logseq_sqlite_storage.commit_batch callbacks batch with
                   | Error _ ->
                     finish (Error (Invalid_snapshot "plaintext snapshot commit failed"))
                   | Ok () ->
                     (match Logseq_sqlite_storage.collect_garbage callbacks with
                      | Error _ ->
                        finish (Error (Invalid_snapshot "plaintext snapshot GC failed"))
                      | Ok () -> finish (Ok ())))
              with
              | _ ->
                callbacks.abort_staging ();
                finish (Error (Invalid_snapshot "plaintext snapshot could not persist"))))))
;;

let import_snapshot ?decrypt_protected database_path snapshot_path expected_rows =
  match import_snapshot_rows database_path snapshot_path expected_rows with
  | Error _ as error -> error
  | Ok () ->
    (match decrypt_protected with
     | None -> Ok ()
     | Some decrypt -> materialize_plaintext_snapshot database_path decrypt)
;;

let inspect_staged_schema database_path graph_id =
  match Logseq_sqlite_storage.open_database database_path with
  | Error _ -> Error (Invalid_snapshot "staged SQLite graph could not be opened")
  | Ok connection ->
    let callbacks = Logseq_sqlite_storage.connection_callbacks connection in
    let finish result =
      match Logseq_sqlite_storage.close callbacks, result with
      | Ok (), result -> result
      | Error _, Ok _ -> Error (Invalid_snapshot "staged SQLite graph could not close")
      | Error _, (Error _ as error) -> error
    in
    (match
       ( Logseq_sqlite_storage.startup_metadata connection
       , Logseq_sqlite_storage.restore_database connection )
     with
     | Ok startup, Ok db ->
       (match
          Admission.inspect
            ~target:(Synced_target graph_id)
            ~db
            ~storage_schema:startup.schema
        with
        | Ok admitted -> finish (Ok admitted.schema)
        | Error admission -> finish (Error (Admission_failed admission)))
     | Error _, _ | _, Error _ ->
       finish (Error (Invalid_snapshot "staged graph storage is corrupt")))
;;

let initialize_metadata database_path metadata =
  let db = Sqlite3.db_open database_path in
  let close result =
    if Sqlite3.db_close db
    then result
    else Error (Invalid_metadata "database did not close")
  in
  try
    Sqlite3.Rc.check (Sqlite3.exec db "BEGIN IMMEDIATE");
    match Sync_checkpoint_store.initialize_database db metadata with
    | Error message ->
      ignore (Sqlite3.exec db "ROLLBACK");
      close (Error (Invalid_metadata message))
    | Ok () ->
      (match rc_result db (Sqlite3.exec db "COMMIT") with
       | Ok () -> close (Ok ())
       | Error message ->
         ignore (Sqlite3.exec db "ROLLBACK");
         close (Error (Invalid_metadata message)))
  with
  | exn ->
    ignore (Sqlite3.exec db "ROLLBACK");
    close (Error (Invalid_metadata (Printexc.to_string exn)))
;;

let validate_staged database_path metadata =
  match Logseq_sqlite_storage.open_database database_path with
  | Error _ -> Error (Invalid_snapshot "staged SQLite graph could not be opened")
  | Ok connection ->
    let callbacks = Logseq_sqlite_storage.connection_callbacks connection in
    let close () = ignore (Logseq_sqlite_storage.close callbacks) in
    let fail error =
      close ();
      Error error
    in
    (match
       ( Logseq_sqlite_storage.startup_metadata connection
       , Logseq_sqlite_storage.restore_database connection
       , Logseq_sqlite_storage.sync_metadata connection )
     with
     | Ok startup, Ok db, Ok actual_metadata when actual_metadata = metadata ->
       (match
          Admission.inspect
            ~target:(Synced_target metadata.graph_id)
            ~db
            ~storage_schema:startup.schema
        with
        | Error admission -> fail (Admission_failed admission)
        | Ok admitted ->
          if admitted.schema <> metadata.schema
          then fail (Invalid_metadata "schema does not match the staged graph")
          else (
            match Logseq_sqlite_storage.checkpoint callbacks with
            | Error _ -> fail (Invalid_snapshot "staged SQLite checkpoint failed")
            | Ok () ->
              (match Logseq_sqlite_storage.close callbacks with
               | Error _ -> Error (Invalid_snapshot "staged SQLite close failed")
               | Ok () -> Ok ())))
     | Error _, _, _ | _, Error _, _ | _, _, Error _ | Ok _, Ok _, Ok _ ->
       fail (Invalid_snapshot "staged graph storage is corrupt"))
;;

let finalize_computed_checksum
      ?expected_checksum
      database_path
      (metadata : Sync_checkpoint.t)
  =
  match Logseq_sqlite_storage.open_database database_path with
  | Error _ -> Error (Invalid_snapshot "staged SQLite graph could not be reopened")
  | Ok connection ->
    let callbacks = Logseq_sqlite_storage.connection_callbacks connection in
    let finish result =
      match Logseq_sqlite_storage.close callbacks, result with
      | Ok (), result -> result
      | Error _, Ok _ -> Error (Invalid_snapshot "staged SQLite graph could not close")
      | Error _, (Error _ as error) -> error
    in
    (match Logseq_sqlite_storage.restore_database connection with
     | Error _ -> finish (Error (Invalid_snapshot "staged graph could not restore"))
     | Ok db ->
       let checksum = Core.recompute_checksum db in
       if
         match expected_checksum with
         | Some expected -> not (String.equal expected checksum)
         | None -> false
       then finish (Error (Invalid_snapshot "snapshot checksum does not match metadata"))
       else (
         match
           Sync_checkpoint.create_full
             ~graph_id:metadata.graph_id
             ~schema:metadata.schema
             ~applied_server_t:metadata.applied_server_t
             ~checksum
             ~status:Sync_checkpoint.Active
             ~last_error:None
         with
         | Error message -> finish (Error (Invalid_metadata message))
         | Ok metadata ->
           (match Logseq_sqlite_storage.commit_sync_metadata callbacks metadata with
            | Error _ ->
              finish (Error (Invalid_snapshot "computed checksum could not persist"))
            | Ok () -> finish (Ok metadata))))
;;

let fsync_file path =
  let fd = Unix.openfile path [ Unix.O_RDONLY ] 0 in
  Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> Unix.fsync fd)
;;

let fsync_directory path =
  let fd = Unix.openfile path [ Unix.O_RDONLY ] 0 in
  Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> Unix.fsync fd)
;;

let bootstrap
      ~application_support_directory
      ~graph_id
      ~applied_server_t
      ?checksum
      ~expected_rows
      ~snapshot_path
      ?decrypt_protected
      ()
  =
  let initial_checksum = Option.value checksum ~default:"0000000000000000" in
  match ensure_root application_support_directory with
  | Error _ as error -> error
  | Ok root ->
    let active = graph_directory ~application_support_directory ~graph_id in
    if Sys.file_exists active
    then Error Mirror_exists
    else (
      let temporary = Filename.temp_file ~temp_dir:root ".stage-" "" in
      Sys.remove temporary;
      Unix.mkdir temporary 0o700;
      let database_path = Filename.concat temporary "db.sqlite" in
      let cleanup () = remove_tree temporary in
      let fail error =
        cleanup ();
        error
      in
      let activated = ref false in
      let cleanup_failed_activation () =
        if !activated then remove_tree active else cleanup ()
      in
      let staged =
        bind
          (import_snapshot ?decrypt_protected database_path snapshot_path expected_rows)
          (fun () ->
             bind (inspect_staged_schema database_path graph_id) (fun schema ->
               let initial_metadata =
                 match
                   Sync_checkpoint.create
                     ~graph_id
                     ~schema
                     ~applied_server_t
                     ~checksum:initial_checksum
                 with
                 | Ok metadata -> Ok metadata
                 | Error message -> Error (Invalid_metadata message)
               in
               bind initial_metadata (fun initial_metadata ->
                 bind (initialize_metadata database_path initial_metadata) (fun () ->
                   bind
                     (finalize_computed_checksum
                        ?expected_checksum:checksum
                        database_path
                        initial_metadata)
                     (fun metadata ->
                        bind (validate_staged database_path metadata) (fun () ->
                          Ok metadata))))))
      in
      match staged with
      | Error _ as error -> fail error
      | Ok _ ->
        (try
           fsync_file database_path;
           fsync_directory temporary;
           Unix.rename temporary active;
           activated := true;
           fsync_directory root;
           match resolve ~application_support_directory ~graph_id with
           | Ok _ as resolved -> resolved
           | Error _ as error ->
             cleanup_failed_activation ();
             error
         with
         | exn ->
           cleanup_failed_activation ();
           Error (Activation_failed (Printexc.to_string exn))))
;;
