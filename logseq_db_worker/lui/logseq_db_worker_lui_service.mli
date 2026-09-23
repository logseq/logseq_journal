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

type local_deletion_stage = Logseq_sync_pure_reducer.Core.local_deletion_stage =
  | Closing_graph
  | Deleting_mirror
  | Clearing_selection

type local_deletion = Logseq_sync_pure_reducer.Core.local_deletion =
  | Deletion_in_progress of local_deletion_stage
  | Deletion_failed of local_deletion_stage

type snapshot =
  { sync_phase : sync_phase
  ; catalog : graph list
  ; selected_graph : graph_id option
  ; applied_server_t : int option
  ; timeline_presentation_pending : bool
  ; startup : startup_facts
  ; last_error : string option
  ; local_deletion : local_deletion option
  }

type diagnostic_group =
  { title : string
  ; entries : (string * string) list
  }

type diagnostics = { groups : diagnostic_group list }

type state =
  { snapshot : snapshot
  ; diagnostics : diagnostics
  }

type token_request

val token_request_id : token_request -> string

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

module Asset : sig
  type priority = Logseq_sync_pure_reducer.Asset_transfer.priority =
    | Foreground
    | Background

  type failure = Logseq_sync_pure_reducer.Asset_transfer.failure =
    | Network
    | Not_found
    | Checksum_mismatch
    | Authentication
    | Locked
    | Storage_full
    | Invalid_content of string

  type availability = Logseq_sync_pure_reducer.Asset_transfer.availability =
    | Queued
    | Downloading
    | Ready of string
    | Waiting_remote
    | Waiting_network
    | Waiting_unlock
    | Failed of
        { failure : failure
        ; attempts : int
        ; retry_scheduled : bool
        }
end

type asset_scope = Logseq_sync_pure_reducer.Core.graph_scope

type asset_notice = Logseq_db_worker_pure_reducer.Core.asset_notice =
  | Asset_availability of
      { consumer : string
      ; asset : Logseq_db_types.Graph_types.Uuid.t
      ; availability : Logseq_sync_pure_reducer.Asset_transfer.availability
      }
  | Asset_demand_accepted of string
  | Asset_backpressure of string
  | Asset_capacity_available
  | Upload_status of
      { operation : Logseq_db_types.Graph_types.Uuid.t
      ; asset : Logseq_db_types.Graph_types.Uuid.t
      ; target : Logseq_db_types.Graph_types.Uuid.t
      ; title : string
      ; status : Logseq_db_worker_pure_reducer.Asset_upload.status
      }

type asset_command =
  | Replace_asset_demand of
      { consumer : string
      ; priority : Logseq_sync_pure_reducer.Asset_transfer.priority
      ; assets : Logseq_db_types.Asset_descriptor.t list
      }
  | Release_asset_demand of string
  | Retry_asset of Logseq_db_types.Graph_types.Uuid.t
  | Retry_upload of Logseq_db_types.Graph_types.Uuid.t

type request =
  | Import_asset of
      { graph_generation : int
      ; source : Logseq_db_types.Asset_import.t
      }
  | Client_command of client_command
  | Graph_request of Logseq_db_worker.Protocol.request
  | Get_graph_state
  | Asset_command of
      { graph_generation : int
      ; command : asset_command
      }
  | Acquire_imported_file of
      { scope : Logseq_sync_pure_reducer.Core.graph_scope
      ; operation : Logseq_db_types.Graph_types.Uuid.t
      }
  | Acquire_asset_file of
      { scope : Logseq_sync_pure_reducer.Core.graph_scope
      ; handle : string
      }
  | Release_asset_file of
      { scope : Logseq_sync_pure_reducer.Core.graph_scope
      ; handle : string
      }

type response =
  | Asset_imported of (Logseq_db_worker.import_receipt, string) result
  | Client_command_completed
  | Asset_file of (string * string) option
  | Graph_response of Logseq_db_worker.Protocol.response
  | Graph_state of Logseq_db_worker.graph_state

type push =
  | Graph_push of Logseq_db_worker.Protocol.push
  | Client_state_changed of state
  | Need_id_token of token_request
  | Bootstrap_progress of bootstrap_progress
  | Graph_state_changed of Logseq_db_worker.graph_state
  | Asset_notice of
      Logseq_sync_pure_reducer.Core.graph_scope
      * Logseq_db_worker_pure_reducer.Core.asset_notice

val invalidation_topic : Journal_worker_ids.Worker.Push_topic.t
val manager_topic : Journal_worker_ids.Worker.Push_topic.t
val auth_topic : Journal_worker_ids.Worker.Push_topic.t
val bootstrap_topic : Journal_worker_ids.Worker.Push_topic.t
val graph_state_topic : Journal_worker_ids.Worker.Push_topic.t
val asset_topic : Journal_worker_ids.Worker.Push_topic.t

type dependencies

val dependencies
  :  overlay:Logseq_overlay_db.Database.dependencies
  -> tls_authenticator:Logseq_sync_effect_runner.Effect_runner.tls_authenticator
  -> secrets:Logseq_sync_effect_runner.Effect_runner.secrets
  -> crypto:Logseq_sync_effect_runner.Effect_runner.crypto
  -> dependencies

val create
  :  dependencies:dependencies
  -> (Logseq_db_worker.Config.t, request, response, push) Journal_worker.Service.t

val service
  : (Logseq_db_worker.Config.t, request, response, push) Journal_worker.Service.t
