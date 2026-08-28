open Logseq_db_types

let rc_result db rc =
  if Sqlite3.Rc.is_success rc then Ok () else Error (Sqlite3.errmsg db)
;;

let initialize_database db checkpoint =
  let create_sql =
    "CREATE TABLE sync_meta(singleton INTEGER PRIMARY KEY CHECK(singleton = \
     1),format_version INTEGER NOT NULL CHECK(format_version = 2),graph_id TEXT NOT \
     NULL,schema_major INTEGER NOT NULL CHECK(schema_major >= 0),schema_minor INTEGER \
     NOT NULL CHECK(schema_minor >= 0),applied_server_t INTEGER NOT NULL \
     CHECK(applied_server_t >= 0),checksum TEXT NOT NULL,status TEXT NOT NULL \
     CHECK(status IN ('active','paused')),last_error TEXT, CHECK((status = 'active' AND \
     last_error IS NULL) OR (status = 'paused' AND last_error IS NOT NULL AND \
     length(last_error) > 0)))"
  in
  match rc_result db (Sqlite3.exec db create_sql) with
  | Error _ as error -> error
  | Ok () ->
    let statement =
      Sqlite3.prepare
        db
        "INSERT INTO sync_meta(singleton, format_version, graph_id, schema_major, \
         schema_minor, applied_server_t, checksum, status, last_error) VALUES(1, ?, ?, \
         ?, ?, ?, ?, ?, ?)"
    in
    Fun.protect
      ~finally:(fun () -> ignore (Sqlite3.finalize statement))
      (fun () ->
         Sqlite3.Rc.check
           (Sqlite3.bind_int statement 1 checkpoint.Sync_checkpoint.format_version);
         Sqlite3.Rc.check
           (Sqlite3.bind_text
              statement
              2
              (Graph_types.Uuid.to_string checkpoint.graph_id));
         Sqlite3.Rc.check (Sqlite3.bind_int statement 3 checkpoint.schema.major);
         Sqlite3.Rc.check (Sqlite3.bind_int statement 4 checkpoint.schema.minor);
         Sqlite3.Rc.check (Sqlite3.bind_int statement 5 checkpoint.applied_server_t);
         Sqlite3.Rc.check (Sqlite3.bind_text statement 6 checkpoint.checksum);
         Sqlite3.Rc.check
           (Sqlite3.bind_text
              statement
              7
              (match checkpoint.status with
               | Sync_checkpoint.Active -> "active"
               | Sync_checkpoint.Paused -> "paused"));
         Sqlite3.Rc.check
           (Sqlite3.bind
              statement
              8
              (match checkpoint.last_error with
               | None -> Sqlite3.Data.NULL
               | Some value -> TEXT value));
         rc_result db (Sqlite3.step statement))
;;

let expected_columns =
  [ Some "singleton", Some "INTEGER", Some "0", Some "1"
  ; Some "format_version", Some "INTEGER", Some "1", Some "0"
  ; Some "graph_id", Some "TEXT", Some "1", Some "0"
  ; Some "schema_major", Some "INTEGER", Some "1", Some "0"
  ; Some "schema_minor", Some "INTEGER", Some "1", Some "0"
  ; Some "applied_server_t", Some "INTEGER", Some "1", Some "0"
  ; Some "checksum", Some "TEXT", Some "1", Some "0"
  ; Some "status", Some "TEXT", Some "1", Some "0"
  ; Some "last_error", Some "TEXT", Some "0", Some "0"
  ]
;;

let table_contract db =
  let columns = ref [] in
  match
    rc_result
      db
      (Sqlite3.exec db "PRAGMA table_info(sync_meta)" ~cb:(fun row _ ->
         if Array.length row >= 6
         then columns := (row.(1), row.(2), row.(3), row.(5)) :: !columns))
  with
  | Error _ as error -> error
  | Ok () ->
    if List.rev !columns = expected_columns
    then Ok ()
    else Error "unexpected sync_meta table contract"
;;

let read_database db =
  match table_contract db with
  | Error _ as error -> error
  | Ok () ->
    let statement =
      Sqlite3.prepare
        db
        "SELECT format_version, graph_id, schema_major, schema_minor, applied_server_t, \
         checksum, status, last_error FROM sync_meta WHERE singleton = 1"
    in
    Fun.protect
      ~finally:(fun () -> ignore (Sqlite3.finalize statement))
      (fun () ->
         match Sqlite3.step statement with
         | Sqlite3.Rc.ROW ->
           let version = Sqlite3.column_int statement 0 in
           let graph_id = Sqlite3.column_text statement 1 in
           let major = Sqlite3.column_int statement 2 in
           let minor = Sqlite3.column_int statement 3 in
           let applied_server_t = Sqlite3.column_int statement 4 in
           let checksum = Sqlite3.column_text statement 5 in
           let status =
             match Sqlite3.column statement 6 with
             | Sqlite3.Data.TEXT "active" -> Ok Sync_checkpoint.Active
             | TEXT "paused" -> Ok Sync_checkpoint.Paused
             | _ -> Error "sync_meta status is invalid"
           in
           let last_error =
             match Sqlite3.column statement 7 with
             | Sqlite3.Data.NULL -> Ok None
             | TEXT value -> Ok (Some value)
             | _ -> Error "sync_meta error is invalid"
           in
           if version <> Sync_checkpoint.format_version
           then Error "unsupported sync_meta format version"
           else (
             match Graph_types.Uuid.of_string graph_id with
             | Error _ -> Error "sync_meta graph id is invalid"
             | Ok graph_id ->
               (match status, last_error with
                | Error message, _ | _, Error message -> Error message
                | Ok status, Ok last_error ->
                  (match
                     Sync_checkpoint.create_full
                       ~graph_id
                       ~schema:Graph_types.{ major; minor }
                       ~applied_server_t
                       ~checksum
                       ~status
                       ~last_error
                   with
                   | Error _ as error -> error
                   | Ok checkpoint ->
                     (match Sqlite3.step statement with
                      | Sqlite3.Rc.DONE -> Ok checkpoint
                      | _ -> Error "sync_meta must contain exactly one row"))))
         | Sqlite3.Rc.DONE -> Error "sync_meta row is missing"
         | _ -> Error (Sqlite3.errmsg db))
;;

let update_database db checkpoint =
  try
    match table_contract db with
    | Error _ as error -> error
    | Ok () ->
      let statement =
        Sqlite3.prepare
          db
          "UPDATE sync_meta SET format_version = ?, graph_id = ?, schema_major = ?, \
           schema_minor = ?, applied_server_t = ?, checksum = ?, status = ?, last_error \
           = ? WHERE singleton = 1"
      in
      Fun.protect
        ~finally:(fun () -> ignore (Sqlite3.finalize statement))
        (fun () ->
           Sqlite3.Rc.check
             (Sqlite3.bind_int statement 1 checkpoint.Sync_checkpoint.format_version);
           Sqlite3.Rc.check
             (Sqlite3.bind_text
                statement
                2
                (Graph_types.Uuid.to_string checkpoint.graph_id));
           Sqlite3.Rc.check (Sqlite3.bind_int statement 3 checkpoint.schema.major);
           Sqlite3.Rc.check (Sqlite3.bind_int statement 4 checkpoint.schema.minor);
           Sqlite3.Rc.check (Sqlite3.bind_int statement 5 checkpoint.applied_server_t);
           Sqlite3.Rc.check (Sqlite3.bind_text statement 6 checkpoint.checksum);
           Sqlite3.Rc.check
             (Sqlite3.bind_text
                statement
                7
                (match checkpoint.status with
                 | Sync_checkpoint.Active -> "active"
                 | Sync_checkpoint.Paused -> "paused"));
           Sqlite3.Rc.check
             (Sqlite3.bind
                statement
                8
                (match checkpoint.last_error with
                 | None -> Sqlite3.Data.NULL
                 | Some value -> TEXT value));
           rc_result db (Sqlite3.step statement))
  with
  | exn -> Error (Printexc.to_string exn)
;;

let read_path path =
  try
    let db = Sqlite3.db_open ~mode:`READONLY path in
    Fun.protect
      ~finally:(fun () -> ignore (Sqlite3.db_close db))
      (fun () -> read_database db)
  with
  | exn -> Error (Printexc.to_string exn)
;;
