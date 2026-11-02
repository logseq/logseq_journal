module Worker = Journal_worker_coordination.Worker_api
module Core = Journal_worker_coordination.Worker_pure_coordinator
module Runner = Journal_worker_coordination.Worker_effect_runner

type t

val create
  :  client:Runner.client
  -> client_id:Worker.Uuid.t
  -> managed_origin:string
  -> user_id:string
  -> enqueue:((unit -> unit) -> unit)
  -> changed:(Core.view -> unit)
  -> (t, Worker.error) result

val view : t -> Core.view

val request
  :  t
  -> Worker.session
  -> 'a Worker.request
  -> ('a Core.ticket, Worker.error) result

val reconcile_mutation
  : t -> presentation:Worker.presentation -> Worker.mutation_intent
  -> (Worker.mutation_progress Core.ticket, Worker.error) result

val settle_applied_mutation
  : t -> presentation:Worker.presentation -> applied_presentation:Worker.presentation -> Worker.mutation_intent
  -> (Core.mutation_settlement, Worker.error) result

val begin_change_application
  :  t
  -> Worker.change_batch
  -> root:Worker.Uuid.t
  -> (Core.change_application, Worker.error) result

val post : t -> Core.event -> unit

val plan_query
  :  t
  -> owner:Runner.Service.timeline_scope
  -> maximum_items:int
  -> maximum_bytes:int
  -> 'a Worker.query
  -> ('a Core.ticket, Worker.error) result

(** Retain the same pure ticket on pre-admission Full and retry only after real
    capacity. Session replacement still revokes its original send authority. *)
val plan_query_when_available
  :  t
  -> owner:Runner.Service.timeline_scope
  -> maximum_items:int
  -> maximum_bytes:int
  -> 'a Worker.query
  -> ('a Core.ticket, Worker.error) result

(** A host-owned callback outlet only. The coordinator owns admission, cancellation
    and terminal consumption; completed tickets are forgotten on a later queued
    turn before the business callback is delivered. *)
val watch : t -> 'a Core.ticket -> f:('a Worker.reply -> unit) -> unit

(** Capture pure query provenance before the scheduled Forget, then deliver it on
    the same later business callback turn. No session is inferred from the latest
    projection; non-query or unsent tickets carry None. *)
val watch_read
  :  t
  -> 'a Core.ticket
  -> f:((Worker.session * Worker.read_budget) option -> 'a Worker.reply -> unit)
  -> unit

val validate_session
  :  ?owner:Logseq_db_worker_lui.Logseq_db_worker_lui_service.timeline_scope
  -> t
  -> Worker.session
  -> (unit, Worker.error) result

val on_event
  :  t
  -> (Runner.Service.response, Runner.Service.push) Runner.Mailbox.event
  -> Runner.delivery

val shutdown : t -> Runner.shutdown_state

(** Route existing business Block/Page dependency point reads through the same
    typed admission and exclusive response owner. False means another request
    family; callbacks retain the actual Send origin and carry only checked DTOs. *)
val query_point
  :  t
  -> owner:Runner.Service.timeline_scope
  -> maximum_bytes:int
  -> Logseq_db_worker.Protocol.command
  -> f:
       ((Worker.session * Worker.read_budget) option
        -> (Logseq_db_worker.Protocol.v2_outcome, Worker.error) result
        -> unit)
  -> (bool, Worker.error) result

(** Queued business outlets only. Exact plan/admission/cleanup/one-use decisions
    remain in Core; the host supplies real legacy retirement facts through post. *)
val prepare_host_change : ?legacy_pending:bool -> t -> Worker.host_change -> (Worker.handoff_id,Worker.error)result
val authorize_host_change : t -> Worker.handoff_receipt -> (unit,Worker.error)result
val watch_handoff : t -> Worker.handoff_id -> f:(Worker.handoff_state -> unit) -> unit

val host_change_blocks : t -> owner:Runner.Service.timeline_scope -> bool
