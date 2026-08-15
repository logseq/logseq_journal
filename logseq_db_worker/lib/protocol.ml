open Graph_types

let api_version = 1
let maximum_request_bytes = 1_048_576
let maximum_response_bytes = 262_144
let maximum_push_bytes = 65_536
let default_page_size = 50
let maximum_page_size = 200
let maximum_tree_nodes = 2_000
let maximum_tree_depth = 64
let maximum_title_bytes = 65_536
let maximum_roots = 1_024
let maximum_changed_uuids = 1_024
let maximum_property_values = 1_024
let maximum_filter_values = 64

type request =
  { api_version : int
  ; request_id : Uuid.t
  ; command : command
  }

and mutation_context =
  { mutation_id : Uuid.t
  ; expected_basis : int64
  }

and command =
  | Read of read_command
  | Mutate of mutation

and read_command =
  | Graph_info
  | Get_block of { block : block_uuid }
  | Get_page of { page : page_selector }
  | Get_children of
      { parent : Uuid.t
      ; limit : int
      ; cursor : Cursor.t option
      }
  | Get_page_tree of
      { page : page_uuid
      ; maximum_depth : int
      ; limit : int
      ; cursor : Cursor.t option
      }
  | Get_ancestors of
      { block : block_uuid
      ; limit : int
      }
  | Get_siblings of
      { block : block_uuid
      ; limit : int
      ; cursor : Cursor.t option
      }
  | List_pages of
      { kind : page_kind_filter
      ; limit : int
      ; cursor : Cursor.t option
      }
  | List_tags of
      { limit : int
      ; cursor : Cursor.t option
      }
  | List_properties of
      { scope : property_scope
      ; limit : int
      ; cursor : Cursor.t option
      }
  | List_tasks of
      { filter : task_filter
      ; limit : int
      ; cursor : Cursor.t option
      }
  | Get_references of
      { target : Uuid.t
      ; direction : reference_direction
      ; limit : int
      ; cursor : Cursor.t option
      }

and relative_position =
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
      ; context : mutation_context
      }
  | Insert_blocks of
      { roots : block_tree list
      ; position : insert_position
      ; context : mutation_context
      }
  | Move_blocks of
      { roots : block_uuid list
      ; position : relative_position
      ; context : mutation_context
      }
  | Move_up_down of
      { roots : block_uuid list
      ; direction : direction
      ; context : mutation_context
      }
  | Indent_outdent of
      { roots : block_uuid list
      ; direction : indent_direction
      ; context : mutation_context
      }
  | Delete_blocks of
      { roots : block_uuid list
      ; context : mutation_context
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
      ; context : mutation_context
      }
  | Rename_page of
      { page : page_uuid
      ; title : string
      ; context : mutation_context
      }
  | Delete_page of
      { page : page_uuid
      ; context : mutation_context
      }
  | Restore_recycled_page of
      { page : page_uuid
      ; context : mutation_context
      }
  | Permanently_delete_recycled_page of
      { page : page_uuid
      ; context : mutation_context
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
      ; context : mutation_context
      }
  | Set_property of
      { block : block_uuid
      ; property : property_selector
      ; value : property_value
      ; context : mutation_context
      }
  | Remove_property of
      { block : block_uuid
      ; property : property_selector
      ; context : mutation_context
      }
  | Batch_set_property of
      { blocks : block_uuid list
      ; property : property_selector
      ; mode : batch_set_mode
      ; context : mutation_context
      }
  | Batch_remove_property of
      { blocks : block_uuid list
      ; property : property_selector
      ; context : mutation_context
      }
  | Manage_closed_values of
      { property : property_selector
      ; action : closed_value_action
      ; context : mutation_context
      }
  | Manage_class_property of
      { class_ : class_uuid
      ; property : property_selector
      ; action : class_property_action
      ; context : mutation_context
      }

and mutation =
  | Structural of structural_mutation
  | Page of page_mutation
  | Property of property_mutation

type mutation_status =
  | Applied
  | No_change
  | Already_applied

type mutation_success =
  { status : mutation_status
  ; basis_before : int64
  ; basis_after : int64
  ; changed_uuids : Uuid.t list
  ; changed_uuids_truncated : bool
  }

type success =
  | Graph_info_result of graph_info
  | Block_result of block
  | Page_result of page
  | Children_result of block page_result
  | Page_tree_result of block_tree_item page_result
  | Ancestors_result of block list
  | Siblings_result of sibling_result
  | Pages_result of page_summary page_result
  | Tags_result of tag_summary page_result
  | Properties_result of property_definition page_result
  | Tasks_result of task page_result
  | References_result of reference page_result
  | Mutation_result of mutation_success

type failure_phase =
  | Open
  | Execute

type failure =
  { request_id : Uuid.t
  ; phase : failure_phase
  ; basis : int64 option
  ; error : Error.t
  }

type response =
  | Succeeded of
      { request_id : Uuid.t
      ; basis : int64
      ; success : success
      }
  | Failed of failure

type invalidation =
  { basis : int64
  ; changed_uuids : Uuid.t list
  ; changed_uuids_truncated : bool
  ; invalidate_graph_info : bool
  ; invalidate_pages : bool
  ; invalidate_tags : bool
  ; invalidate_properties : bool
  ; invalidate_tasks : bool
  ; invalidate_references : bool
  }

type push = Graph_invalidated of invalidation

let failed ~request_id ~phase ~basis error = Failed { request_id; phase; basis; error }

let mutation_context = function
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
let cursor_json value = `String (Cursor.to_string value)
let int64_json value = `String (Int64.to_string value)
let option_json encode = function None -> `Null | Some value -> encode value

let exact_assoc expected = function
  | `Assoc fields ->
      let actual = List.map fst fields |> List.sort String.compare in
      let expected = List.sort String.compare expected in
      if actual = expected then fields else decode_error "unknown, duplicate, or missing field"
  | _ -> decode_error "expected object"

let field name fields =
  match List.assoc_opt name fields with Some value -> value | None -> decode_error ("missing " ^ name)

let string = function `String value -> value | _ -> decode_error "expected string"
let boolean = function `Bool value -> value | _ -> decode_error "expected boolean"
let integer = function `Int value -> value | _ -> decode_error "expected integer"
let int64 value = try Int64.of_string (string value) with Failure _ -> decode_error "invalid int64"
let uuid value = match Uuid.of_string (string value) with Ok value -> value | Error message -> decode_error message
let cursor = function `Null -> None | value -> (match Cursor.of_string (string value) with Ok value -> Some value | Error message -> decode_error message)
let uuid_list = function `List values -> List.map uuid values | _ -> decode_error "expected UUID list"

let context_to_json context =
  `Assoc [ "mutationId", uuid_json context.mutation_id; "expectedBasis", int64_json context.expected_basis ]

let context_of_json json =
  let fields = exact_assoc [ "mutationId"; "expectedBasis" ] json in
  { mutation_id = uuid (field "mutationId" fields); expected_basis = int64 (field "expectedBasis" fields) }

let page_kind_filter_string = function
  | Any_page -> "any" | Only_ordinary_pages -> "ordinary" | Only_journals -> "journal"
  | Only_classes -> "class" | Only_properties -> "property"

let page_kind_filter = function
  | "any" -> Any_page | "ordinary" -> Only_ordinary_pages | "journal" -> Only_journals
  | "class" -> Only_classes | "property" -> Only_properties
  | _ -> decode_error "invalid page kind filter"

let page_selector_to_json = function
  | Page_by_uuid uuid -> `Assoc [ "type", `String "uuid"; "uuid", uuid_json uuid ]
  | Page_by_name { name; kind } ->
      `Assoc [ "type", `String "name"; "name", `String name; "kind", `String (page_kind_filter_string kind) ]

let page_selector_of_json json =
  match field "type" (match json with `Assoc fields -> fields | _ -> decode_error "invalid page selector") |> string with
  | "uuid" -> let fields = exact_assoc [ "type"; "uuid" ] json in Page_by_uuid (uuid (field "uuid" fields))
  | "name" ->
      let fields = exact_assoc [ "type"; "name"; "kind" ] json in
      Page_by_name { name = string (field "name" fields); kind = page_kind_filter (string (field "kind" fields)) }
  | _ -> decode_error "invalid page selector type"

let property_selector_to_json = function
  | Property_by_ident ident -> `Assoc [ "type", `String "ident"; "ident", `String ident ]
  | Property_by_uuid uuid -> `Assoc [ "type", `String "uuid"; "uuid", uuid_json uuid ]

let property_selector_of_json json =
  let raw = match json with `Assoc fields -> fields | _ -> decode_error "invalid property selector" in
  match string (field "type" raw) with
  | "ident" -> let fields = exact_assoc [ "type"; "ident" ] json in Property_by_ident (string (field "ident" fields))
  | "uuid" -> let fields = exact_assoc [ "type"; "uuid" ] json in Property_by_uuid (uuid (field "uuid" fields))
  | _ -> decode_error "invalid property selector type"

let property_type_string = function
  | Default -> "default" | Number -> "number" | Date -> "date" | Datetime -> "datetime"
  | Checkbox -> "checkbox" | Url -> "url" | Node -> "node" | Asset -> "asset"
  | Keyword -> "keyword" | Map -> "map" | Collection -> "collection" | Any -> "any"
  | Entity -> "entity" | Class -> "class" | Page -> "page" | Property -> "property"
  | String -> "string" | Json -> "json" | Raw_number -> "rawNumber"

let property_type = function
  | "default" -> Default | "number" -> Number | "date" -> Date | "datetime" -> Datetime
  | "checkbox" -> Checkbox | "url" -> Url | "node" -> Node | "asset" -> Asset
  | "keyword" -> Keyword | "map" -> Map | "collection" -> Collection | "any" -> Any
  | "entity" -> Entity | "class" -> Class | "page" -> Page | "property" -> Property
  | "string" -> String | "json" -> Json | "rawNumber" -> Raw_number
  | _ -> decode_error "invalid property type"

let property_schema_to_json schema =
  `Assoc
    [ "type", `String (property_type_string schema.property_type)
    ; "cardinality", `String (match schema.cardinality with One -> "one" | Many -> "many")
    ; "hidden", `Bool schema.hidden
    ; "public", `Bool schema.public
    ]

let property_schema_of_json json =
  let fields = exact_assoc [ "type"; "cardinality"; "hidden"; "public" ] json in
  { property_type = property_type (string (field "type" fields))
  ; cardinality = (match string (field "cardinality" fields) with "one" -> One | "many" -> Many | _ -> decode_error "invalid cardinality")
  ; hidden = boolean (field "hidden" fields)
  ; public = boolean (field "public" fields)
  }

let rec internal_value_to_json = function
  | Internal_null -> `Assoc [ "type", `String "null" ]
  | Internal_bool value -> `Assoc [ "type", `String "boolean"; "value", `Bool value ]
  | Internal_number value -> `Assoc [ "type", `String "number"; "value", `String value ]
  | Internal_string value -> `Assoc [ "type", `String "string"; "value", `String value ]
  | Internal_keyword value -> `Assoc [ "type", `String "keyword"; "value", `String value ]
  | Internal_uuid value -> `Assoc [ "type", `String "uuid"; "value", uuid_json value ]
  | Internal_list values -> `Assoc [ "type", `String "list"; "values", `List (List.map internal_value_to_json values) ]
  | Internal_map entries ->
      `Assoc [ "type", `String "map"; "entries", `List (List.map (fun (key, value) -> `Assoc [ "key", internal_value_to_json key; "value", internal_value_to_json value ]) entries) ]

let rec internal_value_of_json json =
  let raw = match json with `Assoc fields -> fields | _ -> decode_error "invalid internal value" in
  match string (field "type" raw) with
  | "null" -> ignore (exact_assoc [ "type" ] json); Internal_null
  | "boolean" -> let f = exact_assoc [ "type"; "value" ] json in Internal_bool (boolean (field "value" f))
  | "number" -> let f = exact_assoc [ "type"; "value" ] json in Internal_number (string (field "value" f))
  | "string" -> let f = exact_assoc [ "type"; "value" ] json in Internal_string (string (field "value" f))
  | "keyword" -> let f = exact_assoc [ "type"; "value" ] json in Internal_keyword (string (field "value" f))
  | "uuid" -> let f = exact_assoc [ "type"; "value" ] json in Internal_uuid (uuid (field "value" f))
  | "list" -> let f = exact_assoc [ "type"; "values" ] json in (match field "values" f with `List xs -> Internal_list (List.map internal_value_of_json xs) | _ -> decode_error "invalid list")
  | "map" ->
      let f = exact_assoc [ "type"; "entries" ] json in
      (match field "entries" f with
       | `List xs -> Internal_map (List.map (fun item -> let e = exact_assoc [ "key"; "value" ] item in internal_value_of_json (field "key" e), internal_value_of_json (field "value" e)) xs)
       | _ -> decode_error "invalid map")
  | _ -> decode_error "invalid internal value type"

let property_value_to_json = function
  | Default_value value -> `Assoc [ "type", `String "default"; "value", `String value ]
  | Number_value value -> `Assoc [ "type", `String "number"; "value", `String value ]
  | Date_value { journal_day } -> `Assoc [ "type", `String "date"; "journalDay", `Int journal_day ]
  | Datetime_value { unix_ms } -> `Assoc [ "type", `String "datetime"; "unixMs", int64_json unix_ms ]
  | Checkbox_value value -> `Assoc [ "type", `String "checkbox"; "value", `Bool value ]
  | Url_value value -> `Assoc [ "type", `String "url"; "value", `String value ]
  | Node_value value -> `Assoc [ "type", `String "node"; "value", uuid_json value ]
  | Asset_value value -> `Assoc [ "type", `String "asset"; "value", uuid_json value ]
  | Keyword_value value -> `Assoc [ "type", `String "keyword"; "value", `String value ]
  | Map_value entries -> `Assoc [ "type", `String "map"; "value", internal_value_to_json (Internal_map entries) ]
  | Collection_value values -> `Assoc [ "type", `String "collection"; "value", internal_value_to_json (Internal_list values) ]
  | Any_value value -> `Assoc [ "type", `String "any"; "value", internal_value_to_json value ]
  | Entity_value value -> `Assoc [ "type", `String "entity"; "value", uuid_json value ]
  | Class_value value -> `Assoc [ "type", `String "class"; "value", uuid_json value ]
  | Page_value value -> `Assoc [ "type", `String "page"; "value", uuid_json value ]
  | Property_value value -> `Assoc [ "type", `String "property"; "value", `String value ]
  | String_value value -> `Assoc [ "type", `String "string"; "value", `String value ]
  | Json_value value -> `Assoc [ "type", `String "json"; "value", `String value ]
  | Raw_number_value value -> `Assoc [ "type", `String "rawNumber"; "value", `String value ]

let property_value_of_json json =
  let raw = match json with `Assoc fields -> fields | _ -> decode_error "invalid property value" in
  let kind = string (field "type" raw) in
  let scalar decode constructor = let f = exact_assoc [ "type"; "value" ] json in constructor (decode (field "value" f)) in
  match kind with
  | "default" -> scalar string (fun x -> Default_value x) | "number" -> scalar string (fun x -> Number_value x)
  | "date" -> let f = exact_assoc [ "type"; "journalDay" ] json in Date_value { journal_day = integer (field "journalDay" f) }
  | "datetime" -> let f = exact_assoc [ "type"; "unixMs" ] json in Datetime_value { unix_ms = int64 (field "unixMs" f) }
  | "checkbox" -> scalar boolean (fun x -> Checkbox_value x) | "url" -> scalar string (fun x -> Url_value x)
  | "node" -> scalar uuid (fun x -> Node_value x) | "asset" -> scalar uuid (fun x -> Asset_value x)
  | "keyword" -> scalar string (fun x -> Keyword_value x) | "entity" -> scalar uuid (fun x -> Entity_value x)
  | "class" -> scalar uuid (fun x -> Class_value x) | "page" -> scalar uuid (fun x -> Page_value x)
  | "property" -> scalar string (fun x -> Property_value x) | "string" -> scalar string (fun x -> String_value x)
  | "json" -> scalar string (fun x -> Json_value x) | "rawNumber" -> scalar string (fun x -> Raw_number_value x)
  | "map" -> scalar internal_value_of_json (function Internal_map x -> Map_value x | _ -> decode_error "expected internal map")
  | "collection" -> scalar internal_value_of_json (function Internal_list x -> Collection_value x | _ -> decode_error "expected internal list")
  | "any" -> scalar internal_value_of_json (fun x -> Any_value x)
  | _ -> decode_error "invalid property value type"

let position_to_json = function
  | Before block -> `Assoc [ "type", `String "before"; "block", uuid_json block ]
  | After block -> `Assoc [ "type", `String "after"; "block", uuid_json block ]
  | First_child block -> `Assoc [ "type", `String "firstChild"; "block", uuid_json block ]
  | Last_child block -> `Assoc [ "type", `String "lastChild"; "block", uuid_json block ]

let position_of_json json =
  let fields = exact_assoc [ "type"; "block" ] json in
  let block = uuid (field "block" fields) in
  match string (field "type" fields) with
  | "before" -> Before block | "after" -> After block | "firstChild" -> First_child block
  | "lastChild" -> Last_child block | _ -> decode_error "invalid position"

let rec block_tree_to_json tree =
  `Assoc [ "uuid", uuid_json tree.uuid; "title", `String tree.title; "children", `List (List.map block_tree_to_json tree.children) ]

let rec block_tree_of_json json =
  let fields = exact_assoc [ "uuid"; "title"; "children" ] json in
  { uuid = uuid (field "uuid" fields)
  ; title = string (field "title" fields)
  ; children = (match field "children" fields with `List xs -> List.map block_tree_of_json xs | _ -> decode_error "invalid children")
  }

let property_scope_to_json = function
  | All_properties -> `Assoc [ "type", `String "all" ]
  | User_properties -> `Assoc [ "type", `String "user" ]
  | Properties_for_block block -> `Assoc [ "type", `String "block"; "block", uuid_json block ]
  | Properties_for_class class_ -> `Assoc [ "type", `String "class"; "class", uuid_json class_ ]

let property_scope_of_json json =
  let raw = match json with `Assoc fields -> fields | _ -> decode_error "invalid scope" in
  match string (field "type" raw) with
  | "all" -> ignore (exact_assoc [ "type" ] json); All_properties
  | "user" -> ignore (exact_assoc [ "type" ] json); User_properties
  | "block" -> let f = exact_assoc [ "type"; "block" ] json in Properties_for_block (uuid (field "block" f))
  | "class" -> let f = exact_assoc [ "type"; "class" ] json in Properties_for_class (uuid (field "class" f))
  | _ -> decode_error "invalid scope type"

let task_state_string = function
  | Todo -> "todo" | Doing -> "doing" | Done -> "done" | Cancelled -> "cancelled"
  | Waiting -> "waiting" | Now -> "now" | Later -> "later"

let task_state = function
  | "todo" -> Todo | "doing" -> Doing | "done" -> Done | "cancelled" -> Cancelled
  | "waiting" -> Waiting | "now" -> Now | "later" -> Later | _ -> decode_error "invalid task state"

let task_filter_to_json filter =
  let opt_int = option_json (fun value -> `Int value) in
  `Assoc
    [ "states", `List (List.map (fun state -> `String (task_state_string state)) filter.states)
    ; "page", option_json uuid_json filter.page
    ; "scheduledFrom", opt_int filter.scheduled_from
    ; "scheduledThrough", opt_int filter.scheduled_through
    ; "deadlineFrom", opt_int filter.deadline_from
    ; "deadlineThrough", opt_int filter.deadline_through
    ]

let task_filter_of_json json =
  let fields = exact_assoc [ "states"; "page"; "scheduledFrom"; "scheduledThrough"; "deadlineFrom"; "deadlineThrough" ] json in
  let opt_int = function `Null -> None | value -> Some (integer value) in
  { states = (match field "states" fields with `List xs -> List.map (fun x -> task_state (string x)) xs | _ -> decode_error "invalid states")
  ; page = (match field "page" fields with `Null -> None | value -> Some (uuid value))
  ; scheduled_from = opt_int (field "scheduledFrom" fields)
  ; scheduled_through = opt_int (field "scheduledThrough" fields)
  ; deadline_from = opt_int (field "deadlineFrom" fields)
  ; deadline_through = opt_int (field "deadlineThrough" fields)
  }

let paged_fields limit cursor = [ "limit", `Int limit; "cursor", option_json cursor_json cursor ]

let read_to_json = function
  | Graph_info -> `Assoc [ "type", `String "graphInfo" ]
  | Get_block { block } -> `Assoc [ "type", `String "getBlock"; "block", uuid_json block ]
  | Get_page { page } -> `Assoc [ "type", `String "getPage"; "page", page_selector_to_json page ]
  | Get_children { parent; limit; cursor } -> `Assoc (("type", `String "getChildren") :: ("parent", uuid_json parent) :: paged_fields limit cursor)
  | Get_page_tree { page; maximum_depth; limit; cursor } -> `Assoc (("type", `String "getPageTree") :: ("page", uuid_json page) :: ("maximumDepth", `Int maximum_depth) :: paged_fields limit cursor)
  | Get_ancestors { block; limit } -> `Assoc [ "type", `String "getAncestors"; "block", uuid_json block; "limit", `Int limit ]
  | Get_siblings { block; limit; cursor } -> `Assoc (("type", `String "getSiblings") :: ("block", uuid_json block) :: paged_fields limit cursor)
  | List_pages { kind; limit; cursor } -> `Assoc (("type", `String "listPages") :: ("kind", `String (page_kind_filter_string kind)) :: paged_fields limit cursor)
  | List_tags { limit; cursor } -> `Assoc (("type", `String "listTags") :: paged_fields limit cursor)
  | List_properties { scope; limit; cursor } -> `Assoc (("type", `String "listProperties") :: ("scope", property_scope_to_json scope) :: paged_fields limit cursor)
  | List_tasks { filter; limit; cursor } -> `Assoc (("type", `String "listTasks") :: ("filter", task_filter_to_json filter) :: paged_fields limit cursor)
  | Get_references { target; direction; limit; cursor } ->
      `Assoc (("type", `String "getReferences") :: ("target", uuid_json target) :: ("direction", `String (match direction with Referring_to -> "referringTo" | Referred_from -> "referredFrom")) :: paged_fields limit cursor)

let read_of_json kind json =
  let paged expected constructor =
    let f = exact_assoc (expected @ [ "type"; "limit"; "cursor" ]) json in
    constructor f (integer (field "limit" f)) (cursor (field "cursor" f))
  in
  match kind with
  | "graphInfo" -> ignore (exact_assoc [ "type" ] json); Graph_info
  | "getBlock" -> let f = exact_assoc [ "type"; "block" ] json in Get_block { block = uuid (field "block" f) }
  | "getPage" -> let f = exact_assoc [ "type"; "page" ] json in Get_page { page = page_selector_of_json (field "page" f) }
  | "getChildren" -> paged [ "parent" ] (fun f limit cursor -> Get_children { parent = uuid (field "parent" f); limit; cursor })
  | "getPageTree" -> paged [ "page"; "maximumDepth" ] (fun f limit cursor -> Get_page_tree { page = uuid (field "page" f); maximum_depth = integer (field "maximumDepth" f); limit; cursor })
  | "getAncestors" -> let f = exact_assoc [ "type"; "block"; "limit" ] json in Get_ancestors { block = uuid (field "block" f); limit = integer (field "limit" f) }
  | "getSiblings" -> paged [ "block" ] (fun f limit cursor -> Get_siblings { block = uuid (field "block" f); limit; cursor })
  | "listPages" -> paged [ "kind" ] (fun f limit cursor -> List_pages { kind = page_kind_filter (string (field "kind" f)); limit; cursor })
  | "listTags" -> paged [] (fun _ limit cursor -> List_tags { limit; cursor })
  | "listProperties" -> paged [ "scope" ] (fun f limit cursor -> List_properties { scope = property_scope_of_json (field "scope" f); limit; cursor })
  | "listTasks" -> paged [ "filter" ] (fun f limit cursor -> List_tasks { filter = task_filter_of_json (field "filter" f); limit; cursor })
  | "getReferences" -> paged [ "target"; "direction" ] (fun f limit cursor -> Get_references { target = uuid (field "target" f); direction = (match string (field "direction" f) with "referringTo" -> Referring_to | "referredFrom" -> Referred_from | _ -> decode_error "invalid reference direction"); limit; cursor })
  | _ -> decode_error "unknown read command"

let uuids_json values = `List (List.map uuid_json values)
let with_context fields context = `Assoc (fields @ [ "context", context_to_json context ])

let property_identity_to_json = function
  | Existing_property selector -> `Assoc [ "type", `String "existing"; "property", property_selector_to_json selector ]
  | New_property { ident; title } -> `Assoc [ "type", `String "new"; "ident", `String ident; "title", `String title ]

let property_identity_of_json json =
  let raw = match json with `Assoc fields -> fields | _ -> decode_error "invalid property identity" in
  match string (field "type" raw) with
  | "existing" -> let f = exact_assoc [ "type"; "property" ] json in Existing_property (property_selector_of_json (field "property" f))
  | "new" -> let f = exact_assoc [ "type"; "ident"; "title" ] json in New_property { ident = string (field "ident" f); title = string (field "title" f) }
  | _ -> decode_error "invalid property identity type"

let create_page_kind_to_json = function
  | Create_ordinary_page { uuid } -> `Assoc [ "type", `String "ordinary"; "uuid", uuid_json uuid ]
  | Create_class_page { uuid } -> `Assoc [ "type", `String "class"; "uuid", uuid_json uuid ]
  | Create_journal_page { journal_day; supplied_uuid } ->
      `Assoc [ "type", `String "journal"; "journalDay", `Int journal_day; "suppliedUuid", option_json uuid_json supplied_uuid ]

let create_page_kind_of_json json =
  let raw = match json with `Assoc fields -> fields | _ -> decode_error "invalid create page kind" in
  match string (field "type" raw) with
  | "ordinary" -> let f = exact_assoc [ "type"; "uuid" ] json in Create_ordinary_page { uuid = uuid (field "uuid" f) }
  | "class" -> let f = exact_assoc [ "type"; "uuid" ] json in Create_class_page { uuid = uuid (field "uuid" f) }
  | "journal" ->
      let f = exact_assoc [ "type"; "journalDay"; "suppliedUuid" ] json in
      Create_journal_page { journal_day = integer (field "journalDay" f); supplied_uuid = (match field "suppliedUuid" f with `Null -> None | x -> Some (uuid x)) }
  | _ -> decode_error "invalid create page kind type"

let mutation_to_json = function
  | Structural (Save_block { block; title; context }) -> with_context [ "type", `String "saveBlock"; "block", uuid_json block; "title", `String title ] context
  | Structural (Insert_blocks { roots; position; context }) ->
      let position = match position with Relative p -> position_to_json p | Replace_empty block -> `Assoc [ "type", `String "replaceEmpty"; "block", uuid_json block ] in
      with_context [ "type", `String "insertBlocks"; "roots", `List (List.map block_tree_to_json roots); "position", position ] context
  | Structural (Move_blocks { roots; position; context }) -> with_context [ "type", `String "moveBlocks"; "roots", uuids_json roots; "position", position_to_json position ] context
  | Structural (Move_up_down { roots; direction; context }) -> with_context [ "type", `String "moveUpDown"; "roots", uuids_json roots; "direction", `String (match direction with Up -> "up" | Down -> "down") ] context
  | Structural (Indent_outdent { roots; direction; context }) -> with_context [ "type", `String "indentOutdent"; "roots", uuids_json roots; "direction", `String (match direction with Indent -> "indent" | Direct_outdent -> "directOutdent") ] context
  | Structural (Delete_blocks { roots; context }) -> with_context [ "type", `String "deleteBlocks"; "roots", uuids_json roots ] context
  | Page (Create_page { title; kind; context }) -> with_context [ "type", `String "createPage"; "title", `String title; "kind", create_page_kind_to_json kind ] context
  | Page (Rename_page { page; title; context }) -> with_context [ "type", `String "renamePage"; "page", uuid_json page; "title", `String title ] context
  | Page (Delete_page { page; context }) -> with_context [ "type", `String "deletePage"; "page", uuid_json page ] context
  | Page (Restore_recycled_page { page; context }) -> with_context [ "type", `String "restoreRecycledPage"; "page", uuid_json page ] context
  | Page (Permanently_delete_recycled_page { page; context }) -> with_context [ "type", `String "permanentlyDeleteRecycledPage"; "page", uuid_json page ] context
  | Property (Upsert_property { property; schema; context }) -> with_context [ "type", `String "upsertProperty"; "property", property_identity_to_json property; "schema", property_schema_to_json schema ] context
  | Property (Set_property { block; property; value; context }) -> with_context [ "type", `String "setProperty"; "block", uuid_json block; "property", property_selector_to_json property; "value", property_value_to_json value ] context
  | Property (Remove_property { block; property; context }) -> with_context [ "type", `String "removeProperty"; "block", uuid_json block; "property", property_selector_to_json property ] context
  | Property (Batch_set_property { blocks; property; mode; context }) ->
      let mode = match mode with Append value -> `Assoc [ "type", `String "append"; "value", property_value_to_json value ] | Replace values -> `Assoc [ "type", `String "replace"; "values", `List (List.map property_value_to_json values) ] in
      with_context [ "type", `String "batchSetProperty"; "blocks", uuids_json blocks; "property", property_selector_to_json property; "mode", mode ] context
  | Property (Batch_remove_property { blocks; property; context }) -> with_context [ "type", `String "batchRemoveProperty"; "blocks", uuids_json blocks; "property", property_selector_to_json property ] context
  | Property (Manage_closed_values { property; action; context }) ->
      let action = match action with
        | Add_closed_value { value_uuid; value; icon } -> `Assoc [ "type", `String "add"; "valueUuid", uuid_json value_uuid; "value", property_value_to_json value; "icon", option_json (fun x -> `String x) icon ]
        | Update_closed_value { value_uuid; value; icon } -> `Assoc [ "type", `String "update"; "valueUuid", uuid_json value_uuid; "value", property_value_to_json value; "icon", option_json (fun x -> `String x) icon ]
        | Associate_closed_value { value_uuid } -> `Assoc [ "type", `String "associate"; "valueUuid", uuid_json value_uuid ]
        | Delete_closed_value { value_uuid } -> `Assoc [ "type", `String "delete"; "valueUuid", uuid_json value_uuid ] in
      with_context [ "type", `String "manageClosedValues"; "property", property_selector_to_json property; "action", action ] context
  | Property (Manage_class_property { class_; property; action; context }) ->
      let action = match action with Add_class_property { default_value } -> `Assoc [ "type", `String "add"; "defaultValue", option_json property_value_to_json default_value ] | Remove_class_property -> `Assoc [ "type", `String "remove" ] in
      with_context [ "type", `String "manageClassProperty"; "class", uuid_json class_; "property", property_selector_to_json property; "action", action ] context

let mutation_of_json kind json =
  let f names = exact_assoc ("type" :: "context" :: names) json in
  let roots field_name fields = uuid_list (field field_name fields) in
  match kind with
  | "saveBlock" -> let x = f [ "block"; "title" ] in Structural (Save_block { block = uuid (field "block" x); title = string (field "title" x); context = context_of_json (field "context" x) })
  | "insertBlocks" -> let x = f [ "roots"; "position" ] in
      let position_json = field "position" x in
      let raw = match position_json with `Assoc fields -> fields | _ -> decode_error "invalid insert position" in
      let position = match string (field "type" raw) with "replaceEmpty" -> let p = exact_assoc [ "type"; "block" ] position_json in Replace_empty (uuid (field "block" p)) | _ -> Relative (position_of_json position_json) in
      Structural (Insert_blocks { roots = (match field "roots" x with `List values -> List.map block_tree_of_json values | _ -> decode_error "invalid roots"); position; context = context_of_json (field "context" x) })
  | "moveBlocks" -> let x = f [ "roots"; "position" ] in Structural (Move_blocks { roots = roots "roots" x; position = position_of_json (field "position" x); context = context_of_json (field "context" x) })
  | "moveUpDown" -> let x = f [ "roots"; "direction" ] in Structural (Move_up_down { roots = roots "roots" x; direction = (match string (field "direction" x) with "up" -> Up | "down" -> Down | _ -> decode_error "invalid direction"); context = context_of_json (field "context" x) })
  | "indentOutdent" -> let x = f [ "roots"; "direction" ] in Structural (Indent_outdent { roots = roots "roots" x; direction = (match string (field "direction" x) with "indent" -> Indent | "directOutdent" -> Direct_outdent | _ -> decode_error "invalid indent direction"); context = context_of_json (field "context" x) })
  | "deleteBlocks" -> let x = f [ "roots" ] in Structural (Delete_blocks { roots = roots "roots" x; context = context_of_json (field "context" x) })
  | "createPage" -> let x = f [ "title"; "kind" ] in Page (Create_page { title = string (field "title" x); kind = create_page_kind_of_json (field "kind" x); context = context_of_json (field "context" x) })
  | "renamePage" -> let x = f [ "page"; "title" ] in Page (Rename_page { page = uuid (field "page" x); title = string (field "title" x); context = context_of_json (field "context" x) })
  | "deletePage" | "restoreRecycledPage" | "permanentlyDeleteRecycledPage" as page_kind ->
      let x = f [ "page" ] in let page = uuid (field "page" x) and context = context_of_json (field "context" x) in
      Page (match page_kind with "deletePage" -> Delete_page { page; context } | "restoreRecycledPage" -> Restore_recycled_page { page; context } | _ -> Permanently_delete_recycled_page { page; context })
  | "upsertProperty" -> let x = f [ "property"; "schema" ] in Property (Upsert_property { property = property_identity_of_json (field "property" x); schema = property_schema_of_json (field "schema" x); context = context_of_json (field "context" x) })
  | "setProperty" -> let x = f [ "block"; "property"; "value" ] in Property (Set_property { block = uuid (field "block" x); property = property_selector_of_json (field "property" x); value = property_value_of_json (field "value" x); context = context_of_json (field "context" x) })
  | "removeProperty" -> let x = f [ "block"; "property" ] in Property (Remove_property { block = uuid (field "block" x); property = property_selector_of_json (field "property" x); context = context_of_json (field "context" x) })
  | "batchSetProperty" -> let x = f [ "blocks"; "property"; "mode" ] in
      let mode_json = field "mode" x in let raw = match mode_json with `Assoc fields -> fields | _ -> decode_error "invalid batch mode" in
      let mode = match string (field "type" raw) with "append" -> let m = exact_assoc [ "type"; "value" ] mode_json in Append (property_value_of_json (field "value" m)) | "replace" -> let m = exact_assoc [ "type"; "values" ] mode_json in Replace (match field "values" m with `List values -> List.map property_value_of_json values | _ -> decode_error "invalid replace values") | _ -> decode_error "invalid batch mode type" in
      Property (Batch_set_property { blocks = roots "blocks" x; property = property_selector_of_json (field "property" x); mode; context = context_of_json (field "context" x) })
  | "batchRemoveProperty" -> let x = f [ "blocks"; "property" ] in Property (Batch_remove_property { blocks = roots "blocks" x; property = property_selector_of_json (field "property" x); context = context_of_json (field "context" x) })
  | "manageClosedValues" -> let x = f [ "property"; "action" ] in
      let action_json = field "action" x in let raw = match action_json with `Assoc fields -> fields | _ -> decode_error "invalid closed action" in
      let action = match string (field "type" raw) with
        | "add" | "update" as action_kind -> let a = exact_assoc [ "type"; "valueUuid"; "value"; "icon" ] action_json in let value_uuid = uuid (field "valueUuid" a) and value = property_value_of_json (field "value" a) and icon = (match field "icon" a with `Null -> None | v -> Some (string v)) in if action_kind = "add" then Add_closed_value { value_uuid; value; icon } else Update_closed_value { value_uuid; value; icon }
        | "associate" -> let a = exact_assoc [ "type"; "valueUuid" ] action_json in Associate_closed_value { value_uuid = uuid (field "valueUuid" a) }
        | "delete" -> let a = exact_assoc [ "type"; "valueUuid" ] action_json in Delete_closed_value { value_uuid = uuid (field "valueUuid" a) }
        | _ -> decode_error "invalid closed action type" in
      Property (Manage_closed_values { property = property_selector_of_json (field "property" x); action; context = context_of_json (field "context" x) })
  | "manageClassProperty" -> let x = f [ "class"; "property"; "action" ] in
      let action_json = field "action" x in let raw = match action_json with `Assoc fields -> fields | _ -> decode_error "invalid class action" in
      let action = match string (field "type" raw) with "remove" -> ignore (exact_assoc [ "type" ] action_json); Remove_class_property | "add" -> let a = exact_assoc [ "type"; "defaultValue" ] action_json in Add_class_property { default_value = (match field "defaultValue" a with `Null -> None | v -> Some (property_value_of_json v)) } | _ -> decode_error "invalid class action type" in
      Property (Manage_class_property { class_ = uuid (field "class" x); property = property_selector_of_json (field "property" x); action; context = context_of_json (field "context" x) })
  | _ -> decode_error "unknown mutation command"

let request_to_yojson request =
  `Assoc [ "apiVersion", `Int request.api_version; "requestId", uuid_json request.request_id; "command", (match request.command with Read read -> read_to_json read | Mutate mutation -> mutation_to_json mutation) ]

let invalid_request message =
  match Error.create ~code:Invalid_request ~message ~details:[] with
  | Ok error -> error
  | Error internal_error -> failwith ("invalid internal request error: " ^ internal_error)

let request_of_yojson json =
  try
    if String.length (Yojson.Safe.to_string json) > maximum_request_bytes then decode_error "request exceeds byte budget";
    let fields = exact_assoc [ "apiVersion"; "requestId"; "command" ] json in
    let version = integer (field "apiVersion" fields) in
    if version <> api_version then decode_error "unsupported apiVersion";
    let command_json = field "command" fields in
    let command_fields = match command_json with `Assoc fields -> fields | _ -> decode_error "invalid command" in
    let kind = string (field "type" command_fields) in
    let read_kinds = [ "graphInfo"; "getBlock"; "getPage"; "getChildren"; "getPageTree"; "getAncestors"; "getSiblings"; "listPages"; "listTags"; "listProperties"; "listTasks"; "getReferences" ] in
    let command = if List.mem kind read_kinds then Read (read_of_json kind command_json) else Mutate (mutation_of_json kind command_json) in
    Ok { api_version = version; request_id = uuid (field "requestId" fields); command }
  with Decode_error message -> Error (invalid_request message)

let mutation_status_string = function Applied -> "applied" | No_change -> "noChange" | Already_applied -> "alreadyApplied"
let mutation_status = function "applied" -> Applied | "noChange" -> No_change | "alreadyApplied" -> Already_applied | _ -> decode_error "invalid mutation status"

let mutation_success_to_json success =
  `Assoc
    [ "type", `String "mutation"
    ; "status", `String (mutation_status_string success.status)
    ; "basisBefore", int64_json success.basis_before
    ; "basisAfter", int64_json success.basis_after
    ; "changedUuids", uuids_json success.changed_uuids
    ; "changedUuidsTruncated", `Bool success.changed_uuids_truncated
    ]

let mutation_success_of_json json =
  let fields = exact_assoc [ "type"; "status"; "basisBefore"; "basisAfter"; "changedUuids"; "changedUuidsTruncated" ] json in
  if string (field "type" fields) <> "mutation" then decode_error "unsupported success type";
  { status = mutation_status (string (field "status" fields))
  ; basis_before = int64 (field "basisBefore" fields)
  ; basis_after = int64 (field "basisAfter" fields)
  ; changed_uuids = uuid_list (field "changedUuids" fields)
  ; changed_uuids_truncated = boolean (field "changedUuidsTruncated" fields)
  }

let property_schema_json = property_schema_to_json

let property_summary_to_json (summary : property_summary) =
  `Assoc
    [ "ident", `String summary.ident
    ; "uuid", uuid_json summary.uuid
    ; "title", `String summary.title
    ; "schema", property_schema_json summary.schema
    ; "values", `List (List.map property_value_to_json summary.values)
    ; "valuesTruncated", `Bool summary.values_truncated
    ]

let page_kind_to_json = function
  | Ordinary_page -> `Assoc [ "type", `String "ordinary" ]
  | Journal_page { journal_day } -> `Assoc [ "type", `String "journal"; "journalDay", `Int journal_day ]
  | Class_page -> `Assoc [ "type", `String "class" ]
  | Property_page -> `Assoc [ "type", `String "property" ]
  | Hidden_page -> `Assoc [ "type", `String "hidden" ]
  | Built_in_page -> `Assoc [ "type", `String "builtIn" ]

let block_to_json (block : block) =
  `Assoc
    [ "uuid", uuid_json block.uuid
    ; "title", `String block.title
    ; "parent", uuid_json block.parent
    ; "page", uuid_json block.page
    ; "order", `String block.order
    ; "createdAtMs", int64_json block.created_at_ms
    ; "updatedAtMs", int64_json block.updated_at_ms
    ; "refs", uuids_json block.refs
    ; "tags", uuids_json block.tags
    ; "properties", `List (List.map property_summary_to_json block.properties)
    ]

let page_to_json (page : page) =
  `Assoc
    [ "uuid", uuid_json page.uuid
    ; "name", `String page.name
    ; "title", `String page.title
    ; "kind", page_kind_to_json page.kind
    ; "createdAtMs", int64_json page.created_at_ms
    ; "updatedAtMs", int64_json page.updated_at_ms
    ; "tags", uuids_json page.tags
    ; "properties", `List (List.map property_summary_to_json page.properties)
    ; "recycled", `Bool page.recycled
    ]

let admission_fact_to_json = function
  | Compatible_schema { minimum; actual } ->
      `Assoc
        [ "type", `String "compatibleSchema"
        ; "minimum", `String (Printf.sprintf "%d.%d" minimum.major minimum.minor)
        ; "actual", `String (Printf.sprintf "%d.%d" actual.major actual.minor)
        ]
  | Local_graph uuid -> `Assoc [ "type", `String "localGraph"; "uuid", uuid_json uuid ]
  | Remote_flag_absent -> `Assoc [ "type", `String "remoteFlagAbsent" ]
  | Remote_flag_false -> `Assoc [ "type", `String "remoteFlagFalse" ]
  | No_rtc_identity -> `Assoc [ "type", `String "noRtcIdentity" ]
  | Lossless_codec -> `Assoc [ "type", `String "losslessCodec" ]
  | Ownership_verified -> `Assoc [ "type", `String "ownershipVerified" ]
  | Backup_verified -> `Assoc [ "type", `String "backupVerified" ]
  | Sidecars_invalidated -> `Assoc [ "type", `String "sidecarsInvalidated" ]

let graph_info_to_json (info : graph_info) =
  `Assoc
    [ "localGraphUuid", uuid_json info.local_graph_uuid
    ; "graphName", `String info.graph_name
    ; "graphDir", `String info.graph_dir
    ; "schema", `String (Printf.sprintf "%d.%d" info.schema.major info.schema.minor)
    ; "basis", int64_json info.basis
    ; "mode", `String (match info.mode with Snapshot -> "snapshot" | Native_read_write -> "nativeReadWrite")
    ; "admissionFacts", `List (List.map admission_fact_to_json info.admission_facts)
    ]

let page_result_to_json encode result =
  `Assoc
    [ "items", `List (List.map encode result.items)
    ; "continuation", option_json cursor_json result.continuation
    ]

let page_summary_to_json (summary : page_summary) =
  `Assoc
    [ "uuid", uuid_json summary.uuid
    ; "name", `String summary.name
    ; "title", `String summary.title
    ; "kind", page_kind_to_json summary.kind
    ; "recycled", `Bool summary.recycled
    ]

let tag_summary_to_json (summary : tag_summary) =
  `Assoc
    [ "uuid", uuid_json summary.uuid
    ; "title", `String summary.title
    ; "ident", option_json (fun value -> `String value) summary.ident
    ]

let property_definition_to_json (definition : property_definition) =
  `Assoc
    [ "uuid", uuid_json definition.uuid
    ; "ident", `String definition.ident
    ; "title", `String definition.title
    ; "schema", property_schema_to_json definition.schema
    ; "closedValues", uuids_json definition.closed_values
    ]

let task_to_json (task : task) =
  `Assoc
    [ "block", block_to_json task.block
    ; "state", `String (task_state_string task.state)
    ; "scheduledDay", option_json (fun value -> `Int value) task.scheduled_day
    ; "deadlineDay", option_json (fun value -> `Int value) task.deadline_day
    ]

let reference_kind_string = function
  | Block_reference -> "block" | Page_reference -> "page" | Tag_reference -> "tag"
  | Property_reference -> "property" | Scheduled_reference -> "scheduled"
  | Deadline_reference -> "deadline" | Alias_reference -> "alias"

let reference_to_json (reference : reference) =
  `Assoc
    [ "source", uuid_json reference.source
    ; "target", uuid_json reference.target
    ; "kind", `String (reference_kind_string reference.kind)
    ]

let success_to_json = function
  | Mutation_result success -> mutation_success_to_json success
  | Graph_info_result info -> `Assoc [ "type", `String "graphInfo"; "graph", graph_info_to_json info ]
  | Block_result block -> `Assoc [ "type", `String "block"; "block", block_to_json block ]
  | Page_result page -> `Assoc [ "type", `String "page"; "page", page_to_json page ]
  | Children_result result -> `Assoc [ "type", `String "children"; "page", page_result_to_json block_to_json result ]
  | Page_tree_result result -> `Assoc [ "type", `String "pageTree"; "page", page_result_to_json (fun item -> `Assoc [ "block", block_to_json item.block; "depth", `Int item.depth ]) result ]
  | Ancestors_result blocks -> `Assoc [ "type", `String "ancestors"; "items", `List (List.map block_to_json blocks) ]
  | Siblings_result result -> `Assoc [ "type", `String "siblings"; "siblings", page_result_to_json block_to_json result.siblings; "currentIndex", `Int result.current_index ]
  | Pages_result result -> `Assoc [ "type", `String "pages"; "page", page_result_to_json page_summary_to_json result ]
  | Tags_result result -> `Assoc [ "type", `String "tags"; "page", page_result_to_json tag_summary_to_json result ]
  | Properties_result result -> `Assoc [ "type", `String "properties"; "page", page_result_to_json property_definition_to_json result ]
  | Tasks_result result -> `Assoc [ "type", `String "tasks"; "page", page_result_to_json task_to_json result ]
  | References_result result -> `Assoc [ "type", `String "references"; "page", page_result_to_json reference_to_json result ]

let response_to_yojson = function
  | Succeeded { request_id; basis; success } ->
      `Assoc
        [ "type", `String "succeeded"
        ; "requestId", uuid_json request_id
        ; "basis", int64_json basis
        ; "success", success_to_json success
        ]
  | Failed { request_id; phase; basis; error } ->
      `Assoc
        [ "type", `String "failed"
        ; "requestId", uuid_json request_id
        ; "phase", `String (match phase with Open -> "open" | Execute -> "execute")
        ; "basis", option_json int64_json basis
        ; "error", Error.to_yojson error
        ]

let response_of_yojson json =
  try
    let raw = match json with `Assoc fields -> fields | _ -> decode_error "invalid response" in
    match string (field "type" raw) with
    | "succeeded" ->
        let fields = exact_assoc [ "type"; "requestId"; "basis"; "success" ] json in
        Ok (Succeeded { request_id = uuid (field "requestId" fields); basis = int64 (field "basis" fields); success = Mutation_result (mutation_success_of_json (field "success" fields)) })
    | "failed" ->
        let fields = exact_assoc [ "type"; "requestId"; "phase"; "basis"; "error" ] json in
        let error = match Error.of_yojson (field "error" fields) with Ok error -> error | Error message -> decode_error message in
        Ok (Failed { request_id = uuid (field "requestId" fields); phase = (match string (field "phase" fields) with "open" -> Open | "execute" -> Execute | _ -> decode_error "invalid failure phase"); basis = (match field "basis" fields with `Null -> None | value -> Some (int64 value)); error })
    | _ -> decode_error "invalid response type"
  with Decode_error message -> Error message

let push_to_yojson (Graph_invalidated invalidation) =
  `Assoc
    [ "type", `String "graphInvalidated"
    ; "basis", int64_json invalidation.basis
    ; "changedUuids", uuids_json invalidation.changed_uuids
    ; "changedUuidsTruncated", `Bool invalidation.changed_uuids_truncated
    ; "invalidateGraphInfo", `Bool invalidation.invalidate_graph_info
    ; "invalidatePages", `Bool invalidation.invalidate_pages
    ; "invalidateTags", `Bool invalidation.invalidate_tags
    ; "invalidateProperties", `Bool invalidation.invalidate_properties
    ; "invalidateTasks", `Bool invalidation.invalidate_tasks
    ; "invalidateReferences", `Bool invalidation.invalidate_references
    ]

let push_of_yojson json =
  try
    let fields = exact_assoc [ "type"; "basis"; "changedUuids"; "changedUuidsTruncated"; "invalidateGraphInfo"; "invalidatePages"; "invalidateTags"; "invalidateProperties"; "invalidateTasks"; "invalidateReferences" ] json in
    if string (field "type" fields) <> "graphInvalidated" then decode_error "invalid push type";
    Ok (Graph_invalidated
          { basis = int64 (field "basis" fields)
          ; changed_uuids = uuid_list (field "changedUuids" fields)
          ; changed_uuids_truncated = boolean (field "changedUuidsTruncated" fields)
          ; invalidate_graph_info = boolean (field "invalidateGraphInfo" fields)
          ; invalidate_pages = boolean (field "invalidatePages" fields)
          ; invalidate_tags = boolean (field "invalidateTags" fields)
          ; invalidate_properties = boolean (field "invalidateProperties" fields)
          ; invalidate_tasks = boolean (field "invalidateTasks" fields)
          ; invalidate_references = boolean (field "invalidateReferences" fields)
          })
  with Decode_error message -> Error message
let encoded_response_bytes response = String.length (Yojson.Safe.to_string (response_to_yojson response))
