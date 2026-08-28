let rc_result db rc =
  if Sqlite3.Rc.is_success rc then Ok () else Error (Sqlite3.errmsg db)
;;

let initialize_database db =
  rc_result
    db
    (Sqlite3.exec
       db
       "CREATE TABLE IF NOT EXISTS sync_outbox (position INTEGER PRIMARY KEY, record \
        TEXT NOT NULL)")
;;

let read_database db =
  try
    let records = ref [] in
    let result =
      Sqlite3.exec db "SELECT record FROM sync_outbox ORDER BY position" ~cb:(fun row _ ->
        match row.(0) with
        | Some record -> records := record :: !records
        | None -> ())
    in
    Result.map (fun () -> List.rev !records) (rc_result db result)
  with
  | exn -> Error (Printexc.to_string exn)
;;

let replace_database db records =
  match rc_result db (Sqlite3.exec db "DELETE FROM sync_outbox") with
  | Error _ as error -> error
  | Ok () ->
    let statement =
      Sqlite3.prepare db "INSERT INTO sync_outbox(position, record) VALUES(?, ?)"
    in
    Fun.protect
      ~finally:(fun () -> ignore (Sqlite3.finalize statement))
      (fun () ->
         let rec insert position = function
           | [] -> Ok ()
           | record :: rest ->
             Sqlite3.Rc.check (Sqlite3.reset statement);
             Sqlite3.Rc.check (Sqlite3.bind_int statement 1 position);
             Sqlite3.Rc.check (Sqlite3.bind_text statement 2 record);
             (match rc_result db (Sqlite3.step statement) with
              | Error _ as error -> error
              | Ok () -> insert (position + 1) rest)
         in
         try insert 0 records with
         | exn -> Error (Printexc.to_string exn))
;;
