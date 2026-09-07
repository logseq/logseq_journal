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

let admission_inspection : Logseq_db_worker.Protocol.v2_admission_inspection =
  { active_records = 3
  ; active_bytes = 1536
  ; protected_wire_bytes = 512
  ; retained_origin_evidence_bytes = 256
  ; maximum_records = 1000
  ; maximum_bytes = 8 * 1024 * 1024
  }
;;

let test_admission_rows_are_compact_and_complete () =
  check_pairs
    "admission rows"
    [ "Outbox records", "3 / 1000"
    ; "Outbox bytes", "1.5 KB / 8 MB"
    ; "Protected payload", "512 B"
    ; "Origin evidence", "256 B"
    ]
    (Application.admission_rows
       (Application.Admission_refresh.Available admission_inspection));
  Alcotest.(check int)
    "unavailable row count"
    4
    (List.length (Application.admission_rows Application.Admission_refresh.Unavailable))
;;

let test_byte_formatting () =
  List.iter
    (fun (bytes, expected) ->
       Alcotest.(check string) expected expected (Application.format_bytes bytes))
    [ 0, "0 B"; 1, "1 B"; 1536, "1.5 KB"; 8 * 1024 * 1024, "8 MB" ]
;;

let test_admission_refresh_coalesces_and_fences_generations () =
  let open Application.Admission_refresh in
  let request graph_generation request_generation
    : Journal_graph_request.admission_request
    =
    { graph_generation; request_generation }
  in
  let state, directive = open_ closed ~graph_generation:4 ~graph_open:true in
  Alcotest.(check bool)
    "open requests inspection"
    true
    (directive = Request (request 4 1L));
  let state, directive = trigger state ~graph_generation:4 ~graph_open:true in
  Alcotest.(check bool) "in-flight trigger coalesces" true (directive = No_request);
  let state, directive =
    complete state ~request:(request 4 1L) ~result:(Inspected admission_inspection)
  in
  Alcotest.(check bool) "one follow-up requested" true (directive = Request (request 4 2L));
  let state, directive =
    complete state ~request:(request 4 2L) ~result:(Inspected admission_inspection)
  in
  Alcotest.(check bool) "follow-up completes idle" true (directive = No_request);
  let state, directive = trigger state ~graph_generation:5 ~graph_open:true in
  Alcotest.(check bool)
    "new generation requests inspection"
    true
    (directive = Request (request 5 3L));
  let state, directive =
    complete state ~request:(request 4 2L) ~result:(Inspected admission_inspection)
  in
  Alcotest.(check bool) "stale generation ignored" true (directive = No_request);
  Alcotest.(check bool) "new generation remains loading" true (observation state = Loading);
  let state = close state in
  let state, directive =
    complete state ~request:(request 5 3L) ~result:(Inspected admission_inspection)
  in
  Alcotest.(check bool) "closed view ignores completion" true (directive = No_request);
  Alcotest.(check bool) "closed view unavailable" true (observation state = Unavailable)
;;

let test_block_identity_admission_boundary () =
  let time instant_unix_ms =
    Journal_time.create ~instant_unix_ms ~local_day:20260907 ~local_minute_of_day:0
    |> Result.get_ok
  in
  let creation_time = time 1_800_000_000_000L in
  let entropy () = Bytes.make 16 '\000' in
  let draft = Journal_capture.create ~session_number:99L ~source:"Keep this draft" in
  let admit block_id =
    Journal_capture.admit_save
      draft
      ~block_id:(Logseq_db_types.Graph_types.Uuid.to_string block_id)
      ~mutation_id:"70000000-0000-4000-9000-000000000099"
      ~calendar_generation:1L
      ~sibling_order:"000000000099"
      ~creation_time
  in
  let first =
    Application.For_testing.with_block_identity ~entropy ~creation_time ~f:Fun.id ()
    |> Result.get_ok
  in
  List.iter
    (fun (entropy, creation_time) ->
       let admissions = ref 0 in
       let result =
         Application.For_testing.with_block_identity
           ~entropy
           ~creation_time
           ~f:(fun id ->
             incr admissions;
             admit id)
           ()
       in
       Alcotest.(check int) "allocation failure publishes no admission" 0 !admissions;
       (match result with
        | Ok _ -> Alcotest.fail "invalid allocation succeeded"
        | Error message ->
          Alcotest.(check bool) "actionable save error" true (String.length message > 20));
       Alcotest.(check string)
         "failed allocation retains draft"
         "Keep this draft"
         (Journal_capture.source draft);
       Alcotest.(check bool)
         "failed allocation remains editable"
         true
         (Journal_capture.can_save draft))
    [ ( (fun () -> raise (Unix.Unix_error (Unix.EACCES, "open", "/dev/urandom")))
      , creation_time )
    ; (fun () -> Bytes.empty), creation_time
    ; entropy, time (-1L)
    ; entropy, time 0x1000000000000L
    ];
  let _, request =
    Application.For_testing.with_block_identity ~entropy ~creation_time ~f:admit ()
    |> Result.get_ok
  in
  match request with
  | Some (Journal_graph_request.Capture { command; _ }) ->
    let text = Logseq_db_types.Graph_types.Uuid.to_string first in
    Alcotest.(check string)
      "failures did not advance shared generator"
      (String.sub text 0 35 ^ "1")
      command.block_id;
    Alcotest.(check bool)
      "sampled creation time retained"
      true
      (Journal_time.equal creation_time command.creation_time)
  | _ -> Alcotest.fail "allocation retry did not admit a capture"
;;

let test_block_identity_serialization_and_native_entropy () =
  let random = Application.For_testing.read_block_entropy () in
  Alcotest.(check int) "OS entropy length" 16 (Bytes.length random);
  let creation_time =
    Journal_time.create
      ~instant_unix_ms:1_800_000_000_001L
      ~local_day:20260907
      ~local_minute_of_day:0
    |> Result.get_ok
  in
  let results = Array.make 64 None in
  let threads =
    Array.init 64 (fun i ->
      Thread.create
        (fun () ->
           results.(i)
           <- Some
                (Application.For_testing.with_block_identity ~creation_time ~f:Fun.id ()))
        ())
  in
  Array.iter Thread.join threads;
  let ids =
    Array.to_list results |> List.map (fun result -> Option.get result |> Result.get_ok)
  in
  let unique = List.sort_uniq Logseq_db_types.Graph_types.Uuid.compare ids in
  Alcotest.(check int)
    "serialized process owner allocates unique IDs"
    64
    (List.length unique)
;;

let () =
  Alcotest.run
    "application view"
    [ ( "block identity adapter"
      , [ Alcotest.test_case
            "failure retains admission and state"
            `Quick
            test_block_identity_admission_boundary
        ; Alcotest.test_case
            "serialization and native entropy"
            `Quick
            test_block_identity_serialization_and_native_entropy
        ] )
    ; ( "worker presentation"
      , [ Alcotest.test_case "phase labels" `Quick test_phase_names
        ; Alcotest.test_case
            "retired diagnostics are hidden"
            `Quick
            test_diagnostics_hide_retired_phase_rows
        ; Alcotest.test_case
            "graph lifecycle survives missing snapshot"
            `Quick
            test_missing_snapshot_keeps_graph_lifecycle_visible
        ; Alcotest.test_case
            "admission rows are compact"
            `Quick
            test_admission_rows_are_compact_and_complete
        ; Alcotest.test_case "byte formatting" `Quick test_byte_formatting
        ; Alcotest.test_case
            "admission refresh coalesces and fences"
            `Quick
            test_admission_refresh_coalesces_and_fences_generations
        ] )
    ]
;;
