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

type startup_authority =
  | No_startup_authority
  | Restoring_authority of Sync_startup_phase.restoring Sync_startup_phase.witness
  | Presented_authority of Sync_startup_phase.presented Sync_startup_phase.witness

type pending_network_permit =
  | Pending_account_permit of
      Sync_startup_phase.account Sync_startup_phase.network_permit
  | Pending_graph_permit of Sync_startup_phase.graph Sync_startup_phase.network_permit
  | Pending_connection_permit of
      Sync_startup_phase.connection Sync_startup_phase.network_permit

type t =
  { base_url : Uri.t
  ; auth : Sync_auth.t
  ; mutable snapshot : snapshot
  ; mutable bootstrap : bootstrap_state
  ; e2ee_platform : Sync_e2ee_session.platform
  ; mutable e2ee : Sync_e2ee_session.t option
  ; mutable e2ee_continuation : e2ee_continuation
  ; mutable transport : transport_state
  ; mutable reconnect_attempt : int
  ; mutable last_resumed_generation : int64
  ; mutable pull : pull_state
  ; mutable frame_application : frame_application
  ; mutable submission : submission_state
  ; mutable recover_after_http_pull : Graph_types.Uuid.t list
  ; mutable local_fast_path : bool
  ; mutable pending_user_reconciliation : (string option * string) option
  ; mutable pending_catalog_reconciliation : Sync_catalog.graph list option
  ; mutable pending_changed_before_presentation : bool
  ; mutable startup_authority : startup_authority
  ; mutable next_permit_id : int64
  ; mutable graph_network_permit :
      Sync_startup_phase.graph Sync_startup_phase.network_permit option
  ; mutable pending_network_permits : (string * pending_network_permit) list
  ; mutable pending_online_recovery :
      (Sync_startup_phase.online_recovery * recovery_continuation) option
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
  | Awaiting_http_pull_token
  | Http_pull_in_flight
  | Http_catchup_applied
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
  | Awaiting_http_submission_token of
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
  | Awaiting_metadata of Sync_bootstrap.baseline
  | Awaiting_artifact of Sync_bootstrap.baseline * Sync_bootstrap.snapshot_metadata

and e2ee_continuation =
  | No_e2ee_continuation
  | Open_after_e2ee
  | Bootstrap_after_e2ee

and recovery_continuation =
  | Snapshot_recovery
  | E2ee_recovery of e2ee_continuation

let default_e2ee_platform =
  Sync_e2ee_session.
    { has_private_key = Sync_platform_crypto.has_private_key
    ; unlock_private_key = Sync_platform_crypto.unlock_private_key
    }
;;

let create_with_e2ee ~e2ee_platform ~next_challenge_id ~base_url =
  { base_url
  ; auth = Sync_auth.create ~next_id:next_challenge_id ()
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
  ; recover_after_http_pull = []
  ; local_fast_path = false
  ; pending_user_reconciliation = None
  ; pending_catalog_reconciliation = None
  ; pending_changed_before_presentation = false
  ; startup_authority = No_startup_authority
  ; next_permit_id = 0L
  ; graph_network_permit = None
  ; pending_network_permits = []
  ; pending_online_recovery = None
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

let create ~next_challenge_id ~base_url =
  create_with_e2ee ~e2ee_platform:default_e2ee_platform ~next_challenge_id ~base_url
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
    Sync_startup_phase.account_scope
      ~managed_sync_origin:t.base_url
      ~user_id
      ~account_generation:t.snapshot.account_generation
      ~presentation_generation:t.snapshot.presentation_generation
      ~permit_id:(fresh_permit_id t)
;;

let current_graph_scope t =
  match current_account_scope t, t.snapshot.selected_graph with
  | Some account_scope, Some graph_id ->
    Sync_startup_phase.graph_scope
      account_scope
      ~graph_id:(Graph_types.Uuid.to_string graph_id)
      ~graph_generation:t.snapshot.graph_generation
  | None, _ | Some _, None -> None
;;

let begin_local_restore_authority t =
  t.startup_authority
  <- (match current_graph_scope t with
      | Some graph_scope ->
        Restoring_authority (Sync_startup_phase.begin_restore graph_scope)
      | None -> No_startup_authority)
;;

let contract_graph (graph : Sync_catalog.graph) =
  Sync_action.
    { graph_id = Graph_types.Uuid.to_string graph.graph_id
    ; name = graph.name
    ; schema_major = graph.schema.major
    ; schema_minor = graph.schema.minor
    ; schema_exact = graph.schema.exact
    ; encrypted = graph.encrypted
    }
;;

let pack action = Sync_action.pack action

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
    let scope = Sync_startup_phase.permit_graph_scope permit in
    if
      Sync_startup_phase.graph_scope_matches
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
    let graph_scope = Sync_startup_phase.permit_graph_scope graph_permit in
    Option.bind
      (Sync_startup_phase.connection_scope
         graph_scope
         ~connection_generation:t.snapshot.connection_generation
         ~lifecycle_generation)
      (Sync_startup_phase.connection_permit graph_permit)
;;

let current_account_permit t =
  match current_graph_permit t with
  | Some graph_permit -> Some (Sync_startup_phase.account_permit graph_permit)
  | None ->
    Option.bind (current_account_scope t) (fun scope ->
      Sync_startup_phase.begin_account_recovery scope
      |> Sync_startup_phase.permit_account_recovery
      |> Result.to_option)
;;

let store_pending_permit t challenge_id permit =
  t.pending_network_permits
  <- (challenge_id, permit)
     :: List.remove_assoc challenge_id t.pending_network_permits
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

let is_revalidating = function
  | Revalidating_websocket _ -> true
  | Disconnected
  | Awaiting_websocket_token
  | Connecting_websocket
  | Live_websocket _
  | Awaiting_http_pull_token
  | Http_pull_in_flight
  | Http_catchup_applied
  | Backing_off -> false
;;

let is_http_pull_in_flight = function
  | Http_pull_in_flight -> true
  | Disconnected
  | Awaiting_websocket_token
  | Connecting_websocket
  | Live_websocket _
  | Revalidating_websocket _
  | Awaiting_http_pull_token
  | Http_catchup_applied
  | Backing_off -> false
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
  t.recover_after_http_pull <- []
;;

let submission_ids = function
  | No_submission -> []
  | Deferred_submission { tx_ids; _ }
  | Awaiting_http_submission_token { tx_ids; _ }
  | In_flight_submission { tx_ids; _ } -> tx_ids
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
    (fun permit -> Sync_action.send_websocket permit ~payload)
;;

let schedule_reconnect_action t delay_seconds =
  with_connection_permit
    t
    ~lifecycle_generation:(Int64.max 0L t.last_resumed_generation)
    "reconnect scheduling"
    (fun permit -> Sync_action.schedule_reconnect permit ~delay_seconds)
;;

let schedule_foreground_probe_action t ~lifecycle_generation ~delay_seconds =
  with_connection_permit
    t
    ~lifecycle_generation
    "foreground probe scheduling"
    (fun permit -> Sync_action.schedule_foreground_probe permit ~delay_seconds)
;;

let apply_sync_frame_action t frame =
  with_connection_permit
    t
    ~lifecycle_generation:(Int64.max 0L t.last_resumed_generation)
    "sync frame application"
    (fun permit -> Sync_action.apply_sync_frame permit ~frame)
;;

let recover_submitted_action t transaction_ids =
  with_connection_permit
    t
    ~lifecycle_generation:(Int64.max 0L t.last_resumed_generation)
    "submitted transaction recovery"
    (fun permit ->
      Sync_action.recover_submitted
        permit
        ~transaction_ids:(List.map Graph_types.Uuid.to_string transaction_ids))
;;

let remember_uncertain_submission t =
  let tx_ids = submission_ids t.submission in
  if tx_ids <> [] then t.recover_after_http_pull <- tx_ids;
  t.submission <- No_submission
;;

let pull_payload t =
  Sync_protocol.encode_pull ~since:(Option.value t.snapshot.applied_server_t ~default:0)
;;

let request_pull t =
  if not (pull_is_idle t.pull)
  then (
    t.pull <- Pull_in_flight { requested_again = true };
    [])
  else (
    match current_transport t with
    | Live_websocket _ | Revalidating_websocket _ ->
      t.pull <- Pull_in_flight { requested_again = false };
      [ send_websocket_action t (pull_payload t) ]
    | Disconnected
    | Awaiting_websocket_token
    | Connecting_websocket
    | Awaiting_http_pull_token
    | Http_pull_in_flight
    | Http_catchup_applied
    | Backing_off -> [])
;;

let decode_submission payload =
  Result.map (fun tx_ids -> payload, tx_ids) (Sync_protocol.decode_tx_batch_ids payload)
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
  else if
    purpose = Sync_auth.Http_pull
    &&
    match current_transport t with
    | Awaiting_http_pull_token | Http_pull_in_flight -> true
    | Disconnected
    | Awaiting_websocket_token
    | Connecting_websocket
    | Live_websocket _
    | Revalidating_websocket _
    | Http_catchup_applied
    | Backing_off -> false
  then []
  else (
    match t.snapshot.user_id with
    | None -> []
    | Some user_id ->
      (match purpose with
       | Sync_auth.Websocket_connect -> set_current_transport t Awaiting_websocket_token
       | Http_pull -> set_current_transport t Awaiting_http_pull_token
       | Catalog_discovery | Snapshot_bootstrap | E2ee_key_access | Transaction_submission
         -> ());
      let graph_generation, connection_generation =
        match purpose with
        | Sync_auth.Catalog_discovery -> None, None
        | Snapshot_bootstrap | E2ee_key_access -> Some t.snapshot.graph_generation, None
        | Http_pull | Transaction_submission | Websocket_connect ->
          Some t.snapshot.graph_generation, Some t.snapshot.connection_generation
      in
      let challenge =
        Sync_auth.issue
          t.auth
          ~purpose
          ~user_id
          ~account_generation:t.snapshot.account_generation
          ~graph_generation
          ~connection_generation
      in
      let typed_action =
        match purpose with
        | Sync_auth.Catalog_discovery ->
          current_account_permit t
          |> Option.map (fun permit ->
            store_pending_permit
              t
              challenge.challenge_id
              (Pending_account_permit permit);
            Sync_action.need_id_token
              permit
              ~challenge_id:challenge.challenge_id
              Sync_action.Catalog_discovery
            |> pack_result "catalog token challenge")
        | Snapshot_bootstrap ->
          current_graph_permit t
          |> Option.map (fun permit ->
            store_pending_permit
              t
              challenge.challenge_id
              (Pending_graph_permit permit);
            Sync_action.need_id_token
              permit
              ~challenge_id:challenge.challenge_id
              Sync_action.Snapshot_bootstrap
            |> pack_result "snapshot token challenge")
        | E2ee_key_access ->
          current_graph_permit t
          |> Option.map (fun permit ->
            store_pending_permit
              t
              challenge.challenge_id
              (Pending_graph_permit permit);
            Sync_action.need_id_token
              permit
              ~challenge_id:challenge.challenge_id
              Sync_action.E2ee_key_access
            |> pack_result "E2EE token challenge")
        | Http_pull ->
          current_connection_permit
            t
            ~lifecycle_generation:(Int64.max 0L t.last_resumed_generation)
          |> Option.map (fun permit ->
            store_pending_permit
              t
              challenge.challenge_id
              (Pending_connection_permit permit);
            Sync_action.need_id_token
              permit
              ~challenge_id:challenge.challenge_id
              Sync_action.Http_pull
            |> pack_result "HTTP pull token challenge")
        | Transaction_submission ->
          current_connection_permit
            t
            ~lifecycle_generation:(Int64.max 0L t.last_resumed_generation)
          |> Option.map (fun permit ->
            store_pending_permit
              t
              challenge.challenge_id
              (Pending_connection_permit permit);
            Sync_action.need_id_token
              permit
              ~challenge_id:challenge.challenge_id
              Sync_action.Transaction_submission
            |> pack_result "transaction token challenge")
        | Websocket_connect ->
          current_connection_permit
            t
            ~lifecycle_generation:(Int64.max 0L t.last_resumed_generation)
          |> Option.map (fun permit ->
            store_pending_permit
              t
              challenge.challenge_id
              (Pending_connection_permit permit);
            Sync_action.need_id_token
              permit
              ~challenge_id:challenge.challenge_id
              Sync_action.Websocket_connect
            |> pack_result "WebSocket token challenge")
      in
      (match typed_action with
       | None ->
         ignore (Sync_auth.fail t.auth ~challenge_id:challenge.challenge_id);
         []
       | Some action ->
         if
           (not (before_timeline_presented t))
           && (purpose <> Sync_auth.Catalog_discovery || t.snapshot.selected_graph = None)
         then t.snapshot <- { t.snapshot with phase = Awaiting_token purpose };
         [ action ]))
;;

let route_submission t payload =
  match t.submission with
  | Deferred_submission _ | Awaiting_http_submission_token _ | In_flight_submission _ ->
    []
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
         | Live_websocket _ -> send_submission t payload tx_ids
         | Revalidating_websocket _ | Awaiting_websocket_token | Connecting_websocket ->
           defer_submission t payload tx_ids
         | Disconnected
         | Awaiting_http_pull_token
         | Http_pull_in_flight
         | Http_catchup_applied
         | Backing_off ->
           t.submission <- Awaiting_http_submission_token { payload; tx_ids };
           challenge t Sync_auth.Transaction_submission))
;;

let selected t =
  match t.snapshot.selected_graph with
  | None -> None
  | Some graph_id ->
    List.find_opt
      (fun graph -> Graph_types.Uuid.equal graph.Sync_catalog.graph_id graph_id)
      t.snapshot.catalog
;;

let close_graph_action = pack Sync_action.close_graph
let close_websocket_action = pack Sync_action.close_websocket

let inspect_mirror_action t graph =
  match current_restoring_witness t with
  | None -> failwith "mirror inspection requires a restoring witness"
  | Some restoring ->
    let request = Sync_startup_phase.request_mirror restoring in
    Sync_action.inspect_mirror request (contract_graph graph)
    |> pack_result "mirror inspection"
;;

let load_wrapped_graph_key_local_action t =
  match current_restoring_witness t with
  | None -> failwith "wrapped-key lookup requires a restoring witness"
  | Some restoring ->
    let wrapped_key_request =
      Sync_startup_phase.request_wrapped_graph_key restoring
    in
    let private_key_request = Sync_startup_phase.request_local_private_key restoring in
    Sync_action.load_and_verify_wrapped_graph_key
      wrapped_key_request
      private_key_request
    |> action_result "wrapped-key lookup"
;;

let open_graph_local_action t graph encrypted_graph_key =
  match current_restoring_witness t with
  | None -> failwith "graph open requires a restoring witness"
  | Some restoring ->
    let request = Sync_startup_phase.request_graph_open restoring in
    Sync_action.open_graph
      request
      (contract_graph graph)
      ~encrypted_graph_key
    |> action_result "graph open"
;;

let open_graph_action t graph encrypted_graph_key =
  pack (open_graph_local_action t graph encrypted_graph_key)
;;

let graph_scope_for_id t graph_id =
  Option.bind (current_account_scope t) (fun account_scope ->
    Sync_startup_phase.graph_scope
      account_scope
      ~graph_id:(Graph_types.Uuid.to_string graph_id)
      ~graph_generation:t.snapshot.graph_generation)
;;

let delete_mirror_action t graph_id =
  match graph_scope_for_id t graph_id with
  | Some scope -> pack (Sync_action.delete_mirror scope)
  | None -> failwith "mirror deletion requires a current account scope"
;;

let delete_wrapped_graph_key_action t graph_id =
  match graph_scope_for_id t graph_id with
  | Some scope -> pack (Sync_action.delete_wrapped_graph_key scope)
  | None -> failwith "wrapped-key deletion requires a current account scope"
;;

let delete_account_secrets_action scope =
  pack (Sync_action.delete_account_secrets scope)
;;

let verify_and_save_wrapped_graph_key_action t encrypted_graph_key =
  match current_graph_scope t with
  | None -> failwith "wrapped-key save requires a current graph scope"
  | Some scope ->
    pack (Sync_action.verify_and_save_wrapped_graph_key scope encrypted_graph_key)
;;

let authorize_recovery t receipt =
  match current_restoring_witness t with
  | Some restoring -> Sync_startup_phase.recover restoring receipt
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
       phase = Recovering_online (Sync_startup_phase.recovery_reason recovery)
     ; last_error = Some diagnostic
     };
  []
;;

let clear_e2ee t =
  Option.iter Sync_e2ee_session.clear t.e2ee;
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
         (Sync_e2ee_session.create
            ~platform:t.e2ee_platform
            ~managed_sync_origin:t.base_url
            ~user_id
            ~graph_id:graph.Sync_catalog.graph_id
            ~graph_name:graph.name);
    challenge t Sync_auth.E2ee_key_access
;;

let open_selected_graph_local t ~account_generation ~graph_generation graph
  : Sync_action.local Sync_action.t list
  =
  ignore account_generation;
  ignore graph_generation;
  if graph.Sync_catalog.encrypted
  then [ load_wrapped_graph_key_local_action t ]
  else (
    t.snapshot <- { t.snapshot with phase = Opening_graph };
    [ open_graph_local_action t graph None ])
;;

let open_selected_graph t ~account_generation ~graph_generation graph =
  open_selected_graph_local t ~account_generation ~graph_generation graph
  |> List.map pack
;;

let resume_after_e2ee t graph encrypted_graph_key =
  match t.e2ee_continuation with
  | No_e2ee_continuation -> []
  | Open_after_e2ee ->
    t.e2ee_continuation <- No_e2ee_continuation;
    t.snapshot <- { t.snapshot with phase = Opening_graph; last_error = None };
    (match Sync_action.wrapped_graph_key_of_string encrypted_graph_key with
     | Some encrypted_graph_key ->
       [ open_graph_action t graph (Some encrypted_graph_key) ]
     | None -> failwith "E2EE session returned invalid wrapped key")
  | Bootstrap_after_e2ee ->
    t.e2ee_continuation <- No_e2ee_continuation;
    t.bootstrap <- Awaiting_baseline;
    t.snapshot <- { t.snapshot with phase = Bootstrapping; last_error = None };
    challenge t Sync_auth.Snapshot_bootstrap
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
  Sync_auth.cancel_all t.auth;
  set_current_transport t Backing_off;
  t.pull <- Pull_idle;
  t.frame_application <- No_frame_application;
  t.snapshot
  <- { t.snapshot with
       connection_generation = t.snapshot.connection_generation + 1
     ; last_error
     }
;;

let begin_http_fallback t ?last_error () =
  fence_transport t ?last_error ();
  if is_backgrounded t
  then []
  else close_websocket_action :: challenge t Sync_auth.Http_pull
;;

let begin_scheduled_reconnect t ~message =
  fence_transport t ~last_error:message ();
  schedule_reconnect t
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
    Sync_auth.provide
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
     | Sync_auth.Catalog_discovery, Some (Pending_account_permit permit) ->
       if t.snapshot.selected_graph = None
       then t.snapshot <- { t.snapshot with phase = Loading_catalog };
       [ Sync_action.fetch_catalog permit ~token |> pack_result "catalog fetch" ]
     | Websocket_connect, Some (Pending_connection_permit permit) ->
       (match t.snapshot.selected_graph with
       | None -> []
        | Some _ ->
          set_current_transport t Connecting_websocket;
          [ Sync_action.connect_websocket permit ~token
            |> pack_result "WebSocket connect"
          ])
     | Snapshot_bootstrap, Some (Pending_graph_permit permit) ->
       (match selected t with
       | None -> []
       | Some graph ->
          let graph = contract_graph graph in
          (match t.bootstrap with
           | Awaiting_baseline ->
             [ Sync_action.fetch_snapshot_baseline permit graph ~token
               |> pack_result "snapshot baseline fetch"
             ]
           | Awaiting_metadata _ ->
             [ Sync_action.fetch_snapshot_metadata permit graph ~token
               |> pack_result "snapshot metadata fetch"
             ]
           | Awaiting_artifact (baseline, metadata) ->
             let baseline = Sync_action.{ server_t = baseline.server_t } in
             let metadata =
               Sync_action.
                 { key = metadata.key
                 ; url = metadata.url
                 ; content_encoding =
                     Option.value metadata.content_encoding ~default:`Identity
                 }
             in
             [ Sync_action.download_snapshot_artifact
                 permit
                 graph
                 ~baseline
                 ~metadata
                 ~token
               |> pack_result "snapshot artifact download"
             ]
           | Bootstrap_idle -> []))
     | E2ee_key_access, Some (Pending_graph_permit permit) ->
       (match selected t, t.e2ee with
       | Some graph, Some session ->
          (match Sync_e2ee_session.phase session with
           | Fetching_graph_key ->
             [ Sync_action.fetch_e2ee_graph_key permit (contract_graph graph) ~token
               |> pack_result "E2EE graph key fetch"
             ]
           | Fetching_user_keys ->
             [ Sync_action.fetch_e2ee_user_keys permit ~token
               |> pack_result "E2EE user key fetch"
             ]
           | Awaiting_password | Ready | Failed -> [])
        | _, _ -> [])
     | Http_pull, Some (Pending_connection_permit permit) ->
       (match
          ( t.snapshot.selected_graph
          , t.snapshot.applied_server_t
          , challenge.connection_generation
          , current_transport t )
        with
        | Some graph_id, Some since, Some connection_generation, Awaiting_http_pull_token
          when connection_generation = t.snapshot.connection_generation ->
          set_current_transport t Http_pull_in_flight;
          ignore graph_id;
          [ Sync_action.fetch_http_pull permit ~since ~token
            |> pack_result "HTTP pull"
          ]
        | _ -> [])
     | Transaction_submission, Some (Pending_connection_permit permit) ->
       (match t.snapshot.selected_graph, t.submission with
        | Some _, Awaiting_http_submission_token { payload; tx_ids } ->
          t.submission <- In_flight_submission { payload; tx_ids };
          [ Sync_action.submit_http_transaction permit ~payload ~token
            |> pack_result "HTTP transaction submission"
          ]
        | None, _
        | Some _, (No_submission | Deferred_submission _ | In_flight_submission _) -> [])
     | ( Catalog_discovery
       | Snapshot_bootstrap
       | E2ee_key_access
       | Http_pull
       | Transaction_submission
       | Websocket_connect )
       , _ -> [])
;;

let install_account t ~user_id ~local_fast_path =
  let closing = close_graph_effects t in
  let cleanup =
    current_account_scope t
    |> Option.map delete_account_secrets_action
    |> Option.to_list
  in
  Sync_auth.cancel_all t.auth;
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
      | Awaiting_http_pull_token
      | Http_pull_in_flight
      | Http_catchup_applied
      | Backing_off
      | Live_websocket _ )
    , _ ) -> []
;;

let release_post_presentation_network t =
  match current_transport t, t.snapshot.applied_server_t with
  | Disconnected, Some _ -> challenge t Sync_auth.Websocket_connect
  | _ -> release_deferred_pull t
;;

let apply_catalog_loaded t graphs =
  match t.snapshot.selected_graph with
  | None ->
    t.snapshot
    <- { t.snapshot with phase = Awaiting_selection; catalog = graphs; last_error = None };
    []
  | Some selected_graph ->
    (match
       List.find_opt
         (fun graph -> Graph_types.Uuid.equal graph.Sync_catalog.graph_id selected_graph)
         graphs
     with
     | Some graph when t.snapshot.phase = Failed && t.snapshot.applied_server_t = None ->
       Sync_auth.cancel_all t.auth;
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
       []
     | None ->
       let secret_cleanup =
         match selected t with
         | Some graph when graph.encrypted ->
           [ delete_wrapped_graph_key_action t selected_graph ]
         | None | Some _ -> []
       in
       Sync_auth.cancel_all t.auth;
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

let rec handle_command t = function
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
        challenge t Sync_auth.Catalog_discovery
      | Some user_id, None | Some user_id, Some _ ->
        let closing = install_account t ~user_id ~local_fast_path:false in
        closing @ challenge t Sync_auth.Catalog_discovery
      | None, _ -> handle_command t Signed_out_command)
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
          Sync_startup_phase.acknowledge_timeline
            restoring
            { account_generation; graph_generation; presentation_generation }
        with
        | None -> []
        | Some presented ->
          t.startup_authority <- Presented_authority presented;
          t.graph_network_permit
          <- Some (Sync_startup_phase.permit_reconciliation presented);
          t.snapshot <- { t.snapshot with startup_presentation = Timeline_presented };
          (match t.pending_user_reconciliation with
     | Some (user_id, managed_sync_origin) ->
       clear_pending_reconciliation t;
       t.snapshot <- { t.snapshot with startup_presentation = Reconciled };
       handle_command t (Reconcile_authenticated_user { user_id; managed_sync_origin })
     | None ->
       (match t.pending_catalog_reconciliation with
        | Some graphs ->
          t.pending_catalog_reconciliation <- None;
          t.snapshot <- { t.snapshot with startup_presentation = Reconciled };
          apply_catalog_loaded t graphs
        | None -> release_post_presentation_network t)))
     | No_startup_authority | Presented_authority _ -> [])
  | Timeline_presented _ -> []
  | Authenticated_user { user_id } ->
    let closing = install_account t ~user_id ~local_fast_path:false in
    closing @ challenge t Sync_auth.Catalog_discovery
  | Signed_out_command ->
    let effects = close_graph_effects t in
    let cleanup =
      current_account_scope t
      |> Option.map delete_account_secrets_action
      |> Option.to_list
    in
    Sync_auth.cancel_all t.auth;
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
      (match Sync_auth.fail t.auth ~challenge_id with
       | Ok { purpose = Http_pull | Websocket_connect; _ } ->
         set_current_transport t Backing_off
       | Ok { purpose = Transaction_submission; _ } ->
         (match t.submission with
          | Awaiting_http_submission_token { payload; tx_ids } ->
            t.submission <- Deferred_submission { payload; tx_ids }
          | No_submission | Deferred_submission _ | In_flight_submission _ -> ())
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
    (match Sync_auth.fail t.auth ~challenge_id with
     | Error _ -> []
     | Ok challenge ->
       let retryable_transport_failure =
         match challenge.Sync_auth.purpose with
         | Websocket_connect | Http_pull ->
           set_current_transport t Backing_off;
           true
         | Transaction_submission ->
           set_current_transport t Backing_off;
           (match t.submission with
            | Awaiting_http_submission_token { payload; tx_ids } ->
              t.submission <- Deferred_submission { payload; tx_ids }
            | No_submission | Deferred_submission _ | In_flight_submission _ -> ());
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
         (fun graph -> Graph_types.Uuid.equal graph.Sync_catalog.graph_id graph_id)
         t.snapshot.catalog
     with
     | None -> []
     | Some graph ->
       let closing = close_graph_effects t in
       Sync_auth.cancel_all t.auth;
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
       closing
       @ [ inspect_mirror_action t graph ])
  | Return_to_graph_picker ->
    (match t.snapshot.user_id with
     | None -> []
     | Some _ ->
       let closing = close_graph_effects t in
       Sync_auth.cancel_all t.auth;
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
  | Refresh_catalog -> challenge t Sync_auth.Catalog_discovery
  | Begin_online_recovery ->
    (match t.pending_online_recovery, selected t with
     | Some (recovery, continuation), Some graph ->
       t.pending_online_recovery <- None;
       (match Sync_startup_phase.permit_recovery recovery with
        | Error `Already_consumed -> []
        | Ok permit ->
          let scope = Sync_startup_phase.permit_graph_scope permit in
          if
            not
              (Sync_startup_phase.graph_scope_matches
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
              challenge t Sync_auth.Snapshot_bootstrap
            | E2ee_recovery e2ee_continuation ->
              start_e2ee t graph e2ee_continuation))
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
                  ; initialized = true
                  });
             let hello =
               if initialized
               then []
               else
                 [ send_websocket_action
                     t
                     (Sync_protocol.encode_hello ~client:"logseq-journal")
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
           | Http_catchup_applied ->
             let recovery =
               if t.recover_after_http_pull = []
               then []
               else [ recover_submitted_action t t.recover_after_http_pull ]
             in
             t.recover_after_http_pull <- [];
             recovery @ challenge t Sync_auth.Websocket_connect
           | Awaiting_http_pull_token | Http_pull_in_flight -> []
           | Awaiting_websocket_token | Connecting_websocket -> []
           | Disconnected | Backing_off -> challenge t Sync_auth.Http_pull)
        | Some _, None, _ -> challenge t Sync_auth.Catalog_discovery
        | None, _, _ | Some _, Some _, None -> []))
  | Submit_e2ee_password password ->
    (match selected t, t.e2ee with
     | Some _, Some session ->
       (match Sync_e2ee_session.submit_password session password with
        | Ok () ->
          (match Sync_e2ee_session.encrypted_graph_key session with
           | Some encrypted_graph_key ->
             (match Sync_action.wrapped_graph_key_of_string encrypted_graph_key with
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
       Sync_auth.cancel_all t.auth;
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

let handle_event t = function
  | Cached_catalog_loaded { account_generation; graphs }
    when account_current t account_generation -> apply_catalog_loaded t graphs
  | Cached_catalog_loaded _ -> []
  | Catalog_loaded { account_generation; graphs }
    when account_current t account_generation && before_timeline_presented t ->
    t.pending_catalog_reconciliation <- Some graphs;
    []
  | Catalog_loaded { account_generation; graphs }
    when account_current t account_generation -> apply_catalog_loaded t graphs
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
    (match selected t, Sync_action.wrapped_graph_key_of_string encrypted_graph_key with
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
       stage_online_recovery
         t
         recovery
         (E2ee_recovery Open_after_e2ee)
         ~diagnostic
     | None -> [])
  | Wrapped_graph_key_load_failed _ -> []
  | Wrapped_graph_key_saved
      { account_generation; graph_generation; graph_id; diagnostic }
    when graph_current t account_generation graph_generation
         && t.snapshot.selected_graph = Some graph_id ->
    Option.iter
      (fun message -> t.snapshot <- { t.snapshot with last_error = Some message })
      diagnostic;
    (match selected t, t.e2ee with
     | Some graph, Some session ->
       (match Sync_e2ee_session.encrypted_graph_key session with
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
    challenge t Sync_auth.Snapshot_bootstrap
  | Snapshot_baseline_loaded _ -> []
  | Snapshot_metadata_loaded { account_generation; graph_generation; graph_id; metadata }
    when graph_current t account_generation graph_generation
         && t.snapshot.selected_graph = Some graph_id ->
    (match t.bootstrap with
     | Awaiting_metadata baseline ->
       t.bootstrap <- Awaiting_artifact (baseline, metadata);
       challenge t Sync_auth.Snapshot_bootstrap
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
           (Option.bind t.e2ee Sync_e2ee_session.encrypted_graph_key)
           Sync_action.wrapped_graph_key_of_string
       in
       (match current_graph_permit t with
        | None -> []
        | Some permit ->
          [ Sync_action.activate_snapshot
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
       (match Sync_e2ee_session.accept_graph_key_response session response with
        | Error message ->
          t.snapshot <- { t.snapshot with phase = Failed; last_error = Some message };
          []
        | Ok () ->
          (match Sync_e2ee_session.phase session with
           | Fetching_user_keys -> challenge t Sync_auth.E2ee_key_access
           | Ready ->
             (match Sync_e2ee_session.encrypted_graph_key session with
              | Some encrypted_graph_key ->
                (match Sync_action.wrapped_graph_key_of_string encrypted_graph_key with
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
       (match Sync_e2ee_session.accept_user_keys_response session response with
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
    if before_timeline_presented t then [] else challenge t Sync_auth.Websocket_connect
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
      set_current_transport t (Live_websocket { initialized = true });
      t.pull <- Pull_in_flight { requested_again = false };
      [ send_websocket_action t (Sync_protocol.encode_hello ~client:"logseq-journal")
      ; send_websocket_action t (pull_payload t)
      ])
  | Websocket_opened _ -> []
  | Websocket_frame
      { account_generation; graph_generation; connection_generation; payload }
    when connection_current t account_generation graph_generation connection_generation ->
    (match Sync_protocol.decode_server_message payload with
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
     | Error message ->
       if is_revalidating (current_transport t)
       then begin_http_fallback t ~last_error:message ()
       else (
         t.snapshot <- { t.snapshot with phase = Sync_paused; last_error = Some message };
         []))
  | Websocket_frame _ -> []
  | Websocket_closed
      { account_generation; graph_generation; connection_generation; message }
    when connection_current t account_generation graph_generation connection_generation ->
    if is_revalidating (current_transport t)
    then begin_http_fallback t ~last_error:message ()
    else begin_scheduled_reconnect t ~message
  | Websocket_closed _ -> []
  | Reconnect_timer_elapsed
      { account_generation; graph_generation; connection_generation }
    when connection_current t account_generation graph_generation connection_generation ->
    if is_backgrounded t then [] else challenge t Sync_auth.Http_pull
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
        begin_http_fallback t ()
      | Revalidating_websocket _
      | Disconnected
      | Awaiting_websocket_token
      | Connecting_websocket
      | Live_websocket _
      | Awaiting_http_pull_token
      | Http_pull_in_flight
      | Http_catchup_applied
      | Backing_off -> [])
  | Foreground_probe_timed_out _ -> []
  | Pending_batch payload -> route_submission t payload
  | Http_pull_loaded
      { account_generation; graph_generation; connection_generation; payload }
    when connection_current t account_generation graph_generation connection_generation
         && is_http_pull_in_flight (current_transport t) ->
    t.frame_application <- Applying_pull;
    [ apply_sync_frame_action t payload ]
  | Http_pull_loaded _ -> []
  | Http_transaction_loaded
      { account_generation; graph_generation; connection_generation; payload }
    when connection_current t account_generation graph_generation connection_generation ->
    t.submission <- No_submission;
    t.frame_application <- Applying_transaction;
    [ apply_sync_frame_action t payload ]
  | Http_transaction_loaded _ -> []
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
    let failed_probe =
      completed_pull
      && activity = Protocol.Sync_paused
      && is_revalidating transport_before_application
    in
    let requested_again =
      match t.pull with
      | Pull_idle -> false
      | Pull_in_flight { requested_again } -> requested_again
    in
    t.frame_application <- No_frame_application;
    if failed_probe
    then begin_http_fallback t ~last_error:"foreground probe replay failed" ()
    else (
      if completed_pull
      then (
        t.pull <- Pull_idle;
        match transport_before_application with
        | Revalidating_websocket _ ->
          set_current_transport t (Live_websocket { initialized = true })
        | Disconnected
        | Awaiting_websocket_token
        | Connecting_websocket
        | Live_websocket _
        | Awaiting_http_pull_token
        | Http_pull_in_flight
        | Http_catchup_applied
        | Backing_off -> ());
      if completed_pull && is_http_pull_in_flight transport_before_application
      then (
        Option.iter
          (fun payload ->
             match t.submission, decode_submission payload with
             | No_submission, Ok (payload, tx_ids) ->
               t.submission <- Deferred_submission { payload; tx_ids }
             | No_submission, Error message ->
               t.snapshot
               <- { t.snapshot with phase = Sync_paused; last_error = Some message }
             | ( ( Deferred_submission _
                 | Awaiting_http_submission_token _
                 | In_flight_submission _ )
               , _ ) -> ())
          pending_payload;
        if is_backgrounded t
        then (
          set_current_transport t Http_catchup_applied;
          [])
        else (
          let recovery =
            if t.recover_after_http_pull = []
            then []
            else [ recover_submitted_action t t.recover_after_http_pull ]
          in
          t.recover_after_http_pull <- [];
          recovery @ challenge t Sync_auth.Websocket_connect))
      else (
        let need_pull =
          requested_again
          ||
          match activity with
          | Protocol.Pull_required -> true
          | Pull_applied | Pull_duplicate | Sync_paused | Sync_submission_blocked -> false
        in
        let pull = if need_pull then request_pull t else [] in
        let pending =
          match pending_payload, t.submission with
          | Some payload, No_submission -> route_submission t payload
          | ( Some _
            , ( Deferred_submission _
              | Awaiting_http_submission_token _
              | In_flight_submission _ ) )
          | None, _ -> []
        in
        let deferred =
          if
            completed_pull
            && pull_is_idle t.pull
            && (not (is_backgrounded t))
            &&
            match current_transport t with
            | Live_websocket _ -> true
            | Disconnected
            | Awaiting_websocket_token
            | Connecting_websocket
            | Revalidating_websocket _
            | Awaiting_http_pull_token
            | Http_pull_in_flight
            | Http_catchup_applied
            | Backing_off -> false
          then (
            match t.submission with
            | Deferred_submission { payload; tx_ids } -> send_submission t payload tx_ids
            | No_submission | Awaiting_http_submission_token _ | In_flight_submission _ ->
              [])
          else []
        in
        pull @ pending @ deferred))
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
    then
      if is_revalidating (current_transport t)
      then begin_http_fallback t ~last_error:message ()
      else begin_scheduled_reconnect t ~message
    else []
  | Network_failed _ -> []
;;

let diagnostics t =
  Printf.sprintf
    "phase=%d account-generation=%d graph-generation=%d connection-generation=%d \
     pending-token-challenges=%d"
    (match t.snapshot.phase with
     | Signed_out -> 0
     | Awaiting_token _ -> 1
     | Loading_catalog -> 2
     | Awaiting_selection -> 3
     | Bootstrapping -> 4
     | Recovering_online _ -> 5
     | Awaiting_e2ee_password -> 6
     | Opening_graph -> 7
     | Graph_open -> 8
     | Sync_paused -> 9
     | Stopping_graph -> 10
     | Failed -> 11)
    t.snapshot.account_generation
    t.snapshot.graph_generation
    t.snapshot.connection_generation
    (Sync_auth.pending_count t.auth)
;;
