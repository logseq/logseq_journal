open Graph_types

val api_version : int

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
  | V2_list_task_statuses of
      { limit : int
      ; cursor : Cursor.t option
      }
  | V2_get_task_status_definitions of { statuses : Uuid.t list }
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
  (* Canonical target, owning page and a bounded direct-child slice share one
     Database snapshot. Limit is 1..maximum_page_size; use default_page_size
     for normal metadata. The opaque child cursor is projection-version-bound. *)
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
      ; preconditions : Worker_pure_data.preconditions
      }
  | V2_save_block of
      { mutation_id : Uuid.t
      ; block : block_uuid
      ; title : string
      ; preconditions : Worker_pure_data.preconditions
      }
  | V2_insert_blocks of
      { mutation_id : Uuid.t
      ; parent : Uuid.t
      ; roots : Worker_pure_data.block_tree list
      ; preconditions : Worker_pure_data.preconditions
      }
  (* Atomic Append executes only through the registered durable intent bridge;
     unregistered raw graph requests cannot bypass persistence/receipt ownership. *)
  | V2_append_journal of
      { mutation_id : Uuid.t
      ; page : page_uuid
      ; journal_day : int
      ; root : Worker_pure_data.append_node
      }
  | V2_delete_blocks of
      { mutation_id : Uuid.t
      ; root : block_uuid
      ; preconditions : Worker_pure_data.preconditions
      }
  | V2_create_journal_page of
      { mutation_id : Uuid.t
      ; page : page_uuid
      ; journal_day : int
      ; title : string
      ; preconditions : Worker_pure_data.preconditions
      }
  | V2_set_task_status of
      { mutation_id : Uuid.t
      ; block : block_uuid
      ; status : Worker_pure_data.task_status
      ; preconditions : Worker_pure_data.preconditions
      }
  | V2_clear_task_status of
      { mutation_id : Uuid.t
      ; block : block_uuid
      ; preconditions : Worker_pure_data.preconditions
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

type response =
  | V2_response of
      { api_version : int
      ; request_id : Uuid.t
      ; outcome : v2_outcome
      }

and v2_favorites_result =
  { favorites_page : page_uuid option
  ; generation : string
  ; projection_revision : string
  ; items : Worker_pure_data.favorite_item list
  ; next_cursor : Cursor.t option
  }

and v2_outcome =
  | V2_graph_info_outcome of
      { graph_uuid : Uuid.t
      ; graph_name : string
      ; schema : schema_version
      ; admission_facts : admission_fact list
      ; journal_title_format : string option
      ; limits : Worker_pure_data.capability_limits
      ; generation : string
      ; projection_revision : string
      }
  | V2_task_statuses_outcome of
      { property_uuid : Uuid.t option
      ; default_status : Uuid.t option
      ; items : task_status_definition list
      ; next_cursor : Cursor.t option
      }
  | V2_task_status_definitions_outcome of task_status_definition option list
  | V2_favorites_outcome of v2_favorites_result
  | V2_assets_outcome of
      { generation : string
      ; projection_revision : string
      ; items : Logseq_db_types.Asset_descriptor.t list
      ; next_cursor : Cursor.t option
      }
  | V2_admission_outcome of Worker_pure_data.admission_inspection
  | V2_journals_outcome of
      { items : Worker_pure_data.journal_item list
      ; next_cursor : Cursor.t option
      }
  | V2_page_outcome of Worker_pure_data.page_lookup
  | V2_block_outcome of Worker_pure_data.block_lookup
  (* All fields belong to generation/projection_revision. Child count becomes
     exact only after consuming next_cursor; page=None denotes a missing target. *)
  | V2_block_summary_outcome of
      { lookup : Worker_pure_data.block_lookup
      ; page : Worker_pure_data.page_lookup option
      ; items : Worker_pure_data.child_member list
      ; next_cursor : Cursor.t option
      ; scope_revision : string
      ; generation : string
      ; projection_revision : string
      }
  | V2_children_outcome of
      { parent : Uuid.t
      ; revision_scope : Worker_pure_data.revision_scope
      ; scope_revision : string
      ; items : Worker_pure_data.child_member list
      ; next_cursor : Cursor.t option
      }
  | V2_page_tree_outcome of
      { page : page_uuid
      ; maximum_depth : int
      ; items : Worker_pure_data.tree_member list
      ; next_cursor : Cursor.t option
      }
  | V2_mutation_committed of
      { mutation_id : Uuid.t
      ; status : Worker_pure_data.local_status
      ; generation : string
      ; before_projection_revision : string
      ; after_projection_revision : string
      }
  | V2_changes of
      { generation : string
      ; from_exclusive : string option
      ; through : string
      ; windows : Worker_pure_data.change_window list
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

(** Ordinary snapshot reads only; changefeed pulls/ACKs and mutations are effects
    requiring their existing ownership path. *)
val is_snapshot_read : command -> bool

(** Fresh DB queries supported by atomic registered sampling. A continuation or
    revision-pinned query cannot stand in for a fresh observation; changefeed ACK
    and admission inspection have separate state owners. *)
val is_observable_read : command -> bool

(** Pure bounded-page planning for one pinned snapshot. Only ordinary paged reads
    can shrink; query family, cursor, revision and filters remain exact. Returning
    None requires an explicit oversized-singleton/error result, never truncation. *)
val smaller_read_page : command -> command option
