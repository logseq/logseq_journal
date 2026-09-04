open Pure_reducer_bad_case_support

(* Scenario: A server message arrives after its WebSocket connection closed.
   The reducer must ignore the late message, then recover with a fresh token
   and a distinct connection generation. *)
let run () =
  let fixture = connected_fixture () in
  let closed_event = Core.Websocket_closed (fixture.connection, Some "closed") in
  let closed = Core.step fixture.opened.next closed_event in
  let late_message =
    Core.Websocket_message
      (fixture.connection, Protocol.Server.Pull_ok { t = 0; checksum = None; txs = [] })
  in
  let rejected = check_step "BC05" closed.next late_message (observe closed.next) [] in
  let recovery_event =
    Core.Foreground_changed { foreground = true; lifecycle_generation = 1L }
  in
  let recovery = Core.step rejected.next recovery_event in
  let fresh_token =
    match recovery.effects with
    | [ Core.Publish (Core.Token_requested request) ]
      when Core.token_request_purpose request = Core.Websocket_connect -> request
    | _ -> Alcotest.fail "BC05 did not issue a fresh WebSocket token"
  in
  let reconnected =
    Core.step recovery.next (Core.Token_provided (fresh_token, "fresh-token"))
  in
  match reconnected.effects with
  | [ Core.Publish (Core.State_changed _); Core.Run (Core.Start_websocket request) ] ->
    Alcotest.(check bool)
      "BC05 replacement connection generation"
      true
      (request.scope.connection_generation <> fixture.connection.connection_generation)
  | _ -> Alcotest.fail "BC05 fresh WebSocket token was not accepted"
;;

let scenario = Alcotest.test_case "BC05 message after WebSocket close" `Quick run
