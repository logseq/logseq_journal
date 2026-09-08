open Graph_types

let api_version = 2
let maximum_request_bytes = Limits.maximum_request_bytes
let maximum_response_bytes = Limits.maximum_response_bytes
let maximum_push_bytes = Limits.maximum_push_bytes
let default_page_size = 50
let maximum_page_size = 200
let maximum_tree_nodes = 2_000
let maximum_tree_depth = 64
let maximum_title_bytes = 65_536
let maximum_roots = 1_024
let maximum_changed_uuids = Limits.maximum_changed_uuids
let maximum_property_values = 1_024
let maximum_filter_values = 64

type request =
  { api_version : int
  ; request_id : Uuid.t
  ; command : command
  }

and command =
  | V2_graph_info
  | V2_inspect_admission
  | V2_list_favorites of
      { limit : int
      ; cursor : Cursor.t option
      }
  | V2_list_journals of
      { from_day : int
      ; through_day : int
      ; limit : int
      ; cursor : Cursor.t option
      ; revision : string option
      }
  | V2_get_page of
      { page : page_uuid
      ; revision : string option
      }
  | V2_get_block of
      { block : block_uuid
      ; revision : string option
      }
  | V2_get_children of
      { parent : Uuid.t
      ; limit : int
      ; cursor : Cursor.t option
      ; revision : string option
      }
  | V2_get_page_tree of
      { page : page_uuid
      ; maximum_depth : int
      ; limit : int
      ; cursor : Cursor.t option
      ; revision : string option
      }
  | V2_save_block of
      { mutation_id : Uuid.t
      ; block : block_uuid
      ; title : string
      ; preconditions : v2_preconditions
      }
  | V2_insert_blocks of
      { mutation_id : Uuid.t
      ; parent : Uuid.t
      ; roots : v2_block_tree list
      ; preconditions : v2_preconditions
      }
  | V2_delete_blocks of
      { mutation_id : Uuid.t
      ; root : block_uuid
      ; preconditions : v2_preconditions
      }
  | V2_create_journal_page of
      { mutation_id : Uuid.t
      ; page : page_uuid
      ; journal_day : int
      ; title : string
      ; preconditions : v2_preconditions
      }
  | V2_set_task_status of
      { mutation_id : Uuid.t
      ; block : block_uuid
      ; status : v2_task_status
      ; preconditions : v2_preconditions
      }
  | V2_clear_task_status of
      { mutation_id : Uuid.t
      ; block : block_uuid
      ; preconditions : v2_preconditions
      }
  | V2_pull_changes of
      { generation : string
      ; after : string option
      ; limit : int
      }
  | V2_ack_changes of
      { generation : string
      ; through : string
      }

and v2_scope = V2_children_scope of Uuid.t

and v2_task_status =
  | V2_todo
  | V2_doing
  | V2_in_review
  | V2_now
  | V2_done
  | V2_canceled
  | V2_backlog
  | V2_waiting
  | V2_later

and v2_preconditions =
  { blocks : (block_uuid * string) list
  ; pages : (page_uuid * string) list
  ; scopes : (v2_scope * string) list
  }

and v2_block_tree =
  { uuid : block_uuid
  ; title : string
  ; children : v2_block_tree list
  }

type response =
  | V2_response of
      { api_version : int
      ; request_id : Uuid.t
      ; outcome : v2_outcome
      }

and v2_change_window =
  { id : string
  ; predecessor : string
  ; successor : string
  ; block_uuids : block_uuid list
  ; page_uuids : page_uuid list
  ; structure_interests : v2_structure_interest list
  }

and v2_structure_interest =
  | V2_children_interest of Uuid.t
  | V2_page_tree_interest of page_uuid
  | V2_journal_index_interest

and v2_capability_limits =
  { response_budget_bytes : int
  ; outbox_max_records : int
  ; outbox_max_bytes : int
  ; change_max_items : int
  ; change_max_bytes : int
  ; dispatcher_capacity : int
  ; wire_batch_max_bytes : int
  }

and v2_page_lookup =
  | V2_present_page of
      { page : page
      ; revision : string
      }
  | V2_missing_page of
      { uuid : page_uuid
      ; revision : string
      }

and v2_block_record =
  { block : block
  ; task_status : v2_task_status option
  ; rendered_page_title : string
  }

and v2_block_lookup =
  | V2_present_block of
      { value : v2_block_record
      ; revision : string
      }
  | V2_missing_block of
      { uuid : block_uuid
      ; revision : string
      }

and v2_journal_item =
  { page : page
  ; journal_day : int
  ; revision : string
  }

and v2_favorite_target =
  | V2_favorite_page of
      { uuid : page_uuid
      ; title : string
      ; revision : string
      }
  | V2_favorite_block of
      { uuid : block_uuid
      ; title : string
      ; task_status : v2_task_status option
      ; revision : string
      }

and v2_favorite_item =
  { membership_uuid : block_uuid
  ; membership_order : string
  ; membership_revision : string
  ; target : v2_favorite_target
  }

and v2_favorites_result =
  { favorites_page : page_uuid option
  ; generation : string
  ; projection_revision : string
  ; items : v2_favorite_item list
  ; next_cursor : Cursor.t option
  }

and v2_child_member =
  { value : v2_block_record
  ; revision : string
  }

and v2_tree_member =
  { value : v2_block_record
  ; revision : string
  ; depth : int
  ; parent : Uuid.t
  }

and v2_revision_scope = V2_children_revision of Uuid.t

and v2_local_status =
  | V2_applied
  | V2_no_change
  | V2_already_applied

and v2_outcome =
  | V2_graph_info_outcome of
      { graph_uuid : Uuid.t
      ; graph_name : string
      ; schema : schema_version
      ; admission_facts : admission_fact list
      ; limits : v2_capability_limits
      ; generation : string
      ; projection_revision : string
      }
  | V2_favorites_outcome of v2_favorites_result
  | V2_admission_outcome of v2_admission_inspection
  | V2_journals_outcome of
      { items : v2_journal_item list
      ; next_cursor : Cursor.t option
      }
  | V2_page_outcome of v2_page_lookup
  | V2_block_outcome of v2_block_lookup
  | V2_children_outcome of
      { parent : Uuid.t
      ; revision_scope : v2_revision_scope
      ; scope_revision : string
      ; items : v2_child_member list
      ; next_cursor : Cursor.t option
      }
  | V2_page_tree_outcome of
      { page : page_uuid
      ; maximum_depth : int
      ; items : v2_tree_member list
      ; next_cursor : Cursor.t option
      }
  | V2_mutation_committed of
      { mutation_id : Uuid.t
      ; status : v2_local_status
      ; generation : string
      ; before_projection_revision : string
      ; after_projection_revision : string
      }
  | V2_changes of
      { generation : string
      ; from_exclusive : string option
      ; through : string
      ; windows : v2_change_window list
      ; next : string option
      }
  | V2_changes_acknowledged of
      { generation : string
      ; through : string
      }
  | V2_failed of
      { code : string
      ; message : string
      }
  | V2_resync_required of
      { generation : string
      ; reason : string
      }

and v2_admission_inspection =
  { active_records : int
  ; active_bytes : int
  ; protected_wire_bytes : int
  ; retained_origin_evidence_bytes : int
  ; maximum_records : int
  ; maximum_bytes : int
  }

type push =
  | V2_changes_available of
      { api_version : int
      ; generation : string
      ; through : string
      }
  | V2_resync_required_push of
      { api_version : int
      ; generation : string
      ; reason : string
      }

let failed ~request_id error =
  V2_response
    { api_version
    ; request_id
    ; outcome =
        V2_failed
          { code = Error.code_string (Error.code error); message = Error.message error }
    }
;;

exception Decode_error of string

let decode_error message = raise (Decode_error message)
let uuid_json value = `String (Uuid.to_string value)
let cursor_json value = `String (Cursor.to_string value)
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

let cursor = function
  | `Null -> None
  | value ->
    (match Cursor.of_string (string value) with
     | Ok value -> Some value
     | Error message -> decode_error message)
;;

let uuid_list = function
  | `List values -> List.map uuid values
  | _ -> decode_error "expected UUID list"
;;

let uuids_json values = `List (List.map uuid_json values)

let optional_string = function
  | `Null -> None
  | value -> Some (string value)
;;

let optional_string_json = option_json (fun value -> `String value)

let v2_scope_to_json = function
  | V2_children_scope parent ->
    `Assoc [ "type", `String "children"; "parent", uuid_json parent ]
;;

let v2_scope_of_json json =
  let fields =
    match json with
    | `Assoc fields -> fields
    | _ -> decode_error "invalid revision scope"
  in
  match string (field "type" fields) with
  | "children" ->
    let fields = exact_assoc [ "type"; "parent" ] json in
    V2_children_scope (uuid (field "parent" fields))
  | _ -> decode_error "invalid revision scope type"
;;

let v2_task_status_string = function
  | V2_todo -> "todo"
  | V2_doing -> "doing"
  | V2_in_review -> "inReview"
  | V2_now -> "now"
  | V2_done -> "done"
  | V2_canceled -> "canceled"
  | V2_backlog -> "backlog"
  | V2_waiting -> "waiting"
  | V2_later -> "later"
;;

let v2_task_status = function
  | "todo" -> V2_todo
  | "doing" -> V2_doing
  | "inReview" -> V2_in_review
  | "now" -> V2_now
  | "done" -> V2_done
  | "canceled" -> V2_canceled
  | "backlog" -> V2_backlog
  | "waiting" -> V2_waiting
  | "later" -> V2_later
  | _ -> decode_error "invalid task status"
;;

let v2_local_status_string = function
  | V2_applied -> "applied"
  | V2_no_change -> "noChange"
  | V2_already_applied -> "alreadyApplied"
;;

let v2_local_status = function
  | "applied" -> V2_applied
  | "noChange" -> V2_no_change
  | "alreadyApplied" -> V2_already_applied
  | _ -> decode_error "invalid local mutation status"
;;

let v2_precondition_entry_to_json key (id, revision) =
  `Assoc [ key, uuid_json id; "revision", `String revision ]
;;

let v2_preconditions_to_json preconditions =
  `Assoc
    [ ( "blocks"
      , `List (List.map (v2_precondition_entry_to_json "uuid") preconditions.blocks) )
    ; "pages", `List (List.map (v2_precondition_entry_to_json "uuid") preconditions.pages)
    ; ( "scopes"
      , `List
          (List.map
             (fun (scope, revision) ->
                `Assoc [ "scope", v2_scope_to_json scope; "revision", `String revision ])
             preconditions.scopes) )
    ]
;;

let v2_preconditions_of_json json =
  let fields = exact_assoc [ "blocks"; "pages"; "scopes" ] json in
  let entity_entries name =
    match field name fields with
    | `List entries ->
      List.map
        (fun entry ->
           let entry_fields = exact_assoc [ "uuid"; "revision" ] entry in
           uuid (field "uuid" entry_fields), string (field "revision" entry_fields))
        entries
    | _ -> decode_error (name ^ " preconditions must be a list")
  in
  let scopes =
    match field "scopes" fields with
    | `List entries ->
      List.map
        (fun entry ->
           let entry_fields = exact_assoc [ "scope"; "revision" ] entry in
           ( v2_scope_of_json (field "scope" entry_fields)
           , string (field "revision" entry_fields) ))
        entries
    | _ -> decode_error "scope preconditions must be a list"
  in
  { blocks = entity_entries "blocks"; pages = entity_entries "pages"; scopes }
;;

let rec v2_block_tree_to_json tree =
  `Assoc
    [ "uuid", uuid_json tree.uuid
    ; "title", `String tree.title
    ; "children", `List (List.map v2_block_tree_to_json tree.children)
    ]
;;

let rec v2_block_tree_of_json json =
  let fields = exact_assoc [ "uuid"; "title"; "children" ] json in
  { uuid = uuid (field "uuid" fields)
  ; title = string (field "title" fields)
  ; children =
      (match field "children" fields with
       | `List children -> List.map v2_block_tree_of_json children
       | _ -> decode_error "block tree children must be a list")
  }
;;

let v2_command_to_json = function
  | V2_graph_info -> `Assoc [ "type", `String "graphInfo" ]
  | V2_inspect_admission -> `Assoc [ "type", `String "inspectAdmission" ]
  | V2_list_favorites { limit; cursor } ->
    `Assoc
      [ "type", `String "listFavorites"
      ; "limit", `Int limit
      ; "cursor", option_json cursor_json cursor
      ]
  | V2_list_journals { from_day; through_day; limit; cursor; revision } ->
    `Assoc
      [ "type", `String "listJournals"
      ; "fromDay", `Int from_day
      ; "throughDay", `Int through_day
      ; "limit", `Int limit
      ; "cursor", option_json cursor_json cursor
      ; "revision", optional_string_json revision
      ]
  | V2_get_page { page; revision } ->
    `Assoc
      [ "type", `String "getPage"
      ; "page", uuid_json page
      ; "revision", optional_string_json revision
      ]
  | V2_get_block { block; revision } ->
    `Assoc
      [ "type", `String "getBlock"
      ; "block", uuid_json block
      ; "revision", optional_string_json revision
      ]
  | V2_get_children { parent; limit; cursor; revision } ->
    `Assoc
      [ "type", `String "getChildren"
      ; "parent", uuid_json parent
      ; "limit", `Int limit
      ; "cursor", option_json cursor_json cursor
      ; "revision", optional_string_json revision
      ]
  | V2_get_page_tree { page; maximum_depth; limit; cursor; revision } ->
    `Assoc
      [ "type", `String "getPageTree"
      ; "page", uuid_json page
      ; "maximumDepth", `Int maximum_depth
      ; "limit", `Int limit
      ; "cursor", option_json cursor_json cursor
      ; "revision", optional_string_json revision
      ]
  | V2_save_block { mutation_id; block; title; preconditions } ->
    `Assoc
      [ "type", `String "saveBlock"
      ; "mutationId", uuid_json mutation_id
      ; "block", uuid_json block
      ; "title", `String title
      ; "preconditions", v2_preconditions_to_json preconditions
      ]
  | V2_insert_blocks { mutation_id; parent; roots; preconditions } ->
    `Assoc
      [ "type", `String "insertBlocks"
      ; "mutationId", uuid_json mutation_id
      ; "parent", uuid_json parent
      ; "roots", `List (List.map v2_block_tree_to_json roots)
      ; "preconditions", v2_preconditions_to_json preconditions
      ]
  | V2_delete_blocks { mutation_id; root; preconditions } ->
    `Assoc
      [ "type", `String "deleteBlocks"
      ; "mutationId", uuid_json mutation_id
      ; "root", uuid_json root
      ; "preconditions", v2_preconditions_to_json preconditions
      ]
  | V2_create_journal_page { mutation_id; page; journal_day; title; preconditions } ->
    `Assoc
      [ "type", `String "createJournalPage"
      ; "mutationId", uuid_json mutation_id
      ; "page", uuid_json page
      ; "journalDay", `Int journal_day
      ; "title", `String title
      ; "preconditions", v2_preconditions_to_json preconditions
      ]
  | V2_set_task_status { mutation_id; block; status; preconditions } ->
    `Assoc
      [ "type", `String "setTaskStatus"
      ; "mutationId", uuid_json mutation_id
      ; "block", uuid_json block
      ; "status", `String (v2_task_status_string status)
      ; "preconditions", v2_preconditions_to_json preconditions
      ]
  | V2_clear_task_status { mutation_id; block; preconditions } ->
    `Assoc
      [ "type", `String "clearTaskStatus"
      ; "mutationId", uuid_json mutation_id
      ; "block", uuid_json block
      ; "preconditions", v2_preconditions_to_json preconditions
      ]
  | V2_pull_changes { generation; after; limit } ->
    `Assoc
      [ "type", `String "pullChanges"
      ; "generation", `String generation
      ; "after", optional_string_json after
      ; "limit", `Int limit
      ]
  | V2_ack_changes { generation; through } ->
    `Assoc
      [ "type", `String "ackChanges"
      ; "generation", `String generation
      ; "through", `String through
      ]
;;

let v2_command_of_json kind json =
  let fields names = exact_assoc ("type" :: names) json in
  let preconditions fields = v2_preconditions_of_json (field "preconditions" fields) in
  match kind with
  | "graphInfo" ->
    ignore (fields []);
    V2_graph_info
  | "inspectAdmission" ->
    ignore (fields []);
    V2_inspect_admission
  | "listFavorites" ->
    let f = fields [ "limit"; "cursor" ] in
    let limit = integer (field "limit" f) in
    if limit < 1 || limit > maximum_page_size then decode_error "invalid favorites limit";
    V2_list_favorites { limit; cursor = cursor (field "cursor" f) }
  | "listJournals" ->
    let f = fields [ "fromDay"; "throughDay"; "limit"; "cursor"; "revision" ] in
    V2_list_journals
      { from_day = integer (field "fromDay" f)
      ; through_day = integer (field "throughDay" f)
      ; limit = integer (field "limit" f)
      ; cursor = cursor (field "cursor" f)
      ; revision = optional_string (field "revision" f)
      }
  | "getPage" ->
    let f = fields [ "page"; "revision" ] in
    V2_get_page
      { page = uuid (field "page" f); revision = optional_string (field "revision" f) }
  | "getBlock" ->
    let f = fields [ "block"; "revision" ] in
    V2_get_block
      { block = uuid (field "block" f); revision = optional_string (field "revision" f) }
  | "getChildren" ->
    let f = fields [ "parent"; "limit"; "cursor"; "revision" ] in
    V2_get_children
      { parent = uuid (field "parent" f)
      ; limit = integer (field "limit" f)
      ; cursor = cursor (field "cursor" f)
      ; revision = optional_string (field "revision" f)
      }
  | "getPageTree" ->
    let f = fields [ "page"; "maximumDepth"; "limit"; "cursor"; "revision" ] in
    V2_get_page_tree
      { page = uuid (field "page" f)
      ; maximum_depth = integer (field "maximumDepth" f)
      ; limit = integer (field "limit" f)
      ; cursor = cursor (field "cursor" f)
      ; revision = optional_string (field "revision" f)
      }
  | "saveBlock" ->
    let f = fields [ "mutationId"; "block"; "title"; "preconditions" ] in
    V2_save_block
      { mutation_id = uuid (field "mutationId" f)
      ; block = uuid (field "block" f)
      ; title = string (field "title" f)
      ; preconditions = preconditions f
      }
  | "insertBlocks" ->
    let f = fields [ "mutationId"; "parent"; "roots"; "preconditions" ] in
    V2_insert_blocks
      { mutation_id = uuid (field "mutationId" f)
      ; parent = uuid (field "parent" f)
      ; roots =
          (match field "roots" f with
           | `List roots -> List.map v2_block_tree_of_json roots
           | _ -> decode_error "roots must be a list")
      ; preconditions = preconditions f
      }
  | "deleteBlocks" ->
    let f = fields [ "mutationId"; "root"; "preconditions" ] in
    V2_delete_blocks
      { mutation_id = uuid (field "mutationId" f)
      ; root = uuid (field "root" f)
      ; preconditions = preconditions f
      }
  | "createJournalPage" ->
    let f = fields [ "mutationId"; "page"; "journalDay"; "title"; "preconditions" ] in
    V2_create_journal_page
      { mutation_id = uuid (field "mutationId" f)
      ; page = uuid (field "page" f)
      ; journal_day = integer (field "journalDay" f)
      ; title = string (field "title" f)
      ; preconditions = preconditions f
      }
  | "setTaskStatus" ->
    let f = fields [ "mutationId"; "block"; "status"; "preconditions" ] in
    V2_set_task_status
      { mutation_id = uuid (field "mutationId" f)
      ; block = uuid (field "block" f)
      ; status = v2_task_status (string (field "status" f))
      ; preconditions = preconditions f
      }
  | "clearTaskStatus" ->
    let f = fields [ "mutationId"; "block"; "preconditions" ] in
    V2_clear_task_status
      { mutation_id = uuid (field "mutationId" f)
      ; block = uuid (field "block" f)
      ; preconditions = preconditions f
      }
  | "pullChanges" ->
    let f = fields [ "generation"; "after"; "limit" ] in
    V2_pull_changes
      { generation = string (field "generation" f)
      ; after = optional_string (field "after" f)
      ; limit = integer (field "limit" f)
      }
  | "ackChanges" ->
    let f = fields [ "generation"; "through" ] in
    V2_ack_changes
      { generation = string (field "generation" f); through = string (field "through" f) }
  | _ -> decode_error "unknown v2 command"
;;

let request_to_yojson request =
  `Assoc
    [ "apiVersion", `Int request.api_version
    ; "requestId", uuid_json request.request_id
    ; "command", v2_command_to_json request.command
    ]
;;

let invalid_request message =
  match Error.create ~code:Invalid_request ~message ~details:[] with
  | Ok error -> error
  | Error internal_error -> failwith ("invalid internal request error: " ^ internal_error)
;;

let request_of_yojson json =
  try
    if String.length (Yojson.Safe.to_string json) > maximum_request_bytes
    then decode_error "request exceeds byte budget";
    let fields = exact_assoc [ "apiVersion"; "requestId"; "command" ] json in
    let version = integer (field "apiVersion" fields) in
    if version <> api_version then decode_error "unsupported apiVersion";
    let command_json = field "command" fields in
    let command_fields =
      match command_json with
      | `Assoc fields -> fields
      | _ -> decode_error "invalid command"
    in
    let kind = string (field "type" command_fields) in
    let command = v2_command_of_json kind command_json in
    Ok { api_version = version; request_id = uuid (field "requestId" fields); command }
  with
  | Decode_error message -> Error (invalid_request message)
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

let property_schema_json schema =
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
     | `List values -> Internal_list (List.map internal_value_of_json values)
     | _ -> decode_error "invalid list")
  | "map" ->
    let f = exact_assoc [ "type"; "entries" ] json in
    (match field "entries" f with
     | `List entries ->
       Internal_map
         (List.map
            (fun entry ->
               let fields = exact_assoc [ "key"; "value" ] entry in
               ( internal_value_of_json (field "key" fields)
               , internal_value_of_json (field "value" fields) ))
            entries)
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
  let scalar decode constructor =
    let f = exact_assoc [ "type"; "value" ] json in
    constructor (decode (field "value" f))
  in
  match string (field "type" raw) with
  | "default" -> scalar string (fun value -> Default_value value)
  | "number" -> scalar string (fun value -> Number_value value)
  | "date" ->
    let f = exact_assoc [ "type"; "journalDay" ] json in
    Date_value { journal_day = integer (field "journalDay" f) }
  | "datetime" ->
    let f = exact_assoc [ "type"; "unixMs" ] json in
    Datetime_value { unix_ms = int64 (field "unixMs" f) }
  | "checkbox" -> scalar boolean (fun value -> Checkbox_value value)
  | "url" -> scalar string (fun value -> Url_value value)
  | "node" -> scalar uuid (fun value -> Node_value value)
  | "asset" -> scalar uuid (fun value -> Asset_value value)
  | "keyword" -> scalar string (fun value -> Keyword_value value)
  | "entity" -> scalar uuid (fun value -> Entity_value value)
  | "class" -> scalar uuid (fun value -> Class_value value)
  | "page" -> scalar uuid (fun value -> Page_value value)
  | "property" -> scalar string (fun value -> Property_value value)
  | "string" -> scalar string (fun value -> String_value value)
  | "json" -> scalar string (fun value -> Json_value value)
  | "rawNumber" -> scalar string (fun value -> Raw_number_value value)
  | "map" ->
    scalar internal_value_of_json (function
      | Internal_map values -> Map_value values
      | _ -> decode_error "expected map")
  | "collection" ->
    scalar internal_value_of_json (function
      | Internal_list values -> Collection_value values
      | _ -> decode_error "expected list")
  | "any" -> scalar internal_value_of_json (fun value -> Any_value value)
  | _ -> decode_error "invalid property value type"
;;

let property_summary_to_json (summary : property_summary) =
  `Assoc
    [ "ident", `String summary.ident
    ; "uuid", uuid_json summary.uuid
    ; "title", `String summary.title
    ; "schema", property_schema_json summary.schema
    ; "values", `List (List.map property_value_to_json summary.values)
    ; "valuesTruncated", `Bool summary.values_truncated
    ]
;;

let page_kind_to_json = function
  | Ordinary_page -> `Assoc [ "type", `String "ordinary" ]
  | Journal_page { journal_day } ->
    `Assoc [ "type", `String "journal"; "journalDay", `Int journal_day ]
  | Class_page -> `Assoc [ "type", `String "class" ]
  | Property_page -> `Assoc [ "type", `String "property" ]
  | Hidden_page -> `Assoc [ "type", `String "hidden" ]
  | Built_in_page -> `Assoc [ "type", `String "builtIn" ]
;;

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
;;

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
;;

let schema_version_to_json schema =
  `Assoc [ "major", `Int schema.major; "minor", `Int schema.minor ]
;;

let schema_version_of_json json =
  let fields = exact_assoc [ "major"; "minor" ] json in
  { major = integer (field "major" fields); minor = integer (field "minor" fields) }
;;

let page_kind_of_json json =
  let raw =
    match json with
    | `Assoc fields -> fields
    | _ -> decode_error "invalid page kind"
  in
  match string (field "type" raw) with
  | "ordinary" ->
    ignore (exact_assoc [ "type" ] json);
    Ordinary_page
  | "journal" ->
    let fields = exact_assoc [ "type"; "journalDay" ] json in
    Journal_page { journal_day = integer (field "journalDay" fields) }
  | "class" ->
    ignore (exact_assoc [ "type" ] json);
    Class_page
  | "property" ->
    ignore (exact_assoc [ "type" ] json);
    Property_page
  | "hidden" ->
    ignore (exact_assoc [ "type" ] json);
    Hidden_page
  | "builtIn" ->
    ignore (exact_assoc [ "type" ] json);
    Built_in_page
  | _ -> decode_error "invalid page kind"
;;

let property_summary_of_json json =
  let fields =
    exact_assoc [ "ident"; "uuid"; "title"; "schema"; "values"; "valuesTruncated" ] json
  in
  let schema = property_schema_of_json (field "schema" fields) in
  let values =
    match field "values" fields with
    | `List values -> List.map (fun value -> property_value_of_json value) values
    | _ -> decode_error "property values must be a list"
  in
  { ident = string (field "ident" fields)
  ; uuid = uuid (field "uuid" fields)
  ; title = string (field "title" fields)
  ; schema
  ; values
  ; values_truncated = boolean (field "valuesTruncated" fields)
  }
;;

let property_summaries_of_json = function
  | `List values -> List.map property_summary_of_json values
  | _ -> decode_error "properties must be a list"
;;

let block_of_json json =
  let fields =
    exact_assoc
      [ "uuid"
      ; "title"
      ; "parent"
      ; "page"
      ; "order"
      ; "createdAtMs"
      ; "updatedAtMs"
      ; "refs"
      ; "tags"
      ; "properties"
      ]
      json
  in
  { uuid = uuid (field "uuid" fields)
  ; title = string (field "title" fields)
  ; parent = uuid (field "parent" fields)
  ; page = uuid (field "page" fields)
  ; order = string (field "order" fields)
  ; created_at_ms = int64 (field "createdAtMs" fields)
  ; updated_at_ms = int64 (field "updatedAtMs" fields)
  ; refs = uuid_list (field "refs" fields)
  ; tags = uuid_list (field "tags" fields)
  ; properties = property_summaries_of_json (field "properties" fields)
  }
;;

let page_of_json json =
  let fields =
    exact_assoc
      [ "uuid"
      ; "name"
      ; "title"
      ; "kind"
      ; "createdAtMs"
      ; "updatedAtMs"
      ; "tags"
      ; "properties"
      ; "recycled"
      ]
      json
  in
  { uuid = uuid (field "uuid" fields)
  ; name = string (field "name" fields)
  ; title = string (field "title" fields)
  ; kind = page_kind_of_json (field "kind" fields)
  ; created_at_ms = int64 (field "createdAtMs" fields)
  ; updated_at_ms = int64 (field "updatedAtMs" fields)
  ; tags = uuid_list (field "tags" fields)
  ; properties = property_summaries_of_json (field "properties" fields)
  ; recycled = boolean (field "recycled" fields)
  }
;;

let v2_admission_fact_to_json = function
  | Compatible_schema { minimum; actual } ->
    `Assoc
      [ "type", `String "compatibleSchema"
      ; "minimum", schema_version_to_json minimum
      ; "actual", schema_version_to_json actual
      ]
  | Local_graph uuid ->
    `Assoc [ "type", `String "localGraph"; "graphUuid", uuid_json uuid ]
  | Remote_flag_absent -> `Assoc [ "type", `String "remoteFlagAbsent" ]
  | Remote_flag_false -> `Assoc [ "type", `String "remoteFlagFalse" ]
  | Remote_flag_true -> `Assoc [ "type", `String "remoteFlagTrue" ]
  | No_rtc_identity -> `Assoc [ "type", `String "noRtcIdentity" ]
  | Synced_graph_identity graph_uuid ->
    `Assoc [ "type", `String "syncedGraphIdentity"; "graphUuid", uuid_json graph_uuid ]
  | Lossless_codec -> `Assoc [ "type", `String "losslessCodec" ]
  | Ownership_verified -> `Assoc [ "type", `String "ownershipVerified" ]
;;

let v2_admission_fact_of_json json =
  let raw =
    match json with
    | `Assoc fields -> fields
    | _ -> decode_error "invalid admission fact"
  in
  match string (field "type" raw) with
  | "compatibleSchema" ->
    let fields = exact_assoc [ "type"; "minimum"; "actual" ] json in
    Compatible_schema
      { minimum = schema_version_of_json (field "minimum" fields)
      ; actual = schema_version_of_json (field "actual" fields)
      }
  | "localGraph" ->
    let fields = exact_assoc [ "type"; "graphUuid" ] json in
    Local_graph (uuid (field "graphUuid" fields))
  | "remoteFlagAbsent" ->
    ignore (exact_assoc [ "type" ] json);
    Remote_flag_absent
  | "remoteFlagFalse" ->
    ignore (exact_assoc [ "type" ] json);
    Remote_flag_false
  | "remoteFlagTrue" ->
    ignore (exact_assoc [ "type" ] json);
    Remote_flag_true
  | "noRtcIdentity" ->
    ignore (exact_assoc [ "type" ] json);
    No_rtc_identity
  | "syncedGraphIdentity" ->
    let fields = exact_assoc [ "type"; "graphUuid" ] json in
    Synced_graph_identity (uuid (field "graphUuid" fields))
  | "losslessCodec" ->
    ignore (exact_assoc [ "type" ] json);
    Lossless_codec
  | "ownershipVerified" ->
    ignore (exact_assoc [ "type" ] json);
    Ownership_verified
  | _ -> decode_error "invalid admission fact"
;;

let v2_revision_scope_to_json = function
  | V2_children_revision parent ->
    `Assoc [ "type", `String "children"; "parent", uuid_json parent ]
;;

let v2_revision_scope_of_json json =
  let raw =
    match json with
    | `Assoc fields -> fields
    | _ -> decode_error "invalid revision scope"
  in
  match string (field "type" raw) with
  | "children" ->
    let fields = exact_assoc [ "type"; "parent" ] json in
    V2_children_revision (uuid (field "parent" fields))
  | _ -> decode_error "invalid revision scope"
;;

let v2_structure_interest_to_json = function
  | V2_children_interest parent ->
    `Assoc [ "type", `String "children"; "parent", uuid_json parent ]
  | V2_page_tree_interest page ->
    `Assoc [ "type", `String "pageTree"; "page", uuid_json page ]
  | V2_journal_index_interest -> `Assoc [ "type", `String "journalIndex" ]
;;

let v2_structure_interest_of_json json =
  let raw =
    match json with
    | `Assoc fields -> fields
    | _ -> decode_error "invalid structure interest"
  in
  match string (field "type" raw) with
  | "children" ->
    let fields = exact_assoc [ "type"; "parent" ] json in
    V2_children_interest (uuid (field "parent" fields))
  | "pageTree" ->
    let fields = exact_assoc [ "type"; "page" ] json in
    V2_page_tree_interest (uuid (field "page" fields))
  | "journalIndex" ->
    ignore (exact_assoc [ "type" ] json);
    V2_journal_index_interest
  | _ -> decode_error "invalid structure interest type"
;;

let v2_change_window_to_json window =
  `Assoc
    [ "id", `String window.id
    ; "predecessor", `String window.predecessor
    ; "successor", `String window.successor
    ; "blockUuids", uuids_json window.block_uuids
    ; "pageUuids", uuids_json window.page_uuids
    ; ( "structureInterests"
      , `List (List.map v2_structure_interest_to_json window.structure_interests) )
    ]
;;

let v2_capability_limits_to_json limits =
  `Assoc
    [ "responseBudgetBytes", `Int limits.response_budget_bytes
    ; "outboxMaxRecords", `Int limits.outbox_max_records
    ; "outboxMaxBytes", `Int limits.outbox_max_bytes
    ; "changeMaxItems", `Int limits.change_max_items
    ; "changeMaxBytes", `Int limits.change_max_bytes
    ; "dispatcherCapacity", `Int limits.dispatcher_capacity
    ; "wireBatchMaxBytes", `Int limits.wire_batch_max_bytes
    ]
;;

let v2_capability_limits_of_json json =
  let fields =
    exact_assoc
      [ "responseBudgetBytes"
      ; "outboxMaxRecords"
      ; "outboxMaxBytes"
      ; "changeMaxItems"
      ; "changeMaxBytes"
      ; "dispatcherCapacity"
      ; "wireBatchMaxBytes"
      ]
      json
  in
  { response_budget_bytes = integer (field "responseBudgetBytes" fields)
  ; outbox_max_records = integer (field "outboxMaxRecords" fields)
  ; outbox_max_bytes = integer (field "outboxMaxBytes" fields)
  ; change_max_items = integer (field "changeMaxItems" fields)
  ; change_max_bytes = integer (field "changeMaxBytes" fields)
  ; dispatcher_capacity = integer (field "dispatcherCapacity" fields)
  ; wire_batch_max_bytes = integer (field "wireBatchMaxBytes" fields)
  }
;;

let v2_block_record_to_json value =
  `Assoc
    [ "block", block_to_json value.block
    ; ( "taskStatus"
      , option_json
          (fun status -> `String (v2_task_status_string status))
          value.task_status )
    ; "renderedPageTitle", `String value.rendered_page_title
    ]
;;

let v2_page_lookup_to_json = function
  | V2_present_page { page; revision } ->
    `Assoc
      [ "type", `String "present"
      ; "revision", `String revision
      ; "page", page_to_json page
      ]
  | V2_missing_page { uuid; revision } ->
    `Assoc
      [ "type", `String "missing"; "uuid", uuid_json uuid; "revision", `String revision ]
;;

let v2_page_lookup_of_json json =
  let raw =
    match json with
    | `Assoc fields -> fields
    | _ -> decode_error "invalid page lookup"
  in
  match string (field "type" raw) with
  | "present" ->
    let fields = exact_assoc [ "type"; "revision"; "page" ] json in
    V2_present_page
      { page = page_of_json (field "page" fields)
      ; revision = string (field "revision" fields)
      }
  | "missing" ->
    let fields = exact_assoc [ "type"; "uuid"; "revision" ] json in
    V2_missing_page
      { uuid = uuid (field "uuid" fields); revision = string (field "revision" fields) }
  | _ -> decode_error "invalid page lookup type"
;;

let v2_block_lookup_to_json = function
  | V2_present_block { value; revision } ->
    (match v2_block_record_to_json value with
     | `Assoc fields ->
       `Assoc (("type", `String "present") :: ("revision", `String revision) :: fields)
     | _ -> assert false)
  | V2_missing_block { uuid; revision } ->
    `Assoc
      [ "type", `String "missing"; "uuid", uuid_json uuid; "revision", `String revision ]
;;

let v2_block_lookup_of_json json =
  let raw =
    match json with
    | `Assoc fields -> fields
    | _ -> decode_error "invalid block lookup"
  in
  match string (field "type" raw) with
  | "present" ->
    let fields =
      exact_assoc [ "type"; "revision"; "taskStatus"; "renderedPageTitle"; "block" ] json
    in
    V2_present_block
      { value =
          { block = block_of_json (field "block" fields)
          ; task_status =
              (match field "taskStatus" fields with
               | `Null -> None
               | value -> Some (v2_task_status (string value)))
          ; rendered_page_title = string (field "renderedPageTitle" fields)
          }
      ; revision = string (field "revision" fields)
      }
  | "missing" ->
    let fields = exact_assoc [ "type"; "uuid"; "revision" ] json in
    V2_missing_block
      { uuid = uuid (field "uuid" fields); revision = string (field "revision" fields) }
  | _ -> decode_error "invalid block lookup type"
;;

let v2_favorite_target_to_json = function
  | V2_favorite_page { uuid; title; revision } ->
    `Assoc
      [ "type", `String "page"
      ; "uuid", uuid_json uuid
      ; "title", `String title
      ; "revision", `String revision
      ]
  | V2_favorite_block { uuid; title; task_status; revision } ->
    `Assoc
      [ "type", `String "block"
      ; "uuid", uuid_json uuid
      ; "title", `String title
      ; "revision", `String revision
      ; ( "taskStatus"
        , option_json (fun status -> `String (v2_task_status_string status)) task_status )
      ]
;;

let v2_favorite_target_of_json json =
  let kind =
    match json with
    | `Assoc f -> string (field "type" f)
    | _ -> decode_error "invalid favorite target"
  in
  let names = [ "type"; "uuid"; "title"; "revision" ] in
  let f = exact_assoc (if kind = "block" then "taskStatus" :: names else names) json in
  let uuid = uuid (field "uuid" f)
  and title = string (field "title" f)
  and revision = string (field "revision" f) in
  if String.length title > maximum_title_bytes
  then decode_error "favorite title exceeds limit";
  match kind with
  | "page" -> V2_favorite_page { uuid; title; revision }
  | "block" ->
    V2_favorite_block
      { uuid
      ; title
      ; revision
      ; task_status =
          (match field "taskStatus" f with
           | `Null -> None
           | value -> Some (v2_task_status (string value)))
      }
  | _ -> decode_error "invalid favorite target kind"
;;

let v2_favorite_item_to_json (item : v2_favorite_item) =
  `Assoc
    [ "membershipUuid", uuid_json item.membership_uuid
    ; "membershipOrder", `String item.membership_order
    ; "membershipRevision", `String item.membership_revision
    ; "target", v2_favorite_target_to_json item.target
    ]
;;

let v2_favorite_item_of_json json =
  let f =
    exact_assoc
      [ "membershipUuid"; "membershipOrder"; "membershipRevision"; "target" ]
      json
  in
  { membership_uuid = uuid (field "membershipUuid" f)
  ; membership_order = string (field "membershipOrder" f)
  ; membership_revision = string (field "membershipRevision" f)
  ; target = v2_favorite_target_of_json (field "target" f)
  }
;;

let v2_journal_item_to_json (item : v2_journal_item) =
  `Assoc
    [ "page", page_to_json item.page
    ; "journalDay", `Int item.journal_day
    ; "revision", `String item.revision
    ]
;;

let v2_journal_item_of_json json =
  let fields = exact_assoc [ "page"; "journalDay"; "revision" ] json in
  { page = page_of_json (field "page" fields)
  ; journal_day = integer (field "journalDay" fields)
  ; revision = string (field "revision" fields)
  }
;;

let v2_child_member_to_json (item : v2_child_member) =
  match v2_block_record_to_json item.value with
  | `Assoc fields -> `Assoc (("revision", `String item.revision) :: fields)
  | _ -> assert false
;;

let v2_child_member_of_json json =
  let fields =
    exact_assoc [ "block"; "taskStatus"; "renderedPageTitle"; "revision" ] json
  in
  { value =
      { block = block_of_json (field "block" fields)
      ; task_status =
          (match field "taskStatus" fields with
           | `Null -> None
           | value -> Some (v2_task_status (string value)))
      ; rendered_page_title = string (field "renderedPageTitle" fields)
      }
  ; revision = string (field "revision" fields)
  }
;;

let v2_tree_member_to_json (item : v2_tree_member) =
  match v2_block_record_to_json item.value with
  | `Assoc fields ->
    `Assoc
      (("revision", `String item.revision)
       :: ("depth", `Int item.depth)
       :: ("parent", uuid_json item.parent)
       :: fields)
  | _ -> assert false
;;

let v2_tree_member_of_json json =
  let fields =
    exact_assoc
      [ "block"; "taskStatus"; "renderedPageTitle"; "revision"; "depth"; "parent" ]
      json
  in
  { value =
      { block = block_of_json (field "block" fields)
      ; task_status =
          (match field "taskStatus" fields with
           | `Null -> None
           | value -> Some (v2_task_status (string value)))
      ; rendered_page_title = string (field "renderedPageTitle" fields)
      }
  ; revision = string (field "revision" fields)
  ; depth = integer (field "depth" fields)
  ; parent = uuid (field "parent" fields)
  }
;;

let v2_outcome_to_json = function
  | V2_graph_info_outcome
      { graph_uuid
      ; graph_name
      ; schema
      ; admission_facts
      ; limits
      ; generation
      ; projection_revision
      } ->
    `Assoc
      [ "type", `String "graphInfo"
      ; "graphUuid", uuid_json graph_uuid
      ; "graphName", `String graph_name
      ; "schema", schema_version_to_json schema
      ; "admissionFacts", `List (List.map v2_admission_fact_to_json admission_facts)
      ; "limits", v2_capability_limits_to_json limits
      ; "generation", `String generation
      ; "projectionRevision", `String projection_revision
      ]
  | V2_admission_outcome
      { active_records
      ; active_bytes
      ; protected_wire_bytes
      ; retained_origin_evidence_bytes
      ; maximum_records
      ; maximum_bytes
      } ->
    `Assoc
      [ "type", `String "admission"
      ; "activeRecords", `Int active_records
      ; "activeBytes", `Int active_bytes
      ; "protectedWireBytes", `Int protected_wire_bytes
      ; "retainedOriginEvidenceBytes", `Int retained_origin_evidence_bytes
      ; "maximumRecords", `Int maximum_records
      ; "maximumBytes", `Int maximum_bytes
      ]
  | V2_favorites_outcome result ->
    `Assoc
      [ "type", `String "favorites"
      ; "favoritesPage", option_json uuid_json result.favorites_page
      ; "generation", `String result.generation
      ; "projectionRevision", `String result.projection_revision
      ; "items", `List (List.map v2_favorite_item_to_json result.items)
      ; "nextCursor", option_json cursor_json result.next_cursor
      ]
  | V2_journals_outcome { items; next_cursor } ->
    `Assoc
      [ "type", `String "journals"
      ; "items", `List (List.map v2_journal_item_to_json items)
      ; "nextCursor", option_json cursor_json next_cursor
      ]
  | V2_page_outcome lookup ->
    `Assoc [ "type", `String "page"; "lookup", v2_page_lookup_to_json lookup ]
  | V2_block_outcome lookup ->
    `Assoc [ "type", `String "block"; "lookup", v2_block_lookup_to_json lookup ]
  | V2_children_outcome { parent; revision_scope; scope_revision; items; next_cursor } ->
    `Assoc
      [ "type", `String "children"
      ; "parent", uuid_json parent
      ; "revisionScope", v2_revision_scope_to_json revision_scope
      ; "scopeRevision", `String scope_revision
      ; "items", `List (List.map v2_child_member_to_json items)
      ; "nextCursor", option_json cursor_json next_cursor
      ]
  | V2_page_tree_outcome { page; maximum_depth; items; next_cursor } ->
    `Assoc
      [ "type", `String "pageTree"
      ; "page", uuid_json page
      ; "maximumDepth", `Int maximum_depth
      ; "items", `List (List.map v2_tree_member_to_json items)
      ; "nextCursor", option_json cursor_json next_cursor
      ]
  | V2_mutation_committed
      { mutation_id
      ; status
      ; generation
      ; before_projection_revision
      ; after_projection_revision
      } ->
    `Assoc
      [ "type", `String "mutationCommitted"
      ; "mutationId", uuid_json mutation_id
      ; "status", `String (v2_local_status_string status)
      ; "generation", `String generation
      ; "beforeProjectionRevision", `String before_projection_revision
      ; "afterProjectionRevision", `String after_projection_revision
      ]
  | V2_changes { generation; from_exclusive; through; windows; next } ->
    `Assoc
      [ "type", `String "changes"
      ; "generation", `String generation
      ; "fromExclusive", optional_string_json from_exclusive
      ; "through", `String through
      ; "windows", `List (List.map v2_change_window_to_json windows)
      ; "next", optional_string_json next
      ]
  | V2_changes_acknowledged { generation; through } ->
    `Assoc
      [ "type", `String "changesAcknowledged"
      ; "generation", `String generation
      ; "through", `String through
      ]
  | V2_failed { code; message } ->
    `Assoc [ "type", `String "failed"; "code", `String code; "message", `String message ]
  | V2_resync_required { generation; reason } ->
    `Assoc
      [ "type", `String "resyncRequired"
      ; "generation", `String generation
      ; "reason", `String reason
      ]
;;

let v2_change_window_of_json json =
  let fields =
    exact_assoc
      [ "id"
      ; "predecessor"
      ; "successor"
      ; "blockUuids"
      ; "pageUuids"
      ; "structureInterests"
      ]
      json
  in
  { id = string (field "id" fields)
  ; predecessor = string (field "predecessor" fields)
  ; successor = string (field "successor" fields)
  ; block_uuids = uuid_list (field "blockUuids" fields)
  ; page_uuids = uuid_list (field "pageUuids" fields)
  ; structure_interests =
      (match field "structureInterests" fields with
       | `List values -> List.map v2_structure_interest_of_json values
       | _ -> decode_error "structureInterests must be a list")
  }
;;

let v2_outcome_of_json json =
  let raw =
    match json with
    | `Assoc fields -> fields
    | _ -> decode_error "invalid v2 outcome"
  in
  match string (field "type" raw) with
  | "graphInfo" ->
    let fields =
      exact_assoc
        [ "type"
        ; "graphUuid"
        ; "graphName"
        ; "schema"
        ; "admissionFacts"
        ; "limits"
        ; "generation"
        ; "projectionRevision"
        ]
        json
    in
    V2_graph_info_outcome
      { graph_uuid = uuid (field "graphUuid" fields)
      ; graph_name = string (field "graphName" fields)
      ; schema = schema_version_of_json (field "schema" fields)
      ; admission_facts =
          (match field "admissionFacts" fields with
           | `List values -> List.map v2_admission_fact_of_json values
           | _ -> decode_error "admissionFacts must be a list")
      ; limits = v2_capability_limits_of_json (field "limits" fields)
      ; generation = string (field "generation" fields)
      ; projection_revision = string (field "projectionRevision" fields)
      }
  | "admission" ->
    let fields =
      exact_assoc
        [ "type"
        ; "activeRecords"
        ; "activeBytes"
        ; "protectedWireBytes"
        ; "retainedOriginEvidenceBytes"
        ; "maximumRecords"
        ; "maximumBytes"
        ]
        json
    in
    V2_admission_outcome
      { active_records = integer (field "activeRecords" fields)
      ; active_bytes = integer (field "activeBytes" fields)
      ; protected_wire_bytes = integer (field "protectedWireBytes" fields)
      ; retained_origin_evidence_bytes =
          integer (field "retainedOriginEvidenceBytes" fields)
      ; maximum_records = integer (field "maximumRecords" fields)
      ; maximum_bytes = integer (field "maximumBytes" fields)
      }
  | "favorites" ->
    let f =
      exact_assoc
        [ "type"
        ; "favoritesPage"
        ; "generation"
        ; "projectionRevision"
        ; "items"
        ; "nextCursor"
        ]
        json
    in
    let items =
      match field "items" f with
      | `List items when List.length items <= maximum_page_size ->
        List.map v2_favorite_item_of_json items
      | _ -> decode_error "invalid favorite items"
    in
    V2_favorites_outcome
      { favorites_page =
          (match field "favoritesPage" f with
           | `Null -> None
           | value -> Some (uuid value))
      ; generation = string (field "generation" f)
      ; projection_revision = string (field "projectionRevision" f)
      ; items
      ; next_cursor = cursor (field "nextCursor" f)
      }
  | "journals" ->
    let fields = exact_assoc [ "type"; "items"; "nextCursor" ] json in
    V2_journals_outcome
      { items =
          (match field "items" fields with
           | `List values -> List.map v2_journal_item_of_json values
           | _ -> decode_error "journal items must be a list")
      ; next_cursor = cursor (field "nextCursor" fields)
      }
  | "page" ->
    let fields = exact_assoc [ "type"; "lookup" ] json in
    V2_page_outcome (v2_page_lookup_of_json (field "lookup" fields))
  | "block" ->
    let fields = exact_assoc [ "type"; "lookup" ] json in
    V2_block_outcome (v2_block_lookup_of_json (field "lookup" fields))
  | "children" ->
    let fields =
      exact_assoc
        [ "type"; "parent"; "revisionScope"; "scopeRevision"; "items"; "nextCursor" ]
        json
    in
    V2_children_outcome
      { parent = uuid (field "parent" fields)
      ; revision_scope = v2_revision_scope_of_json (field "revisionScope" fields)
      ; scope_revision = string (field "scopeRevision" fields)
      ; items =
          (match field "items" fields with
           | `List values -> List.map v2_child_member_of_json values
           | _ -> decode_error "child items must be a list")
      ; next_cursor = cursor (field "nextCursor" fields)
      }
  | "pageTree" ->
    let fields =
      exact_assoc [ "type"; "page"; "maximumDepth"; "items"; "nextCursor" ] json
    in
    V2_page_tree_outcome
      { page = uuid (field "page" fields)
      ; maximum_depth = integer (field "maximumDepth" fields)
      ; items =
          (match field "items" fields with
           | `List values -> List.map v2_tree_member_of_json values
           | _ -> decode_error "page-tree items must be a list")
      ; next_cursor = cursor (field "nextCursor" fields)
      }
  | "mutationCommitted" ->
    let fields =
      exact_assoc
        [ "type"
        ; "mutationId"
        ; "status"
        ; "generation"
        ; "beforeProjectionRevision"
        ; "afterProjectionRevision"
        ]
        json
    in
    V2_mutation_committed
      { mutation_id = uuid (field "mutationId" fields)
      ; status = v2_local_status (string (field "status" fields))
      ; generation = string (field "generation" fields)
      ; before_projection_revision = string (field "beforeProjectionRevision" fields)
      ; after_projection_revision = string (field "afterProjectionRevision" fields)
      }
  | "changes" ->
    let fields =
      exact_assoc
        [ "type"; "generation"; "fromExclusive"; "through"; "windows"; "next" ]
        json
    in
    V2_changes
      { generation = string (field "generation" fields)
      ; from_exclusive = optional_string (field "fromExclusive" fields)
      ; through = string (field "through" fields)
      ; windows =
          (match field "windows" fields with
           | `List windows -> List.map v2_change_window_of_json windows
           | _ -> decode_error "windows must be a list")
      ; next = optional_string (field "next" fields)
      }
  | "changesAcknowledged" ->
    let fields = exact_assoc [ "type"; "generation"; "through" ] json in
    V2_changes_acknowledged
      { generation = string (field "generation" fields)
      ; through = string (field "through" fields)
      }
  | "failed" ->
    let fields = exact_assoc [ "type"; "code"; "message" ] json in
    V2_failed
      { code = string (field "code" fields); message = string (field "message" fields) }
  | "resyncRequired" ->
    let fields = exact_assoc [ "type"; "generation"; "reason" ] json in
    V2_resync_required
      { generation = string (field "generation" fields)
      ; reason = string (field "reason" fields)
      }
  | _ -> decode_error "invalid v2 outcome type"
;;

let response_to_yojson = function
  | V2_response { api_version; request_id; outcome } ->
    `Assoc
      [ "apiVersion", `Int api_version
      ; "requestId", uuid_json request_id
      ; "outcome", v2_outcome_to_json outcome
      ]
;;

let response_of_yojson json =
  try
    let fields = exact_assoc [ "apiVersion"; "requestId"; "outcome" ] json in
    let version = integer (field "apiVersion" fields) in
    if version <> api_version then decode_error "unsupported apiVersion";
    Ok
      (V2_response
         { api_version = version
         ; request_id = uuid (field "requestId" fields)
         ; outcome = v2_outcome_of_json (field "outcome" fields)
         })
  with
  | Decode_error message -> Error message
;;

let push_to_yojson = function
  | V2_changes_available { api_version; generation; through } ->
    `Assoc
      [ "apiVersion", `Int api_version
      ; ( "push"
        , `Assoc
            [ "type", `String "changesAvailable"
            ; "generation", `String generation
            ; "through", `String through
            ] )
      ]
  | V2_resync_required_push { api_version; generation; reason } ->
    `Assoc
      [ "apiVersion", `Int api_version
      ; ( "push"
        , `Assoc
            [ "type", `String "resyncRequired"
            ; "generation", `String generation
            ; "reason", `String reason
            ] )
      ]
;;

let push_of_yojson json =
  try
    let fields = exact_assoc [ "apiVersion"; "push" ] json in
    let version = integer (field "apiVersion" fields) in
    if version <> api_version then decode_error "unsupported apiVersion";
    let push_json = field "push" fields in
    let push_fields =
      match push_json with
      | `Assoc values -> values
      | _ -> decode_error "invalid push"
    in
    match string (field "type" push_fields) with
    | "changesAvailable" ->
      let values = exact_assoc [ "type"; "generation"; "through" ] push_json in
      Ok
        (V2_changes_available
           { api_version = version
           ; generation = string (field "generation" values)
           ; through = string (field "through" values)
           })
    | "resyncRequired" ->
      let values = exact_assoc [ "type"; "generation"; "reason" ] push_json in
      Ok
        (V2_resync_required_push
           { api_version = version
           ; generation = string (field "generation" values)
           ; reason = string (field "reason" values)
           })
    | _ -> decode_error "invalid v2 push type"
  with
  | Decode_error message -> Error message
;;

let encoded_response_bytes response =
  String.length (Yojson.Safe.to_string (response_to_yojson response))
;;
