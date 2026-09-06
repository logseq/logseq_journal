open Pure_reducer_bad_case_support

(* Scenario: Snapshot progress arrives when no snapshot download owns the event.
   The reducer must ignore it without effects, then still accept authentication
   and start catalog discovery. *)
let run () =
  let origin = initial () in
  let event =
    Core.Snapshot_download_progress
      { graph_id; received_bytes = 1L; total_bytes = Some 2L }
  in
  let rejected = check_step "BC01" origin event (observe origin) [] in
  let startup_event = Core.Account_authenticated { user_id = Some "user" } in
  let startup =
    Core.step rejected.next startup_event
    |> check_replay "BC01 follow-up" rejected.next startup_event
  in
  match startup.effects with
  | [ Core.Publish (Core.State_changed _)
    ; Core.Run (Core.Request (_, Core.Fetch_catalog _))
    ] -> ()
  | _ -> Alcotest.fail "BC01 valid startup event was not accepted"
;;

let scenario = Alcotest.test_case "BC01 unowned snapshot progress" `Quick run
