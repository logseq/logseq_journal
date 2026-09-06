open Pure_reducer_bad_case_support

(* Scenario: An outbox completion commits a transition that differs from the
   pending request. The mismatch must be ignored without consuming ownership,
   then the exact completion must send the reserved transaction batch. *)
let run () =
  let fixture = pending_submission_fixture () in
  let mismatched_commit = { fixture.commit with transition = Overlay.Submit_group [] } in
  let mismatched_event =
    Core.Outbox_transition_applied
      { scope = fixture.request.scope
      ; commit = mismatched_commit
      ; sync = fixture.result_sync
      }
  in
  let rejected =
    check_step "BC10" fixture.origin mismatched_event (observe fixture.origin) []
  in
  let exact_event =
    Core.Outbox_transition_applied
      { scope = fixture.request.scope
      ; commit = fixture.commit
      ; sync = fixture.result_sync
      }
  in
  let accepted = Core.step rejected.next exact_event in
  match accepted.effects with
  | [ Core.Run (Core.Send_websocket { scope; message = Protocol.Client.Tx_batch _ })
    ; Core.Run (Core.Schedule_timer timer)
    ]
    when scope = fixture.connected.connection
         && timer.delay_seconds = 30.
         && timer.scope.connection_generation = Some scope.connection_generation -> ()
  | _ -> Alcotest.fail "BC10 exact transition completion was not accepted"
;;

let scenario = Alcotest.test_case "BC10 mismatched outbox transition" `Quick run
