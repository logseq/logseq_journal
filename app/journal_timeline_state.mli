type request =
  | Feed of { before_day : int option }
  | Day of
      { day : int
      ; after : Journal_graph_projection.block_cursor option
      }

type slot =
  | Day_heading of Journal_graph_projection.page
  | Top_level of Journal_graph_projection.timeline_entry
  | Day_continuation of
      { day : int
      ; after : Journal_graph_projection.block_cursor option
      }
  | Feed_continuation of { before_day : int }

type t

type staged_delete =
  { block : Journal_model.t
  ; before : t
  }

val empty : today:int -> t
val reset : t -> today:int -> t
val begin_request : t -> generation:int64 -> request -> t
val apply_feed : t -> generation:int64 -> Journal_graph_projection.feed -> t

val apply_timeline_entry_page
  :  t
  -> generation:int64
  -> Journal_graph_projection.timeline_entry_page
  -> t

val next_request : t -> request option
val pending_request : t -> (int64 * request) option
val replace_block : t -> Journal_model.t -> t
val remove_block : t -> block_id:string -> t
val replace_timeline_entry : t -> Journal_graph_projection.timeline_entry -> t

val replace_timeline_entry_page
  :  t
  -> page:Journal_graph_projection.page
  -> Journal_graph_projection.timeline_entry_page
  -> t

val prepend_timeline_entry : t -> Journal_graph_projection.timeline_entry -> t
val stage_delete : t -> block_id:string -> (t * staged_delete) option
val undo_delete : t -> staged_delete -> t
val observe_visible_range : t -> first_index:int -> last_exclusive:int -> t

(** Read an index relative to the first retained slot. Out-of-range indices return [None]. *)
val retained_slot : t -> int -> slot option

(** Fold retained slots from first to last without materializing an intermediate collection. *)
val fold_slots : ('a -> slot -> 'a) -> 'a -> t -> 'a

(** Includes a hidden placeholder while its day remains known. *)
val find_block : t -> block_id:string -> Journal_model.t option

val retained_slot_count : t -> int
val first_retained_index : t -> int
val total_count : t -> int
val today : t -> int
val set_today : t -> today:int -> t
val slot_key : slot -> string
val day_error : t -> day:int -> string option

val fail_day_request
  :  t
  -> generation:int64
  -> day:int
  -> stale_cursor:bool
  -> message:string
  -> t

val retry_day : t -> day:int -> t
val first_visible_index : t -> int
val scroll_generation : t -> int64
val scroll_target : t -> (int64 * int * string) option
val scroll_outcome : t -> Journal_view.View.Native_list.outcome option

val complete_scroll
  :  t
  -> token:int64
  -> outcome:Journal_view.View.Native_list.outcome
  -> t
