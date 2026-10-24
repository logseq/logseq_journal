type graph_id = Logseq_db_types.Graph_types.Uuid.t
type graph = Logseq_db_types.Managed_graph.t

(** Narrow projection of the unlock operation; construction evidence stays with
    the sync owner. UI clients need not depend on the sync library directly. *)
module Unlock : sig
  type graph_scope = Logseq_sync_pure_reducer.Core.graph_scope
  type unlock_challenge = Logseq_sync_pure_reducer.Core.unlock_challenge
  type unlock_submission = Logseq_sync_pure_reducer.Core.unlock_submission
  type unlock_attached = Logseq_sync_pure_reducer.Core.unlock_attached
  type unlock_recovery = Logseq_sync_pure_reducer.Core.unlock_recovery =
    | Retry_password of unlock_challenge * string
    | Retry_preparation of string
  type unlock_phase = Logseq_sync_pure_reducer.Core.unlock_phase =
    | Unlock_inactive
    | Unlock_challenge of unlock_challenge
    | Unlock_running of unlock_submission
    | Unlock_bootstrapping of unlock_submission
    | Unlock_presentable of unlock_attached
    | Unlock_failed of unlock_recovery
    | Unlock_cancelled of unlock_submission
  val unlock_challenge : unlock_phase -> unlock_challenge option
  val equal_unlock_challenge : unlock_challenge -> unlock_challenge -> bool
  val unlock_challenge_scope : unlock_challenge -> graph_scope
  val unlock_submission_challenge : unlock_submission -> unlock_challenge
  val equal_unlock_submission : unlock_submission -> unlock_submission -> bool
  val unlock_attached_submission : unlock_attached -> unlock_submission
  val unlock_attached_scope : unlock_attached -> graph_scope
end

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

type local_unavailability = Logseq_sync_pure_reducer.Core.local_unavailability =
  | No_local_account
  | Local_catalog_unavailable
  | Local_mirror_unavailable
  | Local_key_unavailable
  | Local_restore_failed

type local_access = Logseq_sync_pure_reducer.Core.local_access =
  | Local_pending
  | Local_available
  | Local_unavailable of local_unavailability

type startup_network_phase = Logseq_sync_pure_reducer.Core.startup_network_phase =
  | Local_only
  | Online_after_timeline
  | Online_by_user

type startup_scope = Logseq_sync_pure_reducer.Core.startup_scope
type timeline_scope = Logseq_sync_pure_reducer.Core.timeline_scope

type startup_facts =
  { authenticated : bool
  ; local_access : local_access
  ; network_phase : startup_network_phase
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
  ; applied_server_t : Logseq_db_types.Server_cursor.t option
  ; timeline_presentation_pending : bool
  ; unlock : Unlock.unlock_phase
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
  | Acknowledge_timeline_presented of timeline_scope
  | Request_sign_in of startup_scope
  | Cancel_online of startup_scope
  | Local_account_unavailable of startup_scope * local_unavailability
  | Provide_token of
      { request : token_request
      ; token : string
      }
  | Reject_token of token_request
  | Select_graph of graph_id
  | Return_to_graph_picker
  | Refresh_catalog of startup_scope
  | Begin_online_recovery of timeline_scope
  | Submit_e2ee_password of Unlock.unlock_challenge * string
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

type local_copy_presence = Downloaded | Not_downloaded

type local_copy_request =
  { graph_id : graph_id
  ; account_generation : int
  }

type request =
  | Inspect_local_copy of local_copy_request
  | Delete_local_copy of local_copy_request
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
  | Local_copy_inspected of local_copy_request * (local_copy_presence, string) result
  | Local_copy_deleted of local_copy_request * (unit, string) result
  | Asset_imported of (Logseq_db_worker.import_receipt, string) result
  | Client_command_completed
  | Asset_file of (string * string) option
  | Graph_response of Logseq_db_worker.Protocol.response
  | Graph_state of Logseq_db_worker.graph_state

type asset_notice_batch

type push =
  | Asset_notices of asset_notice_batch
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

(** Pending latest asset facts, in arrival order. Other push kinds return []. *)
val asset_notices : push -> (asset_scope * asset_notice) list

(** Worker topic merge policy. Snapshot topics replace; independent asset facts
    survive together, up to 4096 distinct pending facts. *)
val coalesce_push : topic:Journal_worker_ids.Worker.push_topic -> push -> push -> push

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

(** Fixed operation, phase and display text for an internal diagnostic signal.
    Unknown signals use a safe fallback without displaying the input. *)
val diagnostic_report : string -> string * string * string

(** Complete the current token challenge through bounded control storage.
    Stale/duplicate replies cannot replace the current flight. Authentication
    changes revoke old tickets before their ordered DB work is admitted. *)
val answer_token
  :  (request, response, push) Journal_worker.client
  -> token_request
  -> (string, string) result
  -> Journal_worker.control_send_result

(** Bounded ledger projection of a typed terminal asset failure. Retry/cancel
    states return None; the original notice and its delivery remain unchanged. *)
val diagnostic_asset_notice : asset_notice -> string option
