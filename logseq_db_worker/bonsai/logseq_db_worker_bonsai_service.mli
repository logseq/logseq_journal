type request =
  | Manager_command of Logseq_db_worker.Sync_manager.command
  | Graph_request of Logseq_db_worker.Protocol.request

type response =
  | Manager_snapshot of Logseq_db_worker.Sync_manager.snapshot
  | Graph_response of Logseq_db_worker.Protocol.response

type push =
  | Graph_push of Logseq_db_worker.Protocol.push
  | Manager_state_changed of Logseq_db_worker.Sync_manager.snapshot
  | Need_id_token of Logseq_db_worker.Sync_auth.challenge
  | Bootstrap_progress of
      { account_generation : int
      ; graph_generation : int
      ; progress : Logseq_db_worker.Sync_bootstrap.progress
      }

val invalidation_topic : Bonsai_flutter_spec.Id.Worker.Push_topic.t
val manager_topic : Bonsai_flutter_spec.Id.Worker.Push_topic.t
val auth_topic : Bonsai_flutter_spec.Id.Worker.Push_topic.t
val bootstrap_topic : Bonsai_flutter_spec.Id.Worker.Push_topic.t

val create
  :  dependencies:Logseq_db_worker.Engine.dependencies
  -> (Logseq_db_worker.Config.t, request, response, push) Worker.Service.t

val service : (Logseq_db_worker.Config.t, request, response, push) Worker.Service.t
