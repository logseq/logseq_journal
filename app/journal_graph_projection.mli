type favorite_target =
  | Page of string
  | Block of string

type favorite =
  { membership_id : string
  ; target : favorite_target
  ; title : string
  ; task_state : Journal_model.task_state
  }

type page =
  { id : string
  ; day : int
  ; title : string
  }

type block = Journal_model.t
type time_context = { localtime : float -> Unix.tm }

type capture_child =
  { mutation_id : string
  ; block_id : string
  ; sibling_order : string
  ; source : string
  ; task_state : Journal_model.task_state
  ; creation_time : Journal_time.t
  }

type capture =
  { mutation_id : string
  ; block_id : string
  ; sibling_order : string
  ; source : string
  ; task_state : Journal_model.task_state
  ; status_confirmation : bool
  ; status_intent_revision : int64
    (** Capture-owned choice generation; stable for retries of one selection. *)
  ; creation_time : Journal_time.t
  ; children : capture_child list
  }

type create_child =
  { mutation_id : string
  ; calendar_generation : int64
  ; block_id : string
  ; parent_block_id : string
  ; expected_parent_revision : string
  ; sibling_order : string
  ; source : string
  ; task_state : Journal_model.task_state
  ; status_confirmation : bool
  ; status_intent_revision : int64
  ; creation_time : Journal_time.t
  }

type set_task_state =
  { mutation_id : string
  ; block_id : string
  ; expected_revision : string
  ; task_state : Journal_model.task_state
  }

type delete_subtree =
  { mutation_id : string
  ; block_id : string
  ; expected_revision : string
  }

(** App-local traversal, independent of displayed date order. [before_day = None]
    resumes at the latest date; [skipped_day] is the already-prioritized day. *)
type feed_cursor =
  { before_day : int option
  ; skipped_day : int option
  }

type child_cursor =
  { after :
      Logseq_db_worker.Protocol.v2_child_member
        Journal_worker_coordination.Worker_api.continuation
  ; maximum_items : int
  }

(** A bounded remainder of one read packet plus its sealed server continuation.
    The final server page can still retain items. Session/owner and page epoch
    must be revalidated before replay; this value owns no Worker resource. *)
type root_cursor =
  { session : Journal_worker_coordination.Worker_api.session
  ; budget : Journal_worker_coordination.Worker_api.read_budget
  ; maximum_items : int
  ; page : Logseq_db_types.Graph_types.Uuid.t
  ; epoch : int64
  ; after :
      Logseq_db_worker.Protocol.v2_tree_member
        Journal_worker_coordination.Worker_api.continuation
        option
  ; remaining : Logseq_db_worker.Protocol.v2_tree_member Rrbvec.t
  }

type block_continuation =
  | Root_tree_cursor of root_cursor
  | Child_cursor of child_cursor

type block_cursor =
  { after_sibling_order : string
  ; after_block_id : string
  ; protocol_cursor : block_continuation option
  }

type child_summary =
  { block_id : string
  ; source : string
  ; asset_file_type : string option
  }

type timeline_entry =
  { block : block
  ; child_summaries : child_summary list
  }

type day_feed =
  { page : page
  ; entries : timeline_entry list
  ; has_more_entries : bool
  ; continuation : block_cursor option
  }

type feed =
  { days : day_feed list
  ; slot_count : int
  ; continuation : feed_cursor option
  ; prioritized_day : int option
    (** The initial scan has covered this day, even if it has no entries. *)
  }

type block_page =
  { blocks : block list
  ; continuation : block_cursor option
  }

type timeline_entry_page =
  { entries : timeline_entry list
  ; continuation : block_cursor option
  }

type detail =
  { root : block
  ; children : block_page
  }

type block_member =
  { block : Logseq_db_types.Graph_types.block
  ; revision : string
  }

type children_page =
  { items : block_member list
  ; continuation : child_cursor option
  }

type tree_member =
  { block : Logseq_db_types.Graph_types.block
  ; revision : string
  ; depth : int
  }

val page_of_summary : Logseq_db_types.Graph_types.page_summary -> page option

val block
  :  page:page
  -> revision:string
  -> child_count:int
  -> time_context:time_context
  -> Logseq_db_types.Graph_types.block
  -> (block, string) result

val block_on_page
  :  page:Logseq_db_types.Graph_types.page
  -> revision:string
  -> child_count:int
  -> time_context:time_context
  -> Logseq_db_types.Graph_types.block
  -> (block, string) result

val timeline_entry_page
  :  ?root_continuation:root_cursor
  -> ?tag_titles:(Logseq_db_types.Graph_types.Uuid.t -> string list)
  -> page:page
  -> time_context:time_context
  -> tree_member Logseq_db_types.Graph_types.page_result
  -> (timeline_entry_page, string) result

val detail
  :  page:page
  -> time_context:time_context
  -> root:block_member
  -> children_page
  -> (detail, string) result

val detail_on_page
  :  page:Logseq_db_types.Graph_types.page
  -> time_context:time_context
  -> root:block_member
  -> children_page
  -> (detail, string) result

val favorite : Logseq_db_worker.Protocol.v2_favorite_item -> favorite

(** Canonical target projection retains the full raw child count while only
    materializing the existing bounded preview. *)
val timeline_target_entry
  : page:page -> time_context:time_context -> root:tree_member
  -> tag_titles:(Logseq_db_types.Graph_types.Uuid.t -> string list)
  -> Logseq_db_worker.Protocol.v2_child_member Rrbvec.t
  -> (timeline_entry option,string) result
