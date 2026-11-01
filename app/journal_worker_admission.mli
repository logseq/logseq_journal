type t

val create
  :  runtime_epoch:Logseq_db_worker_lui.Journal_worker_ids.Runtime.epoch
  -> worker_generation:Logseq_db_worker_lui.Journal_worker_ids.Worker.generation
  -> send:
       (Logseq_db_worker_lui.Logseq_db_worker_lui_service.request
        -> Logseq_db_worker_lui.Journal_worker.send_result)
  -> cancel:(Logseq_db_worker_lui.Journal_worker_ids.Worker.request_id -> unit)
  -> projection_accepted:(Logseq_db_worker.Protocol.request -> unit)
  -> projection_finished:(Logseq_db_types.Graph_types.Uuid.t -> unit)
  -> refused:
       (Logseq_db_worker_lui.Logseq_db_worker_lui_service.request
        -> Logseq_db_worker_lui.Journal_worker.send_result
        -> unit)
  -> t

val dispatch
  :  t
  -> ?observe_projection:bool
  -> Logseq_db_worker_lui.Logseq_db_worker_lui_service.request
  -> Logseq_db_worker_lui.Journal_worker.send_result

type delivery = Registered_response | Unowned_response | Broadcast | Dropped_envelope

(** Classify the real channel before business dispatch. Each Accepted ID has one
    terminal delivery, including failures and cancellations. Unknown or duplicate
    responses never enter a generic failure handler. Broadcasts do not retire
    requests. Call once at the shared host entry, before scoped fanout. *)
val receive
  : t
  -> (Logseq_db_worker_lui.Logseq_db_worker_lui_service.response,
      Logseq_db_worker_lui.Logseq_db_worker_lui_service.push)
       Logseq_db_worker_lui.Journal_worker.event
  -> delivery

(** Remove the delivered lease and return whether it was already retired.
    An unknown worker ID and a live completion both return [false]. *)
val retire : t -> Logseq_db_worker_lui.Journal_worker_ids.Worker.request_id -> bool
(** Cancel each live lease once, forgetting projection ownership first. Protocol
    IDs are reopened; worker-ID tombstones remain until their response arrives. *)
val cancel_graph_leases : t -> unit

val cancel_graph_scope : t -> Logseq_db_worker_lui.Logseq_db_worker_lui_service.timeline_scope option -> unit
