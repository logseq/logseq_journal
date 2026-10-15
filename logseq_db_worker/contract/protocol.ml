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
  | V2_get_asset_descriptors of { assets : Uuid.t list }
  | V2_list_assets of
      { recursive : bool
      ; roots : Uuid.t list
      ; limit : int
      ; cursor : Cursor.t option
      }
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
  (* Outline content requires parent/page/order; page targets use V2_get_page. *)
  | V2_get_outline_block of
      { block : block_uuid
      ; revision : string option
      }
  | V2_get_outline_block_summary of
      { block : block_uuid
      ; limit : int
      ; cursor : Cursor.t option
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
  | V2_set_asset_reference of
      { mutation_id : Uuid.t
      ; block : block_uuid
      ; previous : Uuid.t option
      ; asset : Uuid.t
      ; preconditions : v2_preconditions
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
[@@deriving yojson]

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
  ; tag_titles : string list
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
      ; journal_title_format : string option
      ; limits : v2_capability_limits
      ; generation : string
      ; projection_revision : string
      }
  | V2_favorites_outcome of v2_favorites_result
  | V2_assets_outcome of
      { generation : string
      ; projection_revision : string
      ; items : Logseq_db_types.Asset_descriptor.t list
      ; next_cursor : Cursor.t option
      }
  | V2_admission_outcome of v2_admission_inspection
  | V2_journals_outcome of
      { items : v2_journal_item list
      ; next_cursor : Cursor.t option
      }
  | V2_page_outcome of v2_page_lookup
  | V2_block_outcome of v2_block_lookup
  | V2_block_summary_outcome of
      { lookup : v2_block_lookup
      ; page : v2_page_lookup option
      ; items : v2_child_member list
      ; next_cursor : Cursor.t option
      ; scope_revision : string
      ; generation : string
      ; projection_revision : string
      }
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
[@@deriving yojson]

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
[@@deriving yojson]

let failed ~request_id error =
  V2_response
    { api_version
    ; request_id
    ; outcome =
        V2_failed
          { code = Error.code_string (Error.code error); message = Error.message error }
    }
;;

let invalid_request message =
  match Error.create ~code:Invalid_request ~message ~details:[] with
  | Ok error -> error
  | Error internal_error -> failwith ("invalid internal request error: " ^ internal_error)
;;

let valid_title title = String.length title <= maximum_title_bytes
let valid_limit limit = limit >= 1 && limit <= maximum_page_size

let valid_tree roots =
  let rec visit nodes = function
    | [] -> true
    | (depth, tree) :: remaining ->
      depth <= maximum_tree_depth
      && nodes < maximum_tree_nodes
      && valid_title tree.title
      && visit
           (nodes + 1)
           (List.fold_left
              (fun remaining child -> (depth + 1, child) :: remaining)
              remaining
              tree.children)
  in
  List.length roots <= maximum_roots && visit 0 (List.map (fun tree -> 0, tree) roots)
;;

let validate_command = function
  | V2_get_asset_descriptors { assets } -> List.length assets <= maximum_page_size
  | V2_list_assets { roots; limit; _ } ->
    List.length roots <= maximum_filter_values && valid_limit limit
  | V2_list_favorites { limit; _ }
  | V2_list_journals { limit; _ }
  | V2_get_outline_block_summary { limit; _ }
  | V2_get_children { limit; _ }
  | V2_pull_changes { limit; _ } -> valid_limit limit
  | V2_get_page_tree { maximum_depth; limit; _ } ->
    maximum_depth >= 0 && maximum_depth <= maximum_tree_depth && valid_limit limit
  | V2_save_block { title; _ } | V2_create_journal_page { title; _ } -> valid_title title
  | V2_insert_blocks { roots; _ } -> valid_tree roots
  | V2_graph_info
  | V2_inspect_admission
  | V2_get_page _
  | V2_get_outline_block _
  | V2_set_asset_reference _
  | V2_delete_blocks _
  | V2_set_task_status _
  | V2_clear_task_status _
  | V2_ack_changes _ -> true
;;

let request_of_yojson json =
  let decoded =
    Logseq_db_types.Json_codec.decode
      ~maximum_bytes:maximum_request_bytes
      request_of_yojson
      json
  in
  Result.bind decoded (fun (request : request) ->
    if request.api_version <> api_version
    then Error "unsupported api_version"
    else if not (validate_command request.command)
    then Error "request exceeds domain bounds"
    else Ok request)
  |> Result.map_error invalid_request
;;

let valid_page (page : page) = valid_title page.title
let valid_record value = valid_title value.block.title

let valid_page_lookup = function
  | V2_present_page { page; _ } -> valid_page page
  | V2_missing_page _ -> true
;;

let valid_block_lookup = function
  | V2_present_block { value; _ } -> valid_record value
  | V2_missing_block _ -> true
;;

let validate_outcome = function
  | V2_favorites_outcome { items; _ } ->
    List.length items <= maximum_page_size
    && List.for_all
         (fun item ->
            match item.target with
            | V2_favorite_page { title; _ } | V2_favorite_block { title; _ } ->
              valid_title title)
         items
  | V2_assets_outcome { items; _ } -> List.length items <= maximum_page_size
  | V2_journals_outcome { items; _ } ->
    List.for_all (fun (item : v2_journal_item) -> valid_page item.page) items
  | V2_page_outcome lookup -> valid_page_lookup lookup
  | V2_block_outcome lookup -> valid_block_lookup lookup
  | V2_block_summary_outcome { lookup; page; items; _ } ->
    valid_block_lookup lookup
    && Option.fold ~none:true ~some:valid_page_lookup page
    && List.for_all (fun (item : v2_child_member) -> valid_record item.value) items
  | V2_children_outcome { items; _ } ->
    List.for_all (fun (item : v2_child_member) -> valid_record item.value) items
  | V2_page_tree_outcome { items; _ } ->
    List.for_all (fun (item : v2_tree_member) -> valid_record item.value) items
  | V2_graph_info_outcome _
  | V2_admission_outcome _
  | V2_mutation_committed _
  | V2_changes _
  | V2_changes_acknowledged _
  | V2_failed _
  | V2_resync_required _ -> true
;;

let response_of_yojson json =
  Result.bind
    (Logseq_db_types.Json_codec.decode
       ~maximum_bytes:maximum_response_bytes
       response_of_yojson
       json)
    (fun (V2_response { api_version = version; outcome; _ } as response) ->
       if version <> api_version
       then Error "unsupported api_version"
       else if not (validate_outcome outcome)
       then Error "response exceeds domain bounds"
       else Ok response)
;;

let push_of_yojson json =
  Result.bind
    (Logseq_db_types.Json_codec.decode
       ~maximum_bytes:maximum_push_bytes
       push_of_yojson
       json)
    (fun push ->
       let version =
         match push with
         | V2_changes_available { api_version; _ }
         | V2_resync_required_push { api_version; _ } -> api_version
       in
       if version <> api_version then Error "unsupported api_version" else Ok push)
;;

let encoded_response_bytes response =
  String.length (Yojson.Safe.to_string (response_to_yojson response))
;;
