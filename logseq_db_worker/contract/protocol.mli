open Graph_types

val api_version : int
val maximum_request_bytes : int
val maximum_response_bytes : int
val maximum_push_bytes : int
val default_page_size : int
val maximum_page_size : int
val maximum_tree_nodes : int
val maximum_tree_depth : int
val maximum_title_bytes : int
val maximum_roots : int
val maximum_changed_uuids : int
val maximum_property_values : int
val maximum_filter_values : int

type request =
  { api_version : int
  ; request_id : Uuid.t
  ; command : command
  }

and command =
  | V2_graph_info
  | V2_inspect_admission
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

and v2_scope =
  | V2_children_scope of Uuid.t
  | V2_page_tree_scope of
      { page : page_uuid
      ; maximum_depth : int
      }

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

and v2_revision_scope =
  | V2_children_revision of Uuid.t
  | V2_page_tree_revision of
      { page : page_uuid
      ; maximum_depth : int
      }

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
      ; revision_scope : v2_revision_scope
      ; scope_revision : string
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

val failed : request_id:Uuid.t -> Error.t -> response
val request_to_yojson : request -> Yojson.Safe.t
val request_of_yojson : Yojson.Safe.t -> (request, Error.t) result
val response_to_yojson : response -> Yojson.Safe.t
val response_of_yojson : Yojson.Safe.t -> (response, string) result
val push_to_yojson : push -> Yojson.Safe.t
val push_of_yojson : Yojson.Safe.t -> (push, string) result
val encoded_response_bytes : response -> int
