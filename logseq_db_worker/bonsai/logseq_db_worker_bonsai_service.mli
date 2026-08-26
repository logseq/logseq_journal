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

type local_secrets =
  { load_and_verify_wrapped_graph_key :
      managed_sync_origin:Uri.t
      -> user_id:string
      -> graph_id:Logseq_db_worker.Graph_types.Uuid.t
      -> (string, Logseq_db_worker.Sync_platform_crypto.wrapped_key_load_failure) result
  ; verify_and_save_wrapped_graph_key :
      managed_sync_origin:Uri.t
      -> user_id:string
      -> graph_id:Logseq_db_worker.Graph_types.Uuid.t
      -> encrypted_graph_key:string
      -> (unit, string) result
  ; delete_wrapped_graph_key :
      managed_sync_origin:Uri.t
      -> user_id:string
      -> graph_id:Logseq_db_worker.Graph_types.Uuid.t
      -> (unit, string) result
  ; delete_account_secrets :
      managed_sync_origin:Uri.t -> user_id:string -> (unit, string) result
  }

val invalidation_topic : Bonsai_flutter_spec.Id.Worker.Push_topic.t
val manager_topic : Bonsai_flutter_spec.Id.Worker.Push_topic.t
val auth_topic : Bonsai_flutter_spec.Id.Worker.Push_topic.t
val bootstrap_topic : Bonsai_flutter_spec.Id.Worker.Push_topic.t

val create
  :  dependencies:Logseq_db_worker.Engine.dependencies
  -> (Logseq_db_worker.Config.t, request, response, push) Worker.Service.t

val create_with_local_secrets
  :  dependencies:Logseq_db_worker.Engine.dependencies
  -> local_secrets:local_secrets
  -> (Logseq_db_worker.Config.t, request, response, push) Worker.Service.t

val service : (Logseq_db_worker.Config.t, request, response, push) Worker.Service.t
