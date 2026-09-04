open Pure_reducer_bad_case_support

(* Scenario: An authoritative apply completion arrives without a pending apply.
   The reducer must ignore it, then accept the same completion after a pull has
   created the matching authoritative owner. *)
let run () =
  let fixture = connected_fixture () in
  let scope = fixture.connection.graph in
  let cursor1 = token Overlay.Server_cursor.of_string "server-cursor:v1:1" in
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
  let completion = Core.Authoritative_batch_applied { scope; commit; sync } in
  let rejected =
    check_step "BC06" fixture.opened.next completion (observe fixture.opened.next) []
  in
  let remote_tx : Protocol.Server.pull_transaction =
    { t = 1; tx = "[]"; outliner_op = None }
  in
  let request_event =
    Core.Websocket_message
      ( fixture.connection
      , Protocol.Server.Pull_ok { t = 1; checksum = None; txs = [ remote_tx ] } )
  in
  let requested = Core.step rejected.next request_event in
  (match requested.effects with
   | [ Core.Delegate (Core.Apply_authoritative_batch _) ] -> ()
   | _ -> Alcotest.fail "BC06 did not create a valid authoritative owner");
  let accepted = Core.step requested.next completion in
  match accepted.effects with
  | [ Core.Publish (Core.State_changed state) ]
    when state.snapshot.applied_server_t = Some 1 -> ()
  | _ -> Alcotest.fail "BC06 exact authoritative completion was not accepted"
;;

let scenario = Alcotest.test_case "BC06 unsolicited authoritative apply" `Quick run
