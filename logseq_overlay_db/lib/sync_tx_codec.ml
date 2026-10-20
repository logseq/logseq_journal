module Transit = Transit_core.Json
module Codec = Transit_native.Transit.Json
open Datascript

let protected_attributes = [ "block/title"; "block/name" ]

let bind result next =
  match result with
  | Ok value -> next value
  | Error _ as error -> error
;;

let map_all decode values =
  let rec loop decoded = function
    | [] -> Ok (List.rev decoded)
    | value :: rest -> bind (decode value) (fun value -> loop (value :: decoded) rest)
  in
  loop [] values
;;

module Diagnostic = Logseq_db_types.Authoritative_diagnostic

let transit_kind = function
  | Transit.Null -> "null"
  | Bool _ -> "bool"
  | String _ -> "string"
  | Int _ -> "integer"
  | Int64 _ -> "int64"
  | Float _ -> "float"
  | Binary _ -> "binary"
  | Big_decimal _ -> "decimal"
  | Big_int _ -> "big-integer"
  | Date _ -> "date"
  | Uuid _ -> "uuid"
  | Uri _ -> "uri"
  | Keyword _ -> "keyword"
  | Symbol _ -> "symbol"
  | Array _ -> "array"
  | Map _ -> "map"
  | Set _ -> "set"
  | List _ -> "list"
  | Tagged _ -> "tagged"
;;

let diagnostic_error ?field ?actual reason =
  Error (Diagnostic.encode (Diagnostic.create ~stage:Decode ~reason ?field ?actual ()))
;;

let diagnostic_context
      ?field
      ?operation_index
      ?operation_count
      ?arity
      ?operation
      ?attribute
      result
  =
  Result.map_error
    (fun source ->
       let detail =
         match Diagnostic.decode source with
         | Some detail -> detail
         | None -> Diagnostic.create ~stage:Decode ~reason:Unknown ()
       in
       Diagnostic.with_context
         ?field
         ?operation_index
         ?operation_count
         ?arity
         ?operation
         ?attribute
         detail
       |> Diagnostic.encode)
    result
;;

let operation_context index count operation result =
  let arity, name, attribute =
    match operation with
    | Transit.Array (Keyword op :: _entity :: Keyword attr :: _ as fields) ->
      Some (List.length fields), Some op, Some attr
    | Array (Keyword op :: _ as fields) -> Some (List.length fields), Some op, None
    | Array fields -> Some (List.length fields), None, None
    | _ -> None, None, None
  in
  diagnostic_context
    ~operation_index:index
    ~operation_count:count
    ?arity
    ?operation:name
    ?attribute
    result
;;

let lookup_value entity attr =
  match Datascript.Entity.entity_attr_raw entity attr with
  | Some (Datascript.One_value value) -> Some value
  | Some (Datascript.One_entity _ | Many_values _ | Many_entities _) | None -> None
;;

let stable_entity_ref db eid =
  match Datascript.entity db (Datascript.Entity_id eid) with
  | Some entity ->
    (match lookup_value entity "block/uuid", lookup_value entity "db/ident" with
     | Some (Datascript.Uuid uuid), _ ->
       Datascript.Lookup_ref ("block/uuid", Datascript.Uuid uuid)
     | _, Some (Datascript.Keyword ident) ->
       Datascript.Lookup_ref ("db/ident", Datascript.Keyword ident)
     | _ -> Datascript.Entity_id eid)
  | None -> Datascript.Entity_id eid
;;

let rec transit_of_entity_ref db = function
  | Datascript.Entity_id eid ->
    (match stable_entity_ref db eid with
     | Datascript.Entity_id stable_eid -> Transit.Int stable_eid
     | stable_ref -> transit_of_entity_ref db stable_ref)
  | Temp_id temp_id -> Transit.String temp_id
  | CurrentTx -> Transit.Keyword "db/current-tx"
  | Ident ident -> Transit.Keyword ident
  | Lookup_ref (attr, value) ->
    Transit.Array [ Transit.Keyword attr; transit_of_value db value ]

and transit_of_value db = function
  | Datascript.Nil -> Transit.Null
  | Int64 value ->
    if
      Int64.compare value (Int64.of_int min_int) >= 0
      && Int64.compare value (Int64.of_int max_int) <= 0
    then Transit.Int (Int64.to_int value)
    else Transit.Int64 value
  | Float value -> Transit.Float value
  | String value -> Transit.String value
  | Symbol value -> Transit.Symbol value
  | Bool value -> Transit.Bool value
  | Keyword value -> Transit.Keyword value
  | Uuid value -> Transit.Uuid value
  | Instant value -> Transit.Date value
  | Regex value -> Transit.Tagged ("regex", Transit.String value)
  | Ref eid -> transit_of_entity_ref db (stable_entity_ref db eid)
  | List values -> Transit.List (List.map (transit_of_value db) values)
  | Vector values -> Transit.Array (List.map (transit_of_value db) values)
  | Map entries ->
    Transit.Map
      (List.map
         (fun (key, value) -> transit_of_value db key, transit_of_value db value)
         entries)
  | Set values -> Transit.Set (List.map (transit_of_value db) values)
  | Tuple values ->
    Transit.Array
      (List.map (Option.fold ~none:Transit.Null ~some:(transit_of_value db)) values)
  | TxRef -> Transit.Keyword "db/current-tx"
  | Ref_to entity_ref -> transit_of_entity_ref db entity_ref
;;

let transit_of_tx_op db = function
  | Datascript.Add (entity, attr, value) ->
    Ok
      (Transit.Array
         [ Keyword "db/add"
         ; transit_of_entity_ref db entity
         ; Keyword attr
         ; transit_of_value db value
         ])
  | Retract (entity, attr, Some value) ->
    Ok
      (Transit.Array
         [ Keyword "db/retract"
         ; transit_of_entity_ref db entity
         ; Keyword attr
         ; transit_of_value db value
         ])
  | Retract (entity, attr, None) | RetractAttr (entity, attr) ->
    Ok
      (Transit.Array
         [ Keyword "db.fn/retractAttribute"
         ; transit_of_entity_ref db entity
         ; Keyword attr
         ])
  | RetractEntity entity ->
    Ok (Transit.Array [ Keyword "db/retractEntity"; transit_of_entity_ref db entity ])
  | CompareAndSet (entity, attr, expected, value) ->
    Ok
      (Transit.Array
         [ Keyword "db.fn/cas"
         ; transit_of_entity_ref db entity
         ; Keyword attr
         ; Option.fold ~none:Transit.Null ~some:(transit_of_value db) expected
         ; transit_of_value db value
         ])
  | Raw_datom datom ->
    Ok
      (Transit.Array
         [ Keyword (if datom.added then "db/add" else "db/retract")
         ; transit_of_entity_ref db (stable_entity_ref db datom.e)
         ; Keyword datom.a
         ; transit_of_value db datom.v
         ])
  | Entity _ | CallIdent _ | InstallTxFn _ | Call _ ->
    Error "complex transaction forms cannot be sent over sync"
;;

let synchronized_operation = function
  | Datascript.Add (CurrentTx, _, _)
  | Retract (CurrentTx, _, _)
  | RetractAttr (CurrentTx, _)
  | CompareAndSet (CurrentTx, _, _, _)
  | Datascript.Add (_, "block/tx-id", _)
  | Retract (_, "block/tx-id", _)
  | RetractAttr (_, "block/tx-id")
  | CompareAndSet (_, "block/tx-id", _, _)
  | Raw_datom { a = "block/tx-id"; _ } -> false
  | Add _ | Retract _ | RetractAttr _ | RetractEntity _ | CompareAndSet _ | Raw_datom _ ->
    true
  | Entity _ | CallIdent _ | InstallTxFn _ | Call _ -> true
;;

let synchronized_operations operations = List.filter synchronized_operation operations

let encode ~db operations =
  let operations = synchronized_operations operations in
  let rec loop encoded = function
    | [] -> Ok (Codec.to_string ~mode:Codec.Verbose (Transit.Array (List.rev encoded)))
    | operation :: rest ->
      bind (transit_of_tx_op db operation) (fun encoded_operation ->
        loop (encoded_operation :: encoded) rest)
  in
  loop [] operations
;;

let plaintext_of_value attribute = function
  | Datascript.String plaintext when List.mem attribute protected_attributes ->
    Ok (Some (Codec.to_string (Transit.String plaintext)))
  | String _ -> Ok None
  | _ when List.mem attribute protected_attributes ->
    Error ("protected attribute " ^ attribute ^ " must be a string")
  | _ -> Ok None
;;

let protected_plaintexts operations =
  let add_value acc attribute value =
    Result.map
      (function
        | None -> acc
        | Some plaintext -> plaintext :: acc)
      (plaintext_of_value attribute value)
  in
  let add_operation acc = function
    | Datascript.Add (_, attribute, value) | Retract (_, attribute, Some value) ->
      add_value acc attribute value
    | CompareAndSet (_, attribute, expected, value) ->
      bind
        (match expected with
         | None -> Ok acc
         | Some expected -> add_value acc attribute expected)
        (fun acc -> add_value acc attribute value)
    | Raw_datom datom -> add_value acc datom.a datom.v
    | Retract (_, _, None) | RetractAttr _ | RetractEntity _ -> Ok acc
    | Entity _ | CallIdent _ | InstallTxFn _ | Call _ ->
      Error "complex transaction forms cannot be sent over sync"
  in
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | operation :: rest -> bind (add_operation acc operation) (fun acc -> loop acc rest)
  in
  loop [] operations
;;

let replace_value attribute value encrypted =
  if List.mem attribute protected_attributes
  then (
    match value, encrypted with
    | Datascript.String _, next :: rest -> Ok (Datascript.String next, rest)
    | String _, [] -> Error "encrypted value count does not match protected values"
    | _, _ -> Error ("protected attribute " ^ attribute ^ " must be a string"))
  else Ok (value, encrypted)
;;

let replace_protected_values operations encrypted =
  let replace operation encrypted =
    match operation with
    | Datascript.Add (entity, attribute, value) ->
      Result.map
        (fun (value, rest) -> Datascript.Add (entity, attribute, value), rest)
        (replace_value attribute value encrypted)
    | Retract (entity, attribute, Some value) ->
      Result.map
        (fun (value, rest) -> Datascript.Retract (entity, attribute, Some value), rest)
        (replace_value attribute value encrypted)
    | CompareAndSet (entity, attribute, expected, value) ->
      bind
        (match expected with
         | None -> Ok (None, encrypted)
         | Some expected ->
           Result.map
             (fun (expected, rest) -> Some expected, rest)
             (replace_value attribute expected encrypted))
        (fun (expected, encrypted) ->
           Result.map
             (fun (value, rest) ->
                Datascript.CompareAndSet (entity, attribute, expected, value), rest)
             (replace_value attribute value encrypted))
    | Raw_datom datom ->
      Result.map
        (fun (value, rest) -> Datascript.Raw_datom { datom with v = value }, rest)
        (replace_value datom.a datom.v encrypted)
    | (Retract (_, _, None) | RetractAttr _ | RetractEntity _) as operation ->
      Ok (operation, encrypted)
    | Entity _ | CallIdent _ | InstallTxFn _ | Call _ ->
      Error "complex transaction forms cannot be sent over sync"
  in
  let rec loop replaced encrypted = function
    | [] ->
      if encrypted = []
      then Ok (List.rev replaced)
      else Error "encrypted value count does not match protected values"
    | operation :: rest ->
      bind (replace operation encrypted) (fun (operation, encrypted) ->
        loop (operation :: replaced) encrypted rest)
  in
  loop [] encrypted operations
;;

let encode_protected ~db operations ~encrypted_values =
  bind (replace_protected_values operations encrypted_values) (encode ~db)
;;

let integer = function
  | Transit.Int value -> Ok value
  | Int64 value
    when Int64.compare value (Int64.of_int min_int) >= 0
         && Int64.compare value (Int64.of_int max_int) <= 0 -> Ok (Int64.to_int value)
  | value -> diagnostic_error ~actual:(transit_kind value) Integer_range
;;

let integer64 = function
  | Transit.Int value -> Ok (Int64.of_int value)
  | Int64 value -> Ok value
  | value -> diagnostic_error ~actual:(transit_kind value) Integer_value
;;

let rec value_of_transit = function
  | Transit.Null -> Ok Nil
  | Bool value -> Ok (Bool value)
  | String value -> Ok (String value)
  | Int value -> Ok (Int64 (Int64.of_int value))
  | Int64 value -> Ok (Int64 value)
  | Float value -> Ok (Float value)
  | Binary value -> Ok (String value)
  | Big_decimal value ->
    (match float_of_string_opt value with
     | Some value -> Ok (Float value)
     | None -> diagnostic_error ~actual:"decimal" Decimal_value)
  | Big_int value ->
    (match Int64.of_string_opt value with
     | Some value -> value_of_transit (Transit.Int64 value)
     | None -> diagnostic_error ~actual:"big-integer" Integer_value)
  | Date value -> Ok (Instant value)
  | Uuid value -> Ok (Uuid value)
  | Uri value -> Ok (String value)
  | Keyword value -> Ok (Keyword value)
  | Symbol value -> Ok (Symbol value)
  | Array values ->
    bind (map_all value_of_transit values) (fun values -> Ok (Vector values))
  | Map entries ->
    let decode_entry (key, value) =
      bind (value_of_transit key) (fun key ->
        bind (value_of_transit value) (fun value -> Ok (key, value)))
    in
    bind (map_all decode_entry entries) (fun entries -> Ok (Map entries))
  | Set values -> bind (map_all value_of_transit values) (fun values -> Ok (Set values))
  | List values -> bind (map_all value_of_transit values) (fun values -> Ok (List values))
  | Tagged ("u", Transit.String value) -> Ok (Uuid value)
  | Tagged ("m", value) -> bind (integer64 value) (fun value -> Ok (Instant value))
  | Tagged ("regex", Transit.String value) -> Ok (Regex value)
  | Tagged (tag, value) ->
    bind (value_of_transit value) (fun value -> Ok (Vector [ String tag; value ]))
;;

let entity_ref_of_transit ?(reason = Diagnostic.Entity_shape) = function
  | Transit.Int value -> Ok (Entity_id value)
  | Int64 value ->
    bind (integer (Transit.Int64 value)) (fun value -> Ok (Entity_id value))
  | String value when String.length value > 0 -> Ok (Temp_id value)
  | Keyword "db/current-tx" -> Ok CurrentTx
  | Keyword value -> Ok (Ident value)
  | Array [ Keyword attr; value ] ->
    bind (value_of_transit value) (fun value -> Ok (Lookup_ref (attr, value)))
  | value -> diagnostic_error ~actual:(transit_kind value) reason
;;

let schema_attr db attr = List.assoc_opt attr (Datascript.schema db)

let tx_value ~db ~attr value =
  match schema_attr db attr with
  | Some { Datascript.value_type = Some RefType; _ } ->
    bind (entity_ref_of_transit ~reason:Reference_shape value) (fun entity ->
      Ok (Ref_to entity))
  | None | Some _ -> value_of_transit value
;;

let valid_source_tx = function
  | Transit.Int _ -> Ok ()
  | Int64 value -> bind (integer (Transit.Int64 value)) (fun _ -> Ok ())
  | value ->
    diagnostic_error ~field:"source-tx" ~actual:(transit_kind value) Source_tx_type
;;

let plaintext_value attribute value plaintexts =
  if List.mem attribute protected_attributes
  then (
    match value, plaintexts with
    | Transit.String _, plaintext :: rest -> Ok (Transit.String plaintext, rest)
    | String _, [] -> diagnostic_error Decrypted_value_count
    | value, _ -> diagnostic_error ~actual:(transit_kind value) Protected_value_type)
  else Ok (value, plaintexts)
;;

let decode_add_or_retract ~db constructor fields plaintexts =
  match fields with
  | [ entity; Transit.Keyword attr; value ]
  | [ entity; Transit.Keyword attr; value; Transit.Int _ ]
  | [ entity; Transit.Keyword attr; value; Transit.Int64 _ ] ->
    bind
      (diagnostic_context ~field:"entity" (entity_ref_of_transit entity))
      (fun entity ->
         bind (plaintext_value attr value plaintexts) (fun (value, plaintexts) ->
           bind
             (diagnostic_context ~field:"value" (tx_value ~db ~attr value))
             (fun value -> Ok (constructor entity attr value, plaintexts))))
  | [ _; attribute; _; source_tx ] ->
    bind (valid_source_tx source_tx) (fun () ->
      diagnostic_error
        ~field:"attribute"
        ~actual:(transit_kind attribute)
        Operation_fields)
  | [ _; attribute; _ ] ->
    diagnostic_error ~field:"attribute" ~actual:(transit_kind attribute) Operation_fields
  | _ -> diagnostic_error Operation_fields
;;

let decode_operation ~db operation plaintexts =
  match operation with
  | Transit.Array (Keyword "db/add" :: fields) ->
    decode_add_or_retract
      ~db
      (fun entity attr value -> Add (entity, attr, value))
      fields
      plaintexts
  | Array (Keyword "db/retract" :: fields) ->
    decode_add_or_retract
      ~db
      (fun entity attr value -> Retract (entity, attr, Some value))
      fields
      plaintexts
  | Array
      [ Keyword ("db.fn/retractAttribute" | "db/retractAttribute"); entity; Keyword attr ]
    ->
    bind
      (diagnostic_context ~field:"entity" (entity_ref_of_transit entity))
      (fun entity -> Ok (RetractAttr (entity, attr), plaintexts))
  | Array [ Keyword "db/retractEntity"; entity ] ->
    bind
      (diagnostic_context ~field:"entity" (entity_ref_of_transit entity))
      (fun entity -> Ok (RetractEntity entity, plaintexts))
  | Array [ Keyword ("db.fn/cas" | "db/cas"); entity; Keyword attr; expected; value ] ->
    bind
      (diagnostic_context ~field:"entity" (entity_ref_of_transit entity))
      (fun entity ->
         bind
           (match expected with
            | Transit.Null -> Ok (None, plaintexts)
            | expected ->
              bind
                (diagnostic_context
                   ~field:"expected"
                   (plaintext_value attr expected plaintexts))
                (fun (expected, plaintexts) ->
                   bind
                     (diagnostic_context ~field:"expected" (tx_value ~db ~attr expected))
                     (fun expected -> Ok (Some expected, plaintexts))))
           (fun (expected, plaintexts) ->
              bind (plaintext_value attr value plaintexts) (fun (value, plaintexts) ->
                bind
                  (diagnostic_context ~field:"value" (tx_value ~db ~attr value))
                  (fun value ->
                     Ok (CompareAndSet (entity, attr, expected, value), plaintexts)))))
  | Array (Keyword operation :: _) ->
    diagnostic_error
      (if
         List.mem
           operation
           [ "db/add"
           ; "db/retract"
           ; "db.fn/cas"
           ; "db/cas"
           ; "db.fn/retractAttribute"
           ; "db/retractAttribute"
           ; "db/retractEntity"
           ]
       then Operation_fields
       else Unsupported_operation)
  | Array fields ->
    diagnostic_error
      ?actual:(List.nth_opt fields 0 |> Option.map transit_kind)
      Operation_keyword
  | value -> diagnostic_error ~actual:(transit_kind value) Operation_shape
;;

let parse ?(allow_empty = false) source =
  try
    match Codec.of_string source with
    | (Transit.Array [] | List []) when not allow_empty -> diagnostic_error Empty_transaction
    | Array operations | List operations -> Ok operations
    | value -> diagnostic_error ~actual:(transit_kind value) Transaction_shape
  with
  | Transit.Decode_error _ | Yojson.Json_error _ | Failure _ | Invalid_argument _ ->
    diagnostic_error Transit_syntax
;;

let protected_values ?(allow_empty = false) source =
  let value ?(field = "value") attribute value =
    if List.mem attribute protected_attributes
    then (
      match value with
      | Transit.String ciphertext -> Ok [ ciphertext ]
      | value -> diagnostic_error ~field ~actual:(transit_kind value) Protected_value_type)
    else Ok []
  in
  let operation = function
    | Transit.Array
        (Keyword ("db/add" | "db/retract") :: _entity :: Keyword attribute :: value_ :: _)
      -> value attribute value_
    | Array
        [ Keyword ("db.fn/cas" | "db/cas"); _entity; Keyword attribute; expected; value_ ]
      ->
      bind
        (match expected with
         | Transit.Null -> Ok []
         | expected -> value ~field:"expected" attribute expected)
        (fun expected ->
           bind (value attribute value_) (fun value -> Ok (expected @ value)))
    | Array [ Keyword ("db.fn/retractAttribute" | "db/retractAttribute"); _; Keyword _ ]
    | Array [ Keyword "db/retractEntity"; _ ] -> Ok []
    | Array (Keyword operation :: _) ->
      diagnostic_error
        (if
           List.mem
             operation
             [ "db/add"
             ; "db/retract"
             ; "db.fn/cas"
             ; "db/cas"
             ; "db.fn/retractAttribute"
             ; "db/retractAttribute"
             ; "db/retractEntity"
             ]
         then Operation_fields
         else Unsupported_operation)
    | Array fields ->
      diagnostic_error
        ?actual:(List.nth_opt fields 0 |> Option.map transit_kind)
        Operation_keyword
    | value -> diagnostic_error ~actual:(transit_kind value) Operation_shape
  in
  bind (parse ~allow_empty source) (fun operations ->
    let operation_count = List.length operations in
    let rec loop index values = function
      | [] -> Ok (List.concat (List.rev values))
      | operation_ :: rest ->
        bind
          (operation_context index operation_count operation_ (operation operation_))
          (fun current -> loop (index + 1) (current :: values) rest)
    in
    loop 1 [] operations)
;;

let decode ?(allow_empty = false) ~db ~decrypted_values source =
  bind (parse ~allow_empty source) (fun operations ->
    let operation_count = List.length operations in
    let rec loop index decoded plaintexts = function
      | [] ->
        if plaintexts = []
        then Ok (List.rev decoded)
        else diagnostic_error Decrypted_value_count
      | operation :: rest ->
        bind
          (operation_context
             index
             operation_count
             operation
             (decode_operation ~db operation plaintexts))
          (fun (operation, plaintexts) ->
             loop (index + 1) (operation :: decoded) plaintexts rest)
    in
    loop 1 [] decrypted_values operations)
;;

let inserted_orders source =
  bind (parse source) (fun operations ->
    let uuids = Hashtbl.create 16 in
    List.iter
      (function
        | Transit.Array [ Keyword "db/add"; entity; Keyword "block/uuid"; Uuid uuid ] ->
          Hashtbl.replace uuids entity uuid
        | _ -> ())
      operations;
    operations
    |> List.filter_map (function
      | Transit.Array [ Keyword "db/add"; entity; Keyword "block/order"; String order ] ->
        Some
          (match Hashtbl.find_opt uuids entity with
           | Some uuid -> Ok (uuid, order)
           | None -> Error "inserted order has no block UUID")
      | _ -> None)
    |> map_all Fun.id)
;;
