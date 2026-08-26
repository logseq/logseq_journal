module T = Logseq_db_worker_test_support.Test_support
module Raw_manager = Logseq_db_worker.Sync_manager
module A = Logseq_db_worker.Sync_auth
module C = Logseq_db_worker.Sync_catalog
module Uuid = Logseq_db_worker.Graph_types.Uuid
module Typed_action = Logseq_db_worker.Sync_action
module Startup_phase = Logseq_db_worker.Sync_startup_phase

module M = struct
  include Raw_manager

  let latest_mirror_request = ref None
  let latest_wrapped_key_request = ref None
  let latest_private_key_request = ref None

  type action =
    | Need_id_token of A.challenge
    | Fetch_catalog of
        { account_generation : int
        ; base_url : Uri.t
        ; token : string
        }
    | Inspect_mirror of
        { account_generation : int
        ; graph_generation : int
        ; graph : C.graph
        }
    | Fetch_snapshot_baseline of
        { account_generation : int
        ; graph_generation : int
        ; graph : C.graph
        ; token : string
        }
    | Fetch_snapshot_metadata of
        { account_generation : int
        ; graph_generation : int
        ; graph : C.graph
        ; token : string
        }
    | Download_snapshot_artifact of
        { account_generation : int
        ; graph_generation : int
        ; graph : C.graph
        ; baseline : Logseq_db_worker.Sync_bootstrap.baseline
        ; metadata : Logseq_db_worker.Sync_bootstrap.snapshot_metadata
        ; token : string
        }
    | Activate_snapshot of
        { account_generation : int
        ; graph_generation : int
        ; graph : C.graph
        ; server_t : int
        ; snapshot_path : string
        ; expected_rows : int
        ; graph_key : string option
        }
    | Fetch_e2ee_graph_key of
        { account_generation : int
        ; graph_generation : int
        ; graph : C.graph
        ; token : string
        }
    | Fetch_e2ee_user_keys of
        { account_generation : int
        ; graph_generation : int
        ; graph_id : Uuid.t
        ; token : string
        }
    | Open_graph of
        { account_generation : int
        ; graph_generation : int
        ; graph : C.graph
        ; encrypted_graph_key : string option
        }
    | Close_graph
    | Connect_websocket of
        { account_generation : int
        ; graph_generation : int
        ; connection_generation : int
        ; graph_id : Uuid.t
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
    | Recover_submitted of Uuid.t list
    | Fetch_http_pull of
        { account_generation : int
        ; graph_generation : int
        ; connection_generation : int
        ; graph_id : Uuid.t
        ; since : int
        ; token : string
        }
    | Submit_http_transaction of
        { account_generation : int
        ; graph_generation : int
        ; connection_generation : int
        ; graph_id : Uuid.t
        ; payload : string
        ; token : string
        }
    | Delete_mirror of Uuid.t
    | Load_wrapped_graph_key
    | Save_wrapped_graph_key
    | Delete_wrapped_graph_key
    | Delete_account_secrets

  let graph_of_contract (graph : Typed_action.graph) =
    C.
      { graph_id = Uuid.of_string graph.graph_id |> Result.get_ok
      ; name = graph.name
      ; schema =
          { major = graph.schema_major
          ; minor = graph.schema_minor
          ; exact = graph.schema_exact
          }
      ; encrypted = graph.encrypted
      }
  ;;

  let challenge_of_scoped (challenge : Typed_action.scoped_challenge) =
    let account, graph_generation, connection_generation =
      match challenge.scope with
      | Account_scope account -> account, None, None
      | Graph_scope graph -> graph.account, Some graph.graph_generation, None
      | Connection_scope connection ->
        ( connection.graph.account
        , Some connection.graph.graph_generation
        , Some connection.connection_generation )
    in
    let purpose =
      match challenge.purpose with
      | Catalog_discovery_name -> A.Catalog_discovery
      | Snapshot_bootstrap_name -> Snapshot_bootstrap
      | E2ee_key_access_name -> E2ee_key_access
      | Http_pull_name -> Http_pull
      | Transaction_submission_name -> Transaction_submission
      | Websocket_connect_name -> Websocket_connect
    in
    A.
      { challenge_id = challenge.challenge_id
      ; purpose
      ; user_id = account.user_id
      ; account_generation = account.account_generation
      ; graph_generation
      ; connection_generation
      }
  ;;

  let graph_scope_of_request request =
    Startup_phase.local_request_graph_scope request |> Startup_phase.graph_scope_view
  ;;

  let view (Typed_action.Pack action) =
    match action with
    | Typed_action.Need_id_token challenge ->
      Need_id_token (challenge_of_scoped challenge)
    | Fetch_catalog { scope; token } ->
      Fetch_catalog
        { account_generation = scope.account_generation
        ; base_url = scope.managed_sync_origin
        ; token
        }
    | Inspect_mirror { request; graph } ->
      latest_mirror_request := Some request;
      let scope = graph_scope_of_request request in
      Inspect_mirror
        { account_generation = scope.account.account_generation
        ; graph_generation = scope.graph_generation
        ; graph = graph_of_contract graph
        }
    | Load_and_verify_wrapped_graph_key
        { wrapped_key_request; private_key_request } ->
      latest_wrapped_key_request := Some wrapped_key_request;
      latest_private_key_request := Some private_key_request;
      Load_wrapped_graph_key
    | Verify_and_save_wrapped_graph_key _ -> Save_wrapped_graph_key
    | Delete_wrapped_graph_key _ -> Delete_wrapped_graph_key
    | Delete_account_secrets _ -> Delete_account_secrets
    | Open_graph { request; graph; encrypted_graph_key } ->
      let scope = graph_scope_of_request request in
      Open_graph
        { account_generation = scope.account.account_generation
        ; graph_generation = scope.graph_generation
        ; graph = graph_of_contract graph
        ; encrypted_graph_key =
            Option.map Typed_action.wrapped_graph_key_to_string encrypted_graph_key
        }
    | Close_graph -> Close_graph
    | Delete_mirror { scope } ->
      Delete_mirror (Uuid.of_string scope.graph_id |> Result.get_ok)
    | Fetch_snapshot_baseline { scope; graph; token } ->
      Fetch_snapshot_baseline
        { account_generation = scope.account.account_generation
        ; graph_generation = scope.graph_generation
        ; graph = graph_of_contract graph
        ; token
        }
    | Fetch_snapshot_metadata { scope; graph; token } ->
      Fetch_snapshot_metadata
        { account_generation = scope.account.account_generation
        ; graph_generation = scope.graph_generation
        ; graph = graph_of_contract graph
        ; token
        }
    | Download_snapshot_artifact { scope; graph; baseline; metadata; token } ->
      Download_snapshot_artifact
        { account_generation = scope.account.account_generation
        ; graph_generation = scope.graph_generation
        ; graph = graph_of_contract graph
        ; baseline = { server_t = baseline.server_t }
        ; metadata =
            { key = metadata.key
            ; url = metadata.url
            ; content_encoding = Some metadata.content_encoding
            }
        ; token
        }
    | Activate_snapshot
        { scope; graph; server_t; snapshot_path; expected_rows; encrypted_graph_key } ->
      Activate_snapshot
        { account_generation = scope.account.account_generation
        ; graph_generation = scope.graph_generation
        ; graph = graph_of_contract graph
        ; server_t
        ; snapshot_path
        ; expected_rows
        ; graph_key =
            Option.map Typed_action.wrapped_graph_key_to_string encrypted_graph_key
        }
    | Fetch_e2ee_graph_key { scope; graph; token } ->
      Fetch_e2ee_graph_key
        { account_generation = scope.account.account_generation
        ; graph_generation = scope.graph_generation
        ; graph = graph_of_contract graph
        ; token
        }
    | Fetch_e2ee_user_keys { scope; token } ->
      Fetch_e2ee_user_keys
        { account_generation = scope.account.account_generation
        ; graph_generation = scope.graph_generation
        ; graph_id = Uuid.of_string scope.graph_id |> Result.get_ok
        ; token
        }
    | Connect_websocket { scope; token } ->
      Connect_websocket
        { account_generation = scope.graph.account.account_generation
        ; graph_generation = scope.graph.graph_generation
        ; connection_generation = scope.connection_generation
        ; graph_id = Uuid.of_string scope.graph.graph_id |> Result.get_ok
        ; token
        }
    | Close_websocket -> Close_websocket
    | Send_websocket { payload; _ } -> Send_websocket payload
    | Schedule_reconnect { scope; delay_seconds } ->
      Schedule_reconnect
        { account_generation = scope.graph.account.account_generation
        ; graph_generation = scope.graph.graph_generation
        ; connection_generation = scope.connection_generation
        ; delay_seconds
        }
    | Schedule_foreground_probe { scope; delay_seconds } ->
      Schedule_foreground_probe
        { account_generation = scope.graph.account.account_generation
        ; graph_generation = scope.graph.graph_generation
        ; connection_generation = scope.connection_generation
        ; lifecycle_generation = scope.lifecycle_generation
        ; delay_seconds
        }
    | Apply_sync_frame { frame; _ } -> Apply_sync_frame frame
    | Recover_submitted { transaction_ids; _ } ->
      Recover_submitted
        (List.map (fun id -> Uuid.of_string id |> Result.get_ok) transaction_ids)
    | Fetch_http_pull { scope; since; token } ->
      Fetch_http_pull
        { account_generation = scope.graph.account.account_generation
        ; graph_generation = scope.graph.graph_generation
        ; connection_generation = scope.connection_generation
        ; graph_id = Uuid.of_string scope.graph.graph_id |> Result.get_ok
        ; since
        ; token
        }
    | Submit_http_transaction { scope; payload; token } ->
      Submit_http_transaction
        { account_generation = scope.graph.account.account_generation
        ; graph_generation = scope.graph.graph_generation
        ; connection_generation = scope.connection_generation
        ; graph_id = Uuid.of_string scope.graph.graph_id |> Result.get_ok
        ; payload
        ; token
        }
  ;;

  let handle_command manager command =
    Raw_manager.handle_command manager command |> List.map view
  ;;

  let handle_event manager event = Raw_manager.handle_event manager event |> List.map view

  let mirror_failure_receipt diagnostic =
    match !latest_mirror_request with
    | Some request -> Startup_phase.Local_completion.mirror_failed request ~diagnostic
    | None -> T.fail "no mirror request is available for a failure receipt"
  ;;

  let wrapped_key_failure_receipt diagnostic =
    match !latest_wrapped_key_request with
    | Some request ->
      Raw_manager.Wrapped_key_failure_receipt
        (Startup_phase.Local_completion.wrapped_graph_key_failed request ~diagnostic)
    | None -> T.fail "no wrapped-key request is available for a failure receipt"
  ;;

  let private_key_failure_receipt diagnostic =
    match !latest_private_key_request with
    | Some request ->
      Raw_manager.Private_key_failure_receipt
        (Startup_phase.Local_completion.local_private_key_failed request ~diagnostic)
    | None -> T.fail "no private-key request is available for a failure receipt"
  ;;
end

let contains text needle =
  let rec loop offset =
    if offset + String.length needle > String.length text
    then false
    else if String.sub text offset (String.length needle) = needle
    then true
    else loop (offset + 1)
  in
  String.length needle = 0 || loop 0
;;

let graph_id = Uuid.of_string "10000000-0000-4000-8000-000000000001" |> Result.get_ok

let other_graph_id =
  Uuid.of_string "10000000-0000-4000-8000-000000000002" |> Result.get_ok
;;

let graph graph_id name =
  C.
    { graph_id
    ; name
    ; schema = { major = 65; minor = 33; exact = true }
    ; encrypted = false
    }
;;

let encrypted_graph graph_id name =
  C.
    { graph_id
    ; name
    ; schema = { major = 65; minor = 33; exact = true }
    ; encrypted = true
    }
;;

let next_challenge_id =
  let current = ref 0 in
  fun () ->
    incr current;
    Printf.sprintf "manager-challenge-%d" !current
;;

let need_token = function
  | [ M.Need_id_token challenge ] -> challenge
  | _ -> T.fail "manager did not request exactly one token challenge"
;;

let provide manager challenge token =
  M.handle_command
    manager
    (Provide_id_token
       { challenge_id = challenge.A.challenge_id
       ; user_id = challenge.user_id
       ; account_generation = challenge.account_generation
       ; graph_generation = challenge.graph_generation
       ; connection_generation = challenge.connection_generation
       ; token
       })
;;

let restore_local_catalog manager =
  let effects =
    M.handle_command
      manager
      (Restore_local_account
         { user_id = "user-1"; managed_sync_origin = "https://api.logseq.io" })
  in
  T.require (effects = []) "local account restore emitted online work";
  let snapshot = M.snapshot manager in
  T.require
    (snapshot.user_id = Some "user-1" && snapshot.startup_presentation = Restoring_local)
    "local account restore did not enter the local startup lane";
  let effects =
    M.handle_event
      manager
      (Cached_catalog_loaded
         { account_generation = snapshot.account_generation
         ; graphs = [ graph graph_id "First"; graph other_graph_id "Second" ]
         })
  in
  T.require (effects = []) "cached catalog restore emitted online work";
  ignore (M.handle_command manager (Select_graph graph_id))
;;

let open_restored_graph manager cursor =
  restore_local_catalog manager;
  let snapshot = M.snapshot manager in
  let open_effects =
    M.handle_event
      manager
      (Mirror_ready
         { account_generation = snapshot.account_generation
         ; graph_generation = snapshot.graph_generation
         ; graph_id
         })
  in
  T.require
    (match open_effects with
     | [ Open_graph _ ] -> true
     | _ -> false)
    "restored mirror did not open locally";
  let before_graph_open = M.snapshot manager in
  let graph_opened =
    M.handle_event
      manager
      (Graph_opened
         { account_generation = before_graph_open.account_generation
         ; graph_generation = before_graph_open.graph_generation
         ; graph_id
         ; applied_server_t = cursor
         })
  in
  T.require
    (graph_opened = [])
    "offline-ready graph open constructed network work before Timeline presentation";
  T.require
    ((M.snapshot manager).phase = before_graph_open.phase)
    "local graph open changed the startup presentation phase"
;;

let present_restored_timeline manager =
  let snapshot = M.snapshot manager in
  let account_generation = snapshot.account_generation in
  let graph_generation = snapshot.graph_generation in
  let presentation_generation = snapshot.presentation_generation in
  T.require
    (M.handle_command
       manager
       (Local_feed_ready { account_generation; graph_generation; presentation_generation })
     = [])
    "local feed readiness emitted online work";
  M.handle_command
    manager
    (Timeline_presented { account_generation; graph_generation; presentation_generation })
;;

let test_local_restore_is_independent_from_authentication_and_network () =
  let manager =
    M.create ~next_challenge_id ~base_url:(Uri.of_string "https://api.logseq.io")
  in
  open_restored_graph manager 41;
  let snapshot = M.snapshot manager in
  T.require
    (snapshot.applied_server_t = Some 41
     && snapshot.startup_presentation = Restoring_local)
    "local graph open waited for online reconciliation";
  let catalog_challenge =
    let effects =
      M.handle_command
        manager
        (Reconcile_authenticated_user
           { user_id = Some "user-1"; managed_sync_origin = "https://api.logseq.io" })
    in
    T.require
      (effects = [])
      "authenticated reconciliation constructed network work before Timeline presentation";
    present_restored_timeline manager |> need_token
  in
  T.require
    (catalog_challenge.purpose = Catalog_discovery)
    "online reconciliation requested the wrong token";
  ignore
    (M.handle_command
       manager
       (Token_failed { challenge_id = catalog_challenge.challenge_id }));
  let failed = M.snapshot manager in
  T.require
    (failed.applied_server_t = Some 41
     && failed.selected_graph = Some graph_id
     && failed.startup_presentation = Reconciled)
    "network failure preempted the restored graph"
;;

let test_offline_eof_does_not_preempt_local_timeline () =
  let manager =
    M.create ~next_challenge_id ~base_url:(Uri.of_string "https://api.logseq.io")
  in
  open_restored_graph manager 41;
  let before = M.snapshot manager in
  ignore
    (M.handle_event
       manager
       (Network_failed
          { account_generation = before.account_generation
          ; graph_generation = Some before.graph_generation
          ; connection_generation = Some before.connection_generation
          ; message = "End_of_file"
          }));
  let offline = M.snapshot manager in
  T.require
    (offline.phase = before.phase
     && offline.selected_graph = Some graph_id
     && offline.applied_server_t = Some 41
     && offline.startup_presentation = Restoring_local)
    "offline EOF changed the local startup route before Timeline presentation";
  T.require
    (offline.last_error = Some "Network unavailable")
    "offline EOF exposed an internal exception name";
  ignore (present_restored_timeline manager);
  T.require
    ((M.snapshot manager).selected_graph = Some graph_id)
    "offline EOF removed the local graph after Timeline presentation"
;;

let test_online_reconciliation_is_fenced_until_timeline_presentation () =
  let manager =
    M.create ~next_challenge_id ~base_url:(Uri.of_string "https://api.logseq.io")
  in
  open_restored_graph manager 41;
  let snapshot = M.snapshot manager in
  let revoked =
    M.handle_event
      manager
      (Catalog_loaded
         { account_generation = snapshot.account_generation
         ; graphs = [ graph other_graph_id "Second" ]
         })
  in
  T.require (revoked = []) "catalog revocation closed the graph before presentation";
  T.require
    ((M.snapshot manager).selected_graph = Some graph_id)
    "catalog revocation cleared the restored selection before presentation";
  let effects = present_restored_timeline manager in
  T.require
    (match effects with
     | [ Close_websocket; Close_graph ] -> true
     | _ -> false)
    "pending catalog revocation was not applied after presentation";
  T.require
    ((M.snapshot manager).startup_presentation = Reconciled
     && (M.snapshot manager).selected_graph = None)
    "post-presentation reconciliation retained the revoked graph"
;;

let test_account_replacement_is_fenced_until_timeline_presentation () =
  let manager =
    M.create ~next_challenge_id ~base_url:(Uri.of_string "https://api.logseq.io")
  in
  open_restored_graph manager 41;
  let before = M.snapshot manager in
  let effects =
    M.handle_command
      manager
      (Reconcile_authenticated_user
         { user_id = Some "user-2"; managed_sync_origin = "https://api.logseq.io" })
  in
  T.require (effects = []) "account replacement closed the graph before presentation";
  T.require
    ((M.snapshot manager).account_generation = before.account_generation)
    "account replacement fenced the local lane too early";
  let effects = present_restored_timeline manager in
  T.require
    (match effects with
     | [ Close_websocket; Close_graph; Delete_account_secrets; Need_id_token challenge ] ->
       String.equal challenge.user_id "user-2"
     | _ -> false)
    "account replacement was not applied after presentation"
;;

let test_websocket_pull_waits_for_timeline_presentation () =
  let manager =
    M.create ~next_challenge_id ~base_url:(Uri.of_string "https://api.logseq.io")
  in
  restore_local_catalog manager;
  let snapshot = M.snapshot manager in
  ignore
    (M.handle_event
       manager
       (Mirror_ready
          { account_generation = snapshot.account_generation
          ; graph_generation = snapshot.graph_generation
          ; graph_id
          }));
  let opened =
    M.handle_event
      manager
      (Graph_opened
         { account_generation = snapshot.account_generation
         ; graph_generation = snapshot.graph_generation
         ; graph_id
         ; applied_server_t = 41
         })
  in
  T.require
    (opened = [])
    "graph open constructed WebSocket authentication before Timeline presentation";
  let challenge = present_restored_timeline manager |> need_token in
  ignore (provide manager challenge "websocket-token");
  let connected = M.snapshot manager in
  let handshake =
    M.handle_event
      manager
      (Websocket_opened
         { account_generation = connected.account_generation
         ; graph_generation = connected.graph_generation
         ; connection_generation = connected.connection_generation
         })
  in
  T.require
    (handshake
     = [ Send_websocket
           (Logseq_db_worker.Sync_protocol.encode_hello ~client:"logseq-journal")
       ; Send_websocket (Logseq_db_worker.Sync_protocol.encode_pull ~since:41)
       ])
    "post-presentation WebSocket handshake did not request hello and initial pull"
;;

let authenticate_and_load_catalog manager =
  let challenge =
    M.handle_command manager (Authenticated_user { user_id = "user-1" }) |> need_token
  in
  T.require (challenge.purpose = Catalog_discovery) "wrong first token purpose";
  let effects = provide manager challenge "catalog-token" in
  (match effects with
   | [ Fetch_catalog { token; _ } ] ->
     T.require (String.equal token "catalog-token") "catalog token changed"
   | _ -> T.fail "catalog fetch was not started");
  T.require ((M.snapshot manager).phase = Loading_catalog) "catalog phase was not entered";
  ignore
    (M.handle_event
       manager
       (Catalog_loaded
          { account_generation = (M.snapshot manager).account_generation
          ; graphs = [ graph graph_id "First"; graph other_graph_id "Second" ]
          }))
;;

let test_mirror_inspection_precedes_truthful_bootstrap_phase () =
  let manager =
    M.create ~next_challenge_id ~base_url:(Uri.of_string "https://api.logseq.io")
  in
  restore_local_catalog manager;
  let inspecting = M.snapshot manager in
  T.require
    (inspecting.phase = Opening_graph)
    "local mirror inspection was presented as a graph download";
  let local_failure =
    M.handle_event
      manager
      (Mirror_missing
         { account_generation = inspecting.account_generation
         ; graph_generation = inspecting.graph_generation
         ; graph_id
         ; receipt = M.mirror_failure_receipt "mirror missing"
         })
  in
  T.require
    (local_failure = [])
    "a confirmed missing mirror emitted network work in its local transition";
  T.require
    ((M.snapshot manager).phase = Recovering_online Startup_phase.Mirror_unavailable)
    "a confirmed missing mirror did not enter explicit online recovery";
  let challenge = M.handle_command manager Begin_online_recovery |> need_token in
  T.require
    ((M.snapshot manager).phase = Bootstrapping)
    "consuming mirror recovery did not enter the graph download phase";
  T.require
    (challenge.purpose = Snapshot_bootstrap)
    "a confirmed missing mirror requested the wrong authenticated operation"
;;

type live_context =
  { manager : M.t
  ; account_generation : int
  ; graph_generation : int
  ; connection_generation : int
  }

let open_live_manager cursor =
  let manager =
    M.create ~next_challenge_id ~base_url:(Uri.of_string "https://api.logseq.io")
  in
  authenticate_and_load_catalog manager;
  ignore (M.handle_command manager (Select_graph graph_id));
  let account_generation = (M.snapshot manager).account_generation in
  let graph_generation = (M.snapshot manager).graph_generation in
  ignore
    (M.handle_event
       manager
       (Mirror_ready { account_generation; graph_generation; graph_id }));
  let graph_opened =
    M.handle_event
      manager
      (Graph_opened
         { account_generation; graph_generation; graph_id; applied_server_t = cursor })
  in
  T.require (graph_opened = []) "graph open bypassed Timeline presentation";
  let challenge = present_restored_timeline manager |> need_token in
  ignore (provide manager challenge "websocket-token");
  let connection_generation = (M.snapshot manager).connection_generation in
  ignore
    (M.handle_event
       manager
       (Websocket_opened { account_generation; graph_generation; connection_generation }));
  let payload = Printf.sprintf {|{"type":"pull/ok","t":%d,"txs":[]}|} cursor in
  ignore
    (M.handle_event
       manager
       (Websocket_frame
          { account_generation; graph_generation; connection_generation; payload }));
  ignore
    (M.handle_event
       manager
       (Sync_applied
          { account_generation
          ; graph_generation
          ; applied_server_t = cursor
          ; activity = Logseq_db_worker.Protocol.Pull_duplicate
          ; pending_payload = None
          }));
  { manager; account_generation; graph_generation; connection_generation }
;;

let batch_payload tx_id =
  Printf.sprintf
    {|{"type":"tx/batch","t-before":21,"txs":[{"tx":"[]","tx-id":"%s"}]}|}
    tx_id
;;

let test_long_lived_lifecycle_and_foreground_handshake () =
  let manager =
    M.create ~next_challenge_id ~base_url:(Uri.of_string "https://api.logseq.io")
  in
  T.require ((M.snapshot manager).phase = Signed_out) "manager opened a graph at startup";
  authenticate_and_load_catalog manager;
  T.require
    ((M.snapshot manager).phase = Awaiting_selection)
    "catalog did not reach selection";
  let inspect = M.handle_command manager (Select_graph graph_id) in
  let account_generation = (M.snapshot manager).account_generation in
  let graph_generation = (M.snapshot manager).graph_generation in
  (match inspect with
   | [ Inspect_mirror { graph = selected; _ } ] ->
     T.require (Uuid.equal selected.graph_id graph_id) "wrong graph mirror inspected"
   | _ -> T.fail "selection did not inspect the local mirror");
  let open_effects =
    M.handle_event
      manager
      (Mirror_ready { account_generation; graph_generation; graph_id })
  in
  T.require ((M.snapshot manager).phase = Opening_graph) "ready mirror did not enter open";
  T.require
    (match open_effects with
     | [ Open_graph _ ] -> true
     | _ -> false)
    "ready mirror did not request serialized engine open";
  let graph_opened =
    M.handle_event
      manager
      (Graph_opened
         { account_generation; graph_generation; graph_id; applied_server_t = 41 })
  in
  T.require (graph_opened = []) "graph open bypassed Timeline presentation";
  let token_challenge = present_restored_timeline manager |> need_token in
  T.require
    (token_challenge.purpose = Websocket_connect)
    "graph open requested wrong token";
  let connect = provide manager token_challenge "websocket-token" in
  let connection_generation = (M.snapshot manager).connection_generation in
  T.require
    (match connect with
     | [ Connect_websocket { token; _ } ] -> String.equal token "websocket-token"
     | _ -> false)
    "WebSocket connect did not consume its fresh token";
  let handshake =
    M.handle_event
      manager
      (Websocket_opened { account_generation; graph_generation; connection_generation })
  in
  T.require
    ((M.snapshot manager).phase = Graph_open)
    "WebSocket open did not expose graph";
  T.require
    (handshake
     = [ Send_websocket
           (Logseq_db_worker.Sync_protocol.encode_hello ~client:"logseq-journal")
       ; Send_websocket (Logseq_db_worker.Sync_protocol.encode_pull ~since:41)
       ])
    "manager did not own foreground hello and pull"
;;

let test_graph_switch_signout_and_late_event_fences () =
  let manager =
    M.create ~next_challenge_id ~base_url:(Uri.of_string "https://api.logseq.io")
  in
  authenticate_and_load_catalog manager;
  ignore (M.handle_command manager (Select_graph graph_id));
  let picker_generation = (M.snapshot manager).graph_generation in
  let picker = M.handle_command manager Return_to_graph_picker in
  T.require
    (picker = [ Close_websocket; Close_graph ])
    "graph picker did not close transport and engine first";
  T.require
    ((M.snapshot manager).phase = Awaiting_selection
     && (M.snapshot manager).graph_generation > picker_generation)
    "graph picker did not fence old graph work";
  ignore (M.handle_command manager (Select_graph graph_id));
  let old_account = (M.snapshot manager).account_generation in
  let old_graph = (M.snapshot manager).graph_generation in
  let effects = M.handle_command manager (Select_graph other_graph_id) in
  T.require
    (match effects with
     | [ Close_websocket; Close_graph; Inspect_mirror _ ] -> true
     | _ -> false)
    "graph switch did not close transport and engine before inspecting next mirror";
  T.require
    ((M.snapshot manager).graph_generation > old_graph)
    "graph switch did not fence old work";
  let before = M.snapshot manager in
  let late =
    M.handle_event
      manager
      (Websocket_frame
         { account_generation = old_account
         ; graph_generation = old_graph
         ; connection_generation = 0
         ; payload = {|{"type":"changed","t":99}|}
         })
  in
  T.require (late = []) "late frame produced an effect";
  T.require (M.snapshot manager = before) "late frame changed manager state";
  let signout = M.handle_command manager Signed_out_command in
  T.require
    (match signout with
     | [ Close_websocket; Close_graph; Delete_account_secrets ] -> true
     | _ -> false)
    "sign-out did not close network before engine";
  let signed_out = M.snapshot manager in
  T.require
    (signed_out.phase = Signed_out && signed_out.user_id = None)
    "sign-out retained account state";
  T.require
    (not (contains (M.diagnostics manager) "catalog-token"))
    "manager diagnostics exposed token material"
;;

let test_authenticated_account_replacement_closes_graph_first () =
  let manager =
    M.create ~next_challenge_id ~base_url:(Uri.of_string "https://api.logseq.io")
  in
  authenticate_and_load_catalog manager;
  ignore (M.handle_command manager (Select_graph graph_id));
  let old_account_generation = (M.snapshot manager).account_generation in
  let actions = M.handle_command manager (Authenticated_user { user_id = "user-2" }) in
  T.require
    (match actions with
     | [ Close_websocket; Close_graph; Delete_account_secrets; Need_id_token challenge ] ->
       challenge.purpose = Catalog_discovery && String.equal challenge.user_id "user-2"
     | _ -> false)
    "authenticated account replacement did not close the old graph before discovery";
  T.require
    ((M.snapshot manager).account_generation > old_account_generation)
    "authenticated account replacement did not fence old work"
;;

let test_confirmed_local_cache_reset_immediately_redownloads () =
  let manager =
    M.create ~next_challenge_id ~base_url:(Uri.of_string "https://api.logseq.io")
  in
  authenticate_and_load_catalog manager;
  ignore (M.handle_command manager (Select_graph graph_id));
  let actions = M.handle_command manager (Delete_local_cache graph_id) in
  T.require
    (match actions with
     | [ Close_websocket; Close_graph; Delete_wrapped_graph_key; Delete_mirror deleted ] ->
       Uuid.equal deleted graph_id
     | _ -> false)
    "confirmed cache reset did not close the graph before deletion";
  let snapshot = M.snapshot manager in
  T.require
    (snapshot.phase = Bootstrapping && snapshot.selected_graph = Some graph_id)
    "confirmed cache reset did not retain the selected graph for redownload";
  let redownload =
    M.handle_event
      manager
      (Local_cache_deleted
         { account_generation = snapshot.account_generation
         ; graph_generation = snapshot.graph_generation
         ; graph_id
         })
  in
  T.require
    (match redownload with
     | [ Inspect_mirror { graph; graph_generation; _ } ] ->
       Uuid.equal graph.graph_id graph_id
       && graph_generation = (M.snapshot manager).graph_generation
     | _ -> false)
    "successful cache deletion did not inspect the mirror for redownload"
;;

let test_reconnect_uses_fresh_token_and_frames_enter_serial_owner () =
  let manager =
    M.create ~next_challenge_id ~base_url:(Uri.of_string "https://api.logseq.io")
  in
  authenticate_and_load_catalog manager;
  ignore (M.handle_command manager (Select_graph graph_id));
  let account_generation = (M.snapshot manager).account_generation in
  let graph_generation = (M.snapshot manager).graph_generation in
  ignore
    (M.handle_event
       manager
       (Mirror_ready { account_generation; graph_generation; graph_id }));
  let graph_opened =
    M.handle_event
      manager
      (Graph_opened
         { account_generation; graph_generation; graph_id; applied_server_t = 12 })
  in
  T.require (graph_opened = []) "graph open bypassed Timeline presentation";
  let first = present_restored_timeline manager |> need_token in
  ignore (provide manager first "first-websocket-token");
  let old_connection = (M.snapshot manager).connection_generation in
  let reconnect_timer =
    M.handle_event
      manager
      (Websocket_closed
         { account_generation
         ; graph_generation
         ; connection_generation = old_connection
         ; message = "closed"
         })
  in
  let reconnect_generation = (M.snapshot manager).connection_generation in
  let delay_seconds =
    match reconnect_timer with
    | [ Schedule_reconnect { connection_generation; delay_seconds; _ } ] ->
      T.require
        (connection_generation = reconnect_generation)
        "reconnect timer used the wrong connection generation";
      delay_seconds
    | _ -> T.fail "disconnect did not schedule exactly one reconnect timer"
  in
  T.require (delay_seconds >= 1. && delay_seconds <= 30.) "reconnect delay is unbounded";
  let reconnect =
    M.handle_event
      manager
      (Reconnect_timer_elapsed
         { account_generation
         ; graph_generation
         ; connection_generation = reconnect_generation
         })
    |> need_token
  in
  T.require
    (reconnect.purpose = Http_pull)
    "disconnect did not request an HTTP catch-up token";
  T.require
    ((M.snapshot manager).connection_generation > old_connection)
    "reconnect did not increment connection generation";
  let http_pull = provide manager reconnect "fresh-pull-token" in
  T.require
    (match http_pull with
     | [ Fetch_http_pull { token; since = 12; _ } ] ->
       String.equal token "fresh-pull-token"
     | _ -> false)
    "disconnect did not start an independently authenticated HTTP pull";
  let pull_frame = {|{"type":"pull/ok","t":12,"txs":[]}|} in
  T.require
    (M.handle_event
       manager
       (Http_pull_loaded
          { account_generation
          ; graph_generation
          ; connection_generation = reconnect_generation
          ; payload = pull_frame
          })
     = [ Apply_sync_frame pull_frame ])
    "HTTP pull bypassed the serialized sync decoder";
  let websocket_reconnect =
    M.handle_event
      manager
      (Sync_applied
         { account_generation
         ; graph_generation
         ; applied_server_t = 12
         ; activity = Logseq_db_worker.Protocol.Pull_applied
         ; pending_payload = None
         })
    |> need_token
  in
  T.require
    (websocket_reconnect.purpose = Websocket_connect)
    "HTTP catch-up did not request a fresh reconnect token";
  ignore (provide manager websocket_reconnect "fresh-websocket-token");
  let current_connection = (M.snapshot manager).connection_generation in
  ignore
    (M.handle_event
       manager
       (Websocket_opened
          { account_generation
          ; graph_generation
          ; connection_generation = current_connection
          }));
  let frame = {|{"type":"pull/ok","t":12,"txs":[]}|} in
  let effects =
    M.handle_event
      manager
      (Websocket_frame
         { account_generation
         ; graph_generation
         ; connection_generation = current_connection
         ; payload = frame
         })
  in
  T.require
    (effects = [ Apply_sync_frame frame ])
    "network frame bypassed or failed to enter the serialized owner";
  let pending = batch_payload "33000000-0000-4000-8000-000000000010" in
  let after_apply =
    M.handle_event
      manager
      (Sync_applied
         { account_generation
         ; graph_generation
         ; applied_server_t = 13
         ; activity = Logseq_db_worker.Protocol.Pull_required
         ; pending_payload = Some pending
         })
  in
  T.require
    ((M.snapshot manager).applied_server_t = Some 13)
    "durable cursor did not advance";
  T.require
    (after_apply
     = [ Send_websocket (Logseq_db_worker.Sync_protocol.encode_pull ~since:13)
       ; Send_websocket pending
       ])
    "serialized replay outcome did not drive pull and pending submission"
;;

let test_network_failure_retries_with_bounded_backoff () =
  let manager =
    M.create ~next_challenge_id ~base_url:(Uri.of_string "https://api.logseq.io")
  in
  authenticate_and_load_catalog manager;
  ignore (M.handle_command manager (Select_graph graph_id));
  let account_generation = (M.snapshot manager).account_generation in
  let graph_generation = (M.snapshot manager).graph_generation in
  ignore
    (M.handle_event
       manager
       (Mirror_ready { account_generation; graph_generation; graph_id }));
  ignore
    (M.handle_event
       manager
       (Graph_opened
          { account_generation; graph_generation; graph_id; applied_server_t = 12 }));
  ignore (present_restored_timeline manager);
  let first =
    M.handle_event
      manager
      (Network_failed
         { account_generation
         ; graph_generation = Some graph_generation
         ; connection_generation = None
         ; message = "offline"
         })
  in
  let first_delay =
    match first with
    | [ Schedule_reconnect { delay_seconds; _ } ] -> delay_seconds
    | _ -> T.fail "open graph network failure did not schedule reconnect"
  in
  let second =
    M.handle_event
      manager
      (Network_failed
         { account_generation
         ; graph_generation = Some graph_generation
         ; connection_generation = None
         ; message = "offline"
         })
  in
  let second_delay =
    match second with
    | [ Schedule_reconnect { delay_seconds; _ } ] -> delay_seconds
    | _ -> T.fail "repeated network failure did not schedule reconnect"
  in
  T.require (second_delay > first_delay) "reconnect backoff did not increase";
  T.require (second_delay <= 30.) "reconnect backoff exceeded its bound"
;;

let test_preopen_network_failure_is_terminal_for_current_attempt () =
  let manager =
    M.create ~next_challenge_id ~base_url:(Uri.of_string "https://api.logseq.io")
  in
  authenticate_and_load_catalog manager;
  ignore (M.handle_command manager (Select_graph graph_id));
  let snapshot = M.snapshot manager in
  let actions =
    M.handle_event
      manager
      (Network_failed
         { account_generation = snapshot.account_generation
         ; graph_generation = Some snapshot.graph_generation
         ; connection_generation = None
         ; message = "bootstrap failed"
         })
  in
  T.require (actions = []) "pre-open failure scheduled a transport reconnect";
  T.require
    ((M.snapshot manager).phase = Failed)
    "pre-open failure was presented as an offline-open graph";
  let refresh = M.handle_command manager Refresh_catalog |> need_token in
  ignore (provide manager refresh "refresh-token");
  let failed = M.snapshot manager in
  let retry =
    M.handle_event
      manager
      (Catalog_loaded
         { account_generation = failed.account_generation
         ; graphs = [ graph graph_id "First"; graph other_graph_id "Second" ]
         })
  in
  T.require
    (match retry with
     | [ Close_websocket; Close_graph; Inspect_mirror { graph; _ } ] ->
       Uuid.equal graph.graph_id graph_id
     | _ -> false)
    "successful catalog retry did not restart the failed graph open"
;;

let test_pending_batch_uses_authenticated_http_when_socket_is_unavailable () =
  let manager =
    M.create ~next_challenge_id ~base_url:(Uri.of_string "https://api.logseq.io")
  in
  authenticate_and_load_catalog manager;
  ignore (M.handle_command manager (Select_graph graph_id));
  let account_generation = (M.snapshot manager).account_generation in
  let graph_generation = (M.snapshot manager).graph_generation in
  ignore
    (M.handle_event
       manager
       (Mirror_ready { account_generation; graph_generation; graph_id }));
  let graph_opened =
    M.handle_event
      manager
      (Graph_opened
         { account_generation; graph_generation; graph_id; applied_server_t = 4 })
  in
  T.require (graph_opened = []) "graph open bypassed Timeline presentation";
  let websocket = present_restored_timeline manager |> need_token in
  ignore (provide manager websocket "websocket-token");
  let connection_generation = (M.snapshot manager).connection_generation in
  ignore
    (M.handle_event
       manager
       (Websocket_closed
          { account_generation
          ; graph_generation
          ; connection_generation
          ; message = "unavailable"
          }));
  let payload = batch_payload "33000000-0000-4000-8000-000000000011" in
  let challenge = M.handle_event manager (Pending_batch payload) |> need_token in
  T.require
    (challenge.purpose = Transaction_submission)
    "offline pending batch requested the wrong token purpose";
  let effects = provide manager challenge "transaction-token" in
  T.require
    (match effects with
     | [ Submit_http_transaction { token; payload = actual; _ } ] ->
       String.equal token "transaction-token" && String.equal actual payload
     | _ -> false)
    "pending batch was not submitted through authenticated OCaml HTTP"
;;

let test_catalog_refresh_preserves_offline_graph_and_revokes_removed_selection () =
  let manager =
    M.create ~next_challenge_id ~base_url:(Uri.of_string "https://api.logseq.io")
  in
  authenticate_and_load_catalog manager;
  ignore (M.handle_command manager (Select_graph graph_id));
  let account_generation = (M.snapshot manager).account_generation in
  let graph_generation = (M.snapshot manager).graph_generation in
  ignore
    (M.handle_event
       manager
       (Mirror_ready { account_generation; graph_generation; graph_id }));
  let graph_opened =
    M.handle_event
      manager
      (Graph_opened
         { account_generation; graph_generation; graph_id; applied_server_t = 9 })
  in
  T.require (graph_opened = []) "graph open bypassed Timeline presentation";
  let websocket = present_restored_timeline manager |> need_token in
  ignore (provide manager websocket "websocket-token");
  let connection_generation = (M.snapshot manager).connection_generation in
  ignore
    (M.handle_event
       manager
       (Websocket_opened { account_generation; graph_generation; connection_generation }));
  let refresh = M.handle_command manager Refresh_catalog |> need_token in
  T.require ((M.snapshot manager).phase = Graph_open) "catalog refresh hid an open graph";
  ignore (provide manager refresh "refresh-token");
  T.require
    ((M.snapshot manager).phase = Graph_open)
    "catalog HTTP start hid an open graph";
  ignore
    (M.handle_event manager (Catalog_failed { account_generation; message = "offline" }));
  T.require
    ((M.snapshot manager).phase = Graph_open)
    "offline refresh closed an open graph";
  let revoked =
    M.handle_event
      manager
      (Catalog_loaded { account_generation; graphs = [ graph other_graph_id "Second" ] })
  in
  T.require
    (revoked = [ Close_websocket; Close_graph ])
    "catalog revocation did not close transport before the engine";
  T.require
    ((M.snapshot manager).phase = Awaiting_selection
     && (M.snapshot manager).selected_graph = None)
    "revoked graph remained selected"
;;

let test_background_resume_revalidates_the_preserved_websocket () =
  let context = open_live_manager 21 in
  let manager = context.manager in
  T.require
    (M.handle_command manager (Backgrounded { lifecycle_generation = 7L }) = [])
    "background entry started a network operation";
  let deferred_payload = batch_payload "33000000-0000-4000-8000-000000000001" in
  T.require
    (M.handle_event manager (Pending_batch deferred_payload) = [])
    "background pending batch started a network operation";
  let before = M.snapshot manager in
  let effects =
    M.handle_command manager (Foreground_resumed { lifecycle_generation = 7L })
  in
  T.require
    ((M.snapshot manager).connection_generation = before.connection_generation)
    "foreground probe fenced the preserved WebSocket";
  T.require
    (effects
     = [ Send_websocket (Logseq_db_worker.Sync_protocol.encode_pull ~since:21)
       ; Schedule_foreground_probe
           { account_generation = context.account_generation
           ; graph_generation = context.graph_generation
           ; connection_generation = context.connection_generation
           ; lifecycle_generation = 7L
           ; delay_seconds = 3.
           }
       ])
    "foreground resume did not start one bounded pull probe";
  let payload = {|{"type":"pull/ok","t":21,"txs":[]}|} in
  T.require
    (M.handle_event
       manager
       (Websocket_frame
          { account_generation = context.account_generation
          ; graph_generation = context.graph_generation
          ; connection_generation = context.connection_generation
          ; payload
          })
     = [ Apply_sync_frame payload ])
    "foreground pull/ok bypassed serialized replay";
  T.require
    (M.handle_event
       manager
       (Sync_applied
          { account_generation = context.account_generation
          ; graph_generation = context.graph_generation
          ; applied_server_t = 21
          ; activity = Logseq_db_worker.Protocol.Pull_duplicate
          ; pending_payload = None
          })
     = [ Send_websocket deferred_payload ])
    "successful probe did not resume the deferred pending pump";
  T.require
    (M.handle_command manager (Foreground_resumed { lifecycle_generation = 7L }) = [])
    "duplicate foreground epoch started another probe"
;;

let test_probe_timeout_fences_once_and_falls_back_to_http () =
  let context = open_live_manager 21 in
  let manager = context.manager in
  ignore (M.handle_command manager (Backgrounded { lifecycle_generation = 8L }));
  ignore (M.handle_command manager (Foreground_resumed { lifecycle_generation = 8L }));
  let fallback =
    M.handle_event
      manager
      (Foreground_probe_timed_out
         { account_generation = context.account_generation
         ; graph_generation = context.graph_generation
         ; connection_generation = context.connection_generation
         ; lifecycle_generation = 8L
         })
  in
  let challenge =
    match fallback with
    | [ Close_websocket; Need_id_token challenge ] -> challenge
    | _ -> T.fail "probe timeout did not start one HTTP fallback"
  in
  T.require (challenge.purpose = Http_pull) "probe fallback requested the wrong token";
  T.require
    ((M.snapshot manager).connection_generation > context.connection_generation)
    "probe timeout did not fence the old connection";
  T.require
    (M.handle_event
       manager
       (Foreground_probe_timed_out
          { account_generation = context.account_generation
          ; graph_generation = context.graph_generation
          ; connection_generation = context.connection_generation
          ; lifecycle_generation = 8L
          })
     = [])
    "duplicate probe timeout repeated fallback";
  T.require
    (M.handle_event
       manager
       (Websocket_frame
          { account_generation = context.account_generation
          ; graph_generation = context.graph_generation
          ; connection_generation = context.connection_generation
          ; payload = {|{"type":"pull/ok","t":21,"txs":[]}|}
          })
     = [])
    "late frame from the fenced probe was accepted";
  T.require
    (match provide manager challenge "http-pull-token" with
     | [ Fetch_http_pull { since = 21; token; _ } ] ->
       String.equal token "http-pull-token"
     | _ -> false)
    "probe fallback did not pull from the durable cursor"
;;

let test_background_disconnect_and_timer_defer_reconnect_until_resume () =
  let context = open_live_manager 21 in
  let manager = context.manager in
  ignore (M.handle_command manager (Backgrounded { lifecycle_generation = 9L }));
  T.require
    (M.handle_event
       manager
       (Websocket_closed
          { account_generation = context.account_generation
          ; graph_generation = context.graph_generation
          ; connection_generation = context.connection_generation
          ; message = "closed while suspended"
          })
     = [])
    "background disconnect scheduled reconnect work";
  let disconnected_generation = (M.snapshot manager).connection_generation in
  T.require
    (M.handle_event
       manager
       (Reconnect_timer_elapsed
          { account_generation = context.account_generation
          ; graph_generation = context.graph_generation
          ; connection_generation = disconnected_generation
          })
     = [])
    "background reconnect timer started network work";
  let challenge =
    M.handle_command manager (Foreground_resumed { lifecycle_generation = 9L })
    |> need_token
  in
  T.require
    (challenge.purpose = Http_pull)
    "foreground did not resume deferred reconnect through HTTP catch-up"
;;

let test_changed_and_tx_ack_are_serialized_around_foreground_probe () =
  let context = open_live_manager 21 in
  let manager = context.manager in
  let tx_id = "33000000-0000-4000-8000-000000000002" in
  let outgoing = batch_payload tx_id in
  T.require
    (M.handle_event manager (Pending_batch outgoing) = [ Send_websocket outgoing ])
    "live pending batch was not sent";
  ignore (M.handle_command manager (Backgrounded { lifecycle_generation = 10L }));
  ignore (M.handle_command manager (Foreground_resumed { lifecycle_generation = 10L }));
  T.require
    (M.handle_event
       manager
       (Websocket_frame
          { account_generation = context.account_generation
          ; graph_generation = context.graph_generation
          ; connection_generation = context.connection_generation
          ; payload = {|{"type":"changed","t":22}|}
          })
     = [])
    "changed hint created a concurrent foreground pull";
  let ack = {|{"type":"tx/batch/ok","t":22}|} in
  T.require
    (M.handle_event
       manager
       (Websocket_frame
          { account_generation = context.account_generation
          ; graph_generation = context.graph_generation
          ; connection_generation = context.connection_generation
          ; payload = ack
          })
     = [ Apply_sync_frame ack ])
    "ordered transaction acknowledgement was not applied";
  T.require
    (M.handle_event
       manager
       (Sync_applied
          { account_generation = context.account_generation
          ; graph_generation = context.graph_generation
          ; applied_server_t = 21
          ; activity = Logseq_db_worker.Protocol.Pull_required
          ; pending_payload = None
          })
     = [])
    "transaction acknowledgement created a concurrent pull";
  let pull = {|{"type":"pull/ok","t":22,"txs":[]}|} in
  ignore
    (M.handle_event
       manager
       (Websocket_frame
          { account_generation = context.account_generation
          ; graph_generation = context.graph_generation
          ; connection_generation = context.connection_generation
          ; payload = pull
          }));
  T.require
    (M.handle_event
       manager
       (Sync_applied
          { account_generation = context.account_generation
          ; graph_generation = context.graph_generation
          ; applied_server_t = 22
          ; activity = Logseq_db_worker.Protocol.Pull_duplicate
          ; pending_payload = None
          })
     = [ Send_websocket (Logseq_db_worker.Sync_protocol.encode_pull ~since:22) ])
    "coalesced changed hint was lost after foreground revalidation"
;;

let test_failed_probe_recovers_only_the_uncertain_submission () =
  let context = open_live_manager 21 in
  let manager = context.manager in
  let tx_id = Uuid.of_string "33000000-0000-4000-8000-000000000003" |> Result.get_ok in
  let outgoing = batch_payload (Uuid.to_string tx_id) in
  ignore (M.handle_event manager (Pending_batch outgoing));
  ignore (M.handle_command manager (Backgrounded { lifecycle_generation = 11L }));
  ignore (M.handle_command manager (Foreground_resumed { lifecycle_generation = 11L }));
  let fallback =
    M.handle_event
      manager
      (Foreground_probe_timed_out
         { account_generation = context.account_generation
         ; graph_generation = context.graph_generation
         ; connection_generation = context.connection_generation
         ; lifecycle_generation = 11L
         })
  in
  let challenge =
    match fallback with
    | [ Close_websocket; Need_id_token challenge ] -> challenge
    | _ -> T.fail "uncertain submission did not enter HTTP fallback"
  in
  let connection_generation =
    match provide manager challenge "http-pull-token" with
    | [ Fetch_http_pull { connection_generation; _ } ] -> connection_generation
    | _ -> T.fail "uncertain submission did not start HTTP catch-up"
  in
  let pull_response = {|{"type":"pull/ok","t":21,"txs":[]}|} in
  T.require
    (M.handle_event
       manager
       (Http_pull_loaded
          { account_generation = context.account_generation
          ; graph_generation = context.graph_generation
          ; connection_generation
          ; payload = pull_response
          })
     = [ Apply_sync_frame pull_response ])
    "uncertain submission catch-up was not serialized";
  T.require
    (M.handle_event
       manager
       (Sync_applied
          { account_generation = context.account_generation
          ; graph_generation = context.graph_generation
          ; applied_server_t = 21
          ; activity = Logseq_db_worker.Protocol.Pull_duplicate
          ; pending_payload = None
          })
     |> function
     | [ Recover_submitted [ actual ]; Need_id_token reconnect ] ->
       Uuid.equal actual tx_id && reconnect.purpose = Websocket_connect
     | _ -> false)
    "HTTP catch-up did not recover the exact uncertain transaction before reconnect"
;;

let begin_foreground_probe context lifecycle_generation =
  ignore (M.handle_command context.manager (Backgrounded { lifecycle_generation }));
  ignore (M.handle_command context.manager (Foreground_resumed { lifecycle_generation }))
;;

let require_immediate_probe_fallback context effects message =
  let challenge =
    match effects with
    | [ M.Close_websocket; M.Need_id_token challenge ] -> challenge
    | _ -> T.fail "%s" message
  in
  T.require (challenge.purpose = Http_pull) "%s requested the wrong token" message;
  T.require
    ((M.snapshot context.manager).connection_generation > context.connection_generation)
    "%s did not fence the preserved connection"
    message
;;

let test_probe_failures_share_one_immediate_http_fallback () =
  let malformed = open_live_manager 21 in
  begin_foreground_probe malformed 12L;
  require_immediate_probe_fallback
    malformed
    (M.handle_event
       malformed.manager
       (Websocket_frame
          { account_generation = malformed.account_generation
          ; graph_generation = malformed.graph_generation
          ; connection_generation = malformed.connection_generation
          ; payload = {|{"type":"pull/ok","t":"invalid","txs":[]}|}
          }))
    "malformed foreground probe";
  let closed = open_live_manager 21 in
  begin_foreground_probe closed 13L;
  require_immediate_probe_fallback
    closed
    (M.handle_event
       closed.manager
       (Websocket_closed
          { account_generation = closed.account_generation
          ; graph_generation = closed.graph_generation
          ; connection_generation = closed.connection_generation
          ; message = "closed during foreground probe"
          }))
    "closed foreground probe";
  let replay_failed = open_live_manager 21 in
  begin_foreground_probe replay_failed 14L;
  require_immediate_probe_fallback
    replay_failed
    (M.handle_event
       replay_failed.manager
       (Network_failed
          { account_generation = replay_failed.account_generation
          ; graph_generation = Some replay_failed.graph_generation
          ; connection_generation = Some replay_failed.connection_generation
          ; message = "foreground replay failed"
          }))
    "failed foreground replay";
  let paused = open_live_manager 21 in
  begin_foreground_probe paused 15L;
  let paused_pull = {|{"type":"pull/ok","t":21,"txs":[]}|} in
  T.require
    (M.handle_event
       paused.manager
       (Websocket_frame
          { account_generation = paused.account_generation
          ; graph_generation = paused.graph_generation
          ; connection_generation = paused.connection_generation
          ; payload = paused_pull
          })
     = [ Apply_sync_frame paused_pull ])
    "paused foreground replay did not enter the sync engine";
  require_immediate_probe_fallback
    paused
    (M.handle_event
       paused.manager
       (Sync_applied
          { account_generation = paused.account_generation
          ; graph_generation = paused.graph_generation
          ; applied_server_t = 21
          ; activity = Logseq_db_worker.Protocol.Sync_paused
          ; pending_payload = None
          }))
    "paused foreground replay"
;;

let test_presence_does_not_fail_foreground_probe () =
  let context = open_live_manager 21 in
  begin_foreground_probe context 18L;
  let before = M.snapshot context.manager in
  T.require
    (M.handle_event
       context.manager
       (Websocket_frame
          { account_generation = context.account_generation
          ; graph_generation = context.graph_generation
          ; connection_generation = context.connection_generation
          ; payload = {|{"type":"online-users","online-users":[]}|}
          })
     = [])
    "presence message triggered a foreground transport effect";
  T.require
    (M.snapshot context.manager = before)
    "presence message failed or completed foreground revalidation"
;;

let background_during_probe context first_generation second_generation =
  begin_foreground_probe context first_generation;
  ignore
    (M.handle_command
       context.manager
       (Backgrounded { lifecycle_generation = second_generation }))
;;

let require_deferred_http_fallback context lifecycle_generation event message =
  T.require
    (M.handle_event context.manager event = [])
    "%s started transport work while backgrounded"
    message;
  let challenge =
    M.handle_command context.manager (Foreground_resumed { lifecycle_generation })
    |> need_token
  in
  T.require
    (challenge.purpose = Http_pull)
    "%s did not resume the deferred HTTP fallback"
    message
;;

let test_probe_failures_while_backgrounded_defer_http_fallback () =
  let closed = open_live_manager 21 in
  background_during_probe closed 20L 21L;
  require_deferred_http_fallback
    closed
    21L
    (Websocket_closed
       { account_generation = closed.account_generation
       ; graph_generation = closed.graph_generation
       ; connection_generation = closed.connection_generation
       ; message = "closed after returning to background"
       })
    "backgrounded probe close";
  let malformed = open_live_manager 21 in
  background_during_probe malformed 22L 23L;
  require_deferred_http_fallback
    malformed
    23L
    (Websocket_frame
       { account_generation = malformed.account_generation
       ; graph_generation = malformed.graph_generation
       ; connection_generation = malformed.connection_generation
       ; payload = {|{"type":"pull/ok","t":"invalid","txs":[]}|}
       })
    "backgrounded malformed probe response";
  let failed = open_live_manager 21 in
  background_during_probe failed 24L 25L;
  require_deferred_http_fallback
    failed
    25L
    (Network_failed
       { account_generation = failed.account_generation
       ; graph_generation = Some failed.graph_generation
       ; connection_generation = Some failed.connection_generation
       ; message = "probe replay failed after returning to background"
       })
    "backgrounded probe replay failure";
  let timed_out = open_live_manager 21 in
  background_during_probe timed_out 26L 27L;
  T.require
    (M.handle_event
       timed_out.manager
       (Foreground_probe_timed_out
          { account_generation = timed_out.account_generation
          ; graph_generation = timed_out.graph_generation
          ; connection_generation = timed_out.connection_generation
          ; lifecycle_generation = 26L
          })
     = [])
    "obsolete probe timeout started fallback while backgrounded";
  T.require
    (match
       M.handle_command
         timed_out.manager
         (Foreground_resumed { lifecycle_generation = 27L })
     with
     | [ Schedule_foreground_probe { lifecycle_generation = 27L; _ } ] -> true
     | _ -> false)
    "foreground did not supersede the obsolete probe deadline"
;;

let test_backgrounded_http_submission_token_is_deferred () =
  let context = open_live_manager 21 in
  ignore
    (M.handle_event
       context.manager
       (Websocket_closed
          { account_generation = context.account_generation
          ; graph_generation = context.graph_generation
          ; connection_generation = context.connection_generation
          ; message = "disconnected"
          }));
  let outgoing = batch_payload "33000000-0000-4000-8000-000000000014" in
  let transaction_challenge =
    M.handle_event context.manager (Pending_batch outgoing) |> need_token
  in
  ignore (M.handle_command context.manager (Backgrounded { lifecycle_generation = 28L }));
  T.require
    (provide context.manager transaction_challenge "transaction-token" = [])
    "backgrounded transaction token started network work";
  let pull_challenge =
    M.handle_command context.manager (Foreground_resumed { lifecycle_generation = 28L })
    |> need_token
  in
  let connection_generation =
    match provide context.manager pull_challenge "http-pull-token" with
    | [ Fetch_http_pull { connection_generation; _ } ] -> connection_generation
    | _ -> T.fail "foreground did not start authoritative HTTP catch-up"
  in
  let catchup = {|{"type":"pull/ok","t":21,"txs":[]}|} in
  ignore
    (M.handle_event
       context.manager
       (Http_pull_loaded
          { account_generation = context.account_generation
          ; graph_generation = context.graph_generation
          ; connection_generation
          ; payload = catchup
          }));
  let reconnect =
    M.handle_event
      context.manager
      (Sync_applied
         { account_generation = context.account_generation
         ; graph_generation = context.graph_generation
         ; applied_server_t = 21
         ; activity = Logseq_db_worker.Protocol.Pull_duplicate
         ; pending_payload = None
         })
    |> need_token
  in
  ignore (provide context.manager reconnect "websocket-token");
  let opened_generation = (M.snapshot context.manager).connection_generation in
  ignore
    (M.handle_event
       context.manager
       (Websocket_opened
          { account_generation = context.account_generation
          ; graph_generation = context.graph_generation
          ; connection_generation = opened_generation
          }));
  let opened_pull = {|{"type":"pull/ok","t":21,"txs":[]}|} in
  ignore
    (M.handle_event
       context.manager
       (Websocket_frame
          { account_generation = context.account_generation
          ; graph_generation = context.graph_generation
          ; connection_generation = opened_generation
          ; payload = opened_pull
          }));
  T.require
    (M.handle_event
       context.manager
       (Sync_applied
          { account_generation = context.account_generation
          ; graph_generation = context.graph_generation
          ; applied_server_t = 21
          ; activity = Logseq_db_worker.Protocol.Pull_duplicate
          ; pending_payload = None
          })
     = [ Send_websocket outgoing ])
    "transaction waiting for a backgrounded token was lost after catch-up"
;;

let start_http_catchup context =
  let reconnect =
    M.handle_event
      context.manager
      (Websocket_closed
         { account_generation = context.account_generation
         ; graph_generation = context.graph_generation
         ; connection_generation = context.connection_generation
         ; message = "disconnected"
         })
  in
  let timer_generation = (M.snapshot context.manager).connection_generation in
  let delay =
    match reconnect with
    | [ Schedule_reconnect { connection_generation; _ } ] ->
      T.require
        (connection_generation = timer_generation)
        "reconnect timer generation changed";
      ()
    | _ -> T.fail "disconnect did not schedule reconnect"
  in
  ignore delay;
  let challenge =
    M.handle_event
      context.manager
      (Reconnect_timer_elapsed
         { account_generation = context.account_generation
         ; graph_generation = context.graph_generation
         ; connection_generation = timer_generation
         })
    |> need_token
  in
  let effects = provide context.manager challenge "http-pull-token" in
  T.require
    (match effects with
     | [ Fetch_http_pull { since = 21; _ } ] -> true
     | _ -> false)
    "reconnect did not start HTTP catch-up";
  timer_generation
;;

let require_nonblocking_token_backoff context challenge message =
  T.require
    (match
       M.handle_command
         context.manager
         (Token_failed { challenge_id = challenge.A.challenge_id })
     with
     | [ Schedule_reconnect { connection_generation; _ } ] ->
       connection_generation = (M.snapshot context.manager).connection_generation
     | _ -> false)
    "%s did not schedule bounded reconnect backoff"
    message;
  T.require
    ((M.snapshot context.manager).phase = Sync_paused)
    "%s made the populated graph terminal"
    message
;;

let test_open_graph_token_failures_are_nonblocking_and_retryable () =
  let http = open_live_manager 21 in
  let reconnect =
    M.handle_event
      http.manager
      (Websocket_closed
         { account_generation = http.account_generation
         ; graph_generation = http.graph_generation
         ; connection_generation = http.connection_generation
         ; message = "disconnected"
         })
  in
  let connection_generation = (M.snapshot http.manager).connection_generation in
  (match reconnect with
   | [ Schedule_reconnect _ ] -> ()
   | _ -> T.fail "disconnect did not schedule the first retry");
  let http_challenge =
    M.handle_event
      http.manager
      (Reconnect_timer_elapsed
         { account_generation = http.account_generation
         ; graph_generation = http.graph_generation
         ; connection_generation
         })
    |> need_token
  in
  require_nonblocking_token_backoff http http_challenge "HTTP pull token failure";
  let websocket = open_live_manager 21 in
  let http_generation = start_http_catchup websocket in
  let catchup = {|{"type":"pull/ok","t":21,"txs":[]}|} in
  ignore
    (M.handle_event
       websocket.manager
       (Http_pull_loaded
          { account_generation = websocket.account_generation
          ; graph_generation = websocket.graph_generation
          ; connection_generation = http_generation
          ; payload = catchup
          }));
  let websocket_challenge =
    M.handle_event
      websocket.manager
      (Sync_applied
         { account_generation = websocket.account_generation
         ; graph_generation = websocket.graph_generation
         ; applied_server_t = 21
         ; activity = Logseq_db_worker.Protocol.Pull_duplicate
         ; pending_payload = None
         })
    |> need_token
  in
  require_nonblocking_token_backoff
    websocket
    websocket_challenge
    "WebSocket reconnect token failure"
;;

let test_backgrounded_token_failure_defers_retry () =
  let context = open_live_manager 21 in
  ignore
    (M.handle_event
       context.manager
       (Websocket_closed
          { account_generation = context.account_generation
          ; graph_generation = context.graph_generation
          ; connection_generation = context.connection_generation
          ; message = "disconnected"
          }));
  let connection_generation = (M.snapshot context.manager).connection_generation in
  let challenge =
    M.handle_event
      context.manager
      (Reconnect_timer_elapsed
         { account_generation = context.account_generation
         ; graph_generation = context.graph_generation
         ; connection_generation
         })
    |> need_token
  in
  ignore (M.handle_command context.manager (Backgrounded { lifecycle_generation = 29L }));
  T.require
    (M.handle_command
       context.manager
       (Token_failed { challenge_id = challenge.A.challenge_id })
     = [])
    "backgrounded token failure started retry work";
  T.require
    ((M.snapshot context.manager).phase = Sync_paused)
    "backgrounded token failure made the populated graph terminal";
  let resumed =
    M.handle_command context.manager (Foreground_resumed { lifecycle_generation = 29L })
    |> need_token
  in
  T.require
    (resumed.purpose = Http_pull)
    "foreground did not resume the deferred token retry"
;;

let test_background_resume_waits_for_inflight_http_pull () =
  let context = open_live_manager 21 in
  let http_generation = start_http_catchup context in
  ignore (M.handle_command context.manager (Backgrounded { lifecycle_generation = 16L }));
  T.require
    (M.handle_command context.manager (Foreground_resumed { lifecycle_generation = 16L })
     = [])
    "foreground duplicated the in-flight HTTP pull";
  let payload = {|{"type":"pull/ok","t":21,"txs":[]}|} in
  T.require
    (M.handle_event
       context.manager
       (Http_pull_loaded
          { account_generation = context.account_generation
          ; graph_generation = context.graph_generation
          ; connection_generation = http_generation
          ; payload
          })
     = [ Apply_sync_frame payload ])
    "current in-flight HTTP pull was not applied";
  T.require
    (http_generation = (M.snapshot context.manager).connection_generation)
    "waiting for the current HTTP pull changed connection generation"
;;

let test_http_transaction_completion_does_not_finish_http_catchup () =
  let context = open_live_manager 21 in
  ignore
    (M.handle_event
       context.manager
       (Websocket_closed
          { account_generation = context.account_generation
          ; graph_generation = context.graph_generation
          ; connection_generation = context.connection_generation
          ; message = "disconnected"
          }));
  let connection_generation = (M.snapshot context.manager).connection_generation in
  let outgoing = batch_payload "33000000-0000-4000-8000-000000000013" in
  let transaction_challenge =
    M.handle_event context.manager (Pending_batch outgoing) |> need_token
  in
  T.require
    (match provide context.manager transaction_challenge "transaction-token" with
     | [ Submit_http_transaction { connection_generation = actual; _ } ] ->
       actual = connection_generation
     | _ -> false)
    "disconnected transaction did not start on the current attempt";
  ignore (M.handle_command context.manager (Backgrounded { lifecycle_generation = 19L }));
  let pull_challenge =
    M.handle_command context.manager (Foreground_resumed { lifecycle_generation = 19L })
    |> need_token
  in
  T.require
    (match provide context.manager pull_challenge "http-pull-token" with
     | [ Fetch_http_pull { connection_generation = actual; _ } ] ->
       actual = connection_generation
     | _ -> false)
    "foreground did not preserve the authoritative HTTP catch-up attempt";
  let transaction_response = {|{"type":"tx/batch/ok","t":22}|} in
  T.require
    (M.handle_event
       context.manager
       (Http_transaction_loaded
          { account_generation = context.account_generation
          ; graph_generation = context.graph_generation
          ; connection_generation
          ; payload = transaction_response
          })
     = [ Apply_sync_frame transaction_response ])
    "current HTTP transaction response was not serialized";
  T.require
    (M.handle_event
       context.manager
       (Sync_applied
          { account_generation = context.account_generation
          ; graph_generation = context.graph_generation
          ; applied_server_t = 22
          ; activity = Logseq_db_worker.Protocol.Pull_required
          ; pending_payload = None
          })
     = [])
    "HTTP transaction completion incorrectly finished authoritative catch-up";
  let pull_response = {|{"type":"pull/ok","t":22,"txs":[]}|} in
  T.require
    (M.handle_event
       context.manager
       (Http_pull_loaded
          { account_generation = context.account_generation
          ; graph_generation = context.graph_generation
          ; connection_generation
          ; payload = pull_response
          })
     = [ Apply_sync_frame pull_response ])
    "transaction completion discarded the in-flight HTTP catch-up"
;;

let test_late_http_completion_is_fenced_by_connection_generation () =
  let context = open_live_manager 21 in
  let http_generation = start_http_catchup context in
  ignore
    (M.handle_event
       context.manager
       (Network_failed
          { account_generation = context.account_generation
          ; graph_generation = Some context.graph_generation
          ; connection_generation = Some http_generation
          ; message = "HTTP attempt failed"
          }));
  let before = M.snapshot context.manager in
  T.require
    (M.handle_event
       context.manager
       (Http_pull_loaded
          { account_generation = context.account_generation
          ; graph_generation = context.graph_generation
          ; connection_generation = http_generation
          ; payload = {|{"type":"pull/ok","t":21,"txs":[]}|}
          })
     = [])
    "late HTTP completion from a fenced attempt was applied";
  T.require
    (M.snapshot context.manager = before)
    "late HTTP completion mutated manager state"
;;

let test_new_pending_batch_does_not_replace_uncertain_submission () =
  let context = open_live_manager 21 in
  let first_id = Uuid.of_string "33000000-0000-4000-8000-000000000011" |> Result.get_ok in
  let second_id = "33000000-0000-4000-8000-000000000012" in
  let first = batch_payload (Uuid.to_string first_id) in
  T.require
    (M.handle_event context.manager (Pending_batch first) = [ Send_websocket first ])
    "first batch was not submitted";
  ignore (M.handle_command context.manager (Backgrounded { lifecycle_generation = 17L }));
  T.require
    (M.handle_event context.manager (Pending_batch (batch_payload second_id)) = [])
    "second background batch started network work";
  ignore
    (M.handle_command context.manager (Foreground_resumed { lifecycle_generation = 17L }));
  let fallback =
    M.handle_event
      context.manager
      (Foreground_probe_timed_out
         { account_generation = context.account_generation
         ; graph_generation = context.graph_generation
         ; connection_generation = context.connection_generation
         ; lifecycle_generation = 17L
         })
  in
  let challenge =
    match fallback with
    | [ Close_websocket; Need_id_token challenge ] -> challenge
    | _ -> T.fail "uncertain submission did not enter HTTP fallback"
  in
  let connection_generation =
    match provide context.manager challenge "http-pull-token" with
    | [ Fetch_http_pull { connection_generation; _ } ] -> connection_generation
    | _ -> T.fail "uncertain submission did not start HTTP catch-up"
  in
  let pull_response = {|{"type":"pull/ok","t":21,"txs":[]}|} in
  T.require
    (M.handle_event
       context.manager
       (Http_pull_loaded
          { account_generation = context.account_generation
          ; graph_generation = context.graph_generation
          ; connection_generation
          ; payload = pull_response
          })
     = [ Apply_sync_frame pull_response ])
    "uncertain submission catch-up was not serialized";
  T.require
    (M.handle_event
       context.manager
       (Sync_applied
          { account_generation = context.account_generation
          ; graph_generation = context.graph_generation
          ; applied_server_t = 21
          ; activity = Logseq_db_worker.Protocol.Pull_duplicate
          ; pending_payload = None
          })
     |> function
     | [ Recover_submitted [ actual ]; Need_id_token _ ] -> Uuid.equal actual first_id
     | _ -> false)
    "a later pending batch replaced the actual uncertain submission"
;;

let test_bootstrap_requests_a_fresh_token_for_each_authenticated_operation () =
  let manager =
    M.create ~next_challenge_id ~base_url:(Uri.of_string "https://api.logseq.io")
  in
  authenticate_and_load_catalog manager;
  ignore (M.handle_command manager (Select_graph graph_id));
  let account_generation = (M.snapshot manager).account_generation in
  let graph_generation = (M.snapshot manager).graph_generation in
  T.require
    (M.handle_event
       manager
       (Mirror_missing
          { account_generation
          ; graph_generation
          ; graph_id
          ; receipt = M.mirror_failure_receipt "mirror missing"
          })
     = [])
    "mirror failure emitted bootstrap network work in the local transition";
  let baseline_challenge =
    M.handle_command manager Begin_online_recovery |> need_token
  in
  let baseline_effects = provide manager baseline_challenge "baseline-token" in
  T.require
    (match baseline_effects with
     | [ Fetch_snapshot_baseline { token; _ } ] -> String.equal token "baseline-token"
     | _ -> false)
    "bootstrap did not start with an independently authenticated baseline";
  let metadata_challenge =
    M.handle_event
      manager
      (Snapshot_baseline_loaded
         { account_generation
         ; graph_generation
         ; graph_id
         ; baseline = { Logseq_db_worker.Sync_bootstrap.server_t = 48192 }
         })
    |> need_token
  in
  T.require
    (not (String.equal metadata_challenge.challenge_id baseline_challenge.challenge_id))
    "snapshot metadata reused the baseline token challenge";
  let metadata_effects = provide manager metadata_challenge "metadata-token" in
  T.require
    (match metadata_effects with
     | [ Fetch_snapshot_metadata { token; _ } ] -> String.equal token "metadata-token"
     | _ -> false)
    "bootstrap did not authenticate snapshot metadata independently";
  let metadata =
    Logseq_db_worker.Sync_bootstrap.
      { key = "snapshot-key"
      ; url = Uri.of_string "https://objects.example/snapshot"
      ; content_encoding = Some `Gzip
      }
  in
  let artifact_challenge =
    M.handle_event
      manager
      (Snapshot_metadata_loaded
         { account_generation; graph_generation; graph_id; metadata })
    |> need_token
  in
  T.require
    (not (String.equal artifact_challenge.challenge_id metadata_challenge.challenge_id))
    "snapshot artifact reused the metadata token challenge";
  let artifact_effects = provide manager artifact_challenge "artifact-token" in
  T.require
    (match artifact_effects with
     | [ Download_snapshot_artifact { token; baseline; metadata = actual; _ } ] ->
       String.equal token "artifact-token"
       && baseline.server_t = 48192
       && String.equal actual.key metadata.key
     | _ -> false)
    "bootstrap did not authenticate the artifact independently";
  let activation =
    M.handle_event
      manager
      (Snapshot_artifact_ready
         { account_generation
         ; graph_generation
         ; graph_id
         ; snapshot_path = "/private/snapshot.transit"
         ; expected_rows = 120
         })
  in
  T.require
    (match activation with
     | [ Activate_snapshot { server_t = 48192; expected_rows = 120; _ } ] -> true
     | _ -> false)
    "downloaded artifact was not staged for serialized mirror activation"
;;

let test_e2ee_endpoint_orchestration_and_password_prompt_are_ocaml_owned () =
  let unlocked = ref false in
  let e2ee_platform =
    Logseq_db_worker.Sync_e2ee_session.
      { has_private_key = (fun ~managed_sync_origin:_ ~user_id:_ -> !unlocked)
      ; unlock_private_key =
          (fun ~managed_sync_origin:_ ~user_id:_ ~password ~private_key_package:_ ->
            if String.equal password "secret"
            then (
              unlocked := true;
              Ok ())
            else Error "wrong password")
      }
  in
  let manager =
    M.create_with_e2ee
      ~e2ee_platform
      ~next_challenge_id
      ~base_url:(Uri.of_string "https://api.logseq.io")
  in
  let catalog_challenge =
    M.handle_command manager (Authenticated_user { user_id = "user-1" }) |> need_token
  in
  ignore (provide manager catalog_challenge "catalog-token");
  let account_generation = (M.snapshot manager).account_generation in
  ignore
    (M.handle_event
       manager
       (Catalog_loaded
          { account_generation; graphs = [ encrypted_graph graph_id "Secrets" ] }));
  ignore (M.handle_command manager (Select_graph graph_id));
  let graph_generation = (M.snapshot manager).graph_generation in
  let local_key_lookup =
    M.handle_event
      manager
      (Mirror_ready { account_generation; graph_generation; graph_id })
  in
  T.require
    (local_key_lookup = [ Load_wrapped_graph_key ])
    "encrypted mirror did not inspect local wrapped-key state first";
  T.require
    (M.handle_event
       manager
       (Wrapped_graph_key_load_failed
          { account_generation
          ; graph_generation
          ; graph_id
          ; diagnostic = "cache miss"
          ; receipt = M.wrapped_key_failure_receipt "cache miss"
          })
     = [])
    "wrapped-key cache miss emitted network work in the local transition";
  let graph_key_challenge =
    M.handle_command manager Begin_online_recovery |> need_token
  in
  T.require
    (graph_key_challenge.purpose = E2ee_key_access)
    "encrypted graph skipped E2EE token";
  T.require
    (match provide manager graph_key_challenge "graph-key-token" with
     | [ Fetch_e2ee_graph_key { token; _ } ] -> String.equal token "graph-key-token"
     | _ -> false)
    "encrypted graph key request was not worker-owned";
  let wrapped = {|["~#'","~bZ3JhcGgta2V5"]|} in
  let graph_key_response =
    Yojson.Safe.to_string (`Assoc [ "encrypted-aes-key", `String wrapped ])
  in
  let user_key_challenge =
    M.handle_event
      manager
      (E2ee_graph_key_loaded
         { account_generation; graph_generation; graph_id; response = graph_key_response })
    |> need_token
  in
  T.require
    (match provide manager user_key_challenge "user-key-token" with
     | [ Fetch_e2ee_user_keys { token; _ } ] -> String.equal token "user-key-token"
     | _ -> false)
    "private-key package request reused or bypassed authentication";
  let package = {|["20251210","~bc2FsdA","~baXY","~bY2lwaGVydGV4dA"]|} in
  let user_keys_response =
    Yojson.Safe.to_string
      (`Assoc
          [ "public-key", `String "bounded-public-key-package"
          ; "encrypted-private-key", `String package
          ])
  in
  let prompt =
    M.handle_event
      manager
      (E2ee_user_keys_loaded
         { account_generation; graph_generation; graph_id; response = user_keys_response })
  in
  T.require (prompt = []) "E2EE password prompt emitted a transport operation";
  T.require
    ((M.snapshot manager).phase = Awaiting_e2ee_password)
    "OCaml manager did not own the E2EE password prompt";
  T.require
    (M.handle_command manager (Submit_e2ee_password "secret")
     = [ Save_wrapped_graph_key ])
    "verified online key was not staged for local persistence";
  T.require
    (match
       M.handle_event
         manager
         (Wrapped_graph_key_saved
            { account_generation; graph_generation; graph_id; diagnostic = None })
     with
     | [ Open_graph { encrypted_graph_key = Some actual; _ } ] ->
       String.equal actual wrapped
     | _ -> false)
    "unlocked E2EE graph did not enter serialized engine open"
;;

let test_encrypted_offline_cache_hit_opens_before_any_network_work () =
  let manager =
    M.create ~next_challenge_id ~base_url:(Uri.of_string "https://api.logseq.io")
  in
  T.require
    (M.handle_command
       manager
       (Restore_local_account
          { user_id = "user-1"; managed_sync_origin = "https://api.logseq.io" })
     = [])
    "encrypted local account restore emitted network work";
  let account_generation = (M.snapshot manager).account_generation in
  ignore
    (M.handle_event
       manager
       (Cached_catalog_loaded
          { account_generation; graphs = [ encrypted_graph graph_id "Secrets" ] }));
  T.require
    (match M.handle_command manager (Select_graph graph_id) with
     | [ Inspect_mirror _ ] -> true
     | _ -> false)
    "encrypted local selection did not inspect its mirror";
  let graph_generation = (M.snapshot manager).graph_generation in
  T.require
    (M.handle_event
       manager
       (Mirror_ready { account_generation; graph_generation; graph_id })
     = [ Load_wrapped_graph_key ])
    "encrypted mirror did not request only local key verification";
  let wrapped = {|["~#'","~bZ3JhcGgta2V5"]|} in
  T.require
    (match
       M.handle_event
         manager
         (Wrapped_graph_key_loaded
            { account_generation; graph_generation; graph_id; encrypted_graph_key = wrapped })
     with
     | [ Open_graph { encrypted_graph_key = Some actual; _ } ] ->
       String.equal actual wrapped
     | _ -> false)
    "verified local wrapped key did not open the encrypted mirror";
  T.require
    (M.handle_event
       manager
       (Graph_opened
          { account_generation; graph_generation; graph_id; applied_server_t = 41 })
     = [])
    "encrypted local graph open emitted network work before Timeline presentation";
  let challenge = present_restored_timeline manager |> need_token in
  T.require
    (challenge.purpose = Websocket_connect)
    "encrypted local graph did not release reconciliation after presentation"
;;

let test_encrypted_cache_failure_mints_only_matching_recovery () =
  let manager =
    M.create ~next_challenge_id ~base_url:(Uri.of_string "https://api.logseq.io")
  in
  ignore
    (M.handle_command
       manager
       (Restore_local_account
          { user_id = "user-1"; managed_sync_origin = "https://api.logseq.io" }));
  let account_generation = (M.snapshot manager).account_generation in
  ignore
    (M.handle_event
       manager
       (Cached_catalog_loaded
          { account_generation; graphs = [ encrypted_graph graph_id "Secrets" ] }));
  ignore (M.handle_command manager (Select_graph graph_id));
  let graph_generation = (M.snapshot manager).graph_generation in
  ignore
    (M.handle_event
       manager
       (Mirror_ready { account_generation; graph_generation; graph_id }));
  T.require
    (M.handle_event
       manager
       (Wrapped_graph_key_load_failed
          { account_generation
          ; graph_generation
          ; graph_id
          ; diagnostic = "corrupt item"
          ; receipt = M.wrapped_key_failure_receipt "corrupt item"
          })
     = [])
    "matching wrapped-key failure emitted network work in its local transition";
  T.require
    ((M.snapshot manager).phase
     = Recovering_online Startup_phase.Wrapped_graph_key_unavailable)
    "matching wrapped-key failure did not expose its scoped recovery state";
  let challenge = M.handle_command manager Begin_online_recovery |> need_token in
  T.require
    (challenge.purpose = E2ee_key_access)
    "matching wrapped-key failure did not enter explicit E2EE recovery";
  T.require
    (M.handle_command manager Begin_online_recovery = [])
    "the manager reused a consumed recovery ticket";
  T.require
    (M.handle_event
       manager
       (Wrapped_graph_key_load_failed
          { account_generation
          ; graph_generation = graph_generation - 1
          ; graph_id
          ; diagnostic = "stale completion"
          ; receipt = M.wrapped_key_failure_receipt "stale completion"
          })
     = [])
    "stale wrapped-key failure produced recovery authority"
;;

let test_missing_private_key_has_a_distinct_recovery_state () =
  let manager =
    M.create ~next_challenge_id ~base_url:(Uri.of_string "https://api.logseq.io")
  in
  ignore
    (M.handle_command
       manager
       (Restore_local_account
          { user_id = "user-1"; managed_sync_origin = "https://api.logseq.io" }));
  let account_generation = (M.snapshot manager).account_generation in
  ignore
    (M.handle_event
       manager
       (Cached_catalog_loaded
          { account_generation; graphs = [ encrypted_graph graph_id "Secrets" ] }));
  ignore (M.handle_command manager (Select_graph graph_id));
  let graph_generation = (M.snapshot manager).graph_generation in
  ignore
    (M.handle_event
       manager
       (Mirror_ready { account_generation; graph_generation; graph_id }));
  T.require
    (M.handle_event
       manager
       (Wrapped_graph_key_load_failed
          { account_generation
          ; graph_generation
          ; graph_id
          ; diagnostic = "local private key is unavailable"
          ; receipt = M.private_key_failure_receipt "local private key is unavailable"
          })
     = [])
    "missing private-key recovery emitted network work in its local transition";
  T.require
    ((M.snapshot manager).phase
     = Recovering_online Startup_phase.Local_private_key_unavailable)
    "missing private key was reported as a wrapped-key cache miss"
;;

let test_managed_sync_startup_has_no_graph_target_or_credential () =
  let json =
    `Assoc
      [ "applicationSupportDirectory", `String "/tmp/support"
      ; ( "target"
        , `Assoc
            [ "kind", `String "managedSync"; "baseUrl", `String "https://api.logseq.io" ]
        )
      ; "compatibilityProfile", `String "logseq-65.33-or-newer"
      ; "responseBudgetBytes", `Int Logseq_db_worker.Protocol.maximum_response_bytes
      ; "defaultPageSize", `Int Logseq_db_worker.Protocol.default_page_size
      ]
  in
  let encoded = Yojson.Safe.to_string json in
  T.require (not (contains encoded "idToken")) "startup fixture contains token material";
  match Logseq_db_worker.Config.of_yojson json with
  | Error message -> T.fail "managed sync startup was rejected: %s" message
  | Ok config ->
    T.require
      (Logseq_db_worker.Config.to_yojson config = json)
      "managed startup resolved or rewrote a graph before authentication"
;;

let () =
  test_local_restore_is_independent_from_authentication_and_network ();
  test_offline_eof_does_not_preempt_local_timeline ();
  test_online_reconciliation_is_fenced_until_timeline_presentation ();
  test_account_replacement_is_fenced_until_timeline_presentation ();
  test_websocket_pull_waits_for_timeline_presentation ();
  test_mirror_inspection_precedes_truthful_bootstrap_phase ();
  test_long_lived_lifecycle_and_foreground_handshake ();
  test_graph_switch_signout_and_late_event_fences ();
  test_authenticated_account_replacement_closes_graph_first ();
  test_confirmed_local_cache_reset_immediately_redownloads ();
  test_reconnect_uses_fresh_token_and_frames_enter_serial_owner ();
  test_network_failure_retries_with_bounded_backoff ();
  test_preopen_network_failure_is_terminal_for_current_attempt ();
  test_pending_batch_uses_authenticated_http_when_socket_is_unavailable ();
  test_catalog_refresh_preserves_offline_graph_and_revokes_removed_selection ();
  test_background_resume_revalidates_the_preserved_websocket ();
  test_probe_timeout_fences_once_and_falls_back_to_http ();
  test_background_disconnect_and_timer_defer_reconnect_until_resume ();
  test_changed_and_tx_ack_are_serialized_around_foreground_probe ();
  test_failed_probe_recovers_only_the_uncertain_submission ();
  test_probe_failures_share_one_immediate_http_fallback ();
  test_presence_does_not_fail_foreground_probe ();
  test_probe_failures_while_backgrounded_defer_http_fallback ();
  test_backgrounded_http_submission_token_is_deferred ();
  test_background_resume_waits_for_inflight_http_pull ();
  test_http_transaction_completion_does_not_finish_http_catchup ();
  test_open_graph_token_failures_are_nonblocking_and_retryable ();
  test_backgrounded_token_failure_defers_retry ();
  test_late_http_completion_is_fenced_by_connection_generation ();
  test_new_pending_batch_does_not_replace_uncertain_submission ();
  test_bootstrap_requests_a_fresh_token_for_each_authenticated_operation ();
  test_e2ee_endpoint_orchestration_and_password_prompt_are_ocaml_owned ();
  test_encrypted_offline_cache_hit_opens_before_any_network_work ();
  test_encrypted_cache_failure_mints_only_matching_recovery ();
  test_missing_private_key_has_a_distinct_recovery_state ();
  test_managed_sync_startup_has_no_graph_target_or_credential ()
;;
