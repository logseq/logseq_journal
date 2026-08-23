module Transit = Transit_core.Json
open Datascript

let bind result f =
  match result with
  | Ok value -> f value
  | Error _ as error -> error
;;

let map_all f values =
  let rec loop decoded = function
    | [] -> Ok (List.rev decoded)
    | value :: rest -> bind (f value) (fun value -> loop (value :: decoded) rest)
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
  | Transit.Null -> Ok Datascript.Nil
  | Bool value -> Ok (Bool value)
  | String value -> Ok (String value)
  | Int value -> Ok (Int value)
  | Int64 value ->
    if
      Int64.compare value (Int64.of_int min_int) >= 0
      && Int64.compare value (Int64.of_int max_int) <= 0
    then Ok (Int (Int64.to_int value))
    else Error "Transit integer is outside the native DataScript range"
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
  | Date value ->
    if
      Int64.compare value (Int64.of_int min_int) >= 0
      && Int64.compare value (Int64.of_int max_int) <= 0
    then Ok (Instant (Int64.to_int value))
    else Error "Transit instant is outside the native DataScript range"
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
  | Transit.Int value -> Ok (Datascript.Entity_id value)
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
    bind (entity_ref_of_transit value) (fun entity -> Ok (Datascript.Ref_to entity))
  | None | Some _ -> value_of_transit value
;;

let valid_source_tx = function
  | Transit.Int _ -> Ok ()
  | Int64 value -> bind (integer (Transit.Int64 value)) (fun _ -> Ok ())
  | _ -> Error "normalized transaction source tx must be an integer"
;;

let decrypt_value decrypt_protected attr value =
  if List.mem attr Sync_e2ee.protected_attributes
  then (
    match value with
    | Transit.String ciphertext -> decrypt_protected ~attribute:attr ciphertext
    | _ -> Error "protected sync attributes must contain encrypted strings")
  else Ok value
;;

let decode_add_or_retract ~decrypt_protected ~db constructor = function
  | [ entity; Transit.Keyword attr; value ] ->
    bind (entity_ref_of_transit entity) (fun entity ->
      bind (decrypt_value decrypt_protected attr value) (fun value ->
        bind (tx_value ~db ~attr value) (fun value -> Ok (constructor entity attr value))))
  | [ entity; Transit.Keyword attr; value; source_tx ] ->
    bind (valid_source_tx source_tx) (fun () ->
      bind (entity_ref_of_transit entity) (fun entity ->
        bind (decrypt_value decrypt_protected attr value) (fun value ->
          bind (tx_value ~db ~attr value) (fun value ->
            Ok (constructor entity attr value)))))
  | _ -> Error "normalized add/retract operation has invalid fields"
;;

let decode_operation ~decrypt_protected ~db = function
  | Transit.Array (Keyword "db/add" :: fields) ->
    decode_add_or_retract
      ~decrypt_protected
      ~db
      (fun entity attr value -> Datascript.Add (entity, attr, value))
      fields
  | Array (Keyword "db/retract" :: fields) ->
    decode_add_or_retract
      ~decrypt_protected
      ~db
      (fun entity attr value -> Datascript.Retract (entity, attr, Some value))
      fields
  | Array
      [ Keyword ("db.fn/retractAttribute" | "db/retractAttribute"); entity; Keyword attr ]
    ->
    bind (entity_ref_of_transit entity) (fun entity ->
      Ok (Datascript.RetractAttr (entity, attr)))
  | Array [ Keyword "db/retractEntity"; entity ] ->
    bind (entity_ref_of_transit entity) (fun entity ->
      Ok (Datascript.RetractEntity entity))
  | Array [ Keyword ("db.fn/cas" | "db/cas"); entity; Keyword attr; expected; value ] ->
    bind (entity_ref_of_transit entity) (fun entity ->
      let expected =
        match expected with
        | Transit.Null -> Ok None
        | expected ->
          bind (decrypt_value decrypt_protected attr expected) (fun expected ->
            bind (tx_value ~db ~attr expected) (fun value -> Ok (Some value)))
      in
      bind expected (fun expected ->
        bind (decrypt_value decrypt_protected attr value) (fun value ->
          bind (tx_value ~db ~attr value) (fun value ->
            Ok (Datascript.CompareAndSet (entity, attr, expected, value))))))
  | Array (Keyword operation :: _) ->
    Error ("unsupported normalized transaction operation: " ^ operation)
  | Array _ -> Error "normalized transaction operation must start with a keyword"
  | _ -> Error "normalized transaction entries must be operation arrays"
;;

let decode
      ?(decrypt_protected = fun ~attribute:_ value -> Ok (Transit.String value))
      ~db
      source
  =
  try
    match Logseq_sqlite_codec.decode_transit source with
    | Error message -> Error ("invalid transaction Transit: " ^ message)
    | Ok (Transit.Array []) -> Error "normalized transaction must not be empty"
    | Ok (Array operations) ->
      map_all (decode_operation ~decrypt_protected ~db) operations
    | Ok _ -> Error "normalized transaction must be a Transit array"
  with
  | Transit.Decode_error message
  | Yojson.Json_error message
  | Failure message
  | Invalid_argument message -> Error ("invalid transaction Transit: " ^ message)
  | exn -> Error ("invalid transaction Transit: " ^ Printexc.to_string exn)
;;
