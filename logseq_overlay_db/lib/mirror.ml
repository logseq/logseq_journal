module Graph = Logseq_db_types.Graph_types
module Storage = Logseq_db_storage.Logseq_sqlite_storage

type staged =
  { directory : string
  ; database_path : string
  ; database : Datascript.db
  ; schema : Graph.schema_version
  ; callbacks : Storage.callbacks
  ; mutable storage_closed : bool
  ; mutable activated : bool
  }

let directory staged = staged.directory
let database_path staged = staged.database_path
let database staged = staged.database
let schema staged = staged.schema
let plaintext_table = "overlay_snapshot_plaintexts"

let rec remove_tree path =
  match Unix.lstat path with
  | { st_kind = Unix.S_DIR; _ } ->
    Sys.readdir path |> Array.iter (fun name -> remove_tree (Filename.concat path name));
    Unix.rmdir path
  | _ -> Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
;;

let sqlite_result sqlite result =
  if Sqlite3.Rc.is_success result then Ok () else Error (Sqlite3.errmsg sqlite)
;;

let import_snapshot_rows ~snapshot_path ~expected_rows database_path =
  let sqlite = Sqlite3.db_open database_path in
  let rollback () = ignore (Sqlite3.exec sqlite "ROLLBACK") in
  let close () = ignore (Sqlite3.db_close sqlite) in
  let fail message =
    rollback ();
    close ();
    Error message
  in
  try
    Sqlite3.Rc.check (Sqlite3.exec sqlite "PRAGMA journal_mode=DELETE");
    Sqlite3.Rc.check (Sqlite3.exec sqlite "PRAGMA synchronous=FULL");
    Sqlite3.Rc.check
      (Sqlite3.exec
         sqlite
         "CREATE TABLE kvs (addr INTEGER PRIMARY KEY, content TEXT, addresses JSON)");
    Sqlite3.Rc.check (Sqlite3.exec sqlite "BEGIN IMMEDIATE");
    let statement =
      Sqlite3.prepare sqlite "INSERT INTO kvs(addr, content, addresses) VALUES(?, ?, ?)"
    in
    let parser = Snapshot_parser.create_parser ~max_frame_bytes:(64 * 1_024 * 1_024) in
    let import = Snapshot_parser.create_import ~expected_rows in
    let channel = open_in_bin snapshot_path in
    let buffer = Bytes.create 65_536 in
    let insert_row (row : Snapshot_parser.row) =
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
      | result -> Error (Sqlite3.Rc.to_string result)
    in
    let rec insert = function
      | [] -> Ok ()
      | row :: rest -> Result.bind (insert_row row) (fun () -> insert rest)
    in
    let rec read () =
      match input channel buffer 0 (Bytes.length buffer) with
      | 0 -> Ok ()
      | count ->
        Result.bind
          (Snapshot_parser.feed parser (Bytes.sub_string buffer 0 count))
          (fun rows ->
             Result.bind (Snapshot_parser.accept_rows import rows) (fun () ->
               Result.bind (insert rows) read))
    in
    let imported =
      Fun.protect
        ~finally:(fun () ->
          close_in_noerr channel;
          ignore (Sqlite3.finalize statement))
        (fun () ->
           Result.bind (read ()) (fun () ->
             Result.bind (Snapshot_parser.finish parser) (fun () ->
               Result.map (fun _ -> ()) (Snapshot_parser.finish_import import))))
    in
    match imported with
    | Error message -> fail message
    | Ok () ->
      (match sqlite_result sqlite (Sqlite3.exec sqlite "COMMIT") with
       | Error message -> fail message
       | Ok () ->
         close ();
         Ok ())
  with
  | exn -> fail (Printexc.to_string exn)
;;

let inspect_database database_path graph_id =
  match Storage.open_database database_path with
  | Error _ -> Error "snapshot SQLite storage cannot be opened"
  | Ok connection ->
    let callbacks = Storage.connection_callbacks connection in
    (match Storage.startup_metadata connection, Storage.restore_database connection with
     | Ok startup, Ok database ->
       (match
          Logseq_db_storage.Admission.inspect
            ~target:(Synced_target graph_id)
            ~db:database
            ~storage_schema:startup.schema
        with
        | Ok admitted -> Ok (database, admitted.schema, callbacks)
        | Error _ ->
          ignore (Storage.close callbacks);
          Error "snapshot graph admission failed")
     | Error _, _ | _, Error _ ->
       ignore (Storage.close callbacks);
       Error "snapshot SQLite storage is corrupt")
;;

let stage ~root ~graph_id ~snapshot_path ~expected_rows =
  let directory = Filename.temp_file ~temp_dir:root ".stage-" "" in
  Sys.remove directory;
  Unix.mkdir directory 0o700;
  let database_path = Filename.concat directory "db.sqlite" in
  let cleanup message =
    remove_tree directory;
    Error message
  in
  match import_snapshot_rows ~snapshot_path ~expected_rows database_path with
  | Error message -> cleanup message
  | Ok () ->
    (match inspect_database database_path graph_id with
     | Error message -> cleanup message
     | Ok (database, schema, callbacks) ->
       Ok
         { directory
         ; database_path
         ; database
         ; schema
         ; callbacks
         ; storage_closed = false
         ; activated = false
         })
;;

let close_storage staged =
  if staged.storage_closed
  then Ok ()
  else (
    match Storage.close staged.callbacks with
    | Ok () ->
      staged.storage_closed <- true;
      Ok ()
    | Error _ -> Error "snapshot storage cannot be closed")
;;

let initialize_plaintext_table sqlite =
  sqlite_result
    sqlite
    (Sqlite3.exec
       sqlite
       ("CREATE TABLE IF NOT EXISTS "
        ^ plaintext_table
        ^ " (entity INTEGER NOT NULL, attribute TEXT NOT NULL, tx INTEGER NOT NULL, "
        ^ "ciphertext TEXT NOT NULL, plaintext TEXT NOT NULL, "
        ^ "PRIMARY KEY(entity, attribute, tx, ciphertext))"))
;;

let stage_plaintexts staged replacements =
  let sqlite = Sqlite3.db_open ~mode:`NO_CREATE staged.database_path in
  Fun.protect
    ~finally:(fun () -> ignore (Sqlite3.db_close sqlite))
    (fun () ->
       Result.bind (initialize_plaintext_table sqlite) (fun () ->
         Result.bind
           (sqlite_result sqlite (Sqlite3.exec sqlite "BEGIN IMMEDIATE"))
           (fun () ->
              let statement =
                Sqlite3.prepare
                  sqlite
                  ("INSERT INTO "
                   ^ plaintext_table
                   ^ "(entity, attribute, tx, ciphertext, plaintext) VALUES(?, ?, ?, ?, \
                      ?)")
              in
              let rollback message =
                ignore (Sqlite3.exec sqlite "ROLLBACK");
                Error message
              in
              Fun.protect
                ~finally:(fun () -> ignore (Sqlite3.finalize statement))
                (fun () ->
                   let rec insert = function
                     | [] ->
                       (match sqlite_result sqlite (Sqlite3.exec sqlite "COMMIT") with
                        | Ok () -> Ok ()
                        | Error message -> rollback message)
                     | (datom, plaintext) :: rest ->
                       (match datom.Datascript.v with
                        | Datascript.String ciphertext ->
                          (try
                             Sqlite3.Rc.check (Sqlite3.reset statement);
                             Sqlite3.Rc.check (Sqlite3.bind_int statement 1 datom.e);
                             Sqlite3.Rc.check (Sqlite3.bind_text statement 2 datom.a);
                             Sqlite3.Rc.check (Sqlite3.bind_int statement 3 datom.tx);
                             Sqlite3.Rc.check (Sqlite3.bind_text statement 4 ciphertext);
                             Sqlite3.Rc.check (Sqlite3.bind_text statement 5 plaintext);
                             match sqlite_result sqlite (Sqlite3.step statement) with
                             | Ok () -> insert rest
                             | Error message -> rollback message
                           with
                           | exn -> rollback (Printexc.to_string exn))
                        | _ -> rollback "snapshot plaintext target is not a string")
                   in
                   insert replacements))))
;;

let apply_staged_plaintexts staged =
  let sqlite = Sqlite3.db_open ~mode:`NO_CREATE staged.database_path in
  Fun.protect
    ~finally:(fun () -> ignore (Sqlite3.db_close sqlite))
    (fun () ->
       Result.bind (initialize_plaintext_table sqlite) (fun () ->
         let statement =
           Sqlite3.prepare
             sqlite
             ("SELECT plaintext FROM "
              ^ plaintext_table
              ^ " WHERE entity = ? AND attribute = ? AND tx = ? AND ciphertext = ?")
         in
         let rebuilt =
           Fun.protect
             ~finally:(fun () -> ignore (Sqlite3.finalize statement))
             (fun () ->
                try
                  let replace datom =
                    match datom.Datascript.v with
                    | Datascript.String ciphertext
                      when String.equal datom.a "block/title"
                           || String.equal datom.a "block/name" ->
                      Sqlite3.Rc.check (Sqlite3.reset statement);
                      Sqlite3.Rc.check (Sqlite3.bind_int statement 1 datom.e);
                      Sqlite3.Rc.check (Sqlite3.bind_text statement 2 datom.a);
                      Sqlite3.Rc.check (Sqlite3.bind_int statement 3 datom.tx);
                      Sqlite3.Rc.check (Sqlite3.bind_text statement 4 ciphertext);
                      (match Sqlite3.step statement with
                       | Sqlite3.Rc.ROW ->
                         Ok
                           { datom with
                             Datascript.v =
                               Datascript.String (Sqlite3.column_text statement 0)
                           }
                       | DONE -> Error "snapshot plaintext batch is incomplete"
                       | result -> Error (Sqlite3.Rc.to_string result))
                    | _ -> Ok datom
                  in
                  let rec collect reversed sequence =
                    match sequence () with
                    | Seq.Nil -> Ok (List.rev reversed)
                    | Seq.Cons (datom, rest) ->
                      Result.bind (replace datom) (fun datom ->
                        collect (datom :: reversed) rest)
                  in
                  Result.map
                    (Datascript.init_db ~schema:staged.database.schema)
                    (collect [] (Datascript.datoms staged.database Datascript.Eavt ()))
                with
                | exn -> Error (Printexc.to_string exn))
         in
         Result.bind rebuilt (fun database ->
           Result.map
             (fun () -> database)
             (sqlite_result
                sqlite
                (Sqlite3.exec sqlite ("DROP TABLE " ^ plaintext_table))))))
;;

let initialize_ledgers path metadata =
  let sqlite = Sqlite3.db_open ~mode:`NO_CREATE path in
  Fun.protect
    ~finally:(fun () -> ignore (Sqlite3.db_close sqlite))
    (fun () ->
       Result.bind
         (Logseq_db_storage.Sync_checkpoint_store.initialize_database sqlite metadata)
         (fun () ->
            Result.bind
              (Logseq_db_storage.Sync_outbox_store.initialize_database sqlite)
              (fun () ->
                 Logseq_db_storage.Mutation_receipt_store.initialize_database sqlite)))
;;

let persist_database staged database metadata =
  let callbacks = staged.callbacks in
  if staged.storage_closed
  then Error "snapshot storage is already closed"
  else (
    match callbacks.begin_staging () with
    | Error message -> Error message
    | Ok () ->
      (try
         Datascript.store ~storage:callbacks.storage database;
         match callbacks.finish_staging None [] with
         | Error message ->
           callbacks.abort_staging ();
           Error message
         | Ok batch ->
           (match Storage.commit_batch callbacks batch with
            | Error _ -> Error "snapshot database commit failed"
            | Ok () ->
              (match Storage.commit_sync_metadata callbacks metadata with
               | Error _ -> Error "snapshot metadata commit failed"
               | Ok () -> Ok ()))
       with
       | exn ->
         callbacks.abort_staging ();
         Error (Printexc.to_string exn)))
;;

let persist staged database metadata =
  Result.bind (initialize_ledgers staged.database_path metadata) (fun () ->
    persist_database staged database metadata)
;;

let activate staged ~active_directory =
  if staged.activated
  then Error "snapshot staging artifact is already activated"
  else if Sys.file_exists active_directory
  then Error "active mirror already exists"
  else
    Result.bind (close_storage staged) (fun () ->
      try
        Unix.rename staged.directory active_directory;
        staged.activated <- true;
        Ok ()
      with
      | exn -> Error (Printexc.to_string exn))
;;

let cancel staged =
  ignore (close_storage staged);
  if not staged.activated then remove_tree staged.directory
;;
