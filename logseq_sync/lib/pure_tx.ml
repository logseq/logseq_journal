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

let integer = function
  | Transit.Int value -> Ok value
  | Int64 value
    when Int64.compare value (Int64.of_int min_int) >= 0
         && Int64.compare value (Int64.of_int max_int) <= 0 -> Ok (Int64.to_int value)
  | _ -> Error "expected a Transit integer"
;;

let rec value_of_transit = function
  | Transit.Null -> Ok Nil
  | Bool value -> Ok (Bool value)
  | String value -> Ok (String value)
  | Int value -> Ok (Int value)
  | Int64 value -> bind (integer (Transit.Int64 value)) (fun value -> Ok (Int value))
  | Float value -> Ok (Float value)
  | Binary value -> Ok (String value)
  | Big_decimal value ->
    (match float_of_string_opt value with
     | Some value -> Ok (Float value)
     | None -> Error "invalid Transit decimal")
  | Big_int value ->
    (match Int64.of_string_opt value with
     | Some value -> value_of_transit (Transit.Int64 value)
     | None -> Error "invalid Transit integer")
  | Date value -> bind (integer (Transit.Int64 value)) (fun value -> Ok (Instant value))
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
  | Tagged ("m", value) -> bind (integer value) (fun value -> Ok (Instant value))
  | Tagged ("regex", Transit.String value) -> Ok (Regex value)
  | Tagged (tag, value) ->
    bind (value_of_transit value) (fun value -> Ok (Vector [ String tag; value ]))
;;

let entity_ref_of_transit = function
  | Transit.Int value -> Ok (Entity_id value)
  | Int64 value ->
    bind (integer (Transit.Int64 value)) (fun value -> Ok (Entity_id value))
  | String value when String.length value > 0 -> Ok (Temp_id value)
  | Keyword "db/current-tx" -> Ok CurrentTx
  | Keyword value -> Ok (Ident value)
  | Array [ Keyword attr; value ] ->
    bind (value_of_transit value) (fun value -> Ok (Lookup_ref (attr, value)))
  | _ -> Error "transaction entity must be an eid, tempid, ident, or lookup ref"
;;

let schema_attr db attr =
  let serializable = Datascript.serializable db in
  List.assoc_opt attr serializable.serializable_schema
;;

let tx_value ~db ~attr value =
  match schema_attr db attr with
  | Some { Datascript.value_type = Some RefType; _ } ->
    bind (entity_ref_of_transit value) (fun entity -> Ok (Ref_to entity))
  | None | Some _ -> value_of_transit value
;;

let valid_source_tx = function
  | Transit.Int _ -> Ok ()
  | Int64 value -> bind (integer (Transit.Int64 value)) (fun _ -> Ok ())
  | _ -> Error "normalized transaction source tx must be an integer"
;;

let plaintext_value attribute value plaintexts =
  if List.mem attribute protected_attributes
  then (
    match value, plaintexts with
    | Transit.String _, plaintext :: rest ->
      (try Ok (Codec.of_string plaintext, rest) with
       | Transit.Decode_error message -> Error message)
    | String _, [] -> Error "decrypted value count does not match protected values"
    | _, _ -> Error "protected sync attributes must contain strings")
  else Ok (value, plaintexts)
;;

let decode_add_or_retract ~db constructor fields plaintexts =
  match fields with
  | [ entity; Transit.Keyword attr; value ]
  | [ entity; Transit.Keyword attr; value; Transit.Int _ ]
  | [ entity; Transit.Keyword attr; value; Transit.Int64 _ ] ->
    bind (entity_ref_of_transit entity) (fun entity ->
      bind (plaintext_value attr value plaintexts) (fun (value, plaintexts) ->
        bind (tx_value ~db ~attr value) (fun value ->
          Ok (constructor entity attr value, plaintexts))))
  | [ _; _; _; source_tx ] ->
    bind (valid_source_tx source_tx) (fun () ->
      Error "normalized add/retract operation has invalid fields")
  | _ -> Error "normalized add/retract operation has invalid fields"
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
    bind (entity_ref_of_transit entity) (fun entity ->
      Ok (RetractAttr (entity, attr), plaintexts))
  | Array [ Keyword "db/retractEntity"; entity ] ->
    bind (entity_ref_of_transit entity) (fun entity ->
      Ok (RetractEntity entity, plaintexts))
  | Array [ Keyword ("db.fn/cas" | "db/cas"); entity; Keyword attr; expected; value ] ->
    bind (entity_ref_of_transit entity) (fun entity ->
      bind
        (match expected with
         | Transit.Null -> Ok (None, plaintexts)
         | expected ->
           bind (plaintext_value attr expected plaintexts) (fun (expected, plaintexts) ->
             bind (tx_value ~db ~attr expected) (fun expected ->
               Ok (Some expected, plaintexts))))
        (fun (expected, plaintexts) ->
           bind (plaintext_value attr value plaintexts) (fun (value, plaintexts) ->
             bind (tx_value ~db ~attr value) (fun value ->
               Ok (CompareAndSet (entity, attr, expected, value), plaintexts)))))
  | Array (Keyword operation :: _) ->
    Error ("unsupported normalized transaction operation: " ^ operation)
  | Array _ -> Error "normalized transaction operation must start with a keyword"
  | _ -> Error "normalized transaction entries must be operation arrays"
;;

let parse source =
  try
    match Codec.of_string source with
    | Transit.Array [] -> Error "normalized transaction must not be empty"
    | Array operations -> Ok operations
    | _ -> Error "normalized transaction must be a Transit array"
  with
  | Transit.Decode_error message
  | Yojson.Json_error message
  | Failure message
  | Invalid_argument message -> Error ("invalid transaction Transit: " ^ message)
;;

let protected_values source =
  let value attribute value =
    if List.mem attribute protected_attributes
    then (
      match value with
      | Transit.String ciphertext -> Ok [ ciphertext ]
      | _ -> Error "protected sync attributes must contain encrypted strings")
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
         | expected -> value attribute expected)
        (fun expected ->
           bind (value attribute value_) (fun value -> Ok (expected @ value)))
    | Array [ Keyword ("db.fn/retractAttribute" | "db/retractAttribute"); _; Keyword _ ]
    | Array [ Keyword "db/retractEntity"; _ ] -> Ok []
    | Array (Keyword operation :: _) ->
      Error ("unsupported normalized transaction operation: " ^ operation)
    | Array _ -> Error "normalized transaction operation must start with a keyword"
    | _ -> Error "normalized transaction entries must be operation arrays"
  in
  bind (parse source) (fun operations ->
    let rec loop values = function
      | [] -> Ok (List.concat (List.rev values))
      | operation_ :: rest ->
        bind (operation operation_) (fun current -> loop (current :: values) rest)
    in
    loop [] operations)
;;

let decode ~db ~decrypted_values source =
  bind (parse source) (fun operations ->
    let rec loop decoded plaintexts = function
      | [] ->
        if plaintexts = []
        then Ok (List.rev decoded)
        else Error "decrypted value count does not match protected values"
      | operation :: rest ->
        bind (decode_operation ~db operation plaintexts) (fun (operation, plaintexts) ->
          loop (operation :: decoded) plaintexts rest)
    in
    loop [] decrypted_values operations)
;;
