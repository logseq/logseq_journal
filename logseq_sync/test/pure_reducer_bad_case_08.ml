open Pure_reducer_bad_case_support

(* Scenario: A replaced WebSocket token is provided after recovery requested a
   fresh token. The stale token must be ignored without consuming the fresh
   token owner, whose exact completion must still start the WebSocket. *)
let run () =
  let fixture = connected_fixture () in
  let recovery =
    Core.step
      fixture.attached.next
      (Core.Foreground_changed { foreground = true; lifecycle_generation = 1L })
  in
  let fresh_token =
    match recovery.effects with
    | [ Core.Publish (Core.Token_requested request) ] -> request
    | _ -> Alcotest.fail "BC08 recovery did not issue a fresh token"
  in
  Alcotest.(check bool)
    "BC08 opaque token IDs differ"
    true
    (Core.token_request_id fresh_token <> Core.token_request_id fixture.websocket_token);
  let stale_event = Core.Token_provided (fixture.websocket_token, "stale-token") in
  let rejected = check_step "BC08" recovery.next stale_event (observe recovery.next) [] in
  let fresh_event = Core.Token_provided (fresh_token, "fresh-token") in
  let accepted =
    Core.step rejected.next fresh_event
    |> check_replay "BC08 follow-up" rejected.next fresh_event
  in
  match accepted.effects with
  | [ Core.Publish (Core.State_changed _); Core.Run (Core.Start_websocket _) ] -> ()
  | _ -> Alcotest.fail "BC08 fresh token was not accepted"
;;

let scenario = Alcotest.test_case "BC08 replaced WebSocket token" `Quick run
