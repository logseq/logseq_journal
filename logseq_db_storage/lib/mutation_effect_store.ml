module Uuid = Logseq_db_types.Graph_types.Uuid

type error =
  | Invalid_input of string
  | Identity_conflict
  | Storage_failure of string

type record =
  { sequence : int64
  ; namespace : string
  ; mutation_id : Uuid.t
  ; payload : string
  ; evidence : string option
  ; acknowledged : bool
  }

type page =
  { items : record list
  ; next : int64 option
  }

let ( let* ) = Result.bind

let namespace_valid namespace =
  String.length namespace = 64
  && String.for_all
       (function
         | '0' .. '9' | 'a' .. 'f' -> true
         | _ -> false)
       namespace
;;

let validate_namespace namespace =
  if namespace_valid namespace
  then Ok ()
  else Error (Invalid_input "Intent namespace must be a lowercase SHA-256 value")
;;

let validate_bytes label maximum bytes =
  if String.length bytes = 0 || String.length bytes > maximum
  then Error (Invalid_input (label ^ " has an invalid byte length"))
  else Ok ()
;;

let rc db code =
  if Sqlite3.Rc.is_success code
  then Ok ()
  else Error (Storage_failure (Sqlite3.errmsg db))
;;

let protect action =
  try action () with
  | exn -> Error (Storage_failure (Printexc.to_string exn))
;;

let statement db sql f =
  protect (fun () ->
    let stmt = Sqlite3.prepare db sql in
    Fun.protect ~finally:(fun () -> ignore (Sqlite3.finalize stmt)) (fun () -> f stmt))
;;

let initialize_database db =
  protect (fun () ->
    let* () =
      rc
        db
        (Sqlite3.exec
           db
           "CREATE TABLE IF NOT EXISTS overlay_intents_v1 (sequence INTEGER PRIMARY KEY \
            AUTOINCREMENT, namespace TEXT NOT NULL CHECK(length(namespace)=64), \
            mutation_id TEXT NOT NULL, payload BLOB NOT NULL, evidence BLOB, \
            acknowledged INTEGER NOT NULL DEFAULT 0 CHECK(acknowledged IN (0,1)), \
            UNIQUE(namespace,mutation_id))")
    in
    rc
      db
      (Sqlite3.exec
         db
         "CREATE INDEX IF NOT EXISTS overlay_intents_pending_v1 ON \
          overlay_intents_v1(namespace,acknowledged,sequence)"))
;;

let bind_identity stmt namespace mutation_id =
  Sqlite3.Rc.check (Sqlite3.bind_text stmt 1 namespace);
  Sqlite3.Rc.check (Sqlite3.bind_text stmt 2 (Uuid.to_string mutation_id))
;;

let decode stmt =
  let namespace = Sqlite3.column_text stmt 1 in
  let* () = validate_namespace namespace in
  let* mutation_id =
    Uuid.of_string (Sqlite3.column_text stmt 2)
    |> Result.map_error (fun _ -> Storage_failure "Invalid stored intent identity")
  in
  let sequence = Sqlite3.column_int64 stmt 0
  and payload = Sqlite3.column_blob stmt 3
  and acknowledged = Sqlite3.column_int stmt 5 in
  let* () = validate_bytes "Stored intent" 2097152 payload in
  let* evidence =
    match Sqlite3.column stmt 4 with
    | Sqlite3.Data.NULL -> Ok None
    | BLOB bytes | TEXT bytes ->
      let* () = validate_bytes "Stored evidence" 1048576 bytes in
      Ok (Some bytes)
    | _ -> Error (Storage_failure "Invalid stored intent evidence")
  in
  if
    sequence <= 0L
    || (acknowledged <> 0 && acknowledged <> 1)
    || (acknowledged = 1 && evidence = None)
  then Error (Storage_failure "Invalid stored intent checkpoint")
  else
    Ok
      { sequence
      ; namespace
      ; mutation_id
      ; payload
      ; evidence
      ; acknowledged = acknowledged = 1
      }
;;

let read db ~namespace ~mutation_id =
  let* () = validate_namespace namespace in
  statement
    db
    "SELECT sequence,namespace,mutation_id,payload,evidence,acknowledged FROM \
     overlay_intents_v1 WHERE namespace=? AND mutation_id=?"
    (fun stmt ->
       bind_identity stmt namespace mutation_id;
       match Sqlite3.step stmt with
       | Sqlite3.Rc.DONE -> Ok None
       | ROW -> Result.map Option.some (decode stmt)
       | code ->
         let* () = rc db code in
         Error (Storage_failure "Intent lookup returned no row"))
;;

let prepare db ~namespace ~mutation_id ~payload =
  let* () = validate_namespace namespace in
  let* () = validate_bytes "Intent" 2097152 payload in
  let* () =
    statement
      db
      "INSERT INTO overlay_intents_v1(namespace,mutation_id,payload) VALUES(?,?,?) ON \
       CONFLICT(namespace,mutation_id) DO NOTHING"
      (fun stmt ->
         bind_identity stmt namespace mutation_id;
         Sqlite3.Rc.check (Sqlite3.bind_blob stmt 3 payload);
         rc db (Sqlite3.step stmt))
  in
  let* current = read db ~namespace ~mutation_id in
  match current with
  | Some record when record.payload = payload -> Ok record
  | _ -> Error Identity_conflict
;;

let commit db ~namespace ~mutation_id ~payload ~evidence =
  let* () = validate_namespace namespace in
  let* () = validate_bytes "Intent" 2097152 payload in
  let* () = validate_bytes "Evidence" 1048576 evidence in
  let* () =
    statement
      db
      "UPDATE overlay_intents_v1 SET evidence=? WHERE namespace=? AND mutation_id=? AND \
       payload=? AND evidence IS NULL"
      (fun stmt ->
         Sqlite3.Rc.check (Sqlite3.bind_blob stmt 1 evidence);
         Sqlite3.Rc.check (Sqlite3.bind_text stmt 2 namespace);
         Sqlite3.Rc.check (Sqlite3.bind_text stmt 3 (Uuid.to_string mutation_id));
         Sqlite3.Rc.check (Sqlite3.bind_blob stmt 4 payload);
         rc db (Sqlite3.step stmt))
  in
  let* current = read db ~namespace ~mutation_id in
  match current with
  | Some record when record.payload = payload && record.evidence = Some evidence ->
    Ok record
  | _ -> Error Identity_conflict
;;

let acknowledge db ~namespace ~mutation_id ~evidence =
  let* () = validate_namespace namespace in
  let* () = validate_bytes "Evidence" 1048576 evidence in
  let* () =
    statement
      db
      "UPDATE overlay_intents_v1 SET acknowledged=1 WHERE namespace=? AND mutation_id=? \
       AND evidence=?"
      (fun stmt ->
         bind_identity stmt namespace mutation_id;
         Sqlite3.Rc.check (Sqlite3.bind_blob stmt 3 evidence);
         rc db (Sqlite3.step stmt))
  in
  let* current = read db ~namespace ~mutation_id in
  match current with
  | Some { evidence = Some actual; acknowledged = true; _ } when evidence = actual ->
    Ok ()
  | _ -> Error Identity_conflict
;;

let pending db ~namespace ~after ~limit =
  let* () = validate_namespace namespace in
  let after = Option.value after ~default:0L in
  if after < 0L || limit <= 0 || limit > 256
  then Error (Invalid_input "Invalid recovery page bounds")
  else
    statement
      db
      "SELECT sequence,namespace,mutation_id,payload,evidence,acknowledged, \
       length(payload),coalesce(length(evidence),0) FROM overlay_intents_v1 WHERE \
       namespace=? AND acknowledged=0 AND sequence>? ORDER BY sequence LIMIT ?"
      (fun stmt ->
         Sqlite3.Rc.check (Sqlite3.bind_text stmt 1 namespace);
         Sqlite3.Rc.check (Sqlite3.bind_int64 stmt 2 after);
         Sqlite3.Rc.check (Sqlite3.bind_int stmt 3 (limit + 1));
         let page reversed next = Ok { items = List.rev reversed; next } in
         let rec collect reversed count bytes last =
           match Sqlite3.step stmt with
           | Sqlite3.Rc.ROW ->
             let payload_bytes = Sqlite3.column_int stmt 6
             and evidence_bytes = Sqlite3.column_int stmt 7 in
             if payload_bytes <= 0 || payload_bytes > 2097152 || evidence_bytes > 1048576
             then Error (Storage_failure "Stored intent exceeds recovery bounds")
             else if count = limit || bytes + payload_bytes + evidence_bytes > 4194304
             then page reversed last
             else
               let* item = decode stmt in
               collect
                 (item :: reversed)
                 (count + 1)
                 (bytes + payload_bytes + evidence_bytes)
                 (Some item.sequence)
           | DONE -> page reversed None
           | code ->
             let* () = rc db code in
             Error (Storage_failure "Recovery query did not complete")
         in
         collect [] 0 0 None)
;;
