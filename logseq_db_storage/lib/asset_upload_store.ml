module Intent = Logseq_db_types.Asset_upload_intent
module Uuid = Logseq_db_types.Graph_types.Uuid
module Asset = Logseq_db_types.Asset_descriptor

let ( let* ) = Result.bind

let phase_name = function
  | Intent.Prepared -> "prepared"
  | Local_committed -> "local_committed"
  | Uploading -> "uploading"
  | Remote_stored -> "remote_stored"
  | Metadata_pending -> "metadata_pending"
  | Complete -> "complete"
  | Cancelled -> "cancelled"
;;

let phase_of_name = function
  | "prepared" -> Ok Intent.Prepared
  | "local_committed" -> Ok Intent.Local_committed
  | "uploading" -> Ok Intent.Uploading
  | "remote_stored" -> Ok Intent.Remote_stored
  | "metadata_pending" -> Ok Intent.Metadata_pending
  | "complete" -> Ok Intent.Complete
  | "cancelled" -> Ok Intent.Cancelled
  | _ -> Error "Invalid upload checkpoint phase"
;;

let encode (i : Intent.t) =
  Yojson.Safe.to_string
    (`Assoc
        [ "operation", `String (Uuid.to_string i.operation_id)
        ; "origin", `String i.origin
        ; "account", `String i.account
        ; "graph", `String (Uuid.to_string i.graph)
        ; "asset", `String (Uuid.to_string i.asset)
        ; "checksum", `String i.version.checksum
        ; "type", `String i.version.file_type
        ; "title", `String i.title
        ; "size", `String (Int64.to_string i.size)
        ; "staged_file", `String i.staged_file
        ; ( "replace_reference"
          , Option.fold
              ~none:`Null
              ~some:(fun id -> `String (Uuid.to_string id))
              i.replace_reference )
        ; "target", `String (Uuid.to_string i.target)
        ; "local_mutation", `String (Uuid.to_string i.local_mutation)
        ; "metadata_mutation", `String (Uuid.to_string i.metadata_mutation)
        ; "phase", `String (phase_name i.phase)
        ; "revision", `Int i.revision
        ])
;;

let decode payload =
  try
    if String.length payload > 8192
    then Error "Upload checkpoint exceeds size limit"
    else (
      let json = Yojson.Safe.from_string payload in
      let field key = Yojson.Safe.Util.(json |> member key |> to_string) in
      let* operation_id = Uuid.of_string (field "operation") in
      let* graph = Uuid.of_string (field "graph") in
      let* asset = Uuid.of_string (field "asset") in
      let* replace_reference =
        match json with
        | `Assoc fields ->
          (match List.assoc_opt "replace_reference" fields with
           | Some `Null -> Ok None
           | Some (`String id) -> Result.map Option.some (Uuid.of_string id)
           | _ -> Error "Missing or invalid replacement reference")
        | _ -> Error "Invalid upload checkpoint"
      in
      let* target = Uuid.of_string (field "target") in
      let* local_mutation = Uuid.of_string (field "local_mutation") in
      let* metadata_mutation = Uuid.of_string (field "metadata_mutation") in
      let* version =
        Asset.version ~checksum:(field "checksum") ~file_type:(field "type")
      in
      let* phase = phase_of_name (field "phase") in
      let revision = Yojson.Safe.Util.(json |> member "revision" |> to_int) in
      let* prepared =
        Intent.prepare
          ~replace_reference
          ~operation_id
          ~origin:(field "origin")
          ~account:(field "account")
          ~graph
          ~asset
          ~version
          ~title:(field "title")
          ~size:(Int64.of_string (field "size"))
          ~staged_file:(field "staged_file")
          ~target
          ~local_mutation
          ~metadata_mutation
      in
      Intent.restore prepared ~phase ~revision)
  with
  | Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ | Failure _ ->
    Error "Invalid upload checkpoint"
;;

let protect f =
  try f () with
  | Sqlite3.Error message | Sqlite3.SqliteError message | Sqlite3.DataTypeError message ->
    Error message
;;

let check db rc = if Sqlite3.Rc.is_success rc then Ok () else Error (Sqlite3.errmsg db)

let initialize_database db =
  protect (fun () ->
    let* () =
      check
        db
        (Sqlite3.exec
           db
           "CREATE TABLE IF NOT EXISTS asset_upload_intents (operation TEXT PRIMARY KEY, \
            origin TEXT NOT NULL, account TEXT NOT NULL, graph TEXT NOT NULL, revision \
            INTEGER NOT NULL, payload TEXT NOT NULL CHECK(length(payload) <= 8192))")
    in
    check
      db
      (Sqlite3.exec
         db
         "CREATE INDEX IF NOT EXISTS asset_upload_scope ON asset_upload_intents(origin, \
          account, graph, operation)"))
;;

let statement db sql f =
  protect (fun () ->
    let stmt = Sqlite3.prepare db sql in
    Fun.protect ~finally:(fun () -> ignore (Sqlite3.finalize stmt)) (fun () -> f stmt))
;;

let bind stmt values = Sqlite3.Rc.check (Sqlite3.bind_values stmt values)

let read db ~operation =
  statement db "SELECT payload FROM asset_upload_intents WHERE operation = ?" (fun stmt ->
    bind stmt [ Sqlite3.Data.TEXT (Uuid.to_string operation) ];
    match Sqlite3.step stmt with
    | ROW ->
      let* intent = decode (Sqlite3.column_text stmt 0) in
      if Uuid.equal operation intent.operation_id
      then Ok (Some intent)
      else Error "Upload checkpoint identity mismatch"
    | DONE -> Ok None
    | rc ->
      let* () = check db rc in
      Error "Unexpected upload checkpoint query result")
;;

let save db ~expected intent =
  let* old = read db ~operation:intent.Intent.operation_id in
  if old = Some intent
  then Ok ()
  else (
    let payload = encode intent in
    if String.length payload > 8192
    then Error "Upload checkpoint exceeds size limit"
    else (
      match old, expected with
      | None, None
        when (intent.phase = Prepared && intent.revision = 0)
             || (intent.phase = Cancelled && intent.revision = 1) ->
        statement
          db
          "INSERT INTO \
           asset_upload_intents(operation,origin,account,graph,revision,payload) \
           VALUES(?,?,?,?,?,?)"
          (fun stmt ->
             bind
               stmt
               [ TEXT (Uuid.to_string intent.operation_id)
               ; TEXT intent.origin
               ; TEXT intent.account
               ; TEXT (Uuid.to_string intent.graph)
               ; INT (Int64.of_int intent.revision)
               ; TEXT payload
               ];
             check db (Sqlite3.step stmt))
      | Some previous, Some revision
        when previous.revision = revision
             && Intent.advance previous intent.phase = Ok intent ->
        statement
          db
          "UPDATE asset_upload_intents SET revision=?,payload=? WHERE operation=? AND \
           revision=? AND payload=?"
          (fun stmt ->
             bind
               stmt
               [ INT (Int64.of_int intent.revision)
               ; TEXT payload
               ; TEXT (Uuid.to_string intent.operation_id)
               ; INT (Int64.of_int revision)
               ; TEXT (encode previous)
               ];
             let* () = check db (Sqlite3.step stmt) in
             if Sqlite3.changes db = 1
             then Ok ()
             else Error "Upload checkpoint changed concurrently")
      | _ -> Error "Stale or invalid upload checkpoint transition"))
;;

let list db ~origin ~account ~graph ~after ~limit =
  if limit < 1 || limit > 200
  then Error "Upload recovery limit must be between 1 and 200"
  else
    statement
      db
      "SELECT operation,payload FROM asset_upload_intents WHERE origin=? AND account=? \
       AND graph=? AND operation>? ORDER BY operation LIMIT ?"
      (fun stmt ->
         bind
           stmt
           [ TEXT origin
           ; TEXT account
           ; TEXT (Uuid.to_string graph)
           ; TEXT (Option.fold ~none:"" ~some:Uuid.to_string after)
           ; INT (Int64.of_int limit)
           ];
         let rec rows acc =
           match Sqlite3.step stmt with
           | DONE -> Ok (List.rev acc)
           | ROW ->
             let* intent = decode (Sqlite3.column_text stmt 1) in
             if
               intent.origin <> origin
               || intent.account <> account
               || (not (Uuid.equal intent.graph graph))
               || Uuid.to_string intent.operation_id <> Sqlite3.column_text stmt 0
             then Error "Upload checkpoint scope mismatch"
             else rows (intent :: acc)
           | rc ->
             let* () = check db rc in
             Error "Unexpected upload recovery query result"
         in
         rows [])
;;

let delete_graph db ~origin ~account ~graph =
  statement
    db
    "DELETE FROM asset_upload_intents WHERE origin=? AND account=? AND graph=?"
    (fun stmt ->
       bind stmt [ TEXT origin; TEXT account; TEXT (Uuid.to_string graph) ];
       check db (Sqlite3.step stmt))
;;

let delete_account db ~origin ~account =
  statement
    db
    "DELETE FROM asset_upload_intents WHERE origin=? AND account=?"
    (fun stmt ->
       bind stmt [ TEXT origin; TEXT account ];
       check db (Sqlite3.step stmt))
;;
