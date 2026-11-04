module ID = Journal_ids

type mode =
  | Reading
  | Saving_child
  | Failed of string

type t

type row =
  | Block of
      { block : Journal_model.t
      ; depth : int
      }
  | More of
      { parent_id : string
      ; depth : int
      ; loading : bool
      ; enabled : bool
      ; error : string option
      }

type event =
  | Observe_visible_range of int64 * int64
  | Load_next
  | Load_initial_next
  | Load_more of string
  | Loaded of int64 * Journal_graph_projection.detail
  | Load_failed of int64 * bool * string
  | Append_failed of string * string

val create : session_number:int64 -> Journal_graph_projection.detail -> t

(** Equality of outline content, actions and reveal commands, excluding child
    draft text and request bookkeeping. *)
val equal_presentation : t -> t -> bool

val root : t -> Journal_model.t
val find_block : t -> block_id:string -> Journal_model.t option
val children : t -> Journal_model.t list
val children_of : t -> parent_id:string -> Journal_model.t list
val continuation : t -> parent_id:string -> Journal_graph_projection.block_cursor option
val rows : t -> row list
val row_key : row -> string

(** Next bounded first-page read demanded by the native visible index range.
    Before the first observation no automatic read is admitted. Each round
    reserves complete 128-item pages against a conservative 384-block counter
    and at most 128 reads. Initially the counter includes the root and its
    projection page. A successfully admitted explicit action starts a new
    round counting returned pages; earlier explicit rows and external updates
    remain available and are not globally truncated.
    Continuations and
    failed reads remain explicit Load more actions. *)
val next_automatic_load : t -> string option

(** Initial body discovery uses the same depth, complete-page reservation and
    attempt budgets as visible demand. It reads only unknown first pages of
    materialized branches; continuation cursors remain explicit. Publication
    must preserve these counters rather than starting another automatic round. *)
val initial_staging : t -> [ `Waiting | `Ready | `Load of string ]

(** A page completion owns membership and continuation. Content changed by a
    point update since dispatch survives that completion; opaque revisions are
    never ordered as clocks. *)
val step : t -> event -> t * Journal_graph_request.t list
val mode : t -> mode
val session_id : t -> ID.Text_input.session_id
val composer_revision : t -> int64
val reveal_id : t -> string option
val request_back : t -> [ `Close ]
val child_capture : t -> Journal_capture.t option

(** Update the owned draft only while editable; an admitted child remains frozen. *)
val map_child_capture : t -> f:(Journal_capture.t -> Journal_capture.t) -> t

(** Staged imports for this exact child completion, before retiring its draft. *)
val child_attachment_imports
  :  t
  -> child:Journal_model.t
  -> parent:Journal_model.t
  -> (string * Journal_asset_import.staged list) option

val update_child_source : t -> string -> t
val apply_child_edit : t -> Journal_view.Event.Payload.text_edit -> t
val set_child_task : t -> Journal_model.task_state -> t
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

(** Charge newly materialized shared updates to the still-hidden initial owner.
    Existing nodes are not charged twice; consumed counters never decrease. *)
val account_initial_update : previous:t -> t -> t

val apply_child_created : t -> child:Journal_model.t -> parent:Journal_model.t -> t

(** Remove a committed subtree from the materialized outline. Unrelated pending
    reads retain their ownership; removed branches cannot accept completions. *)
val remove_block : t -> block_id:string -> t option

(** Only composer ownership is retained; reopening loads a fresh outline projection. *)
type retained_composer

val retained_attachments : retained_composer -> Journal_asset_import.staged list
val retained_capture : retained_composer -> Journal_capture.t
val retained_saving : retained_composer -> bool

val map_retained_capture
  :  retained_composer
  -> f:(Journal_capture.t -> Journal_capture.t)
  -> retained_composer

val retained_attachment_imports
  :  retained_composer
  -> child:Journal_model.t
  -> parent:Journal_model.t
  -> (string * Journal_asset_import.staged list) option

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

val child_error : t -> string option
val has_child_request : t -> Journal_graph_projection.create_child -> bool
val retained_has_child_request : retained_composer -> Journal_graph_projection.create_child -> bool
val preview_child_created : t -> command:Journal_graph_projection.create_child
  -> child:Journal_model.t -> parent:Journal_model.t -> error:string option -> t
val preview_child_failure : t -> command:Journal_graph_projection.create_child -> message:string -> t
val preview_retained_child : retained_composer -> command:Journal_graph_projection.create_child
  -> child:Journal_model.t -> parent:Journal_model.t -> error:string option -> retained_composer
val preview_retained_failure : retained_composer -> command:Journal_graph_projection.create_child
  -> message:string -> retained_composer
val child_projection_applied : t -> command:Journal_graph_projection.create_child
  -> child:Journal_model.t -> parent:Journal_model.t -> error:string option -> bool
val retained_projection_applied : retained_composer -> command:Journal_graph_projection.create_child
  -> child:Journal_model.t -> parent:Journal_model.t -> error:string option -> bool
val child_failure_applied : t -> command:Journal_graph_projection.create_child -> message:string -> bool
val retained_failure_applied : retained_composer -> command:Journal_graph_projection.create_child -> message:string -> bool
val release_rejected_child : t -> command:Journal_graph_projection.create_child -> message:string -> t
val release_rejected_retained : retained_composer -> command:Journal_graph_projection.create_child
  -> message:string -> retained_composer

val child_chain : t -> command:Journal_graph_projection.create_child ->
  Journal_graph_mutation_confirmation.Pure_insertion.t option
val retained_child_chain : retained_composer -> command:Journal_graph_projection.create_child ->
  Journal_graph_mutation_confirmation.Pure_insertion.t option
val retain_child_chain : t -> command:Journal_graph_projection.create_child ->
  Journal_graph_mutation_confirmation.Pure_insertion.t -> t
val retain_retained_child_chain : retained_composer -> command:Journal_graph_projection.create_child ->
  Journal_graph_mutation_confirmation.Pure_insertion.t -> retained_composer

module Pure_observation : sig
  module Worker = Journal_worker_coordination.Worker_api
  module Core = Journal_worker_coordination.Worker_pure_coordinator

  type context =
    { entry_id : string
    ; request_generation : int64
    ; root : Worker.Uuid.t
    ; owner : Logseq_db_worker_lui.Logseq_db_worker_lui_service.timeline_scope
    ; original : Worker.Uuid.t
    ; maximum_children : int
    }

  type ticket = Worker_pure_data.block_lookup Worker.observed Core.ticket

  type instruction =
    | Cancel_initial of ticket
    | Forget_initial of ticket
    | Release of Worker_pure_data.block_lookup Worker.observation
    | Initial of context * Worker_pure_data.block_lookup Worker.observed
    | Updated of context * Worker_pure_data.block_lookup Worker.observed
    | Failed of context * Worker.error
    | Rejected of context * Worker.error

  type t

  val empty : t

  (** Retain presentation context, never a second admission or resource authority.
      Replacement delegates cancellation/release to the Worker coordinator. *)
  val planned : t -> context -> ticket -> t * instruction Rrbvec.t

  (** Forward only coordinator-owned current samples. Missing values and failed
      reads retain their observation; errors do not imply physical release. *)
  val inspect : t -> Core.view -> t * instruction Rrbvec.t

  (** Native path identity includes the entry generation, even for the same UUID.
      Cleanup ownership remains in Core until its actual physical ACK. *)
  val retain : t -> (string * int64 * Worker.Uuid.t) Rrbvec.t -> t * instruction Rrbvec.t

  val context_count : t -> int
  val handle : t -> entry_id:string -> request_generation:int64 -> root:Worker.Uuid.t ->
    Worker_pure_data.block_lookup Worker.observation option

end

val await_child_confirmation : t -> block_id:string -> t
val await_retained_confirmation : retained_composer -> block_id:string -> retained_composer

val pending_submission : t -> (Journal_graph_projection.create_child * Journal_graph_mutation_confirmation.Pure_insertion.t) option
val retained_pending_submission : retained_composer -> (Journal_graph_projection.create_child * Journal_graph_mutation_confirmation.Pure_insertion.t) option
