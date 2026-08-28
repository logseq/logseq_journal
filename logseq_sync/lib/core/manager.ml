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
      ; activity : Sync_status.activity
      ; pending_payload : string option
      }
  | Network_failed of
      { account_generation : int
      ; graph_generation : int option
      ; connection_generation : int option
      ; message : string
      }

type startup_authority =
  | No_startup_authority
  | Restoring_authority of Startup_phase.restoring Startup_phase.witness
  | Presented_authority of Startup_phase.presented Startup_phase.witness

type pending_network_permit =
  | Pending_account_permit of Startup_phase.account Startup_phase.network_permit
  | Pending_graph_permit of Startup_phase.graph Startup_phase.network_permit
  | Pending_connection_permit of Startup_phase.connection Startup_phase.network_permit

type t =
  { base_url : Uri.t
  ; auth : Auth.t
  ; mutable snapshot : snapshot
  ; mutable bootstrap : bootstrap_state
  ; e2ee_platform : E2ee_session.platform
  ; mutable e2ee : E2ee_session.t option
  ; mutable e2ee_continuation : e2ee_continuation
  ; mutable transport : transport_state
  ; mutable reconnect_attempt : int
  ; mutable last_resumed_generation : int64
  ; mutable pull : pull_state
  ; mutable frame_application : frame_application
  ; mutable submission : submission_state
  ; mutable recover_after_authoritative_pull : Graph_types.Uuid.t list
  ; mutable local_fast_path : bool
  ; mutable pending_user_reconciliation : (string option * string) option
  ; mutable pending_catalog_reconciliation : Catalog.graph list option
  ; mutable pending_changed_before_presentation : bool
  ; mutable startup_authority : startup_authority
  ; mutable next_permit_id : int64
  ; mutable graph_network_permit : Startup_phase.graph Startup_phase.network_permit option
  ; mutable pending_network_permits : (string * pending_network_permit) list
  ; mutable pending_online_recovery :
      (Startup_phase.online_recovery * recovery_continuation) option
  ; mutable diagnostic_history : diagnostic_history_entry list
  ; mutable next_diagnostic_sequence : int
  }

and transport_state =
  | Foreground_transport of foreground_transport
  | Suspended of
      { lifecycle_generation : int64
      ; transport : foreground_transport
      }

and foreground_transport =
  | Disconnected
  | Awaiting_websocket_token
  | Connecting_websocket
  | Live_websocket of { initialized : bool }
  | Revalidating_websocket of
      { lifecycle_generation : int64
      ; connection_generation : int
      ; initialized : bool
      }
  | Backing_off

and pull_state =
  | Pull_idle
  | Pull_in_flight of { requested_again : bool }

and submission_state =
  | No_submission
  | Deferred_submission of
      { payload : string
      ; tx_ids : Graph_types.Uuid.t list
      }
  | In_flight_submission of
      { payload : string
      ; tx_ids : Graph_types.Uuid.t list
      }

and frame_application =
  | No_frame_application
  | Applying_pull
  | Applying_transaction
  | Applying_control

and bootstrap_state =
  | Bootstrap_idle
  | Awaiting_baseline
  | Awaiting_metadata of Bootstrap.baseline
  | Awaiting_artifact of Bootstrap.baseline * Bootstrap.snapshot_metadata

and e2ee_continuation =
  | No_e2ee_continuation
  | Open_after_e2ee
  | Bootstrap_after_e2ee

and recovery_continuation =
  | Snapshot_recovery
  | E2ee_recovery of e2ee_continuation

let create ~e2ee_platform ~next_challenge_id ~base_url =
  { base_url
  ; auth = Auth.create ~next_id:next_challenge_id ()
  ; bootstrap = Bootstrap_idle
  ; e2ee_platform
  ; e2ee = None
  ; e2ee_continuation = No_e2ee_continuation
  ; transport = Foreground_transport Disconnected
  ; reconnect_attempt = 0
  ; last_resumed_generation = -1L
  ; pull = Pull_idle
  ; frame_application = No_frame_application
  ; submission = No_submission
  ; recover_after_authoritative_pull = []
  ; local_fast_path = false
  ; pending_user_reconciliation = None
  ; pending_catalog_reconciliation = None
  ; pending_changed_before_presentation = false
  ; startup_authority = No_startup_authority
  ; next_permit_id = 0L
  ; graph_network_permit = None
  ; pending_network_permits = []
  ; pending_online_recovery = None
  ; diagnostic_history = []
  ; next_diagnostic_sequence = 1
  ; snapshot =
      { phase = Signed_out
      ; account_generation = 0
      ; graph_generation = 0
      ; connection_generation = 0
      ; user_id = None
      ; catalog = []
      ; selected_graph = None
      ; applied_server_t = None
      ; last_error = None
      ; presentation_generation = 0
      ; startup_presentation = Restoring_local
      }
  }
;;

let snapshot t = t.snapshot
let managed_sync_origin t = Uri.to_string t.base_url

let fresh_permit_id t =
  let permit_id = t.next_permit_id in
  t.next_permit_id <- Int64.succ permit_id;
  permit_id
;;

let current_account_scope t =
  match t.snapshot.user_id with
  | None -> None
  | Some user_id ->
    Startup_phase.account_scope
      ~managed_sync_origin:t.base_url
      ~user_id
      ~account_generation:t.snapshot.account_generation
      ~presentation_generation:t.snapshot.presentation_generation
      ~permit_id:(fresh_permit_id t)
;;

let current_graph_scope t =
  match current_account_scope t, t.snapshot.selected_graph with
  | Some account_scope, Some graph_id ->
    Startup_phase.graph_scope
      account_scope
      ~graph_id:(Graph_types.Uuid.to_string graph_id)
      ~graph_generation:t.snapshot.graph_generation
  | None, _ | Some _, None -> None
;;

let begin_local_restore_authority t =
  t.startup_authority
  <- (match current_graph_scope t with
      | Some graph_scope -> Restoring_authority (Startup_phase.begin_restore graph_scope)
      | None -> No_startup_authority)
;;

let contract_graph (graph : Catalog.graph) : Action.graph = graph
let pack action = Action.pack action

let pack_result operation = function
  | Ok action -> pack action
  | Error `Invalid_payload -> failwith (operation ^ " rejected an internal payload")
  | Error `Scope_mismatch -> failwith (operation ^ " rejected the current scope")
;;

let action_result operation = function
  | Ok action -> action
  | Error `Invalid_payload -> failwith (operation ^ " rejected an internal payload")
  | Error `Scope_mismatch -> failwith (operation ^ " rejected the current scope")
;;

let current_restoring_witness t =
  match t.startup_authority with
  | Restoring_authority restoring -> Some restoring
  | No_startup_authority | Presented_authority _ -> None
;;

let begin_graph_authority t =
  begin_local_restore_authority t;
  t.graph_network_permit <- None;
  t.pending_online_recovery <- None
;;

let current_graph_permit t =
  match t.graph_network_permit with
  | None -> None
  | Some permit ->
    let scope = Startup_phase.permit_graph_scope permit in
    if
      Startup_phase.graph_scope_matches
        scope
        ~account_generation:t.snapshot.account_generation
        ~graph_generation:t.snapshot.graph_generation
        ~presentation_generation:t.snapshot.presentation_generation
    then Some permit
    else None
;;

let current_connection_permit t ~lifecycle_generation =
  match current_graph_permit t with
  | None -> None
  | Some graph_permit ->
    let graph_scope = Startup_phase.permit_graph_scope graph_permit in
    Option.bind
      (Startup_phase.connection_scope
         graph_scope
         ~connection_generation:t.snapshot.connection_generation
         ~lifecycle_generation)
      (Startup_phase.connection_permit graph_permit)
;;

let current_account_permit t =
  match current_graph_permit t with
  | Some graph_permit -> Some (Startup_phase.account_permit graph_permit)
  | None ->
    Option.bind (current_account_scope t) (fun scope ->
      Startup_phase.begin_account_recovery scope
      |> Startup_phase.permit_account_recovery
      |> Result.to_option)
;;

let store_pending_permit t challenge_id permit =
  t.pending_network_permits
  <- (challenge_id, permit) :: List.remove_assoc challenge_id t.pending_network_permits
;;

let take_pending_permit t challenge_id =
  let permit = List.assoc_opt challenge_id t.pending_network_permits in
  t.pending_network_permits <- List.remove_assoc challenge_id t.pending_network_permits;
  permit
;;

let clear_network_authority t =
  t.graph_network_permit <- None;
  t.pending_network_permits <- [];
  t.pending_online_recovery <- None
;;

let valid_local_account t ~user_id ~managed_sync_origin:expected_origin =
  String.length user_id > 0
  && String.length user_id <= 512
  && String.is_valid_utf_8 user_id
  && (not (String.contains user_id '\000'))
  && String.equal expected_origin (managed_sync_origin t)
;;

let before_timeline_presented t =
  match t.startup_authority with
  | Restoring_authority _ -> true
  | No_startup_authority | Presented_authority _ -> false
;;

let clear_pending_reconciliation t =
  t.pending_user_reconciliation <- None;
  t.pending_catalog_reconciliation <- None;
  t.pending_changed_before_presentation <- false
;;

let is_backgrounded t =
  match t.transport with
  | Foreground_transport _ -> false
  | Suspended _ -> true
;;

let current_transport t =
  match t.transport with
  | Foreground_transport transport | Suspended { transport; _ } -> transport
;;

let set_current_transport t transport =
  t.transport
  <- (match t.transport with
      | Foreground_transport _ -> Foreground_transport transport
      | Suspended suspended -> Suspended { suspended with transport })
;;

let pull_is_idle = function
  | Pull_idle -> true
  | Pull_in_flight _ -> false
;;

let clear_transport_coordination t =
  set_current_transport t Disconnected;
  t.pull <- Pull_idle;
  t.frame_application <- No_frame_application;
  t.submission <- No_submission;
  t.recover_after_authoritative_pull <- []
;;

let with_connection_permit t ~lifecycle_generation operation constructor =
  match current_connection_permit t ~lifecycle_generation with
  | None -> failwith (operation ^ " requires a current connection permit")
  | Some permit -> constructor permit |> pack_result operation
;;

let send_websocket_action t payload =
  with_connection_permit
    t
    ~lifecycle_generation:(Int64.max 0L t.last_resumed_generation)
    "WebSocket send"
    (fun permit -> Action.send_websocket permit ~payload)
;;

let schedule_reconnect_action t delay_seconds =
  with_connection_permit
    t
    ~lifecycle_generation:(Int64.max 0L t.last_resumed_generation)
    "reconnect scheduling"
    (fun permit -> Action.schedule_reconnect permit ~delay_seconds)
;;

let schedule_foreground_probe_action t ~lifecycle_generation ~delay_seconds =
  with_connection_permit
    t
    ~lifecycle_generation
    "foreground probe scheduling"
    (fun permit -> Action.schedule_foreground_probe permit ~delay_seconds)
;;

let apply_sync_frame_action t frame =
  with_connection_permit
    t
    ~lifecycle_generation:(Int64.max 0L t.last_resumed_generation)
    "sync frame application"
    (fun permit -> Action.apply_sync_frame permit ~frame)
;;

let recover_submitted_action t transaction_ids =
  with_connection_permit
    t
    ~lifecycle_generation:(Int64.max 0L t.last_resumed_generation)
    "submitted transaction recovery"
    (fun permit ->
       Action.recover_submitted
         permit
         ~transaction_ids:(List.map Graph_types.Uuid.to_string transaction_ids))
;;

let remember_uncertain_submission t =
  match t.submission with
  | In_flight_submission { tx_ids; _ } ->
    t.recover_after_authoritative_pull <- tx_ids;
    t.submission <- No_submission
  | No_submission | Deferred_submission _ -> ()
;;

let pull_payload t =
  Protocol.encode_pull ~since:(Option.value t.snapshot.applied_server_t ~default:0)
;;

let request_pull t =
  if not (pull_is_idle t.pull)
  then (
    t.pull <- Pull_in_flight { requested_again = true };
    [])
  else (
    match current_transport t with
    | Live_websocket { initialized = true } | Revalidating_websocket _ ->
      t.pull <- Pull_in_flight { requested_again = false };
      [ send_websocket_action t (pull_payload t) ]
    | Disconnected | Awaiting_websocket_token | Connecting_websocket
    | Live_websocket { initialized = false }
    | Backing_off -> [])
;;

let decode_submission payload =
  Result.map (fun tx_ids -> payload, tx_ids) (Protocol.decode_tx_batch_ids payload)
;;

let defer_submission t payload tx_ids =
  t.submission <- Deferred_submission { payload; tx_ids };
  []
;;

let send_submission t payload tx_ids =
  t.submission <- In_flight_submission { payload; tx_ids };
  [ send_websocket_action t payload ]
;;

let challenge t purpose =
  if is_backgrounded t
  then []
  else (
    match t.snapshot.user_id with
    | None -> []
    | Some user_id ->
      (match purpose with
       | Auth.Websocket_connect -> set_current_transport t Awaiting_websocket_token
       | Catalog_discovery | Snapshot_bootstrap | E2ee_key_access -> ());
      let graph_generation, connection_generation =
        match purpose with
        | Auth.Catalog_discovery -> None, None
        | Snapshot_bootstrap | E2ee_key_access -> Some t.snapshot.graph_generation, None
        | Websocket_connect ->
          Some t.snapshot.graph_generation, Some t.snapshot.connection_generation
      in
      let challenge =
        Auth.issue
          t.auth
          ~purpose
          ~user_id
          ~account_generation:t.snapshot.account_generation
          ~graph_generation
          ~connection_generation
      in
      let typed_action =
        match purpose with
        | Auth.Catalog_discovery ->
          current_account_permit t
          |> Option.map (fun permit ->
            store_pending_permit t challenge.challenge_id (Pending_account_permit permit);
            Action.need_id_token
              permit
              ~challenge_id:challenge.challenge_id
              Action.Catalog_discovery
            |> pack_result "catalog token challenge")
        | Snapshot_bootstrap ->
          current_graph_permit t
          |> Option.map (fun permit ->
            store_pending_permit t challenge.challenge_id (Pending_graph_permit permit);
            Action.need_id_token
              permit
              ~challenge_id:challenge.challenge_id
              Action.Snapshot_bootstrap
            |> pack_result "snapshot token challenge")
        | E2ee_key_access ->
          current_graph_permit t
          |> Option.map (fun permit ->
            store_pending_permit t challenge.challenge_id (Pending_graph_permit permit);
            Action.need_id_token
              permit
              ~challenge_id:challenge.challenge_id
              Action.E2ee_key_access
            |> pack_result "E2EE token challenge")
        | Websocket_connect ->
          current_connection_permit
            t
            ~lifecycle_generation:(Int64.max 0L t.last_resumed_generation)
          |> Option.map (fun permit ->
            store_pending_permit
              t
              challenge.challenge_id
              (Pending_connection_permit permit);
            Action.need_id_token
              permit
              ~challenge_id:challenge.challenge_id
              Action.Websocket_connect
            |> pack_result "WebSocket token challenge")
      in
      (match typed_action with
       | None ->
         ignore (Auth.fail t.auth ~challenge_id:challenge.challenge_id);
         []
       | Some action ->
         if
           (not (before_timeline_presented t))
           && (purpose <> Auth.Catalog_discovery || t.snapshot.selected_graph = None)
         then t.snapshot <- { t.snapshot with phase = Awaiting_token purpose };
         [ action ]))
;;

let route_submission t payload =
  match t.submission with
  | Deferred_submission _ | In_flight_submission _ -> []
  | No_submission ->
    (match decode_submission payload with
     | Error message ->
       t.snapshot <- { t.snapshot with phase = Sync_paused; last_error = Some message };
       []
     | Ok (payload, tx_ids) ->
       if is_backgrounded t
       then defer_submission t payload tx_ids
       else (
         match current_transport t with
         | Live_websocket { initialized = true } -> send_submission t payload tx_ids
         | Revalidating_websocket _ | Awaiting_websocket_token | Connecting_websocket ->
           defer_submission t payload tx_ids
         | Disconnected | Live_websocket { initialized = false } | Backing_off ->
           defer_submission t payload tx_ids))
;;

let selected t =
  match t.snapshot.selected_graph with
  | None -> None
  | Some graph_id ->
    List.find_opt
      (fun graph -> Graph_types.Uuid.equal graph.Catalog.graph_id graph_id)
      t.snapshot.catalog
;;

let close_graph_action = pack Action.close_graph
let close_websocket_action = pack Action.close_websocket

let inspect_mirror_action t graph =
  match current_restoring_witness t with
  | None -> failwith "mirror inspection requires a restoring witness"
  | Some restoring ->
    let request = Startup_phase.request_mirror restoring in
    Action.inspect_mirror request (contract_graph graph)
    |> pack_result "mirror inspection"
;;

let load_wrapped_graph_key_local_action t =
  match current_restoring_witness t with
  | None -> failwith "wrapped-key lookup requires a restoring witness"
  | Some restoring ->
    let wrapped_key_request = Startup_phase.request_wrapped_graph_key restoring in
    let private_key_request = Startup_phase.request_local_private_key restoring in
    Action.load_and_verify_wrapped_graph_key wrapped_key_request private_key_request
    |> action_result "wrapped-key lookup"
;;

let open_graph_local_action t graph encrypted_graph_key =
  match current_restoring_witness t with
  | None -> failwith "graph open requires a restoring witness"
  | Some restoring ->
    let request = Startup_phase.request_graph_open restoring in
    Action.open_graph request (contract_graph graph) ~encrypted_graph_key
    |> action_result "graph open"
;;

let open_graph_action t graph encrypted_graph_key =
  pack (open_graph_local_action t graph encrypted_graph_key)
;;

let graph_scope_for_id t graph_id =
  Option.bind (current_account_scope t) (fun account_scope ->
    Startup_phase.graph_scope
      account_scope
      ~graph_id:(Graph_types.Uuid.to_string graph_id)
      ~graph_generation:t.snapshot.graph_generation)
;;

let delete_mirror_action t graph_id =
  match graph_scope_for_id t graph_id with
  | Some scope -> pack (Action.delete_mirror scope)
  | None -> failwith "mirror deletion requires a current account scope"
;;

let delete_wrapped_graph_key_action t graph_id =
  match graph_scope_for_id t graph_id with
  | Some scope -> pack (Action.delete_wrapped_graph_key scope)
  | None -> failwith "wrapped-key deletion requires a current account scope"
;;

let delete_account_secrets_action scope = pack (Action.delete_account_secrets scope)

let verify_and_save_wrapped_graph_key_action t encrypted_graph_key =
  match current_graph_scope t with
  | None -> failwith "wrapped-key save requires a current graph scope"
  | Some scope ->
    pack (Action.verify_and_save_wrapped_graph_key scope encrypted_graph_key)
;;

let authorize_recovery t receipt =
  match current_restoring_witness t with
  | Some restoring -> Startup_phase.recover restoring receipt
  | None -> None
;;

let authorize_local_secret_recovery t = function
  | Wrapped_key_failure_receipt receipt -> authorize_recovery t receipt
  | Private_key_failure_receipt receipt -> authorize_recovery t receipt
;;

let stage_online_recovery t recovery continuation ~diagnostic =
  t.pending_online_recovery <- Some (recovery, continuation);
  t.snapshot
  <- { t.snapshot with
       phase = Recovering_online (Startup_phase.recovery_reason recovery)
     ; last_error = Some diagnostic
     };
  []
;;

let clear_e2ee t =
  Option.iter E2ee_session.clear t.e2ee;
  t.e2ee <- None;
  t.e2ee_continuation <- No_e2ee_continuation
;;

let start_e2ee t graph continuation =
  match t.snapshot.user_id with
  | None -> []
  | Some user_id ->
    clear_e2ee t;
    t.e2ee_continuation <- continuation;
    t.e2ee
    <- Some
         (E2ee_session.create
            ~platform:t.e2ee_platform
            ~managed_sync_origin:t.base_url
            ~user_id
            ~graph_id:graph.Catalog.graph_id
            ~graph_name:graph.name);
    challenge t Auth.E2ee_key_access
;;

let open_selected_graph_local t ~account_generation ~graph_generation graph
  : Action.local Action.t list
  =
  ignore account_generation;
  ignore graph_generation;
  if graph.Catalog.encrypted
  then [ load_wrapped_graph_key_local_action t ]
  else (
    t.snapshot <- { t.snapshot with phase = Opening_graph };
    [ open_graph_local_action t graph None ])
;;

let open_selected_graph t ~account_generation ~graph_generation graph =
  open_selected_graph_local t ~account_generation ~graph_generation graph |> List.map pack
;;

let resume_after_e2ee t graph encrypted_graph_key =
  match t.e2ee_continuation with
  | No_e2ee_continuation -> []
  | Open_after_e2ee ->
    t.e2ee_continuation <- No_e2ee_continuation;
    t.snapshot <- { t.snapshot with phase = Opening_graph; last_error = None };
    (match Action.wrapped_graph_key_of_string encrypted_graph_key with
     | Some encrypted_graph_key ->
       [ open_graph_action t graph (Some encrypted_graph_key) ]
     | None -> failwith "E2EE session returned invalid wrapped key")
  | Bootstrap_after_e2ee ->
    t.e2ee_continuation <- No_e2ee_continuation;
    t.bootstrap <- Awaiting_baseline;
    t.snapshot <- { t.snapshot with phase = Bootstrapping; last_error = None };
    challenge t Auth.Snapshot_bootstrap
;;

let close_graph_effects t =
  match t.snapshot.selected_graph with
  | None -> []
  | Some _ -> [ close_websocket_action; close_graph_action ]
;;

let schedule_reconnect t =
  if is_backgrounded t
  then []
  else (
    match t.snapshot.user_id, t.snapshot.selected_graph, t.snapshot.applied_server_t with
    | Some _, Some _, Some _ ->
      let delay_seconds = min 30. (2. ** Float.of_int t.reconnect_attempt) in
      t.reconnect_attempt <- min 30 (t.reconnect_attempt + 1);
      [ schedule_reconnect_action t delay_seconds ]
    | None, _, _ | Some _, None, _ | Some _, Some _, None -> [])
;;

let fence_transport t ?last_error () =
  remember_uncertain_submission t;
  Auth.cancel_all t.auth;
  set_current_transport t Backing_off;
  t.pull <- Pull_idle;
  t.frame_application <- No_frame_application;
  t.snapshot
  <- { t.snapshot with
       connection_generation = t.snapshot.connection_generation + 1
     ; last_error
     }
;;

let begin_scheduled_reconnect t ~message =
  fence_transport t ~last_error:message ();
  schedule_reconnect t
;;

let begin_failed_socket_reconnect t ~message =
  fence_transport t ~last_error:message ();
  close_websocket_action :: (if is_backgrounded t then [] else schedule_reconnect t)
;;

let provide_token
      t
      ~challenge_id
      ~user_id
      ~account_generation
      ~graph_generation
      ~connection_generation
      ~token
  =
  match
    Auth.provide
      t.auth
      ~challenge_id
      ~user_id
      ~account_generation
      ~graph_generation
      ~connection_generation
      ~token
  with
  | Error _ -> []
  | Ok (challenge, token) ->
    let pending_permit = take_pending_permit t challenge.challenge_id in
    (match challenge.purpose, pending_permit with
     | Auth.Catalog_discovery, Some (Pending_account_permit permit) ->
       if t.snapshot.selected_graph = None
       then t.snapshot <- { t.snapshot with phase = Loading_catalog };
       [ Action.fetch_catalog permit ~token |> pack_result "catalog fetch" ]
     | Websocket_connect, Some (Pending_connection_permit permit) ->
       (match t.snapshot.selected_graph with
        | None -> []
        | Some _ ->
          set_current_transport t Connecting_websocket;
          [ Action.connect_websocket permit ~token |> pack_result "WebSocket connect" ])
     | Snapshot_bootstrap, Some (Pending_graph_permit permit) ->
       (match selected t with
        | None -> []
        | Some graph ->
          let graph = contract_graph graph in
          (match t.bootstrap with
           | Awaiting_baseline ->
             [ Action.fetch_snapshot_baseline permit graph ~token
               |> pack_result "snapshot baseline fetch"
             ]
           | Awaiting_metadata _ ->
             [ Action.fetch_snapshot_metadata permit graph ~token
               |> pack_result "snapshot metadata fetch"
             ]
           | Awaiting_artifact (baseline, metadata) ->
             let baseline = Action.{ server_t = baseline.server_t } in
             let metadata =
               Action.
                 { key = metadata.key
                 ; url = metadata.url
                 ; content_encoding =
                     Option.value metadata.content_encoding ~default:`Identity
                 }
             in
             [ Action.download_snapshot_artifact permit graph ~baseline ~metadata ~token
               |> pack_result "snapshot artifact download"
             ]
           | Bootstrap_idle -> []))
     | E2ee_key_access, Some (Pending_graph_permit permit) ->
       (match selected t, t.e2ee with
        | Some graph, Some session ->
          (match E2ee_session.phase session with
           | Fetching_graph_key ->
             [ Action.fetch_e2ee_graph_key permit (contract_graph graph) ~token
               |> pack_result "E2EE graph key fetch"
             ]
           | Fetching_user_keys ->
             [ Action.fetch_e2ee_user_keys permit ~token
               |> pack_result "E2EE user key fetch"
             ]
           | Awaiting_password | Ready | Failed -> [])
        | _, _ -> [])
     | (Catalog_discovery | Snapshot_bootstrap | E2ee_key_access | Websocket_connect), _
       -> [])
;;

let install_account t ~user_id ~local_fast_path =
  let closing = close_graph_effects t in
  let cleanup =
    current_account_scope t |> Option.map delete_account_secrets_action |> Option.to_list
  in
  Auth.cancel_all t.auth;
  t.bootstrap <- Bootstrap_idle;
  clear_e2ee t;
  t.reconnect_attempt <- 0;
  clear_transport_coordination t;
  clear_pending_reconciliation t;
  t.startup_authority <- No_startup_authority;
  clear_network_authority t;
  t.local_fast_path <- local_fast_path;
  t.snapshot
  <- { phase = Signed_out
     ; account_generation = t.snapshot.account_generation + 1
     ; graph_generation = 0
     ; connection_generation = 0
     ; user_id = Some user_id
     ; catalog = []
     ; selected_graph = None
     ; applied_server_t = None
     ; last_error = None
     ; presentation_generation = t.snapshot.presentation_generation + 1
     ; startup_presentation = (if local_fast_path then Restoring_local else Reconciled)
     };
  closing @ cleanup
;;

let release_deferred_pull t =
  match current_transport t, t.snapshot.applied_server_t with
  | Live_websocket { initialized = false }, Some _ ->
    set_current_transport t (Live_websocket { initialized = true });
    t.pull <- Pull_in_flight { requested_again = false };
    t.pending_changed_before_presentation <- false;
    [ send_websocket_action t (pull_payload t) ]
  | Live_websocket { initialized = true }, Some _
    when t.pending_changed_before_presentation ->
    t.pending_changed_before_presentation <- false;
    request_pull t
  | ( ( Disconnected
      | Awaiting_websocket_token
      | Connecting_websocket
      | Revalidating_websocket _
      | Backing_off
      | Live_websocket _ )
    , _ ) -> []
;;

let release_post_presentation_network t =
  match current_transport t, t.snapshot.applied_server_t with
  | Disconnected, Some _ -> challenge t Auth.Websocket_connect
  | _ -> release_deferred_pull t
;;

let apply_catalog_loaded t ~release_network graphs =
  match t.snapshot.selected_graph with
  | None ->
    t.snapshot
    <- { t.snapshot with phase = Awaiting_selection; catalog = graphs; last_error = None };
    []
  | Some selected_graph ->
    (match
       List.find_opt
         (fun graph -> Graph_types.Uuid.equal graph.Catalog.graph_id selected_graph)
         graphs
     with
     | Some graph when t.snapshot.phase = Failed && t.snapshot.applied_server_t = None ->
       Auth.cancel_all t.auth;
       t.bootstrap <- Bootstrap_idle;
       clear_e2ee t;
       t.reconnect_attempt <- 0;
       let graph_generation = t.snapshot.graph_generation + 1 in
       t.snapshot
       <- { t.snapshot with
            phase = Bootstrapping
          ; graph_generation
          ; connection_generation = t.snapshot.connection_generation + 1
          ; catalog = graphs
          ; last_error = None
          };
       begin_graph_authority t;
       [ close_websocket_action; close_graph_action; inspect_mirror_action t graph ]
     | Some _ ->
       t.snapshot <- { t.snapshot with catalog = graphs; last_error = None };
       if release_network then release_post_presentation_network t else []
     | None ->
       let secret_cleanup =
         match selected t with
         | Some graph when graph.encrypted ->
           [ delete_wrapped_graph_key_action t selected_graph ]
         | None | Some _ -> []
       in
       Auth.cancel_all t.auth;
       t.bootstrap <- Bootstrap_idle;
       clear_e2ee t;
       t.reconnect_attempt <- 0;
       t.snapshot
       <- { t.snapshot with
            phase = Awaiting_selection
          ; graph_generation = t.snapshot.graph_generation + 1
          ; connection_generation = t.snapshot.connection_generation + 1
          ; catalog = graphs
          ; selected_graph = None
          ; applied_server_t = None
          ; last_error = None
          };
       t.startup_authority <- No_startup_authority;
       clear_network_authority t;
       [ close_websocket_action; close_graph_action ] @ secret_cleanup)
;;

let phase_name = function
  | Signed_out -> "Signed_out"
  | Awaiting_token _ -> "Awaiting_token"
  | Loading_catalog -> "Loading_catalog"
  | Awaiting_selection -> "Awaiting_selection"
  | Bootstrapping -> "Bootstrapping"
  | Recovering_online _ -> "Recovering_online"
  | Awaiting_e2ee_password -> "Awaiting_e2ee_password"
  | Opening_graph -> "Opening_graph"
  | Graph_open -> "Graph_open"
  | Sync_paused -> "Sync_paused"
  | Stopping_graph -> "Stopping_graph"
  | Failed -> "Failed"
;;

let startup_presentation_name = function
  | Restoring_local -> "Restoring_local"
  | Local_feed_ready -> "Local_feed_ready"
  | Timeline_presented -> "Timeline_presented"
  | Reconciled -> "Reconciled"
;;

let diagnostic_transport_scope_name (scope : diagnostic_transport_scope) =
  match scope with
  | Foreground -> "Foreground"
  | Suspended -> "Suspended"
;;

let diagnostic_transport_name (transport : diagnostic_transport) =
  match transport with
  | Disconnected -> "Disconnected"
  | Awaiting_token -> "Awaiting_token"
  | Connecting -> "Connecting"
  | Live -> "Live"
  | Revalidating -> "Revalidating"
  | Backing_off -> "Backing_off"
;;

let diagnostic_pull_name (pull : diagnostic_pull) =
  match pull with
  | Diagnostic_pull_idle -> "Idle"
  | Diagnostic_pull_in_flight { requested_again = false } -> "In flight"
  | Diagnostic_pull_in_flight { requested_again = true } -> "In flight (requested again)"
;;

let transaction_count count =
  Printf.sprintf "%d transaction%s" count (if count = 1 then "" else "s")
;;

let diagnostic_submission_name (submission : diagnostic_submission) =
  match submission with
  | Diagnostic_submission_none -> "None"
  | Diagnostic_submission_deferred count ->
    Printf.sprintf "Deferred (%s)" (transaction_count count)
  | Diagnostic_submission_in_flight count ->
    Printf.sprintf "In flight (%s)" (transaction_count count)
;;

let diagnostic_serialization_name (serialization : diagnostic_serialization) =
  match serialization with
  | Diagnostic_serialization_idle -> "Idle"
  | Diagnostic_serialization_applying_pull -> "Applying pull"
  | Diagnostic_serialization_applying_transaction -> "Applying transaction"
  | Diagnostic_serialization_applying_control -> "Applying control"
;;

let diagnostic_change_category_name = function
  | Manager_phase_changed -> "Manager phase"
  | Startup_presentation_changed -> "Startup presentation"
  | Account_generation_changed -> "Account generation"
  | Graph_generation_changed -> "Graph generation"
  | Presentation_generation_changed -> "Presentation generation"
  | Connection_generation_changed -> "Connection generation"
  | Graph_selection_changed -> "Graph selection"
  | Transport_scope_changed -> "Transport scope"
  | Transport_changed -> "Transport"
  | Websocket_initialization_changed -> "WebSocket initialization"
  | Pull_changed -> "Pull"
  | Submission_changed -> "Submission"
  | Reconnect_attempt_changed -> "Reconnect attempt"
  | Uncertain_transaction_count_changed -> "Uncertain transactions"
  | Applied_server_t_changed -> "Applied server transaction"
  | Serialization_changed -> "Serialization"
  | Error_changed -> "Error"
;;

let diagnostic_transport_scope t : diagnostic_transport_scope =
  match t.transport with
  | Foreground_transport _ -> Foreground
  | Suspended _ -> Suspended
;;

let diagnostic_transport t : diagnostic_transport =
  match current_transport t with
  | Disconnected -> Disconnected
  | Awaiting_websocket_token -> Awaiting_token
  | Connecting_websocket -> Connecting
  | Live_websocket _ -> Live
  | Revalidating_websocket _ -> Revalidating
  | Backing_off -> Backing_off
;;

let diagnostic_websocket_initialized t =
  match current_transport t with
  | Live_websocket { initialized } | Revalidating_websocket { initialized; _ } ->
    Some initialized
  | Disconnected | Awaiting_websocket_token | Connecting_websocket | Backing_off -> None
;;

let diagnostic_pull t =
  match t.pull with
  | Pull_idle -> Diagnostic_pull_idle
  | Pull_in_flight { requested_again } -> Diagnostic_pull_in_flight { requested_again }
;;

let diagnostic_submission t =
  match t.submission with
  | No_submission -> Diagnostic_submission_none
  | Deferred_submission { tx_ids; _ } ->
    Diagnostic_submission_deferred (List.length tx_ids)
  | In_flight_submission { tx_ids; _ } ->
    Diagnostic_submission_in_flight (List.length tx_ids)
;;

let diagnostic_serialization t =
  match t.frame_application with
  | No_frame_application -> Diagnostic_serialization_idle
  | Applying_pull -> Diagnostic_serialization_applying_pull
  | Applying_transaction -> Diagnostic_serialization_applying_transaction
  | Applying_control -> Diagnostic_serialization_applying_control
;;

let current_diagnostics t : diagnostics =
  { phase = t.snapshot.phase
  ; startup_presentation = t.snapshot.startup_presentation
  ; account_generation = t.snapshot.account_generation
  ; graph_generation = t.snapshot.graph_generation
  ; presentation_generation = t.snapshot.presentation_generation
  ; connection_generation = t.snapshot.connection_generation
  ; graph_selected = Option.is_some t.snapshot.selected_graph
  ; selected_graph = t.snapshot.selected_graph
  ; applied_server_t = t.snapshot.applied_server_t
  ; transport_scope = diagnostic_transport_scope t
  ; transport = diagnostic_transport t
  ; websocket_initialized = diagnostic_websocket_initialized t
  ; pull = diagnostic_pull t
  ; submission = diagnostic_submission t
  ; reconnect_attempt = t.reconnect_attempt
  ; uncertain_transaction_count = List.length t.recover_after_authoritative_pull
  ; serialization = diagnostic_serialization t
  ; pending_token_challenge_count = Auth.pending_count t.auth
  ; last_error = t.snapshot.last_error
  ; history = t.diagnostic_history
  }
;;

type diagnostic_projection =
  { diagnostic_phase : phase
  ; diagnostic_startup_presentation : startup_presentation
  ; diagnostic_account_generation : int
  ; diagnostic_graph_generation : int
  ; diagnostic_presentation_generation : int
  ; diagnostic_connection_generation : int
  ; diagnostic_graph_selected : bool
  ; diagnostic_applied_server_t : int option
  ; diagnostic_transport_scope : diagnostic_transport_scope
  ; diagnostic_transport : diagnostic_transport
  ; diagnostic_websocket_initialized : bool option
  ; diagnostic_pull : diagnostic_pull
  ; diagnostic_submission : diagnostic_submission
  ; diagnostic_reconnect_attempt : int
  ; diagnostic_uncertain_transaction_count : int
  ; diagnostic_serialization : diagnostic_serialization
  ; diagnostic_last_error : string option
  }

let diagnostic_projection t =
  let diagnostics = current_diagnostics t in
  { diagnostic_phase = diagnostics.phase
  ; diagnostic_startup_presentation = diagnostics.startup_presentation
  ; diagnostic_account_generation = diagnostics.account_generation
  ; diagnostic_graph_generation = diagnostics.graph_generation
  ; diagnostic_presentation_generation = diagnostics.presentation_generation
  ; diagnostic_connection_generation = diagnostics.connection_generation
  ; diagnostic_graph_selected = diagnostics.graph_selected
  ; diagnostic_applied_server_t = diagnostics.applied_server_t
  ; diagnostic_transport_scope = diagnostics.transport_scope
  ; diagnostic_transport = diagnostics.transport
  ; diagnostic_websocket_initialized = diagnostics.websocket_initialized
  ; diagnostic_pull = diagnostics.pull
  ; diagnostic_submission = diagnostics.submission
  ; diagnostic_reconnect_attempt = diagnostics.reconnect_attempt
  ; diagnostic_uncertain_transaction_count = diagnostics.uncertain_transaction_count
  ; diagnostic_serialization = diagnostics.serialization
  ; diagnostic_last_error = diagnostics.last_error
  }
;;

let optional_int_name = function
  | None -> "None"
  | Some value -> string_of_int value
;;

let optional_bool_name = function
  | None -> "Not available"
  | Some value -> string_of_bool value
;;

let graph_selection_name selected = if selected then "Selected" else "None"

let diagnostic_changes before after =
  let add category before after changes = { category; before; after } :: changes in
  let changes = [] in
  let changes =
    if before.diagnostic_phase = after.diagnostic_phase
    then changes
    else
      add
        Manager_phase_changed
        (phase_name before.diagnostic_phase)
        (phase_name after.diagnostic_phase)
        changes
  in
  let changes =
    if before.diagnostic_startup_presentation = after.diagnostic_startup_presentation
    then changes
    else
      add
        Startup_presentation_changed
        (startup_presentation_name before.diagnostic_startup_presentation)
        (startup_presentation_name after.diagnostic_startup_presentation)
        changes
  in
  let add_int category before after changes =
    if before = after
    then changes
    else add category (string_of_int before) (string_of_int after) changes
  in
  let changes =
    add_int
      Account_generation_changed
      before.diagnostic_account_generation
      after.diagnostic_account_generation
      changes
  in
  let changes =
    add_int
      Graph_generation_changed
      before.diagnostic_graph_generation
      after.diagnostic_graph_generation
      changes
  in
  let changes =
    add_int
      Presentation_generation_changed
      before.diagnostic_presentation_generation
      after.diagnostic_presentation_generation
      changes
  in
  let changes =
    add_int
      Connection_generation_changed
      before.diagnostic_connection_generation
      after.diagnostic_connection_generation
      changes
  in
  let changes =
    if before.diagnostic_graph_selected = after.diagnostic_graph_selected
    then changes
    else
      add
        Graph_selection_changed
        (graph_selection_name before.diagnostic_graph_selected)
        (graph_selection_name after.diagnostic_graph_selected)
        changes
  in
  let changes =
    if before.diagnostic_transport_scope = after.diagnostic_transport_scope
    then changes
    else
      add
        Transport_scope_changed
        (diagnostic_transport_scope_name before.diagnostic_transport_scope)
        (diagnostic_transport_scope_name after.diagnostic_transport_scope)
        changes
  in
  let changes =
    if before.diagnostic_transport = after.diagnostic_transport
    then changes
    else
      add
        Transport_changed
        (diagnostic_transport_name before.diagnostic_transport)
        (diagnostic_transport_name after.diagnostic_transport)
        changes
  in
  let changes =
    if before.diagnostic_websocket_initialized = after.diagnostic_websocket_initialized
    then changes
    else
      add
        Websocket_initialization_changed
        (optional_bool_name before.diagnostic_websocket_initialized)
        (optional_bool_name after.diagnostic_websocket_initialized)
        changes
  in
  let changes =
    if before.diagnostic_pull = after.diagnostic_pull
    then changes
    else
      add
        Pull_changed
        (diagnostic_pull_name before.diagnostic_pull)
        (diagnostic_pull_name after.diagnostic_pull)
        changes
  in
  let changes =
    if before.diagnostic_submission = after.diagnostic_submission
    then changes
    else
      add
        Submission_changed
        (diagnostic_submission_name before.diagnostic_submission)
        (diagnostic_submission_name after.diagnostic_submission)
        changes
  in
  let changes =
    add_int
      Reconnect_attempt_changed
      before.diagnostic_reconnect_attempt
      after.diagnostic_reconnect_attempt
      changes
  in
  let changes =
    add_int
      Uncertain_transaction_count_changed
      before.diagnostic_uncertain_transaction_count
      after.diagnostic_uncertain_transaction_count
      changes
  in
  let changes =
    if before.diagnostic_applied_server_t = after.diagnostic_applied_server_t
    then changes
    else
      add
        Applied_server_t_changed
        (optional_int_name before.diagnostic_applied_server_t)
        (optional_int_name after.diagnostic_applied_server_t)
        changes
  in
  let changes =
    if before.diagnostic_serialization = after.diagnostic_serialization
    then changes
    else
      add
        Serialization_changed
        (diagnostic_serialization_name before.diagnostic_serialization)
        (diagnostic_serialization_name after.diagnostic_serialization)
        changes
  in
  let changes =
    match before.diagnostic_last_error, after.diagnostic_last_error with
    | None, None -> changes
    | Some before, Some after when String.equal before after -> changes
    | None, Some _ -> add Error_changed "None" "set" changes
    | Some _, None -> add Error_changed "set" "cleared" changes
    | Some _, Some _ -> add Error_changed "set" "changed" changes
  in
  List.rev changes
;;

let append_diagnostic_history t changes =
  if changes <> []
  then (
    let entry = { sequence = t.next_diagnostic_sequence; changes } in
    t.next_diagnostic_sequence <- t.next_diagnostic_sequence + 1;
    let history = t.diagnostic_history @ [ entry ] in
    t.diagnostic_history
    <- (if List.length history > 64 then List.tl history else history))
;;

let record_diagnostic_transition t ~before_user ~before ~reset =
  if reset || before_user <> t.snapshot.user_id
  then t.diagnostic_history <- []
  else append_diagnostic_history t (diagnostic_changes before (diagnostic_projection t))
;;

let rec handle_command_internal t = function
  | Restore_local_account { user_id; managed_sync_origin = origin } ->
    if not (valid_local_account t ~user_id ~managed_sync_origin:origin)
    then []
    else if t.snapshot.user_id = Some user_id && t.local_fast_path
    then []
    else install_account t ~user_id ~local_fast_path:true
  | Reconcile_authenticated_user { user_id; managed_sync_origin = origin } ->
    if not (String.equal origin (managed_sync_origin t))
    then []
    else if before_timeline_presented t
    then (
      t.pending_user_reconciliation <- Some (user_id, origin);
      [])
    else (
      match user_id, t.snapshot.user_id with
      | Some user_id, Some current when String.equal user_id current ->
        challenge t Auth.Catalog_discovery
      | Some user_id, None | Some user_id, Some _ ->
        let closing = install_account t ~user_id ~local_fast_path:false in
        closing @ challenge t Auth.Catalog_discovery
      | None, _ -> handle_command_internal t Signed_out_command)
  | Local_feed_ready { account_generation; graph_generation; presentation_generation }
    when t.snapshot.account_generation = account_generation
         && t.snapshot.graph_generation = graph_generation
         && t.snapshot.presentation_generation = presentation_generation
         && before_timeline_presented t ->
    t.snapshot <- { t.snapshot with startup_presentation = Local_feed_ready };
    []
  | Local_feed_ready _ -> []
  | Timeline_presented { account_generation; graph_generation; presentation_generation }
    when t.snapshot.account_generation = account_generation
         && t.snapshot.graph_generation = graph_generation
         && t.snapshot.presentation_generation = presentation_generation
         && t.snapshot.startup_presentation = Local_feed_ready ->
    (match t.startup_authority with
     | Restoring_authority restoring ->
       (match
          Startup_phase.acknowledge_timeline
            restoring
            { account_generation; graph_generation; presentation_generation }
        with
        | None -> []
        | Some presented ->
          t.startup_authority <- Presented_authority presented;
          t.graph_network_permit <- Some (Startup_phase.permit_reconciliation presented);
          t.snapshot <- { t.snapshot with startup_presentation = Timeline_presented };
          (match t.pending_user_reconciliation with
           | Some (user_id, managed_sync_origin) ->
             clear_pending_reconciliation t;
             t.snapshot <- { t.snapshot with startup_presentation = Reconciled };
             handle_command_internal
               t
               (Reconcile_authenticated_user { user_id; managed_sync_origin })
           | None ->
             (match t.pending_catalog_reconciliation with
              | Some graphs ->
                t.pending_catalog_reconciliation <- None;
                t.snapshot <- { t.snapshot with startup_presentation = Reconciled };
                apply_catalog_loaded t ~release_network:true graphs
              | None -> release_post_presentation_network t)))
     | No_startup_authority | Presented_authority _ -> [])
  | Timeline_presented _ -> []
  | Authenticated_user { user_id } ->
    let closing = install_account t ~user_id ~local_fast_path:false in
    closing @ challenge t Auth.Catalog_discovery
  | Signed_out_command ->
    let effects = close_graph_effects t in
    let cleanup =
      current_account_scope t
      |> Option.map delete_account_secrets_action
      |> Option.to_list
    in
    Auth.cancel_all t.auth;
    t.bootstrap <- Bootstrap_idle;
    clear_e2ee t;
    t.reconnect_attempt <- 0;
    clear_transport_coordination t;
    clear_pending_reconciliation t;
    t.startup_authority <- No_startup_authority;
    clear_network_authority t;
    t.local_fast_path <- false;
    t.snapshot
    <- { phase = Signed_out
       ; account_generation = t.snapshot.account_generation + 1
       ; graph_generation = t.snapshot.graph_generation + 1
       ; connection_generation = t.snapshot.connection_generation + 1
       ; user_id = None
       ; catalog = []
       ; selected_graph = None
       ; applied_server_t = None
       ; last_error = None
       ; presentation_generation = t.snapshot.presentation_generation + 1
       ; startup_presentation = Reconciled
       };
    effects @ cleanup
  | Provide_id_token
      { challenge_id
      ; user_id
      ; account_generation
      ; graph_generation
      ; connection_generation
      ; token
      } ->
    if is_backgrounded t
    then (
      (match Auth.fail t.auth ~challenge_id with
       | Ok { purpose = Websocket_connect; _ } -> set_current_transport t Backing_off
       | Ok { purpose = Catalog_discovery | Snapshot_bootstrap | E2ee_key_access; _ }
       | Error _ -> ());
      [])
    else
      provide_token
        t
        ~challenge_id
        ~user_id
        ~account_generation
        ~graph_generation
        ~connection_generation
        ~token
  | Token_failed { challenge_id } ->
    (match Auth.fail t.auth ~challenge_id with
     | Error _ -> []
     | Ok challenge ->
       let retryable_transport_failure =
         match challenge.Auth.purpose with
         | Websocket_connect ->
           set_current_transport t Backing_off;
           true
         | Catalog_discovery | Snapshot_bootstrap | E2ee_key_access -> false
       in
       let populated_graph = Option.is_some t.snapshot.applied_server_t in
       t.snapshot
       <- { t.snapshot with
            phase = (if populated_graph then Sync_paused else Failed)
          ; last_error = Some "ID token acquisition failed"
          };
       if retryable_transport_failure && populated_graph then schedule_reconnect t else [])
  | Select_graph graph_id ->
    (match
       List.find_opt
         (fun graph -> Graph_types.Uuid.equal graph.Catalog.graph_id graph_id)
         t.snapshot.catalog
     with
     | None -> []
     | Some graph ->
       let closing = close_graph_effects t in
       Auth.cancel_all t.auth;
       t.bootstrap <- Bootstrap_idle;
       clear_e2ee t;
       t.reconnect_attempt <- 0;
       clear_transport_coordination t;
       t.snapshot
       <- { t.snapshot with
            phase = Opening_graph
          ; graph_generation = t.snapshot.graph_generation + 1
          ; connection_generation = 0
          ; selected_graph = Some graph_id
          ; applied_server_t = None
          ; last_error = None
          ; presentation_generation = t.snapshot.presentation_generation + 1
          ; startup_presentation =
              (if t.local_fast_path then Restoring_local else Reconciled)
          };
       begin_graph_authority t;
       closing @ [ inspect_mirror_action t graph ])
  | Return_to_graph_picker ->
    (match t.snapshot.user_id with
     | None -> []
     | Some _ ->
       let closing = close_graph_effects t in
       Auth.cancel_all t.auth;
       t.bootstrap <- Bootstrap_idle;
       clear_e2ee t;
       t.reconnect_attempt <- 0;
       clear_transport_coordination t;
       clear_pending_reconciliation t;
       t.startup_authority <- No_startup_authority;
       clear_network_authority t;
       t.local_fast_path <- false;
       t.snapshot
       <- { t.snapshot with
            phase = Awaiting_selection
          ; graph_generation = t.snapshot.graph_generation + 1
          ; connection_generation = t.snapshot.connection_generation + 1
          ; applied_server_t = None
          ; last_error = None
          ; presentation_generation = t.snapshot.presentation_generation + 1
          ; startup_presentation = Reconciled
          };
       closing)
  | Refresh_catalog -> challenge t Auth.Catalog_discovery
  | Begin_online_recovery ->
    (match t.pending_online_recovery, selected t with
     | Some (recovery, continuation), Some graph ->
       t.pending_online_recovery <- None;
       (match Startup_phase.permit_recovery recovery with
        | Error `Already_consumed -> []
        | Ok permit ->
          let scope = Startup_phase.permit_graph_scope permit in
          if
            not
              (Startup_phase.graph_scope_matches
                 scope
                 ~account_generation:t.snapshot.account_generation
                 ~graph_generation:t.snapshot.graph_generation
                 ~presentation_generation:t.snapshot.presentation_generation)
          then []
          else (
            t.graph_network_permit <- Some permit;
            t.snapshot <- { t.snapshot with last_error = None };
            match continuation with
            | Snapshot_recovery ->
              t.snapshot <- { t.snapshot with phase = Bootstrapping };
              t.bootstrap <- Awaiting_baseline;
              challenge t Auth.Snapshot_bootstrap
            | E2ee_recovery e2ee_continuation -> start_e2ee t graph e2ee_continuation))
     | None, _ | Some _, None -> [])
  | Backgrounded { lifecycle_generation } ->
    if
      Int64.compare lifecycle_generation t.last_resumed_generation <= 0
      ||
      match t.transport with
      | Suspended suspended ->
        Int64.equal suspended.lifecycle_generation lifecycle_generation
      | Foreground_transport _ -> false
    then []
    else (
      let transport = current_transport t in
      t.transport <- Suspended { lifecycle_generation; transport };
      [])
  | Foreground_resumed { lifecycle_generation } ->
    (match t.transport with
     | Foreground_transport _ -> []
     | Suspended suspended
       when not (Int64.equal suspended.lifecycle_generation lifecycle_generation) -> []
     | Suspended suspended ->
       t.transport <- Foreground_transport suspended.transport;
       t.last_resumed_generation <- lifecycle_generation;
       t.reconnect_attempt <- 0;
       t.snapshot <- { t.snapshot with last_error = None };
       (match
          t.snapshot.user_id, t.snapshot.selected_graph, t.snapshot.applied_server_t
        with
        | Some _, Some _, Some _ ->
          (match current_transport t with
           | Live_websocket { initialized } | Revalidating_websocket { initialized; _ } ->
             set_current_transport
               t
               (Revalidating_websocket
                  { lifecycle_generation
                  ; connection_generation = t.snapshot.connection_generation
                  ; initialized
                  });
             let hello =
               if initialized
               then []
               else
                 [ send_websocket_action
                     t
                     (Protocol.encode_hello ~client:"logseq-journal")
                 ]
             in
             let pull = request_pull t in
             hello
             @ pull
             @ [ schedule_foreground_probe_action
                   t
                   ~lifecycle_generation
                   ~delay_seconds:3.
               ]
           | Awaiting_websocket_token | Connecting_websocket -> []
           | Disconnected | Backing_off -> challenge t Auth.Websocket_connect)
        | Some _, None, _ -> challenge t Auth.Catalog_discovery
        | None, _, _ | Some _, Some _, None -> []))
  | Submit_e2ee_password password ->
    (match selected t, t.e2ee with
     | Some _, Some session ->
       (match E2ee_session.submit_password session password with
        | Ok () ->
          (match E2ee_session.encrypted_graph_key session with
           | Some encrypted_graph_key ->
             (match Action.wrapped_graph_key_of_string encrypted_graph_key with
              | Some encrypted_graph_key ->
                [ verify_and_save_wrapped_graph_key_action t encrypted_graph_key ]
              | None -> [])
           | None -> [])
        | Error message ->
          t.snapshot <- { t.snapshot with last_error = Some message };
          [])
     | _, _ -> [])
  | Delete_local_cache graph_id ->
    (match selected t with
     | Some graph when Graph_types.Uuid.equal graph.graph_id graph_id ->
       Auth.cancel_all t.auth;
       t.bootstrap <- Bootstrap_idle;
       clear_e2ee t;
       t.reconnect_attempt <- 0;
       clear_transport_coordination t;
       t.snapshot
       <- { t.snapshot with
            phase = Bootstrapping
          ; graph_generation = t.snapshot.graph_generation + 1
          ; connection_generation = t.snapshot.connection_generation + 1
          ; applied_server_t = None
          ; last_error = None
          };
       begin_graph_authority t;
       [ close_websocket_action
       ; close_graph_action
       ; delete_wrapped_graph_key_action t graph_id
       ; delete_mirror_action t graph_id
       ]
     | None | Some _ ->
       [ delete_wrapped_graph_key_action t graph_id; delete_mirror_action t graph_id ])
;;

let handle_command t command =
  let before_user = t.snapshot.user_id in
  let before = diagnostic_projection t in
  let effects = handle_command_internal t command in
  let reset =
    match command with
    | Signed_out_command -> true
    | Restore_local_account _
    | Reconcile_authenticated_user _
    | Local_feed_ready _
    | Timeline_presented _
    | Authenticated_user _
    | Provide_id_token _
    | Token_failed _
    | Select_graph _
    | Return_to_graph_picker
    | Refresh_catalog
    | Begin_online_recovery
    | Backgrounded _
    | Foreground_resumed _
    | Submit_e2ee_password _
    | Delete_local_cache _ -> false
  in
  record_diagnostic_transition t ~before_user ~before ~reset;
  effects
;;

let account_current t account_generation =
  t.snapshot.account_generation = account_generation
;;

let graph_current t account_generation graph_generation =
  account_current t account_generation && t.snapshot.graph_generation = graph_generation
;;

let connection_current t account_generation graph_generation connection_generation =
  graph_current t account_generation graph_generation
  && t.snapshot.connection_generation = connection_generation
;;

let user_network_message = function
  | "End_of_file" -> "Network unavailable"
  | message -> message
;;

let handle_event_internal t = function
  | Cached_catalog_loaded { account_generation; graphs }
    when account_current t account_generation ->
    apply_catalog_loaded t ~release_network:false graphs
  | Cached_catalog_loaded _ -> []
  | Catalog_loaded { account_generation; graphs }
    when account_current t account_generation && before_timeline_presented t ->
    t.pending_catalog_reconciliation <- Some graphs;
    []
  | Catalog_loaded { account_generation; graphs }
    when account_current t account_generation ->
    apply_catalog_loaded t ~release_network:true graphs
  | Catalog_loaded _ -> []
  | Catalog_failed { account_generation; message }
    when account_current t account_generation ->
    t.snapshot
    <- { t.snapshot with
         phase =
           (match t.snapshot.selected_graph with
            | Some _ -> t.snapshot.phase
            | None -> Failed)
       ; last_error = Some message
       };
    []
  | Catalog_failed _ -> []
  | Mirror_ready { account_generation; graph_generation; graph_id }
    when graph_current t account_generation graph_generation
         && t.snapshot.selected_graph = Some graph_id ->
    (match selected t with
     | None -> []
     | Some graph -> open_selected_graph t ~account_generation ~graph_generation graph)
  | Mirror_ready _ -> []
  | Mirror_missing { account_generation; graph_generation; graph_id; receipt }
    when graph_current t account_generation graph_generation
         && t.snapshot.selected_graph = Some graph_id ->
    (match authorize_recovery t receipt, selected t with
     | Some recovery, Some graph when graph.encrypted ->
       stage_online_recovery
         t
         recovery
         (E2ee_recovery Bootstrap_after_e2ee)
         ~diagnostic:"mirror missing"
     | Some recovery, Some _ ->
       stage_online_recovery t recovery Snapshot_recovery ~diagnostic:"mirror missing"
     | None, _ | Some _, None -> [])
  | Mirror_missing _ -> []
  | Wrapped_graph_key_loaded
      { account_generation; graph_generation; graph_id; encrypted_graph_key }
    when graph_current t account_generation graph_generation
         && t.snapshot.selected_graph = Some graph_id ->
    (match selected t, Action.wrapped_graph_key_of_string encrypted_graph_key with
     | Some graph, Some encrypted_graph_key ->
       t.snapshot <- { t.snapshot with phase = Opening_graph; last_error = None };
       [ open_graph_action t graph (Some encrypted_graph_key) ]
     | Some _, None ->
       t.snapshot
       <- { t.snapshot with
            phase = Failed
          ; last_error = Some "local crypto returned an invalid wrapped graph key"
          };
       []
     | None, _ -> [])
  | Wrapped_graph_key_loaded _ -> []
  | Wrapped_graph_key_load_failed
      { account_generation; graph_generation; graph_id; diagnostic; receipt }
    when graph_current t account_generation graph_generation
         && t.snapshot.selected_graph = Some graph_id ->
    (match authorize_local_secret_recovery t receipt with
     | Some recovery ->
       stage_online_recovery t recovery (E2ee_recovery Open_after_e2ee) ~diagnostic
     | None -> [])
  | Wrapped_graph_key_load_failed _ -> []
  | Wrapped_graph_key_saved { account_generation; graph_generation; graph_id; diagnostic }
    when graph_current t account_generation graph_generation
         && t.snapshot.selected_graph = Some graph_id ->
    Option.iter
      (fun message -> t.snapshot <- { t.snapshot with last_error = Some message })
      diagnostic;
    (match selected t, t.e2ee with
     | Some graph, Some session ->
       (match E2ee_session.encrypted_graph_key session with
        | Some encrypted_graph_key -> resume_after_e2ee t graph encrypted_graph_key
        | None -> [])
     | _, _ -> [])
  | Wrapped_graph_key_saved _ -> []
  | Local_secret_cleanup_finished _ -> []
  | Local_cache_deleted { account_generation; graph_generation; graph_id }
    when graph_current t account_generation graph_generation
         && t.snapshot.selected_graph = Some graph_id ->
    (match selected t with
     | None -> []
     | Some graph ->
       ignore account_generation;
       ignore graph_generation;
       [ inspect_mirror_action t graph ])
  | Local_cache_deleted _ -> []
  | Snapshot_baseline_loaded { account_generation; graph_generation; graph_id; baseline }
    when graph_current t account_generation graph_generation
         && t.snapshot.selected_graph = Some graph_id
         && t.bootstrap = Awaiting_baseline ->
    t.bootstrap <- Awaiting_metadata baseline;
    challenge t Auth.Snapshot_bootstrap
  | Snapshot_baseline_loaded _ -> []
  | Snapshot_metadata_loaded { account_generation; graph_generation; graph_id; metadata }
    when graph_current t account_generation graph_generation
         && t.snapshot.selected_graph = Some graph_id ->
    (match t.bootstrap with
     | Awaiting_metadata baseline ->
       t.bootstrap <- Awaiting_artifact (baseline, metadata);
       challenge t Auth.Snapshot_bootstrap
     | Bootstrap_idle | Awaiting_baseline | Awaiting_artifact _ -> [])
  | Snapshot_metadata_loaded _ -> []
  | Snapshot_artifact_ready
      { account_generation; graph_generation; graph_id; snapshot_path; expected_rows }
    when graph_current t account_generation graph_generation
         && t.snapshot.selected_graph = Some graph_id ->
    (match t.bootstrap, selected t with
     | Awaiting_artifact (baseline, _), Some graph ->
       t.bootstrap <- Bootstrap_idle;
       let encrypted_graph_key =
         Option.bind
           (Option.bind t.e2ee E2ee_session.encrypted_graph_key)
           Action.wrapped_graph_key_of_string
       in
       (match current_graph_permit t with
        | None -> []
        | Some permit ->
          [ Action.activate_snapshot
              permit
              (contract_graph graph)
              ~server_t:baseline.server_t
              ~snapshot_path
              ~expected_rows
              ~encrypted_graph_key
            |> pack_result "snapshot activation"
          ])
     | _, _ -> [])
  | Snapshot_artifact_ready _ -> []
  | E2ee_graph_key_loaded { account_generation; graph_generation; graph_id; response }
    when graph_current t account_generation graph_generation
         && t.snapshot.selected_graph = Some graph_id ->
    (match selected t, t.e2ee with
     | Some _, Some session ->
       (match E2ee_session.accept_graph_key_response session response with
        | Error message ->
          t.snapshot <- { t.snapshot with phase = Failed; last_error = Some message };
          []
        | Ok () ->
          (match E2ee_session.phase session with
           | Fetching_user_keys -> challenge t Auth.E2ee_key_access
           | Ready ->
             (match E2ee_session.encrypted_graph_key session with
              | Some encrypted_graph_key ->
                (match Action.wrapped_graph_key_of_string encrypted_graph_key with
                 | Some encrypted_graph_key ->
                   [ verify_and_save_wrapped_graph_key_action t encrypted_graph_key ]
                 | None -> [])
              | None -> [])
           | Fetching_graph_key | Awaiting_password | Failed -> []))
     | _, _ -> [])
  | E2ee_graph_key_loaded _ -> []
  | E2ee_user_keys_loaded { account_generation; graph_generation; graph_id; response }
    when graph_current t account_generation graph_generation
         && t.snapshot.selected_graph = Some graph_id ->
    (match t.e2ee with
     | Some session ->
       (match E2ee_session.accept_user_keys_response session response with
        | Ok () ->
          t.snapshot
          <- { t.snapshot with phase = Awaiting_e2ee_password; last_error = None };
          []
        | Error message ->
          t.snapshot <- { t.snapshot with phase = Failed; last_error = Some message };
          [])
     | None -> [])
  | E2ee_user_keys_loaded _ -> []
  | Graph_opened { account_generation; graph_generation; graph_id; applied_server_t }
    when graph_current t account_generation graph_generation
         && t.snapshot.selected_graph = Some graph_id ->
    t.snapshot
    <- { t.snapshot with
         applied_server_t = Some applied_server_t
       ; connection_generation = t.snapshot.connection_generation + 1
       };
    if before_timeline_presented t then [] else challenge t Auth.Websocket_connect
  | Graph_opened _ -> []
  | Websocket_opened { account_generation; graph_generation; connection_generation }
    when connection_current t account_generation graph_generation connection_generation ->
    set_current_transport t (Live_websocket { initialized = false });
    t.reconnect_attempt <- 0;
    t.snapshot <- { t.snapshot with phase = Graph_open; last_error = None };
    if is_backgrounded t
    then []
    else if before_timeline_presented t
    then []
    else (
      t.pull <- Pull_in_flight { requested_again = false };
      [ send_websocket_action t (Protocol.encode_hello ~client:"logseq-journal")
      ; send_websocket_action t (pull_payload t)
      ])
  | Websocket_opened _ -> []
  | Websocket_frame
      { account_generation; graph_generation; connection_generation; payload }
    when connection_current t account_generation graph_generation connection_generation ->
    (match Protocol.decode_server_message payload with
     | Ok (Changed _ | Pull_ok _) when before_timeline_presented t ->
       t.pending_changed_before_presentation <- true;
       []
     | Ok (Changed _) -> request_pull t
     | Ok (Pull_ok _) ->
       t.frame_application <- Applying_pull;
       [ apply_sync_frame_action t payload ]
     | Ok (Tx_batch_ok _ | Tx_reject _) ->
       t.submission <- No_submission;
       t.frame_application <- Applying_transaction;
       [ apply_sync_frame_action t payload ]
     | Ok (Hello _ | Server_error _ | Pong) ->
       t.frame_application <- Applying_control;
       [ apply_sync_frame_action t payload ]
     | Ok Online_users -> []
     | Error message -> begin_failed_socket_reconnect t ~message)
  | Websocket_frame _ -> []
  | Websocket_closed
      { account_generation; graph_generation; connection_generation; message }
    when connection_current t account_generation graph_generation connection_generation ->
    begin_scheduled_reconnect t ~message
  | Websocket_closed _ -> []
  | Reconnect_timer_elapsed
      { account_generation; graph_generation; connection_generation }
    when connection_current t account_generation graph_generation connection_generation ->
    if is_backgrounded t then [] else challenge t Auth.Websocket_connect
  | Reconnect_timer_elapsed _ -> []
  | Foreground_probe_timed_out
      { account_generation
      ; graph_generation
      ; connection_generation
      ; lifecycle_generation
      }
    when connection_current t account_generation graph_generation connection_generation ->
    if is_backgrounded t
    then []
    else (
      match current_transport t with
      | Revalidating_websocket probe
        when Int64.equal probe.lifecycle_generation lifecycle_generation
             && probe.connection_generation = connection_generation ->
        begin_failed_socket_reconnect t ~message:"foreground probe timed out"
      | Revalidating_websocket _
      | Disconnected
      | Awaiting_websocket_token
      | Connecting_websocket
      | Live_websocket _
      | Backing_off -> [])
  | Foreground_probe_timed_out _ -> []
  | Pending_batch payload -> route_submission t payload
  | Sync_applied
      { account_generation
      ; graph_generation
      ; applied_server_t
      ; activity
      ; pending_payload
      }
    when graph_current t account_generation graph_generation ->
    t.snapshot <- { t.snapshot with applied_server_t = Some applied_server_t };
    let completed_pull = t.frame_application = Applying_pull in
    let transport_before_application = current_transport t in
    let failed_pull = completed_pull && activity = Sync_status.Sync_paused in
    let requested_again =
      match t.pull with
      | Pull_idle -> false
      | Pull_in_flight { requested_again } -> requested_again
    in
    t.frame_application <- No_frame_application;
    if failed_pull
    then begin_failed_socket_reconnect t ~message:"authoritative pull replay failed"
    else (
      if completed_pull
      then (
        t.pull <- Pull_idle;
        match transport_before_application with
        | Revalidating_websocket _ ->
          set_current_transport t (Live_websocket { initialized = true })
        | Live_websocket { initialized = false } ->
          set_current_transport t (Live_websocket { initialized = true })
        | Disconnected | Awaiting_websocket_token | Connecting_websocket
        | Live_websocket { initialized = true }
        | Backing_off -> ());
      let need_pull =
        requested_again
        ||
        match activity with
        | Sync_status.Pull_required -> true
        | Pull_applied | Pull_duplicate | Sync_paused | Sync_submission_blocked -> false
      in
      let pull = if need_pull then request_pull t else [] in
      if completed_pull && pull_is_idle t.pull && t.recover_after_authoritative_pull <> []
      then (
        let transaction_ids = t.recover_after_authoritative_pull in
        if is_backgrounded t
        then []
        else (
          t.recover_after_authoritative_pull <- [];
          [ recover_submitted_action t transaction_ids ]))
      else if t.recover_after_authoritative_pull <> []
      then pull
      else (
        if completed_pull
        then (
          match t.submission with
          | Deferred_submission _ -> t.submission <- No_submission
          | No_submission | In_flight_submission _ -> ());
        let pending =
          match pending_payload, t.submission with
          | Some payload, No_submission when completed_pull && not (pull_is_idle t.pull)
            ->
            (match decode_submission payload with
             | Ok (payload, tx_ids) -> defer_submission t payload tx_ids
             | Error message ->
               t.snapshot
               <- { t.snapshot with phase = Sync_paused; last_error = Some message };
               [])
          | Some payload, No_submission -> route_submission t payload
          | Some _, (Deferred_submission _ | In_flight_submission _) | None, _ -> []
        in
        pull @ pending))
  | Sync_applied _ -> []
  | Network_failed
      { account_generation; graph_generation; connection_generation; message }
    when account_current t account_generation
         &&
         match graph_generation with
         | None -> true
         | Some generation ->
           generation = t.snapshot.graph_generation
           &&
             (match connection_generation with
             | None -> true
             | Some generation -> generation = t.snapshot.connection_generation) ->
    let message = user_network_message message in
    if Option.is_none t.snapshot.applied_server_t
    then (
      t.startup_authority <- No_startup_authority;
      clear_network_authority t);
    t.snapshot
    <- { t.snapshot with
         phase =
           (if Option.is_none t.snapshot.applied_server_t
            then Failed
            else if before_timeline_presented t
            then t.snapshot.phase
            else Sync_paused)
       ; last_error = Some message
       };
    if before_timeline_presented t
    then []
    else if Option.is_some graph_generation && Option.is_some t.snapshot.applied_server_t
    then (
      match current_transport t with
      | Live_websocket _ | Revalidating_websocket _ ->
        begin_failed_socket_reconnect t ~message
      | Disconnected | Awaiting_websocket_token | Connecting_websocket | Backing_off ->
        begin_scheduled_reconnect t ~message)
    else []
  | Network_failed _ -> []
;;

let handle_event t event =
  let before_user = t.snapshot.user_id in
  let before = diagnostic_projection t in
  let effects = handle_event_internal t event in
  record_diagnostic_transition t ~before_user ~before ~reset:false;
  effects
;;

let diagnostics = current_diagnostics
let state t = { snapshot = t.snapshot; diagnostics = current_diagnostics t }
