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

and mutation_context =
  { mutation_id : Uuid.t
  ; expected_basis : int64
  }

and command =
  | Read of read_command
  | Mutate of mutation
  | Sync_receive of
      { transport : sync_transport
      ; payload : string
      }

and sync_transport =
  | Websocket
  | Http_pull

and read_command =
  | Graph_info
  | Sync_status
  | Sync_pending
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

type sync_state =
  | Sync_active
  | Sync_paused_state

type sync_activity =
  | Pull_applied
  | Pull_duplicate
  | Pull_required
  | Sync_paused
  | Sync_submission_blocked

type sync_status =
  { state : sync_state
  ; applied_server_t : int
  ; checksum : string
  ; last_error : string option
  }

type sync_pending =
  { payload : string option
  ; count : int
  ; blocked_error : string option
  }

type sync_success =
  { activity : sync_activity
  ; state : sync_state
  ; applied_server_t : int
  ; checksum : string
  ; last_error : string option
  ; mutation : mutation_success option
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
  | Sync_status_result of sync_status
  | Sync_pending_result of sync_pending
  | Sync_result of sync_success

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

val failed
  :  request_id:Uuid.t
  -> phase:failure_phase
  -> basis:int64 option
  -> Error.t
  -> response

val mutation_context : mutation -> mutation_context
val request_to_yojson : request -> Yojson.Safe.t
val request_of_yojson : Yojson.Safe.t -> (request, Error.t) result
val response_to_yojson : response -> Yojson.Safe.t
val response_of_yojson : Yojson.Safe.t -> (response, string) result
val push_to_yojson : push -> Yojson.Safe.t
val push_of_yojson : Yojson.Safe.t -> (push, string) result
val encoded_response_bytes : response -> int
