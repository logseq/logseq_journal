open Graph_types

let api_version = 1
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
  | Read of read_command
  | Mutate of Mutation.t

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
  | Mutation_result of Mutation.success

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

let page_kind_filter_string = function
  | Any_page -> "any"
  | Only_ordinary_pages -> "ordinary"
  | Only_journals -> "journal"
  | Only_classes -> "class"
  | Only_properties -> "property"
;;

let page_kind_filter = function
  | "any" -> Any_page
  | "ordinary" -> Only_ordinary_pages
  | "journal" -> Only_journals
  | "class" -> Only_classes
  | "property" -> Only_properties
  | _ -> decode_error "invalid page kind filter"
;;

let page_selector_to_json = function
  | Page_by_uuid uuid -> `Assoc [ "type", `String "uuid"; "uuid", uuid_json uuid ]
  | Page_by_name { name; kind } ->
    `Assoc
      [ "type", `String "name"
      ; "name", `String name
      ; "kind", `String (page_kind_filter_string kind)
      ]
;;

let page_selector_of_json json =
  match
    field
      "type"
      (match json with
       | `Assoc fields -> fields
       | _ -> decode_error "invalid page selector")
    |> string
  with
  | "uuid" ->
    let fields = exact_assoc [ "type"; "uuid" ] json in
    Page_by_uuid (uuid (field "uuid" fields))
  | "name" ->
    let fields = exact_assoc [ "type"; "name"; "kind" ] json in
    Page_by_name
      { name = string (field "name" fields)
      ; kind = page_kind_filter (string (field "kind" fields))
      }
  | _ -> decode_error "invalid page selector type"
;;

let property_scope_to_json = function
  | All_properties -> `Assoc [ "type", `String "all" ]
  | User_properties -> `Assoc [ "type", `String "user" ]
  | Properties_for_block block ->
    `Assoc [ "type", `String "block"; "block", uuid_json block ]
  | Properties_for_class class_ ->
    `Assoc [ "type", `String "class"; "class", uuid_json class_ ]
;;

let property_scope_of_json json =
  let raw =
    match json with
    | `Assoc fields -> fields
    | _ -> decode_error "invalid scope"
  in
  match string (field "type" raw) with
  | "all" ->
    ignore (exact_assoc [ "type" ] json);
    All_properties
  | "user" ->
    ignore (exact_assoc [ "type" ] json);
    User_properties
  | "block" ->
    let f = exact_assoc [ "type"; "block" ] json in
    Properties_for_block (uuid (field "block" f))
  | "class" ->
    let f = exact_assoc [ "type"; "class" ] json in
    Properties_for_class (uuid (field "class" f))
  | _ -> decode_error "invalid scope type"
;;

let task_state_string = function
  | Todo -> "todo"
  | Doing -> "doing"
  | Done -> "done"
  | Cancelled -> "cancelled"
  | Waiting -> "waiting"
  | Now -> "now"
  | Later -> "later"
;;

let task_state = function
  | "todo" -> Todo
  | "doing" -> Doing
  | "done" -> Done
  | "cancelled" -> Cancelled
  | "waiting" -> Waiting
  | "now" -> Now
  | "later" -> Later
  | _ -> decode_error "invalid task state"
;;

let task_filter_to_json filter =
  let opt_int = option_json (fun value -> `Int value) in
  `Assoc
    [ ( "states"
      , `List (List.map (fun state -> `String (task_state_string state)) filter.states) )
    ; "page", option_json uuid_json filter.page
    ; "scheduledFrom", opt_int filter.scheduled_from
    ; "scheduledThrough", opt_int filter.scheduled_through
    ; "deadlineFrom", opt_int filter.deadline_from
    ; "deadlineThrough", opt_int filter.deadline_through
    ]
;;

let task_filter_of_json json =
  let fields =
    exact_assoc
      [ "states"
      ; "page"
      ; "scheduledFrom"
      ; "scheduledThrough"
      ; "deadlineFrom"
      ; "deadlineThrough"
      ]
      json
  in
  let opt_int = function
    | `Null -> None
    | value -> Some (integer value)
  in
  { states =
      (match field "states" fields with
       | `List xs -> List.map (fun x -> task_state (string x)) xs
       | _ -> decode_error "invalid states")
  ; page =
      (match field "page" fields with
       | `Null -> None
       | value -> Some (uuid value))
  ; scheduled_from = opt_int (field "scheduledFrom" fields)
  ; scheduled_through = opt_int (field "scheduledThrough" fields)
  ; deadline_from = opt_int (field "deadlineFrom" fields)
  ; deadline_through = opt_int (field "deadlineThrough" fields)
  }
;;

let paged_fields limit cursor =
  [ "limit", `Int limit; "cursor", option_json cursor_json cursor ]
;;

let read_to_json = function
  | Graph_info -> `Assoc [ "type", `String "graphInfo" ]
  | Get_block { block } -> `Assoc [ "type", `String "getBlock"; "block", uuid_json block ]
  | Get_page { page } ->
    `Assoc [ "type", `String "getPage"; "page", page_selector_to_json page ]
  | Get_children { parent; limit; cursor } ->
    `Assoc
      (("type", `String "getChildren")
       :: ("parent", uuid_json parent)
       :: paged_fields limit cursor)
  | Get_page_tree { page; maximum_depth; limit; cursor } ->
    `Assoc
      (("type", `String "getPageTree")
       :: ("page", uuid_json page)
       :: ("maximumDepth", `Int maximum_depth)
       :: paged_fields limit cursor)
  | Get_ancestors { block; limit } ->
    `Assoc
      [ "type", `String "getAncestors"; "block", uuid_json block; "limit", `Int limit ]
  | Get_siblings { block; limit; cursor } ->
    `Assoc
      (("type", `String "getSiblings")
       :: ("block", uuid_json block)
       :: paged_fields limit cursor)
  | List_pages { kind; limit; cursor } ->
    `Assoc
      (("type", `String "listPages")
       :: ("kind", `String (page_kind_filter_string kind))
       :: paged_fields limit cursor)
  | List_tags { limit; cursor } ->
    `Assoc (("type", `String "listTags") :: paged_fields limit cursor)
  | List_properties { scope; limit; cursor } ->
    `Assoc
      (("type", `String "listProperties")
       :: ("scope", property_scope_to_json scope)
       :: paged_fields limit cursor)
  | List_tasks { filter; limit; cursor } ->
    `Assoc
      (("type", `String "listTasks")
       :: ("filter", task_filter_to_json filter)
       :: paged_fields limit cursor)
  | Get_references { target; direction; limit; cursor } ->
    `Assoc
      (("type", `String "getReferences")
       :: ("target", uuid_json target)
       :: ( "direction"
          , `String
              (match direction with
               | Referring_to -> "referringTo"
               | Referred_from -> "referredFrom") )
       :: paged_fields limit cursor)
;;

let read_of_json kind json =
  let paged expected constructor =
    let f = exact_assoc (expected @ [ "type"; "limit"; "cursor" ]) json in
    constructor f (integer (field "limit" f)) (cursor (field "cursor" f))
  in
  match kind with
  | "graphInfo" ->
    ignore (exact_assoc [ "type" ] json);
    Graph_info
  | "getBlock" ->
    let f = exact_assoc [ "type"; "block" ] json in
    Get_block { block = uuid (field "block" f) }
  | "getPage" ->
    let f = exact_assoc [ "type"; "page" ] json in
    Get_page { page = page_selector_of_json (field "page" f) }
  | "getChildren" ->
    paged [ "parent" ] (fun f limit cursor ->
      Get_children { parent = uuid (field "parent" f); limit; cursor })
  | "getPageTree" ->
    paged [ "page"; "maximumDepth" ] (fun f limit cursor ->
      Get_page_tree
        { page = uuid (field "page" f)
        ; maximum_depth = integer (field "maximumDepth" f)
        ; limit
        ; cursor
        })
  | "getAncestors" ->
    let f = exact_assoc [ "type"; "block"; "limit" ] json in
    Get_ancestors { block = uuid (field "block" f); limit = integer (field "limit" f) }
  | "getSiblings" ->
    paged [ "block" ] (fun f limit cursor ->
      Get_siblings { block = uuid (field "block" f); limit; cursor })
  | "listPages" ->
    paged [ "kind" ] (fun f limit cursor ->
      List_pages { kind = page_kind_filter (string (field "kind" f)); limit; cursor })
  | "listTags" -> paged [] (fun _ limit cursor -> List_tags { limit; cursor })
  | "listProperties" ->
    paged [ "scope" ] (fun f limit cursor ->
      List_properties { scope = property_scope_of_json (field "scope" f); limit; cursor })
  | "listTasks" ->
    paged [ "filter" ] (fun f limit cursor ->
      List_tasks { filter = task_filter_of_json (field "filter" f); limit; cursor })
  | "getReferences" ->
    paged [ "target"; "direction" ] (fun f limit cursor ->
      Get_references
        { target = uuid (field "target" f)
        ; direction =
            (match string (field "direction" f) with
             | "referringTo" -> Referring_to
             | "referredFrom" -> Referred_from
             | _ -> decode_error "invalid reference direction")
        ; limit
        ; cursor
        })
  | _ -> decode_error "unknown read command"
;;

let request_to_yojson request =
  let command =
    match request.command with
    | Read read -> read_to_json read
    | Mutate mutation -> Mutation.to_yojson mutation
  in
  `Assoc
    [ "apiVersion", `Int request.api_version
    ; "requestId", uuid_json request.request_id
    ; "command", command
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
    let read_kinds =
      [ "graphInfo"
      ; "getBlock"
      ; "getPage"
      ; "getChildren"
      ; "getPageTree"
      ; "getAncestors"
      ; "getSiblings"
      ; "listPages"
      ; "listTags"
      ; "listProperties"
      ; "listTasks"
      ; "getReferences"
      ]
    in
    let command =
      if List.mem kind read_kinds
      then Read (read_of_json kind command_json)
      else (
        match Mutation.of_yojson command_json with
        | Ok mutation -> Mutate mutation
        | Error message -> decode_error message)
    in
    Ok { api_version = version; request_id = uuid (field "requestId" fields); command }
  with
  | Decode_error message -> Error (invalid_request message)
;;

let mutation_status_string = function
  | Mutation.Applied -> "applied"
  | No_change -> "noChange"
  | Already_applied -> "alreadyApplied"
;;

let mutation_status = function
  | "applied" -> Mutation.Applied
  | "noChange" -> No_change
  | "alreadyApplied" -> Already_applied
  | _ -> decode_error "invalid mutation status"
;;

let mutation_success_to_json (success : Mutation.success) =
  `Assoc
    [ "type", `String "mutation"
    ; "status", `String (mutation_status_string success.status)
    ; "basisBefore", int64_json success.basis_before
    ; "basisAfter", int64_json success.basis_after
    ; "changedUuids", uuids_json success.changed_uuids
    ; "changedUuidsTruncated", `Bool success.changed_uuids_truncated
    ]
;;

let mutation_success_of_json json =
  let fields =
    exact_assoc
      [ "type"
      ; "status"
      ; "basisBefore"
      ; "basisAfter"
      ; "changedUuids"
      ; "changedUuidsTruncated"
      ]
      json
  in
  if string (field "type" fields) <> "mutation"
  then decode_error "unsupported success type";
  Mutation.
    { status = mutation_status (string (field "status" fields))
    ; basis_before = int64 (field "basisBefore" fields)
    ; basis_after = int64 (field "basisAfter" fields)
    ; changed_uuids = uuid_list (field "changedUuids" fields)
    ; changed_uuids_truncated = boolean (field "changedUuidsTruncated" fields)
    }
;;

let property_schema_json = Mutation.property_schema_to_yojson

let property_summary_to_json (summary : property_summary) =
  `Assoc
    [ "ident", `String summary.ident
    ; "uuid", uuid_json summary.uuid
    ; "title", `String summary.title
    ; "schema", property_schema_json summary.schema
    ; "values", `List (List.map Mutation.property_value_to_yojson summary.values)
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
  | Remote_flag_true -> `Assoc [ "type", `String "remoteFlagTrue" ]
  | No_rtc_identity -> `Assoc [ "type", `String "noRtcIdentity" ]
  | Synced_graph_identity graph_id ->
    `Assoc
      [ "type", `String "syncedGraphIdentity"
      ; "graphId", `String (Uuid.to_string graph_id)
      ]
  | Lossless_codec -> `Assoc [ "type", `String "losslessCodec" ]
  | Ownership_verified -> `Assoc [ "type", `String "ownershipVerified" ]
;;

let graph_info_to_json (info : graph_info) =
  `Assoc
    [ "localGraphUuid", uuid_json info.local_graph_uuid
    ; "graphName", `String info.graph_name
    ; "graphDir", `String info.graph_dir
    ; "schema", `String (Printf.sprintf "%d.%d" info.schema.major info.schema.minor)
    ; "basis", int64_json info.basis
    ; "admissionFacts", `List (List.map admission_fact_to_json info.admission_facts)
    ]
;;

let page_result_to_json encode result =
  `Assoc
    [ "items", `List (List.map encode result.items)
    ; "continuation", option_json cursor_json result.continuation
    ]
;;

let page_summary_to_json (summary : page_summary) =
  `Assoc
    [ "uuid", uuid_json summary.uuid
    ; "name", `String summary.name
    ; "title", `String summary.title
    ; "kind", page_kind_to_json summary.kind
    ; "recycled", `Bool summary.recycled
    ]
;;

let tag_summary_to_json (summary : tag_summary) =
  `Assoc
    [ "uuid", uuid_json summary.uuid
    ; "title", `String summary.title
    ; "ident", option_json (fun value -> `String value) summary.ident
    ]
;;

let property_definition_to_json (definition : property_definition) =
  `Assoc
    [ "uuid", uuid_json definition.uuid
    ; "ident", `String definition.ident
    ; "title", `String definition.title
    ; "schema", Mutation.property_schema_to_yojson definition.schema
    ; "closedValues", uuids_json definition.closed_values
    ]
;;

let task_to_json (task : task) =
  `Assoc
    [ "block", block_to_json task.block
    ; "state", `String (task_state_string task.state)
    ; "scheduledDay", option_json (fun value -> `Int value) task.scheduled_day
    ; "deadlineDay", option_json (fun value -> `Int value) task.deadline_day
    ]
;;

let reference_kind_string = function
  | Block_reference -> "block"
  | Page_reference -> "page"
  | Tag_reference -> "tag"
  | Property_reference -> "property"
  | Scheduled_reference -> "scheduled"
  | Deadline_reference -> "deadline"
  | Alias_reference -> "alias"
;;

let reference_to_json (reference : reference) =
  `Assoc
    [ "source", uuid_json reference.source
    ; "target", uuid_json reference.target
    ; "kind", `String (reference_kind_string reference.kind)
    ]
;;

let success_to_json = function
  | Mutation_result success -> mutation_success_to_json success
  | Graph_info_result info ->
    `Assoc [ "type", `String "graphInfo"; "graph", graph_info_to_json info ]
  | Block_result block -> `Assoc [ "type", `String "block"; "block", block_to_json block ]
  | Page_result page -> `Assoc [ "type", `String "page"; "page", page_to_json page ]
  | Children_result result ->
    `Assoc
      [ "type", `String "children"; "page", page_result_to_json block_to_json result ]
  | Page_tree_result result ->
    `Assoc
      [ "type", `String "pageTree"
      ; ( "page"
        , page_result_to_json
            (fun item ->
               `Assoc [ "block", block_to_json item.block; "depth", `Int item.depth ])
            result )
      ]
  | Ancestors_result blocks ->
    `Assoc [ "type", `String "ancestors"; "items", `List (List.map block_to_json blocks) ]
  | Siblings_result result ->
    `Assoc
      [ "type", `String "siblings"
      ; "siblings", page_result_to_json block_to_json result.siblings
      ; "currentIndex", `Int result.current_index
      ]
  | Pages_result result ->
    `Assoc
      [ "type", `String "pages"; "page", page_result_to_json page_summary_to_json result ]
  | Tags_result result ->
    `Assoc
      [ "type", `String "tags"; "page", page_result_to_json tag_summary_to_json result ]
  | Properties_result result ->
    `Assoc
      [ "type", `String "properties"
      ; "page", page_result_to_json property_definition_to_json result
      ]
  | Tasks_result result ->
    `Assoc [ "type", `String "tasks"; "page", page_result_to_json task_to_json result ]
  | References_result result ->
    `Assoc
      [ "type", `String "references"
      ; "page", page_result_to_json reference_to_json result
      ]
;;

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
      ; ( "phase"
        , `String
            (match phase with
             | Open -> "open"
             | Execute -> "execute") )
      ; "basis", option_json int64_json basis
      ; "error", Error.to_yojson error
      ]
;;

let response_of_yojson json =
  try
    let raw =
      match json with
      | `Assoc fields -> fields
      | _ -> decode_error "invalid response"
    in
    match string (field "type" raw) with
    | "succeeded" ->
      let fields = exact_assoc [ "type"; "requestId"; "basis"; "success" ] json in
      let success_json = field "success" fields in
      let success_fields =
        match success_json with
        | `Assoc values -> values
        | _ -> decode_error "invalid success"
      in
      let success =
        match string (field "type" success_fields) with
        | "mutation" -> Mutation_result (mutation_success_of_json success_json)
        | _ -> decode_error "unsupported success type"
      in
      Ok
        (Succeeded
           { request_id = uuid (field "requestId" fields)
           ; basis = int64 (field "basis" fields)
           ; success
           })
    | "failed" ->
      let fields = exact_assoc [ "type"; "requestId"; "phase"; "basis"; "error" ] json in
      let error =
        match Error.of_yojson (field "error" fields) with
        | Ok error -> error
        | Error message -> decode_error message
      in
      Ok
        (Failed
           { request_id = uuid (field "requestId" fields)
           ; phase =
               (match string (field "phase" fields) with
                | "open" -> Open
                | "execute" -> Execute
                | _ -> decode_error "invalid failure phase")
           ; basis =
               (match field "basis" fields with
                | `Null -> None
                | value -> Some (int64 value))
           ; error
           })
    | _ -> decode_error "invalid response type"
  with
  | Decode_error message -> Error message
;;

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
;;

let push_of_yojson json =
  try
    let fields =
      exact_assoc
        [ "type"
        ; "basis"
        ; "changedUuids"
        ; "changedUuidsTruncated"
        ; "invalidateGraphInfo"
        ; "invalidatePages"
        ; "invalidateTags"
        ; "invalidateProperties"
        ; "invalidateTasks"
        ; "invalidateReferences"
        ]
        json
    in
    if string (field "type" fields) <> "graphInvalidated"
    then decode_error "invalid push type";
    Ok
      (Graph_invalidated
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
  with
  | Decode_error message -> Error message
;;

let encoded_response_bytes response =
  String.length (Yojson.Safe.to_string (response_to_yojson response))
;;
