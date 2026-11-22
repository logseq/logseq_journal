let server_cursor_of_int value =
  Logseq_db_types.Server_cursor.of_int64 (Int64.of_int value) |> Result.get_ok
;;

open Pure_reducer_bad_case_support

(* Scenario: An authoritative apply completion arrives without a pending apply.
   The reducer must ignore it, then accept the same completion after a pull has
   created the matching authoritative owner. *)
let run () =
  let fixture = connected_fixture () in
  let cursor1 = token Overlay.Server_cursor.of_int64 1L in
  let sync_token = token Overlay.sync_token_of_string "sync-token:v1:bc06" in
  let generation = token Overlay.Generation.of_string "generation:v1:6" in
  let projection = token Overlay.Projection_revision.of_string "projection:v1:6" in
  let sync = Overlay.sync_view ~token:sync_token ~checkpoint:cursor1 ~submissions:[] in
  let commit : Overlay.authoritative_commit =
    { generation
    ; before_projection_revision = projection
    ; after_projection_revision = projection
    ; checkpoint = cursor1
    ; sync_token
    ; terminal_receipts = []
    ; replanned_queued_ids = []
    ; blocked_ids = []
    ; logical_change_summary = Overlay.No_logical_change
    }
  in
  let remote_tx : Protocol.Server.pull_transaction =
    { t = server_cursor_of_int 1; tx = "[]"; outliner_op = None }
  in
  let request_event =
    Core.Websocket_message
      ( fixture.connection
      , Protocol.Server.Pull_ok
          { t = server_cursor_of_int 1; checksum = None; txs = [ remote_tx ] } )
  in
  let requested = Core.step fixture.opened.next request_event in
  let request = match requested.effects with
   | [ Core.Delegate (Core.Apply_authoritative_batch request)
     ; Core.Publish (Core.State_changed state) ]
     when List.exists (fun (group : Core.diagnostic_group) ->
       List.assoc_opt "Remote tx" group.entries = Some "1") state.diagnostics.groups -> request
   | _ -> Alcotest.fail "BC06 did not create a valid authoritative owner"
  in
  let completion = Core.Authoritative_batch_applied { request; commit; sync } in
  ignore (check_step "BC06" fixture.opened.next completion (observe fixture.opened.next) []);
  let accepted = Core.step requested.next completion in
  match accepted.effects with
  | [ Core.Publish (Core.State_changed state) ]
    when state.snapshot.applied_server_t = Some (server_cursor_of_int 1) -> ()
  | _ -> Alcotest.fail "BC06 exact authoritative completion was not accepted"
;;

let run_stale_same_graph () =
  let fixture = connected_fixture () in
  let pull core cursor =
    let t = server_cursor_of_int cursor in
    let tx : Protocol.Server.pull_transaction = { t; tx = "[]"; outliner_op = None } in
    Core.step core (Core.Websocket_message
      (fixture.connection, Protocol.Server.Pull_ok { t; checksum = None; txs = [ tx ] }))
  in
  let request effects =
    List.find_map (function Core.Delegate (Core.Apply_authoritative_batch request) -> Some request | _ -> None) effects
    |> Option.get
  in
  let complete request cursor =
    let checkpoint = server_cursor_of_int cursor in
    let sync_token = token Overlay.sync_token_of_string ("sync-token:v1:stale-" ^ string_of_int cursor) in
    let projection = token Overlay.Projection_revision.of_string "projection:v1:6" in
    let commit : Overlay.authoritative_commit =
      { generation = token Overlay.Generation.of_string "generation:v1:6"
      ; before_projection_revision = projection; after_projection_revision = projection
      ; checkpoint; sync_token; terminal_receipts = []; replanned_queued_ids = []
      ; blocked_ids = []; logical_change_summary = Overlay.No_logical_change }
    in
    let sync = Overlay.sync_view ~token:sync_token ~checkpoint ~submissions:[] in
    Core.Authoritative_batch_applied { request; commit; sync }
  in
  let first = pull fixture.opened.next 1 in
  let demand = Core.step first.next
    (Core.Websocket_message (fixture.connection, Protocol.Server.Changed { t = server_cursor_of_int 2 }))
  in
  let first_receipt = complete (request first.effects) 1 in
  let committed = Core.step demand.next first_receipt in
  let second = pull committed.next 2 in
  let second_receipt = complete (request second.effects) 2 in
  let stale = Core.step second.next first_receipt in
  Alcotest.(check bool) "late receipt leaves the newer apply pending" true
    (stale.effects = [] && Core.state stale.next = Core.state second.next);
  let accepted = Core.step stale.next second_receipt in
  Alcotest.(check bool) "original receipt still advances the checkpoint" true
    ((Core.state accepted.next).snapshot.applied_server_t = Some (server_cursor_of_int 2))
;;

let scenario = Alcotest.test_case "BC06 unsolicited authoritative apply" `Quick run

let stale_same_graph =
  Alcotest.test_case "authoritative stale same-graph receipt preserves pending attempt" `Quick
    run_stale_same_graph
