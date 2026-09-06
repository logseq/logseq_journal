open Pure_reducer_bad_case_support

(* Scenario: An old WebSocket opens after recovery started a replacement.
   The stale connection must be ignored without consuming the fresh scope. *)
let run () =
  let fixture = connected_fixture () in
  let recovery =
    Core.step
      fixture.attached.next
      (Core.Foreground_changed { foreground = true; lifecycle_generation = 1L })
  in
  let fresh_connection =
    match recovery.effects with
    | [ Core.Publish (Core.State_changed _); Core.Run (Core.Start_websocket request) ] ->
      request.scope
    | _ -> Alcotest.fail "BC08 recovery did not start a fresh connection"
  in
  Alcotest.(check bool)
    "BC08 connection generations differ"
    true
    (fresh_connection.connection_generation <> fixture.connection.connection_generation);
  let stale_event = Core.Websocket_opened fixture.connection in
  let rejected = check_step "BC08" recovery.next stale_event (observe recovery.next) [] in
  let fresh_event = Core.Websocket_opened fresh_connection in
  let accepted =
    Core.step rejected.next fresh_event
    |> check_replay "BC08 follow-up" rejected.next fresh_event
  in
  match accepted.effects with
  | [ Core.Publish (Core.State_changed _); Core.Run (Core.Send_websocket _) ] -> ()
  | _ -> Alcotest.fail "BC08 fresh connection was not accepted"
;;

let scenario = Alcotest.test_case "BC08 replaced WebSocket connection" `Quick run
