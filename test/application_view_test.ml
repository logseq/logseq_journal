module Service = Logseq_db_worker_bonsai.Logseq_db_worker_bonsai_service

let check_pairs label expected actual =
  Alcotest.(check (list (pair string string))) label expected actual
;;

let test_phase_names () =
  let sync_phases =
    [ Service.Offline, "Offline"
    ; Connecting, "Connecting"
    ; Pulling, "Pulling"
    ; Submitting, "Submitting"
    ; Current, "Current"
    ; Paused, "Paused"
    ; Failed, "Failed"
    ]
  in
  List.iter
    (fun (phase, expected) ->
       Alcotest.(check string) expected expected (Application.sync_phase_name phase))
    sync_phases;
  let graph_phases =
    [ Logseq_db_worker.Graph_closed, "Closed"
    ; Graph_opening, "Opening"
    ; Graph_open, "Open"
    ; Graph_closing, "Closing"
    ; Graph_failed, "Failed"
    ]
  in
  List.iter
    (fun (phase, expected) ->
       Alcotest.(check string) expected expected (Application.graph_phase_name phase))
    graph_phases
;;

let test_diagnostics_hide_retired_phase_rows () =
  let diagnostics : Service.diagnostics =
    { groups =
        [ { title = "Manager"
          ; entries =
              [ "Phase", "retired"
              ; "Startup presentation", "retired"
              ; "Last error", "None"
              ]
          }
        ; { title = "Graph"; entries = [ "Selected graph", "Fixture" ] }
        ]
    ; history = [ "ignored by the compact diagnostic view" ]
    }
  in
  check_pairs
    "current diagnostic rows"
    [ "Last error", "None"; "Selected graph", "Fixture" ]
    (Application.diagnostic_rows diagnostics)
;;

let test_missing_snapshot_keeps_graph_lifecycle_visible () =
  let graph : Logseq_db_worker.graph_state =
    { generation = 4; graph_id = None; phase = Graph_opening; error = None }
  in
  check_pairs
    "phase rows without a manager snapshot"
    [ "Sync phase", "Not available"
    ; "Startup phase", "Not available"
    ; "Graph phase", "Opening"
    ]
    (Application.diagnostic_phase_rows ~snapshot:None ~graph)
;;

let () =
  Alcotest.run
    "application view"
    [ ( "worker presentation"
      , [ Alcotest.test_case "phase labels" `Quick test_phase_names
        ; Alcotest.test_case
            "retired diagnostics are hidden"
            `Quick
            test_diagnostics_hide_retired_phase_rows
        ; Alcotest.test_case
            "graph lifecycle survives missing snapshot"
            `Quick
            test_missing_snapshot_keeps_graph_lifecycle_visible
        ] )
    ]
;;
