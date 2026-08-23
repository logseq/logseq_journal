type phase =
  | Signed_out
  | Awaiting_token of Sync_auth.purpose
  | Loading_catalog
  | Awaiting_selection
  | Bootstrapping
  | Awaiting_e2ee_password
  | Opening_graph
  | Graph_open
  | Sync_paused
  | Stopping_graph
  | Failed

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
  }

type command =
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
  | Backgrounded of { lifecycle_generation : int64 }
  | Foreground_resumed of { lifecycle_generation : int64 }
  | Submit_e2ee_password of string
  | Delete_local_cache of Graph_types.Uuid.t

type event =
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
      ; payload : string
      }
  | Http_transaction_loaded of
      { account_generation : int
      ; graph_generation : int
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
      ; message : string
      }

type action =
  | Need_id_token of Sync_auth.challenge
  | Fetch_catalog of
      { account_generation : int
      ; base_url : Uri.t
      ; token : string
      }
  | Inspect_mirror of
      { account_generation : int
      ; graph_generation : int
      ; graph : Sync_catalog.graph
      }
  | Fetch_snapshot_baseline of
      { account_generation : int
      ; graph_generation : int
      ; graph : Sync_catalog.graph
      ; token : string
      }
  | Fetch_snapshot_metadata of
      { account_generation : int
      ; graph_generation : int
      ; graph : Sync_catalog.graph
      ; token : string
      }
  | Download_snapshot_artifact of
      { account_generation : int
      ; graph_generation : int
      ; graph : Sync_catalog.graph
      ; baseline : Sync_bootstrap.baseline
      ; metadata : Sync_bootstrap.snapshot_metadata
      ; token : string
      }
  | Activate_snapshot of
      { account_generation : int
      ; graph_generation : int
      ; graph : Sync_catalog.graph
      ; server_t : int
      ; snapshot_path : string
      ; expected_rows : int
      ; graph_key : string option
      }
  | Fetch_e2ee_graph_key of
      { account_generation : int
      ; graph_generation : int
      ; graph : Sync_catalog.graph
      ; token : string
      }
  | Fetch_e2ee_user_keys of
      { account_generation : int
      ; graph_generation : int
      ; graph_id : Graph_types.Uuid.t
      ; token : string
      }
  | Open_graph of
      { account_generation : int
      ; graph_generation : int
      ; graph : Sync_catalog.graph
      ; encrypted_graph_key : string option
      }
  | Close_graph
  | Connect_websocket of
      { account_generation : int
      ; graph_generation : int
      ; connection_generation : int
      ; graph_id : Graph_types.Uuid.t
      ; token : string
      }
  | Close_websocket
  | Send_websocket of string
  | Schedule_reconnect of
      { account_generation : int
      ; graph_generation : int
      ; connection_generation : int
      ; delay_seconds : float
      }
  | Schedule_foreground_probe of
      { account_generation : int
      ; graph_generation : int
      ; connection_generation : int
      ; lifecycle_generation : int64
      ; delay_seconds : float
      }
  | Apply_sync_frame of string
  | Recover_submitted of Graph_types.Uuid.t list
  | Fetch_http_pull of
      { account_generation : int
      ; graph_generation : int
      ; graph_id : Graph_types.Uuid.t
      ; since : int
      ; token : string
      }
  | Submit_http_transaction of
      { account_generation : int
      ; graph_generation : int
      ; graph_id : Graph_types.Uuid.t
      ; payload : string
      ; token : string
      }
  | Delete_mirror of Graph_types.Uuid.t

type t

val create : next_challenge_id:(unit -> string) -> base_url:Uri.t -> t

val create_with_e2ee
  :  e2ee_platform:Sync_e2ee_session.platform
  -> next_challenge_id:(unit -> string)
  -> base_url:Uri.t
  -> t

val snapshot : t -> snapshot
val handle_command : t -> command -> action list
val handle_event : t -> event -> action list
val diagnostics : t -> string
