type graph_id = Logseq_db_types.Graph_types.Uuid.t
type graph = Logseq_db_types.Managed_graph.t

type sync_phase =
  | Offline
  | Connecting
  | Pulling
  | Submitting
  | Current
  | Paused
  | Failed

type startup_failure_stage =
  | During_authentication
  | During_catalog
  | During_local_restore
  | During_bootstrap
  | During_e2ee

type startup_facts =
  { authenticated : bool
  ; catalog_loading : bool
  ; awaiting_selection : bool
  ; restoring_local : bool
  ; bootstrapping : bool
  ; awaiting_e2ee_password : bool
  ; failure : startup_failure_stage option
  ; account_generation : int
  ; graph_generation : int
  ; presentation_generation : int
  }

type snapshot =
  { sync_phase : sync_phase
  ; catalog : graph list
  ; selected_graph : graph_id option
  ; applied_server_t : int option
  ; timeline_presentation_pending : bool
  ; startup : startup_facts
  ; last_error : string option
  }

type diagnostic_group =
  { title : string
  ; entries : (string * string) list
  }

type diagnostics =
  { groups : diagnostic_group list
  ; history : string list
  }

type state =
  { snapshot : snapshot
  ; diagnostics : diagnostics
  }

type token_purpose =
  | Catalog_discovery
  | Snapshot_bootstrap
  | E2ee_key_access
  | Websocket_connect

type token_request

val token_request_id : token_request -> string
val token_request_purpose : token_request -> token_purpose

type bootstrap_progress =
  { graph_id : graph_id
  ; received_bytes : int64
  ; total_bytes : int64 option
  }

type client_command =
  | Restore_local_account of { user_id : string }
  | Reconcile_authenticated_user of { user_id : string option }
  | Acknowledge_local_feed
  | Acknowledge_timeline_presented
  | Provide_token of
      { request : token_request
      ; token : string
      }
  | Reject_token of token_request
  | Select_graph of graph_id
  | Return_to_graph_picker
  | Refresh_catalog
  | Begin_online_recovery
  | Submit_e2ee_password of string
  | Delete_local_cache of graph_id
  | Set_foreground of bool

type request =
  | Client_command of client_command
  | Graph_request of Logseq_db_worker.Protocol.request
  | Get_graph_state

type response =
  | Client_command_completed
  | Graph_response of Logseq_db_worker.Protocol.response
  | Graph_state of Logseq_db_worker.graph_state

type push =
  | Graph_push of Logseq_db_worker.Protocol.push
  | Client_state_changed of state
  | Need_id_token of token_request
  | Bootstrap_progress of bootstrap_progress
  | Graph_state_changed of Logseq_db_worker.graph_state

val invalidation_topic : Bonsai_flutter_spec.Id.Worker.Push_topic.t
val manager_topic : Bonsai_flutter_spec.Id.Worker.Push_topic.t
val auth_topic : Bonsai_flutter_spec.Id.Worker.Push_topic.t
val bootstrap_topic : Bonsai_flutter_spec.Id.Worker.Push_topic.t
val graph_state_topic : Bonsai_flutter_spec.Id.Worker.Push_topic.t

type dependencies

val dependencies
  :  overlay:Logseq_overlay_db.Database.dependencies
  -> tls_authenticator:Logseq_sync_effect_runner.Effect_runner.tls_authenticator
  -> secrets:Logseq_sync_effect_runner.Effect_runner.secrets
  -> crypto:Logseq_sync_effect_runner.Effect_runner.crypto
  -> dependencies

val create
  :  dependencies:dependencies
  -> (Logseq_db_worker.Config.t, request, response, push) Worker.Service.t

val service : (Logseq_db_worker.Config.t, request, response, push) Worker.Service.t
