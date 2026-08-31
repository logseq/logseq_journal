(* Scenario: snapshot progress arrives for a graph with no active download owner.
   Expected: the reducer ignores the event without changing state or emitting effects. *)

module Core = Logseq_sync_pure_reducer.Core

let limits () =
  Core.limits
    ~maximum_response_bytes:Logseq_db_types.Limits.maximum_response_bytes
    ~maximum_artifact_bytes:(1024 * 1024 * 1024)
    ~submission_batch_size:32
  |> Result.get_ok
;;

let initial () =
  Core.config
    ~managed_sync_origin:(Uri.of_string "https://api.logseq.io")
    ~limits:(limits ())
  |> Result.get_ok
  |> Core.initial
  |> Result.get_ok
;;

let expected_initial_state : Core.state =
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
          ; restoring_local = false
          ; bootstrapping = false
          ; awaiting_e2ee_password = false
          ; failure = None
          ; account_generation = 0
          ; graph_generation = 0
          ; presentation_generation = 0
          }
      ; last_error = None
      }
  ; diagnostics = { groups = []; history = [] }
  }
;;

let test_unowned_snapshot_progress_is_ignored () =
  let origin = initial () in
  let origin_before = Core.state origin, Core.admitted_graph_scope origin in
  let graph_id =
    Logseq_db_types.Graph_types.Uuid.of_string "11111111-1111-4111-8111-111111111111"
    |> Result.get_ok
  in
  let event =
    Core.Snapshot_download_progress
      { graph_id; received_bytes = 64L; total_bytes = Some 128L }
  in
  let first = Core.step origin event in
  Alcotest.check
    Alcotest.bool
    "BC01 unowned progress preserves the exact initial public state"
    true
    (Core.state first.next = expected_initial_state);
  Alcotest.check
    Alcotest.bool
    "BC01 unowned progress preserves the absent graph admission"
    true
    (Core.admitted_graph_scope first.next = None);
  Alcotest.check
    Alcotest.bool
    "BC01 unowned progress emits no output"
    true
    (Core.equal_instructions first.effects []);
  Alcotest.check
    Alcotest.bool
    "BC01 step does not mutate its origin"
    true
    ((Core.state origin, Core.admitted_graph_scope origin) = origin_before);
  let replay = Core.step origin event in
  Alcotest.check
    Alcotest.bool
    "BC01 replay is deterministic"
    true
    (Core.state replay.next = Core.state first.next
     && Core.admitted_graph_scope replay.next = Core.admitted_graph_scope first.next
     && Core.equal_instructions replay.effects first.effects)
;;

let () =
  Alcotest.run
    "pure reducer bad case 01"
    [ ( "pure core bad case"
      , [ Alcotest.test_case
            "unowned snapshot progress is ignored"
            `Quick
            test_unowned_snapshot_progress_is_ignored
        ] )
    ]
;;
