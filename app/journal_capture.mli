module ID = Bonsai_flutter_spec.Id
module Ui = Bonsai_flutter_ui

type phase =
  | Editing
  | Saving
  | Failed of string

module Editor : sig
  type t

  val create : session_number:int64 -> source:string -> t
  val session_id : t -> ID.Text_input.session_id
  val document_revision : t -> ID.Text_input.document_revision
  val accepted_local_revision : t -> ID.Text_input.local_revision
  val update_mode : t -> Ui.Text_editing.update_mode
  val value : t -> Ui.Text_editing.Value.t
  val source : t -> string
  val replace : t -> source:string -> t
  val apply_text_edit : t -> Ui.Event.Payload.text_edit -> t option
end

type t

val create : session_number:int64 -> source:string -> t
val session_id : t -> ID.Text_input.session_id
val document_revision : t -> ID.Text_input.document_revision
val accepted_local_revision : t -> ID.Text_input.local_revision
val update_mode : t -> Ui.Text_editing.update_mode
val value : t -> Ui.Text_editing.Value.t
val source : t -> string
val task_state : t -> Journal_model.task_state
val phase : t -> phase
val can_save : t -> bool
val update_source : t -> source:string -> t
val toggle_task_intent : t -> t
val apply_text_edit : t -> Ui.Event.Payload.text_edit -> t

val admit_save
  :  t
  -> mutation_id:string
  -> block_id:string
  -> sibling_order:string
  -> calendar_generation:int64
  -> creation_time:Journal_time.t
  -> t * Journal_graph_request.t option

val fail : t -> message:string -> t
val retry : t -> t * Journal_graph_request.t option
