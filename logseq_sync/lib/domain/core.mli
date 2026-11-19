module Overlay = Logseq_overlay_db.Types
module Server_cursor = Overlay.Server_cursor
type graph_id = Logseq_db_types.Sync_account.graph_id
val graph_id_to_yojson : graph_id -> Yojson.Safe.t
val graph_id_of_yojson :
  Yojson.Safe.t -> graph_id Ppx_deriving_yojson_runtime.error_or
type cache_schema =
  Logseq_db_types.Sync_account.cache_schema = {
  major : int;
  minor : int;
  exact : bool;
}
val cache_schema_to_yojson : cache_schema -> Yojson.Safe.t
val cache_schema_of_yojson :
  Yojson.Safe.t -> cache_schema Ppx_deriving_yojson_runtime.error_or
type graph =
  Logseq_db_types.Sync_account.graph = {
  graph_id : graph_id;
  name : string;
  schema : cache_schema;
  encrypted : bool;
}
val graph_to_yojson : graph -> Yojson.Safe.t
val graph_of_yojson :
  Yojson.Safe.t -> graph Ppx_deriving_yojson_runtime.error_or
type account_generation = Logseq_db_types.Sync_account.account_generation
type graph_generation = Logseq_db_types.Sync_account.graph_generation
type connection_generation =
    Logseq_db_types.Sync_account.connection_generation
type presentation_generation =
    Logseq_db_types.Sync_account.presentation_generation
type lifecycle_generation = Logseq_db_types.Sync_account.lifecycle_generation
type account_scope =
  Logseq_db_types.Sync_account.account_scope = {
  managed_sync_origin : Uri.t;
  user_id : string;
  account_generation : account_generation;
  presentation_generation : presentation_generation;
  lifecycle_generation : lifecycle_generation;
}
type graph_scope =
  Logseq_db_types.Sync_account.graph_scope = {
  account : account_scope;
  graph_id : graph_id;
  graph_generation : graph_generation;
}
module Host_cleanup_scopes :
  sig
    type elt = graph_scope
    type t
    val empty : t
    val add : elt -> t -> t
    val singleton : elt -> t
    val remove : elt -> t -> t
    val union : t -> t -> t
    val inter : t -> t -> t
    val disjoint : t -> t -> bool
    val diff : t -> t -> t
    val cardinal : t -> int
    val elements : t -> elt list
    val min_elt : t -> elt
    val min_elt_opt : t -> elt option
    val max_elt : t -> elt
    val max_elt_opt : t -> elt option
    val choose : t -> elt
    val choose_opt : t -> elt option
    val find : elt -> t -> elt
    val find_opt : elt -> t -> elt option
    val find_first : (elt -> bool) -> t -> elt
    val find_first_opt : (elt -> bool) -> t -> elt option
    val find_last : (elt -> bool) -> t -> elt
    val find_last_opt : (elt -> bool) -> t -> elt option
    val iter : (elt -> unit) -> t -> unit
    val fold : (elt -> 'acc -> 'acc) -> t -> 'acc -> 'acc
    val map : (elt -> elt) -> t -> t
    val filter : (elt -> bool) -> t -> t
    val filter_map : (elt -> elt option) -> t -> t
    val partition : (elt -> bool) -> t -> t * t
    val split : elt -> t -> t * bool * t
    val is_empty : t -> bool
    val is_singleton : t -> bool
    val mem : elt -> t -> bool
    val equal : t -> t -> bool
    val compare : t -> t -> int
    val subset : t -> t -> bool
    val for_all : (elt -> bool) -> t -> bool
    val exists : (elt -> bool) -> t -> bool
    val to_list : t -> elt list
    val of_list : elt list -> t
    val to_seq_from : elt -> t -> elt Seq.t
    val to_seq : t -> elt Seq.t
    val to_rev_seq : t -> elt Seq.t
    val add_seq : elt Seq.t -> t -> t
    val of_seq : elt Seq.t -> t
  end
type host_fence_target = One_graph of graph_id | All_graphs
type host_fence = {
  id : Logseq_db_types.Graph_types.Uuid.t;
  owner : account_scope;
  target : host_fence_target;
  captured_scopes : graph_scope Rrbvec.t;
  previous : Logseq_db_types.Graph_types.Uuid.t option;
}
type connection_scope = {
  graph : graph_scope;
  connection_generation : connection_generation;
}
type sync_phase =
  Logseq_db_types.Sync_account.sync_phase =
    Offline
  | Connecting
  | Pulling
  | Submitting
  | Current
  | Paused
  | Failed
type startup_failure_stage =
  Logseq_db_types.Sync_account.startup_failure_stage =
    During_authentication
  | During_catalog
  | During_local_restore
  | During_bootstrap
  | During_e2ee
type local_unavailability =
  Logseq_db_types.Sync_account.local_unavailability =
    No_local_account
  | Local_catalog_unavailable
  | Local_mirror_unavailable
  | Local_key_unavailable
  | Local_restore_failed
type local_access =
  Logseq_db_types.Sync_account.local_access =
    Local_pending
  | Local_available
  | Local_unavailable of local_unavailability
type startup_network_phase =
  Logseq_db_types.Sync_account.startup_network_phase =
    Local_only
  | Online_after_timeline
  | Online_by_user
type startup_facts =
  Logseq_db_types.Sync_account.startup_facts = {
  authenticated : bool;
  local_access : local_access;
  network_phase : startup_network_phase;
  catalog_loading : bool;
  awaiting_selection : bool;
  restoring_local : bool;
  bootstrapping : bool;
  awaiting_e2ee_password : bool;
  failure : startup_failure_stage option;
  account_generation : account_generation;
  graph_generation : graph_generation;
  presentation_generation : presentation_generation;
}
type local_deletion_stage =
  Logseq_db_types.Sync_account.local_deletion_stage =
    Closing_graph
  | Deleting_mirror
  | Clearing_selection
type local_deletion =
  Logseq_db_types.Sync_account.local_deletion =
    Deletion_in_progress of local_deletion_stage
  | Deletion_failed of local_deletion_stage
type unlock_challenge =
  Logseq_db_types.Sync_account.unlock_challenge = {
  challenge_scope : graph_scope;
  challenge_id : int;
  encrypted_graph_key : string;
  private_key_package : string;
}
type unlock_stage =
  Logseq_db_types.Sync_account.unlock_stage =
    Private_key of int
  | Graph_key of int
  | Attachment
type unlock_submission =
  Logseq_db_types.Sync_account.unlock_submission = {
  challenge : unlock_challenge;
  operation_id : int;
  stage : unlock_stage;
}
type unlock_attached =
  Logseq_db_types.Sync_account.unlock_attached = {
  submission : unlock_submission;
  attached_scope : graph_scope;
}
type unlock_recovery =
  Logseq_db_types.Sync_account.unlock_recovery =
    Retry_password of unlock_challenge * string
  | Retry_preparation of string
type unlock_phase =
  Logseq_db_types.Sync_account.unlock_phase =
    Unlock_inactive
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
type error_attention =
  Logseq_db_types.Sync_account.error_attention =
    Transient_connection
  | Requires_attention
type snapshot =
  Logseq_db_types.Sync_account.snapshot = {
  sync_phase : sync_phase;
  catalog : graph list;
  selected_graph : graph_id option;
  resident_graphs : graph_id list;
  applied_server_t : Server_cursor.t option;
  timeline_presentation_pending : bool;
  unlock : unlock_phase;
  startup : startup_facts;
  last_error : string option;
  last_error_attention : error_attention option;
  local_deletion : local_deletion option;
}
type diagnostic_group =
  Logseq_db_types.Sync_account.diagnostic_group = {
  title : string;
  entries : (string * string) list;
}
type diagnostics =
  Logseq_db_types.Sync_account.diagnostics = {
  groups : diagnostic_group list;
}
type state =
  Logseq_db_types.Sync_account.state = {
  snapshot : snapshot;
  diagnostics : diagnostics;
}
type limits = {
  maximum_response_bytes : int;
  maximum_artifact_bytes : int;
  submission_batch_size : int;
}
type config = { config_origin : Uri.t; limits : limits; }
type config_error = Invalid_config of string
val limits :
  maximum_response_bytes:int ->
  maximum_artifact_bytes:int ->
  submission_batch_size:int -> (limits, config_error) result
val config :
  managed_sync_origin:Uri.t -> limits:limits -> (config, config_error) result
type bootstrap_progress = {
  graph_id : graph_id;
  received_bytes : int64;
  total_bytes : int64 option;
}
type invalidation = {
  basis : int64;
  changed_uuids : graph_id list;
  changed_uuids_truncated : bool;
}
type effect_scope = {
  account_generation : account_generation option;
  graph_generation : graph_generation option;
  connection_generation : connection_generation option;
  presentation_generation : presentation_generation option;
  lifecycle_generation : lifecycle_generation option;
}
type effect_id = int
type crypto_failure_kind = Invalid_key_material | Crypto_provider_unavailable
type effect_error =
    Effect_failed of string
  | Crypto_failed of crypto_failure_kind * string
type graph_key_handle = { handle_id : string; handle_scope : graph_scope; }
type snapshot_download = {
  scope : graph_scope;
  uri : Uri.t;
  expected_bytes : int64 option;
  maximum_bytes : int;
  metadata_cursor : Server_cursor.t;
  attempt_id : effect_id;
  download_id : effect_id;
}
type staged_artifact = {
  download : snapshot_download;
  artifact_path : string;
  artifact_expected_rows : int;
}
type catalog_cache =
  Logseq_db_types.Sync_account.catalog_cache = {
  cache_user_id : string;
  cache_graphs : graph list;
  cache_selected_graph : graph_id option;
  cache_resident_graphs : graph_id list option;
}
val catalog_cache_to_yojson : catalog_cache -> Yojson.Safe.t
val catalog_cache_of_yojson :
  Yojson.Safe.t -> catalog_cache Ppx_deriving_yojson_runtime.error_or
val graph_key_handle : id:string -> scope:graph_scope -> graph_key_handle
val graph_key_handle_id : graph_key_handle -> string
val graph_key_handle_scope : graph_key_handle -> graph_scope
val stage_snapshot_download :
  snapshot_download ->
  path:string -> expected_rows:int -> (staged_artifact, string) result
val snapshot_download_scope : snapshot_download -> graph_scope
val snapshot_download_uri : snapshot_download -> Uri.t
val snapshot_download_expected_bytes : snapshot_download -> int64 option
val snapshot_download_maximum_bytes : snapshot_download -> int
val staged_artifact_path : staged_artifact -> string
val staged_artifact_expected_rows : staged_artifact -> int
val effect_scope_of_account : account_scope -> effect_scope
val effect_scope_of_graph : graph_scope -> effect_scope
val effect_scope_of_connection : connection_scope -> effect_scope
val catalog_cache :
  user_id:string ->
  graphs:graph list -> selected_graph:graph_id option -> catalog_cache
val catalog_cache_user_id : catalog_cache -> string
val catalog_cache_graphs : catalog_cache -> graph list
val catalog_cache_selected_graph : catalog_cache -> graph_id option
val catalog_cache_resident_graphs : catalog_cache -> graph_id list
val encode_catalog_cache : catalog_cache -> string
val decode_catalog_cache : string -> (catalog_cache, string) result
type encryption_batch = {
  scope : graph_scope;
  key : graph_key_handle;
  plaintexts : string list;
}
type encrypted_values = (string * string) list
type decryption_batch = {
  scope : graph_scope;
  key : graph_key_handle;
  protected_values : (string * string) list;
}
type decrypted_values = string list
type snapshot_baseline = string
type snapshot_metadata = string
type graph_key_request = {
  scope : graph_scope;
  encrypted_graph_key : string;
}
type private_key_unlock = {
  scope : account_scope;
  password : string;
  private_key_package : string;
}
type retirement_id = Logseq_db_types.Graph_types.Retirement_id.t
val retirement_id_of_string :
  string -> (Logseq_db_types.Graph_types.Retirement_id.t, string) result
val retirement_id_to_string :
  Logseq_db_types.Graph_types.Retirement_id.t -> string
type asset_deletion = {
  deletion_scope : graph_scope;
  retirement : retirement_id;
}
val asset_deletion_reference :
  scope:graph_scope -> retirement:retirement_id -> asset_deletion
val asset_deletion_scope : asset_deletion -> graph_scope
val asset_deletion_retirement : asset_deletion -> retirement_id
type asset_context = {
  scope : graph_scope;
  encrypted : bool;
  key : graph_key_handle option;
}
type asset_action =
    Check_asset_cache of graph_id * Logseq_db_types.Asset_descriptor.version
  | Fetch_asset of { asset : graph_id;
      version : Logseq_db_types.Asset_descriptor.version;
      maximum_plaintext_bytes : int;
    }
  | Stage_asset_file of { operation : graph_id; file_type : string;
      source_file : string;
    }
  | Put_asset_file of { asset : graph_id;
      version : Logseq_db_types.Asset_descriptor.version; file : string;
      maximum_plaintext_bytes : int;
    }
  | Publish_staged_asset of { asset : Logseq_db_types.Graph_types.Uuid.t;
      version : Logseq_db_types.Asset_descriptor.version; file : string;
    }
  | Retain_asset_file of string
  | Retain_staged_file of string
  | Release_asset_file of string
  | Release_staged_file of string
  | Prune_asset_staging of string list
  | Await_asset_operations
  | Close_asset_scope
  | Prepare_graph_asset_deletion of retirement_id
  | Commit_graph_asset_deletion of asset_deletion
  | Cancel_graph_asset_deletion of asset_deletion
  | Delete_account_assets
  | Asset_retry_after of float
  | Cancel_asset_operation of string
type asset_failure =
    Asset_network
  | Asset_not_found
  | Asset_checksum_mismatch
  | Asset_authentication
  | Asset_locked
  | Asset_storage_full
  | Asset_missing_source
  | Asset_size_rejected
  | Asset_revoked_access
  | Asset_cancelled
  | Asset_invalid_content of string
  | Asset_with_cause of asset_failure * Logseq_db_types.Failure_diagnostic.t
val asset_failure_kind : asset_failure -> asset_failure
val asset_failure_cause :
  asset_failure -> Logseq_db_types.Failure_diagnostic.t option
val asset_failure_with_cause :
  asset_failure -> Logseq_db_types.Failure_diagnostic.t -> asset_failure
type asset_value =
    Asset_unit
  | Asset_cached of string option
  | Asset_downloaded of string
  | Asset_staged of { file : string; checksum : string; size : int64; }
  | Asset_retained of (string * string) option
  | Asset_deletion_prepared of asset_deletion
  | Asset_pruned of int
  | Asset_retry_elapsed
type asset_result = (asset_value, asset_failure) result
type asset_request = {
  scope : graph_scope;
  operation : string;
  action : asset_action;
}
type asset_io_request = {
  context : asset_context;
  operation : string;
  action : asset_action;
}
type asset_ticket = { asset_serial : int; asset_request : asset_io_request; }
val asset_ticket_id : asset_ticket -> string
type asset_output = { request : asset_request; result : asset_result; }
type protected_action =
    Encrypt_values of graph_key_handle * string list
  | Decrypt_value of graph_key_handle * string
type protected_request = {
  protected_operation : string;
  protected_scope : graph_scope;
  protected_action : protected_action;
}
type protected_value =
    Encrypted_values of (string * string) list
  | Decrypted_value of string
type protected_result = (protected_value, effect_error) result
type protected_output = {
  protected_request : protected_request;
  protected_result : protected_result;
}
type protected_ticket = {
  protected_serial : int;
  protected_input : protected_request;
}
val protected_ticket_id : protected_ticket -> string
type _ runner_request =
    Load_catalog : account_scope -> catalog_cache option runner_request
  | Save_catalog : { account : account_scope; cache : catalog_cache;
    } -> unit runner_request
  | Fetch_catalog : account_scope -> graph list runner_request
  | Fetch_snapshot_baseline : graph_scope -> snapshot_baseline runner_request
  | Fetch_snapshot_metadata : graph_scope -> snapshot_metadata runner_request
  | Download_snapshot : snapshot_download -> staged_artifact runner_request
  | Fetch_e2ee_graph_key : graph_scope -> string runner_request
  | Fetch_e2ee_user_keys : account_scope -> string runner_request
  | Load_and_unlock_graph_key :
      graph_scope -> graph_key_handle runner_request
  | Fetch_and_unlock_graph_key :
      graph_key_request -> graph_key_handle runner_request
  | Unlock_private_key : private_key_unlock -> unit runner_request
  | Delete_account_secrets : account_scope -> unit runner_request
  | Encrypt_protected_values :
      encryption_batch -> encrypted_values runner_request
  | Decrypt_protected_values :
      decryption_batch -> decrypted_values runner_request
type _ request_kind =
    Load_catalog_kind : catalog_cache option request_kind
  | Save_catalog_kind : unit request_kind
  | Fetch_catalog_kind : graph list request_kind
  | Fetch_snapshot_baseline_kind : snapshot_baseline request_kind
  | Fetch_snapshot_metadata_kind : snapshot_metadata request_kind
  | Download_snapshot_kind : staged_artifact request_kind
  | Fetch_e2ee_graph_key_kind : string request_kind
  | Fetch_e2ee_user_keys_kind : string request_kind
  | Load_and_unlock_graph_key_kind : graph_key_handle request_kind
  | Fetch_and_unlock_graph_key_kind : graph_key_handle request_kind
  | Unlock_private_key_kind : unit request_kind
  | Delete_account_secrets_kind : unit request_kind
  | Encrypt_protected_values_kind : encrypted_values request_kind
  | Decrypt_protected_values_kind : decrypted_values request_kind
type 'a effect_ticket = {
  id : effect_id;
  scope : effect_scope;
  kind : 'a request_kind;
}
val effect_ticket_id : 'a effect_ticket -> effect_id
val effect_ticket_scope : 'a effect_ticket -> effect_scope
val effect_id_to_string : int -> string
type websocket_request = { scope : connection_scope; uri : Uri.t; }
type websocket_send = {
  scope : connection_scope;
  message : Logseq_sync_protocol.Sync_protocol.Client.message;
}
type websocket_termination =
    Recoverable_close of { message : string option;
      attention : error_attention;
    }
  | Local_close
  | Authentication_failure of string
  | Protocol_failure of string
type timer_id = int
type timer_request = {
  id : timer_id;
  scope : effect_scope;
  delay_seconds : float;
}
type runner_effect =
    Await_io of int64 * effect_scope
  | Asset_io of asset_ticket * asset_io_request
  | Protected_io of protected_ticket * protected_request
  | Request : 'a effect_ticket * 'a runner_request -> runner_effect
  | Start_websocket of websocket_request
  | Send_websocket of websocket_send
  | Close_websocket of connection_scope
  | Schedule_timer of timer_request
  | Cancel_effects of effect_scope
  | Cancel_network_effects of effect_scope
type runner_completion =
    Asset_completion of asset_ticket * asset_result
  | Protected_completion of protected_ticket * protected_result
  | Completion : 'a effect_ticket *
      ('a, effect_error) result -> runner_completion
val scope_of_request : 'a runner_request -> effect_scope
val runner_effect_scope : runner_effect -> effect_scope
val runner_effect_diagnostic : runner_effect -> string
val equal_runner_effect : 'a -> 'a -> bool
type mirror_request = { graph : graph; scope : graph_scope; }
type snapshot_activation_request = private {
  artifact : staged_artifact;
  scope : graph_scope;
  applied_server_t : Server_cursor.t;
  key : graph_key_handle option;
}
val activate_staged_snapshot :
  staged_artifact -> key:graph_key_handle option -> (snapshot_activation_request, string) result
val snapshot_activation_scope : snapshot_activation_request -> graph_scope
val snapshot_activation_cursor :
  snapshot_activation_request -> Server_cursor.t
val snapshot_activation_artifact :
  snapshot_activation_request -> staged_artifact
val snapshot_activation_key :
  snapshot_activation_request -> graph_key_handle option
type bootstrap =
    No_bootstrap
  | Preparing_snapshot of graph_scope
  | Awaiting_snapshot_metadata of graph_scope * effect_id
  | Downloading_snapshot of snapshot_download
  | Activating_snapshot of snapshot_activation_request
val bootstrap_scope : bootstrap -> graph_scope option
val bootstrap_downloading : bootstrap -> bool
val bootstrap_activating : bootstrap -> bool
type mirror_deletion = {
  account : account_scope;
  graph_id : graph_id;
  scope : effect_scope;
}
type mirror_inspection =
    Mirror_available of mirror_request
  | Mirror_absent of graph_scope
type outbox_transition_request = {
  expected : Overlay.sync_token;
  key : graph_key_handle option;
  scope : graph_scope;
  transition : Overlay.outbox_transition;
}
type outbox_transition_failure = {
  request : outbox_transition_request;
  message : string;
}
type authoritative_batch = {
  input : Overlay.authoritative_batch;
  key : graph_key_handle option;
  scope : connection_scope;
  presentation_generation : presentation_generation;
  lifecycle_generation : lifecycle_generation;
}
type worker_effect =
    Inspect_mirror of mirror_request
  | Activate_snapshot of snapshot_activation_request
  | Delete_mirror of mirror_deletion
  | Attach_graph of mirror_request
  | Detach_graph of graph_scope
  | Reset_managed_account of account_scope
  | Inspect_sync of graph_scope
  | Apply_outbox_transition of outbox_transition_request
  | Apply_authoritative_batch of authoritative_batch
type output =
    Asset_finished of asset_output
  | Protected_finished of protected_output
  | State_changed of state
  | Resident_scopes_changed of graph_scope list
  | Session_state_changed of graph_scope * state
  | Bootstrap_progressed of bootstrap_progress
type instruction =
    Run of runner_effect
  | Delegate of worker_effect
  | Publish of output
val equal_instruction : 'a -> 'a -> bool
val equal_instructions : 'a -> 'a -> bool
type scoped_error = { scope : effect_scope; message : string; }
type graph_attachment = { scope : graph_scope; sync : Overlay.sync_view; }
type sync_inspection = { scope : graph_scope; sync : Overlay.sync_view; }
type authoritative_commit_result = {
  scope : graph_scope;
  commit : Overlay.authoritative_commit;
  sync : Overlay.sync_view;
}
type authoritative_deferred_result = {
  scope : graph_scope;
  defer : Overlay.authoritative_defer;
}
type outbox_transition_result = {
  scope : graph_scope;
  commit : Overlay.outbox_commit;
  sync : Overlay.sync_view;
}
type snapshot_activation = snapshot_activation_request
type snapshot_activation_error = {
  activation : snapshot_activation_request;
  message : string;
}
val snapshot_activation_completed :
  snapshot_activation_request -> snapshot_activation
val snapshot_activation_failed :
  snapshot_activation_request -> message:string -> snapshot_activation_error
type startup_scope =
  Logseq_db_types.Sync_account.startup_scope = {
  account_generation : account_generation;
  presentation_generation : presentation_generation;
}
type timeline_scope =
  Logseq_db_types.Sync_account.timeline_scope = {
  startup : startup_scope;
  graph_id : graph_id;
  graph_generation : graph_generation;
}
type event =
    Host_fence_started of host_fence
  | Host_fence_released of Logseq_db_types.Graph_types.Uuid.t
  | IO_fence_requested of int64 * effect_scope
  | IO_fence_completed of int64 * effect_scope * (unit, string) result
  | Asset_requested of asset_request
  | Protected_requested of protected_request
  | Restore_local_account of { user_id : string; }
  | Account_authenticated of { user_id : string option; }
  | Local_feed_acknowledged
  | Local_outbox_changed
  | Resident_graphs_changed of graph_id list
  | Visible_graph_changed of graph_id
  | Local_graph_outbox_changed of graph_scope
  | Timeline_presented of timeline_scope
  | Graph_selected of graph_id
  | Graph_picker_requested
  | Sign_in_requested of startup_scope
  | Catalog_refresh_requested of startup_scope
  | Online_recovery_requested of timeline_scope
  | Online_cancelled of startup_scope
  | Local_account_unavailable of startup_scope * local_unavailability
  | E2ee_password_submitted of unlock_challenge * string
  | Local_cache_deletion_requested of graph_id
  | Foreground_changed of { foreground : bool;
      lifecycle_generation : lifecycle_generation;
    }
  | Graph_detached of graph_scope * (unit, string) result
  | Mirror_deleted of mirror_deletion * (unit, string) result
  | Mirror_inspected of mirror_inspection
  | Graph_attached of graph_attachment
  | Graph_attachment_failed of scoped_error
  | Sync_inspected of sync_inspection
  | Outbox_transition_applied of outbox_transition_result
  | Outbox_transition_superseded of { request : outbox_transition_request;
      sync : Logseq_overlay_db.Types.sync_view;
    }
  | Outbox_transition_failed of outbox_transition_failure
  | Authoritative_batch_applied of authoritative_commit_result
  | Authoritative_batch_deferred of authoritative_deferred_result
  | Authoritative_batch_failed of scoped_error
  | Snapshot_activated of snapshot_activation
  | Snapshot_activation_failed of snapshot_activation_error
  | Runner_completed of runner_completion
  | Snapshot_download_progress of bootstrap_progress
  | Websocket_opened of connection_scope
  | Websocket_message of connection_scope *
      Logseq_sync_protocol.Sync_protocol.Server.message
  | Websocket_protocol_error of connection_scope *
      Logseq_sync_protocol.Sync_protocol.codec_error
  | Websocket_closed of connection_scope * websocket_termination
  | Websocket_retired of connection_scope
  | Timer_elapsed of timer_id
  | Shutdown
type coordination_state =
  Logseq_db_types.Sync_account.coordination_state = {
  account : account_scope option;
  desired_residents : graph_id list;
  residents : (graph_scope * state) list;
  selected : timeline_scope option;
  deletion : (graph_scope * local_deletion) option;
}
