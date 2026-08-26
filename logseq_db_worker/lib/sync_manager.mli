type phase =
  | Signed_out
  | Awaiting_token of Sync_auth.purpose
  | Loading_catalog
  | Awaiting_selection
  | Bootstrapping
  | Recovering_online of Sync_startup_phase.recovery_reason
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
  ; catalog : Sync_catalog.graph list
  ; selected_graph : Graph_types.Uuid.t option
  ; applied_server_t : int option
  ; last_error : string option
  ; presentation_generation : int
  ; startup_presentation : startup_presentation
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
      Sync_startup_phase.wrapped_graph_key Sync_startup_phase.failure_receipt
  | Private_key_failure_receipt of
      Sync_startup_phase.local_private_key Sync_startup_phase.failure_receipt

type event =
  | Cached_catalog_loaded of
      { account_generation : int
      ; graphs : Sync_catalog.graph list
      }
  | Catalog_loaded of
      { account_generation : int
      ; graphs : Sync_catalog.graph list
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
      ; receipt : Sync_startup_phase.mirror Sync_startup_phase.failure_receipt
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
      ; baseline : Sync_bootstrap.baseline
      }
  | Snapshot_metadata_loaded of
      { account_generation : int
      ; graph_generation : int
      ; graph_id : Graph_types.Uuid.t
      ; metadata : Sync_bootstrap.snapshot_metadata
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
  | Http_pull_loaded of
      { account_generation : int
      ; graph_generation : int
      ; connection_generation : int
      ; payload : string
      }
  | Http_transaction_loaded of
      { account_generation : int
      ; graph_generation : int
      ; connection_generation : int
      ; payload : string
      }
  | Sync_applied of
      { account_generation : int
      ; graph_generation : int
      ; applied_server_t : int
      ; activity : Protocol.sync_activity
      ; pending_payload : string option
      }
  | Network_failed of
      { account_generation : int
      ; graph_generation : int option
      ; connection_generation : int option
      ; message : string
      }

type t

val create : next_challenge_id:(unit -> string) -> base_url:Uri.t -> t

val create_with_e2ee
  :  e2ee_platform:Sync_e2ee_session.platform
  -> next_challenge_id:(unit -> string)
  -> base_url:Uri.t
  -> t

val snapshot : t -> snapshot
val handle_command : t -> command -> Sync_action.packed list
val handle_event : t -> event -> Sync_action.packed list
val diagnostics : t -> string
