module ID = Bonsai_flutter_spec.Id
module Ui = Bonsai_flutter_ui

type phase =
  | Editing
  | Confirm_discard
  | Saving
  | Failed of string
  | Committed

type t
type editor

type dismissal =
  | Close
  | Confirm of t
  | Block

val create : session_number:int64 -> source:string -> t
val session_id : t -> ID.Text_input.session_id
val document_revision : t -> ID.Text_input.document_revision
val accepted_local_revision : t -> ID.Text_input.local_revision
val update_mode : t -> Ui.Text_editing.update_mode
val value : t -> Ui.Text_editing.Value.t
val source : t -> string
val task_state : t -> Journal_model.task_state
val phase : t -> phase
val child_editors : t -> editor list
val editor_session_id : editor -> ID.Text_input.session_id
val editor_document_revision : editor -> ID.Text_input.document_revision
val editor_accepted_local_revision : editor -> ID.Text_input.local_revision
val editor_update_mode : editor -> Ui.Text_editing.update_mode
val editor_value : editor -> Ui.Text_editing.Value.t
val dirty : t -> bool
val can_save : t -> bool
val can_add_child : t -> bool
val add_child : t -> session_number:int64 -> t
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
  -> child_identities:(string * string * string) list
  -> calendar_generation:int64
  -> creation_time:Journal_time.t
  -> t * Journal_graph_request.t option

val fail : t -> message:string -> t
val retry : t -> t * Journal_graph_request.t option
val commit : t -> Journal_model.t -> t
