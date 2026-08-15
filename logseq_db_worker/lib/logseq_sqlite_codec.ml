module Ds = Datascript
module PSet = Persistent_sorted_set
module Transit = Transit_native.Transit.Json
open Ds

type error =
  | Unsupported_tag of string
  | Malformed_transit of string
  | Out_of_range_number of string
  | Malformed_storage_payload of string

type physical_entry =
  { address : Datascript.storage_address
  ; content : string
  ; addresses : Datascript.storage_address list
  }

type index_metadata =
  { count : int
  ; shift : int
  }

type root_index_metadata =
  { eavt : index_metadata
  ; aevt : index_metadata
  ; avet : index_metadata
  }

let schema_attr_default : Ds.schema_attr =
  { cardinality = One
  ; unique = None
  ; indexed = false
  ; is_component = false
  ; no_history = false
  ; doc = None
  ; value_type = None
  ; tuple_attrs = None
  ; tuple_types = None
  }
;;

let string_of_transit_key = function
  | Transit.Keyword value | Transit.String value -> Some value
  | _ -> None
;;

let keyword_of_transit = function
  | Transit.Keyword value -> Some value
  | _ -> None
;;

let bool_of_transit = function
  | Transit.Bool value -> Some value
  | _ -> None
;;

let string_of_transit = function
  | Transit.String value -> Some value
  | _ -> None
;;

let int_of_transit_value = function
  | Transit.Int value -> Some value
  | Transit.Int64 value ->
    if
      Int64.compare value (Int64.of_int min_int) >= 0
      && Int64.compare value (Int64.of_int max_int) <= 0
    then Some (Int64.to_int value)
    else None
  | _ -> None
;;

let lookup_transit_key key entries =
  List.find_map
    (fun (entry_key, value) ->
       match string_of_transit_key entry_key with
       | Some entry_key when String.equal entry_key key -> Some value
       | _ -> None)
    entries
;;

let transit_of_cardinality = function
  | One -> Transit.Keyword "db.cardinality/one"
  | Many -> Transit.Keyword "db.cardinality/many"
;;

let cardinality_of_transit = function
  | Transit.Keyword "db.cardinality/many" -> Many
  | Transit.Keyword "db.cardinality/one" -> One
  | _ -> One
;;

let transit_of_unique = function
  | Value -> Transit.Keyword "db.unique/value"
  | Identity -> Transit.Keyword "db.unique/identity"
;;

let unique_of_transit = function
  | Transit.Keyword "db.unique/value" -> Some Value
  | Transit.Keyword "db.unique/identity" -> Some Identity
  | _ -> None
;;

let transit_of_value_type = function
  | RefType -> Transit.Keyword "db.type/ref"
  | StringType -> Transit.Keyword "db.type/string"
  | KeywordType -> Transit.Keyword "db.type/keyword"
  | NumberType -> Transit.Keyword "db.type/number"
  | UuidType -> Transit.Keyword "db.type/uuid"
  | InstantType -> Transit.Keyword "db.type/instant"
  | TupleType -> Transit.Keyword "db.type/tuple"
;;

let value_type_of_transit = function
  | Transit.Keyword "db.type/ref" -> Some RefType
  | Transit.Keyword "db.type/string" -> Some StringType
  | Transit.Keyword "db.type/keyword" -> Some KeywordType
  | Transit.Keyword "db.type/number" -> Some NumberType
  | Transit.Keyword "db.type/uuid" -> Some UuidType
  | Transit.Keyword "db.type/instant" -> Some InstantType
  | Transit.Keyword "db.type/tuple" -> Some TupleType
  | _ -> None
;;

let transit_of_ref_type = function
  | PSet.Strong -> Transit.Keyword "strong"
  | PSet.Weak -> Transit.Keyword "weak"
;;

let ref_type_of_transit = function
  | Transit.Keyword "soft" -> PSet.Weak
  | Transit.Keyword "weak" -> PSet.Weak
  | Transit.Keyword "strong" | _ -> PSet.Strong
;;

let address_to_transit address = Transit.String address

let address_of_transit label = function
  | Transit.String address -> address
  | Transit.Int address -> string_of_int address
  | Transit.Int64 address -> Int64.to_string address
  | _ -> invalid_arg (label ^ " must be a storage address")
;;

let transit_of_tuple_attrs attrs =
  Transit.Array (List.map (fun attr -> Transit.Keyword attr) attrs)
;;

let transit_of_tuple_types types = Transit.Array (List.map transit_of_value_type types)

let schema_attr_to_transit attr =
  let entries = ref [] in
  let add key value = entries := (Transit.Keyword key, value) :: !entries in
  (match attr.cardinality with
   | One -> ()
   | Many -> add "db/cardinality" (transit_of_cardinality attr.cardinality));
  Option.iter (fun unique -> add "db/unique" (transit_of_unique unique)) attr.unique;
  if attr.indexed then add "db/index" (Transit.Bool true);
  if attr.is_component then add "db/isComponent" (Transit.Bool true);
  if attr.no_history then add "db/noHistory" (Transit.Bool true);
  Option.iter (fun doc -> add "db/doc" (Transit.String doc)) attr.doc;
  Option.iter
    (fun value_type -> add "db/valueType" (transit_of_value_type value_type))
    attr.value_type;
  Option.iter
    (fun attrs -> add "db/tupleAttrs" (transit_of_tuple_attrs attrs))
    attr.tuple_attrs;
  Option.iter
    (fun types -> add "db/tupleTypes" (transit_of_tuple_types types))
    attr.tuple_types;
  Transit.Map (List.rev !entries)
;;

let schema_to_transit schema =
  Transit.Map
    (List.map
       (fun (attr, schema_attr) ->
          Transit.Keyword attr, schema_attr_to_transit schema_attr)
       schema)
;;

let tuple_attrs_of_transit = function
  | Transit.Array values | Transit.List values ->
    Some (List.filter_map keyword_of_transit values)
  | _ -> None
;;

let tuple_types_of_transit = function
  | Transit.Array values | Transit.List values ->
    let types = List.filter_map value_type_of_transit values in
    if List.length types = List.length values then Some types else None
  | _ -> None
;;

let schema_attr_of_transit = function
  | Transit.Map props ->
    List.fold_left
      (fun schema (key, value) ->
         match keyword_of_transit key with
         | Some "db/cardinality" ->
           { schema with cardinality = cardinality_of_transit value }
         | Some "db/unique" -> { schema with unique = unique_of_transit value }
         | Some "db/index" ->
           { schema with indexed = Option.value (bool_of_transit value) ~default:false }
         | Some "db/isComponent" ->
           { schema with
             is_component = Option.value (bool_of_transit value) ~default:false
           }
         | Some "db/noHistory" ->
           { schema with
             no_history = Option.value (bool_of_transit value) ~default:false
           }
         | Some "db/doc" -> { schema with doc = string_of_transit value }
         | Some "db/valueType" -> { schema with value_type = value_type_of_transit value }
         | Some "db/tupleAttrs" ->
           { schema with tuple_attrs = tuple_attrs_of_transit value }
         | Some "db/tupleTypes" ->
           { schema with tuple_types = tuple_types_of_transit value }
         | Some _ | None -> schema)
      schema_attr_default
      props
  | _ -> schema_attr_default
;;

let schema_of_transit = function
  | Transit.Map entries ->
    List.filter_map
      (fun (attr, schema_attr) ->
         match keyword_of_transit attr with
         | Some attr -> Some (attr, schema_attr_of_transit schema_attr)
         | None -> None)
      entries
  | _ -> []
;;

let rec value_to_transit = function
  | Ds.Nil -> Transit.Null
  | Int value -> Transit.Int value
  | Float value -> Transit.Float value
  | String value -> Transit.String value
  | Symbol value -> Transit.Symbol value
  | Bool value -> Transit.Bool value
  | Keyword value -> Transit.Keyword value
  | Uuid value -> Transit.Tagged ("u", Transit.String value)
  | Instant value -> Transit.Tagged ("m", Transit.Int value)
  | Regex value -> Transit.Tagged ("regex", Transit.String value)
  | Ref entity_id -> Transit.Int entity_id
  | List values -> Transit.List (List.map value_to_transit values)
  | Vector values -> Transit.Array (List.map value_to_transit values)
  | Map entries ->
    Transit.Map
      (List.map
         (fun (key, value) -> value_to_transit key, value_to_transit value)
         entries)
  | Set values -> Transit.Set (List.map value_to_transit values)
  | Tuple values ->
    Transit.Array
      (List.map
         (function
           | None -> Transit.Null
           | Some value -> value_to_transit value)
         values)
  | TxRef -> Transit.Keyword "db/current-tx"
  | Ref_to _ -> invalid_arg "storage payload cannot contain unresolved refs"
;;

let rec value_of_transit = function
  | Transit.Null -> Ds.Nil
  | Bool value -> Bool value
  | String value -> String value
  | Int value -> Int value
  | Int64 value ->
    if
      Int64.compare value (Int64.of_int min_int) >= 0
      && Int64.compare value (Int64.of_int max_int) <= 0
    then Int (Int64.to_int value)
    else Instant (Int64.to_int value)
  | Float value -> Float value
  | Binary value -> String value
  | Big_decimal value -> Float (float_of_string value)
  | Big_int value -> Transit.Int64 (Int64.of_string value) |> value_of_transit
  | Date value -> Instant (Int64.to_int value)
  | Uuid value -> Uuid value
  | Uri value -> String value
  | Keyword value -> Keyword value
  | Symbol value -> Symbol value
  | Array values -> Vector (List.map value_of_transit values)
  | Map entries ->
    Map
      (List.map
         (fun (key, value) -> value_of_transit key, value_of_transit value)
         entries)
  | Set values -> Set (List.map value_of_transit values)
  | List values -> List (List.map value_of_transit values)
  | Tagged ("u", Transit.String value) -> Uuid value
  | Tagged ("m", Transit.Int value) -> Instant value
  | Tagged ("m", Transit.Int64 value) -> Instant (Int64.to_int value)
  | Tagged ("regex", Transit.String value) -> Regex value
  | Tagged (tag, value) -> Vector [ String tag; value_of_transit value ]
;;

let datom_to_transit datom =
  let tx = if datom.Ds.added then datom.tx else -datom.tx in
  Transit.Array
    [ Transit.Int datom.e
    ; Transit.Keyword datom.a
    ; value_to_transit datom.v
    ; Transit.Int tx
    ]
;;

let int_of_transit label value =
  match int_of_transit_value value with
  | Some value -> value
  | None -> invalid_arg (label ^ " must be a Transit integer")
;;

let datom_of_transit = function
  | Transit.Array [ entity; attr; value; tx ] ->
    let e = int_of_transit "datom entity" entity in
    let a =
      match keyword_of_transit attr with
      | Some attr -> attr
      | None -> invalid_arg "datom attr must be a Transit keyword"
    in
    let tx = int_of_transit "datom tx" tx in
    { Ds.e; a; v = value_of_transit value; tx = abs tx; added = tx >= 0 }
  | _ -> invalid_arg "storage datom must be [e a v tx]"
;;

let datoms_to_transit datoms = Transit.Array (List.map datom_to_transit datoms)

let datoms_of_transit = function
  | Transit.Array datoms | Transit.List datoms -> List.map datom_of_transit datoms
  | _ -> invalid_arg "storage datoms must be a Transit array"
;;

let index_metadata_to_transit metadata =
  Transit.Map
    [ Transit.Keyword "count", Transit.Int metadata.count
    ; Transit.Keyword "shift", Transit.Int metadata.shift
    ]
;;

let storage_root_to_transit ?metadata root =
  let entries =
    [ Transit.Keyword "schema", schema_to_transit root.storage_schema
    ; Transit.Keyword "max-eid", Transit.Int root.storage_max_eid
    ; Transit.Keyword "max-tx", Transit.Int root.storage_max_tx
    ; Transit.Keyword "eavt", address_to_transit root.storage_eavt
    ; Transit.Keyword "aevt", address_to_transit root.storage_aevt
    ; Transit.Keyword "avet", address_to_transit root.storage_avet
    ; Transit.Keyword "duplicate-datoms", datoms_to_transit root.storage_duplicate_datoms
    ; Transit.Keyword "max-addr", Transit.Int root.storage_max_addr
    ; Transit.Keyword "branching-factor", Transit.Int root.storage_branching_factor
    ; Transit.Keyword "ref-type", transit_of_ref_type root.storage_ref_type
    ]
  in
  let entries =
    match metadata with
    | None -> entries
    | Some metadata ->
      entries
      @ [ Transit.Keyword "eavt-metadata", index_metadata_to_transit metadata.eavt
        ; Transit.Keyword "aevt-metadata", index_metadata_to_transit metadata.aevt
        ; Transit.Keyword "avet-metadata", index_metadata_to_transit metadata.avet
        ]
  in
  Transit.Map entries
;;

let storage_node_to_transit = function
  | PSet.Leaf datoms -> Transit.Map [ Transit.Keyword "keys", datoms_to_transit datoms ]
  | PSet.Branch (keys, child_addresses) ->
    Transit.Map
      [ Transit.Keyword "keys", datoms_to_transit keys
      ; ( Transit.Keyword "children"
        , Transit.Array (List.map address_to_transit child_addresses) )
      ]
;;

let storage_tail_to_transit groups =
  Transit.Array (List.map (fun group -> datoms_to_transit group) groups)
;;

let payload_to_transit = function
  | Ds.Storage_root root -> storage_root_to_transit root
  | Storage_node node -> storage_node_to_transit node
  | Storage_tail groups -> storage_tail_to_transit groups
;;

let require_key key entries =
  match lookup_transit_key key entries with
  | Some value -> value
  | None -> invalid_arg ("storage payload is missing :" ^ key)
;;

let optional_datoms key entries =
  match lookup_transit_key key entries with
  | None -> []
  | Some value -> datoms_of_transit value
;;

let storage_root_of_transit entries =
  { Ds.storage_schema = schema_of_transit (require_key "schema" entries)
  ; storage_max_eid =
      int_of_transit "storage root :max-eid" (require_key "max-eid" entries)
  ; storage_max_tx = int_of_transit "storage root :max-tx" (require_key "max-tx" entries)
  ; storage_eavt = address_of_transit "storage root :eavt" (require_key "eavt" entries)
  ; storage_aevt = address_of_transit "storage root :aevt" (require_key "aevt" entries)
  ; storage_avet = address_of_transit "storage root :avet" (require_key "avet" entries)
  ; storage_duplicate_datoms = optional_datoms "duplicate-datoms" entries
  ; storage_max_addr =
      int_of_transit "storage root :max-addr" (require_key "max-addr" entries)
  ; storage_branching_factor =
      int_of_transit
        "storage root :branching-factor"
        (require_key "branching-factor" entries)
  ; storage_ref_type = ref_type_of_transit (require_key "ref-type" entries)
  }
;;

let child_addresses_of_transit = function
  | Transit.Array values | Transit.List values ->
    List.map (address_of_transit "storage node :children") values
  | _ -> invalid_arg "storage node :children must be a Transit array"
;;

let storage_node_of_transit entries =
  let keys = datoms_of_transit (require_key "keys" entries) in
  match lookup_transit_key "children" entries with
  | None -> PSet.Leaf keys
  | Some children -> PSet.Branch (keys, child_addresses_of_transit children)
;;

let storage_tail_of_transit = function
  | Transit.Array groups | Transit.List groups -> List.map datoms_of_transit groups
  | _ -> invalid_arg "storage tail must be a Transit array"
;;

let payload_of_transit = function
  | Transit.Map entries ->
    if Option.is_some (lookup_transit_key "schema" entries)
    then Storage_root (storage_root_of_transit entries)
    else if Option.is_some (lookup_transit_key "keys" entries)
    then Storage_node (storage_node_of_transit entries)
    else invalid_arg "unknown storage payload map"
  | (Transit.Array _ | Transit.List _) as tail ->
    Storage_tail (storage_tail_of_transit tail)
  | _ -> invalid_arg "unknown storage payload"
;;

type transit_cache_entry =
  | Cached_value of Transit.value
  | Cached_tag of string

type transit_reader = { mutable transit_cache : transit_cache_entry array }

let transit_cache_digits = "0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ["

let transit_cache_index text =
  let digit char =
    let rec find index =
      if index = String.length transit_cache_digits
      then invalid_arg ("invalid Transit cache code " ^ text)
      else if Char.equal transit_cache_digits.[index] char
      then index
      else find (index + 1)
    in
    find 0
  in
  let index = ref 0 in
  String.iter
    (fun char -> index := (!index * String.length transit_cache_digits) + digit char)
    text;
  !index
;;

let transit_cache_reference text =
  String.length text > 1 && Char.equal text.[0] '^' && not (String.equal text "^ ")
;;

let transit_cacheable_token text =
  String.length text > 3
  && Char.equal text.[0] '~'
  && (Char.equal text.[1] ':' || Char.equal text.[1] '$')
;;

let transit_remember reader entry =
  reader.transit_cache <- Array.append reader.transit_cache [| entry |]
;;

let transit_cached reader text =
  let code = String.sub text 1 (String.length text - 1) in
  let index = transit_cache_index code in
  if index < Array.length reader.transit_cache
  then reader.transit_cache.(index)
  else
    invalid_arg
      (Printf.sprintf
         "unknown Transit cache code %s at cache size %d"
         text
         (Array.length reader.transit_cache))
;;

let transit_primitive text = Transit.of_string (Yojson.Safe.to_string (`String text))

let transit_string_value reader text =
  if transit_cache_reference text
  then (
    match transit_cached reader text with
    | Cached_value value -> value
    | Cached_tag tag -> Transit.String tag)
  else (
    let value = transit_primitive text in
    if transit_cacheable_token text then transit_remember reader (Cached_value value);
    value)
;;

let transit_map_key reader text =
  if transit_cache_reference text
  then (
    match transit_cached reader text with
    | Cached_value value -> value
    | Cached_tag tag -> Transit.String tag)
  else (
    let value = transit_primitive text in
    if String.length text > 3 then transit_remember reader (Cached_value value);
    value)
;;

let transit_array_tag reader text =
  if transit_cache_reference text
  then (
    match transit_cached reader text with
    | Cached_tag tag | Cached_value (Transit.String tag) -> tag
    | Cached_value _ -> invalid_arg ("Transit cache code is not a tag: " ^ text))
  else (
    if String.length text > 3 then transit_remember reader (Cached_tag text);
    text)
;;

let rec transit_of_yojson reader = function
  | `Null -> Transit.Null
  | `Bool value -> Transit.Bool value
  | `Int value -> Transit.Int value
  | `Intlit value ->
    (match int_of_string_opt value with
     | Some value -> Transit.Int value
     | None -> Transit.Int64 (Int64.of_string value))
  | `Float value -> Transit.Float value
  | `Floatlit value -> Transit.Float (float_of_string value)
  | `String text -> transit_string_value reader text
  | `List [ `String "~#'"; value ] -> transit_of_yojson reader value
  | `List (`String "^ " :: entries) -> Transit.Map (transit_map_entries reader entries)
  | `List [ `String raw_tag; value ] ->
    let tag = transit_array_tag reader raw_tag in
    let value = transit_of_yojson reader value in
    (match tag, value with
     | "~#set", Transit.Array values -> Transit.Set values
     | "~#list", Transit.Array values -> Transit.List values
     | "~#cmap", Transit.Array values -> Transit.Map (transit_map_values values)
     | _ when String.length tag > 2 && String.sub tag 0 2 = "~#" ->
       Transit.Tagged (String.sub tag 2 (String.length tag - 2), value)
     | _ -> Transit.Array [ transit_string_value reader tag; value ])
  | `List values -> Transit.Array (List.map (transit_of_yojson reader) values)
  | `Assoc [ (tag, value) ] when String.length tag > 2 && String.sub tag 0 2 = "~#" ->
    let value = transit_of_yojson reader value in
    (match tag, value with
     | "~#'", value -> value
     | "~#set", Transit.Array values -> Transit.Set values
     | "~#list", Transit.Array values -> Transit.List values
     | "~#cmap", Transit.Array values -> Transit.Map (transit_map_values values)
     | _ -> Transit.Tagged (String.sub tag 2 (String.length tag - 2), value))
  | `Assoc entries ->
    Transit.Map
      (List.map
         (fun (key, value) -> transit_primitive key, transit_of_yojson reader value)
         entries)
  | `Tuple _ | `Variant _ -> invalid_arg "Transit JSON must be standard JSON"

and transit_map_entries reader = function
  | [] -> []
  | `String key :: value :: rest ->
    let key = transit_map_key reader key in
    let value = transit_of_yojson reader value in
    let rest = transit_map_entries reader rest in
    (key, value) :: rest
  | key :: value :: rest ->
    let key = transit_of_yojson reader key in
    let value = transit_of_yojson reader value in
    let rest = transit_map_entries reader rest in
    (key, value) :: rest
  | [ _ ] -> invalid_arg "Transit map expects an even number of entries"

and transit_map_values = function
  | [] -> []
  | key :: value :: rest -> (key, value) :: transit_map_values rest
  | [ _ ] -> invalid_arg "Transit cmap expects an even number of entries"
;;

let transit_of_string content =
  try
    let reader = { transit_cache = [||] } in
    Ok (transit_of_yojson reader (Yojson.Safe.from_string content))
  with
  | Transit.Decode_error message -> Error (Malformed_transit message)
  | Yojson.Json_error message -> Error (Malformed_transit message)
  | Invalid_argument message -> Error (Malformed_transit message)
  | exn -> Error (Malformed_transit (Printexc.to_string exn))
;;

let int64_fits_int value =
  Int64.compare value (Int64.of_int min_int) >= 0
  && Int64.compare value (Int64.of_int max_int) <= 0
;;

let rec preflight_value = function
  | Transit.Null | Bool _ | String _ | Int _ | Keyword _ | Symbol _ | Uuid _ -> Ok ()
  | Int64 value | Date value ->
    if int64_fits_int value
    then Ok ()
    else Error (Out_of_range_number (Int64.to_string value))
  | Float value ->
    (match classify_float value with
     | FP_normal | FP_subnormal | FP_zero -> Ok ()
     | FP_infinite | FP_nan -> Error (Out_of_range_number (string_of_float value)))
  | Big_int value ->
    (try
       let value = Int64.of_string value in
       if int64_fits_int value
       then Ok ()
       else Error (Out_of_range_number (Int64.to_string value))
     with
     | Failure _ -> Error (Out_of_range_number value))
  | Binary _ -> Error (Unsupported_tag "b")
  | Big_decimal _ -> Error (Unsupported_tag "f")
  | Uri _ -> Error (Unsupported_tag "r")
  | Array values | Set values | List values -> preflight_values values
  | Map entries ->
    preflight_values (List.concat_map (fun (key, value) -> [ key; value ]) entries)
  | Tagged ("u", String _)
  | Tagged ("regex", String _)
  | Tagged ("logseq/ref", (Int _ | Int64 _)) -> Ok ()
  | Tagged ("m", ((Int _ | Int64 _) as value)) -> preflight_value value
  | Tagged (tag, _) -> Error (Unsupported_tag tag)

and preflight_values = function
  | [] -> Ok ()
  | value :: rest ->
    (match preflight_value value with
     | Error _ as error -> error
     | Ok () -> preflight_values rest)
;;

let preflight content =
  match transit_of_string content with
  | Error _ as error -> error
  | Ok value -> preflight_value value
;;

let protect_value f =
  try Ok (f ()) with
  | Invalid_argument message -> Error (Malformed_transit message)
  | Failure message -> Error (Malformed_transit message)
  | exn -> Error (Malformed_transit (Printexc.to_string exn))
;;

let protect_payload f =
  try Ok (f ()) with
  | Invalid_argument message -> Error (Malformed_storage_payload message)
  | Failure message -> Error (Malformed_storage_payload message)
  | exn -> Error (Malformed_storage_payload (Printexc.to_string exn))
;;

let decode_value content =
  match transit_of_string content with
  | Error _ as error -> error
  | Ok transit ->
    (match preflight_value transit with
     | Error _ as error -> error
     | Ok () ->
       protect_value (fun () ->
         match transit with
         | Transit.Tagged ("logseq/ref", Int value) -> Datascript.Ref value
         | Tagged ("logseq/ref", Int64 value) when int64_fits_int value ->
           Ref (Int64.to_int value)
         | _ -> value_of_transit transit))
;;

let encode_value value =
  protect_value (fun () ->
    (match value with
     | Datascript.Ref entity_id -> Transit.Tagged ("logseq/ref", Int entity_id)
     | _ -> value_to_transit value)
    |> Transit.to_string ~mode:Transit.Verbose)
;;

let decode_storage_payload content =
  match transit_of_string content with
  | Error _ as error -> error
  | Ok transit ->
    (match preflight_value transit with
     | Error _ as error -> error
     | Ok () -> protect_payload (fun () -> payload_of_transit transit))
;;

let decode_root_index_metadata content =
  match transit_of_string content with
  | Error _ as error -> error
  | Ok transit ->
    protect_payload (fun () ->
      let decode_metadata label = function
        | Transit.Map entries ->
          let field name =
            let value =
              int_of_transit
                ("storage root :" ^ label ^ " :" ^ name)
                (require_key name entries)
            in
            if value < 0
            then invalid_arg ("storage root :" ^ label ^ " :" ^ name ^ " is negative")
            else value
          in
          { count = field "count"; shift = field "shift" }
        | _ -> invalid_arg ("storage root :" ^ label ^ " must be a Transit map")
      in
      match transit with
      | Transit.Map entries ->
        { eavt = decode_metadata "eavt-metadata" (require_key "eavt-metadata" entries)
        ; aevt = decode_metadata "aevt-metadata" (require_key "aevt-metadata" entries)
        ; avet = decode_metadata "avet-metadata" (require_key "avet-metadata" entries)
        }
      | _ -> invalid_arg "storage root metadata must be a Transit map")
;;

let encode_storage_payload payload =
  protect_payload (fun () ->
    payload |> payload_to_transit |> Transit.to_string ~mode:Transit.Verbose)
;;

let decode_physical_payload ~content ~addresses =
  match transit_of_string content with
  | Error _ as error -> error
  | Ok transit ->
    (match preflight_value transit with
     | Error _ as error -> error
     | Ok () ->
       protect_payload (fun () ->
         match transit, addresses with
         | Transit.Map entries, _ :: _
           when Option.is_some (lookup_transit_key "keys" entries) ->
           let keys = datoms_of_transit (require_key "keys" entries) in
           Storage_node (PSet.Branch (keys, addresses))
         | _ -> payload_of_transit transit))
;;

let encode_physical_payload payload =
  protect_payload (fun () ->
    match payload with
    | Datascript.Storage_node (PSet.Branch (keys, addresses)) ->
      ( Transit.to_string
          ~mode:Transit.Verbose
          (Transit.Map [ Transit.Keyword "keys", datoms_to_transit keys ])
      , addresses )
    | Storage_node (PSet.Leaf keys) ->
      ( Transit.to_string
          ~mode:Transit.Verbose
          (Transit.Map [ Transit.Keyword "keys", datoms_to_transit keys ])
      , [] )
    | payload -> Transit.to_string ~mode:Transit.Verbose (payload_to_transit payload), [])
;;

let encode_physical_batch ?(restore = fun _ -> None) ?metadata entries =
  protect_payload (fun () ->
    let nodes = Hashtbl.create (List.length entries) in
    let root = ref None in
    List.iter
      (fun (address, payload) ->
         if Hashtbl.mem nodes address
         then invalid_arg ("duplicate storage address " ^ address);
         match payload with
         | Datascript.Storage_node node -> Hashtbl.add nodes address node
         | Storage_root value ->
           (match !root with
            | None -> root := Some value
            | Some _ -> invalid_arg "physical storage batch has multiple roots")
         | Storage_tail _ -> ())
      entries;
    let root =
      match !root with
      | Some root -> root
      | None -> invalid_arg "physical storage batch has no root"
    in
    let index_metadata root_address =
      let visiting = Hashtbl.create 32 in
      let rec walk address =
        if Hashtbl.mem visiting address
        then invalid_arg ("cycle in stored index at " ^ address);
        Hashtbl.add visiting address ();
        let result =
          match Hashtbl.find_opt nodes address, restore address with
          | None, Some (Datascript.Storage_node node) ->
            Hashtbl.add nodes address node;
            Hashtbl.remove visiting address;
            walk address
          | None, Some _ | None, None ->
            invalid_arg ("stored index points at missing address " ^ address)
          | Some (PSet.Leaf keys), _ -> { count = List.length keys; shift = 0 }
          | Some (PSet.Branch (keys, children)), _ ->
            if children = []
            then invalid_arg ("stored branch has no children at " ^ address);
            let child_metadata = List.map walk children in
            let child_shift = (List.hd child_metadata).shift in
            if List.exists (fun metadata -> metadata.shift <> child_shift) child_metadata
            then invalid_arg ("stored index has inconsistent depth at " ^ address);
            ignore keys;
            { count =
                List.fold_left
                  (fun count metadata -> count + metadata.count)
                  0
                  child_metadata
            ; shift = child_shift + 1
            }
        in
        Hashtbl.remove visiting address;
        result
      in
      walk root_address
    in
    let metadata =
      match metadata with
      | Some metadata -> metadata
      | None ->
        { eavt = index_metadata root.storage_eavt
        ; aevt = index_metadata root.storage_aevt
        ; avet = index_metadata root.storage_avet
        }
    in
    List.map
      (fun (address, payload) ->
         match payload with
         | Datascript.Storage_root root ->
           { address
           ; content =
               Transit.to_string
                 ~mode:Transit.Verbose
                 (storage_root_to_transit ~metadata root)
           ; addresses = []
           }
         | payload ->
           let content, addresses =
             match encode_physical_payload payload with
             | Ok encoded -> encoded
             | Error _ -> invalid_arg ("unable to encode storage address " ^ address)
           in
           { address; content; addresses })
      entries)
;;
