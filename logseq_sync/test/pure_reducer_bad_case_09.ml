open Pure_reducer_bad_case_support

(* Scenario: Sync inspection data arrives without a pending Inspect_sync. The
   reducer must ignore it, then accept the same data after a local outbox change
   creates the exact inspection owner and reserve the eligible submission. *)
let run () =
  let fixture, current = current_connected_fixture () in
  let scope = fixture.connection.graph in
  let checkpoint = token Overlay.Server_cursor.of_string "server-cursor:v1:0" in
  let sync_token = token Overlay.sync_token_of_string "sync-token:v1:bc09" in
  let sync = queued_sync sync_token checkpoint (List.hd mutation_ids) in
  let event = Core.Sync_inspected { scope; sync } in
  let rejected = check_step "BC09" current.next event (observe current.next) [] in
  let changed = Core.step rejected.next Core.Local_outbox_changed in
  (match changed.effects with
   | [ Core.Delegate (Core.Inspect_sync requested_scope) ] when requested_scope = scope ->
     ()
   | _ -> Alcotest.fail "BC09 valid sync inspection was not requested");
  let accepted = Core.step changed.next event in
  match accepted.effects with
  | [ Core.Publish (Core.State_changed state)
    ; Core.Delegate (Core.Apply_outbox_transition request)
    ]
    when state.snapshot.sync_phase = Core.Submitting
         && request.transition = Overlay.Submit_group [ List.hd mutation_ids ] -> ()
  | _ -> Alcotest.fail "BC09 exact requested sync result was not accepted"
;;

let scenario = Alcotest.test_case "BC09 unsolicited sync inspection" `Quick run
