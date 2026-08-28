open Graph_types

type context =
  { mutation_id : Uuid.t
  ; expected_basis : int64
  }

type relative_position =
  | Before of block_uuid
  | After of block_uuid
  | First_child of block_uuid
  | Last_child of block_uuid

and insert_position =
  | Relative of relative_position
  | Replace_empty of block_uuid

and direction =
  | Up
  | Down

and indent_direction =
  | Indent
  | Direct_outdent

and block_tree =
  { uuid : block_uuid
  ; title : string
  ; children : block_tree list
  }

and structural_mutation =
  | Save_block of
      { block : block_uuid
      ; title : string
      ; context : context
      }
  | Insert_blocks of
      { roots : block_tree list
      ; position : insert_position
      ; context : context
      }
  | Move_blocks of
      { roots : block_uuid list
      ; position : relative_position
      ; context : context
      }
  | Move_up_down of
      { roots : block_uuid list
      ; direction : direction
      ; context : context
      }
  | Indent_outdent of
      { roots : block_uuid list
      ; direction : indent_direction
      ; context : context
      }
  | Delete_blocks of
      { roots : block_uuid list
      ; context : context
      }

and create_page_kind =
  | Create_ordinary_page of { uuid : page_uuid }
  | Create_journal_page of
      { journal_day : int
      ; supplied_uuid : page_uuid option
      }
  | Create_class_page of { uuid : class_uuid }

and page_mutation =
  | Create_page of
      { title : string
      ; kind : create_page_kind
      ; context : context
      }
  | Rename_page of
      { page : page_uuid
      ; title : string
      ; context : context
      }
  | Delete_page of
      { page : page_uuid
      ; context : context
      }
  | Restore_recycled_page of
      { page : page_uuid
      ; context : context
      }
  | Permanently_delete_recycled_page of
      { page : page_uuid
      ; context : context
      }

and property_identity =
  | Existing_property of property_selector
  | New_property of
      { ident : qualified_ident
      ; title : string
      }

and batch_set_mode =
  | Append of property_value
  | Replace of property_value list

and closed_value_action =
  | Add_closed_value of
      { value_uuid : block_uuid
      ; value : property_value
      ; icon : string option
      }
  | Update_closed_value of
      { value_uuid : block_uuid
      ; value : property_value
      ; icon : string option
      }
  | Associate_closed_value of { value_uuid : block_uuid }
  | Delete_closed_value of { value_uuid : block_uuid }

and class_property_action =
  | Add_class_property of { default_value : property_value option }
  | Remove_class_property

and property_mutation =
  | Upsert_property of
      { property : property_identity
      ; schema : property_schema
      ; context : context
      }
  | Set_property of
      { block : block_uuid
      ; property : property_selector
      ; value : property_value
      ; context : context
      }
  | Remove_property of
      { block : block_uuid
      ; property : property_selector
      ; context : context
      }
  | Batch_set_property of
      { blocks : block_uuid list
      ; property : property_selector
      ; mode : batch_set_mode
      ; context : context
      }
  | Batch_remove_property of
      { blocks : block_uuid list
      ; property : property_selector
      ; context : context
      }
  | Manage_closed_values of
      { property : property_selector
      ; action : closed_value_action
      ; context : context
      }
  | Manage_class_property of
      { class_ : class_uuid
      ; property : property_selector
      ; action : class_property_action
      ; context : context
      }

and t =
  | Structural of structural_mutation
  | Page of page_mutation
  | Property of property_mutation

type status =
  | Applied
  | No_change
  | Already_applied

type success =
  { status : status
  ; basis_before : int64
  ; basis_after : int64
  ; changed_uuids : Uuid.t list
  ; changed_uuids_truncated : bool
  }

let context = function
  | Structural (Save_block { context; _ })
  | Structural (Insert_blocks { context; _ })
  | Structural (Move_blocks { context; _ })
  | Structural (Move_up_down { context; _ })
  | Structural (Indent_outdent { context; _ })
  | Structural (Delete_blocks { context; _ })
  | Page (Create_page { context; _ })
  | Page (Rename_page { context; _ })
  | Page (Delete_page { context; _ })
  | Page (Restore_recycled_page { context; _ })
  | Page (Permanently_delete_recycled_page { context; _ })
  | Property (Upsert_property { context; _ })
  | Property (Set_property { context; _ })
  | Property (Remove_property { context; _ })
  | Property (Batch_set_property { context; _ })
  | Property (Batch_remove_property { context; _ })
  | Property (Manage_closed_values { context; _ })
  | Property (Manage_class_property { context; _ }) -> context
;;

exception Decode_error of string

let decode_error message = raise (Decode_error message)
let uuid_json value = `String (Uuid.to_string value)
let int64_json value = `String (Int64.to_string value)

let option_json encode = function
  | None -> `Null
  | Some value -> encode value
;;

let exact_assoc expected = function
  | `Assoc fields ->
    let actual = List.map fst fields |> List.sort String.compare in
    let expected = List.sort String.compare expected in
    if actual = expected
    then fields
    else decode_error "unknown, duplicate, or missing field"
  | _ -> decode_error "expected object"
;;

let field name fields =
  match List.assoc_opt name fields with
  | Some value -> value
  | None -> decode_error ("missing " ^ name)
;;

let string = function
  | `String value -> value
  | _ -> decode_error "expected string"
;;

let boolean = function
  | `Bool value -> value
  | _ -> decode_error "expected boolean"
;;

let integer = function
  | `Int value -> value
  | _ -> decode_error "expected integer"
;;

let int64 value =
  try Int64.of_string (string value) with
  | Failure _ -> decode_error "invalid int64"
;;

let uuid value =
  match Uuid.of_string (string value) with
  | Ok value -> value
  | Error message -> decode_error message
;;

let uuid_list = function
  | `List values -> List.map uuid values
  | _ -> decode_error "expected UUID list"
;;

let context_to_json context =
  `Assoc
    [ "mutationId", uuid_json context.mutation_id
    ; "expectedBasis", int64_json context.expected_basis
    ]
;;

let context_of_json json =
  let fields = exact_assoc [ "mutationId"; "expectedBasis" ] json in
  { mutation_id = uuid (field "mutationId" fields)
  ; expected_basis = int64 (field "expectedBasis" fields)
  }
;;

let property_selector_to_json = function
  | Property_by_ident ident -> `Assoc [ "type", `String "ident"; "ident", `String ident ]
  | Property_by_uuid uuid -> `Assoc [ "type", `String "uuid"; "uuid", uuid_json uuid ]
;;

let property_selector_of_json json =
  let raw =
    match json with
    | `Assoc fields -> fields
    | _ -> decode_error "invalid property selector"
  in
  match string (field "type" raw) with
  | "ident" ->
    let fields = exact_assoc [ "type"; "ident" ] json in
    Property_by_ident (string (field "ident" fields))
  | "uuid" ->
    let fields = exact_assoc [ "type"; "uuid" ] json in
    Property_by_uuid (uuid (field "uuid" fields))
  | _ -> decode_error "invalid property selector type"
;;

let property_type_string = function
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
  | Collection -> "collection"
  | Any -> "any"
  | Entity -> "entity"
  | Class -> "class"
  | Page -> "page"
  | Property -> "property"
  | String -> "string"
  | Json -> "json"
  | Raw_number -> "rawNumber"
;;

let property_type = function
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
  | "rawNumber" -> Raw_number
  | _ -> decode_error "invalid property type"
;;

let property_schema_to_json schema =
  `Assoc
    [ "type", `String (property_type_string schema.property_type)
    ; ( "cardinality"
      , `String
          (match schema.cardinality with
           | One -> "one"
           | Many -> "many") )
    ; "hidden", `Bool schema.hidden
    ; "public", `Bool schema.public
    ]
;;

let property_schema_of_json json =
  let fields = exact_assoc [ "type"; "cardinality"; "hidden"; "public" ] json in
  { property_type = property_type (string (field "type" fields))
  ; cardinality =
      (match string (field "cardinality" fields) with
       | "one" -> One
       | "many" -> Many
       | _ -> decode_error "invalid cardinality")
  ; hidden = boolean (field "hidden" fields)
  ; public = boolean (field "public" fields)
  }
;;

let rec internal_value_to_json = function
  | Internal_null -> `Assoc [ "type", `String "null" ]
  | Internal_bool value -> `Assoc [ "type", `String "boolean"; "value", `Bool value ]
  | Internal_number value -> `Assoc [ "type", `String "number"; "value", `String value ]
  | Internal_string value -> `Assoc [ "type", `String "string"; "value", `String value ]
  | Internal_keyword value -> `Assoc [ "type", `String "keyword"; "value", `String value ]
  | Internal_uuid value -> `Assoc [ "type", `String "uuid"; "value", uuid_json value ]
  | Internal_list values ->
    `Assoc
      [ "type", `String "list"; "values", `List (List.map internal_value_to_json values) ]
  | Internal_map entries ->
    `Assoc
      [ "type", `String "map"
      ; ( "entries"
        , `List
            (List.map
               (fun (key, value) ->
                  `Assoc
                    [ "key", internal_value_to_json key
                    ; "value", internal_value_to_json value
                    ])
               entries) )
      ]
;;

let rec internal_value_of_json json =
  let raw =
    match json with
    | `Assoc fields -> fields
    | _ -> decode_error "invalid internal value"
  in
  match string (field "type" raw) with
  | "null" ->
    ignore (exact_assoc [ "type" ] json);
    Internal_null
  | "boolean" ->
    let f = exact_assoc [ "type"; "value" ] json in
    Internal_bool (boolean (field "value" f))
  | "number" ->
    let f = exact_assoc [ "type"; "value" ] json in
    Internal_number (string (field "value" f))
  | "string" ->
    let f = exact_assoc [ "type"; "value" ] json in
    Internal_string (string (field "value" f))
  | "keyword" ->
    let f = exact_assoc [ "type"; "value" ] json in
    Internal_keyword (string (field "value" f))
  | "uuid" ->
    let f = exact_assoc [ "type"; "value" ] json in
    Internal_uuid (uuid (field "value" f))
  | "list" ->
    let f = exact_assoc [ "type"; "values" ] json in
    (match field "values" f with
     | `List xs -> Internal_list (List.map internal_value_of_json xs)
     | _ -> decode_error "invalid list")
  | "map" ->
    let f = exact_assoc [ "type"; "entries" ] json in
    (match field "entries" f with
     | `List xs ->
       Internal_map
         (List.map
            (fun item ->
               let e = exact_assoc [ "key"; "value" ] item in
               ( internal_value_of_json (field "key" e)
               , internal_value_of_json (field "value" e) ))
            xs)
     | _ -> decode_error "invalid map")
  | _ -> decode_error "invalid internal value type"
;;

let property_value_to_json = function
  | Default_value value -> `Assoc [ "type", `String "default"; "value", `String value ]
  | Number_value value -> `Assoc [ "type", `String "number"; "value", `String value ]
  | Date_value { journal_day } ->
    `Assoc [ "type", `String "date"; "journalDay", `Int journal_day ]
  | Datetime_value { unix_ms } ->
    `Assoc [ "type", `String "datetime"; "unixMs", int64_json unix_ms ]
  | Checkbox_value value -> `Assoc [ "type", `String "checkbox"; "value", `Bool value ]
  | Url_value value -> `Assoc [ "type", `String "url"; "value", `String value ]
  | Node_value value -> `Assoc [ "type", `String "node"; "value", uuid_json value ]
  | Asset_value value -> `Assoc [ "type", `String "asset"; "value", uuid_json value ]
  | Keyword_value value -> `Assoc [ "type", `String "keyword"; "value", `String value ]
  | Map_value entries ->
    `Assoc
      [ "type", `String "map"; "value", internal_value_to_json (Internal_map entries) ]
  | Collection_value values ->
    `Assoc
      [ "type", `String "collection"
      ; "value", internal_value_to_json (Internal_list values)
      ]
  | Any_value value ->
    `Assoc [ "type", `String "any"; "value", internal_value_to_json value ]
  | Entity_value value -> `Assoc [ "type", `String "entity"; "value", uuid_json value ]
  | Class_value value -> `Assoc [ "type", `String "class"; "value", uuid_json value ]
  | Page_value value -> `Assoc [ "type", `String "page"; "value", uuid_json value ]
  | Property_value value -> `Assoc [ "type", `String "property"; "value", `String value ]
  | String_value value -> `Assoc [ "type", `String "string"; "value", `String value ]
  | Json_value value -> `Assoc [ "type", `String "json"; "value", `String value ]
  | Raw_number_value value ->
    `Assoc [ "type", `String "rawNumber"; "value", `String value ]
;;

let property_value_of_json json =
  let raw =
    match json with
    | `Assoc fields -> fields
    | _ -> decode_error "invalid property value"
  in
  let kind = string (field "type" raw) in
  let scalar decode constructor =
    let f = exact_assoc [ "type"; "value" ] json in
    constructor (decode (field "value" f))
  in
  match kind with
  | "default" -> scalar string (fun x -> Default_value x)
  | "number" -> scalar string (fun x -> Number_value x)
  | "date" ->
    let f = exact_assoc [ "type"; "journalDay" ] json in
    Date_value { journal_day = integer (field "journalDay" f) }
  | "datetime" ->
    let f = exact_assoc [ "type"; "unixMs" ] json in
    Datetime_value { unix_ms = int64 (field "unixMs" f) }
  | "checkbox" -> scalar boolean (fun x -> Checkbox_value x)
  | "url" -> scalar string (fun x -> Url_value x)
  | "node" -> scalar uuid (fun x -> Node_value x)
  | "asset" -> scalar uuid (fun x -> Asset_value x)
  | "keyword" -> scalar string (fun x -> Keyword_value x)
  | "entity" -> scalar uuid (fun x -> Entity_value x)
  | "class" -> scalar uuid (fun x -> Class_value x)
  | "page" -> scalar uuid (fun x -> Page_value x)
  | "property" -> scalar string (fun x -> Property_value x)
  | "string" -> scalar string (fun x -> String_value x)
  | "json" -> scalar string (fun x -> Json_value x)
  | "rawNumber" -> scalar string (fun x -> Raw_number_value x)
  | "map" ->
    scalar internal_value_of_json (function
      | Internal_map x -> Map_value x
      | _ -> decode_error "expected internal map")
  | "collection" ->
    scalar internal_value_of_json (function
      | Internal_list x -> Collection_value x
      | _ -> decode_error "expected internal list")
  | "any" -> scalar internal_value_of_json (fun x -> Any_value x)
  | _ -> decode_error "invalid property value type"
;;

let position_to_json = function
  | Before block -> `Assoc [ "type", `String "before"; "block", uuid_json block ]
  | After block -> `Assoc [ "type", `String "after"; "block", uuid_json block ]
  | First_child block -> `Assoc [ "type", `String "firstChild"; "block", uuid_json block ]
  | Last_child block -> `Assoc [ "type", `String "lastChild"; "block", uuid_json block ]
;;

let position_of_json json =
  let fields = exact_assoc [ "type"; "block" ] json in
  let block = uuid (field "block" fields) in
  match string (field "type" fields) with
  | "before" -> Before block
  | "after" -> After block
  | "firstChild" -> First_child block
  | "lastChild" -> Last_child block
  | _ -> decode_error "invalid position"
;;

let rec block_tree_to_json tree =
  `Assoc
    [ "uuid", uuid_json tree.uuid
    ; "title", `String tree.title
    ; "children", `List (List.map block_tree_to_json tree.children)
    ]
;;

let rec block_tree_of_json json =
  let fields = exact_assoc [ "uuid"; "title"; "children" ] json in
  { uuid = uuid (field "uuid" fields)
  ; title = string (field "title" fields)
  ; children =
      (match field "children" fields with
       | `List xs -> List.map block_tree_of_json xs
       | _ -> decode_error "invalid children")
  }
;;

let uuids_json values = `List (List.map uuid_json values)
let with_context fields context = `Assoc (fields @ [ "context", context_to_json context ])

let property_identity_to_json = function
  | Existing_property selector ->
    `Assoc [ "type", `String "existing"; "property", property_selector_to_json selector ]
  | New_property { ident; title } ->
    `Assoc [ "type", `String "new"; "ident", `String ident; "title", `String title ]
;;

let property_identity_of_json json =
  let raw =
    match json with
    | `Assoc fields -> fields
    | _ -> decode_error "invalid property identity"
  in
  match string (field "type" raw) with
  | "existing" ->
    let f = exact_assoc [ "type"; "property" ] json in
    Existing_property (property_selector_of_json (field "property" f))
  | "new" ->
    let f = exact_assoc [ "type"; "ident"; "title" ] json in
    New_property { ident = string (field "ident" f); title = string (field "title" f) }
  | _ -> decode_error "invalid property identity type"
;;

let create_page_kind_to_json = function
  | Create_ordinary_page { uuid } ->
    `Assoc [ "type", `String "ordinary"; "uuid", uuid_json uuid ]
  | Create_class_page { uuid } ->
    `Assoc [ "type", `String "class"; "uuid", uuid_json uuid ]
  | Create_journal_page { journal_day; supplied_uuid } ->
    `Assoc
      [ "type", `String "journal"
      ; "journalDay", `Int journal_day
      ; "suppliedUuid", option_json uuid_json supplied_uuid
      ]
;;

let create_page_kind_of_json json =
  let raw =
    match json with
    | `Assoc fields -> fields
    | _ -> decode_error "invalid create page kind"
  in
  match string (field "type" raw) with
  | "ordinary" ->
    let f = exact_assoc [ "type"; "uuid" ] json in
    Create_ordinary_page { uuid = uuid (field "uuid" f) }
  | "class" ->
    let f = exact_assoc [ "type"; "uuid" ] json in
    Create_class_page { uuid = uuid (field "uuid" f) }
  | "journal" ->
    let f = exact_assoc [ "type"; "journalDay"; "suppliedUuid" ] json in
    Create_journal_page
      { journal_day = integer (field "journalDay" f)
      ; supplied_uuid =
          (match field "suppliedUuid" f with
           | `Null -> None
           | x -> Some (uuid x))
      }
  | _ -> decode_error "invalid create page kind type"
;;

let to_yojson = function
  | Structural (Save_block { block; title; context }) ->
    with_context
      [ "type", `String "saveBlock"; "block", uuid_json block; "title", `String title ]
      context
  | Structural (Insert_blocks { roots; position; context }) ->
    let position =
      match position with
      | Relative p -> position_to_json p
      | Replace_empty block ->
        `Assoc [ "type", `String "replaceEmpty"; "block", uuid_json block ]
    in
    with_context
      [ "type", `String "insertBlocks"
      ; "roots", `List (List.map block_tree_to_json roots)
      ; "position", position
      ]
      context
  | Structural (Move_blocks { roots; position; context }) ->
    with_context
      [ "type", `String "moveBlocks"
      ; "roots", uuids_json roots
      ; "position", position_to_json position
      ]
      context
  | Structural (Move_up_down { roots; direction; context }) ->
    with_context
      [ "type", `String "moveUpDown"
      ; "roots", uuids_json roots
      ; ( "direction"
        , `String
            (match direction with
             | Up -> "up"
             | Down -> "down") )
      ]
      context
  | Structural (Indent_outdent { roots; direction; context }) ->
    with_context
      [ "type", `String "indentOutdent"
      ; "roots", uuids_json roots
      ; ( "direction"
        , `String
            (match direction with
             | Indent -> "indent"
             | Direct_outdent -> "directOutdent") )
      ]
      context
  | Structural (Delete_blocks { roots; context }) ->
    with_context [ "type", `String "deleteBlocks"; "roots", uuids_json roots ] context
  | Page (Create_page { title; kind; context }) ->
    with_context
      [ "type", `String "createPage"
      ; "title", `String title
      ; "kind", create_page_kind_to_json kind
      ]
      context
  | Page (Rename_page { page; title; context }) ->
    with_context
      [ "type", `String "renamePage"; "page", uuid_json page; "title", `String title ]
      context
  | Page (Delete_page { page; context }) ->
    with_context [ "type", `String "deletePage"; "page", uuid_json page ] context
  | Page (Restore_recycled_page { page; context }) ->
    with_context [ "type", `String "restoreRecycledPage"; "page", uuid_json page ] context
  | Page (Permanently_delete_recycled_page { page; context }) ->
    with_context
      [ "type", `String "permanentlyDeleteRecycledPage"; "page", uuid_json page ]
      context
  | Property (Upsert_property { property; schema; context }) ->
    with_context
      [ "type", `String "upsertProperty"
      ; "property", property_identity_to_json property
      ; "schema", property_schema_to_json schema
      ]
      context
  | Property (Set_property { block; property; value; context }) ->
    with_context
      [ "type", `String "setProperty"
      ; "block", uuid_json block
      ; "property", property_selector_to_json property
      ; "value", property_value_to_json value
      ]
      context
  | Property (Remove_property { block; property; context }) ->
    with_context
      [ "type", `String "removeProperty"
      ; "block", uuid_json block
      ; "property", property_selector_to_json property
      ]
      context
  | Property (Batch_set_property { blocks; property; mode; context }) ->
    let mode =
      match mode with
      | Append value ->
        `Assoc [ "type", `String "append"; "value", property_value_to_json value ]
      | Replace values ->
        `Assoc
          [ "type", `String "replace"
          ; "values", `List (List.map property_value_to_json values)
          ]
    in
    with_context
      [ "type", `String "batchSetProperty"
      ; "blocks", uuids_json blocks
      ; "property", property_selector_to_json property
      ; "mode", mode
      ]
      context
  | Property (Batch_remove_property { blocks; property; context }) ->
    with_context
      [ "type", `String "batchRemoveProperty"
      ; "blocks", uuids_json blocks
      ; "property", property_selector_to_json property
      ]
      context
  | Property (Manage_closed_values { property; action; context }) ->
    let action =
      match action with
      | Add_closed_value { value_uuid; value; icon } ->
        `Assoc
          [ "type", `String "add"
          ; "valueUuid", uuid_json value_uuid
          ; "value", property_value_to_json value
          ; "icon", option_json (fun x -> `String x) icon
          ]
      | Update_closed_value { value_uuid; value; icon } ->
        `Assoc
          [ "type", `String "update"
          ; "valueUuid", uuid_json value_uuid
          ; "value", property_value_to_json value
          ; "icon", option_json (fun x -> `String x) icon
          ]
      | Associate_closed_value { value_uuid } ->
        `Assoc [ "type", `String "associate"; "valueUuid", uuid_json value_uuid ]
      | Delete_closed_value { value_uuid } ->
        `Assoc [ "type", `String "delete"; "valueUuid", uuid_json value_uuid ]
    in
    with_context
      [ "type", `String "manageClosedValues"
      ; "property", property_selector_to_json property
      ; "action", action
      ]
      context
  | Property (Manage_class_property { class_; property; action; context }) ->
    let action =
      match action with
      | Add_class_property { default_value } ->
        `Assoc
          [ "type", `String "add"
          ; "defaultValue", option_json property_value_to_json default_value
          ]
      | Remove_class_property -> `Assoc [ "type", `String "remove" ]
    in
    with_context
      [ "type", `String "manageClassProperty"
      ; "class", uuid_json class_
      ; "property", property_selector_to_json property
      ; "action", action
      ]
      context
;;

let of_yojson_kind kind json =
  let f names = exact_assoc ("type" :: "context" :: names) json in
  let roots field_name fields = uuid_list (field field_name fields) in
  match kind with
  | "saveBlock" ->
    let x = f [ "block"; "title" ] in
    Structural
      (Save_block
         { block = uuid (field "block" x)
         ; title = string (field "title" x)
         ; context = context_of_json (field "context" x)
         })
  | "insertBlocks" ->
    let x = f [ "roots"; "position" ] in
    let position_json = field "position" x in
    let raw =
      match position_json with
      | `Assoc fields -> fields
      | _ -> decode_error "invalid insert position"
    in
    let position =
      match string (field "type" raw) with
      | "replaceEmpty" ->
        let p = exact_assoc [ "type"; "block" ] position_json in
        Replace_empty (uuid (field "block" p))
      | _ -> Relative (position_of_json position_json)
    in
    Structural
      (Insert_blocks
         { roots =
             (match field "roots" x with
              | `List values -> List.map block_tree_of_json values
              | _ -> decode_error "invalid roots")
         ; position
         ; context = context_of_json (field "context" x)
         })
  | "moveBlocks" ->
    let x = f [ "roots"; "position" ] in
    Structural
      (Move_blocks
         { roots = roots "roots" x
         ; position = position_of_json (field "position" x)
         ; context = context_of_json (field "context" x)
         })
  | "moveUpDown" ->
    let x = f [ "roots"; "direction" ] in
    Structural
      (Move_up_down
         { roots = roots "roots" x
         ; direction =
             (match string (field "direction" x) with
              | "up" -> Up
              | "down" -> Down
              | _ -> decode_error "invalid direction")
         ; context = context_of_json (field "context" x)
         })
  | "indentOutdent" ->
    let x = f [ "roots"; "direction" ] in
    Structural
      (Indent_outdent
         { roots = roots "roots" x
         ; direction =
             (match string (field "direction" x) with
              | "indent" -> Indent
              | "directOutdent" -> Direct_outdent
              | _ -> decode_error "invalid indent direction")
         ; context = context_of_json (field "context" x)
         })
  | "deleteBlocks" ->
    let x = f [ "roots" ] in
    Structural
      (Delete_blocks
         { roots = roots "roots" x; context = context_of_json (field "context" x) })
  | "createPage" ->
    let x = f [ "title"; "kind" ] in
    Page
      (Create_page
         { title = string (field "title" x)
         ; kind = create_page_kind_of_json (field "kind" x)
         ; context = context_of_json (field "context" x)
         })
  | "renamePage" ->
    let x = f [ "page"; "title" ] in
    Page
      (Rename_page
         { page = uuid (field "page" x)
         ; title = string (field "title" x)
         ; context = context_of_json (field "context" x)
         })
  | ("deletePage" | "restoreRecycledPage" | "permanentlyDeleteRecycledPage") as page_kind
    ->
    let x = f [ "page" ] in
    let page = uuid (field "page" x)
    and context = context_of_json (field "context" x) in
    Page
      (match page_kind with
       | "deletePage" -> Delete_page { page; context }
       | "restoreRecycledPage" -> Restore_recycled_page { page; context }
       | _ -> Permanently_delete_recycled_page { page; context })
  | "upsertProperty" ->
    let x = f [ "property"; "schema" ] in
    Property
      (Upsert_property
         { property = property_identity_of_json (field "property" x)
         ; schema = property_schema_of_json (field "schema" x)
         ; context = context_of_json (field "context" x)
         })
  | "setProperty" ->
    let x = f [ "block"; "property"; "value" ] in
    Property
      (Set_property
         { block = uuid (field "block" x)
         ; property = property_selector_of_json (field "property" x)
         ; value = property_value_of_json (field "value" x)
         ; context = context_of_json (field "context" x)
         })
  | "removeProperty" ->
    let x = f [ "block"; "property" ] in
    Property
      (Remove_property
         { block = uuid (field "block" x)
         ; property = property_selector_of_json (field "property" x)
         ; context = context_of_json (field "context" x)
         })
  | "batchSetProperty" ->
    let x = f [ "blocks"; "property"; "mode" ] in
    let mode_json = field "mode" x in
    let raw =
      match mode_json with
      | `Assoc fields -> fields
      | _ -> decode_error "invalid batch mode"
    in
    let mode =
      match string (field "type" raw) with
      | "append" ->
        let m = exact_assoc [ "type"; "value" ] mode_json in
        Append (property_value_of_json (field "value" m))
      | "replace" ->
        let m = exact_assoc [ "type"; "values" ] mode_json in
        Replace
          (match field "values" m with
           | `List values -> List.map property_value_of_json values
           | _ -> decode_error "invalid replace values")
      | _ -> decode_error "invalid batch mode type"
    in
    Property
      (Batch_set_property
         { blocks = roots "blocks" x
         ; property = property_selector_of_json (field "property" x)
         ; mode
         ; context = context_of_json (field "context" x)
         })
  | "batchRemoveProperty" ->
    let x = f [ "blocks"; "property" ] in
    Property
      (Batch_remove_property
         { blocks = roots "blocks" x
         ; property = property_selector_of_json (field "property" x)
         ; context = context_of_json (field "context" x)
         })
  | "manageClosedValues" ->
    let x = f [ "property"; "action" ] in
    let action_json = field "action" x in
    let raw =
      match action_json with
      | `Assoc fields -> fields
      | _ -> decode_error "invalid closed action"
    in
    let action =
      match string (field "type" raw) with
      | ("add" | "update") as action_kind ->
        let a = exact_assoc [ "type"; "valueUuid"; "value"; "icon" ] action_json in
        let value_uuid = uuid (field "valueUuid" a)
        and value = property_value_of_json (field "value" a)
        and icon =
          match field "icon" a with
          | `Null -> None
          | v -> Some (string v)
        in
        if action_kind = "add"
        then Add_closed_value { value_uuid; value; icon }
        else Update_closed_value { value_uuid; value; icon }
      | "associate" ->
        let a = exact_assoc [ "type"; "valueUuid" ] action_json in
        Associate_closed_value { value_uuid = uuid (field "valueUuid" a) }
      | "delete" ->
        let a = exact_assoc [ "type"; "valueUuid" ] action_json in
        Delete_closed_value { value_uuid = uuid (field "valueUuid" a) }
      | _ -> decode_error "invalid closed action type"
    in
    Property
      (Manage_closed_values
         { property = property_selector_of_json (field "property" x)
         ; action
         ; context = context_of_json (field "context" x)
         })
  | "manageClassProperty" ->
    let x = f [ "class"; "property"; "action" ] in
    let action_json = field "action" x in
    let raw =
      match action_json with
      | `Assoc fields -> fields
      | _ -> decode_error "invalid class action"
    in
    let action =
      match string (field "type" raw) with
      | "remove" ->
        ignore (exact_assoc [ "type" ] action_json);
        Remove_class_property
      | "add" ->
        let a = exact_assoc [ "type"; "defaultValue" ] action_json in
        Add_class_property
          { default_value =
              (match field "defaultValue" a with
               | `Null -> None
               | v -> Some (property_value_of_json v))
          }
      | _ -> decode_error "invalid class action type"
    in
    Property
      (Manage_class_property
         { class_ = uuid (field "class" x)
         ; property = property_selector_of_json (field "property" x)
         ; action
         ; context = context_of_json (field "context" x)
         })
  | _ -> decode_error "unknown mutation command"
;;

let decode decoder json =
  try Ok (decoder json) with
  | Decode_error message -> Error message
;;

let of_yojson json =
  try
    let fields =
      match json with
      | `Assoc fields -> fields
      | _ -> decode_error "invalid mutation command"
    in
    let kind = string (field "type" fields) in
    Ok (of_yojson_kind kind json)
  with
  | Decode_error message -> Error message
;;

let property_selector_to_yojson = property_selector_to_json
let property_selector_of_yojson = decode property_selector_of_json
let property_schema_to_yojson = property_schema_to_json
let property_schema_of_yojson = decode property_schema_of_json
let property_value_to_yojson = property_value_to_json
let property_value_of_yojson = decode property_value_of_json
