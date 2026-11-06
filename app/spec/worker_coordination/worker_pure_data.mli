(** Pure query values shared by the coordinator and Worker. Constructor tags
    preserve the canonical JSON identity of persisted mutation payloads. *)
open Logseq_db_types.Graph_types

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

type precondition_scope = V2_children_scope of Uuid.t

and task_status = Uuid.t

and preconditions =
  { blocks : (block_uuid * string) list
  ; pages : (page_uuid * string) list
  ; scopes : (precondition_scope * string) list
  }

and block_tree =
  { uuid : block_uuid
  ; title : string
  ; children : block_tree list
  }

and append_node =
  { block_id : block_uuid
  ; title : string
  ; task_status : Uuid.t option
  ; children : append_node Rrbvec.t
  }

and change_window =
  { id : string
  ; predecessor : string
  ; successor : string
  ; block_uuids : block_uuid list
  ; page_uuids : page_uuid list
  ; structure_interests : structure_interest list
  }

and structure_interest =
  | V2_children_interest of Uuid.t
  | V2_page_tree_interest of page_uuid
  | V2_journal_index_interest

and capability_limits =
  { response_budget_bytes : int
  ; outbox_max_records : int
  ; outbox_max_bytes : int
  ; change_max_items : int
  ; change_max_bytes : int
  ; dispatcher_capacity : int
  ; wire_batch_max_bytes : int
  }

and page_lookup =
  | V2_present_page of
      { page : page
      ; revision : string
      }
  | V2_missing_page of
      { uuid : page_uuid
      ; revision : string
      }

and block_record =
  { block : block
  ; task_status : task_status option
  ; rendered_page_title : string
  ; tag_titles : string list
  }

and block_lookup =
  | V2_present_block of
      { value : block_record
      ; revision : string
      }
  | V2_missing_block of
      { uuid : block_uuid
      ; revision : string
      }

and journal_item =
  { page : page
  ; journal_day : int
  ; revision : string
  }

and favorite_target =
  | V2_favorite_page of
      { uuid : page_uuid
      ; title : string
      ; revision : string
      }
  | V2_favorite_block of
      { uuid : block_uuid
      ; title : string
      ; task_status : task_status option
      ; revision : string
      }

and favorite_item =
  { membership_uuid : block_uuid
  ; membership_order : string
  ; membership_revision : string
  ; target : favorite_target
  }

and child_member =
  { value : block_record
  ; revision : string
  }

and tree_member =
  { value : block_record
  ; revision : string
  ; depth : int
  ; parent : Uuid.t
  }

and revision_scope = V2_children_revision of Uuid.t

and local_status =
  | V2_applied
  | V2_no_change
  | V2_already_applied

and admission_inspection =
  { active_records : int
  ; active_bytes : int
  ; protected_wire_bytes : int
  ; retained_origin_evidence_bytes : int
  ; maximum_records : int
  ; maximum_bytes : int
  }
[@@deriving yojson]

type changefeed_signal =
  | Changes_available of { generation : string; through : string }
  | Resync_required of { generation : string; reason : string }

val valid_append_node : append_node -> bool
