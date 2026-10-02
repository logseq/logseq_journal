module Service = Logseq_db_worker_lui.Logseq_db_worker_lui_service

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

let test_root_navigation_capture_lifecycle () =
  let module R = Application.Root_navigation in
  let initial = R.create ~graph_generation:3 in
  Alcotest.(check bool)
    "Journals on launch"
    true
    (R.destination initial = Journal_routes.Journals);
  let drafted = R.step initial (Capture_edited "Retained journal draft") in
  let favorite = R.step drafted (Select Journal_routes.Favorites) in
  Alcotest.(check string)
    "draft survives selection"
    "Retained journal draft"
    (Journal_capture.source (Option.get (R.capture favorite)));
  let returned = R.step favorite (Select Journals) in
  let capture = Option.get (R.capture returned) in
  let creation_time =
    Journal_time.create
      ~instant_unix_ms:1_788_825_600_000L
      ~local_day:20260908
      ~local_minute_of_day:0
    |> Result.get_ok
  in
  let capture, request =
    Journal_capture.admit_save
      capture
      ~mutation_id:"76000000-0000-4000-8000-000000000001"
      ~block_id:"76000000-0000-4000-8000-000000000002"
      ~sibling_order:"a0"
      ~calendar_generation:1L
      ~creation_time
  in
  Alcotest.(check bool) "real save admitted" true (Option.is_some request);
  let saving =
    R.step returned (Capture_admitted capture)
    |> fun state -> R.step state (Select Favorites)
  in
  Alcotest.(check bool)
    "tab retains saving owner"
    true
    (Journal_capture.phase (Option.get (R.capture saving)) = Journal_capture.Saving);
  let block =
    Journal_model.create
      ~id:"76000000-0000-4000-8000-000000000002"
      ~page_id:"76000000-0000-4000-8000-000000000003"
      ~journal_day:20260908
      ~parent_id:None
      ~sibling_order:"a0"
      ~source:"Retained journal draft"
      ~task_state:Journal_model.No_status
      ~child_count:0
      ~creation_time
      ~revision:"saved"
      ~last_mutation_id:"76000000-0000-4000-8000-000000000001"
    |> Result.get_ok
  in
  let completed =
    R.step
      saving
      (Completed { payload = Block_captured { block; timeline_entry_update = None } })
  in
  Alcotest.(check bool)
    "save completion retains selected tab"
    true
    (R.destination completed = Favorites);
  Alcotest.(check bool) "save completes in Journals" true (R.capture completed = None);
  let replaced = R.step drafted (Graph_replaced { generation = 4; graph_id = None }) in
  Alcotest.(check bool)
    "replacement resets tab and draft"
    true
    (R.destination replaced = Journals
     && R.capture replaced = None
     && Journal_routes.Favorites.items (R.favorites replaced) = [])
;;

let test_favorites_native_visibility_retires_media () =
  let module W = Logseq_db_worker_lui.Journal_worker in
  let module P = Logseq_db_worker.Protocol in
  let module G = Logseq_db_types.Graph_types in
  let uuid n =
    G.Uuid.of_string (Printf.sprintf "82000000-0000-4000-8000-%012d" n) |> Result.get_ok
  in
  let roots = List.init 65 (fun n -> uuid (n + 1)) in
  let queried = Atomic.make [] in
  let feed_queried = Atomic.make false in
  let items =
    List.mapi
      (fun n root ->
         { P.membership_uuid = uuid (1000 + n)
         ; membership_order = Printf.sprintf "%03d" n
         ; membership_revision = "membership-1"
         ; target =
             (if n mod 2 = 0
              then
                P.V2_favorite_page
                  { uuid = root
                  ; title = Printf.sprintf "Fixture %d" n
                  ; revision = "page-1"
                  }
              else
                P.V2_favorite_block
                  { uuid = root
                  ; title = Printf.sprintf "Fixture %d" n
                  ; task_status = None
                  ; revision = "block-1"
                  })
         })
      roots
  in
  let manager : Service.state =
    { snapshot =
        { sync_phase = Current
        ; catalog = []
        ; selected_graph = Some (uuid 900)
        ; applied_server_t = Some 0
        ; timeline_presentation_pending = false
        ; startup =
            { authenticated = true
            ; catalog_loading = false
            ; awaiting_selection = false
            ; restoring_local = false
            ; bootstrapping = false
            ; awaiting_e2ee_password = false
            ; failure = None
            ; account_generation = 1
            ; graph_generation = 1
            ; presentation_generation = 1
            }
        ; last_error = None
        ; local_deletion = None
        }
    ; diagnostics = { groups = [] }
    }
  in
  let service =
    W.Service.create
      ~push_topic_count:6
      ~concurrency:Serial
      ~init:(fun context _ ->
        W.Session_context.emit
          context
          ~topic:Service.manager_topic
          (Service.Client_state_changed manager);
        Ok ())
      ~handle:(fun _ () request ->
        match request with
        | Service.Get_graph_state ->
          Ok
            (Service.Graph_state
               { generation = 1
               ; graph_id = Some (uuid 900)
               ; phase = Graph_open
               ; error = None
               })
        | Client_command _ | Asset_command _ | Release_asset_file _ ->
          Ok Service.Client_command_completed
        | Acquire_asset_file _ | Acquire_imported_file _ -> Ok (Service.Asset_file None)
        | Import_asset _ -> Error "unexpected import"
        | Graph_request request ->
          let outcome =
            match request.command with
            | P.V2_graph_info ->
              P.V2_graph_info_outcome
                { graph_uuid = uuid 900
                ; graph_name = "Fixture"
                ; schema = { major = 65; minor = 33 }
                ; admission_facts = []
                ; journal_title_format = None
                ; limits =
                    { response_budget_bytes = P.maximum_response_bytes
                    ; outbox_max_records = 4096
                    ; outbox_max_bytes = 8388608
                    ; change_max_items = 4096
                    ; change_max_bytes = 1048576
                    ; dispatcher_capacity = 256
                    ; wire_batch_max_bytes = 262144
                    }
                ; generation = "g"
                ; projection_revision = "p"
                }
            | V2_list_journals _ ->
              Atomic.set feed_queried true;
              V2_journals_outcome { items = []; next_cursor = None }
            | V2_list_favorites _ ->
              V2_favorites_outcome
                { favorites_page = None
                ; generation = "g"
                ; projection_revision = "p"
                ; items
                ; next_cursor = None
                }
            | V2_list_assets { roots; _ } ->
              Atomic.set queried (List.rev_append roots (Atomic.get queried));
              V2_assets_outcome
                { generation = "g"
                ; projection_revision = "p"
                ; items = []
                ; next_cursor = None
                }
            | _ -> V2_failed { code = "unsupported"; message = "Unused fixture command" }
          in
          Ok
            (Service.Graph_response
               (P.V2_response
                  { api_version = 2; request_id = request.request_id; outcome })))
      ~shutdown:(fun () -> ())
      ()
  in
  let hooks = Application.For_testing.app_with_service service in
  let props = Hashtbl.create 512
  and parents = Hashtbl.create 512 in
  let consume encoded =
    if encoded <> ""
    then
      let open Yojson.Safe.Util in
      Yojson.Safe.from_string encoded
      |> member "ops"
      |> to_list
      |> List.iter (fun op ->
        match op |> member "op" |> to_string with
        | "create-extension" ->
          Hashtbl.replace
            props
            (op |> member "id" |> to_int)
            [ "_extension", member "identifier" op ]
        | "set-prop" ->
          let id = op |> member "id" |> to_int in
          let previous = Option.value (Hashtbl.find_opt props id) ~default:[] in
          let key = op |> member "property" |> to_string in
          Hashtbl.replace
            props
            id
            ((key, member "value" op) :: List.remove_assoc key previous)
        | "drop-node" ->
          let id = op |> member "id" |> to_int in
          Hashtbl.remove props id;
          Hashtbl.remove parents id
        | "insert-child" | "move-child" ->
          Hashtbl.replace
            parents
            (op |> member "child" |> to_int)
            (op |> member "parent" |> to_int)
        | _ -> ())
  in
  let find key value =
    Hashtbl.fold
      (fun id values found ->
         if List.assoc_opt key values = Some (`String value) then Some id else found)
      props
      None
  in
  let rec ancestor_property id key =
    if
      List.assoc_opt key (Option.value (Hashtbl.find_opt props id) ~default:[])
      = Some (`Bool true)
    then id
    else (
      match Hashtbl.find_opt parents id with
      | Some parent -> ancestor_property parent key
      | None -> failwith ("fixture node has no " ^ key ^ " ancestor"))
  in
  let dispatch event = hooks.dispatch event |> consume in
  let wait label predicate =
    let deadline = Unix.gettimeofday () +. 5. in
    while (not (predicate ())) && Unix.gettimeofday () < deadline do
      hooks.pump () |> consume;
      Unix.sleepf 0.001
    done;
    Alcotest.(check bool) label true (predicate ())
  in
  let startup =
    Logseq_db_worker.Config.create
      ~application_support_directory:"/tmp/journal-favorites-synthetic"
      ~target:(Managed_sync { base_url = "https://example.invalid" })
      ~compatibility_profile:Logseq_65_33_or_newer
      ~response_budget_bytes:P.maximum_response_bytes
      ~default_page_size:P.default_page_size
    |> Result.get_ok
    |> Journal_startup.encode
    |> Result.get_ok
    |> Bytes.to_string
  in
  Fun.protect
    ~finally:(fun () -> ignore (hooks.dispose ()))
    (fun () ->
       hooks.init 2 2 startup |> consume;
       wait "initial feed read" (fun () -> Atomic.get feed_queried);
       for _ = 1 to 3 do
         hooks.pump () |> consume;
         Unix.sleepf 0.001
       done;
       wait "Journals mounted" (fun () ->
         Option.is_some (find "accessibility-label" "Favorites"));
       let favorites = Option.get (find "accessibility-label" "Favorites") in
       dispatch (Lui_protocol.Press favorites);
       wait "Favorites loaded" (fun () -> Option.is_some (find "text" "Fixture 64"));
       let show n =
         let text = Option.get (find "text" (Printf.sprintf "Fixture %d" n)) in
         dispatch (Lui_protocol.Appear (ancestor_property text "appear-enabled"))
       in
       for n = 0 to 63 do
         show n;
         wait (Printf.sprintf "root %d query completed" n) (fun () ->
           List.mem (List.nth roots n) (Atomic.get queried));
         (* Drain the response as well, so the next root is not query-concurrency limited. *)
         for _ = 1 to 3 do
           hooks.pump () |> consume;
           Unix.sleepf 0.001
         done
       done;
       let list_node = Option.get (find "_extension" "journal-list") in
       (* The native list extension callback converts Visible_range to Int64_pair. *)
       hooks.extension_event
         list_node
         "event"
         (Yojson.Safe.to_string
            (`Assoc
                [ "id", `Int 1
                ; "payload", `String {|{"type":"visible_range","first":64,"last":65}|}
                ]))
       |> consume;
       show 64;
       wait "65th root admitted after real Favorites Int64_pair event" (fun () ->
         List.mem (List.nth roots 64) (Atomic.get queried));
       let list_node = Option.get (find "_extension" "journal-list") in
       hooks.extension_event
         list_node
         "event"
         (Yojson.Safe.to_string
            (`Assoc
                [ "id", `Int 1
                ; "payload", `String {|{"type":"visible_range","first":64,"last":65}|}
                ]))
       |> consume;
       show 64;
       for _ = 1 to 3 do
         hooks.pump () |> consume;
         Unix.sleepf 0.001
       done;
       Alcotest.(check int)
         "same visible page root does not refetch"
         1
         (List.length
            (List.filter (G.Uuid.equal (List.nth roots 64)) (Atomic.get queried))))
;;

let () =
  Alcotest.run
    "application view"
    [ ( "root navigation"
      , [ Alcotest.test_case
            "native Favorites media visibility"
            `Quick
            test_favorites_native_visibility_retires_media
        ; Alcotest.test_case
            "draft, save, and graph lifetime"
            `Quick
            test_root_navigation_capture_lifecycle
        ] )
    ; ( "block identity adapter"
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
