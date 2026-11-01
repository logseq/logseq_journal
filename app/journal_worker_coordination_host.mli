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

val post : t -> Core.event -> unit

val on_event
  :  t
  -> (Runner.Service.response, Runner.Service.push) Runner.Mailbox.event
  -> Runner.delivery

val shutdown : t -> Runner.shutdown_state
