type t =
  { database : Sqlite3.db
  ; mutable released : bool
  }

type error =
  | Already_owned
  | Unavailable of string

let close database =
  if Sqlite3.db_close database then Ok () else Error (Sqlite3.errmsg database)
;;

let acquire ~graph_directory =
  let path = Filename.concat graph_directory ".logseq-overlay-owner.sqlite" in
  try
    let database = Sqlite3.db_open path in
    let fail error =
      ignore (close database);
      Error error
    in
    let execute statement =
      match Sqlite3.exec database statement with
      | result when Sqlite3.Rc.is_success result -> Ok ()
      | Sqlite3.Rc.BUSY | LOCKED -> Error Already_owned
      | _ -> Error (Unavailable (Sqlite3.errmsg database))
    in
    Result.bind (execute "PRAGMA journal_mode = DELETE") (fun () ->
      Result.bind (execute "PRAGMA synchronous = FULL") (fun () ->
        Result.bind (execute "PRAGMA busy_timeout = 0") (fun () ->
          Result.bind
            (execute
               "CREATE TABLE IF NOT EXISTS owner_primitive (protocol INTEGER NOT NULL)")
            (fun () ->
               match execute "BEGIN IMMEDIATE" with
               | Ok () -> Ok { database; released = false }
               | Error error -> fail error))))
  with
  | Sqlite3.SqliteError message | Sys_error message -> Error (Unavailable message)
;;

let release owner =
  if owner.released
  then Ok ()
  else (
    owner.released <- true;
    ignore (Sqlite3.exec owner.database "ROLLBACK");
    close owner.database)
;;
