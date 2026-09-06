module Core = Logseq_sync_pure_reducer.Core

let initial () =
  let limits =
    Core.limits
      ~maximum_response_bytes:Logseq_db_types.Limits.maximum_response_bytes
      ~maximum_artifact_bytes:(1024 * 1024)
      ~submission_batch_size:32
    |> Result.get_ok
  in
  Core.config ~managed_sync_origin:(Uri.of_string "https://sync.example.test") ~limits
  |> Result.get_ok
  |> Core.initial
  |> Result.get_ok
;;

let graph : Core.graph =
  { graph_id =
      Logseq_db_types.Graph_types.Uuid.of_string "11111111-1111-4111-8111-111111111111"
      |> Result.get_ok
  ; name = "Cached encrypted journal"
  ; schema = { major = 1; minor = 0; exact = true }
  ; encrypted = true
  }
;;

let require_instruction label select effects =
  match List.find_map select effects with
  | Some value -> value
  | None -> Alcotest.fail ("Missing " ^ label)
;;

let complete core ticket result =
  Core.step core (Core.Runner_completed (Core.Completion (ticket, result)))
;;

let check_local_failure label core =
  let snapshot = (Core.state core).snapshot in
  Alcotest.(check bool)
    (label ^ ": local restore failure")
    true
    (snapshot.startup.failure = Some Core.During_local_restore);
  Alcotest.(check (option string))
    (label ^ ": diagnostic")
    (Some "wrappedGraphKeyUnavailable")
    snapshot.last_error;
  Alcotest.(check bool)
    (label ^ ": selected graph")
    true
    (snapshot.selected_graph = Some graph.graph_id);
  Alcotest.(check bool)
    (label ^ ": failed sync phase")
    true
    (snapshot.sync_phase = Core.Failed)
;;

let check_catalog_only label effects =
  Alcotest.(check bool)
    (label ^ ": no implicit graph opening or recovery")
    true
    (List.for_all
       (function
         | Core.Publish _
         | Run (Request (_, Fetch_catalog _))
         | Run (Request (_, Save_catalog _)) -> true
         | Run _ | Delegate _ -> false)
       effects)
;;

(* A warm restore can fail before same-account authentication completes.
   Authentication and catalog success must preserve the local restore failure:
   neither event retries key loading or opens the graph. Clearing the failure
   leaves startup waiting indefinitely and removes the explicit recovery action. *)
let preserves_local_restore_failure_during_reconciliation () =
  let user_id = "cached-account" in
  let restoring = Core.step (initial ()) (Core.Restore_local_account { user_id }) in
  let load_ticket =
    require_instruction
      "cached catalog load"
      (function
        | Core.Run (Core.Request (ticket, Core.Load_catalog _)) ->
          Some (ticket : Core.catalog_cache option Core.effect_ticket)
        | Run _ | Delegate _ | Publish _ -> None)
      restoring.effects
  in
  let cache =
    Core.catalog_cache ~user_id ~graphs:[ graph ] ~selected_graph:(Some graph.graph_id)
  in
  let restored = complete restoring.next load_ticket (Ok (Some cache)) in
  let scope = Core.admitted_graph_scope restored.next |> Option.get in
  let inspected =
    Core.step
      restored.next
      (Core.Mirror_inspected (Core.Mirror_available { graph; scope }))
  in
  let key_ticket =
    require_instruction
      "cached graph key load"
      (function
        | Core.Run (Core.Request (ticket, Core.Load_and_unlock_graph_key _)) ->
          Some (ticket : Core.graph_key_handle Core.effect_ticket)
        | Run _ | Delegate _ | Publish _ -> None)
      inspected.effects
  in
  let failed =
    complete
      inspected.next
      key_ticket
      (Error (Core.Effect_failed "wrappedGraphKeyUnavailable"))
  in
  check_local_failure "key load failed" failed.next;
  let authenticated =
    Core.step failed.next (Core.Account_authenticated { user_id = Some user_id })
  in
  let startup = (Core.state authenticated.next).snapshot.startup in
  Alcotest.(check bool) "same account authenticated" true startup.authenticated;
  Alcotest.(check bool) "catalog reconciliation started" true startup.catalog_loading;
  check_local_failure "same-account authentication" authenticated.next;
  check_catalog_only "authentication" authenticated.effects;
  let fetch_ticket =
    require_instruction
      "catalog reconciliation request"
      (function
        | Core.Run (Core.Request (ticket, Core.Fetch_catalog account)) ->
          Alcotest.(check string) "reconciles the same account" user_id account.user_id;
          Some (ticket : Core.graph list Core.effect_ticket)
        | Run _ | Delegate _ | Publish _ -> None)
      authenticated.effects
  in
  let refreshed = complete authenticated.next fetch_ticket (Ok [ graph ]) in
  let snapshot = (Core.state refreshed.next).snapshot in
  Alcotest.(check bool) "catalog loading finished" false snapshot.startup.catalog_loading;
  Alcotest.(check bool) "catalog refreshed" true (snapshot.catalog = [ graph ]);
  check_local_failure "catalog success" refreshed.next;
  check_catalog_only "catalog success" refreshed.effects;
  let recovery = Core.step refreshed.next Core.Online_recovery_requested in
  let recovery_scope =
    require_instruction
      "explicit E2EE recovery request"
      (function
        | Core.Run (Core.Request (_, Core.Fetch_e2ee_graph_key scope)) -> Some scope
        | Run _ | Delegate _ | Publish _ -> None)
      recovery.effects
  in
  Alcotest.(check bool) "recovery retains the graph scope" true (recovery_scope = scope);
  let snapshot = (Core.state recovery.next).snapshot in
  Alcotest.(check bool)
    "explicit recovery clears failure"
    true
    (snapshot.startup.failure = None);
  Alcotest.(check (option string))
    "explicit recovery clears diagnostic"
    None
    snapshot.last_error;
  Alcotest.(check bool)
    "recovery leaves failed sync phase"
    true
    (snapshot.sync_phase = Core.Offline)
;;

let scenario =
  Alcotest.test_case
    "local restore failure survives same-account reconciliation"
    `Quick
    preserves_local_restore_failure_during_reconciliation
;;
