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
