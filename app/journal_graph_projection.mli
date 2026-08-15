type page =
  { id : string
  ; day : int
  ; title : string
  }

type block = Journal_model.t

type time_context =
  { time_zone_id : string
  ; utc_offset_seconds : int
  }

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
  ; creation_time : Journal_time.t
  ; children : capture_child list
  }

type create_child =
  { mutation_id : string
  ; block_id : string
  ; parent_block_id : string
  ; expected_parent_revision : int
  ; sibling_order : string
  ; source : string
  ; task_state : Journal_model.task_state
  ; creation_time : Journal_time.t
  }

type update_source =
  { mutation_id : string
  ; block_id : string
  ; expected_revision : int
  ; source : string
  }

type set_task_state =
  { mutation_id : string
  ; block_id : string
  ; expected_revision : int
  ; task_state : Journal_model.task_state
  }

type delete_subtree =
  { mutation_id : string
  ; block_id : string
  ; expected_revision : int
  }

type block_cursor =
  { after_sibling_order : string
  ; after_block_id : string
  ; protocol_cursor : Logseq_db_worker.Graph_types.Cursor.t option
  }

type child_summary =
  { block_id : string
  ; source : string
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
  ; has_more_days : bool
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

val page_of_summary : Logseq_db_worker.Graph_types.page_summary -> page option

val block
  :  page:page
  -> basis:int64
  -> child_count:int
  -> time_context:time_context
  -> Logseq_db_worker.Graph_types.block
  -> (block, string) result

val timeline_entry_page
  :  page:page
  -> basis:int64
  -> time_context:time_context
  -> Logseq_db_worker.Graph_types.block_tree_item
       Logseq_db_worker.Graph_types.page_result
  -> (timeline_entry_page, string) result

val detail
  :  page:page
  -> basis:int64
  -> time_context:time_context
  -> root:Logseq_db_worker.Graph_types.block
  -> Logseq_db_worker.Graph_types.block Logseq_db_worker.Graph_types.page_result
  -> (detail, string) result
