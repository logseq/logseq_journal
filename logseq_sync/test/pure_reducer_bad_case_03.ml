open Pure_reducer_bad_case_support

(* Scenario: Graph attachment is replayed after the WebSocket is already live.
   The reducer must not request another token and the current connection must
   still accept its next server message. *)
let run () =
  let fixture = connected_fixture () in
  let event = Core.Graph_attached fixture.attachment in
  let rejected =
    check_step "BC03" fixture.opened.next event (observe fixture.opened.next) []
  in
  let message = Protocol.Server.Pull_ok { t = 0; checksum = None; txs = [] } in
  let follow_up = Core.Websocket_message (fixture.connection, message) in
  let accepted =
    Core.step rejected.next follow_up
    |> check_replay "BC03 follow-up" rejected.next follow_up
  in
  match accepted.effects with
  | [ Core.Publish (Core.State_changed state) ]
    when state.snapshot.sync_phase = Core.Current -> ()
  | _ -> Alcotest.fail "BC03 current connection was not retained"
;;

let scenario = Alcotest.test_case "BC03 duplicate graph attachment" `Quick run
