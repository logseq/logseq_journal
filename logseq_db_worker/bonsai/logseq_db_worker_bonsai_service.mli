type client_command =
  | Restore_local_account of { user_id : string }
  | Reconcile_authenticated_user of { user_id : string option }
  | Acknowledge_local_feed
  | Acknowledge_timeline_presented
  | Provide_token of
      { request : Logseq_sync.Api.token_request
      ; token : string
      }
  | Reject_token of Logseq_sync.Api.token_request
  | Select_graph of Logseq_sync.Api.graph_id
  | Return_to_graph_picker
  | Refresh_catalog
  | Begin_online_recovery
  | Submit_e2ee_password of string
  | Delete_local_cache of Logseq_sync.Api.graph_id
  | Set_foreground of bool

type request =
  | Client_command of client_command
  | Graph_request of Logseq_db_worker.Protocol.request
  | Get_graph_state

type response =
  | Client_state of Logseq_sync.Api.state
  | Graph_response of Logseq_db_worker.Protocol.response
  | Graph_state of Logseq_db_worker.graph_state

type push =
  | Graph_push of Logseq_db_worker.Protocol.push
  | Client_state_changed of Logseq_sync.Api.state
  | Need_id_token of Logseq_sync.Api.token_request
  | Bootstrap_progress of Logseq_sync.Api.bootstrap_progress
  | Graph_state_changed of Logseq_db_worker.graph_state

val invalidation_topic : Bonsai_flutter_spec.Id.Worker.Push_topic.t
val manager_topic : Bonsai_flutter_spec.Id.Worker.Push_topic.t
val auth_topic : Bonsai_flutter_spec.Id.Worker.Push_topic.t
val bootstrap_topic : Bonsai_flutter_spec.Id.Worker.Push_topic.t
val graph_state_topic : Bonsai_flutter_spec.Id.Worker.Push_topic.t

type dependencies

val dependencies
  :  engine:Logseq_db_worker.Engine.dependencies
  -> secrets:Logseq_sync.Api.secrets
  -> crypto:Logseq_sync.Api.crypto
  -> dependencies

val create
  :  dependencies:dependencies
  -> (Logseq_db_worker.Config.t, request, response, push) Worker.Service.t

val service : (Logseq_db_worker.Config.t, request, response, push) Worker.Service.t
