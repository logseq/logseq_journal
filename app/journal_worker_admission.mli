type t

val create
  :  runtime_epoch:Logseq_db_worker_lui.Journal_worker_ids.Runtime.epoch
  -> worker_generation:Logseq_db_worker_lui.Journal_worker_ids.Worker.generation
  -> send:
       (Logseq_db_worker_lui.Logseq_db_worker_lui_service.request
        -> Logseq_db_worker_lui.Journal_worker.send_result)
  -> refused:
       (Logseq_db_worker_lui.Logseq_db_worker_lui_service.request
        -> Logseq_db_worker_lui.Journal_worker.send_result
        -> unit)
  -> t

val dispatch
  :  t
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
