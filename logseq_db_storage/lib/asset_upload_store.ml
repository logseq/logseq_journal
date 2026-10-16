module Intent = Logseq_db_types.Asset_upload_intent
module Uuid = Logseq_db_types.Graph_types.Uuid
module Asset = Logseq_db_types.Asset_descriptor

let ( let* ) = Result.bind

type phase = Intent.phase =
  | Prepared
  | Local_committed
  | Uploading
  | Remote_stored
  | Metadata_pending
  | Complete
  | Cancelled
[@@deriving yojson]

type asset_version =
  { checksum : string
  ; file_type : string
  }
[@@deriving yojson]

type checkpoint =
  { format_version : int
  ; operation_id : Uuid.t
  ; origin : string
  ; account : string
  ; graph : Uuid.t
  ; asset : Uuid.t
  ; version : asset_version
  ; title : string
  ; size : int64
  ; staged_file : string
  ; replace_reference : Uuid.t option
  ; target : Uuid.t
  ; local_mutation : Uuid.t
  ; metadata_mutation : Uuid.t
  ; phase : phase
  ; revision : int
  }
[@@deriving yojson]

let encode (i : Intent.t) =
  checkpoint_to_yojson
    { format_version = 1
    ; operation_id = i.operation_id
    ; origin = i.origin
    ; account = i.account
    ; graph = i.graph
    ; asset = i.asset
    ; version = { checksum = i.version.checksum; file_type = i.version.file_type }
    ; title = i.title
    ; size = i.size
    ; staged_file = i.staged_file
    ; replace_reference = i.replace_reference
    ; target = i.target
    ; local_mutation = i.local_mutation
    ; metadata_mutation = i.metadata_mutation
    ; phase = i.phase
    ; revision = i.revision
    }
  |> Yojson.Safe.to_string
;;

let decode payload =
  try
    if String.length payload > 8192
    then Error "Upload checkpoint exceeds size limit"
    else
      let* value =
        Logseq_db_types.Json_codec.decode
          checkpoint_of_yojson
          (Yojson.Safe.from_string payload)
        |> Result.map_error (fun error ->
          "Unsupported or invalid upload checkpoint: " ^ error)
      in
      if value.format_version <> 1
      then Error "Unsupported upload checkpoint format"
      else
        let* version =
          Asset.version
            ~checksum:value.version.checksum
            ~file_type:value.version.file_type
        in
        let* prepared =
          Intent.prepare
            ~operation_id:value.operation_id
            ~origin:value.origin
            ~account:value.account
            ~graph:value.graph
            ~asset:value.asset
            ~version
            ~title:value.title
            ~size:value.size
            ~staged_file:value.staged_file
            ~replace_reference:value.replace_reference
            ~target:value.target
            ~local_mutation:value.local_mutation
            ~metadata_mutation:value.metadata_mutation
        in
        Intent.restore prepared ~phase:value.phase ~revision:value.revision
  with
  | Yojson.Json_error _ | Failure _ -> Error "Unsupported or invalid upload checkpoint"
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

let delete_account db ~origin ~account =
  statement
    db
    "DELETE FROM asset_upload_intents WHERE origin=? AND account=?"
    (fun stmt ->
       bind stmt [ TEXT origin; TEXT account ];
       check db (Sqlite3.step stmt))
;;

module Captured_rows = Map.Make (struct type t = Uuid.t let compare = Uuid.compare end)

type captured_graph =
  { captured_origin : string; captured_account : string; captured_graph : Uuid.t
  ; captured_rows : string Captured_rows.t }

let captured_graph_matches capture ~origin ~account ~graph =
  capture.captured_origin = origin && capture.captured_account = account && Uuid.equal capture.captured_graph graph
;;

let capture_graph db ~origin ~account ~graph =
  statement db "SELECT operation,payload FROM asset_upload_intents WHERE origin=? AND account=? AND graph=? ORDER BY operation"
    (fun stmt ->
      bind stmt [TEXT origin; TEXT account; TEXT (Uuid.to_string graph)];
      let rec rows acc = match Sqlite3.step stmt with
        | DONE -> Ok {captured_origin=origin; captured_account=account; captured_graph=graph; captured_rows=acc}
        | ROW ->
          let payload = Sqlite3.column_text stmt 1 in
          let* intent = decode payload in
          if intent.origin <> origin || intent.account <> account || not (Uuid.equal intent.graph graph)
             || Uuid.to_string intent.operation_id <> Sqlite3.column_text stmt 0
          then Error "Retirement checkpoint scope mismatch"
          else rows (Captured_rows.add intent.operation_id payload acc)
        | rc -> let* () = check db rc in Error "Unexpected retirement capture result" in
      rows Captured_rows.empty)
;;

let captured_graph_to_yojson capture =
  `Assoc ["version", `Int 1; "origin", `String capture.captured_origin
    ; "account", `String capture.captured_account; "graph", Uuid.to_yojson capture.captured_graph
    ; "rows", `List (Captured_rows.bindings capture.captured_rows |> List.map (fun (id,payload) ->
        `List [Uuid.to_yojson id; `String payload]))]
;;

let captured_graph_of_yojson json =
  try
    let open Yojson.Safe.Util in
    if json |> member "version" |> to_int <> 1 then failwith "Unsupported retirement capture";
    let origin = json |> member "origin" |> to_string in
    let account = json |> member "account" |> to_string in
    let* graph = json |> member "graph" |> Uuid.of_yojson in
    let rec decode_rows acc = function
      | [] -> Ok acc
      | `List [id; `String payload] :: rest ->
        let* id = Uuid.of_yojson id in let* intent = decode payload in
        if intent.origin <> origin || intent.account <> account || not (Uuid.equal graph intent.graph)
           || not (Uuid.equal id intent.operation_id) then Error "Retirement capture scope mismatch"
        else if Captured_rows.mem id acc then Error "Duplicate retirement checkpoint"
        else decode_rows (Captured_rows.add id payload acc) rest
      | _ -> Error "Invalid retirement capture" in
    let* rows = decode_rows Captured_rows.empty (json |> member "rows" |> to_list) in
    Ok {captured_origin=origin;captured_account=account;captured_graph=graph;captured_rows=rows}
  with _ -> Error "Invalid retirement capture"
;;

let delete_captured_graph db capture =
  let* () = check db (Sqlite3.exec db "BEGIN IMMEDIATE") in
  let result =
    let* () = Captured_rows.fold (fun id payload result ->
      let* () = result in
      statement db "SELECT payload FROM asset_upload_intents WHERE operation=?" (fun stmt ->
        bind stmt [TEXT (Uuid.to_string id)]; match Sqlite3.step stmt with
        | DONE -> Ok () | ROW when Sqlite3.column_text stmt 0 = payload -> Ok ()
        | ROW -> Error "A captured upload changed; retirement cleanup remains pending."
        | rc -> check db rc)) capture.captured_rows (Ok ()) in
    Captured_rows.fold (fun id payload result -> let* () = result in
      statement db "DELETE FROM asset_upload_intents WHERE operation=? AND payload=?" (fun stmt ->
        bind stmt [TEXT (Uuid.to_string id); TEXT payload]; check db (Sqlite3.step stmt)))
      capture.captured_rows (Ok ()) in
  match result with
  | Ok () -> check db (Sqlite3.exec db "COMMIT")
  | Error _ as error -> ignore (Sqlite3.exec db "ROLLBACK"); error
;;
