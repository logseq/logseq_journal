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
      ; connection_generation : int
      ; graph_id : Graph_types.Uuid.t
      ; since : int
      ; token : string
      }
  | Submit_http_transaction of
      { account_generation : int
      ; graph_generation : int
      ; connection_generation : int
      ; graph_id : Graph_types.Uuid.t
      ; payload : string
      ; token : string
      }
  | Delete_mirror of Graph_types.Uuid.t

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

let default_e2ee_platform =
  Sync_e2ee_session.
    { has_private_key = Sync_platform_crypto.has_private_key
    ; unlock_private_key = Sync_platform_crypto.unlock_private_key
    ; decrypt_graph_key = Sync_platform_crypto.unlock_graph_key
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
      }
  }
;;

let create ~next_challenge_id ~base_url =
  create_with_e2ee ~e2ee_platform:default_e2ee_platform ~next_challenge_id ~base_url
;;

let snapshot t = t.snapshot

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
      [ Send_websocket (pull_payload t) ]
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
  [ Send_websocket payload ]
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
      if purpose <> Sync_auth.Catalog_discovery || t.snapshot.selected_graph = None
      then t.snapshot <- { t.snapshot with phase = Awaiting_token purpose };
      [ Need_id_token challenge ])
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
            ~user_id
            ~graph_id:graph.Sync_catalog.graph_id
            ~graph_name:graph.name);
    challenge t Sync_auth.E2ee_key_access
;;

let open_selected_graph t ~account_generation ~graph_generation graph =
  if graph.Sync_catalog.encrypted
  then start_e2ee t graph Open_after_e2ee
  else (
    t.snapshot <- { t.snapshot with phase = Opening_graph };
    [ Open_graph
        { account_generation; graph_generation; graph; encrypted_graph_key = None }
    ])
;;

let resume_after_e2ee t graph encrypted_graph_key =
  match t.e2ee_continuation with
  | No_e2ee_continuation -> []
  | Open_after_e2ee ->
    t.e2ee_continuation <- No_e2ee_continuation;
    t.snapshot <- { t.snapshot with phase = Opening_graph; last_error = None };
    [ Open_graph
        { account_generation = t.snapshot.account_generation
        ; graph_generation = t.snapshot.graph_generation
        ; graph
        ; encrypted_graph_key = Some encrypted_graph_key
        }
    ]
  | Bootstrap_after_e2ee ->
    t.e2ee_continuation <- No_e2ee_continuation;
    t.bootstrap <- Awaiting_baseline;
    t.snapshot <- { t.snapshot with phase = Bootstrapping; last_error = None };
    challenge t Sync_auth.Snapshot_bootstrap
;;

let close_graph_effects t =
  match t.snapshot.selected_graph with
  | None -> []
  | Some _ -> [ Close_websocket; Close_graph ]
;;

let schedule_reconnect t =
  if is_backgrounded t
  then []
  else (
    match t.snapshot.user_id, t.snapshot.selected_graph, t.snapshot.applied_server_t with
    | Some _, Some _, Some _ ->
      let delay_seconds = min 30. (2. ** Float.of_int t.reconnect_attempt) in
      t.reconnect_attempt <- min 30 (t.reconnect_attempt + 1);
      [ Schedule_reconnect
          { account_generation = t.snapshot.account_generation
          ; graph_generation = t.snapshot.graph_generation
          ; connection_generation = t.snapshot.connection_generation
          ; delay_seconds
          }
      ]
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
  if is_backgrounded t then [] else Close_websocket :: challenge t Sync_auth.Http_pull
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
    (match challenge.purpose with
     | Sync_auth.Catalog_discovery ->
       if t.snapshot.selected_graph = None
       then t.snapshot <- { t.snapshot with phase = Loading_catalog };
       [ Fetch_catalog
           { account_generation = t.snapshot.account_generation
           ; base_url = t.base_url
           ; token
           }
       ]
     | Websocket_connect ->
       (match t.snapshot.selected_graph with
        | None -> []
        | Some graph_id ->
          set_current_transport t Connecting_websocket;
          [ Connect_websocket
              { account_generation = t.snapshot.account_generation
              ; graph_generation = t.snapshot.graph_generation
              ; connection_generation = t.snapshot.connection_generation
              ; graph_id
              ; token
              }
          ])
     | Snapshot_bootstrap ->
       (match selected t with
        | None -> []
        | Some graph ->
          let common account_generation graph_generation =
            account_generation, graph_generation
          in
          let account_generation, graph_generation =
            common t.snapshot.account_generation t.snapshot.graph_generation
          in
          (match t.bootstrap with
           | Awaiting_baseline ->
             [ Fetch_snapshot_baseline
                 { account_generation; graph_generation; graph; token }
             ]
           | Awaiting_metadata _ ->
             [ Fetch_snapshot_metadata
                 { account_generation; graph_generation; graph; token }
             ]
           | Awaiting_artifact (baseline, metadata) ->
             [ Download_snapshot_artifact
                 { account_generation
                 ; graph_generation
                 ; graph
                 ; baseline
                 ; metadata
                 ; token
                 }
             ]
           | Bootstrap_idle -> []))
     | E2ee_key_access ->
       (match selected t, t.e2ee with
        | Some graph, Some session ->
          (match Sync_e2ee_session.phase session with
           | Fetching_graph_key ->
             [ Fetch_e2ee_graph_key
                 { account_generation = t.snapshot.account_generation
                 ; graph_generation = t.snapshot.graph_generation
                 ; graph
                 ; token
                 }
             ]
           | Fetching_user_keys ->
             [ Fetch_e2ee_user_keys
                 { account_generation = t.snapshot.account_generation
                 ; graph_generation = t.snapshot.graph_generation
                 ; graph_id = graph.graph_id
                 ; token
                 }
             ]
           | Awaiting_password | Ready | Failed -> [])
        | _, _ -> [])
     | Http_pull ->
       (match
          ( t.snapshot.selected_graph
          , t.snapshot.applied_server_t
          , challenge.connection_generation
          , current_transport t )
        with
        | Some graph_id, Some since, Some connection_generation, Awaiting_http_pull_token
          when connection_generation = t.snapshot.connection_generation ->
          set_current_transport t Http_pull_in_flight;
          [ Fetch_http_pull
              { account_generation = t.snapshot.account_generation
              ; graph_generation = t.snapshot.graph_generation
              ; connection_generation
              ; graph_id
              ; since
              ; token
              }
          ]
        | _ -> [])
     | Transaction_submission ->
       (match t.snapshot.selected_graph, t.submission with
        | Some graph_id, Awaiting_http_submission_token { payload; tx_ids } ->
          t.submission <- In_flight_submission { payload; tx_ids };
          [ Submit_http_transaction
              { account_generation = t.snapshot.account_generation
              ; graph_generation = t.snapshot.graph_generation
              ; connection_generation = t.snapshot.connection_generation
              ; graph_id
              ; payload
              ; token
              }
          ]
        | None, _
        | Some _, (No_submission | Deferred_submission _ | In_flight_submission _) -> []))
;;

let handle_command t = function
  | Authenticated_user { user_id } ->
    let closing = close_graph_effects t in
    Sync_auth.cancel_all t.auth;
    t.bootstrap <- Bootstrap_idle;
    clear_e2ee t;
    t.reconnect_attempt <- 0;
    clear_transport_coordination t;
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
       };
    closing @ challenge t Sync_auth.Catalog_discovery
  | Signed_out_command ->
    let effects = close_graph_effects t in
    Sync_auth.cancel_all t.auth;
    t.bootstrap <- Bootstrap_idle;
    clear_e2ee t;
    t.reconnect_attempt <- 0;
    clear_transport_coordination t;
    t.snapshot
    <- { t.snapshot with
         phase = Signed_out
       ; account_generation = t.snapshot.account_generation + 1
       ; graph_generation = t.snapshot.graph_generation + 1
       ; connection_generation = t.snapshot.connection_generation + 1
       ; user_id = None
       ; catalog = []
       ; applied_server_t = None
       ; last_error = None
       };
    effects
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
            phase = Bootstrapping
          ; graph_generation = t.snapshot.graph_generation + 1
          ; connection_generation = 0
          ; selected_graph = Some graph_id
          ; applied_server_t = None
          ; last_error = None
          };
       closing
       @ [ Inspect_mirror
             { account_generation = t.snapshot.account_generation
             ; graph_generation = t.snapshot.graph_generation
             ; graph
             }
         ])
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
       t.snapshot
       <- { t.snapshot with
            phase = Awaiting_selection
          ; graph_generation = t.snapshot.graph_generation + 1
          ; connection_generation = t.snapshot.connection_generation + 1
          ; applied_server_t = None
          ; last_error = None
          };
       closing)
  | Refresh_catalog -> challenge t Sync_auth.Catalog_discovery
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
                 [ Send_websocket (Sync_protocol.encode_hello ~client:"logseq-journal") ]
             in
             let pull = request_pull t in
             hello
             @ pull
             @ [ Schedule_foreground_probe
                   { account_generation = t.snapshot.account_generation
                   ; graph_generation = t.snapshot.graph_generation
                   ; connection_generation = t.snapshot.connection_generation
                   ; lifecycle_generation
                   ; delay_seconds = 3.
                   }
               ]
           | Http_catchup_applied ->
             let recovery =
               if t.recover_after_http_pull = []
               then []
               else [ Recover_submitted t.recover_after_http_pull ]
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
     | Some graph, Some session ->
       (match Sync_e2ee_session.submit_password session password with
        | Ok () ->
          (match Sync_e2ee_session.encrypted_graph_key session with
           | Some encrypted_graph_key -> resume_after_e2ee t graph encrypted_graph_key
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
       [ Close_websocket; Close_graph; Delete_mirror graph_id ]
     | None | Some _ -> [ Delete_mirror graph_id ])
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

let handle_event t = function
  | Catalog_loaded { account_generation; graphs }
    when account_current t account_generation ->
    (match t.snapshot.selected_graph with
     | None ->
       t.snapshot
       <- { t.snapshot with
            phase = Awaiting_selection
          ; catalog = graphs
          ; last_error = None
          };
       []
     | Some selected_graph ->
       (match
          List.find_opt
            (fun graph ->
               Graph_types.Uuid.equal graph.Sync_catalog.graph_id selected_graph)
            graphs
        with
        | Some graph when t.snapshot.phase = Failed && t.snapshot.applied_server_t = None
          ->
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
          [ Close_websocket
          ; Close_graph
          ; Inspect_mirror { account_generation; graph_generation; graph }
          ]
        | Some _ ->
          t.snapshot <- { t.snapshot with catalog = graphs; last_error = None };
          []
        | None ->
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
          [ Close_websocket; Close_graph ]))
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
  | Mirror_missing { account_generation; graph_generation; graph_id }
    when graph_current t account_generation graph_generation
         && t.snapshot.selected_graph = Some graph_id ->
    (match selected t with
     | Some graph when graph.encrypted -> start_e2ee t graph Bootstrap_after_e2ee
     | Some _ ->
       t.snapshot <- { t.snapshot with phase = Bootstrapping };
       t.bootstrap <- Awaiting_baseline;
       challenge t Sync_auth.Snapshot_bootstrap
     | None -> [])
  | Mirror_missing _ -> []
  | Local_cache_deleted { account_generation; graph_generation; graph_id }
    when graph_current t account_generation graph_generation
         && t.snapshot.selected_graph = Some graph_id ->
    (match selected t with
     | None -> []
     | Some graph -> [ Inspect_mirror { account_generation; graph_generation; graph } ])
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
       [ Activate_snapshot
           { account_generation
           ; graph_generation
           ; graph
           ; server_t = baseline.server_t
           ; snapshot_path
           ; expected_rows
           ; graph_key = Option.bind t.e2ee Sync_e2ee_session.graph_key
           }
       ]
     | _, _ -> [])
  | Snapshot_artifact_ready _ -> []
  | E2ee_graph_key_loaded { account_generation; graph_generation; graph_id; response }
    when graph_current t account_generation graph_generation
         && t.snapshot.selected_graph = Some graph_id ->
    (match selected t, t.e2ee with
     | Some graph, Some session ->
       (match Sync_e2ee_session.accept_graph_key_response session response with
        | Error message ->
          t.snapshot <- { t.snapshot with phase = Failed; last_error = Some message };
          []
        | Ok () ->
          (match Sync_e2ee_session.phase session with
           | Fetching_user_keys -> challenge t Sync_auth.E2ee_key_access
           | Ready ->
             (match Sync_e2ee_session.encrypted_graph_key session with
              | Some encrypted_graph_key -> resume_after_e2ee t graph encrypted_graph_key
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
    challenge t Sync_auth.Websocket_connect
  | Graph_opened _ -> []
  | Websocket_opened { account_generation; graph_generation; connection_generation }
    when connection_current t account_generation graph_generation connection_generation ->
    set_current_transport t (Live_websocket { initialized = false });
    t.reconnect_attempt <- 0;
    t.snapshot <- { t.snapshot with phase = Graph_open; last_error = None };
    if is_backgrounded t
    then []
    else (
      set_current_transport t (Live_websocket { initialized = true });
      t.pull <- Pull_in_flight { requested_again = false };
      [ Send_websocket (Sync_protocol.encode_hello ~client:"logseq-journal")
      ; Send_websocket (pull_payload t)
      ])
  | Websocket_opened _ -> []
  | Websocket_frame
      { account_generation; graph_generation; connection_generation; payload }
    when connection_current t account_generation graph_generation connection_generation ->
    (match Sync_protocol.decode_server_message payload with
     | Ok (Changed _) -> request_pull t
     | Ok (Pull_ok _) ->
       t.frame_application <- Applying_pull;
       [ Apply_sync_frame payload ]
     | Ok (Tx_batch_ok _ | Tx_reject _) ->
       t.submission <- No_submission;
       t.frame_application <- Applying_transaction;
       [ Apply_sync_frame payload ]
     | Ok (Hello _ | Server_error _ | Pong) ->
       t.frame_application <- Applying_control;
       [ Apply_sync_frame payload ]
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
    [ Apply_sync_frame payload ]
  | Http_pull_loaded _ -> []
  | Http_transaction_loaded
      { account_generation; graph_generation; connection_generation; payload }
    when connection_current t account_generation graph_generation connection_generation ->
    t.submission <- No_submission;
    t.frame_application <- Applying_transaction;
    [ Apply_sync_frame payload ]
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
            else [ Recover_submitted t.recover_after_http_pull ]
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
    t.snapshot
    <- { t.snapshot with
         phase =
           (if Option.is_some t.snapshot.applied_server_t then Sync_paused else Failed)
       ; last_error = Some message
       };
    if Option.is_some graph_generation && Option.is_some t.snapshot.applied_server_t
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
     | Awaiting_e2ee_password -> 5
     | Opening_graph -> 6
     | Graph_open -> 7
     | Sync_paused -> 8
     | Stopping_graph -> 9
     | Failed -> 10)
    t.snapshot.account_generation
    t.snapshot.graph_generation
    t.snapshot.connection_generation
    (Sync_auth.pending_count t.auth)
;;
