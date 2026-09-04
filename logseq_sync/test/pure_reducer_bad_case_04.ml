open Pure_reducer_bad_case_support

(* Scenario: WebSocket_opened is replayed for an already live connection. The
   reducer must not send a duplicate pull and must preserve the connection's
   ownership of the next server message. *)
let run () =
  let fixture = connected_fixture () in
  let event = Core.Websocket_opened fixture.connection in
  let rejected =
    check_step "BC04" fixture.opened.next event (observe fixture.opened.next) []
  in
  let message = Protocol.Server.Pull_ok { t = 0; checksum = None; txs = [] } in
  let follow_up = Core.Websocket_message (fixture.connection, message) in
  let accepted =
    Core.step rejected.next follow_up
    |> check_replay "BC04 follow-up" rejected.next follow_up
  in
  match accepted.effects with
  | [ Core.Publish (Core.State_changed state) ]
    when state.snapshot.sync_phase = Core.Current -> ()
  | _ -> Alcotest.fail "BC04 live connection did not accept its next message"
;;

let scenario = Alcotest.test_case "BC04 duplicate WebSocket open" `Quick run
