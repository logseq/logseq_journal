let rec remove_tree path =
  match Unix.lstat path with
  | { st_kind = Unix.S_DIR; _ } ->
    Sys.readdir path |> Array.iter (fun name -> remove_tree (Filename.concat path name));
    Unix.rmdir path
  | _ -> Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
;;

let import_snapshot_rows
      ~check_current
      ~maximum_frame_bytes
      ~scratch_bytes
      ~snapshot_path
      ~expected_rows
      database_path
  =
  let sqlite = Sqlite3.db_open database_path in
  let closed = ref false in
  let result =
    Fun.protect
      ~finally:(fun () ->
        ignore (Sqlite3.exec sqlite "ROLLBACK");
        closed := Sqlite3.db_close sqlite)
      (fun () ->
         try
           if scratch_bytes < 8192L
           then Error "Snapshot scratch bound"
           else (
             Sqlite3.Rc.check (Sqlite3.exec sqlite "PRAGMA page_size=4096");
             Sqlite3.Rc.check
               (Sqlite3.exec
                  sqlite
                  ("PRAGMA max_page_count="
                   ^ Int64.to_string (Int64.div scratch_bytes 4096L)));
             Sqlite3.Rc.check (Sqlite3.exec sqlite "PRAGMA journal_mode=DELETE");
             Sqlite3.Rc.check
               (Sqlite3.exec
                  sqlite
                  "CREATE TABLE kvs (addr INTEGER PRIMARY KEY, content TEXT, addresses \
                   JSON)");
             Sqlite3.Rc.check (Sqlite3.exec sqlite "BEGIN IMMEDIATE");
             let statement =
               Sqlite3.prepare
                 sqlite
                 "INSERT INTO kvs(addr, content, addresses) VALUES(?, ?, ?)"
             in
             let imported =
               Fun.protect
                 ~finally:(fun () -> ignore (Sqlite3.finalize statement))
                 (fun () ->
                    let channel = open_in_bin snapshot_path in
                    Fun.protect
                      ~finally:(fun () -> close_in_noerr channel)
                      (fun () ->
                         let parser =
                           Snapshot_parser.create_parser
                             ~max_frame_bytes:maximum_frame_bytes
                         in
                         let import = Snapshot_parser.create_import ~expected_rows in
                         let buffer = Bytes.create 65_536 in
                         let insert (row : Snapshot_parser.row) =
                           check_current ();
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
                           | Sqlite3.Rc.DONE -> ()
                           | _ -> failwith "Snapshot storage write failed"
                         in
                         let rec read () =
                           check_current ();
                           match input channel buffer 0 (Bytes.length buffer) with
                           | 0 ->
                             Result.bind (Snapshot_parser.finish parser) (fun () ->
                               Result.map
                                 (fun _ -> ())
                                 (Snapshot_parser.finish_import import))
                           | count ->
                             Result.bind
                               (Snapshot_parser.feed
                                  parser
                                  (Bytes.sub_string buffer 0 count))
                               (fun rows ->
                                  Result.bind
                                    (Snapshot_parser.accept_rows import rows)
                                    (fun () ->
                                       List.iter insert rows;
                                       read ()))
                         in
                         read ()))
             in
             Result.bind imported (fun () ->
               Sqlite3.Rc.check (Sqlite3.exec sqlite "COMMIT");
               if Int64.of_int (Unix.stat database_path).st_size > scratch_bytes
               then Error "Snapshot scratch bound"
               else Ok ()))
         with
         | Eio.Cancel.Cancelled _ as cancelled -> raise cancelled
         | _ -> Error "Snapshot framed storage import failed")
  in
  if !closed then result else Error "Snapshot verification SQLite close failed"
;;

let inspect
      ~verify
      ~check_current
      ~scratch_bytes
      ~maximum_frame_bytes
      ~directory
      ~encrypted
      ~path
      ~expected_rows
  =
  let scratch = Filename.concat directory "verify.sqlite" in
  Fun.protect
    ~finally:(fun () ->
      List.iter
        (fun suffix -> remove_tree (scratch ^ suffix))
        [ ""; "-journal"; "-wal"; "-shm" ])
    (fun () ->
       Result.bind
         (import_snapshot_rows
            ~check_current
            ~scratch_bytes
            ~maximum_frame_bytes
            ~snapshot_path:path
            ~expected_rows
            scratch)
         (fun () -> verify ~check_current ~scratch_bytes ~encrypted ~path:scratch))
;;
