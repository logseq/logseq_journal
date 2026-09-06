module Core = Logseq_sync_pure_reducer.Core
module Overlay = Logseq_overlay_db.Types
module Protocol = Logseq_sync_pure_reducer.Sync_protocol

type observed =
  { state : Core.state
  ; admitted_graph_scope : Core.graph_scope option
  }

let observe core =
  { state = Core.state core; admitted_graph_scope = Core.admitted_graph_scope core }
;;

let check_observed test_id message expected actual =
  Alcotest.(check bool) (test_id ^ " " ^ message) true (expected = actual)
;;

let check_instructions test_id expected actual =
  Alcotest.(check bool)
    (test_id ^ " ordered instructions")
    true
    (Core.equal_instructions expected actual)
;;

let check_replay test_id origin event (first : Core.transition) =
  let origin_observed = observe origin in
  check_observed test_id "origin remains immutable" origin_observed (observe origin);
  let replay = Core.step origin event in
  check_observed test_id "replay observation" (observe first.next) (observe replay.next);
  check_instructions test_id first.effects replay.effects;
  first
;;

let check_step test_id origin event expected effects =
  let origin_observed = observe origin in
  let first = Core.step origin event in
  check_observed test_id "public observation" expected (observe first.next);
  check_instructions test_id effects first.effects;
  check_observed test_id "origin remains immutable" origin_observed (observe origin);
  check_replay test_id origin event first
;;

let limits () =
  Core.limits
    ~maximum_response_bytes:Logseq_db_types.Limits.maximum_response_bytes
    ~maximum_artifact_bytes:(1024 * 1024)
    ~submission_batch_size:32
  |> Result.get_ok
;;

let initial () =
  Core.config
    ~managed_sync_origin:(Uri.of_string "https://api.logseq.io")
    ~limits:(limits ())
  |> Result.get_ok
  |> Core.initial
  |> Result.get_ok
;;

let token module_of_string value = module_of_string value |> Result.get_ok

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

let mutation_ids =
  [ "22222222-2222-4222-8222-222222222221"
  ; "22222222-2222-4222-8222-222222222222"
  ; "22222222-2222-4222-8222-222222222223"
  ]
  |> List.map (fun value ->
    Logseq_db_types.Graph_types.Uuid.of_string value |> Result.get_ok)
;;

let selected_graph () =
  let authenticated =
    Core.step (initial ()) (Core.Account_authenticated { user_id = Some "user" })
  in
  let catalog =
    List.find_map
      (function
        | Core.Run (Core.Request (ticket, Core.Fetch_catalog _)) ->
          Some
            (Core.step
               authenticated.next
               (Core.Runner_completed (Core.Completion (ticket, Ok [ graph ]))))
        | Run _ | Delegate _ | Publish _ -> None)
      authenticated.effects
    |> Option.get
  in
  let selected = Core.step catalog.next (Core.Graph_selected graph_id) in
  selected, Core.admitted_graph_scope selected.next |> Option.get
;;

type connected_fixture =
  { mirror_request : Core.mirror_request
  ; attachment : Core.graph_attachment
  ; attached : Core.transition
  ; connection : Core.connection_scope
  ; opened : Core.transition
  }

let connected_fixture () =
  let selected, scope = selected_graph () in
  let mirror_request =
    match selected.effects with
    | Core.Delegate (Core.Inspect_mirror request) :: _ when request.scope = scope ->
      request
    | _ -> Alcotest.fail "connected fixture did not emit Inspect_mirror"
  in
  let inspected =
    Core.step selected.next (Core.Mirror_inspected (Core.Mirror_available mirror_request))
  in
  let attach_request =
    match inspected.effects with
    | [ Core.Delegate (Core.Attach_graph request) ] when request = mirror_request ->
      request
    | _ -> Alcotest.fail "connected fixture did not emit exact Attach_graph"
  in
  let checkpoint = token Overlay.Server_cursor.of_string "server-cursor:v1:0" in
  let sync_token = token Overlay.sync_token_of_string "sync-token:v1:fixture-0" in
  let sync = Overlay.sync_view ~token:sync_token ~checkpoint ~submissions:[] in
  let attachment : Core.graph_attachment = { scope = attach_request.scope; sync } in
  let attached = Core.step inspected.next (Core.Graph_attached attachment) in
  let connection =
    match attached.effects with
    | [ Core.Publish (Core.State_changed _); Core.Run (Core.Start_websocket request) ] ->
      request.scope
    | _ -> Alcotest.fail "connected fixture did not start WebSocket"
  in
  let opened = Core.step attached.next (Core.Websocket_opened connection) in
  (match opened.effects with
   | [ Core.Publish (Core.State_changed _)
     ; Core.Run
         (Core.Send_websocket { scope; message = Protocol.Client.Pull { since = Some 0 } })
     ]
     when scope = connection -> ()
   | _ -> Alcotest.fail "connected fixture did not issue opening Pull");
  { mirror_request; attachment; attached; connection; opened }
;;

let current_connected_fixture () =
  let fixture = connected_fixture () in
  let current =
    Core.step
      fixture.opened.next
      (Core.Websocket_message
         (fixture.connection, Protocol.Server.Pull_ok { t = 0; checksum = None; txs = [] }))
  in
  (match current.effects with
   | [ Core.Publish (Core.State_changed state) ]
     when state.snapshot.sync_phase = Core.Current -> ()
   | _ -> Alcotest.fail "current fixture did not complete opening Pull");
  fixture, current
;;

let queued_sync sync_token checkpoint mutation_id =
  let fingerprint =
    token Overlay.Mutation_fingerprint.of_string "mutation-fingerprint:v1:bad-case"
  in
  let descriptor : Overlay.submission_descriptor =
    { mutation_id
    ; fingerprint
    ; state = Overlay.Queued
    ; dependency_eligible = true
    ; attempt_count = 0
    ; plaintext_bytes = 16
    ; protected_bytes = Some 16
    }
  in
  Overlay.sync_view ~token:sync_token ~checkpoint ~submissions:[ descriptor ]
;;

type pending_submission_fixture =
  { connected : connected_fixture
  ; origin : Core.t
  ; request : Core.outbox_transition_request
  ; commit : Overlay.outbox_commit
  ; result_sync : Overlay.sync_view
  }

let pending_submission_fixture () =
  let connected, current = current_connected_fixture () in
  let scope = connected.connection.graph in
  let changed = Core.step current.next Core.Local_outbox_changed in
  (match changed.effects with
   | [ Core.Delegate (Core.Inspect_sync requested_scope) ] when requested_scope = scope ->
     ()
   | _ -> Alcotest.fail "pending submission fixture did not inspect sync state");
  let mutation_id = List.hd mutation_ids in
  let checkpoint = token Overlay.Server_cursor.of_string "server-cursor:v1:0" in
  let expected = token Overlay.sync_token_of_string "sync-token:v1:bad-case-before" in
  let sync = queued_sync expected checkpoint mutation_id in
  let planned = Core.step changed.next (Core.Sync_inspected { scope; sync }) in
  let request =
    match planned.effects with
    | [ Core.Publish (Core.State_changed _)
      ; Core.Delegate (Core.Apply_outbox_transition request)
      ]
      when request.scope = scope
           && request.transition = Overlay.Submit_group [ mutation_id ] -> request
    | _ -> Alcotest.fail "pending submission fixture did not reserve Submit_group"
  in
  let batch_id =
    token Overlay.Submission_batch_id.of_string "submission-batch:v1:bad-case"
  in
  let wire =
    Overlay.submission_wire
      ~maximum_bytes:1024
      ~mutation_id
      ~operation:Overlay.Save_block_operation
      ~protected_transaction:"protected-bad-case"
    |> Result.get_ok
  in
  let batch =
    Overlay.submission_batch
      ~maximum_wires:1
      ~maximum_bytes:4096
      ~batch_id
      ~t_before:checkpoint
      ~wires:[ wire ]
    |> Result.get_ok
  in
  let generation = token Overlay.Generation.of_string "generation:v1:10" in
  let projection = token Overlay.Projection_revision.of_string "projection:v1:10" in
  let result_token = token Overlay.sync_token_of_string "sync-token:v1:bad-case-after" in
  let commit : Overlay.outbox_commit =
    { generation
    ; before_projection_revision = projection
    ; after_projection_revision = projection
    ; sync_token = result_token
    ; transition = request.transition
    ; activity = Overlay.Logically_active
    ; logical_change_summary = Overlay.No_logical_change
    ; submission_batch = Some batch
    }
  in
  let submitted_descriptor =
    match Overlay.sync_view_submissions sync with
    | [ descriptor ] -> { descriptor with state = Overlay.Submitted batch_id }
    | _ -> assert false
  in
  let result_sync =
    Overlay.sync_view
      ~token:result_token
      ~checkpoint
      ~submissions:[ submitted_descriptor ]
  in
  { connected; origin = planned.next; request; commit; result_sync }
;;
