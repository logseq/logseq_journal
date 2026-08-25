open Graph_types
include Planner_contract
open Graph_read

type property =
  { entity : int
  ; uuid : Uuid.t
  ; ident : string
  ; schema : property_schema
  ; built_in : bool
  }

type resolved_value =
  { tx_value : Datascript.value
  ; stored_value : Datascript.value
  ; tx_ops : Datascript.tx_op list
  ; created_uuid : Uuid.t option
  }

let one db entity attr =
  match values db entity attr with
  | [] -> Ok None
  | [ value ] -> Ok (Some value)
  | _ -> Error (Invalid_selection ("Entity has multiple values for " ^ attr ^ "."))
;;

let require_uuid db entity =
  match one db entity "block/uuid" with
  | Ok (Some (Datascript.Uuid value)) ->
    (match Uuid.of_string value with
     | Ok value -> Ok value
     | Error _ -> Error (Invalid_selection "Entity has an invalid block UUID."))
  | Ok None | Ok (Some _) | Error _ ->
    Error (Invalid_selection "Entity has no valid block UUID.")
;;

let entity_of_uuid db uuid =
  match
    Datascript.datoms
      db
      Datascript.Avet
      ~a:"block/uuid"
      ~v:(Datascript.Uuid (Uuid.to_string uuid))
      ()
    |> List.of_seq
  with
  | [ datom ] -> Ok datom.Datascript.e
  | [] -> Error (Invalid_selection "UUID selector did not resolve.")
  | _ -> Error (Invalid_selection "UUID selector is ambiguous.")
;;

let entity_of_ident db ident =
  let matches value =
    Datascript.datoms db Datascript.Avet ~a:"db/ident" ~v:value () |> List.of_seq
  in
  match
    matches (Datascript.Keyword ident) @ matches (Datascript.String ident)
    |> List.map (fun datom -> datom.Datascript.e)
    |> List.sort_uniq Int.compare
  with
  | [ entity ] -> Ok entity
  | [] -> Error (Invalid_selection ("Property ident did not resolve: " ^ ident))
  | _ -> Error (Invalid_selection ("Property ident is ambiguous: " ^ ident))
;;

let has_ident db entity ident =
  List.exists
    (function
      | Datascript.Keyword value | String value -> String.equal value ident
      | _ -> false)
    (values db entity "db/ident")
;;

let has_tag_ident db entity ident =
  List.exists
    (function
      | Datascript.Ref tag -> has_ident db tag ident
      | _ -> false)
    (values db entity "block/tags")
;;

let bool_value db entity attr =
  match values db entity attr with
  | [ Datascript.Bool value ] -> value
  | [] | _ -> false
;;

let qualified_ident ident =
  match String.index_opt ident '/' with
  | Some index -> index > 0 && index + 1 < String.length ident
  | None -> false
;;

let property_ident ident =
  List.exists
    (fun prefix -> String.starts_with ~prefix ident)
    [ "user.property/"; "plugin.property."; "logseq.property/"; "block/" ]
;;

let property_type_of_string = function
  | "default" -> Default
  | "number" -> Number
  | "date" -> Date
  | "datetime" -> Datetime
  | "checkbox" -> Checkbox
  | "url" -> Url
  | "node" -> Node
  | "asset" -> Asset
  | "keyword" -> Keyword
  | "map" -> Map
  | "coll" -> Collection
  | "any" -> Any
  | "entity" -> Entity
  | "class" -> Class
  | "page" -> Page
  | "property" -> Property
  | "string" -> String
  | "json" -> Json
  | "raw-number" -> Raw_number
  | _ -> Default
;;

let string_of_property_type = function
  | Default -> "default"
  | Number -> "number"
  | Date -> "date"
  | Datetime -> "datetime"
  | Checkbox -> "checkbox"
  | Url -> "url"
  | Node -> "node"
  | Asset -> "asset"
  | Keyword -> "keyword"
  | Map -> "map"
  | Collection -> "coll"
  | Any -> "any"
  | Entity -> "entity"
  | Class -> "class"
  | Page -> "page"
  | Property -> "property"
  | String -> "string"
  | Json -> "json"
  | Raw_number -> "raw-number"
;;

let property_type db entity =
  match values db entity "logseq.property/type" with
  | [] -> Default
  | [ (Datascript.Keyword value | String value) ] -> property_type_of_string value
  | _ -> Default
;;

let cardinality db entity ident =
  match values db entity "db/cardinality" with
  | [ Datascript.Keyword "db.cardinality/many" ] -> Many
  | [ Datascript.Keyword "db.cardinality/one" ] -> One
  | [] ->
    (match List.assoc_opt ident (Datascript.serializable db).serializable_schema with
     | Some { Datascript.cardinality = Many; _ } -> Many
     | Some _ | None -> One)
  | _ -> One
;;

let resolve_property_entity db entity =
  match require_uuid db entity, one db entity "db/ident" with
  | Ok uuid, Ok (Some (Datascript.Keyword ident | String ident))
    when qualified_ident ident
         && (property_ident ident || has_tag_ident db entity "logseq.class/Property") ->
    Ok
      { entity
      ; uuid
      ; ident
      ; schema =
          { property_type = property_type db entity
          ; cardinality = cardinality db entity ident
          ; hidden = bool_value db entity "logseq.property/hide?"
          ; public = bool_value db entity "logseq.property/public?"
          }
      ; built_in = bool_value db entity "logseq.property/built-in?"
      }
  | Ok _, Ok (Some (Datascript.Keyword ident | String ident))
    when String.equal ident "logseq.property/status" ->
    (match require_uuid db entity with
     | Error _ as error -> error
     | Ok uuid ->
       Ok
         { entity
         ; uuid
         ; ident
         ; schema =
             { property_type = property_type db entity
             ; cardinality = cardinality db entity ident
             ; hidden = false
             ; public = true
             }
         ; built_in = true
         })
  | _ -> Error (Invalid_selection "Selector does not identify a property.")
;;

let resolve_property db = function
  | Property_by_ident ident ->
    if not (qualified_ident ident)
    then Error (Invalid_selection "Property ident must be qualified.")
    else Result.bind (entity_of_ident db ident) (resolve_property_entity db)
  | Property_by_uuid uuid ->
    Result.bind (entity_of_uuid db uuid) (resolve_property_entity db)
;;

let tx_meta context operation =
  [ "db-sync/tx-id", Datascript.Uuid (Uuid.to_string context.Protocol.mutation_id)
  ; "outliner-op", Datascript.Keyword operation
  ; "local-tx?", Datascript.Bool true
  ]
;;

let unique_uuids values = List.sort_uniq Uuid.compare values

let plan_result context operation tx_ops changed_uuids =
  { tx_ops
  ; tx_meta = tx_meta context operation
  ; changed_uuids = unique_uuids changed_uuids
  ; status = (if tx_ops = [] then Protocol.No_change else Applied)
  }
;;

let parse_number value =
  match float_of_string_opt value with
  | Some value -> Ok (Datascript.Float value)
  | None -> Error (Invalid_selection "Property number is invalid.")
;;

let rec datascript_internal_value = function
  | Internal_null -> Ok Datascript.Nil
  | Internal_bool value -> Ok (Datascript.Bool value)
  | Internal_number value -> parse_number value
  | Internal_string value -> Ok (Datascript.String value)
  | Internal_keyword value ->
    if qualified_ident value
    then Ok (Datascript.Keyword value)
    else Error (Invalid_selection "Internal keyword must be qualified.")
  | Internal_uuid value -> Ok (Datascript.Uuid (Uuid.to_string value))
  | Internal_list values ->
    let rec collect acc = function
      | [] -> Ok (Datascript.Vector (List.rev acc))
      | value :: rest ->
        (match datascript_internal_value value with
         | Error _ as error -> error
         | Ok value -> collect (value :: acc) rest)
    in
    collect [] values
  | Internal_map entries ->
    let rec collect acc = function
      | [] -> Ok (Datascript.Map (List.rev acc))
      | (key, value) :: rest ->
        (match datascript_internal_value key, datascript_internal_value value with
         | Ok key, Ok value -> collect ((key, value) :: acc) rest
         | (Error _ as error), _ | _, (Error _ as error) -> error)
    in
    collect [] entries
;;

let normalize_title title = String.trim title

let java_string_hash text =
  let value = ref Int32.zero in
  String.iter
    (fun character ->
       value
       := Int32.add
            (Int32.mul !value (Int32.of_int 31))
            (Int32.of_int (Char.code character)))
    text;
  !value
;;

let rotate_left value bits =
  Int32.logor (Int32.shift_left value bits) (Int32.shift_right_logical value (32 - bits))
;;

let murmur_mix_k1 value =
  value
  |> fun value ->
  Int32.mul value (Int32.of_int (-862048943))
  |> fun value ->
  rotate_left value 15 |> fun value -> Int32.mul value (Int32.of_int 461845907)
;;

let murmur_mix_h1 hash value =
  Int32.logxor hash value
  |> fun hash ->
  rotate_left hash 13
  |> fun hash -> Int32.add (Int32.mul hash (Int32.of_int 5)) (Int32.of_int (-430675100))
;;

let murmur_fmix hash length =
  Int32.logxor hash (Int32.of_int length)
  |> fun hash ->
  Int32.logxor hash (Int32.shift_right_logical hash 16)
  |> fun hash ->
  Int32.mul hash (Int32.of_int (-2048144789))
  |> fun hash ->
  Int32.logxor hash (Int32.shift_right_logical hash 13)
  |> fun hash ->
  Int32.mul hash (Int32.of_int (-1028477387))
  |> fun hash ->
  Int32.logxor hash (Int32.shift_right_logical hash 16)
  |> fun hash -> hash
;;

let murmur3_hash_unencoded_chars text =
  let hash = ref Int32.zero in
  let index = ref 1 in
  while !index < String.length text do
    let code = Char.code text.[!index - 1] lor (Char.code text.[!index] lsl 16) in
    hash := murmur_mix_h1 !hash (murmur_mix_k1 (Int32.of_int code));
    index := !index + 2
  done;
  if String.length text land 1 = 1
  then
    hash
    := Int32.logxor
         !hash
         (murmur_mix_k1 (Int32.of_int (Char.code text.[String.length text - 1])));
  murmur_fmix !hash (2 * String.length text)
;;

let hash_combine seed hash =
  Int32.logxor
    seed
    (Int32.add
       (Int32.add hash (Int32.of_int (-1640531527)))
       (Int32.add (Int32.shift_left seed 6) (Int32.shift_right seed 2)))
;;

let property_uuid ident =
  let namespace, name = Datascript.Util.split_keyword ident in
  let namespace_hash =
    if String.equal namespace "" then Int32.zero else java_string_hash namespace
  in
  let symbol_hash = hash_combine (murmur3_hash_unencoded_chars name) namespace_hash in
  let keyword_hash = Int32.add symbol_hash (Int32.of_int (-1640531527)) in
  let hash_number = Int64.abs (Int64.of_int32 keyword_hash) |> Int64.to_string in
  let padded_part start length =
    let available = max 0 (min length (String.length hash_number - start)) in
    let value = if available = 0 then "" else String.sub hash_number start available in
    value ^ String.make (length - available) '0'
  in
  let uuid =
    "00000002-"
    ^ padded_part 0 4
    ^ "-"
    ^ padded_part 4 4
    ^ "-"
    ^ padded_part 8 4
    ^ "-"
    ^ padded_part 12 12
  in
  match Uuid.of_string uuid with
  | Ok uuid -> uuid
  | Error message -> invalid_arg message
;;

let derived_value_uuid context block ident ordinal content =
  let seed =
    String.concat
      "\000"
      [ Uuid.to_string context.Protocol.mutation_id
      ; Uuid.to_string block
      ; ident
      ; string_of_int ordinal
      ; Marshal.to_string content [ Marshal.No_sharing ]
      ]
  in
  let hex = Digestif.SHA256.(to_hex (digest_string seed)) in
  let bytes = Bytes.of_string (String.sub hex 0 32) in
  Bytes.set bytes 12 '4';
  Bytes.set bytes 16 '8';
  let raw = Bytes.to_string bytes in
  let value =
    String.sub raw 0 8
    ^ "-"
    ^ String.sub raw 8 4
    ^ "-"
    ^ String.sub raw 12 4
    ^ "-"
    ^ String.sub raw 16 4
    ^ "-"
    ^ String.sub raw 20 12
  in
  match Uuid.of_string value with
  | Ok value -> value
  | Error message -> invalid_arg message
;;

let ref_property_type = function
  | Default | Number | Date | Url | Node | Asset | Entity | Class | Page | Property ->
    true
  | Datetime | Checkbox | Keyword | Map | Collection | Any | String | Json | Raw_number ->
    false
;;

let closed_value_type = function
  | Default | Number | Url -> true
  | Date
  | Datetime
  | Checkbox
  | Node
  | Asset
  | Keyword
  | Map
  | Collection
  | Any
  | Entity
  | Class
  | Page
  | Property
  | String
  | Json
  | Raw_number -> false
;;

let value_content_attr = function
  | Number -> "logseq.property/value"
  | _ -> "block/title"
;;

let matching_value_entity db property content_attr content =
  Datascript.datoms
    db
    Datascript.Avet
    ~a:"logseq.property/created-from-property"
    ~v:(Datascript.Ref property.entity)
    ()
  |> List.of_seq
  |> List.find_map (fun datom ->
    let entity = datom.Datascript.e in
    if List.exists (Datascript.Util.value_equal content) (values db entity content_attr)
    then Some entity
    else None)
;;

let closed_value_entity db property content_attr content =
  Datascript.datoms
    db
    Datascript.Avet
    ~a:"block/closed-value-property"
    ~v:(Datascript.Ref property.entity)
    ()
  |> List.of_seq
  |> List.find_map (fun datom ->
    let entity = datom.Datascript.e in
    if List.exists (Datascript.Util.value_equal content) (values db entity content_attr)
    then Some entity
    else None)
;;

let created_value ~now_ms db context block_uuid block_entity property ordinal content =
  let content_attr = value_content_attr property.schema.property_type in
  match closed_value_entity db property content_attr content with
  | Some entity ->
    Ok
      { tx_value = Datascript.Ref_to (Entity_id entity)
      ; stored_value = Datascript.Ref entity
      ; tx_ops = []
      ; created_uuid = None
      }
  | None ->
    if
      Datascript.datoms
        db
        Datascript.Avet
        ~a:"block/closed-value-property"
        ~v:(Datascript.Ref property.entity)
        ()
      |> Seq.is_empty
      |> not
    then Error (Invalid_selection "Property value is not one of the closed values.")
    else (
      match matching_value_entity db property content_attr content with
      | Some entity ->
        Ok
          { tx_value = Datascript.Ref_to (Entity_id entity)
          ; stored_value = Datascript.Ref entity
          ; tx_ops = []
          ; created_uuid = None
          }
      | None ->
        let uuid = derived_value_uuid context block_uuid property.ident ordinal content in
        let temp = Datascript.Temp_id ("property-value-" ^ Uuid.to_string uuid) in
        let page_entity =
          match values db block_entity "block/page" with
          | [ Datascript.Ref page ] -> page
          | _ -> block_entity
        in
        Ok
          { tx_value = Datascript.Ref_to temp
          ; stored_value = Datascript.Ref_to temp
          ; tx_ops =
              [ Datascript.Add (temp, "block/uuid", Uuid (Uuid.to_string uuid))
              ; Add (temp, "block/parent", Ref_to (Entity_id block_entity))
              ; Add (temp, "block/page", Ref_to (Entity_id page_entity))
              ; Add (temp, "block/order", String ("a" ^ string_of_int ordinal))
              ; Add
                  ( temp
                  , "logseq.property/created-from-property"
                  , Ref_to (Entity_id property.entity) )
              ; Add (temp, content_attr, content)
              ; Add (temp, "block/created-at", Int (Int64.to_int now_ms))
              ; Add (temp, "block/updated-at", Int (Int64.to_int now_ms))
              ]
          ; created_uuid = Some uuid
          })
;;

let require_kind db entity property_type =
  match property_type with
  | Class when not (has_tag_ident db entity "logseq.class/Tag") ->
    Error (Invalid_selection "Class property value is not a class.")
  | Page when not (has_tag_ident db entity "logseq.class/Page") ->
    Error (Invalid_selection "Page property value is not a page.")
  | Property when not (has_tag_ident db entity "logseq.class/Property") ->
    Error (Invalid_selection "Property value is not a property.")
  | Asset when not (has_tag_ident db entity "logseq.class/Asset") ->
    Error (Invalid_selection "Asset property value is not an asset.")
  | _ -> Ok ()
;;

let resolved_ref entity =
  { tx_value = Datascript.Ref_to (Entity_id entity)
  ; stored_value = Datascript.Ref entity
  ; tx_ops = []
  ; created_uuid = None
  }
;;

let resolve_value ~now_ms db context block_uuid block_entity property ordinal value =
  let scalar value =
    Ok { tx_value = value; stored_value = value; tx_ops = []; created_uuid = None }
  in
  let entity_value uuid property_type =
    match entity_of_uuid db uuid with
    | Error _ as error -> error
    | Ok entity ->
      if entity = block_entity
      then Error (Conflict "A block cannot reference itself as its property value.")
      else
        Result.map (fun () -> resolved_ref entity) (require_kind db entity property_type)
  in
  match property.schema.property_type, value with
  | Default, Default_value value ->
    created_value
      ~now_ms
      db
      context
      block_uuid
      block_entity
      property
      ordinal
      (Datascript.String value)
  | Number, Number_value value ->
    Result.bind (parse_number value) (fun number ->
      created_value ~now_ms db context block_uuid block_entity property ordinal number)
  | Date, Date_value { journal_day } ->
    (match
       Datascript.datoms
         db
         Datascript.Avet
         ~a:"block/journal-day"
         ~v:(Datascript.Int journal_day)
         ()
       |> List.of_seq
     with
     | [ datom ] -> Ok (resolved_ref datom.Datascript.e)
     | [] -> Error (Invalid_selection "Date value journal does not exist.")
     | _ -> Error (Invalid_selection "Date value journal is ambiguous."))
  | Datetime, Datetime_value { unix_ms } -> scalar (Datascript.Int (Int64.to_int unix_ms))
  | Checkbox, Checkbox_value value -> scalar (Datascript.Bool value)
  | Url, Url_value value ->
    if not (String.contains value ':')
    then Error (Invalid_selection "URL value is invalid.")
    else
      created_value
        ~now_ms
        db
        context
        block_uuid
        block_entity
        property
        ordinal
        (Datascript.String value)
  | Node, Node_value uuid -> entity_value uuid Node
  | Asset, Asset_value uuid -> entity_value uuid Asset
  | Keyword, Keyword_value value ->
    if qualified_ident value
    then scalar (Datascript.Keyword value)
    else Error (Invalid_selection "Keyword property value must be qualified.")
  | Map, Map_value value ->
    datascript_internal_value (Internal_map value)
    |> Result.map (fun value ->
      { tx_value = value; stored_value = value; tx_ops = []; created_uuid = None })
  | Collection, Collection_value value ->
    datascript_internal_value (Internal_list value)
    |> Result.map (fun value ->
      { tx_value = value; stored_value = value; tx_ops = []; created_uuid = None })
  | Any, Any_value value ->
    datascript_internal_value value
    |> Result.map (fun value ->
      { tx_value = value; stored_value = value; tx_ops = []; created_uuid = None })
  | Entity, Entity_value uuid -> entity_value uuid Entity
  | Class, Class_value uuid -> entity_value uuid Class
  | Page, Page_value uuid -> entity_value uuid Page
  | Property, Property_value ident -> Result.map resolved_ref (entity_of_ident db ident)
  | String, String_value value -> scalar (Datascript.String value)
  | Json, Json_value value ->
    (try
       ignore (Yojson.Safe.from_string value);
       scalar (Datascript.String value)
     with
     | Yojson.Json_error _ -> Error (Invalid_selection "JSON property value is invalid."))
  | Raw_number, Raw_number_value value -> Result.bind (parse_number value) scalar
  | _, _ ->
    Error (Invalid_selection "Typed property value does not match the property schema.")
;;

let equal_stored_value left right =
  match left, right with
  | Datascript.Ref_to (Entity_id left), Datascript.Ref right
  | Datascript.Ref left, Datascript.Ref_to (Entity_id right) -> left = right
  | _ -> Datascript.Util.value_equal left right
;;

let ref_entity = function
  | Datascript.Ref entity | Ref_to (Entity_id entity) -> Some entity
  | _ -> None
;;

let reference_is_used_elsewhere db target attr value_entity =
  Datascript.datoms db Datascript.Avet ~a:attr ~v:(Datascript.Ref value_entity) ()
  |> Seq.exists (fun datom -> datom.Datascript.e <> target)
;;

let generated_value db property entity =
  List.exists
    (function
      | Datascript.Ref source -> source = property.entity
      | _ -> false)
    (values db entity "logseq.property/created-from-property")
  && (not (has_tag_ident db entity "logseq.class/Page"))
  && values db entity "block/closed-value-property" = []
;;

let next_tx db = (Datascript.serializable db).serializable_max_tx + 1

let touch_ops ~now_ms db entity =
  [ Datascript.Add (Entity_id entity, "block/updated-at", Int (Int64.to_int now_ms))
  ; Add (Entity_id entity, "block/tx-id", Int (next_tx db))
  ]
;;

let property_reference_source property =
  (String.starts_with ~prefix:"user.property/" property.ident
   && not property.schema.hidden)
  || List.mem
       property.ident
       [ "logseq.property/scheduled"; "logseq.property/deadline" ]
;;

let add_property_refs block property resolved =
  if not (property_reference_source property)
  then []
  else
    Datascript.Add
      (Entity_id block, "block/refs", Ref_to (Entity_id property.entity))
    ::
    match ref_entity resolved.stored_value with
    | Some entity when entity <> block ->
      [ Datascript.Add (Entity_id block, "block/refs", Ref_to (Entity_id entity)) ]
    | Some _ | None -> []
;;

let retract_property_refs block property existing =
  if not (property_reference_source property)
  then []
  else
    Datascript.Retract
      ( Entity_id block
      , "block/refs"
      , Some (Ref_to (Entity_id property.entity)) )
    :: (existing
        |> List.filter_map ref_entity
        |> List.sort_uniq Int.compare
        |> List.map (fun entity ->
          Datascript.Retract
            (Entity_id block, "block/refs", Some (Ref_to (Entity_id entity)))))
;;

let set_ops ~now_ms db block property resolved =
  let existing = values db block property.ident in
  let already_present = List.exists (equal_stored_value resolved.stored_value) existing in
  match property.schema.cardinality with
  | One
    when existing = [ resolved.stored_value ]
         || (already_present && List.length existing = 1) -> [], []
  | One ->
    ( resolved.tx_ops
      @ [ Datascript.RetractAttr (Entity_id block, property.ident)
        ; Add (Entity_id block, property.ident, resolved.tx_value)
        ]
      @ retract_property_refs block property existing
      @ add_property_refs block property resolved
      @ touch_ops ~now_ms db block
    , Option.to_list resolved.created_uuid )
  | Many when already_present -> [], []
  | Many ->
    let placeholder =
      match entity_of_ident db "logseq.property/empty-placeholder" with
      | Ok placeholder ->
        [ Datascript.Retract
            (Entity_id block, property.ident, Some (Ref_to (Entity_id placeholder)))
        ]
      | Error _ -> []
    in
    ( resolved.tx_ops
      @ placeholder
      @ [ Datascript.Add (Entity_id block, property.ident, resolved.tx_value) ]
      @ add_property_refs block property resolved
      @ touch_ops ~now_ms db block
    , Option.to_list resolved.created_uuid )
;;

let plan_set ~now_ms db block_uuid selector value context =
  match entity_of_uuid db block_uuid, resolve_property db selector with
  | (Error _ as error), _ | _, (Error _ as error) -> error
  | Ok block, Ok property ->
    (match resolve_value ~now_ms db context block_uuid block property 0 value with
     | Error _ as error -> error
     | Ok resolved ->
       let tx_ops, created = set_ops ~now_ms db block property resolved in
       Ok
         (plan_result
            context
            "set-block-property"
            tx_ops
            (block_uuid :: property.uuid :: created)))
;;

let inbound_ref_retractions db entity =
  Datascript.serializable db
  |> fun snapshot ->
  snapshot.serializable_datoms
  |> List.filter_map (fun datom ->
    match datom.Datascript.v with
    | Datascript.Ref target when target = entity ->
      Some
        (Datascript.Retract
           (Entity_id datom.e, datom.a, Some (Datascript.Ref_to (Entity_id entity))))
    | _ -> None)
;;

let remove_generated_values db block property existing =
  existing
  |> List.filter_map ref_entity
  |> List.filter (fun entity ->
    generated_value db property entity
    && not (reference_is_used_elsewhere db block property.ident entity))
  |> List.concat_map (fun entity ->
    inbound_ref_retractions db entity @ [ Datascript.RetractEntity (Entity_id entity) ])
;;

let plan_remove ~now_ms db block_uuid selector context =
  match entity_of_uuid db block_uuid, resolve_property db selector with
  | (Error _ as error), _ | _, (Error _ as error) -> error
  | Ok block, Ok property ->
    let existing = values db block property.ident in
    if existing = []
    then Ok (plan_result context "remove-block-property" [] [])
    else if String.equal property.ident "logseq.property/status"
    then (
      let task = entity_of_ident db "logseq.class/Task" in
      let tx_ops =
        [ Datascript.RetractAttr (Entity_id block, property.ident)
        ]
        @ retract_property_refs block property existing
        @ touch_ops ~now_ms db block
        @
        match task with
        | Ok task ->
          [ Datascript.Retract
              (Entity_id block, "block/tags", Some (Ref_to (Entity_id task)))
          ]
        | Error _ -> []
      in
      Ok
        (plan_result context "remove-block-property" tx_ops [ block_uuid; property.uuid ]))
    else (
      let replacement =
        match values db property.entity "logseq.property/default-value" with
        | [ default ] when List.exists (equal_stored_value default) existing ->
          (match entity_of_ident db "logseq.property/empty-placeholder" with
           | Ok placeholder ->
             [ Datascript.RetractAttr (Entity_id block, property.ident)
             ; Add (Entity_id block, property.ident, Ref_to (Entity_id placeholder))
             ]
           | Error _ -> [ Datascript.RetractAttr (Entity_id block, property.ident) ])
        | _ when String.equal property.ident "logseq.property.class/extends" ->
          (match entity_of_ident db "logseq.class/Root" with
           | Ok root ->
             [ Datascript.RetractAttr (Entity_id block, property.ident)
             ; Add (Entity_id block, property.ident, Ref_to (Entity_id root))
             ]
           | Error _ -> [ Datascript.RetractAttr (Entity_id block, property.ident) ])
        | _ -> [ Datascript.RetractAttr (Entity_id block, property.ident) ]
      in
      let cleanup = remove_generated_values db block property existing in
      let tx_ops =
        replacement
        @ cleanup
        @ retract_property_refs block property existing
        @ touch_ops ~now_ms db block
      in
      Ok
        (plan_result context "remove-block-property" tx_ops [ block_uuid; property.uuid ]))
;;

let ensure_unique_blocks blocks =
  if blocks = []
  then Error (Invalid_selection "Batch property selection must not be empty.")
  else if List.length blocks <> List.length (List.sort_uniq Uuid.compare blocks)
  then Error (Invalid_selection "Batch property selection contains duplicate UUIDs.")
  else Ok ()
;;

let resolve_blocks db blocks =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | uuid :: rest ->
      (match entity_of_uuid db uuid with
       | Error _ -> Error (Invalid_selection "Batch property target did not resolve.")
       | Ok entity -> loop ((uuid, entity) :: acc) rest)
  in
  loop [] blocks
;;

let plan_batch_set ~now_ms db blocks selector mode context =
  match ensure_unique_blocks blocks, resolve_property db selector with
  | (Error _ as error), _ | _, (Error _ as error) -> error
  | Ok (), Ok property ->
    (match resolve_blocks db blocks with
     | Error _ as error -> error
     | Ok targets ->
       let input_values, replace =
         match mode with
         | Protocol.Append value -> [ value ], false
         | Replace values -> values, true
       in
       if List.length input_values > Protocol.maximum_property_values
       then Error (Invalid_selection "Property value count exceeds the protocol limit.")
       else if property.schema.cardinality = One && List.length input_values > 1
       then
         Error (Invalid_selection "One-valued property cannot receive multiple values.")
       else (
         let rec resolve_targets ordinal acc_ops acc_uuids = function
           | [] -> Ok (List.rev acc_ops |> List.concat, List.rev acc_uuids |> List.concat)
           | (block_uuid, block) :: rest ->
             let rec resolve_values index values_acc ops_acc uuid_acc = function
               | [] -> Ok (List.rev values_acc, List.rev ops_acc |> List.concat, uuid_acc)
               | value :: remaining ->
                 (match
                    resolve_value
                      ~now_ms
                      db
                      context
                      block_uuid
                      block
                      property
                      (ordinal + index)
                      value
                  with
                  | Error _ as error -> error
                  | Ok resolved ->
                    resolve_values
                      (index + 1)
                      (resolved :: values_acc)
                      (resolved.tx_ops :: ops_acc)
                      (Option.to_list resolved.created_uuid @ uuid_acc)
                      remaining)
             in
             (match resolve_values 0 [] [] [] input_values with
              | Error _ as error -> error
              | Ok (resolved, generated_ops, generated_uuids) ->
                let existing = values db block property.ident in
                let value_ops =
                  List.map
                    (fun value ->
                       Datascript.Add (Entity_id block, property.ident, value.tx_value))
                    resolved
                in
                let fresh =
                  List.filter
                    (fun value ->
                       not
                         (List.exists
                            (equal_stored_value value.stored_value)
                            existing))
                    resolved
                in
                let tx_ops =
                  if replace
                  then
                    [ Datascript.RetractAttr (Entity_id block, property.ident) ]
                    @ generated_ops
                    @ value_ops
                  else
                    generated_ops
                    @ List.map
                        (fun value ->
                           Datascript.Add (Entity_id block, property.ident, value.tx_value))
                        fresh
                in
                let tx_ops =
                  if tx_ops = []
                  then []
                  else
                    tx_ops
                    @ (if replace
                       then retract_property_refs block property existing
                       else [])
                    @ ((if replace then resolved else fresh)
                       |> List.concat_map (add_property_refs block property))
                    @ touch_ops ~now_ms db block
                in
                resolve_targets
                  (ordinal + List.length input_values)
                  (tx_ops :: acc_ops)
                  ((block_uuid :: generated_uuids) :: acc_uuids)
                  rest)
         in
         match resolve_targets 0 [] [] targets with
         | Error _ as error -> error
         | Ok (tx_ops, changed) ->
           Ok (plan_result context "batch-set-property" tx_ops (property.uuid :: changed))))
;;

let plan_batch_remove ~now_ms db blocks selector context =
  match ensure_unique_blocks blocks, resolve_property db selector with
  | (Error _ as error), _ | _, (Error _ as error) -> error
  | Ok (), Ok property ->
    (match resolve_blocks db blocks with
     | Error _ as error -> error
     | Ok targets ->
       let target_entities = List.map snd targets in
       let tx_ops =
         targets
         |> List.concat_map (fun (_, block) ->
           let existing = values db block property.ident in
           if existing = []
           then []
           else
             [ Datascript.RetractAttr (Entity_id block, property.ident)
             ]
             @ retract_property_refs block property existing
             @ touch_ops ~now_ms db block
             @ (existing
                |> List.filter_map ref_entity
                |> List.filter (fun value ->
                  generated_value db property value
                  && Datascript.datoms
                       db
                       Datascript.Avet
                       ~a:property.ident
                       ~v:(Datascript.Ref value)
                       ()
                     |> Seq.for_all (fun datom ->
                       List.mem datom.Datascript.e target_entities))
                |> List.concat_map (fun value ->
                  inbound_ref_retractions db value
                  @ [ Datascript.RetractEntity (Entity_id value) ])))
       in
       Ok (plan_result context "batch-remove-property" tx_ops (property.uuid :: blocks)))
;;

let supported_new_property_type = function
  | Default
  | Number
  | Date
  | Datetime
  | Checkbox
  | Url
  | Node
  | Asset
  | Map
  | String
  | Json -> true
  | Keyword | Collection | Any | Entity | Class | Page | Property | Raw_number -> false
;;

let same_schema left right =
  left.property_type = right.property_type
  && left.cardinality = right.cardinality
  && left.hidden = right.hidden
  && left.public = right.public
;;

let title_conflict db property_entity title =
  Datascript.datoms
    db
    Datascript.Eavt
    ~a:"block/title"
    ~v:(Datascript.String (normalize_title title))
    ()
  |> Seq.exists (fun datom ->
    datom.Datascript.e <> property_entity
    && has_tag_ident db datom.e "logseq.class/Property")
;;

let next_property_order db property_class =
  let orders =
    Datascript.datoms
      db
      Datascript.Avet
      ~a:"block/tags"
      ~v:(Datascript.Ref property_class)
      ()
    |> List.of_seq
    |> List.filter_map (fun datom ->
      match values db datom.Datascript.e "block/order" with
      | [ Datascript.String order ] when Outliner_order.is_valid order -> Some order
      | _ -> None)
    |> List.sort String.compare
    |> List.rev
  in
  let lower =
    match orders with
    | order :: _ -> Some order
    | [] -> None
  in
  match Outliner_order.between ~lower ~upper:None with
  | Ok order -> order
  | Error _ -> "a0"
;;

let property_definition_ref_ops db entity =
  let targets =
    (values db entity "block/tags" |> List.filter_map ref_entity)
    @ Option.to_list (Result.to_option (entity_of_ident db "block/tags"))
    |> List.sort_uniq Int.compare
  in
  List.map
    (fun target ->
       Datascript.Add (Entity_id entity, "block/refs", Ref_to (Entity_id target)))
    targets
;;

let plan_upsert ~now_ms db identity schema context =
  if schema.cardinality = Many && schema.property_type = Checkbox
  then Error (Invalid_selection "Checkbox properties cannot have many values.")
  else (
    match identity with
    | Protocol.New_property { ident; title } ->
      if not (qualified_ident ident)
      then Error (Invalid_selection "New property ident must be qualified.")
      else if not (String.starts_with ~prefix:"user.property/" ident)
      then
        Error
          (Unsupported_semantics "New properties must use the user.property namespace.")
      else if not (supported_new_property_type schema.property_type)
      then
        Error
          (Unsupported_semantics
             "The property type is internal-only for new user properties.")
      else (
        match entity_of_ident db ident with
        | Ok _ -> Error (Conflict "Property ident already exists.")
        | Error _ ->
          if title_conflict db (-1) title
          then Error (Conflict "Property title already exists.")
          else (
            match entity_of_ident db "logseq.class/Property" with
            | Error (Invalid_selection message) -> Error (Invalid_selection message)
            | Error _ -> Error (Invalid_selection "Built-in Property class is missing.")
            | Ok property_class ->
              let uuid = property_uuid ident in
              let temp = Datascript.Temp_id ("property-" ^ Uuid.to_string uuid) in
              let title = normalize_title title in
              let order = next_property_order db property_class in
              let reference_targets =
                property_class :: Option.to_list (Result.to_option (entity_of_ident db "block/tags"))
              in
              let tx_ops =
                [ Datascript.Add (temp, "block/uuid", Uuid (Uuid.to_string uuid))
                ; Add (temp, "db/ident", Keyword ident)
                ; Add (temp, "block/title", String title)
                ; Add (temp, "block/name", String (String.lowercase_ascii title))
                ; Add (temp, "block/order", String order)
                ; Add (temp, "block/tags", Ref_to (Entity_id property_class))
                ; Add
                    ( temp
                    , "logseq.property/type"
                    , Keyword (string_of_property_type schema.property_type) )
                ; Add
                    ( temp
                    , "db/cardinality"
                    , Keyword
                        (match schema.cardinality with
                         | One -> "db.cardinality/one"
                         | Many -> "db.cardinality/many") )
                ; Add (temp, "db/index", Bool true)
                ; Add (temp, "logseq.property/hide?", Bool schema.hidden)
                ; Add (temp, "logseq.property/public?", Bool schema.public)
                ; Add (temp, "block/created-at", Int (Int64.to_int now_ms))
                ; Add (temp, "block/updated-at", Int (Int64.to_int now_ms))
                ; Add (temp, "block/tx-id", Int (next_tx db))
                ]
                @ List.map
                    (fun target ->
                       Datascript.Add
                         (temp, "block/refs", Ref_to (Entity_id target)))
                    reference_targets
                @
                if ref_property_type schema.property_type
                then [ Datascript.Add (temp, "db/valueType", Keyword "db.type/ref") ]
                else []
              in
              Ok (plan_result context "upsert-property" tx_ops [ uuid ])))
    | Existing_property selector ->
      (match resolve_property db selector with
       | Error _ as error -> error
       | Ok property ->
         if property.built_in && not (same_schema property.schema schema)
         then Error Built_in_protected
         else if same_schema property.schema schema
         then Ok (plan_result context "upsert-property" [] [])
         else if
           ((property.schema.cardinality = Many && schema.cardinality = One)
            || property.schema.property_type <> schema.property_type)
           && not
                (Datascript.datoms db Datascript.Avet ~a:property.ident () |> Seq.is_empty)
         then
           Error (Conflict "Property schema change is incompatible with existing values.")
         else (
           let tx_ops =
             [ Datascript.Add
                 ( Entity_id property.entity
                 , "logseq.property/type"
                 , Keyword (string_of_property_type schema.property_type) )
             ; Add
                 ( Entity_id property.entity
                 , "db/cardinality"
                 , Keyword
                     (match schema.cardinality with
                      | One -> "db.cardinality/one"
                      | Many -> "db.cardinality/many") )
             ; Add (Entity_id property.entity, "logseq.property/hide?", Bool schema.hidden)
             ; Add
                 (Entity_id property.entity, "logseq.property/public?", Bool schema.public)
             ; Add
                 (Entity_id property.entity, "block/updated-at", Int (Int64.to_int now_ms))
             ]
             @
             if ref_property_type schema.property_type
             then
               [ Datascript.Add
                   (Entity_id property.entity, "db/valueType", Keyword "db.type/ref")
               ]
             else [ Datascript.RetractAttr (Entity_id property.entity, "db/valueType") ]
           in
           Ok (plan_result context "upsert-property" tx_ops [ property.uuid ]))))
;;

let closed_content property value =
  match property.schema.property_type, value with
  | Default, Default_value value | Url, Url_value value -> Ok (Datascript.String value)
  | Number, Number_value value -> parse_number value
  | _ -> Error (Invalid_selection "Closed value type does not match the property.")
;;

let plan_closed_values ~now_ms db selector action context =
  match resolve_property db selector with
  | Error _ as error -> error
  | Ok property when not (closed_value_type property.schema.property_type) ->
    Error (Unsupported_semantics "This property type does not support closed values.")
  | Ok property ->
    let content_attr = value_content_attr property.schema.property_type in
    (match action with
     | Protocol.Add_closed_value { value_uuid; value; icon } ->
       (match entity_of_uuid db value_uuid, closed_content property value with
        | Ok _, _ -> Error (Conflict "Closed value UUID already exists.")
        | _, (Error _ as error) -> error
        | Error _, Ok content ->
          if Option.is_some (closed_value_entity db property content_attr content)
          then Error (Conflict "Closed value already exists.")
          else (
            let temp = Datascript.Temp_id ("closed-value-" ^ Uuid.to_string value_uuid) in
            let tx_ops =
              [ Datascript.Add (temp, "block/uuid", Uuid (Uuid.to_string value_uuid))
              ; Add (temp, "block/parent", Ref_to (Entity_id property.entity))
              ; Add (temp, "block/page", Ref_to (Entity_id property.entity))
              ; Add
                  (temp, "block/closed-value-property", Ref_to (Entity_id property.entity))
              ; Add
                  ( temp
                  , "logseq.property/created-from-property"
                  , Ref_to (Entity_id property.entity) )
              ; Add (temp, "block/order", String "a0")
              ; Add (temp, content_attr, content)
              ; Add (temp, "block/created-at", Int (Int64.to_int now_ms))
              ]
              @ [ Datascript.Add (temp, "block/updated-at", Int (Int64.to_int now_ms))
                ; Add (temp, "block/tx-id", Int (next_tx db))
                ]
              @ touch_ops ~now_ms db property.entity
              @ property_definition_ref_ops db property.entity
              @ Option.to_list
                  (Option.map
                     (fun icon ->
                        Datascript.Add (temp, "logseq.property/icon", String icon))
                     icon)
            in
            Ok
              (plan_result
                 context
                 "upsert-closed-value"
                 tx_ops
                 [ property.uuid; value_uuid ])))
     | Update_closed_value { value_uuid; value; icon } ->
       (match entity_of_uuid db value_uuid, closed_content property value with
        | (Error _ as error), _ | _, (Error _ as error) -> error
        | Ok entity, Ok content ->
          if
            not
              (List.exists
                 (function
                   | Datascript.Ref value -> value = property.entity
                   | _ -> false)
                 (values db entity "block/closed-value-property"))
          then Error (Invalid_selection "Closed value belongs to another property.")
          else (
            let tx_ops =
              [ Datascript.Add (Entity_id entity, content_attr, content)
              ]
              @ touch_ops ~now_ms db entity
              @ touch_ops ~now_ms db property.entity
              @ property_definition_ref_ops db property.entity
              @
              match icon with
              | Some icon ->
                [ Datascript.Add (Entity_id entity, "logseq.property/icon", String icon) ]
              | None ->
                [ Datascript.RetractAttr (Entity_id entity, "logseq.property/icon") ]
            in
            Ok
              (plan_result
                 context
                 "upsert-closed-value"
                 tx_ops
                 [ property.uuid; value_uuid ])))
     | Associate_closed_value { value_uuid } ->
       (match entity_of_uuid db value_uuid with
        | Error _ as error -> error
        | Ok entity ->
          let tx_ops =
            [ Datascript.Add
                ( Entity_id entity
                , "block/closed-value-property"
                , Ref_to (Entity_id property.entity) )
            ; Add (Entity_id entity, "block/parent", Ref_to (Entity_id property.entity))
            ; Add (Entity_id entity, "block/page", Ref_to (Entity_id property.entity))
            ; Add
                ( Entity_id entity
                , "logseq.property/created-from-property"
                , Ref_to (Entity_id property.entity) )
            ]
            @ touch_ops ~now_ms db entity
            @ touch_ops ~now_ms db property.entity
            @ property_definition_ref_ops db property.entity
          in
          Ok
            (plan_result
               context
               "add-existing-values-to-closed-values"
               tx_ops
               [ property.uuid; value_uuid ]))
     | Delete_closed_value { value_uuid } ->
       (match entity_of_uuid db value_uuid with
        | Error _ as error -> error
        | Ok entity ->
          if bool_value db entity "logseq.property/built-in?"
          then Error Built_in_protected
          else if
            not
              (List.exists
                 (function
                   | Datascript.Ref value -> value = property.entity
                   | _ -> false)
                 (values db entity "block/closed-value-property"))
          then Error (Invalid_selection "Closed value belongs to another property.")
          else (
            let tx_ops =
              inbound_ref_retractions db entity
              @ [ Datascript.RetractEntity (Entity_id entity)
                ]
              @ touch_ops ~now_ms db property.entity
              @ property_definition_ref_ops db property.entity
            in
            Ok
              (plan_result
                 context
                 "delete-closed-value"
                 tx_ops
                 [ property.uuid; value_uuid ]))))
;;

let plan_class_property ~now_ms db class_uuid selector action context =
  match entity_of_uuid db class_uuid, resolve_property db selector with
  | (Error _ as error), _ | _, (Error _ as error) -> error
  | Ok class_entity, Ok property ->
    if
      not
        (has_tag_ident db class_entity "logseq.class/Tag"
         || List.exists
              (function
                | Datascript.Keyword ident | String ident ->
                  String.starts_with ~prefix:"user.class/" ident
                | _ -> false)
              (values db class_entity "db/ident"))
    then Error (Invalid_selection "Class selector does not identify a class.")
    else if bool_value db class_entity "logseq.property/built-in?" || property.built_in
    then Error Built_in_protected
    else (
      let relation = "logseq.property.class/properties" in
      let relation_entity = Result.to_option (entity_of_ident db relation) in
      let add_relation_refs =
        Datascript.Add
          (Entity_id class_entity, "block/refs", Ref_to (Entity_id property.entity))
        :: (relation_entity
            |> Option.to_list
            |> List.map (fun entity ->
              Datascript.Add
                (Entity_id class_entity, "block/refs", Ref_to (Entity_id entity))))
      in
      let retract_relation_refs =
        Datascript.Retract
          ( Entity_id class_entity
          , "block/refs"
          , Some (Ref_to (Entity_id property.entity)) )
        :: (relation_entity
            |> Option.to_list
            |> List.map (fun entity ->
              Datascript.Retract
                ( Entity_id class_entity
                , "block/refs"
                , Some (Ref_to (Entity_id entity)) )))
      in
      let present =
        List.exists
          (function
            | Datascript.Ref value -> value = property.entity
            | _ -> false)
          (values db class_entity relation)
      in
      match action with
      | Protocol.Remove_class_property ->
        let tx_ops =
          if present
          then
            [ Datascript.Retract
                ( Entity_id class_entity
                , relation
                , Some (Ref_to (Entity_id property.entity)) )
            ; RetractAttr (Entity_id class_entity, property.ident)
            ]
            @ retract_relation_refs
            @ touch_ops ~now_ms db class_entity
          else []
        in
        Ok
          (plan_result
             context
             "class-remove-property"
             tx_ops
             [ class_uuid; property.uuid ])
      | Add_class_property { default_value = None } ->
        let tx_ops =
          if present
          then []
          else
            [ Datascript.Add
                (Entity_id class_entity, relation, Ref_to (Entity_id property.entity))
            ]
            @ add_relation_refs
            @ touch_ops ~now_ms db class_entity
        in
        Ok (plan_result context "class-add-property" tx_ops [ class_uuid; property.uuid ])
      | Add_class_property { default_value = Some value } ->
        (match
           resolve_value ~now_ms db context class_uuid class_entity property 0 value
         with
         | Error _ as error -> error
         | Ok resolved ->
           let relation_ops =
             if present
             then []
             else
               [ Datascript.Add
                   (Entity_id class_entity, relation, Ref_to (Entity_id property.entity))
               ]
           in
           let tx_ops =
             resolved.tx_ops
             @ relation_ops
             @ [ Datascript.Add (Entity_id class_entity, property.ident, resolved.tx_value)
               ]
             @ add_relation_refs
             @ add_property_refs class_entity property resolved
             @ touch_ops ~now_ms db class_entity
           in
           let changed =
             class_uuid :: property.uuid :: Option.to_list resolved.created_uuid
           in
           Ok (plan_result context "class-add-property" tx_ops changed)))
;;

let plan ~now_ms db = function
  | Protocol.Upsert_property { property; schema; context } ->
    plan_upsert ~now_ms db property schema context
  | Set_property { block; property; value; context } ->
    plan_set ~now_ms db block property value context
  | Remove_property { block; property; context } ->
    plan_remove ~now_ms db block property context
  | Batch_set_property { blocks; property; mode; context } ->
    plan_batch_set ~now_ms db blocks property mode context
  | Batch_remove_property { blocks; property; context } ->
    plan_batch_remove ~now_ms db blocks property context
  | Manage_closed_values { property; action; context } ->
    plan_closed_values ~now_ms db property action context
  | Manage_class_property { class_; property; action; context } ->
    plan_class_property ~now_ms db class_ property action context
;;
