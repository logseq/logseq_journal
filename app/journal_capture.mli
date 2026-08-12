module ID = Bonsai_flutter_spec.Id
module Ui = Bonsai_flutter_ui

type phase =
  | Editing
  | Confirm_discard
  | Saving
  | Failed of string
  | Committed
  | Recovery_only

type t

type dismissal =
  | Close
  | Confirm of t
  | Block

val create : session_number:int64 -> t
val session_id : t -> ID.Text_input.session_id
val document_revision : t -> ID.Text_input.document_revision
val accepted_local_revision : t -> ID.Text_input.local_revision
val update_mode : t -> Ui.Text_editing.update_mode
val value : t -> Ui.Text_editing.Value.t
val source : t -> string
val task_state : t -> Journal_model.task_state
val phase : t -> phase
val dirty : t -> bool
val can_save : t -> bool
val apply_text_edit : t -> Ui.Event.Payload.text_edit -> t
val toggle_task : t -> t
val request_dismiss : t -> dismissal
val can_pop : t -> bool
val keep_editing : t -> t
val discard : t -> t

val admit_save
  :  t
  -> mutation_id:string
  -> block_id:string
  -> sibling_order:string
  -> calendar_generation:int64
  -> creation_time:Journal_time.t
  -> t * Journal_worker.request option

val fail : t -> message:string -> t
val recovery_only : t -> t
val retry : t -> t * Journal_worker.request option
val commit : t -> Journal_model.t -> t
