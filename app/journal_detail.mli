module ID = Journal_ids

type mode =
  | Reading
  | Saving_child
  | Failed of string

type t
type staged_delete

type row =
  | Block of
      { block : Journal_model.t
      ; depth : int
      ; expanded : bool
      ; leaf : bool
      }
  | More of
      { parent_id : string
      ; depth : int
      ; loading : bool
      ; error : string option
      }

type event =
  | Set_branch_expanded of string * bool
  | Load_more of string
  | Loaded of int64 * Journal_graph_projection.detail
  | Load_failed of int64 * bool * string
  | Append_failed of string * string

val create : session_number:int64 -> Journal_graph_projection.detail -> t
val root : t -> Journal_model.t
val find_block : t -> block_id:string -> Journal_model.t option
val children : t -> Journal_model.t list
val children_of : t -> parent_id:string -> Journal_model.t list
val expanded : t -> block_id:string -> bool
val continuation : t -> parent_id:string -> Journal_graph_projection.block_cursor option
val rows : t -> row list
val row_key : row -> string
val step : t -> event -> t * Journal_graph_request.t list
val mode : t -> mode
val session_id : t -> ID.Text_input.session_id
val composer_revision : t -> int64
val reveal_id : t -> string option
val request_back : t -> [ `Close ]
val child_capture : t -> Journal_capture.t option
val update_child_source : t -> string -> t
val apply_child_edit : t -> Journal_view.Event.Payload.text_edit -> t
val toggle_child_task : t -> t
val fail : t -> message:string -> t
val retry : t -> t * Journal_graph_request.t option

val admit_child
  :  t
  -> mutation_id:string
  -> calendar_generation:int64
  -> block_id:string
  -> sibling_order:string
  -> creation_time:Journal_time.t
  -> t * Journal_graph_request.t option

val apply_block : t -> Journal_model.t -> t
val reconcile_children : t -> Journal_graph_projection.detail -> t
val apply_child_created : t -> child:Journal_model.t -> parent:Journal_model.t -> t
val stage_delete : t -> block_id:string -> (t * staged_delete) option
val undo_delete : t -> staged_delete -> t

(** Only composer ownership is retained; reopening loads a fresh outline projection. *)
type retained_composer

val retain_composer : t -> retained_composer option
val restore_composer : t -> retained_composer -> t

val complete_retained_composer
  :  retained_composer
  -> child:Journal_model.t
  -> parent:Journal_model.t
  -> retained_composer option

val fail_retained_composer
  :  retained_composer
  -> block_id:string
  -> message:string
  -> retained_composer

val interrupt_retained_composer : retained_composer -> retained_composer
val reveal_outcome : t -> Journal_view.View.Native_list.outcome option

val complete_reveal
  :  t
  -> token:int64
  -> outcome:Journal_view.View.Native_list.outcome
  -> t
