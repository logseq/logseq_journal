module Ui = Bonsai_flutter_ui

type request =
  | Feed of { before_day : int option }
  | Day of
      { day : int
      ; after : Journal_repository.block_cursor option
      }
  | Children of
      { parent_id : string
      ; after : Journal_repository.block_cursor option
      }

type slot =
  | Day_heading of Journal_repository.page
  | Block of
      { block : Journal_model.t
      ; depth : int
      }
  | Day_continuation of
      { day : int
      ; after : Journal_repository.block_cursor option
      }
  | Children_continuation of
      { parent_id : string
      ; after : Journal_repository.block_cursor option
      }
  | Feed_continuation of { before_day : int }
  | Bottom_clearance

type anchor_decision =
  | Preserve_visible_slot
  | Reset_to_top

type extent_strategy = Known_profile_extents
type t

type staged_delete =
  { block : Journal_model.t
  ; before : t
  }

type window =
  { total_count : int
  ; first_index : int
  ; slots : slot list
  }

type synthetic_window =
  { first_index : int
  ; count : int
  }

type extent_geometry =
  { default_extent : float
  ; overrides : Ui.Native_widget.Sparse_extent_list.extent_override list
  ; final_clearance_extent : float
  }

val maximum_slots : int
val maximum_supplied_rows : int
val overscan : int
val extent_strategy : extent_strategy
val renderer_event_surface : [ `Visible_range ] list
val empty : today:int -> t
val begin_request : t -> generation:int64 -> request -> t
val apply_feed : t -> generation:int64 -> Journal_repository.feed -> t
val apply_block_page : t -> generation:int64 -> Journal_repository.block_page -> t
val apply_detail : t -> generation:int64 -> Journal_repository.detail -> t
val next_request : t -> request option

val request_for_visible_range
  :  t
  -> first_index:int
  -> last_exclusive:int
  -> request option

val pending_request : t -> (int64 * request) option
val expand : t -> parent_id:string -> t
val collapse : t -> parent_id:string -> t
val replace_block : t -> Journal_model.t -> t
val prepend_block : t -> Journal_model.t -> t
val stage_delete : t -> block_id:string -> (t * staged_delete) option
val undo_delete : staged_delete -> t
val return_from_detail : t -> block_id:string -> t
val observe_visible_range : t -> first_index:int -> last_exclusive:int -> t
val current_window : t -> window
val retained_slots : t -> slot list
val retained_slot_count : t -> int
val first_retained_index : t -> int
val total_count : t -> int
val anchor_decision : t -> anchor_decision
val focus_restore_block_id : t -> string option
val is_expanded : t -> block_id:string -> bool
val slot_key : slot -> string

val extent_geometry
  :  t
  -> profile:Journal_visual_tokens.row_profile
  -> safe_bottom:float
  -> extent_geometry

val synthetic_window
  :  total_count:int
  -> first_visible:int
  -> last_exclusive:int
  -> synthetic_window
