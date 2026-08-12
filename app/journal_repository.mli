module Error : sig
  type t

  type oversized_source =
    { block_id : string
    ; measured_bytes : int
    }

  val to_string : t -> string
  val oversized_source : t -> oversized_source option
end

type page =
  { id : string
  ; day : int
  ; title : string
  }

type block = Journal_model.t

type capture =
  { mutation_id : string
  ; block_id : string
  ; sibling_order : string
  ; source : string
  ; task_state : Journal_model.task_state
  ; creation_time : Journal_time.t
  }

type capture_plan =
  | Already_applied of block
  | Apply of Datascript.tx_op list

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

type create_child_plan =
  | Child_already_applied of block
  | Create_child of Datascript.tx_op list

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

type update_plan =
  | Update_already_applied of block
  | Update_conflict of block
  | Update_block of Datascript.tx_op list

type delete_subtree =
  { mutation_id : string
  ; block_id : string
  ; expected_revision : int
  }

type delete_subtree_plan =
  | Delete_already_applied
  | Delete_conflict of block
  | Delete_subtree of
      { transaction : Datascript.tx_op list
      ; deleted_count : int
      ; parent_block_id : string option
      }

type day_feed =
  { page : page
  ; blocks : block list
  ; has_more_blocks : bool
  }

type feed =
  { days : day_feed list
  ; slot_count : int
  ; has_more_days : bool
  }

type block_cursor =
  { after_sibling_order : string
  ; after_block_id : string
  }

type block_page =
  { blocks : block list
  ; continuation : block_cursor option
  }

type detail =
  { root : block
  ; children : block_page
  }

val initialize_store_transaction : unit -> Datascript.tx_op list
val validate_store : Datascript.db -> (unit, Error.t) result
val prepare_capture : Datascript.db -> capture -> (capture_plan, Error.t) result

val prepare_create_child
  :  Datascript.db
  -> create_child
  -> (create_child_plan, Error.t) result

val prepare_update_source
  :  Datascript.db
  -> update_source
  -> (update_plan, Error.t) result

val prepare_set_task_state
  :  Datascript.db
  -> set_task_state
  -> (update_plan, Error.t) result

val prepare_delete_subtree
  :  Datascript.db
  -> delete_subtree
  -> (delete_subtree_plan, Error.t) result

val find_block : Datascript.db -> id:string -> (block option, Error.t) result

val top_level_blocks
  :  Datascript.db
  -> day:int
  -> limit:int
  -> (block list, Error.t) result

val load_children
  :  Datascript.db
  -> parent_id:string
  -> after:block_cursor option
  -> limit:int
  -> (block_page, Error.t) result

val load_day_blocks
  :  Datascript.db
  -> day:int
  -> after:block_cursor option
  -> limit:int
  -> (block_page, Error.t) result

val load_detail
  :  Datascript.db
  -> block_id:string
  -> after:block_cursor option
  -> limit:int
  -> (detail, Error.t) result

val recent_pages
  :  Datascript.db
  -> before_day:int option
  -> limit:int
  -> (page list * bool, Error.t) result

val load_feed
  :  Datascript.db
  -> before_day:int option
  -> day_limit:int
  -> blocks_per_day:int
  -> slot_limit:int
  -> (feed, Error.t) result
