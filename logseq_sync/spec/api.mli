(** The complete public synchronization API contract. *)

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

type invalidation =
  { basis : int64
  ; changed_uuids : graph_id list
  ; changed_uuids_truncated : bool
  }

type t
type outbox_record

val decode_outbox_records : string list -> (outbox_record list, string) result
val encode_outbox_records : outbox_record list -> (string list, string) result
val outbox_record_mutation_id : outbox_record -> graph_id
val outbox_record_fingerprint : outbox_record -> string

val prepare_local_batch
  :  t
  -> outbox:outbox_record list
  -> mutation_id:graph_id
  -> mutation_payload:string
  -> mutation_fingerprint:string
  -> outliner_op:string
  -> database:Datascript.db
  -> operations:Datascript.tx_op list
  -> (outbox_record list, string) result

val restore_outbox_projection
  :  t
  -> database:Datascript.db
  -> outbox_records:string list
  -> (Datascript.tx_op list list, string) result

type graph_open_request
type authoritative_batch

val authoritative_batch_payload : authoritative_batch -> string
val authoritative_batch_scope : authoritative_batch -> int * int * int * int * int64

type authoritative_commit =
  { transactions : Datascript.tx_op list list
  ; checkpoint : Logseq_db_types.Sync_checkpoint.t
  ; outbox_records : string list
  ; activity : Logseq_db_types.Sync_status.activity
  }

type authoritative_plan =
  | No_authoritative_commit of
      { checkpoint : Logseq_db_types.Sync_checkpoint.t
      ; outbox_records : string list
      ; activity : Logseq_db_types.Sync_status.activity
      }
  | Commit_authoritative of authoritative_commit

val plan_authoritative_batch
  :  t
  -> authoritative_batch
  -> checkpoint:Logseq_db_types.Sync_checkpoint.t
  -> database:Datascript.db
  -> outbox_records:string list
  -> (authoritative_plan, string) result

type outbox_transition

val outbox_transition_scope : outbox_transition -> int * int * int * int64
val outbox_transition_expected_records : outbox_transition -> string list
val outbox_transition_records : outbox_transition -> string list
val outbox_transition_pending_payload : outbox_transition -> string option

type local_operation
type completion

type sync_effect =
  | State_changed of state
  | Token_requested of token_request
  | Bootstrap_progressed of bootstrap_progress
  | Graph_invalidated of invalidation
  | Attach_graph of graph_open_request
  | Detach_graph of { graph_generation : int }
  | Apply_authoritative_batch of authoritative_batch
  | Commit_outbox_transition of outbox_transition
  | Run_local_operation of local_operation
  | Resume of completion

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
  | Foreground_changed of bool
  | Graph_attached of
      { account_generation : int
      ; graph_generation : int
      ; checkpoint : Logseq_db_types.Sync_checkpoint.t
      ; outbox_records : string list
      }
  | Graph_attachment_failed of
      { account_generation : int
      ; graph_generation : int
      ; message : string
      }
  | Local_batch_committed of { outbox_records : string list }
  | Authoritative_batch_applied of
      { account_generation : int
      ; graph_generation : int
      ; checkpoint : Logseq_db_types.Sync_checkpoint.t
      ; outbox_records : string list
      ; activity : Logseq_db_types.Sync_status.activity
      ; invalidation : invalidation option
      }
  | Authoritative_batch_failed of
      { account_generation : int
      ; graph_generation : int
      ; message : string
      }
  | Outbox_transition_committed of
      { outbox_records : string list
      ; pending_payload : string option
      }
  | Outbox_transition_rejected of
      { outbox_records : string list
      ; message : string
      }
  | Shutdown

type dependency_error = Invalid_dependency of string
type config_error = Invalid_config of string
type create_error = Invalid_create of string
type limits

val limits
  :  maximum_response_bytes:int
  -> maximum_artifact_bytes:int
  -> submission_batch_size:int
  -> (limits, config_error) result

type config

val config : managed_sync_origin:Uri.t -> limits:limits -> (config, config_error) result

type runtime

val runtime
  :  fork:(sw:Eio.Switch.t -> (unit -> unit) -> unit)
  -> sleep:(float -> unit)
  -> monotonic_ns:(unit -> int64)
  -> (runtime, dependency_error) result

type transport

val transport
  :  network:_ Eio.Net.t
  -> clock:_ Eio.Time.clock
  -> (transport, dependency_error) result

type local_store

val local_store
  :  application_support_directory:string
  -> (local_store, dependency_error) result

val run_local_operation : t -> local_store -> local_operation -> sync_effect list

type artifact_store

val artifact_store : staging_directory:string -> (artifact_store, dependency_error) result

type wrapped_key_load_error =
  | Wrapped_graph_key_unavailable of string
  | Local_private_key_unavailable of string

type secrets

val secrets
  :  has_private_key:(managed_sync_origin:Uri.t -> user_id:string -> bool)
  -> unlock_private_key:
       (managed_sync_origin:Uri.t
        -> user_id:string
        -> password:string
        -> private_key_package:string
        -> (unit, string) result)
  -> unlock_graph_key:
       (managed_sync_origin:Uri.t
        -> user_id:string
        -> encrypted_graph_key:string
        -> (string, string) result)
  -> load_and_verify_wrapped_graph_key:
       (managed_sync_origin:Uri.t
        -> user_id:string
        -> graph_id:graph_id
        -> (string, wrapped_key_load_error) result)
  -> verify_and_save_wrapped_graph_key:
       (managed_sync_origin:Uri.t
        -> user_id:string
        -> graph_id:graph_id
        -> encrypted_graph_key:string
        -> (unit, string) result)
  -> delete_wrapped_graph_key:
       (managed_sync_origin:Uri.t
        -> user_id:string
        -> graph_id:graph_id
        -> (unit, string) result)
  -> delete_account_secrets:
       (managed_sync_origin:Uri.t -> user_id:string -> (unit, string) result)
  -> (secrets, dependency_error) result

type crypto

val crypto
  :  decrypt_private_key:
       (password:string
        -> iterations:int
        -> salt:string
        -> iv:string
        -> ciphertext:string
        -> (string, string) result)
  -> decrypt_graph_key:
       (private_key:string -> ciphertext:string -> (string, string) result)
  -> encrypt_aes_gcm:(key:string -> plaintext:string -> (string * string, string) result)
  -> decrypt_aes_gcm:
       (key:string -> iv:string -> ciphertext:string -> (string, string) result)
  -> (crypto, dependency_error) result

(** Constructs the production Apple secret-custody adapter explicitly. *)
val apple_secrets : unit -> (secrets, dependency_error) result

(** Constructs the production Apple cryptography adapter explicitly. *)
val apple_crypto : unit -> (crypto, dependency_error) result

val graph_open_request_graph : graph_open_request -> graph
val graph_open_request_graph_directory : graph_open_request -> string
val graph_open_request_database_path : graph_open_request -> string

val graph_open_request_checkpoint
  :  graph_open_request
  -> Logseq_db_types.Sync_checkpoint.t

val graph_open_request_account_generation : graph_open_request -> int
val graph_open_request_generation : graph_open_request -> int

type dependencies

val dependencies
  :  runtime:runtime
  -> transport:transport
  -> artifact_store:artifact_store
  -> secrets:secrets
  -> crypto:crypto
  -> on_effect:(sync_effect -> unit)
  -> (dependencies, dependency_error) result

val create : sw:Eio.Switch.t -> config -> dependencies -> (t, create_error) result
val state : t -> state
val handle : t -> event -> sync_effect list
val resume : t -> completion -> sync_effect list
