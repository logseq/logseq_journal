open Pure_reducer_bad_case_support

(* Scenario: An old account's catalog fetch completes after local restoration
   starts a new account generation. The stale completion must be ignored while
   the new account's exact catalog load completion remains valid. *)
let run () =
  let old_authenticated =
    Core.step (initial ()) (Core.Account_authenticated { user_id = Some "old-user" })
  in
  let old_token = token_request old_authenticated.effects in
  let old_authorized =
    Core.step old_authenticated.next (Core.Token_provided (old_token, "old-token"))
  in
  let old_completion, old_ticket =
    match old_authorized.effects with
    | [ Core.Run (Core.Request (ticket, Core.Fetch_catalog _)) ] ->
      ( Core.Runner_completed (Core.Completion (ticket, Ok [ graph ]))
      , Core.effect_ticket_id ticket )
    | _ -> Alcotest.fail "BC07 old account did not request catalog"
  in
  let restoring =
    Core.step old_authorized.next (Core.Restore_local_account { user_id = "new-user" })
  in
  let load_completion =
    match restoring.effects with
    | [ Core.Publish (Core.State_changed _)
      ; Core.Run (Core.Request (ticket, Core.Load_catalog _))
      ] ->
      Alcotest.(check bool)
        "BC07 account requests have distinct effect IDs"
        true
        (Core.effect_ticket_id ticket <> old_ticket);
      Core.Runner_completed
        (Core.Completion
           ( ticket
           , Ok
               (Some
                  (Core.catalog_cache ~user_id:"new-user" ~graphs:[] ~selected_graph:None))
           ))
    | _ -> Alcotest.fail "BC07 replacement account did not request local catalog"
  in
  let rejected =
    check_step "BC07" restoring.next old_completion (observe restoring.next) []
  in
  let accepted = Core.step rejected.next load_completion in
  match accepted.effects with
  | [ Core.Publish (Core.State_changed state) ]
    when state.snapshot.startup.awaiting_selection -> ()
  | _ -> Alcotest.fail "BC07 new account load completion was not accepted"
;;

let scenario = Alcotest.test_case "BC07 stale catalog completion" `Quick run
