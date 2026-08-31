(* Scenario: a rejected graph-token response is replayed after a new challenge is issued.
   Expected: the fresh challenge accepts its own response once and rejects the stale one. *)

module Core = Logseq_sync_pure_reducer.Core

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

let expected_failed_state : Core.state =
  { snapshot =
      { sync_phase = Failed
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
          ; failure = Some During_authentication
          ; account_generation = 1
          ; graph_generation = 2
          ; presentation_generation = 1
          }
      ; last_error = Some "authentication token was rejected"
      }
  ; diagnostics = { groups = []; history = [] }
  }
;;

let attached_graph () =
  let authenticated =
    Core.step (initial ()) (Account_authenticated { user_id = Some "user-1" })
  in
  let catalog_token =
    match authenticated.effects with
    | [ Publish (State_changed _); Publish (Token_requested request) ] -> request
    | _ -> fail "BC08 setup authentication emitted unexpected effects"
  in
  let authorized =
    Core.step authenticated.next (Token_provided (catalog_token, "catalog-token"))
  in
  let catalog_completion =
    match authorized.effects with
    | [ Run (Request (ticket, Fetch_catalog _)) ] ->
      Core.Runner_completed (Core.Completion (ticket, Ok [ graph ]))
    | _ -> fail "BC08 setup catalog authorization emitted unexpected effects"
  in
  let catalogued = Core.step authorized.next catalog_completion in
  let selected = Core.step catalogued.next (Graph_selected graph_id) in
  let mirror_request =
    match selected.effects with
    | [ Delegate (Inspect_mirror request)
      ; Publish (State_changed _)
      ; Run (Request (_, Save_catalog _))
      ] -> request
    | _ -> fail "BC08 setup graph selection emitted unexpected effects"
  in
  let open_request : Core.graph_open_request =
    { graph = mirror_request.graph
    ; graph_directory = "/worker/bad-case-08"
    ; database_path = "/worker/bad-case-08/db.sqlite"
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
    | _ -> fail "BC08 setup mirror inspection emitted unexpected effects"
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
    | _ -> fail "BC08 setup graph attachment emitted unexpected effects"
  in
  attached.next, websocket_token
;;

let test_rejected_graph_token_cannot_satisfy_later_challenge () =
  let attached, old_request = attached_graph () in
  let rejected = Core.step attached (Token_rejected old_request) in
  (match rejected.effects with
   | [ Publish (State_changed state) ] when state = expected_failed_state -> ()
   | _ -> fail "BC08 setup token rejection emitted unexpected effects");
  let retried =
    Core.step
      rejected.next
      (Foreground_changed { foreground = true; lifecycle_generation = 1L })
  in
  let new_request =
    match retried.effects with
    | [ Publish (Token_requested request) ]
      when Core.token_request_purpose request = Websocket_connect -> request
    | _ -> fail "BC08 setup foreground retry emitted unexpected effects"
  in
  let origin = retried.next in
  let origin_before = Core.state origin, Core.admitted_graph_scope origin in
  let replacement_token = "replacement-token" in
  let accepted = Core.step origin (Token_provided (new_request, replacement_token)) in
  (match accepted.effects with
   | [ Run (Start_websocket request) ]
     when request.scope.graph = graph_scope
          && String.equal request.token replacement_token -> ()
   | _ -> fail "BC08 replacement challenge did not start the current graph WebSocket");
  Alcotest.check
    Alcotest.bool
    "BC08 replacement token preserves the failed public state until WebSocket open"
    true
    (Core.state accepted.next = expected_failed_state);
  Alcotest.check
    Alcotest.bool
    "BC08 replacement token preserves graph admission"
    true
    (Core.admitted_graph_scope accepted.next = Some graph_scope);
  let duplicate =
    Core.step accepted.next (Token_provided (new_request, replacement_token))
  in
  Alcotest.check
    Alcotest.bool
    "BC08 consumed replacement challenge is ignored"
    true
    (Core.state duplicate.next = Core.state accepted.next
     && Core.admitted_graph_scope duplicate.next = Core.admitted_graph_scope accepted.next
     && Core.equal_instructions duplicate.effects []);
  Alcotest.check
    Alcotest.bool
    "BC08 replacement challenge has a fresh opaque ID"
    false
    (String.equal (Core.token_request_id old_request) (Core.token_request_id new_request));
  let event = Core.Token_provided (old_request, "late-old-token") in
  let first = Core.step origin event in
  Alcotest.check
    Alcotest.bool
    "BC08 stale token preserves the exact failed state"
    true
    (Core.state first.next = expected_failed_state);
  Alcotest.check
    Alcotest.bool
    "BC08 stale token preserves graph admission"
    true
    (Core.admitted_graph_scope first.next = Some graph_scope);
  Alcotest.check
    Alcotest.bool
    "BC08 stale token emits no WebSocket start"
    true
    (Core.equal_instructions first.effects []);
  Alcotest.check
    Alcotest.bool
    "BC08 step does not mutate its origin"
    true
    ((Core.state origin, Core.admitted_graph_scope origin) = origin_before);
  let replay = Core.step origin event in
  Alcotest.check
    Alcotest.bool
    "BC08 replay is deterministic"
    true
    (Core.state replay.next = Core.state first.next
     && Core.admitted_graph_scope replay.next = Core.admitted_graph_scope first.next
     && Core.equal_instructions replay.effects first.effects)
;;

let () =
  Alcotest.run
    "pure reducer bad case 08"
    [ ( "pure core bad case"
      , [ Alcotest.test_case
            "rejected graph token cannot satisfy later challenge"
            `Quick
            test_rejected_graph_token_cannot_satisfy_later_challenge
        ] )
    ]
;;
