open Pure_reducer_bad_case_support

(* Scenario: A completed mirror inspection is replayed after graph attachment.
   The reducer must not attach the graph again and must retain the current
   WebSocket scope for its legitimate completion. *)
let run () =
  let fixture = connected_fixture () in
  let event = Core.Mirror_inspected (Core.Mirror_available fixture.mirror_request) in
  let rejected =
    check_step "BC02" fixture.attached.next event (observe fixture.attached.next) []
  in
  let follow_up = Core.Websocket_opened fixture.connection in
  let accepted =
    Core.step rejected.next follow_up
    |> check_replay "BC02 follow-up" rejected.next follow_up
  in
  match accepted.effects with
  | [ Core.Publish (Core.State_changed _); Core.Run (Core.Send_websocket _) ] -> ()
  | _ -> Alcotest.fail "BC02 current WebSocket scope was not retained"
;;

let scenario = Alcotest.test_case "BC02 duplicate mirror inspection" `Quick run
