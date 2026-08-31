(* Scenario: an outbox commit reports durable data that differs from the reservation.
   Expected: the reducer ignores it while retaining the reservation for an exact result. *)

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

let mutation_id =
  Logseq_db_types.Graph_types.Uuid.of_string "33333333-3333-4333-8333-333333333333"
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

let expected_current_state : Core.state =
  { snapshot =
      { sync_phase = Current
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
      ; last_error = None
      }
  ; diagnostics = { groups = []; history = [] }
  }
;;

let expected_submitting_state : Core.state =
  { expected_current_state with
    snapshot = { expected_current_state.snapshot with sync_phase = Submitting }
  }
;;

let current_graph () =
  let authenticated =
    Core.step (initial ()) (Account_authenticated { user_id = Some "user-1" })
  in
  let catalog_token =
    match authenticated.effects with
    | [ Publish (State_changed _); Publish (Token_requested request) ] -> request
    | _ -> fail "BC10 setup authentication emitted unexpected effects"
  in
  let authorized =
    Core.step authenticated.next (Token_provided (catalog_token, "catalog-token"))
  in
  let catalog_completion =
    match authorized.effects with
    | [ Run (Request (ticket, Fetch_catalog _)) ] ->
      Core.Runner_completed (Core.Completion (ticket, Ok [ graph ]))
    | _ -> fail "BC10 setup catalog authorization emitted unexpected effects"
  in
  let catalogued = Core.step authorized.next catalog_completion in
  let selected = Core.step catalogued.next (Graph_selected graph_id) in
  let mirror_request =
    match selected.effects with
    | [ Delegate (Inspect_mirror request)
      ; Publish (State_changed _)
      ; Run (Request (_, Save_catalog _))
      ] -> request
    | _ -> fail "BC10 setup graph selection emitted unexpected effects"
  in
  let open_request : Core.graph_open_request =
    { graph = mirror_request.graph
    ; graph_directory = "/worker/bad-case-10"
    ; database_path = "/worker/bad-case-10/db.sqlite"
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
    | _ -> fail "BC10 setup mirror inspection emitted unexpected effects"
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
    | _ -> fail "BC10 setup graph attachment emitted unexpected effects"
  in
  let connecting =
    Core.step attached.next (Token_provided (websocket_token, "websocket-token"))
  in
  let connection =
    match connecting.effects with
    | [ Run (Start_websocket request) ] -> request.scope
    | _ -> fail "BC10 setup WebSocket authorization emitted unexpected effects"
  in
  let opened = Core.step connecting.next (Websocket_opened connection) in
  (match opened.effects with
   | [ Publish (State_changed _)
     ; Run (Send_websocket { scope; message = Protocol.Client.Pull { since = Some 0 } })
     ]
     when scope = connection -> ()
   | _ -> fail "BC10 setup WebSocket opening emitted unexpected effects");
  let opening_message =
    Protocol.Server.Pull_ok { t = 0; checksum = Some "0000000000000000"; txs = [] }
  in
  let received =
    Core.step opened.next (Websocket_message (connection, opening_message))
  in
  let batch =
    match received.effects with
    | [ Delegate (Inspect_authoritative_batch batch) ] -> batch
    | _ -> fail "BC10 setup opening pull emitted unexpected effects"
  in
  let context : Core.authoritative_context =
    { batch
    ; precondition = "bc10-opening-precondition"
    ; checkpoint
    ; database = Datascript.empty_db ()
    ; outbox_records = []
    }
  in
  let planned = Core.step received.next (Authoritative_batch_inspected context) in
  let apply_request =
    match planned.effects with
    | [ Delegate (Apply_authoritative_batch request) ] -> request
    | _ -> fail "BC10 setup authoritative inspection emitted unexpected effects"
  in
  let applied =
    Core.step
      planned.next
      (Authoritative_batch_applied
         { scope = apply_request.scope
         ; checkpoint = apply_request.checkpoint
         ; outbox_records = apply_request.outbox_records
         ; activity = apply_request.activity
         ; invalidation = None
         })
  in
  (match applied.effects with
   | [ Publish (State_changed state) ] when state = expected_current_state -> ()
   | _ -> fail "BC10 setup authoritative apply emitted unexpected effects");
  applied.next, connection
;;

let reserved_outbox_transition () =
  let current, connection = current_graph () in
  let operation =
    Datascript.Add
      ( Datascript.Temp_id "bc10-block"
      , "block/uuid"
      , Datascript.Uuid "33333333-3333-4333-8333-333333333333" )
  in
  let input =
    Core.local_batch_input
      ~scope:graph_scope
      ~admission_id:"bc10-admission"
      ~key:None
      ~outbox_records:[]
      ~mutation_id
      ~mutation_payload:"bc10-mutation"
      ~mutation_fingerprint:"bc10-fingerprint"
      ~outliner_op:"save-block"
      ~database:(Datascript.empty_db ())
      ~operations:[ operation ]
    |> Result.get_ok
  in
  let prepared = Core.step current (Local_batch_prepared input) in
  let local_commit =
    match prepared.effects with
    | [ Delegate (Complete_local_batch { scope; action = Commit { outbox_records }; _ }) ]
      -> Core.Local_batch_committed { scope; outbox_records }
    | _ -> fail "BC10 setup local planning emitted unexpected effects"
  in
  let committed = Core.step prepared.next local_commit in
  let transition =
    match committed.effects with
    | [ Delegate (Commit_outbox_transition transition) ] -> transition
    | _ -> fail "BC10 setup local commit emitted unexpected effects"
  in
  committed.next, transition, connection
;;

let test_mismatched_outbox_commit_is_ignored () =
  let origin, transition, connection = reserved_outbox_transition () in
  let origin_before = Core.state origin, Core.admitted_graph_scope origin in
  let event =
    Core.Outbox_transition_committed
      { scope = transition.scope
      ; outbox_records = []
      ; pending_message = transition.pending_message
      }
  in
  let first = Core.step origin event in
  Alcotest.check
    Alcotest.bool
    "BC10 mismatched durable result preserves the exact current state"
    true
    (Core.state first.next = expected_current_state);
  Alcotest.check
    Alcotest.bool
    "BC10 mismatched durable result preserves graph admission"
    true
    (Core.admitted_graph_scope first.next = Some graph_scope);
  Alcotest.check
    Alcotest.bool
    "BC10 mismatched durable result dispatches no transaction"
    true
    (Core.equal_instructions first.effects []);
  Alcotest.check
    Alcotest.bool
    "BC10 step does not mutate its origin"
    true
    ((Core.state origin, Core.admitted_graph_scope origin) = origin_before);
  let replay = Core.step origin event in
  Alcotest.check
    Alcotest.bool
    "BC10 replay is deterministic"
    true
    (Core.state replay.next = Core.state first.next
     && Core.admitted_graph_scope replay.next = Core.admitted_graph_scope first.next
     && Core.equal_instructions replay.effects first.effects);
  let pending_message =
    match transition.pending_message with
    | Some message -> message
    | None -> fail "BC10 setup reservation has no pending message"
  in
  let recovered =
    Core.step
      first.next
      (Outbox_transition_committed
         { scope = transition.scope
         ; outbox_records = transition.outbox_records
         ; pending_message = transition.pending_message
         })
  in
  Alcotest.check
    Alcotest.bool
    "BC10 exact follow-up completion advances to submitting"
    true
    (Core.state recovered.next = expected_submitting_state);
  Alcotest.check
    Alcotest.bool
    "BC10 exact follow-up completion preserves graph admission"
    true
    (Core.admitted_graph_scope recovered.next = Some graph_scope);
  Alcotest.check
    Alcotest.bool
    "BC10 exact follow-up completion dispatches the reserved transaction once"
    true
    (Core.equal_instructions
       recovered.effects
       [ Run (Send_websocket { scope = connection; message = pending_message })
       ; Publish (State_changed expected_submitting_state)
       ])
;;

let () =
  Alcotest.run
    "pure reducer bad case 10"
    [ ( "pure core bad case"
      , [ Alcotest.test_case
            "mismatched outbox commit is ignored"
            `Quick
            test_mismatched_outbox_commit_is_ignored
        ] )
    ]
;;
