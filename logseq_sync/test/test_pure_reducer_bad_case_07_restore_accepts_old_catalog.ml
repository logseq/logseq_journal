(* Scenario: an old account's catalog load completes after a new account restore begins.
   Expected: the reducer rejects the stale completion and keeps the new catalog empty. *)

module Core = Logseq_sync_pure_reducer.Core

let fail format = Printf.ksprintf (fun message -> Alcotest.fail message) format

let initial () =
  let limits =
    Core.limits
      ~maximum_response_bytes:Logseq_db_types.Limits.maximum_response_bytes
      ~maximum_artifact_bytes:(1024 * 1024 * 1024)
      ~submission_batch_size:32
    |> Result.get_ok
  in
  Core.config ~managed_sync_origin:(Uri.of_string "https://api.logseq.io") ~limits
  |> Result.get_ok
  |> Core.initial
  |> Result.get_ok
;;

let old_graph_id =
  Logseq_db_types.Graph_types.Uuid.of_string "11111111-1111-4111-8111-111111111111"
  |> Result.get_ok
;;

let old_graph : Core.graph =
  { graph_id = old_graph_id
  ; name = "Old account graph"
  ; schema = { major = 1; minor = 0; exact = true }
  ; encrypted = false
  }
;;

let expected_restoring_state : Core.state =
  { snapshot =
      { sync_phase = Offline
      ; catalog = []
      ; selected_graph = None
      ; applied_server_t = None
      ; timeline_presentation_pending = true
      ; startup =
          { authenticated = false
          ; catalog_loading = false
          ; awaiting_selection = false
          ; restoring_local = true
          ; bootstrapping = false
          ; awaiting_e2ee_password = false
          ; failure = None
          ; account_generation = 2
          ; graph_generation = 2
          ; presentation_generation = 2
          }
      ; last_error = None
      }
  ; diagnostics = { groups = []; history = [] }
  }
;;

let expected_new_account_state : Core.state =
  { snapshot =
      { sync_phase = Offline
      ; catalog = []
      ; selected_graph = None
      ; applied_server_t = None
      ; timeline_presentation_pending = true
      ; startup =
          { authenticated = false
          ; catalog_loading = false
          ; awaiting_selection = true
          ; restoring_local = false
          ; bootstrapping = false
          ; awaiting_e2ee_password = false
          ; failure = None
          ; account_generation = 2
          ; graph_generation = 2
          ; presentation_generation = 2
          }
      ; last_error = None
      }
  ; diagnostics = { groups = []; history = [] }
  }
;;

let test_restore_rejects_previous_account_catalog_completion () =
  let authenticated =
    Core.step (initial ()) (Account_authenticated { user_id = Some "user-1" })
  in
  let token =
    match authenticated.effects with
    | [ Publish (State_changed _); Publish (Token_requested request) ] -> request
    | _ -> fail "BC07 setup authentication emitted unexpected effects"
  in
  let old_catalog_pending =
    Core.step authenticated.next (Token_provided (token, "old-account-token"))
  in
  let old_completion =
    match old_catalog_pending.effects with
    | [ Run (Request (ticket, Fetch_catalog _)) ] ->
      Core.Runner_completed (Core.Completion (ticket, Ok [ old_graph ]))
    | _ -> fail "BC07 setup old catalog authorization emitted unexpected effects"
  in
  let restoring =
    Core.step old_catalog_pending.next (Restore_local_account { user_id = "user-2" })
  in
  let new_completion =
    match restoring.effects with
    | [ Publish (State_changed state); Run (Request (ticket, Load_catalog _)) ]
      when state = expected_restoring_state ->
      Core.Runner_completed (Core.Completion (ticket, Ok None))
    | _ -> fail "BC07 setup local restore emitted unexpected effects"
  in
  let origin = restoring.next in
  let origin_before = Core.state origin, Core.admitted_graph_scope origin in
  let late_old = Core.step origin old_completion in
  Alcotest.check
    Alcotest.bool
    "BC07 late old completion preserves the exact restoration state"
    true
    (Core.state late_old.next = expected_restoring_state);
  Alcotest.check
    Alcotest.bool
    "BC07 late old completion preserves the absent graph admission"
    true
    (Core.admitted_graph_scope late_old.next = None);
  Alcotest.check
    Alcotest.bool
    "BC07 late old completion emits no output"
    true
    (Core.equal_instructions late_old.effects []);
  Alcotest.check
    Alcotest.bool
    "BC07 stale-completion step does not mutate its restoration origin"
    true
    ((Core.state origin, Core.admitted_graph_scope origin) = origin_before);
  let replay = Core.step origin old_completion in
  Alcotest.check
    Alcotest.bool
    "BC07 stale completion replay is deterministic"
    true
    (Core.state replay.next = Core.state late_old.next
     && Core.admitted_graph_scope replay.next = Core.admitted_graph_scope late_old.next
     && Core.equal_instructions replay.effects late_old.effects);
  let restored = Core.step late_old.next new_completion in
  Alcotest.check
    Alcotest.bool
    "BC07 new account restore ends with its empty catalog"
    true
    (Core.state restored.next = expected_new_account_state);
  Alcotest.check
    Alcotest.bool
    "BC07 new account restore retains no graph admission"
    true
    (Core.admitted_graph_scope restored.next = None);
  Alcotest.check
    Alcotest.bool
    "BC07 new restore publishes only the new account state"
    true
    (Core.equal_instructions
       restored.effects
       [ Publish (State_changed expected_new_account_state) ])
;;

let () =
  Alcotest.run
    "pure reducer bad case 07"
    [ ( "pure core bad case"
      , [ Alcotest.test_case
            "restore rejects previous account catalog completion"
            `Quick
            test_restore_rejects_previous_account_catalog_completion
        ] )
    ]
;;
