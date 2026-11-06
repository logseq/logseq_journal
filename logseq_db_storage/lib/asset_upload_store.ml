module Intent = Logseq_db_types.Asset_upload_intent
module Uuid = Logseq_db_types.Graph_types.Uuid

let ( let* ) = Result.bind

let encode=Intent.Pure_codec.encode
let decode=Intent.Pure_codec.decode

let protect f =
  try f () with
  | Sqlite3.Error message | Sqlite3.SqliteError message | Sqlite3.DataTypeError message ->
    Error message
;;

let check db rc = if Sqlite3.Rc.is_success rc then Ok () else Error (Sqlite3.errmsg db)

let input_store_error=function
  |Mutation_effect_store.Invalid_input message|Storage_failure message->message
  |Identity_conflict->"Import input identity is already bound to different bytes"
;;

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
    let* () = check
      db
      (Sqlite3.exec
         db
         "CREATE INDEX IF NOT EXISTS asset_upload_scope ON asset_upload_intents(origin, \
          account, graph, operation)") in
    Mutation_effect_store.initialize_database db |> Result.map_error input_store_error)
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

let transact db action =
  let* () = check db (Sqlite3.exec db "BEGIN IMMEDIATE") in
  match protect action with
  | Ok value ->
    (match check db (Sqlite3.exec db "COMMIT") with
     | Ok () -> Ok value
     | Error _ as error -> ignore (Sqlite3.exec db "ROLLBACK"); error)
  | Error _ as error -> ignore (Sqlite3.exec db "ROLLBACK"); error
;;

let delete_account db ~origin ~account ~input_namespaces =
  let valid namespace = String.length namespace=64
    && String.for_all (function '0'..'9'|'a'..'f' -> true | _ -> false) namespace in
  transact db (fun () ->
    let* () = statement db "DELETE FROM overlay_intents_v1 WHERE namespace=?" (fun stmt ->
      Seq.fold_left (fun result namespace ->
        let* () = result in
        let* () = if valid namespace then Ok ()
          else Error "Account input retirement has an invalid namespace" in
        let* () = check db (Sqlite3.reset stmt) in
        bind stmt [TEXT namespace];
        check db (Sqlite3.step stmt)) (Ok ()) input_namespaces) in
    statement db "DELETE FROM asset_upload_intents WHERE origin=? AND account=?" (fun stmt ->
      bind stmt [TEXT origin; TEXT account];
      check db (Sqlite3.step stmt)))
;;

module Inputs = struct
  module Input=Logseq_db_types.Asset_import.Pure_intent
  module Store=Mutation_effect_store
  type owner={namespace:string;origin:string;account:string;graph:Uuid.t}
  type record={sequence:int64;input:Input.t;prepared:Intent.t option;evidence:string option;acknowledged:bool}
  type page={items:record list;next:int64 option}
  let error result=Result.map_error input_store_error result
  let matches (owner:owner) input (prepared:Intent.t)=
    let source=Input.source input in
    Input.namespace input=owner.namespace && prepared.origin=owner.origin && prepared.account=owner.account && prepared.graph=owner.graph
    && prepared.operation_id=source.operation && prepared.asset=source.asset
    && prepared.target=source.target && prepared.replace_reference=source.replace_reference
    && prepared.local_mutation=source.local_mutation && prepared.metadata_mutation=source.metadata_mutation
    && prepared.title=source.title && prepared.version.file_type=source.file_type
  let decode_fields ~(owner:owner) ~operation ~sequence ~payload ~evidence ~acknowledged=
    let* (value:Logseq_db_types.Asset_import.Recovery.checked)=Logseq_db_types.Asset_import.Recovery.decode
      ~owner:{namespace=owner.namespace;origin=owner.origin;account=owner.account;graph=owner.graph}
      {sequence;input=payload;prepared=evidence;acknowledged} in
    if Input.operation value.input<>operation then Error "Stored import input identity mismatch" else
    Ok{sequence=value.sequence;input=value.input;prepared=value.prepared;evidence=value.evidence;acknowledged=value.acknowledged}
  let decode_record ~owner (row:Store.record)=
    if row.namespace<>owner.namespace then Error "Stored import input namespace does not match its owner" else
    decode_fields ~owner ~operation:row.mutation_id
    ~sequence:row.sequence ~payload:row.payload ~evidence:row.evidence ~acknowledged:row.acknowledged
  let read_checkpoint=read
  let read db ~(owner:owner) ~operation=
    let namespace=owner.namespace in
    let* row=error(Store.read db ~namespace ~mutation_id:operation) in
    match row with None->Ok None|Some row->Result.map Option.some(decode_record ~owner row)
  let reserve db ~(owner:owner) ~input=
    if Input.namespace input<>owner.namespace then Error "Import input namespace does not match its authoritative owner" else
    let namespace=Input.namespace input and mutation_id=Input.operation input in
    let* row=error(Store.read db ~namespace ~mutation_id) in
    let* ()=match row with Some _->Ok()|None->
      let* checkpoint=read_checkpoint db ~operation:mutation_id in
      (match checkpoint with None->Ok()|Some _->Error "The legacy upload has no complete original input; it cannot be rebound to a new source") in
    let* row=error(Store.prepare db ~namespace ~mutation_id ~payload:(Input.encode input)) in
    decode_record ~owner row
  let transact = transact
  let commit_prepared db ~owner ~input prepared=
    if prepared.Intent.phase<>Prepared || prepared.revision<>0 || not(matches owner input prepared)
    then Error "Only an exact original Prepared checkpoint can prove input adoption" else
    transact db(fun()->
      let namespace=Input.namespace input and mutation_id=Input.operation input and payload=Input.encode input in
      let* existing=error(Store.read db ~namespace ~mutation_id) in
      match existing with
      |None->Error "Complete source input was not reserved before preparation"
      |Some row when row.payload<>payload->Error "Import input identity is already bound to different bytes"
      |Some row when row.evidence<>None->
        if row.evidence=Some(encode prepared)then decode_record ~owner row
        else Error "Original Prepared proof is immutable"
      |Some _->
        let* ()=save db ~expected:None prepared in
        let* row=error(Store.commit db ~namespace ~mutation_id ~payload ~evidence:(encode prepared)) in
        decode_record ~owner row)
  let acknowledge db ~(owner:owner) ~input ~evidence=
    if Input.namespace input<>owner.namespace then Error "Import input namespace does not match its authoritative owner" else
    let namespace=Input.namespace input and mutation_id=Input.operation input in
    let* row=read db ~owner ~operation:mutation_id in
    match row with
    |Some row when Input.encode row.input=Input.encode input && row.prepared<>None && row.evidence=Some evidence->
      error(Store.acknowledge db ~namespace ~mutation_id ~evidence)
    |_->Error "Only exact stored original Prepared evidence can acknowledge an import input"
  let encoded_bytes row=Logseq_db_types.Asset_import.Recovery.item_encoded_bytes
    {sequence=row.sequence;input=Input.encode row.input;prepared=row.evidence;acknowledged=row.acknowledged}
  let pending db ~(owner:owner) ~after ~maximum_items ~maximum_bytes=
    let namespace=owner.namespace in
    if maximum_items<1 || maximum_items>200 || maximum_bytes<Logseq_db_types.Asset_import.Recovery.maximum_page_overhead || maximum_bytes>4194304
    then Error "Invalid import input recovery bounds" else
    let* page=error(Store.pending db ~namespace ~after ~limit:maximum_items) in
    let rec collect reversed bytes last=function
      |[]->Ok{items=List.rev reversed;next=page.next}
      |row::rest->let* value=decode_record ~owner row in
        let cost=encoded_bytes value in
        if bytes+cost+1>maximum_bytes then
          if reversed=[] then Error "Import recovery byte budget cannot contain its first input"
          else Ok{items=List.rev reversed;next=last}
        else collect(value::reversed)(bytes+cost+1)(Some row.sequence)rest in
    collect [] Logseq_db_types.Asset_import.Recovery.maximum_page_overhead None page.items
end

module Captured_rows = Map.Make (struct type t = Uuid.t let compare = Uuid.compare end)

type captured_graph =
  { captured_origin : string; captured_account : string; captured_graph : Uuid.t
  ; captured_rows : string Captured_rows.t
  ; captured_namespace:string option;captured_inputs:Inputs.record Captured_rows.t }

let captured_graph_matches capture ~namespace ~origin ~account ~graph =
  capture.captured_origin=origin && capture.captured_account=account && Uuid.equal capture.captured_graph graph
  && Option.fold ~none:true ~some:((=)namespace)capture.captured_namespace
;;

let input_from_statement stmt ~(owner:Inputs.owner) =
  let* operation=Uuid.of_string(Sqlite3.column_text stmt 1) |> Result.map_error(fun _->"Stored source operation identity is invalid") in
  let evidence=match Sqlite3.column stmt 3 with Sqlite3.Data.NULL->None|_->Some(Sqlite3.column_text stmt 3) in
  let acknowledged=Sqlite3.column_int stmt 4 in
  if acknowledged<>0 && acknowledged<>1 then Error "Stored source acknowledgement is invalid" else
  Inputs.decode_fields ~owner ~operation ~sequence:(Sqlite3.column_int64 stmt 0)
    ~payload:(Sqlite3.column_text stmt 2) ~evidence ~acknowledged:(acknowledged=1)
;;

let capture_graph db ~namespace ~origin ~account ~graph =
  if String.length namespace<>64 || not(String.for_all(function '0'..'9'|'a'..'f'->true|_->false)namespace)
  then Error "Retirement source namespace is invalid" else
  Inputs.transact db(fun()->
  let* captured_rows=statement db "SELECT operation,payload FROM asset_upload_intents WHERE origin=? AND account=? AND graph=? ORDER BY operation"
    (fun stmt ->
      bind stmt [TEXT origin;TEXT account;TEXT(Uuid.to_string graph)];
      let rec rows acc=match Sqlite3.step stmt with
        |DONE->Ok acc
        |ROW->let payload=Sqlite3.column_text stmt 1 in let* intent=decode payload in
          if intent.origin<>origin || intent.account<>account || intent.graph<>graph
             || Uuid.to_string intent.operation_id<>Sqlite3.column_text stmt 0
          then Error "Retirement checkpoint scope mismatch"
          else rows(Captured_rows.add intent.operation_id payload acc)
        |rc->let* ()=check db rc in Error "Unexpected retirement capture result" in
      rows Captured_rows.empty) in
  let* captured_inputs=statement db "SELECT sequence,mutation_id,payload,evidence,acknowledged FROM overlay_intents_v1 WHERE namespace=? ORDER BY sequence"
    (fun stmt->bind stmt [TEXT namespace];
      let rec rows acc=match Sqlite3.step stmt with
        |DONE->Ok acc
        |ROW->let* row=input_from_statement stmt ~owner:Inputs.{namespace;origin;account;graph} in
          let valid=Option.fold ~none:true ~some:(fun (prepared:Intent.t)->prepared.origin=origin && prepared.account=account && prepared.graph=graph)row.prepared in
          if not valid then Error "Retirement original source proof scope mismatch"
          else rows(Captured_rows.add(Inputs.Input.operation row.input)row acc)
        |rc->let* ()=check db rc in Error "Unexpected retirement input capture result" in
      rows Captured_rows.empty) in
  Ok{captured_origin=origin;captured_account=account;captured_graph=graph;captured_rows;
    captured_namespace=Some namespace;captured_inputs})
;;

let captured_graph_to_yojson capture =
  let base=["version",`Int(if capture.captured_namespace=None then 1 else 2);"origin",`String capture.captured_origin;
    "account",`String capture.captured_account;"graph",Uuid.to_yojson capture.captured_graph;
    "rows",`List(Captured_rows.fold(fun id payload rows->`List[Uuid.to_yojson id;`String payload]::rows)capture.captured_rows [] |> List.rev)] in
  match capture.captured_namespace with None->`Assoc base|Some namespace->
  `Assoc(base@["namespace",`String namespace;
    "inputs",`List(Captured_rows.fold(fun id (row:Inputs.record) rows->
      `List[Uuid.to_yojson id;`String(Int64.to_string row.sequence);`String(Inputs.Input.encode row.input);
        (match row.evidence with None->`Null|Some value->`String value);`Bool row.acknowledged]::rows)capture.captured_inputs [] |> List.rev)])
;;

let captured_graph_of_yojson json =
  try
    let open Yojson.Safe.Util in
    let version=json |> member "version" |> to_int in
    let* ()=if version<>1 && version<>2 then Error "Unsupported retirement capture format" else Ok() in
    let origin=json |> member "origin" |> to_string and account=json |> member "account" |> to_string in
    let* graph=json |> member "graph" |> Uuid.of_yojson |> Result.map_error(fun _->"Retirement capture graph identity is invalid") in
    let rec decode_rows acc=function
      |[]->Ok acc
      |`List[id;`String payload]::rest->
        let* id=Uuid.of_yojson id |> Result.map_error(fun _->"Retirement capture operation identity is invalid") in
        let* intent=decode payload in
        if intent.origin<>origin || intent.account<>account || intent.graph<>graph || id<>intent.operation_id
        then Error "Retirement capture scope mismatch" else if Captured_rows.mem id acc then Error "Duplicate retirement checkpoint"
        else decode_rows(Captured_rows.add id payload acc)rest
      |_->Error "Retirement capture row shape is invalid" in
    let* captured_rows=decode_rows Captured_rows.empty(json |> member "rows" |> to_list) in
    let* captured_namespace,captured_inputs=if version=1 then Ok(None,Captured_rows.empty) else
      let namespace=json |> member "namespace" |> to_string in
      if String.length namespace<>64 || not(String.for_all(function '0'..'9'|'a'..'f'->true|_->false)namespace)
      then Error "Retirement source namespace is invalid" else
      let rec decode_inputs acc=function
        |[]->Ok(Some namespace,acc)
        |`List[id;`String sequence;`String payload;evidence;`Bool acknowledged]::rest->
          let* id=Uuid.of_yojson id |> Result.map_error(fun _->"Retirement source identity is invalid") in
          let evidence=match evidence with `Null->None|`String value->Some value|_->raise Exit in
          let* row=Inputs.decode_fields ~owner:Inputs.{namespace;origin;account;graph} ~operation:id ~sequence:(Int64.of_string sequence) ~payload ~evidence ~acknowledged in
          if Captured_rows.mem id acc then Error "Duplicate retirement source input"
          else if not(Option.fold ~none:true ~some:(fun (prepared:Intent.t)->prepared.origin=origin && prepared.account=account && prepared.graph=graph)row.prepared)
          then Error "Retirement source proof scope mismatch" else decode_inputs(Captured_rows.add id row acc)rest
        |_->Error "Retirement source input shape is invalid" in
      decode_inputs Captured_rows.empty(json |> member "inputs" |> to_list) in
    Ok{captured_origin=origin;captured_account=account;captured_graph=graph;captured_rows;captured_namespace;captured_inputs}
  with _->Error "Retirement capture shape is invalid"
;;

let delete_captured_graph db capture =
  Inputs.transact db(fun()->
    let* ()=Captured_rows.fold(fun id payload result->let* ()=result in
      statement db "SELECT payload FROM asset_upload_intents WHERE operation=?" (fun stmt->
        bind stmt [TEXT(Uuid.to_string id)];match Sqlite3.step stmt with
        |DONE->Ok()|ROW when Sqlite3.column_text stmt 0=payload->Ok()
        |ROW->Error "A captured upload changed; retirement cleanup remains pending."
        |rc->check db rc))capture.captured_rows(Ok()) in
    let* ()=match capture.captured_namespace with None->Ok()|Some namespace->
      Captured_rows.fold(fun id expected result->let* ()=result in
        statement db "SELECT sequence,mutation_id,payload,evidence,acknowledged FROM overlay_intents_v1 WHERE namespace=? AND mutation_id=?" (fun stmt->
          bind stmt [TEXT namespace;TEXT(Uuid.to_string id)];match Sqlite3.step stmt with
          |DONE->Ok()|ROW->let* actual=input_from_statement stmt ~owner:Inputs.{namespace;origin=capture.captured_origin;account=capture.captured_account;graph=capture.captured_graph} in
            if actual=expected then Ok() else Error "A captured source input changed; retirement cleanup remains pending."
          |rc->check db rc))capture.captured_inputs(Ok()) in
    let* ()=Captured_rows.fold(fun id payload result->let* ()=result in
      statement db "DELETE FROM asset_upload_intents WHERE operation=? AND payload=?" (fun stmt->
        bind stmt [TEXT(Uuid.to_string id);TEXT payload];check db(Sqlite3.step stmt)))capture.captured_rows(Ok()) in
    match capture.captured_namespace with None->Ok()|Some namespace->
      Captured_rows.fold(fun id (_:Inputs.record) result->let* ()=result in
        statement db "DELETE FROM overlay_intents_v1 WHERE namespace=? AND mutation_id=?" (fun stmt->
          bind stmt [TEXT namespace;TEXT(Uuid.to_string id)];check db(Sqlite3.step stmt)))capture.captured_inputs(Ok()))
;;
