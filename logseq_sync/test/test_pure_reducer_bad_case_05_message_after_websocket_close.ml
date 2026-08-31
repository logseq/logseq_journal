(* Scenario: a WebSocket message arrives after the same connection has been closed.
   Expected: the reducer ignores the late message and preserves the closed state. *)

module Core = Logseq_sync_pure_reducer.Core
module Protocol = Logseq_sync_pure_reducer.Sync_protocol

let fail format = Printf.ksprintf (fun message -> Alcotest.fail message) format

let initial () =
  let limits =
    Core.limits
      ~maximum_response_bytes:Logseq_db_types.Limits.maximum_response_bytes
      ~maximum_artifact_bytes:(1024 * 1024 * 1024)
      ~submission_batch_size:32
    |> Result.get_ok
  in
  Core.config ~managed_sync_origin:(Uri.of_string "https://api.logseq.io") ~limits
  |> Result.get_ok
  |> Core.initial
  |> Result.get_ok
;;

let graph_id =
  Logseq_db_types.Graph_types.Uuid.of_string "11111111-1111-4111-8111-111111111111"
  |> Result.get_ok
;;

let graph : Core.graph =
  { graph_id
  ; name = "Journal"
  ; schema = { major = 1; minor = 0; exact = true }
  ; encrypted = false
  }
;;

let checkpoint =
  Logseq_db_types.Sync_checkpoint.create
    ~graph_id
    ~schema:Logseq_db_types.Graph_types.{ major = 1; minor = 0 }
    ~applied_server_t:0
    ~checksum:"0000000000000000"
  |> Result.get_ok
;;

let account_scope : Core.account_scope =
  { managed_sync_origin = Uri.of_string "https://api.logseq.io"
  ; user_id = "user-1"
  ; account_generation = 1
  ; presentation_generation = 1
  ; lifecycle_generation = 0L
  }
;;

let graph_scope : Core.graph_scope =
  { account = account_scope; graph_id; graph_generation = 2 }
;;

let expected_closed_state : Core.state =
  { snapshot =
      { sync_phase = Offline
      ; catalog = [ graph ]
      ; selected_graph = Some graph_id
      ; applied_server_t = Some 0
      ; timeline_presentation_pending = true
      ; startup =
          { authenticated = true
          ; catalog_loading = false
          ; awaiting_selection = false
          ; restoring_local = false
          ; bootstrapping = false
          ; awaiting_e2ee_password = false
          ; failure = None
          ; account_generation = 1
          ; graph_generation = 2
          ; presentation_generation = 1
          }
      ; last_error = Some "socket closed"
      }
  ; diagnostics = { groups = []; history = [] }
  }
;;

let closed_graph () =
  let authenticated =
    Core.step (initial ()) (Account_authenticated { user_id = Some "user-1" })
  in
  let catalog_token =
    match authenticated.effects with
    | [ Publish (State_changed _); Publish (Token_requested request) ] -> request
    | _ -> fail "BC05 setup authentication emitted unexpected effects"
  in
  let authorized =
    Core.step authenticated.next (Token_provided (catalog_token, "catalog-token"))
  in
  let catalog_completion =
    match authorized.effects with
    | [ Run (Request (ticket, Fetch_catalog _)) ] ->
      Core.Runner_completed (Core.Completion (ticket, Ok [ graph ]))
    | _ -> fail "BC05 setup catalog authorization emitted unexpected effects"
  in
  let catalogued = Core.step authorized.next catalog_completion in
  let selected = Core.step catalogued.next (Graph_selected graph_id) in
  let mirror_request =
    match selected.effects with
    | [ Delegate (Inspect_mirror request)
      ; Publish (State_changed _)
      ; Run (Request (_, Save_catalog _))
      ] -> request
    | _ -> fail "BC05 setup graph selection emitted unexpected effects"
  in
  let open_request : Core.graph_open_request =
    { graph = mirror_request.graph
    ; graph_directory = "/worker/bad-case-05"
    ; database_path = "/worker/bad-case-05/db.sqlite"
    ; checkpoint
    ; scope = mirror_request.scope
    }
  in
  let inspected =
    Core.step selected.next (Mirror_inspected (Mirror_available open_request))
  in
  let attach_request =
    match inspected.effects with
    | [ Delegate (Attach_graph request) ] -> request
    | _ -> fail "BC05 setup mirror inspection emitted unexpected effects"
  in
  let attached =
    Core.step
      inspected.next
      (Graph_attached
         { scope = attach_request.scope
         ; checkpoint = attach_request.checkpoint
         ; outbox_records = []
         })
  in
  let websocket_token =
    match attached.effects with
    | [ Publish (State_changed _); Publish (Token_requested request) ]
      when Core.token_request_purpose request = Websocket_connect -> request
    | _ -> fail "BC05 setup graph attachment emitted unexpected effects"
  in
  let connecting =
    Core.step attached.next (Token_provided (websocket_token, "websocket-token"))
  in
  let connection =
    match connecting.effects with
    | [ Run (Start_websocket request) ] -> request.scope
    | _ -> fail "BC05 setup WebSocket authorization emitted unexpected effects"
  in
  let opened = Core.step connecting.next (Websocket_opened connection) in
  (match opened.effects with
   | [ Publish (State_changed _)
     ; Run (Send_websocket { scope; message = Protocol.Client.Pull { since = Some 0 } })
     ]
     when scope = connection -> ()
   | _ -> fail "BC05 setup WebSocket opening emitted unexpected effects");
  let closed =
    Core.step opened.next (Websocket_closed (connection, Some "socket closed"))
  in
  (match closed.effects with
   | [ Publish (State_changed state) ] when state = expected_closed_state -> ()
   | _ -> fail "BC05 setup WebSocket closure emitted unexpected effects");
  closed.next, connection
;;

let test_message_after_websocket_close_is_ignored () =
  let origin, connection = closed_graph () in
  let origin_before = Core.state origin, Core.admitted_graph_scope origin in
  let event =
    Core.Websocket_message
      (connection, Protocol.Server.Error { message = "late server error" })
  in
  let first = Core.step origin event in
  Alcotest.check
    Alcotest.bool
    "BC05 late message preserves the exact closed state"
    true
    (Core.state first.next = expected_closed_state);
  Alcotest.check
    Alcotest.bool
    "BC05 late message preserves graph admission"
    true
    (Core.admitted_graph_scope first.next = Some graph_scope);
  Alcotest.check
    Alcotest.bool
    "BC05 late message emits no failure publication"
    true
    (Core.equal_instructions first.effects []);
  Alcotest.check
    Alcotest.bool
    "BC05 step does not mutate its origin"
    true
    ((Core.state origin, Core.admitted_graph_scope origin) = origin_before);
  let replay = Core.step origin event in
  Alcotest.check
    Alcotest.bool
    "BC05 replay is deterministic"
    true
    (Core.state replay.next = Core.state first.next
     && Core.admitted_graph_scope replay.next = Core.admitted_graph_scope first.next
     && Core.equal_instructions replay.effects first.effects)
;;

let () =
  Alcotest.run
    "pure reducer bad case 05"
    [ ( "pure core bad case"
      , [ Alcotest.test_case
            "message after WebSocket close is ignored"
            `Quick
            test_message_after_websocket_close_is_ignored
        ] )
    ]
;;
