module ID = Journal_ids
module Ui = Journal_view

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

(** Remount the same owned draft with a fresh editor session and unchanged value. *)
val rebind : t -> session_number:int64 -> t

val phase : t -> phase
val can_save : t -> bool
val update_source : t -> source:string -> t
val toggle_task_intent : t -> t
val apply_text_edit : t -> Ui.Event.Payload.text_edit -> t

(** Upper bound on attachments a draft capture may hold. *)
val attachment_limit : int

(** Assets picked for this draft, awaiting attach-on-save. *)
val pending_attachments : t -> Journal_asset_import.staged list

(** Whether another attachment may be added (not saving, under the limit). *)
val can_attach : t -> bool

val add_attachment : t -> Journal_asset_import.staged -> t
val remove_attachment : t -> token:string -> t
val clear_attachments : t -> t

(** For an admitted save, the captured block id and the attachments to import
    into it; [None] without a pending capture or attachments. *)
val attachment_imports : t -> (string * Journal_asset_import.staged list) option

val admit_save
  :  t
  -> mutation_id:string
  -> block_id:string
  -> sibling_order:string
  -> calendar_generation:int64
  -> creation_time:Journal_time.t
  -> t * Journal_graph_request.t option

val fail : t -> message:string -> t
val fail_attempt : t -> mutation_id:string -> block_id:string -> message:string -> t
val retry : t -> t * Journal_graph_request.t option
val completed_by : t -> Journal_model.t -> bool
