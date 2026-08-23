open Datascript
module Transit = Transit_core.Json
module Codec = Transit_native.Transit.Json

let lookup_value entity attr =
  match Datascript.Entity.entity_attr_raw entity attr with
  | Some (One_value value) -> Some value
  | _ -> None
;;

let stable_entity_ref db eid =
  match entity db (Entity_id eid) with
  | Some entity ->
    (match lookup_value entity "block/uuid", lookup_value entity "db/ident" with
     | Some (Uuid uuid), _ -> Lookup_ref ("block/uuid", Uuid uuid)
     | _, Some (Keyword ident) -> Lookup_ref ("db/ident", Keyword ident)
     | _ -> Entity_id eid)
  | None -> Entity_id eid
;;

let rec transit_of_entity_ref db = function
  | Entity_id eid ->
    (match stable_entity_ref db eid with
     | Entity_id stable_eid -> Transit.Int stable_eid
     | stable_ref -> transit_of_entity_ref db stable_ref)
  | Temp_id temp_id -> Transit.String temp_id
  | CurrentTx -> Transit.Keyword "db/current-tx"
  | Ident ident -> Transit.Keyword ident
  | Lookup_ref (attr, value) ->
    Transit.Array [ Transit.Keyword attr; transit_of_value db value ]

and transit_of_value db = function
  | Nil -> Transit.Null
  | Int value -> Transit.Int value
  | Float value -> Transit.Float value
  | String value -> Transit.String value
  | Symbol value -> Transit.Symbol value
  | Bool value -> Transit.Bool value
  | Keyword value -> Transit.Keyword value
  | Uuid value -> Transit.Uuid value
  | Instant value -> Transit.Date (Int64.of_int value)
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

let encrypt_value encrypt attr value =
  if List.mem attr Sync_e2ee.protected_attributes
  then (
    match value with
    | String plaintext ->
      Result.map (fun ciphertext -> String ciphertext) (encrypt plaintext)
    | _ -> Error ("protected attribute " ^ attr ^ " must be a string"))
  else Ok value
;;

let encrypt_tx_op encrypt = function
  | Add (entity_ref, attr, value) ->
    Result.map
      (fun value -> Add (entity_ref, attr, value))
      (encrypt_value encrypt attr value)
  | Retract (entity_ref, attr, Some value) ->
    Result.map
      (fun value -> Retract (entity_ref, attr, Some value))
      (encrypt_value encrypt attr value)
  | CompareAndSet (entity_ref, attr, expected, value) ->
    let expected =
      match expected with
      | None -> Ok None
      | Some value -> Result.map Option.some (encrypt_value encrypt attr value)
    in
    Result.bind expected (fun expected ->
      Result.map
        (fun value -> CompareAndSet (entity_ref, attr, expected, value))
        (encrypt_value encrypt attr value))
  | Raw_datom datom ->
    Result.map
      (fun value -> Raw_datom { datom with v = value })
      (encrypt_value encrypt datom.a datom.v)
  | Entity _ | CallIdent _ | InstallTxFn _ | Call _ ->
    Error "complex transaction forms cannot be sent over sync"
  | (Retract (_, _, None) | RetractAttr _ | RetractEntity _) as operation -> Ok operation
;;

let transit_of_tx_op db = function
  | Add (entity_ref, attr, value) ->
    Ok
      (Transit.Array
         [ Transit.Keyword "db/add"
         ; transit_of_entity_ref db entity_ref
         ; Transit.Keyword attr
         ; transit_of_value db value
         ])
  | Retract (entity_ref, attr, Some value) ->
    Ok
      (Transit.Array
         [ Transit.Keyword "db/retract"
         ; transit_of_entity_ref db entity_ref
         ; Transit.Keyword attr
         ; transit_of_value db value
         ])
  | Retract (entity_ref, attr, None) | RetractAttr (entity_ref, attr) ->
    Ok
      (Transit.Array
         [ Transit.Keyword "db.fn/retractAttribute"
         ; transit_of_entity_ref db entity_ref
         ; Transit.Keyword attr
         ])
  | RetractEntity entity_ref ->
    Ok
      (Transit.Array
         [ Transit.Keyword "db/retractEntity"; transit_of_entity_ref db entity_ref ])
  | CompareAndSet (entity_ref, attr, expected, value) ->
    Ok
      (Transit.Array
         [ Transit.Keyword "db.fn/cas"
         ; transit_of_entity_ref db entity_ref
         ; Transit.Keyword attr
         ; Option.fold ~none:Transit.Null ~some:(transit_of_value db) expected
         ; transit_of_value db value
         ])
  | Raw_datom datom ->
    Ok
      (Transit.Array
         [ Transit.Keyword (if datom.added then "db/add" else "db/retract")
         ; transit_of_entity_ref db (stable_entity_ref db datom.e)
         ; Transit.Keyword datom.a
         ; transit_of_value db datom.v
         ])
  | Entity _ | CallIdent _ | InstallTxFn _ | Call _ ->
    Error "complex transaction forms cannot be sent over sync"
;;

let encode ?(encrypt_protected = fun value -> Ok value) db tx =
  let rec loop encoded = function
    | [] -> Ok (List.rev encoded)
    | operation :: rest ->
      Result.bind (encrypt_tx_op encrypt_protected operation) (fun operation ->
        Result.bind (transit_of_tx_op db operation) (fun value ->
          loop (value :: encoded) rest))
  in
  Result.map
    (fun values -> Codec.to_string ~mode:Codec.Verbose (Transit.Array values))
    (loop [] tx)
;;
