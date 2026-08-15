open Graph_types

module Entity_map = Map.Make (Int)
module Entity_set = Set.Make (Int)

type context =
  { db : Datascript.db
  ; basis : int64
  ; now_ms : int64
  ; cursor_key : bytes
  }

type keyed_block =
  { key : string
  ; block : block
  }

type keyed_tree_item =
  { key : string
  ; item : block_tree_item
  }

let error code message =
  match Error.create ~code ~message ~details:[] with
  | Ok error -> error
  | Error message -> invalid_arg message
;;

let not_found () = error Error.Not_found "The requested graph entity does not exist."
let ambiguous () = error Error.Ambiguous_selector "The page selector is ambiguous."
let invalid_request message = error Error.Invalid_request message
let conflict message = error Error.Conflict message

let corrupt () =
  error Error.Corrupt_storage "The graph projection is structurally invalid."
;;

let values db entity attr =
  Datascript.datoms db Datascript.Eavt ~e:entity ~a:attr ()
  |> List.of_seq
  |> List.map (fun datom -> datom.Datascript.v)
;;

let one db entity attr =
  match values db entity attr with
  | [] -> Ok None
  | [ value ] -> Ok (Some value)
  | _ -> Error (corrupt ())
;;

let required db entity attr decode =
  match one db entity attr with
  | Ok (Some value) ->
    (match decode value with
     | Some value -> Ok value
     | None -> Error (corrupt ()))
  | Ok None | Error _ -> Error (corrupt ())
;;

let string = function
  | Datascript.String value -> Some value
  | _ -> None
;;

let integer = function
  | Datascript.Int value -> Some value
  | _ -> None
;;

let boolean = function
  | Datascript.Bool value -> Some value
  | _ -> None
;;

let reference = function
  | Datascript.Ref value -> Some value
  | _ -> None
;;

let uuid_value = function
  | Datascript.Uuid value | String value ->
    (match Uuid.of_string value with
     | Ok value -> Some value
     | Error _ -> None)
  | _ -> None
;;

let entity_of_uuid db uuid =
  let matches =
    Datascript.datoms
      db
      Datascript.Avet
      ~a:"block/uuid"
      ~v:(Datascript.Uuid (Uuid.to_string uuid))
      ()
    |> List.of_seq
    |> List.map (fun datom -> datom.Datascript.e)
    |> List.sort_uniq Int.compare
  in
  match matches with
  | [ entity ] -> Ok entity
  | [] -> Error (not_found ())
  | _ -> Error (corrupt ())
;;

let uuid_of_entity db entity = required db entity "block/uuid" uuid_value

let uuids_of_refs db entity attr =
  let rec collect acc = function
    | [] -> Ok (List.sort_uniq Uuid.compare acc)
    | Datascript.Ref target :: rest ->
      (match uuid_of_entity db target with
       | Ok uuid -> collect (uuid :: acc) rest
       | Error _ as error -> error)
    | _ -> Error (corrupt ())
  in
  collect [] (values db entity attr)
;;

let int64_of_int value = Int64.of_int value

let ident_of_value = function
  | Datascript.Keyword value | String value -> Some value
  | _ -> None
;;

let entity_of_ident db ident =
  let matches =
    Datascript.datoms db Datascript.Avet ~a:"db/ident" ~v:(Datascript.Keyword ident) ()
    |> List.of_seq
    |> List.map (fun datom -> datom.Datascript.e)
    |> List.sort_uniq Int.compare
  in
  match matches with
  | [ entity ] -> Some entity
  | [] -> None
  | _ -> None
;;

let has_ref db entity attr target =
  Datascript.datoms db Datascript.Eavt ~e:entity ~a:attr ~v:(Datascript.Ref target) ()
  |> Seq.uncons
  |> Option.is_some
;;

let is_property_entity db entity =
  match entity_of_ident db "logseq.class/Property" with
  | Some class_entity -> has_ref db entity "block/tags" class_entity
  | None -> false
;;

let all_property_entities db =
  match entity_of_ident db "logseq.class/Property" with
  | None -> []
  | Some class_entity ->
    Datascript.datoms
      db
      Datascript.Avet
      ~a:"block/tags"
      ~v:(Datascript.Ref class_entity)
      ()
    |> List.of_seq
    |> List.map (fun datom -> datom.Datascript.e)
    |> List.sort_uniq Int.compare
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
  | "collection" -> Collection
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

let property_type db entity =
  match one db entity "logseq.property/type" with
  | Ok None -> Ok Default
  | Ok (Some (Datascript.Keyword value | String value)) ->
    Ok (property_type_of_string value)
  | Ok (Some _) | Error _ -> Error (corrupt ())
;;

let property_cardinality db entity ident =
  match one db entity "db/cardinality" with
  | Ok (Some (Datascript.Keyword "db.cardinality/many")) -> Ok Many
  | Ok (Some (Datascript.Keyword "db.cardinality/one")) -> Ok One
  | Ok None ->
    let schema = (Datascript.serializable db).serializable_schema in
    (match List.assoc_opt ident schema with
     | Some attr when attr.Datascript.cardinality = Datascript.Many -> Ok Many
     | Some _ | None -> Ok One)
  | Ok (Some _) | Error _ -> Error (corrupt ())
;;

let bool_property db entity attr =
  match one db entity attr with
  | Ok None -> Ok false
  | Ok (Some (Datascript.Bool value)) -> Ok value
  | Ok (Some _) | Error _ -> Error (corrupt ())
;;

let closed_values db property_entity =
  Datascript.datoms
    db
    Datascript.Avet
    ~a:"block/closed-value-property"
    ~v:(Datascript.Ref property_entity)
    ()
  |> List.of_seq
  |> List.map (fun datom -> datom.Datascript.e)
  |> List.filter_map (fun entity ->
    match uuid_of_entity db entity with
    | Ok uuid -> Some uuid
    | Error _ -> None)
  |> List.sort_uniq Uuid.compare
;;

let project_property_definition db entity =
  let ( let* ) = Result.bind in
  let* uuid = uuid_of_entity db entity in
  let* ident = required db entity "db/ident" ident_of_value in
  let* title = required db entity "block/title" string in
  let* property_type = property_type db entity in
  let* cardinality = property_cardinality db entity ident in
  let* hidden = bool_property db entity "logseq.property/hide?" in
  let* public = bool_property db entity "logseq.property/public?" in
  Ok
    { uuid
    ; ident
    ; title
    ; schema = { property_type; cardinality; hidden; public }
    ; closed_values = closed_values db entity
    }
;;

let rec internal_value db = function
  | Datascript.Nil -> Ok Internal_null
  | Bool value -> Ok (Internal_bool value)
  | Int value -> Ok (Internal_number (string_of_int value))
  | Float value -> Ok (Internal_number (string_of_float value))
  | String value | Symbol value -> Ok (Internal_string value)
  | Keyword value -> Ok (Internal_keyword value)
  | Uuid value ->
    (match Uuid.of_string value with
     | Ok value -> Ok (Internal_uuid value)
     | Error _ -> Error (corrupt ()))
  | Ref entity -> uuid_of_entity db entity |> Result.map (fun uuid -> Internal_uuid uuid)
  | List values | Vector values | Set values ->
    let rec collect acc = function
      | [] -> Ok (Internal_list (List.rev acc))
      | value :: rest ->
        (match internal_value db value with
         | Ok value -> collect (value :: acc) rest
         | Error _ as error -> error)
    in
    collect [] values
  | Map entries ->
    let rec collect acc = function
      | [] -> Ok (Internal_map (List.rev acc))
      | (key, value) :: rest ->
        (match internal_value db key, internal_value db value with
         | Ok key, Ok value -> collect ((key, value) :: acc) rest
         | (Error _ as error), _ | _, (Error _ as error) -> error)
    in
    collect [] entries
  | Instant value -> Ok (Internal_number (string_of_int value))
  | Regex value -> Ok (Internal_string value)
  | Tuple values ->
    let values = List.map (Option.value ~default:Datascript.Nil) values in
    internal_value db (Datascript.Vector values)
  | TxRef | Ref_to _ -> Error (corrupt ())
;;

let ident_or_uuid_of_ref db entity =
  match one db entity "db/ident" with
  | Ok (Some (Datascript.Keyword ident | String ident)) -> Ok ident
  | Ok None -> uuid_of_entity db entity |> Result.map Uuid.to_string
  | Ok (Some _) | Error _ -> Error (corrupt ())
;;

let property_value db property_type = function
  | Datascript.String value when property_type = Default -> Ok (Default_value value)
  | String value when property_type = Url -> Ok (Url_value value)
  | String value when property_type = String -> Ok (String_value value)
  | String value when property_type = Json -> Ok (Json_value value)
  | String value when property_type = Number -> Ok (Number_value value)
  | String value when property_type = Raw_number -> Ok (Raw_number_value value)
  | Int value when property_type = Number -> Ok (Number_value (string_of_int value))
  | Float value when property_type = Number -> Ok (Number_value (string_of_float value))
  | Int value when property_type = Raw_number ->
    Ok (Raw_number_value (string_of_int value))
  | Float value when property_type = Raw_number ->
    Ok (Raw_number_value (string_of_float value))
  | Int journal_day when property_type = Date -> Ok (Date_value { journal_day })
  | Int unix_ms when property_type = Datetime ->
    Ok (Datetime_value { unix_ms = Int64.of_int unix_ms })
  | Bool value when property_type = Checkbox -> Ok (Checkbox_value value)
  | Keyword value when property_type = Keyword -> Ok (Keyword_value value)
  | Ref entity when property_type = Node ->
    uuid_of_entity db entity |> Result.map (fun value -> Node_value value)
  | Ref entity when property_type = Asset ->
    uuid_of_entity db entity |> Result.map (fun value -> Asset_value value)
  | Ref entity when property_type = Entity ->
    uuid_of_entity db entity |> Result.map (fun value -> Entity_value value)
  | Ref entity when property_type = Class ->
    uuid_of_entity db entity |> Result.map (fun value -> Class_value value)
  | Ref entity when property_type = Page ->
    uuid_of_entity db entity |> Result.map (fun value -> Page_value value)
  | Ref entity when property_type = Property ->
    ident_or_uuid_of_ref db entity |> Result.map (fun value -> Property_value value)
  | value when property_type = Map ->
    (match internal_value db value with
     | Ok (Internal_map value) -> Ok (Map_value value)
     | Ok _ | Error _ -> Error (corrupt ()))
  | value when property_type = Collection ->
    (match internal_value db value with
     | Ok (Internal_list value) -> Ok (Collection_value value)
     | Ok value -> Ok (Collection_value [ value ])
     | Error _ as error -> error)
  | value when property_type = Any ->
    internal_value db value |> Result.map (fun value -> Any_value value)
  | Ref entity when property_type = Default ->
    ident_or_uuid_of_ref db entity |> Result.map (fun value -> Default_value value)
  | value -> internal_value db value |> Result.map (fun value -> Any_value value)
;;

let property_summaries db entity =
  let attrs =
    Datascript.datoms db Datascript.Eavt ~e:entity ()
    |> List.of_seq
    |> List.map (fun datom -> datom.Datascript.a)
    |> List.sort_uniq String.compare
  in
  let rec project (acc : property_summary list) = function
    | [] ->
      Ok
        (List.sort
           (fun (left : property_summary) (right : property_summary) ->
              String.compare left.ident right.ident)
           acc)
    | attr :: rest ->
      (match entity_of_ident db attr with
       | Some property_entity when is_property_entity db property_entity ->
         (match project_property_definition db property_entity with
          | Error _ as error -> error
          | Ok definition ->
            let rec decode_values acc = function
              | [] -> Ok (List.rev acc)
              | value :: values ->
                (match property_value db definition.schema.property_type value with
                 | Ok value -> decode_values (value :: acc) values
                 | Error _ as error -> error)
            in
            (match decode_values [] (values db entity attr) with
             | Error _ as error -> error
             | Ok decoded ->
               let limit = Protocol.maximum_property_values in
               let rec take count acc = function
                 | _ when count = 0 -> List.rev acc
                 | [] -> List.rev acc
                 | value :: rest -> take (count - 1) (value :: acc) rest
               in
               let summary : property_summary =
                 { ident = definition.ident
                 ; uuid = definition.uuid
                 ; title = definition.title
                 ; schema = definition.schema
                 ; values = take limit [] decoded
                 ; values_truncated = List.length decoded > limit
                 }
               in
               project (summary :: acc) rest))
       | Some _ | None -> project acc rest)
  in
  project [] attrs
;;

let project_block db entity =
  let ( let* ) = Result.bind in
  let* uuid = uuid_of_entity db entity in
  let* title = required db entity "block/title" string in
  let* parent_entity = required db entity "block/parent" reference in
  let* parent = uuid_of_entity db parent_entity in
  let* page_entity = required db entity "block/page" reference in
  let* page = uuid_of_entity db page_entity in
  let* order = required db entity "block/order" string in
  let* created_at = required db entity "block/created-at" integer in
  let* updated_at = required db entity "block/updated-at" integer in
  let* refs = uuids_of_refs db entity "block/refs" in
  let* tags = uuids_of_refs db entity "block/tags" in
  let* properties = property_summaries db entity in
  Ok
    { uuid
    ; title
    ; parent
    ; page
    ; order
    ; created_at_ms = int64_of_int created_at
    ; updated_at_ms = int64_of_int updated_at
    ; refs
    ; tags
    ; properties
    }
;;

let optional_bool db entity attr =
  match one db entity attr with
  | Ok None -> Ok false
  | Ok (Some value) ->
    (match boolean value with
     | Some value -> Ok value
     | None -> Error (corrupt ()))
  | Error _ as error -> error
;;

let optional_int db entity attr =
  match one db entity attr with
  | Ok None -> Ok None
  | Ok (Some value) ->
    (match integer value with
     | Some value -> Ok (Some value)
     | None -> Error (corrupt ()))
  | Error _ as error -> error
;;

let optional_ident db entity =
  match one db entity "db/ident" with
  | Ok None -> Ok None
  | Ok (Some (Datascript.Keyword value | String value)) -> Ok (Some value)
  | Ok (Some _) | Error _ -> Error (corrupt ())
;;

let tag_idents db entity =
  let rec collect acc = function
    | [] -> Ok acc
    | Datascript.Ref tag :: rest ->
      (match optional_ident db tag with
       | Ok ident -> collect (Option.to_list ident @ acc) rest
       | Error _ as error -> error)
    | _ -> Error (corrupt ())
  in
  collect [] (values db entity "block/tags")
;;

let page_kind db entity =
  let ( let* ) = Result.bind in
  let* built_in = optional_bool db entity "logseq.property/built-in?" in
  if built_in
  then Ok Built_in_page
  else (
    let* journal_day = optional_int db entity "block/journal-day" in
    match journal_day with
    | Some journal_day -> Ok (Journal_page { journal_day })
    | None ->
      let* hidden = optional_bool db entity "logseq.property/hide?" in
      let* tags = tag_idents db entity in
      if List.mem "logseq.class/Property" tags
      then Ok Property_page
      else if List.mem "logseq.class/Tag" tags
      then Ok Class_page
      else if hidden
      then Ok Hidden_page
      else Ok Ordinary_page)
;;

let project_page db entity =
  let ( let* ) = Result.bind in
  let* uuid = uuid_of_entity db entity in
  let* name = required db entity "block/name" string in
  let* title = required db entity "block/title" string in
  let* kind = page_kind db entity in
  let* created_at = required db entity "block/created-at" integer in
  let* updated_at = required db entity "block/updated-at" integer in
  let* tags = uuids_of_refs db entity "block/tags" in
  let* recycled = optional_int db entity "logseq.property/deleted-at" in
  let* properties = property_summaries db entity in
  Ok
    { uuid
    ; name
    ; title
    ; kind
    ; created_at_ms = int64_of_int created_at
    ; updated_at_ms = int64_of_int updated_at
    ; tags
    ; properties
    ; recycled = Option.is_some recycled
    }
;;

let project_page_summary db entity =
  let ( let* ) = Result.bind in
  let* uuid = uuid_of_entity db entity in
  let* name = required db entity "block/name" string in
  let* title = required db entity "block/title" string in
  let* kind = page_kind db entity in
  let* recycled = optional_int db entity "logseq.property/deleted-at" in
  Ok { uuid; name; title; kind; recycled = Option.is_some recycled }
;;

let kind_matches filter kind =
  match filter, kind with
  | Any_page, _ -> true
  | Only_ordinary_pages, Ordinary_page -> true
  | Only_journals, Journal_page _ -> true
  | Only_classes, Class_page -> true
  | Only_properties, Property_page -> true
  | _ -> false
;;

let all_page_entities db =
  Datascript.datoms db Datascript.Aevt ~a:"block/name" ()
  |> List.of_seq
  |> List.map (fun datom -> datom.Datascript.e)
  |> List.sort_uniq Int.compare
;;

let values_by_entity db attr =
  Datascript.datoms db Datascript.Aevt ~a:attr ()
  |> Seq.fold_left
       (fun values (datom : Datascript.datom) ->
          Entity_map.update
            datom.e
            (function
              | None -> Some [ datom.v ]
              | Some existing -> Some (datom.v :: existing))
            values)
       Entity_map.empty
;;

let values_by_candidate_entity db candidates attr =
  Datascript.datoms db Datascript.Aevt ~a:attr ()
  |> Seq.fold_left
       (fun values (datom : Datascript.datom) ->
          if Entity_set.mem datom.e candidates
          then
            Entity_map.update
              datom.e
              (function
                | None -> Some [ datom.v ]
                | Some existing -> Some (datom.v :: existing))
              values
          else values)
       Entity_map.empty
;;

let required_from_values values decode =
  match values with
  | [ value ] ->
    (match decode value with
     | Some value -> Ok value
     | None -> Error (corrupt ()))
  | [] | _ :: _ :: _ -> Error (corrupt ())
;;

let optional_from_values values decode =
  match values with
  | [] -> Ok None
  | [ value ] ->
    (match decode value with
     | Some value -> Ok (Some value)
     | None -> Error (corrupt ()))
  | _ :: _ :: _ -> Error (corrupt ())
;;

let journal_uuid journal_day =
  let day = Printf.sprintf "%08d" journal_day in
  match
    Uuid.of_string
      (Printf.sprintf
         "00000001-%s-%s-0000-000000000000"
         (String.sub day 0 4)
         (String.sub day 4 4))
  with
  | Ok uuid -> Ok uuid
  | Error _ -> Error (corrupt ())
;;

let journal_page_summaries db =
  let journal_days = values_by_entity db "block/journal-day" in
  let candidates =
    Entity_map.fold (fun entity _ -> Entity_set.add entity) journal_days Entity_set.empty
  in
  let names = values_by_candidate_entity db candidates "block/name" in
  let built_ins =
    values_by_candidate_entity db candidates "logseq.property/built-in?"
  in
  let deleted_at =
    values_by_candidate_entity db candidates "logseq.property/deleted-at"
  in
  Entity_map.fold
    (fun entity journal_day_values result ->
       let ( let* ) = Result.bind in
       let* summaries = result in
       let* name =
         required_from_values
           (Entity_map.find_opt entity names |> Option.value ~default:[])
           string
       in
       let* journal_day = required_from_values journal_day_values integer in
       let* uuid = journal_uuid journal_day in
       let* built_in =
         optional_from_values
           (Entity_map.find_opt entity built_ins |> Option.value ~default:[])
           boolean
       in
       let* recycled =
         optional_from_values
           (Entity_map.find_opt entity deleted_at |> Option.value ~default:[])
           integer
       in
       match built_in with
       | Some true -> Ok summaries
       | None | Some false ->
         let summary : page_summary =
           { uuid
           ; name
           ; title = String.capitalize_ascii name
           ; kind = Journal_page { journal_day }
           ; recycled = Option.is_some recycled
           }
         in
         let key = summary.name ^ "\000" ^ Uuid.to_string summary.uuid in
         Ok ((key, summary) :: summaries))
    journal_days
    (Ok [])
;;

let get_page db selector =
  let candidates =
    match selector with
    | Page_by_uuid uuid ->
      (match entity_of_uuid db uuid with
       | Ok entity -> [ entity ]
       | Error _ -> [])
    | Page_by_name { name; kind } ->
      let normalized = String.lowercase_ascii name in
      all_page_entities db
      |> List.filter (fun entity ->
        match one db entity "block/name", page_kind db entity with
        | Ok (Some (Datascript.String actual)), Ok actual_kind ->
          String.equal actual normalized && kind_matches kind actual_kind
        | _ -> false)
  in
  match candidates with
  | [] -> Error (not_found ())
  | [ entity ] -> project_page db entity
  | _ -> Error (ambiguous ())
;;

let keyed_children db parent_entity =
  let entities =
    Datascript.datoms
      db
      Datascript.Avet
      ~a:"block/parent"
      ~v:(Datascript.Ref parent_entity)
      ()
    |> List.of_seq
    |> List.map (fun datom -> datom.Datascript.e)
    |> List.filter (fun entity -> entity <> parent_entity)
    |> List.sort_uniq Int.compare
  in
  let rec project (acc : keyed_block list) = function
    | [] ->
      Ok
        (List.sort
           (fun (left : keyed_block) (right : keyed_block) ->
              String.compare left.key right.key)
           acc)
    | entity :: rest ->
      (match project_block db entity with
       | Error _ as error -> error
       | Ok block ->
         let key = block.order ^ "\000" ^ Uuid.to_string block.uuid in
         project ({ key; block } :: acc) rest)
  in
  project [] entities
;;

type keyed_child_entity =
  { key : string
  ; entity : int
  }

let keyed_child_entities db parent_entity =
  let entities =
    Datascript.datoms
      db
      Datascript.Avet
      ~a:"block/parent"
      ~v:(Datascript.Ref parent_entity)
      ()
    |> List.of_seq
    |> List.map (fun datom -> datom.Datascript.e)
    |> List.filter (fun entity -> entity <> parent_entity)
    |> List.sort_uniq Int.compare
  in
  let rec collect acc = function
    | [] -> Ok (List.sort (fun left right -> String.compare left.key right.key) acc)
    | entity :: rest ->
      let ( let* ) = Result.bind in
      let* order = required db entity "block/order" string in
      let* uuid = uuid_of_entity db entity in
      collect ({ key = order ^ "\000" ^ Uuid.to_string uuid; entity } :: acc) rest
  in
  collect [] entities
;;

let cursor_ttl_ms = 900_000L

let cursor_start context ~fingerprint cursor =
  match cursor with
  | None -> Ok None
  | Some cursor ->
    (match Query.decode_cursor ~key:context.cursor_key ~now_ms:context.now_ms cursor with
     | Error _ -> Error (invalid_request "The continuation cursor is invalid or expired.")
     | Ok payload ->
       if
         payload.basis <> context.basis
         || not (String.equal payload.fingerprint fingerprint)
       then Error (conflict "The continuation cursor does not match this query basis.")
       else Ok (Some payload.last_sort_key))
;;

let make_cursor context ~fingerprint last_sort_key =
  Query.encode_cursor
    ~key:context.cursor_key
    { api_version = Protocol.api_version
    ; fingerprint
    ; basis = context.basis
    ; last_sort_key
    ; expires_at_ms = Int64.add context.now_ms cursor_ttl_ms
    }
  |> Result.map_error (fun _ ->
    invalid_request "The continuation cursor could not be encoded.")
;;

let paginate context ~fingerprint ~cursor ~limit ~key items =
  let ( let* ) = Result.bind in
  let* () =
    Query.validate_limit limit
    |> Result.map_error (fun _ -> invalid_request "The collection limit is invalid.")
  in
  let* start = cursor_start context ~fingerprint cursor in
  let remaining =
    match start with
    | None -> items
    | Some start -> List.filter (fun item -> String.compare (key item) start > 0) items
  in
  let rec take count acc rest =
    if count = 0
    then List.rev acc, rest
    else (
      match rest with
      | [] -> List.rev acc, []
      | item :: rest -> take (count - 1) (item :: acc) rest)
  in
  let selected, rest = take limit [] remaining in
  let* continuation =
    match List.rev selected, rest with
    | last :: _, _ :: _ ->
      make_cursor context ~fingerprint (key last) |> Result.map Option.some
    | _ -> Ok None
  in
  Ok { items = selected; continuation }
;;

let fingerprint name fields =
  Query.fingerprint (`Assoc (("command", `String name) :: fields))
;;

let uuid_json uuid = `String (Uuid.to_string uuid)

let get_children context parent limit cursor =
  let ( let* ) = Result.bind in
  let* parent_entity = entity_of_uuid context.db parent in
  let* children = keyed_child_entities context.db parent_entity in
  let query_fingerprint = fingerprint "getChildren" [ "parent", uuid_json parent ] in
  let* page =
    paginate
      context
      ~fingerprint:query_fingerprint
      ~cursor
      ~limit
      ~key:(fun (item : keyed_child_entity) -> item.key)
      children
  in
  let rec project acc = function
    | [] -> Ok (List.rev acc)
    | item :: rest ->
      let* block = project_block context.db item.entity in
      project (block :: acc) rest
  in
  let* items = project [] page.items in
  Ok { items; continuation = page.continuation }
;;

let get_page_tree context page maximum_depth limit cursor =
  if maximum_depth < 0 || maximum_depth > Protocol.maximum_tree_depth
  then Error (invalid_request "The requested tree depth is invalid.")
  else (
    let ( let* ) = Result.bind in
    let* page_entity = entity_of_uuid context.db page in
    let* _page = project_page context.db page_entity in
    let visited = Hashtbl.create 64 in
    let rec descend path depth parent_entity =
      let* children = keyed_children context.db parent_entity in
      let rec loop acc = function
        | [] -> Ok (List.rev acc)
        | child :: rest ->
          let uuid = Uuid.to_string child.block.uuid in
          if Hashtbl.mem visited uuid
          then Error (corrupt ())
          else (
            Hashtbl.add visited uuid ();
            let key = path ^ child.key in
            let current = { key; item = { block = child.block; depth } } in
            let* descendants =
              if depth >= maximum_depth
              then Ok []
              else
                let* entity = entity_of_uuid context.db child.block.uuid in
                descend (key ^ "\001") (depth + 1) entity
            in
            let* rest = loop acc rest in
            Hashtbl.remove visited uuid;
            Ok ((current :: descendants) @ rest))
      in
      loop [] children
    in
    let* items = descend "" 0 page_entity in
    let query_fingerprint =
      fingerprint
        "getPageTree"
        [ "page", uuid_json page; "maximumDepth", `Int maximum_depth ]
    in
    let* page =
      paginate
        context
        ~fingerprint:query_fingerprint
        ~cursor
        ~limit
        ~key:(fun (item : keyed_tree_item) -> item.key)
        items
    in
    Ok
      { items = List.map (fun (item : keyed_tree_item) -> item.item) page.items
      ; continuation = page.continuation
      })
;;

let get_ancestors context block_uuid limit =
  let ( let* ) = Result.bind in
  let* () =
    Query.validate_limit limit
    |> Result.map_error (fun _ -> invalid_request "The ancestor limit is invalid.")
  in
  let* entity = entity_of_uuid context.db block_uuid in
  let visited = Hashtbl.create 32 in
  let rec collect count acc entity =
    if count = limit
    then Ok (List.rev acc)
    else if Hashtbl.mem visited entity
    then Error (corrupt ())
    else (
      Hashtbl.add visited entity ();
      match required context.db entity "block/parent" reference with
      | Error _ as error -> error
      | Ok parent ->
        (match one context.db parent "block/name" with
         | Ok (Some _) -> Ok (List.rev acc)
         | Ok None ->
           let* block = project_block context.db parent in
           collect (count + 1) (block :: acc) parent
         | Error _ as error -> error))
  in
  collect 0 [] entity
;;

let get_siblings context block_uuid limit cursor =
  let ( let* ) = Result.bind in
  let* entity = entity_of_uuid context.db block_uuid in
  let* parent = required context.db entity "block/parent" reference in
  let* siblings = keyed_children context.db parent in
  let current_index =
    List.find_index (fun item -> Uuid.equal item.block.uuid block_uuid) siblings
  in
  match current_index with
  | None -> Error (corrupt ())
  | Some current_index ->
    let query_fingerprint = fingerprint "getSiblings" [ "block", uuid_json block_uuid ] in
    let* page =
      paginate
        context
        ~fingerprint:query_fingerprint
        ~cursor
        ~limit
        ~key:(fun (item : keyed_block) -> item.key)
        siblings
    in
    Ok
      { siblings =
          { items = List.map (fun (item : keyed_block) -> item.block) page.items
          ; continuation = page.continuation
          }
      ; current_index
      }
;;

let list_pages context kind limit cursor =
  let ( let* ) = Result.bind in
  let rec project acc = function
    | [] -> Ok acc
    | entity :: rest ->
      (match project_page_summary context.db entity with
       | Ok summary when kind_matches kind summary.kind ->
         let key = summary.name ^ "\000" ^ Uuid.to_string summary.uuid in
         project ((key, summary) :: acc) rest
       | Ok _ -> project acc rest
       | Error _ as error -> error)
  in
  let* pages =
    match kind with
    | Only_journals -> journal_page_summaries context.db
    | Any_page | Only_ordinary_pages | Only_classes | Only_properties ->
      project [] (all_page_entities context.db)
  in
  let pages = List.sort (fun (left, _) (right, _) -> String.compare left right) pages in
  let query_fingerprint =
    fingerprint
      "listPages"
      [ ( "kind"
        , `String
            (match kind with
             | Any_page -> "any"
             | Only_ordinary_pages -> "ordinary"
             | Only_journals -> "journals"
             | Only_classes -> "classes"
             | Only_properties -> "properties") )
      ]
  in
  let* page =
    paginate context ~fingerprint:query_fingerprint ~cursor ~limit ~key:fst pages
  in
  Ok { items = List.map snd page.items; continuation = page.continuation }
;;

let list_tags context limit cursor =
  let ( let* ) = Result.bind in
  let entities =
    match entity_of_ident context.db "logseq.class/Tag" with
    | None -> []
    | Some class_entity ->
      Datascript.datoms
        context.db
        Datascript.Avet
        ~a:"block/tags"
        ~v:(Datascript.Ref class_entity)
        ()
      |> List.of_seq
      |> List.map (fun datom -> datom.Datascript.e)
      |> List.sort_uniq Int.compare
  in
  let rec project acc = function
    | [] -> Ok acc
    | entity :: rest ->
      let* uuid = uuid_of_entity context.db entity in
      let* title = required context.db entity "block/title" string in
      let* ident = optional_ident context.db entity in
      let item : tag_summary = { uuid; title; ident } in
      let key = String.lowercase_ascii title ^ "\000" ^ Uuid.to_string uuid in
      project ((key, item) :: acc) rest
  in
  let* items = project [] entities in
  let items = List.sort (fun (left, _) (right, _) -> String.compare left right) items in
  let query_fingerprint = fingerprint "listTags" [] in
  let* page =
    paginate context ~fingerprint:query_fingerprint ~cursor ~limit ~key:fst items
  in
  Ok { items = List.map snd page.items; continuation = page.continuation }
;;

let property_entities_for_scope context = function
  | All_properties -> Ok (all_property_entities context.db)
  | User_properties ->
    let rec filter acc = function
      | [] -> Ok (List.rev acc)
      | entity :: rest ->
        (match bool_property context.db entity "logseq.property/built-in?" with
         | Ok true -> filter acc rest
         | Ok false -> filter (entity :: acc) rest
         | Error _ as error -> error)
    in
    filter [] (all_property_entities context.db)
  | Properties_for_block block ->
    (match entity_of_uuid context.db block with
     | Error _ as error -> error
     | Ok entity ->
       let entities =
         Datascript.datoms context.db Datascript.Eavt ~e:entity ()
         |> List.of_seq
         |> List.filter_map (fun datom -> entity_of_ident context.db datom.Datascript.a)
         |> List.filter (is_property_entity context.db)
         |> List.sort_uniq Int.compare
       in
       Ok entities)
  | Properties_for_class class_uuid ->
    (match entity_of_uuid context.db class_uuid with
     | Error _ as error -> error
     | Ok class_entity ->
       let rec collect acc = function
         | [] -> Ok (List.sort_uniq Int.compare acc)
         | Datascript.Ref property :: rest when is_property_entity context.db property ->
           collect (property :: acc) rest
         | Datascript.Ref _ :: rest -> collect acc rest
         | _ -> Error (corrupt ())
       in
       collect [] (values context.db class_entity "logseq.property.class/properties"))
;;

let property_scope_json = function
  | All_properties -> `String "all"
  | User_properties -> `String "user"
  | Properties_for_block block -> `Assoc [ "block", `String (Uuid.to_string block) ]
  | Properties_for_class class_uuid ->
    `Assoc [ "class", `String (Uuid.to_string class_uuid) ]
;;

let list_properties context scope limit cursor =
  let ( let* ) = Result.bind in
  let* entities = property_entities_for_scope context scope in
  let rec project acc = function
    | [] -> Ok acc
    | entity :: rest ->
      (match project_property_definition context.db entity with
       | Error _ as error -> error
       | Ok item ->
         let key = item.ident ^ "\000" ^ Uuid.to_string item.uuid in
         project ((key, item) :: acc) rest)
  in
  let* items = project [] entities in
  let items = List.sort (fun (left, _) (right, _) -> String.compare left right) items in
  let query_fingerprint =
    fingerprint "listProperties" [ "scope", property_scope_json scope ]
  in
  let* page =
    paginate context ~fingerprint:query_fingerprint ~cursor ~limit ~key:fst items
  in
  Ok { items = List.map snd page.items; continuation = page.continuation }
;;

let task_state_of_ident = function
  | "logseq.property/status.todo" -> Some Todo
  | "logseq.property/status.doing" -> Some Doing
  | "logseq.property/status.done" -> Some Done
  | "logseq.property/status.canceled" -> Some Cancelled
  | "logseq.property/status.waiting" -> Some Waiting
  | "logseq.property/status.now" -> Some Now
  | "logseq.property/status.later" -> Some Later
  | _ -> None
;;

let task_state context entity =
  match one context.db entity "logseq.property/status" with
  | Ok (Some (Datascript.Ref status)) ->
    (match one context.db status "db/ident" with
     | Ok (Some (Datascript.Keyword ident | String ident)) ->
       (match task_state_of_ident ident with
        | Some state -> Ok state
        | None -> Error (corrupt ()))
     | Ok None | Ok (Some _) | Error _ -> Error (corrupt ()))
  | Ok None -> Error (corrupt ())
  | Ok (Some _) | Error _ -> Error (corrupt ())
;;

let journal_day_of_unix_ms unix_ms =
  let time = Unix.gmtime (Int64.to_float unix_ms /. 1_000.) in
  ((time.tm_year + 1900) * 10_000) + ((time.tm_mon + 1) * 100) + time.tm_mday
;;

let optional_task_day context entity attr =
  match one context.db entity attr with
  | Ok None -> Ok None
  | Ok (Some (Datascript.Int value)) ->
    let value =
      if value >= 10_000_000 && value <= 99_999_999
      then value
      else journal_day_of_unix_ms (Int64.of_int value)
    in
    Ok (Some value)
  | Ok (Some (Datascript.Ref page)) -> optional_int context.db page "block/journal-day"
  | Ok (Some _) | Error _ -> Error (corrupt ())
;;

let within lower upper value =
  match value with
  | None -> Option.is_none lower && Option.is_none upper
  | Some value ->
    Option.fold ~none:true ~some:(fun lower -> value >= lower) lower
    && Option.fold ~none:true ~some:(fun upper -> value <= upper) upper
;;

let task_matches filter (task : task) =
  (filter.states = [] || List.mem task.state filter.states)
  && (match filter.page with
      | None -> true
      | Some page -> Uuid.equal page task.block.page)
  && within filter.scheduled_from filter.scheduled_through task.scheduled_day
  && within filter.deadline_from filter.deadline_through task.deadline_day
;;

let task_filter_json filter =
  let state = function
    | Todo -> "todo"
    | Doing -> "doing"
    | Done -> "done"
    | Cancelled -> "cancelled"
    | Waiting -> "waiting"
    | Now -> "now"
    | Later -> "later"
  in
  let option_int = function
    | None -> `Null
    | Some value -> `Int value
  in
  `Assoc
    [ "states", `List (List.map (fun value -> `String (state value)) filter.states)
    ; "page", Option.fold ~none:`Null ~some:uuid_json filter.page
    ; "scheduledFrom", option_int filter.scheduled_from
    ; "scheduledThrough", option_int filter.scheduled_through
    ; "deadlineFrom", option_int filter.deadline_from
    ; "deadlineThrough", option_int filter.deadline_through
    ]
;;

let list_tasks context filter limit cursor =
  let ( let* ) = Result.bind in
  let entities =
    match entity_of_ident context.db "logseq.class/Task" with
    | None -> []
    | Some class_entity ->
      Datascript.datoms
        context.db
        Datascript.Avet
        ~a:"block/tags"
        ~v:(Datascript.Ref class_entity)
        ()
      |> List.of_seq
      |> List.map (fun datom -> datom.Datascript.e)
      |> List.sort_uniq Int.compare
  in
  let rec project acc = function
    | [] -> Ok acc
    | entity :: rest ->
      let* block = project_block context.db entity in
      let* state = task_state context entity in
      let* scheduled_day = optional_task_day context entity "logseq.property/scheduled" in
      let* deadline_day = optional_task_day context entity "logseq.property/deadline" in
      let item = { block; state; scheduled_day; deadline_day } in
      let key =
        Uuid.to_string block.page
        ^ "\000"
        ^ block.order
        ^ "\000"
        ^ Uuid.to_string block.uuid
      in
      project (if task_matches filter item then (key, item) :: acc else acc) rest
  in
  let* items = project [] entities in
  let items = List.sort (fun (left, _) (right, _) -> String.compare left right) items in
  let query_fingerprint = fingerprint "listTasks" [ "filter", task_filter_json filter ] in
  let* page =
    paginate context ~fingerprint:query_fingerprint ~cursor ~limit ~key:fst items
  in
  Ok { items = List.map snd page.items; continuation = page.continuation }
;;

let entity_is_page db entity =
  match one db entity "block/name" with
  | Ok (Some (Datascript.String _)) -> true
  | Ok None | Ok (Some _) | Error _ -> false
;;

let reference_kind db attr target =
  match attr with
  | "block/refs" ->
    Some (if entity_is_page db target then Page_reference else Block_reference)
  | "block/tags" -> Some Tag_reference
  | "block/alias" -> Some Alias_reference
  | "logseq.property/scheduled" -> Some Scheduled_reference
  | "logseq.property/deadline" -> Some Deadline_reference
  | attr ->
    (match entity_of_ident db attr with
     | Some property when is_property_entity db property -> Some Property_reference
     | Some _ | None -> None)
;;

let reference_of_datom db datom =
  match datom.Datascript.v with
  | Datascript.Ref target ->
    (match
       ( reference_kind db datom.a target
       , uuid_of_entity db datom.e
       , uuid_of_entity db target )
     with
     | Some kind, Ok source, Ok target -> Some { source; target; kind }
     | _ -> None)
  | _ -> None
;;

let reference_kind_key = function
  | Block_reference -> "block"
  | Page_reference -> "page"
  | Tag_reference -> "tag"
  | Property_reference -> "property"
  | Scheduled_reference -> "scheduled"
  | Deadline_reference -> "deadline"
  | Alias_reference -> "alias"
;;

let reference_direction_json = function
  | Referring_to -> `String "referringTo"
  | Referred_from -> `String "referredFrom"
;;

let get_references context target direction limit cursor =
  let ( let* ) = Result.bind in
  let* entity = entity_of_uuid context.db target in
  let datoms =
    match direction with
    | Referred_from -> Datascript.datoms context.db Datascript.Eavt ~e:entity ()
    | Referring_to ->
      Datascript.datoms context.db Datascript.Avet ~v:(Datascript.Ref entity) ()
  in
  let items =
    datoms
    |> List.of_seq
    |> List.filter_map (reference_of_datom context.db)
    |> List.map (fun item ->
      let key =
        Uuid.to_string item.source
        ^ "\000"
        ^ Uuid.to_string item.target
        ^ "\000"
        ^ reference_kind_key item.kind
      in
      key, item)
    |> List.sort_uniq (fun (left, _) (right, _) -> String.compare left right)
  in
  let query_fingerprint =
    fingerprint
      "getReferences"
      [ "target", uuid_json target; "direction", reference_direction_json direction ]
  in
  let* page =
    paginate context ~fingerprint:query_fingerprint ~cursor ~limit ~key:fst items
  in
  Ok { items = List.map snd page.items; continuation = page.continuation }
;;

let execute context = function
  | Protocol.Graph_info -> Error (invalid_request "Graph_info is handled by the Engine.")
  | Get_block { block } ->
    Result.bind (entity_of_uuid context.db block) (project_block context.db)
    |> Result.map (fun block -> Protocol.Block_result block)
  | Get_page { page } ->
    get_page context.db page |> Result.map (fun page -> Protocol.Page_result page)
  | Get_children { parent; limit; cursor } ->
    get_children context parent limit cursor
    |> Result.map (fun page -> Protocol.Children_result page)
  | Get_page_tree { page; maximum_depth; limit; cursor } ->
    get_page_tree context page maximum_depth limit cursor
    |> Result.map (fun page -> Protocol.Page_tree_result page)
  | Get_ancestors { block; limit } ->
    get_ancestors context block limit
    |> Result.map (fun blocks -> Protocol.Ancestors_result blocks)
  | Get_siblings { block; limit; cursor } ->
    get_siblings context block limit cursor
    |> Result.map (fun result -> Protocol.Siblings_result result)
  | List_pages { kind; limit; cursor } ->
    list_pages context kind limit cursor
    |> Result.map (fun page -> Protocol.Pages_result page)
  | List_tags { limit; cursor } ->
    list_tags context limit cursor |> Result.map (fun page -> Protocol.Tags_result page)
  | List_properties { scope; limit; cursor } ->
    list_properties context scope limit cursor
    |> Result.map (fun page -> Protocol.Properties_result page)
  | List_tasks { filter; limit; cursor } ->
    list_tasks context filter limit cursor
    |> Result.map (fun page -> Protocol.Tasks_result page)
  | Get_references { target; direction; limit; cursor } ->
    get_references context target direction limit cursor
    |> Result.map (fun page -> Protocol.References_result page)
;;
