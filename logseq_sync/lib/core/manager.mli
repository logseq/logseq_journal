type phase =
  | Signed_out
  | Awaiting_token of Auth.purpose
  | Loading_catalog
  | Awaiting_selection
  | Bootstrapping
  | Recovering_online of Startup_phase.recovery_reason
  | Awaiting_e2ee_password
  | Opening_graph
  | Graph_open
  | Sync_paused
  | Stopping_graph
  | Failed

type startup_presentation =
  | Restoring_local
  | Local_feed_ready
  | Timeline_presented
  | Reconciled

type snapshot =
  { phase : phase
  ; account_generation : int
  ; graph_generation : int
  ; connection_generation : int
  ; user_id : string option
  ; catalog : Catalog.graph list
  ; selected_graph : Graph_types.Uuid.t option
  ; applied_server_t : int option
  ; last_error : string option
  ; presentation_generation : int
  ; startup_presentation : startup_presentation
  }

type diagnostic_transport_scope =
  | Foreground
  | Suspended

type diagnostic_transport =
  | Disconnected
  | Awaiting_token
  | Connecting
  | Live
  | Revalidating
  | Backing_off

type diagnostic_pull =
  | Diagnostic_pull_idle
  | Diagnostic_pull_in_flight of { requested_again : bool }

type diagnostic_submission =
  | Diagnostic_submission_none
  | Diagnostic_submission_deferred of int
  | Diagnostic_submission_in_flight of int

type diagnostic_serialization =
  | Diagnostic_serialization_idle
  | Diagnostic_serialization_applying_pull
  | Diagnostic_serialization_applying_transaction
  | Diagnostic_serialization_applying_control

type diagnostic_change_category =
  | Manager_phase_changed
  | Startup_presentation_changed
  | Account_generation_changed
  | Graph_generation_changed
  | Presentation_generation_changed
  | Connection_generation_changed
  | Graph_selection_changed
  | Transport_scope_changed
  | Transport_changed
  | Websocket_initialization_changed
  | Pull_changed
  | Submission_changed
  | Reconnect_attempt_changed
  | Uncertain_transaction_count_changed
  | Applied_server_t_changed
  | Serialization_changed
  | Error_changed

type diagnostic_change =
  { category : diagnostic_change_category
  ; before : string
  ; after : string
  }

type diagnostic_history_entry =
  { sequence : int
  ; changes : diagnostic_change list
  }

type diagnostics =
  { phase : phase
  ; startup_presentation : startup_presentation
  ; account_generation : int
  ; graph_generation : int
  ; presentation_generation : int
  ; connection_generation : int
  ; graph_selected : bool
  ; selected_graph : Graph_types.Uuid.t option
  ; applied_server_t : int option
  ; transport_scope : diagnostic_transport_scope
  ; transport : diagnostic_transport
  ; websocket_initialized : bool option
  ; pull : diagnostic_pull
  ; submission : diagnostic_submission
  ; reconnect_attempt : int
  ; uncertain_transaction_count : int
  ; serialization : diagnostic_serialization
  ; pending_token_challenge_count : int
  ; last_error : string option
  ; history : diagnostic_history_entry list
  }

type state =
  { snapshot : snapshot
  ; diagnostics : diagnostics
  }

type command =
  | Restore_local_account of
      { user_id : string
      ; managed_sync_origin : string
      }
  | Reconcile_authenticated_user of
      { user_id : string option
      ; managed_sync_origin : string
      }
  | Local_feed_ready of
      { account_generation : int
      ; graph_generation : int
      ; presentation_generation : int
      }
  | Timeline_presented of
      { account_generation : int
      ; graph_generation : int
      ; presentation_generation : int
      }
  | Authenticated_user of { user_id : string }
  | Signed_out_command
  | Provide_id_token of
      { challenge_id : string
      ; user_id : string
      ; account_generation : int
      ; graph_generation : int option
      ; connection_generation : int option
      ; token : string
      }
  | Token_failed of { challenge_id : string }
  | Select_graph of Graph_types.Uuid.t
  | Return_to_graph_picker
  | Refresh_catalog
  | Begin_online_recovery
  | Backgrounded of { lifecycle_generation : int64 }
  | Foreground_resumed of { lifecycle_generation : int64 }
  | Submit_e2ee_password of string
  | Delete_local_cache of Graph_types.Uuid.t

type local_secret_failure_receipt =
  | Wrapped_key_failure_receipt of
      Startup_phase.wrapped_graph_key Startup_phase.failure_receipt
  | Private_key_failure_receipt of
      Startup_phase.local_private_key Startup_phase.failure_receipt

type event =
  | Cached_catalog_loaded of
      { account_generation : int
      ; graphs : Catalog.graph list
      }
  | Catalog_loaded of
      { account_generation : int
      ; graphs : Catalog.graph list
      }
  | Catalog_failed of
      { account_generation : int
      ; message : string
      }
  | Mirror_ready of
      { account_generation : int
      ; graph_generation : int
      ; graph_id : Graph_types.Uuid.t
      }
  | Mirror_missing of
      { account_generation : int
      ; graph_generation : int
      ; graph_id : Graph_types.Uuid.t
      ; receipt : Startup_phase.mirror Startup_phase.failure_receipt
      }
  | Wrapped_graph_key_loaded of
      { account_generation : int
      ; graph_generation : int
      ; graph_id : Graph_types.Uuid.t
      ; encrypted_graph_key : string
      }
  | Wrapped_graph_key_load_failed of
      { account_generation : int
      ; graph_generation : int
      ; graph_id : Graph_types.Uuid.t
      ; diagnostic : string
      ; receipt : local_secret_failure_receipt
      }
  | Wrapped_graph_key_saved of
      { account_generation : int
      ; graph_generation : int
      ; graph_id : Graph_types.Uuid.t
      ; diagnostic : string option
      }
  | Local_secret_cleanup_finished of
      { account_generation : int
      ; diagnostic : string option
      }
  | Local_cache_deleted of
      { account_generation : int
      ; graph_generation : int
      ; graph_id : Graph_types.Uuid.t
      }
  | Snapshot_baseline_loaded of
      { account_generation : int
      ; graph_generation : int
      ; graph_id : Graph_types.Uuid.t
      ; baseline : Bootstrap.baseline
      }
  | Snapshot_metadata_loaded of
      { account_generation : int
      ; graph_generation : int
      ; graph_id : Graph_types.Uuid.t
      ; metadata : Bootstrap.snapshot_metadata
      }
  | Snapshot_artifact_ready of
      { account_generation : int
      ; graph_generation : int
      ; graph_id : Graph_types.Uuid.t
      ; snapshot_path : string
      ; expected_rows : int
      }
  | E2ee_graph_key_loaded of
      { account_generation : int
      ; graph_generation : int
      ; graph_id : Graph_types.Uuid.t
      ; response : string
      }
  | E2ee_user_keys_loaded of
      { account_generation : int
      ; graph_generation : int
      ; graph_id : Graph_types.Uuid.t
      ; response : string
      }
  | Graph_opened of
      { account_generation : int
      ; graph_generation : int
      ; graph_id : Graph_types.Uuid.t
      ; applied_server_t : int
      }
  | Websocket_opened of
      { account_generation : int
      ; graph_generation : int
      ; connection_generation : int
      }
  | Websocket_frame of
      { account_generation : int
      ; graph_generation : int
      ; connection_generation : int
      ; payload : string
      }
  | Websocket_closed of
      { account_generation : int
      ; graph_generation : int
      ; connection_generation : int
      ; message : string
      }
  | Reconnect_timer_elapsed of
      { account_generation : int
      ; graph_generation : int
      ; connection_generation : int
      }
  | Foreground_probe_timed_out of
      { account_generation : int
      ; graph_generation : int
      ; connection_generation : int
      ; lifecycle_generation : int64
      }
  | Pending_batch of string
  | Sync_applied of
      { account_generation : int
      ; graph_generation : int
      ; applied_server_t : int
      ; activity : Logseq_db_types.Sync_status.activity
      ; pending_payload : string option
      }
  | Network_failed of
      { account_generation : int
      ; graph_generation : int option
      ; connection_generation : int option
      ; message : string
      }

type t

val create
  :  e2ee_platform:E2ee_session.platform
  -> next_challenge_id:(unit -> string)
  -> base_url:Uri.t
  -> t

val snapshot : t -> snapshot
val diagnostics : t -> diagnostics
val state : t -> state
val phase_name : phase -> string
val startup_presentation_name : startup_presentation -> string
val diagnostic_transport_scope_name : diagnostic_transport_scope -> string
val diagnostic_transport_name : diagnostic_transport -> string
val diagnostic_pull_name : diagnostic_pull -> string
val diagnostic_submission_name : diagnostic_submission -> string
val diagnostic_serialization_name : diagnostic_serialization -> string
val diagnostic_change_category_name : diagnostic_change_category -> string
val handle_command : t -> command -> Action.packed list
val handle_event : t -> event -> Action.packed list
