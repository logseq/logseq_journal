(** Pure synchronization policy and protocol state. *)

type graph_id = Logseq_db_types.Graph_types.Uuid.t
type graph = Logseq_db_types.Managed_graph.t
type account_generation = int
type graph_generation = int
type connection_generation = int
type presentation_generation = int
type lifecycle_generation = int64

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
  ; account_generation : account_generation
  ; graph_generation : graph_generation
  ; presentation_generation : presentation_generation
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

type limits
type config
type config_error = Invalid_config of string

val limits
  :  maximum_response_bytes:int
  -> maximum_artifact_bytes:int
  -> submission_batch_size:int
  -> (limits, config_error) result

val config : managed_sync_origin:Uri.t -> limits:limits -> (config, config_error) result

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

type invalidation =
  { basis : int64
  ; changed_uuids : graph_id list
  ; changed_uuids_truncated : bool
  }

type account_scope =
  { managed_sync_origin : Uri.t
  ; user_id : string
  ; account_generation : account_generation
  ; presentation_generation : presentation_generation
  ; lifecycle_generation : lifecycle_generation
  }

type authenticated_account_scope =
  { account : account_scope
  ; token : string
  }

type graph_scope =
  { account : account_scope
  ; graph_id : graph_id
  ; graph_generation : graph_generation
  }

type authorized_graph_scope =
  { graph : graph_scope
  ; token : string
  }

type connection_scope =
  { graph : graph_scope
  ; connection_generation : connection_generation
  }

type effect_scope =
  { account_generation : account_generation option
  ; graph_generation : graph_generation option
  ; connection_generation : connection_generation option
  ; presentation_generation : presentation_generation option
  ; lifecycle_generation : lifecycle_generation option
  }

type effect_id
type effect_error = Effect_failed of string
type graph_key_handle
type staged_artifact
type catalog_cache

val graph_key_handle : id:string -> scope:graph_scope -> graph_key_handle
val graph_key_handle_id : graph_key_handle -> string
val graph_key_handle_scope : graph_key_handle -> graph_scope

val staged_artifact
  :  id:string
  -> scope:graph_scope
  -> path:string
  -> expected_rows:int
  -> staged_artifact

val staged_artifact_path : staged_artifact -> string
val staged_artifact_expected_rows : staged_artifact -> int
val effect_scope_of_graph : graph_scope -> effect_scope

val catalog_cache
  :  user_id:string
  -> graphs:graph list
  -> selected_graph:graph_id option
  -> catalog_cache

val catalog_cache_user_id : catalog_cache -> string
val catalog_cache_graphs : catalog_cache -> graph list
val catalog_cache_selected_graph : catalog_cache -> graph_id option
val encode_catalog_cache : catalog_cache -> string
val decode_catalog_cache : string -> (catalog_cache, string) result

type encryption_batch =
  { scope : graph_scope
  ; key : graph_key_handle
  ; plaintexts : string list
  }

type encrypted_values = (string * string) list

type decryption_batch =
  { scope : graph_scope
  ; key : graph_key_handle
  ; protected_values : (string * string) list
  }

type decrypted_values = string list
type outbox_record
type local_batch_input
type local_batch_plan

val decode_outbox_records : string list -> (outbox_record list, string) result
val encode_outbox_records : outbox_record list -> (string list, string) result
val outbox_record_mutation_id : outbox_record -> graph_id
val outbox_record_fingerprint : outbox_record -> string

val local_batch_input
  :  scope:graph_scope
  -> key:graph_key_handle option
  -> outbox_records:string list
  -> mutation_id:graph_id
  -> mutation_payload:string
  -> mutation_fingerprint:string
  -> outliner_op:string
  -> database:Datascript.db
  -> operations:Datascript.tx_op list
  -> (local_batch_input, string) result

val begin_local_batch : local_batch_input -> (local_batch_plan, string) result
val local_batch_crypto_request : local_batch_plan -> encryption_batch option
val local_batch_input_scope : local_batch_input -> graph_scope
val local_batch_input_mutation_id : local_batch_input -> graph_id
val local_batch_input_fingerprint : local_batch_input -> string

val finish_local_batch
  :  local_batch_plan
  -> encrypted_values option
  -> (outbox_record, string) result

type snapshot_baseline = string
type snapshot_metadata = string

type snapshot_download =
  { scope : authorized_graph_scope
  ; uri : Uri.t
  ; expected_bytes : int64 option
  ; maximum_bytes : int
  }

type graph_key_request =
  { scope : authorized_graph_scope
  ; encrypted_graph_key : string
  }

type private_key_unlock =
  { scope : authenticated_account_scope
  ; password : string
  ; private_key_package : string
  }

type _ runner_request =
  | Load_catalog : account_scope -> catalog_cache option runner_request
  | Save_catalog : catalog_cache -> unit runner_request
  | Fetch_catalog : authenticated_account_scope -> graph list runner_request
  | Fetch_snapshot_baseline : authorized_graph_scope -> snapshot_baseline runner_request
  | Fetch_snapshot_metadata : authorized_graph_scope -> snapshot_metadata runner_request
  | Download_snapshot : snapshot_download -> staged_artifact runner_request
  | Fetch_e2ee_graph_key : authorized_graph_scope -> string runner_request
  | Fetch_e2ee_user_keys : authenticated_account_scope -> string runner_request
  | Load_and_unlock_graph_key : graph_scope -> graph_key_handle runner_request
  | Fetch_and_unlock_graph_key : graph_key_request -> graph_key_handle runner_request
  | Unlock_private_key : private_key_unlock -> unit runner_request
  | Encrypt_protected_values : encryption_batch -> encrypted_values runner_request
  | Decrypt_protected_values : decryption_batch -> decrypted_values runner_request

type 'a effect_ticket

val effect_ticket_id : 'a effect_ticket -> effect_id
val effect_ticket_scope : 'a effect_ticket -> effect_scope
val effect_id_to_string : effect_id -> string

type websocket_request =
  { scope : connection_scope
  ; uri : Uri.t
  ; token : string
  }

type websocket_send =
  { scope : connection_scope
  ; payload : string
  }

type timer_id

type timer_request =
  { id : timer_id
  ; scope : effect_scope
  ; delay_seconds : float
  }

type runner_effect =
  | Request : 'a effect_ticket * 'a runner_request -> runner_effect
  | Start_websocket of websocket_request
  | Send_websocket of websocket_send
  | Close_websocket of connection_scope
  | Schedule_timer of timer_request
  | Cancel_effects of effect_scope

type runner_completion =
  | Completion : 'a effect_ticket * ('a, effect_error) result -> runner_completion

val runner_effect_scope : runner_effect -> effect_scope
val equal_runner_effect : runner_effect -> runner_effect -> bool
val runner_effect_diagnostic : runner_effect -> string

type mirror_request =
  { graph : graph
  ; scope : graph_scope
  }

type snapshot_activation_request =
  { artifact : staged_artifact
  ; scope : graph_scope
  ; applied_server_t : int
  ; key : graph_key_handle option
  }

type mirror_deletion =
  { graph_id : graph_id
  ; scope : effect_scope
  }

type graph_open_request =
  { graph : graph
  ; graph_directory : string
  ; database_path : string
  ; checkpoint : Logseq_db_types.Sync_checkpoint.t
  ; scope : graph_scope
  }

type mirror_inspection =
  | Mirror_available of graph_open_request
  | Mirror_absent of graph_scope

type local_batch_commit_request =
  { operation_id : graph_id
  ; outbox_records : string list
  ; scope : graph_scope
  }

type authoritative_batch =
  { payload : string
  ; scope : connection_scope
  ; presentation_generation : presentation_generation
  ; lifecycle_generation : lifecycle_generation
  }

type authoritative_context =
  { batch : authoritative_batch
  ; checkpoint : Logseq_db_types.Sync_checkpoint.t
  ; database : Datascript.db
  ; outbox_records : string list
  }

type authoritative_plan

val begin_authoritative_batch
  :  authoritative_context
  -> (authoritative_plan, string) result

val authoritative_crypto_request : authoritative_plan -> decryption_batch option

type authoritative_commit_request =
  { scope : graph_scope
  ; transactions : Datascript.tx_op list list
  ; projection_transactions : Datascript.tx_op list list
  ; checkpoint : Logseq_db_types.Sync_checkpoint.t
  ; outbox_records : string list
  ; activity : Logseq_db_types.Sync_status.activity
  }

val finish_authoritative_batch
  :  authoritative_plan
  -> decrypted_values option
  -> (authoritative_commit_request, string) result

type outbox_transition =
  { scope : graph_scope
  ; presentation_generation : presentation_generation
  ; lifecycle_generation : lifecycle_generation
  ; expected_outbox_records : string list
  ; outbox_records : string list
  ; pending_payload : string option
  }

type worker_effect =
  | Inspect_mirror of mirror_request
  | Activate_snapshot of snapshot_activation_request
  | Delete_mirror of mirror_deletion
  | Attach_graph of graph_open_request
  | Detach_graph of { graph_generation : graph_generation }
  | Commit_local_batch of local_batch_commit_request
  | Inspect_authoritative_batch of authoritative_batch
  | Apply_authoritative_batch of authoritative_commit_request
  | Commit_outbox_transition of outbox_transition

type output =
  | State_changed of state
  | Token_requested of token_request
  | Bootstrap_progressed of bootstrap_progress
  | Graph_invalidated of invalidation

type instruction =
  | Run of runner_effect
  | Delegate of worker_effect
  | Publish of output

val equal_instruction : instruction -> instruction -> bool
val equal_instructions : instruction list -> instruction list -> bool

type scoped_error =
  { scope : effect_scope
  ; message : string
  }

type graph_attachment =
  { scope : graph_scope
  ; checkpoint : Logseq_db_types.Sync_checkpoint.t
  ; outbox_records : string list
  }

type local_batch_commit =
  { scope : graph_scope
  ; outbox_records : string list
  }

type authoritative_commit_result =
  { scope : graph_scope
  ; checkpoint : Logseq_db_types.Sync_checkpoint.t
  ; outbox_records : string list
  ; activity : Logseq_db_types.Sync_status.activity
  ; invalidation : invalidation option
  }

type outbox_transition_commit =
  { scope : graph_scope
  ; outbox_records : string list
  ; pending_payload : string option
  }

type outbox_transition_rejection =
  { scope : graph_scope
  ; outbox_records : string list
  ; message : string
  }

type snapshot_activation = { scope : graph_scope }

type event =
  | Restore_local_account of { user_id : string }
  | Account_authenticated of { user_id : string option }
  | Local_feed_acknowledged
  | Timeline_presented
  | Token_provided of token_request * string
  | Token_rejected of token_request
  | Graph_selected of graph_id
  | Graph_picker_requested
  | Catalog_refresh_requested
  | Online_recovery_requested
  | E2ee_password_submitted of string
  | Local_cache_deletion_requested of graph_id
  | Foreground_changed of
      { foreground : bool
      ; lifecycle_generation : lifecycle_generation
      }
  | Mirror_inspected of mirror_inspection
  | Graph_attached of graph_attachment
  | Graph_attachment_failed of scoped_error
  | Local_batch_prepared of local_batch_input
  | Local_batch_committed of local_batch_commit
  | Authoritative_batch_inspected of authoritative_context
  | Authoritative_batch_applied of authoritative_commit_result
  | Authoritative_batch_failed of scoped_error
  | Outbox_transition_committed of outbox_transition_commit
  | Outbox_transition_rejected of outbox_transition_rejection
  | Snapshot_activated of snapshot_activation
  | Snapshot_activation_failed of scoped_error
  | Runner_completed of runner_completion
  | Snapshot_download_progress of bootstrap_progress
  | Websocket_opened of connection_scope
  | Websocket_frame of connection_scope * string
  | Websocket_closed of connection_scope * string option
  | Timer_elapsed of timer_id
  | Shutdown

type t
type create_error = Invalid_create of string

val initial : config -> (t, create_error) result
val state : t -> state

type transition =
  { next : t
  ; effects : instruction list
  }

val step : t -> event -> transition
