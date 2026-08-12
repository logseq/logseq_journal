module ID = Bonsai_flutter_spec.Id
module Ui = Bonsai_flutter_ui

type mode =
  | Reading
  | Editing
  | Confirm_discard
  | Saving
  | Conflict
  | Failed of string
  | Adding_child
  | Saving_child
  | Committed
  | Recovery_only

type t

val create : session_number:int64 -> Journal_repository.detail -> t
val root : t -> Journal_model.t
val children : t -> Journal_model.t list
val mode : t -> mode
val session_id : t -> ID.Text_input.session_id
val document_revision : t -> ID.Text_input.document_revision
val accepted_local_revision : t -> ID.Text_input.local_revision
val update_mode : t -> Ui.Text_editing.update_mode
val editor_value : t -> Ui.Text_editing.Value.t option
val dirty : t -> bool
val can_save : t -> bool
val begin_edit : t -> t
val apply_text_edit : t -> Ui.Event.Payload.text_edit -> t
val request_back : t -> [ `Close | `State of t ]
val keep_editing : t -> t
val discard_edit : t -> t
val admit_save : t -> mutation_id:string -> t * Journal_worker.request option
val apply_conflict : t -> Journal_model.t -> t
val fail : t -> message:string -> t
val recovery_only : t -> t
val retry : t -> mutation_id:string -> t * Journal_worker.request option
val admit_task_toggle : t -> mutation_id:string -> t * Journal_worker.request option
val begin_child : t -> session_number:int64 -> t
val child_capture : t -> Journal_capture.t option
val apply_child_text_edit : t -> Ui.Event.Payload.text_edit -> t

val admit_child
  :  t
  -> mutation_id:string
  -> block_id:string
  -> sibling_order:string
  -> creation_time:Journal_time.t
  -> t * Journal_worker.request option

val apply_block : t -> Journal_model.t -> t
val apply_child_created : t -> child:Journal_model.t -> parent_revision:int -> t
