let rc_result db rc =
  if Sqlite3.Rc.is_success rc then Ok () else Error (Sqlite3.errmsg db)
;;

let valid_key key =
  String.length key = 64
  && String.for_all
       (function
         | '0' .. '9' | 'a' .. 'f' -> true
         | _ -> false)
       key
;;

let initialize_database db =
  Result.bind
    (rc_result
       db
       (Sqlite3.exec
          db
          "CREATE TABLE IF NOT EXISTS overlay_mutation_receipts (receipt_key TEXT \
           PRIMARY KEY CHECK(length(receipt_key) = 64), receipt TEXT NOT NULL)"))
    (fun () ->
       rc_result
         db
         (Sqlite3.exec
            db
            "CREATE TABLE IF NOT EXISTS overlay_terminal_batch_receipts (batch_key TEXT \
             PRIMARY KEY CHECK(length(batch_key) = 64), receipt TEXT NOT NULL)"))
;;

let read_database db =
  try
    let receipts = ref [] in
    let result =
      Sqlite3.exec
        db
        "SELECT receipt_key, receipt FROM overlay_mutation_receipts ORDER BY receipt_key"
        ~cb:(fun row _ ->
          match row.(0), row.(1) with
          | Some key, Some receipt -> receipts := (key, receipt) :: !receipts
          | _ -> ())
    in
    Result.map (fun () -> List.rev !receipts) (rc_result db result)
  with
  | exn -> Error (Printexc.to_string exn)
;;

let validate_database db ~is_valid =
  try
    let invalid = ref false in
    let result =
      Sqlite3.exec
        db
        "SELECT receipt_key, receipt FROM overlay_mutation_receipts"
        ~cb:(fun row _ ->
          match row.(0), row.(1) with
          | Some key, Some receipt when is_valid key receipt -> ()
          | None, _ | _, None | Some _, Some _ -> invalid := true)
    in
    Result.bind (rc_result db result) (fun () ->
      if !invalid then Error "invalid mutation receipt" else Ok ())
  with
  | exn -> Error (Printexc.to_string exn)
;;

let read_mutation db key =
  if not (valid_key key)
  then Error "mutation receipt key must be a lowercase SHA-256 value"
  else (
    let statement =
      Sqlite3.prepare
        db
        "SELECT receipt FROM overlay_mutation_receipts WHERE receipt_key = ?"
    in
    Fun.protect
      ~finally:(fun () -> ignore (Sqlite3.finalize statement))
      (fun () ->
         try
           Sqlite3.Rc.check (Sqlite3.bind_text statement 1 key);
           match Sqlite3.step statement with
           | Sqlite3.Rc.ROW -> Ok (Some (Sqlite3.column_text statement 0))
           | DONE -> Ok None
           | rc ->
             Sqlite3.Rc.check rc;
             assert false
         with
         | exn -> Error (Printexc.to_string exn)))
;;

let upsert_mutations db receipts =
  match List.find_opt (fun (key, _) -> not (valid_key key)) receipts with
  | Some _ -> Error "mutation receipt key must be a lowercase SHA-256 value"
  | None ->
    let statement =
      Sqlite3.prepare
        db
        "INSERT INTO overlay_mutation_receipts(receipt_key, receipt) VALUES(?, ?) ON \
         CONFLICT(receipt_key) DO UPDATE SET receipt = excluded.receipt"
    in
    Fun.protect
      ~finally:(fun () -> ignore (Sqlite3.finalize statement))
      (fun () ->
         let rec insert = function
           | [] -> Ok ()
           | (key, receipt) :: rest ->
             Sqlite3.Rc.check (Sqlite3.reset statement);
             Sqlite3.Rc.check (Sqlite3.bind_text statement 1 key);
             Sqlite3.Rc.check (Sqlite3.bind_text statement 2 receipt);
             (match rc_result db (Sqlite3.step statement) with
              | Error _ as error -> error
              | Ok () -> insert rest)
         in
         try insert receipts with
         | exn -> Error (Printexc.to_string exn))
;;

let read_terminal_batch db key =
  if not (valid_key key)
  then Error "terminal batch key must be a lowercase SHA-256 value"
  else (
    let statement =
      Sqlite3.prepare
        db
        "SELECT receipt FROM overlay_terminal_batch_receipts WHERE batch_key = ?"
    in
    Fun.protect
      ~finally:(fun () -> ignore (Sqlite3.finalize statement))
      (fun () ->
         try
           Sqlite3.Rc.check (Sqlite3.bind_text statement 1 key);
           match Sqlite3.step statement with
           | Sqlite3.Rc.ROW -> Ok (Some (Sqlite3.column_text statement 0))
           | DONE -> Ok None
           | rc ->
             Sqlite3.Rc.check rc;
             assert false
         with
         | exn -> Error (Printexc.to_string exn)))
;;

let upsert_terminal_batches db receipts =
  match List.find_opt (fun (key, _) -> not (valid_key key)) receipts with
  | Some _ -> Error "terminal batch key must be a lowercase SHA-256 value"
  | None ->
    let statement =
      Sqlite3.prepare
        db
        "INSERT INTO overlay_terminal_batch_receipts(batch_key, receipt) VALUES(?, ?) ON \
         CONFLICT(batch_key) DO UPDATE SET receipt = excluded.receipt"
    in
    Fun.protect
      ~finally:(fun () -> ignore (Sqlite3.finalize statement))
      (fun () ->
         let rec insert = function
           | [] -> Ok ()
           | (key, receipt) :: rest ->
             Sqlite3.Rc.check (Sqlite3.reset statement);
             Sqlite3.Rc.check (Sqlite3.bind_text statement 1 key);
             Sqlite3.Rc.check (Sqlite3.bind_text statement 2 receipt);
             (match rc_result db (Sqlite3.step statement) with
              | Error _ as error -> error
              | Ok () -> insert rest)
         in
         try insert receipts with
         | exn -> Error (Printexc.to_string exn))
;;
