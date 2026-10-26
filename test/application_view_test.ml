let server_cursor_of_int value =
  Logseq_db_types.Server_cursor.of_int64 (Int64.of_int value) |> Result.get_ok
;;

module Service = Logseq_db_worker_lui.Logseq_db_worker_lui_service
module Wire_nodes = Set.Make (Int)

let track_wire_teardown ?(parents = Hashtbl.create 64) on_drop =
  let children = Hashtbl.create 64 in
  let children_of node =
    Option.value (Hashtbl.find_opt children node) ~default:Wire_nodes.empty
  in
  let unlink node =
    match Hashtbl.find_opt parents node with
    | None -> ()
    | Some parent ->
      Hashtbl.replace children parent (Wire_nodes.remove node (children_of parent));
      Hashtbl.remove parents node
  in
  let drop node =
    unlink node;
    Wire_nodes.iter (Hashtbl.remove parents) (children_of node);
    Hashtbl.remove children node;
    on_drop node
  in
  let rec detach node =
    Wire_nodes.iter detach (children_of node);
    drop node
  in
  function
  | Lui_protocol.InsertChild (parent, child, _) | MoveChild (parent, child, _) ->
    unlink child;
    Hashtbl.replace parents child parent;
    Hashtbl.replace children parent (Wire_nodes.add child (children_of parent))
  | RemoveChild (parent, child) ->
    if Hashtbl.find_opt parents child = Some parent then unlink child
  | DropNode node -> drop node
  | DetachSubtree node -> detach node
  | _ -> ()
;;

let track_json_wire_teardown ?parents on_drop =
  let track = track_wire_teardown ?parents on_drop in
  fun op ->
    let open Yojson.Safe.Util in
    let id () = member "id" op |> to_int in
    let parent () = member "parent" op |> to_int in
    let child () = member "child" op |> to_int in
    match member "op" op |> to_string with
    | "drop-node" | "drop-extension" -> track (Lui_protocol.DropNode (id ()))
    | "detach-subtree" -> track (Lui_protocol.DetachSubtree (id ()))
    | "insert-child" ->
      track (Lui_protocol.InsertChild (parent (), child (), member "index" op |> to_int))
    | "move-child" ->
      track (Lui_protocol.MoveChild (parent (), child (), member "index" op |> to_int))
    | "remove-child" -> track (Lui_protocol.RemoveChild (parent (), child ()))
    | _ -> ()
;;

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

let test_current_diagnostic_rows () =
  let diagnostics : Service.diagnostics =
    { groups =
        [ { title = "Manager"; entries = [ "Last error", "None" ] }
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
    ; "Worker graph UUID", "Not available"
    ; "Worker graph generation", "4"
    ]
    (Application.diagnostic_phase_rows ~snapshot:None ~graph)
;;

let test_diagnostic_phase_rows_retain_current_error () =
  let message = "Graph schema 65.29 is not supported. Journal requires schema 65.33 or later." in
  let snapshot : Service.snapshot =
    { sync_phase = Failed; catalog = []; selected_graph = None; applied_server_t = None
    ; unlock = Logseq_sync_pure_reducer.Core.Unlock_inactive
        ; timeline_presentation_pending = false; local_deletion = None; last_error_attention = None; last_error = Some message
    ; startup = { authenticated = true; local_access=Service.Local_available; network_phase=Service.Online_by_user; catalog_loading = false; awaiting_selection = false
        ; restoring_local = false; bootstrapping = true; awaiting_e2ee_password = false
        ; failure = Some During_bootstrap; account_generation = 1; graph_generation = 1
        ; presentation_generation = 1 } } in
  let graph : Logseq_db_worker.graph_state =
    { generation = 1; graph_id = None; phase = Graph_closed; error = None } in
  let rows = Application.diagnostic_phase_rows ~snapshot:(Some snapshot) ~graph in
  Alcotest.(check (option string)) "current error visible without diagnostic groups"
    (Some message) (List.assoc_opt "Last error" rows);
  let cleared = Application.diagnostic_phase_rows
      ~snapshot:(Some {snapshot with last_error = None}) ~graph in
  Alcotest.(check bool) "retry does not retain obsolete error" false
    (List.mem_assoc "Last error" cleared)
;;

let test_diagnostic_identity_comes_from_worker () =
  let uuid value = Logseq_db_types.Graph_types.Uuid.of_string value |> Result.get_ok in
  let selected = uuid "60000000-0000-4000-8000-000000000001" in
  let actual = uuid "60000000-0000-4000-8000-000000000002" in
  let snapshot : Service.snapshot =
    { sync_phase = Offline; catalog = []; selected_graph = Some selected
    ; applied_server_t = None; unlock = Logseq_sync_pure_reducer.Core.Unlock_inactive
        ; timeline_presentation_pending = false
    ; local_deletion = None; last_error_attention = None; last_error = None
    ; startup = { authenticated = true; catalog_loading = false
        ; awaiting_selection = false; restoring_local = false; bootstrapping = false
        ; awaiting_e2ee_password = false; failure = None; account_generation = 1
        ; graph_generation = 7; presentation_generation = 1
        ; local_access = Local_available; network_phase = Online_after_timeline } }
  in
  let graph : Logseq_db_worker.graph_state =
    { generation = 7; graph_id = Some actual; phase = Graph_open; error = None }
  in
  let rows = Application.diagnostic_phase_rows ~snapshot:(Some snapshot) ~graph in
  Alcotest.(check (option string)) "worker identity, not selected graph"
    (Some "60000000-0000-4000-8000-000000000002")
    (List.assoc_opt "Worker graph UUID" rows);
  Alcotest.(check (option string)) "worker generation" (Some "7")
    (List.assoc_opt "Worker graph generation" rows);
  Alcotest.(check bool) "different worker cannot appear ready" false
    (List.assoc_opt "Startup phase" rows = Some "Ready");
  let ready = Application.diagnostic_phase_rows
      ~snapshot:(Some { snapshot with selected_graph = Some actual }) ~graph in
  Alcotest.(check (option string)) "matching worker is ready" (Some "Ready")
    (List.assoc_opt "Startup phase" ready);
  let closed = Application.diagnostic_phase_rows ~snapshot:(Some snapshot)
      ~graph:{graph with graph_id = None; phase = Graph_closed} in
  Alcotest.(check (option string)) "no selected-graph fallback when worker closed"
    (Some "Not available") (List.assoc_opt "Worker graph UUID" closed)
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
       (Journal_admission_refresh.Available admission_inspection));
  Alcotest.(check int)
    "unavailable row count"
    4
    (List.length (Application.admission_rows Journal_admission_refresh.Unavailable))
;;

let test_byte_formatting () =
  List.iter
    (fun (bytes, expected) ->
       Alcotest.(check string) expected expected (Application.format_bytes bytes))
    [ 0, "0 B"; 1, "1 B"; 1536, "1.5 KB"; 8 * 1024 * 1024, "8 MB" ]
;;

let test_admission_refresh_coalesces_and_fences_generations () =
  let open Journal_admission_refresh in
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

(* Fixture teardown is outside pure reducer ownership: dispose requests an
   asynchronous stop on the process-wide Worker Domain. Check its public
   lifecycle before another fixture can attach. *)
let check_fixture_worker_idle () =
  let module Runtime = Logseq_db_worker_lui.Journal_worker_runtime in
  let diagnostics = Runtime.For_testing.diagnostics () in
  Alcotest.(check bool)
    "fixture releases Worker Domain to Idle"
    true
    (diagnostics.state = Runtime.Idle);
  Alcotest.(check int)
    "fixture leaves no active Worker session"
    0
    diagnostics.active_sessions
;;

let run_favorites_native_visibility
      ?(check_visible = false)
      ?(check_hidden = false)
      ?(check_draft = false)
      ?(check_detail = false)
      ?(check_detail_discovery = false)
      ?(check_detail_wait = false)
      ?(check_copy = false)
      ?(check_navigation = false)
      ?(check_favorite_targets = false)
      ?(check_detail_row_action = false)
      ?(check_covered_update = false)
      ?calendar_change
      ?(timeline_rows = 3)
      ?(check_generation = false)
      ?(check_reselect = false)
      ?(check_chrome = false)
      ?(check_error_control = false)
      ?malformed_native_event
      ?(check_ios_capture = false)
      ?(check_capture_imports = false)
      ?detail_capture
      ?status_scenario
      ?delete_scenario
      ?(on_initialized = fun () -> ())
      ?media_rows
      ?(shared_media = false)
      ?media_navigation
      ()
  =
  let module W = Logseq_db_worker_lui.Journal_worker in
  let module P = Logseq_db_worker.Protocol in
  let module G = Logseq_db_types.Graph_types in
  let uuid n =
    G.Uuid.of_string (Printf.sprintf "82000000-0000-4000-8000-%012d" n) |> Result.get_ok
  in
  let roots = List.init 65 (fun n -> uuid (n + 1)) in
  let status_value = Atomic.make (match status_scenario with
    | Some "none" -> None
       | Some (("now" | "waiting" | "later") as value) -> Some value
    | Some _ -> Some "doing"
    | None -> None) in
  let delete_writes = Atomic.make 0 in
  let delete_release = Atomic.make false in
  let delete_notices = ref 0 in
  let status_writes = Atomic.make [] in
  let status_revision () = if Atomic.get status_writes = [] then "root" else "status-updated" in
  let status_release = Atomic.make (status_scenario <> Some "duplicate") in
  let graph_generation = Atomic.make 1 in
  let client = ref None in
  let worker_context = ref None in
  let shutdown_called = Atomic.make false in
  let publish_phase = Atomic.make None in
  let publish_error = Atomic.make None in
  let publish_attention = Atomic.make None in
  let publish_graph_first = Atomic.make false in
  let reported_graph_generation = Atomic.make None in
  let queried = Atomic.make [] in
  let feed_queried = Atomic.make false in
  let calendar_feed_reads = Atomic.make 0 in
  let calendar_feed_release = Atomic.make false in
  let calendar_refresh_pending = Atomic.make false in
  let calendar_seconds = ref (1_788_220_800. +. if calendar_change = Some `Zone then 82_800. else 0.) in
  let calendar_offset = ref 0. in
  let calendar_sampler = Option.map (fun _ -> Journal_calendar.Sampler.create
      ~clock:(fun () -> !calendar_seconds)
      ~localtime:(fun instant -> Unix.gmtime (instant +. !calendar_offset)) ()) calendar_change in
  let publish_block = Atomic.make false in
  let updated_block = Atomic.make false in
  let media_notices = Atomic.make [] in
  let media_delivered = Atomic.make 0 in
  let demands = Atomic.make [] in
  let retries = Atomic.make 0 in
  let acquire_entered = Atomic.make 0 in
  let acquire_release = Atomic.make false in
  let released_files = Atomic.make 0 in
  let media_checksum = Atomic.make 'a' in
  let media_metadata_changed = Atomic.make false in
  let detail_fixture = Atomic.make false in
  let detail_initial_limit = Atomic.make None in
  let discovery_reads = Atomic.make [] in
  let detail_wait_release = Atomic.make false in
  let released_demands = Atomic.make 0 in
  let capture_root : P.v2_block_tree option Atomic.t = Atomic.make None in
  let capture_page : G.page option Atomic.t = Atomic.make None in
  let imports_entered = Atomic.make [] in
  let imports_finished = Atomic.make 0 in
  let import_release = Atomic.make false in
  let import_probe = Atomic.make false in
  let import_probed = Atomic.make false in
  let staged_paths = ref [] in
  let durable_paths = Atomic.make [] in
  let detail_captures = Atomic.make [] in
  let child_attempts = Atomic.make 0 in
  let child_release =
    Atomic.make
      (not (List.mem detail_capture [ Some "duplicate"; Some "offscreen-attachments" ]))
  in
  let import_targets = Atomic.make [] in
  let scope : Service.asset_scope =
    { account =
        { managed_sync_origin = Uri.of_string "https://example.invalid"
        ; user_id = "fixture"
        ; account_generation = 1
        ; presentation_generation = 1
        ; lifecycle_generation = 1L
        }
    ; graph_id = uuid 900
    ; graph_generation = 1
    }
  in
  let page : G.page =
    { uuid = uuid 10000
    ; name = "20260901"
    ; title = "Sep 1st, 2026"
    ; kind = Journal_page { journal_day = 20260901 }
    ; created_at_ms = 1_788_192_000_000L
    ; updated_at_ms = 1_788_192_000_000L
    ; recycled = false
    ; tags = []
    ; properties = []
    }
  in
  let status_definitions =
    List.mapi
      (fun n (slug, id, title) ->
         ( slug
         , ({ G.uuid = G.Uuid.of_string id |> Result.get_ok
            ; title
            ; ident = None
            ; order = Printf.sprintf "%03d" n
            ; checkbox_state = None
            }
            : G.task_status_definition) ))
      [ "backlog", "00000002-7233-3491-0000-000000000000", "Backlog"
      ; "todo", "00000002-1615-5853-7700-000000000000", "Todo"
      ; "doing", "00000002-1840-1229-0800-000000000000", "Doing"
      ; "in-review", "00000002-1870-0014-4300-000000000000", "In Review"
      ; "done", "00000002-1827-5820-8200-000000000000", "Done"
      ; "canceled", "00000002-7526-4326-2000-000000000000", "Canceled"
      ; "now", "b1000000-0000-4000-8000-000000000091", "Now"
      ; "waiting", "b1000000-0000-4000-8000-000000000092", "Waiting"
      ; "later", "b1000000-0000-4000-8000-000000000093", "Later"
      ]
  in
  let status_definitions =
    status_definitions
    @ List.init 120 (fun n ->
      let id = Printf.sprintf "b1000000-0000-4000-8000-%012d" (1000 + n) in
      ( id
      , ({ G.uuid = G.Uuid.of_string id |> Result.get_ok
         ; title = (if n < 2 then "Custom 状态" else Printf.sprintf "Custom 状态 %d" n)
         ; ident = None
         ; order = Printf.sprintf "z%04d" n
         ; checkbox_state = None
         }
         : G.task_status_definition) ))
  in
  let status_uuid slug =
    match List.assoc_opt slug status_definitions with
    | Some definition -> definition.G.uuid
    | None -> G.Uuid.of_string slug |> Result.get_ok
  in
  let timeline_block n : P.v2_block_record =
    { block =
        { uuid = List.nth roots n
        ; title =
            (if n = 1 && Atomic.get updated_block
             then "Updated covered row"
             else Printf.sprintf "Timeline fixture %d" n)
        ; parent = page.uuid
        ; page = page.uuid
        ; order = Printf.sprintf "%03d" n
        ; created_at_ms = 1_788_192_000_000L
        ; updated_at_ms = 1_788_192_000_000L
        ; refs = []
        ; tags = []
        ; properties = (match Atomic.get status_value with
            | None -> []
            | Some value ->
              [ { G.ident = "logseq.property/status"; uuid = uuid 90001; title = "Status"
                ; schema = { property_type = Default; cardinality = One; hidden = false; public = false }
                 ; values = [ Default_value (G.Uuid.to_string (status_uuid value)) ]
                ; values_truncated = false } ])
        }
    ; task_status = Option.map status_uuid (Atomic.get status_value)
    ; rendered_page_title = page.title
    ; tag_titles = []
    }
  in
  let favorites_page =
    { page with
      uuid = uuid 40000
    ; name = "$$$favorites"
    ; title = "Favorites"
    ; kind = Hidden_page
    }
  in
  let favorite_target_uuid n =
    if n mod 2 = 0 then uuid (30000 + n) else List.nth roots n
  in
  let favorite_page n =
    { page with
      uuid = favorite_target_uuid n
    ; name = Printf.sprintf "fixture-%d" n
    ; title = Printf.sprintf "Fixture %d" n
    ; kind = Ordinary_page
    }
  in
  let favorite_label n =
    if n mod 2 = 0 then (favorite_page n).title else (timeline_block n).block.title
  in
  let favorite_items () =
    List.init 65 (fun n ->
      { P.membership_uuid = uuid (1000 + n)
      ; membership_order = Printf.sprintf "%03d" n
      ; membership_revision = "membership-1"
      ; target =
          (if n mod 2 = 0
           then
             P.V2_favorite_page
               { uuid = favorite_target_uuid n
               ; title = favorite_label n
               ; revision = "page-1"
               }
           else
             P.V2_favorite_block
               { uuid = favorite_target_uuid n
               ; title = favorite_label n
               ; task_status = None
               ; revision = status_revision ()
               })
      })
  in
  let favorite_membership n =
    let value = timeline_block n in
    { P.value =
        { value with
          block =
            { value.block with
              uuid = uuid (1000 + n)
            ; title = ""
            ; parent = favorites_page.uuid
            ; page = favorites_page.uuid
            ; refs = []
            ; properties = []
            }
        ; rendered_page_title = favorites_page.title
        }
    ; revision = "membership-1"
    }
  in
  let changes_acknowledged = Atomic.make false in
  let manager : Service.state =
    { snapshot =
        { sync_phase = Current
        ; catalog = []
        ; selected_graph = Some (uuid 900)
        ; applied_server_t = Some (server_cursor_of_int 0)
        ; unlock = Logseq_sync_pure_reducer.Core.Unlock_inactive
        ; timeline_presentation_pending = false
        ; startup =
            { authenticated = true; local_access=Service.Local_available; network_phase=Service.Online_by_user
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
        ; last_error_attention = None; last_error = None
        ; local_deletion = None
        }
    ; diagnostics = { groups = [] }
    }
  in
  let latest_error_manager = Atomic.make manager in
  let service =
    W.Service.create
      ~push_topic_count:6
      ~merge_push:Service.coalesce_push
      ~concurrency:
        (if check_capture_imports || Option.is_some detail_capture
         then Concurrent { max_in_flight = 2 }
         else Serial)
      ~init:(fun context _ ->
        worker_context := Some context;
        W.Session_context.emit
          context
          ~topic:Service.manager_topic
          (Service.Client_state_changed manager);
        Ok ())
      ~handle:(fun context () request ->
        match request with
        | Service.Inspect_local_copy _ | Service.Delete_local_copy _ -> Error "Unused fixture local-copy query"
        | Service.Get_graph_state ->
          if Atomic.get import_probe then Atomic.set import_probed true;
          if Atomic.exchange publish_block false
          then (
            Atomic.set updated_block true;
            W.Request_context.emit
              context
              ~topic:Service.invalidation_topic
              (Service.Graph_push
                 (P.V2_changes_available
                    { api_version = 2; generation = "g"; through = "p2" })));
          List.iter
            (fun notice ->
               Atomic.incr media_delivered;
               W.Request_context.emit
                 context
                 ~topic:Service.asset_topic
                 (Service.Asset_notice (scope, notice)))
            (Atomic.exchange media_notices []);
          let sync_phase = Atomic.exchange publish_phase None in
          let error = Atomic.exchange publish_error None in
          let attention = Atomic.exchange publish_attention None in
          let manager = if check_error_control then Atomic.get latest_error_manager else manager in
          (* A current graph must carry the same manager generation. The
             startup owner deliberately rejects mixed old/new graph snapshots. *)
          if sync_phase <> None || error <> None
             || Atomic.get graph_generation <> manager.snapshot.startup.graph_generation
          then (
            if check_error_control && Atomic.exchange publish_graph_first false then
              W.Request_context.emit context ~topic:Service.graph_state_topic
                (Service.Graph_state_changed
                   { generation = Atomic.get graph_generation; graph_id = Some (uuid 900)
                   ; phase = Graph_open; error = None });
            let next =
                 { manager with
                   snapshot =
                     { manager.snapshot with
                       sync_phase = Option.value sync_phase ~default:Service.Current
                     ; last_error_attention = Option.value attention ~default:None
                     ; last_error = Option.value error ~default:None
                     ; startup = { manager.snapshot.startup with
                         graph_generation = Atomic.get graph_generation }
                     }
                 } in
            if check_error_control then Atomic.set latest_error_manager next;
            W.Request_context.emit
              context
              ~topic:Service.manager_topic
              (Service.Client_state_changed next));
          Ok
            (Service.Graph_state
               { generation = Option.value (Atomic.get reported_graph_generation)
                   ~default:(Atomic.get graph_generation)
               ; graph_id = Some (uuid 900)
               ; phase = Graph_open
               ; error = None
               })
        | Asset_command { command = Replace_asset_demand { consumer; assets; _ }; _ }
          when Option.is_some media_rows ->
          List.iter
            (fun asset ->
               Atomic.set
                 demands
                 ((consumer, asset.Logseq_db_types.Asset_descriptor.uuid)
                  :: Atomic.get demands))
            assets;
          Ok Service.Client_command_completed
        | Asset_command { command = Release_asset_demand _; _ } ->
          Atomic.incr released_demands;
          Ok Service.Client_command_completed
        | Asset_command { command = Retry_asset _; _ } when Option.is_some media_rows ->
          Atomic.incr retries;
          Ok Service.Client_command_completed
        | Acquire_asset_file _ when Option.is_some media_rows ->
          let lease = Atomic.fetch_and_add acquire_entered 1 + 1 in
          while not (Atomic.get acquire_release) do
            Eio.Time.Mono.sleep (W.Request_context.clock context) 0.001
          done;
          Ok
            (Service.Asset_file
               (Some (Printf.sprintf "fixture-lease-%d" lease, "/tmp/targeted-media.png")))
        | Release_asset_file _ ->
          Atomic.incr released_files;
          Ok Service.Client_command_completed
        | Client_command _ | Asset_command _ -> Ok Service.Client_command_completed
        | Acquire_asset_file _ | Acquire_imported_file _ -> Ok (Service.Asset_file None)
        | Import_asset { graph_generation; source }
          when check_capture_imports || Option.is_some detail_capture ->
          Atomic.set import_targets (Atomic.get import_targets @ [ source.target ]);
          Atomic.set imports_entered (Atomic.get imports_entered @ [ source.title ]);
          if source.title = "First attachment" then
            while not (Atomic.get import_release) do
              Eio.Time.Mono.sleep (W.Request_context.clock context) 0.001
            done;
          if source.title = "First attachment"
             && detail_capture <> Some "selection-error"
            && ((not
                   (List.mem
                      detail_capture
                      [ Some "retry-imports"; Some "interrupted-imports" ]))
                 || List.length (List.filter (( = ) "First attachment") (Atomic.get imports_entered)) = 1)
          then (
            while not (Atomic.get import_release) do
              Eio.Time.Mono.sleep (W.Request_context.clock context) 0.001
            done;
            Atomic.incr imports_finished;
            if List.mem detail_capture [Some "interrupted-imports"; Some "legacy-interrupted"]
            then Error "Fixture interrupted import"
            else Ok (Service.Asset_imported (Error "Fixture first attachment failed")))
          else
            let module A = Logseq_db_types.Asset_descriptor in
            let durable_path = source.source_file ^ ".durable" in
            let bytes = "synthetic local attachment" in
            Out_channel.with_open_bin durable_path (fun out -> output_string out bytes);
            Atomic.set durable_paths (durable_path :: Atomic.get durable_paths);
            let asset =
              A.create ~uuid:source.asset ~source:(Managed None)
                ~current_checksum:(Some (Logseq_sync_effect_runner.Asset_codec.checksum bytes))
                ~size:(Some (Int64.of_int (String.length bytes))) ~dimensions:None
              |> Result.get_ok
            in
            Atomic.incr imports_finished;
            Ok
              (Service.Asset_imported
                 (Ok
                    { operation = source.operation
                    ; graph_generation
                    ; scope
                    ; target = source.target
                    ; asset
                    ; file_type = source.file_type
                    ; preview = Some ("synthetic-capture-local-lease", durable_path)
                    }))
        | Import_asset _ -> Error "unexpected import"
        | Graph_request request ->
          let commit_status mutation_id block value =
            Alcotest.(check string) "status mutation keeps target UUID"
              (G.Uuid.to_string (uuid 1)) (G.Uuid.to_string block);
            Atomic.set status_writes (Atomic.get status_writes @ [ value ]);
            while not (Atomic.get status_release) do
              Eio.Time.Mono.sleep (W.Request_context.clock context) 0.001
            done;
            if status_scenario = Some "failure"
            then P.V2_failed { code = "invalid-request"; message = "Fixture status write failed" }
            else (
              Atomic.set status_value value;
              P.V2_mutation_committed { mutation_id; status = V2_applied; generation = "g"
                ; before_projection_revision = "p"; after_projection_revision = "p2" })
          in
          let outcome =
            match request.command with
            | P.V2_list_task_statuses _ ->
              P.V2_task_statuses_outcome
                { property_uuid = Some (uuid 90001)
                ; default_status = Some (status_uuid "todo")
                ; items = List.map snd status_definitions
                ; next_cursor = None
                }
            | V2_get_task_status_definitions { statuses } ->
              V2_task_status_definitions_outcome
                (List.map
                   (fun uuid ->
                      List.find_map
                        (fun (_, (d : G.task_status_definition)) ->
                           if G.Uuid.equal uuid d.uuid then Some d else None)
                        status_definitions)
                   statuses)
            | P.V2_delete_blocks { root; mutation_id; preconditions }
              when Option.is_some delete_scenario ->
              Alcotest.(check string) "delete keeps target UUID"
                (G.Uuid.to_string (uuid 1)) (G.Uuid.to_string root);
              Alcotest.(check (list (pair string string))) "delete preserves revision preconditions"
                [ G.Uuid.to_string root, "root" ]
                (List.map (fun (id, revision) -> G.Uuid.to_string id, revision) preconditions.blocks);
              Atomic.incr delete_writes;
              while not (Atomic.get delete_release) do
                Eio.Time.Mono.sleep (W.Request_context.clock context) 0.001
              done;
              if delete_scenario = Some "failure" then
                P.V2_failed { code = Logseq_db_worker.Error.code_string Invalid_request; message = "Fixture delete failed" }
              else P.V2_mutation_committed { mutation_id; status = V2_applied; generation = "g"
                ; before_projection_revision = "p"; after_projection_revision = "p2" }
            | V2_set_task_status { mutation_id; block; status; _ } when Option.is_some status_scenario ->
              let value =
                List.find_map
                  (fun (slug, (d : G.task_status_definition)) ->
                     if G.Uuid.equal status d.uuid then Some slug else None)
                  status_definitions
                |> Option.value ~default:(G.Uuid.to_string status)
              in
              commit_status mutation_id block (Some value)
            | V2_clear_task_status { mutation_id; block; _ } when Option.is_some status_scenario ->
              commit_status mutation_id block None
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
              let _ = Atomic.fetch_and_add calendar_feed_reads 1 in
              if Atomic.get calendar_refresh_pending then (
                while not (Atomic.get calendar_feed_release) do Unix.sleepf 0.001 done;
                V2_failed {code="FixtureCalendarRefresh"; message="Calendar refresh fixture failed"})
              else V2_journals_outcome
                { items = [ { page; journal_day = 20260901; revision = "p" } ]
                ; next_cursor = None
                }
            | V2_get_page_tree _ ->
              V2_page_tree_outcome
                { page = page.uuid
                ; maximum_depth = 1
                ; items =
                    List.init (Option.value media_rows ~default:timeline_rows) (fun n ->
                      { P.value = timeline_block n
                      ; revision = status_revision ()
                      ; depth = 0
                      ; parent = page.uuid
                      })
                ; next_cursor = None
                }
            | V2_pull_changes _ ->
              V2_changes
                { generation = "g"
                ; from_exclusive = Some "p"
                ; through = "p2"
                ; next = None
                ; windows =
                    [ { id = "covered-update"
                      ; predecessor = "p"
                      ; successor = "p2"
                      ; block_uuids =
                          (if Atomic.get media_metadata_changed
                           then [ uuid 20000 ]
                           else [ uuid 2 ])
                      ; page_uuids = []
                      ; structure_interests = []
                      }
                    ]
                }
            | V2_ack_changes _ ->
              Atomic.set changes_acknowledged true;
              V2_changes_acknowledged { generation = "g"; through = "p2" }
            | V2_get_outline_block { block; _ } ->
              V2_block_outcome
                (match
                   List.find_opt
                     (fun (parent, (root : P.v2_block_tree)) ->
                        let _ = parent in
                        G.Uuid.equal root.uuid block)
                     (Atomic.get detail_captures)
                 with
                 | Some (parent, root) ->
                   let value = timeline_block 0 in
                   V2_present_block
                     { value =
                         { value with
                           block =
                             { value.block with
                               uuid = root.uuid
                             ; title = root.title
                             ; parent
                             ; order = "999"
                             }
                         }
                     ; revision = "appended"
                     }
                 | None ->
                   (match List.find_index (G.Uuid.equal block) roots with
                    | Some n ->
                      V2_present_block { value = timeline_block n; revision = status_revision () }
                    | None -> V2_missing_block { uuid = block; revision = "p" }))
            | V2_get_outline_block_summary { block; _ } when Option.is_some status_scenario ->
              let n = List.find_index (G.Uuid.equal block) roots |> Option.get in
              V2_block_summary_outcome
                { lookup = V2_present_block { value = timeline_block n; revision = status_revision () }
                ; page = Some (V2_present_page { page; revision = "p" })
                ; items = []; next_cursor = None; scope_revision = "children"
                ; generation = "g"; projection_revision = "p2" }
            | V2_get_outline_block_summary { block; _ } when check_capture_imports ->
              let root = Atomic.get capture_root |> Option.get in
              let page = Atomic.get capture_page |> Option.get in
              Alcotest.(check string)
                "capture summary queries committed UUID"
                (G.Uuid.to_string root.uuid)
                (G.Uuid.to_string block);
              let value = timeline_block 0 in
              V2_block_summary_outcome
                { lookup =
                    V2_present_block
                      { value =
                          { value with
                            block =
                              { value.block with
                                uuid = root.uuid
                              ; title = root.title
                              ; parent = page.uuid
                              ; page = page.uuid
                              }
                          ; rendered_page_title = page.title
                          }
                      ; revision = "captured"
                      }
                ; page = Some (V2_present_page { page; revision = "p" })
                ; items = []
                ; next_cursor = None
                ; scope_revision = "children"
                ; generation = "g"
                ; projection_revision = "p2"
                }
            | V2_get_page { page = requested; _ } ->
              let known =
                if G.Uuid.equal requested page.uuid
                then Some page
                else if G.Uuid.equal requested favorites_page.uuid
                then Some favorites_page
                else
                  List.find_map
                    (fun n ->
                       if n mod 2 = 0 && G.Uuid.equal requested (favorite_target_uuid n)
                       then Some (favorite_page n)
                       else None)
                    (List.init 65 Fun.id)
              in
              let capture_day =
                if not check_capture_imports
                then None
                else (
                  try
                    Scanf.sscanf
                      (G.Uuid.to_string requested)
                      "00000001-%4d-%4d-0000-000000000000%!"
                      (fun year month_day ->
                         let month = month_day / 100
                         and day = month_day mod 100 in
                         let leap =
                           year mod 4 = 0 && (year mod 100 <> 0 || year mod 400 = 0)
                         in
                         let maximum_day =
                           match month with
                           | 2 -> if leap then 29 else 28
                           | 4 | 6 | 9 | 11 -> 30
                           | 1 | 3 | 5 | 7 | 8 | 10 | 12 -> 31
                           | _ -> 0
                         in
                         if
                           year > 0
                           && day >= 1
                           && day <= maximum_day
                           && G.Uuid.to_string requested
                              = Printf.sprintf
                                  "00000001-%04d-%04d-0000-000000000000"
                                  year
                                  month_day
                         then Some ((year * 10000) + month_day)
                         else None)
                  with
                  | Scanf.Scan_failure _ | End_of_file | Failure _ -> None)
              in
              let known =
                match known, capture_day with
                | Some _, _ -> known
                | None, Some journal_day ->
                  let name = Printf.sprintf "%08d" journal_day in
                  let captured =
                    { page with
                      uuid = requested
                    ; name
                    ; title = name
                    ; kind = Journal_page { journal_day }
                    }
                  in
                  Atomic.set capture_page (Some captured);
                  Some captured
                | None, None -> None
              in
              V2_page_outcome
                (match known with
                 | Some page -> V2_present_page { page; revision = "p" }
                 | None -> V2_missing_page { uuid = requested; revision = "p" })
            | V2_get_children { parent; _ } when Option.is_some detail_capture ->
              let existing =
                if G.Uuid.equal parent (uuid 1)
                then (
                  let value = timeline_block 1 in
                  [ { P.value = { value with block = { value.block with parent } }
                    ; revision = "child"
                    }
                  ])
                else []
              in
              V2_children_outcome
                { parent
                ; revision_scope = V2_children_revision parent
                ; scope_revision = "children"
                ; items =
                    existing
                    @ List.filter_map
                        (fun (owner, (root : P.v2_block_tree)) ->
                           if not (G.Uuid.equal owner parent)
                           then None
                           else (
                             let value = timeline_block 0 in
                             Some
                               { P.value =
                                   { value with
                                     block =
                                       { value.block with
                                         uuid = root.uuid
                                       ; title = root.title
                                       ; parent
                                       ; order = "999"
                                       }
                                   }
                               ; revision = "appended"
                               }))
                        (Atomic.get detail_captures)
                ; next_cursor = None
                }
            | V2_get_children { parent; limit; _ }
              when Atomic.get detail_fixture && G.Uuid.equal parent (uuid 1) ->
              if check_copy && Atomic.get detail_initial_limit = None
              then Atomic.set detail_initial_limit (Some limit);
              let value = timeline_block 1 in
              V2_children_outcome
                { parent
                ; revision_scope = V2_children_revision parent
                ; scope_revision = "children"
                ; items =
                    List.init
                      (if check_detail_wait then 2 else 1)
                      (fun i ->
                       let value = if i = 0 then value else timeline_block 2 in
                       { P.value = { value with block = { value.block with parent } }
                       ; revision = "child"
                         })
                ; next_cursor = None
                }
            | V2_get_children { parent; limit; cursor; _ } ->
              if Atomic.get detail_fixture && (check_detail_discovery || check_detail_wait) && G.Uuid.equal parent (uuid 2)
              then Atomic.set discovery_reads (limit :: Atomic.get discovery_reads);
              (* Initial first pages complete before publication. The wait
                 scenario delays only a later explicit continuation read. *)
              if Atomic.get detail_fixture && check_detail_wait && G.Uuid.equal parent (uuid 2) && cursor <> None then
                while not (Atomic.get detail_wait_release) do
                  Eio.Time.Mono.sleep (W.Request_context.clock context) 0.001
                done;
              V2_children_outcome
                { parent
                ; revision_scope = V2_children_revision parent
                ; scope_revision = "children"
                ; items =
                    (if G.Uuid.equal parent favorites_page.uuid
                     then List.init 65 favorite_membership
                     else if Atomic.get detail_fixture && check_detail_wait && cursor = None
                          && (G.Uuid.equal parent (uuid 2) || G.Uuid.equal parent (uuid 3))
                     then (
                       let value = timeline_block (if G.Uuid.equal parent (uuid 2) then 63 else 64) in
                       [ { P.value = { value with block = { value.block with parent } }
                         ; revision = "child-first-page"
                         }
                       ])
                     else [])
                ; next_cursor =
                    (if Atomic.get detail_fixture && check_detail_wait && cursor = None
                        && (G.Uuid.equal parent (uuid 2) || G.Uuid.equal parent (uuid 3))
                     then Some (G.Cursor.of_string "later-child-page" |> Result.get_ok)
                     else None)
                }
            | V2_list_favorites { limit; cursor } ->
              let offset =
                match cursor with
                | None -> 0
                | Some cursor -> int_of_string (G.Cursor.to_string cursor)
              in
              let items =
                favorite_items ()
                |> List.filteri (fun n _ -> n >= offset && n < offset + limit)
              in
              let through = offset + List.length items in
              V2_favorites_outcome
                { favorites_page = Some favorites_page.uuid
                ; generation = "g"
                ; projection_revision = "p"
                ; items
                ; next_cursor =
                    (if through < 65
                     then
                       Some (G.Cursor.of_string (string_of_int through) |> Result.get_ok)
                     else None)
                }
            | V2_list_assets { roots; _ } ->
              Atomic.set queried (List.rev_append roots (Atomic.get queried));
              V2_assets_outcome
                { generation = "g"
                ; projection_revision = "p"
                ; items =
                    (if check_ios_capture || Option.is_some media_rows
                     then
                       let module A = Logseq_db_types.Asset_descriptor in
                       [ A.create
                           ~uuid:
                             (uuid
                                (if shared_media
                                 then 20000
                                 else
                                   20000
                                   + Option.value
                                       (List.find_index
                                          (G.Uuid.equal (List.hd roots))
                                          (List.init 65 (fun n -> uuid (n + 1))))
                                       ~default:0))
                           ~source:
                             (Managed
                                (Some
                                   (A.version
                                      ~checksum:
                                        (String.make 64 (Atomic.get media_checksum))
                                      ~file_type:"png"
                                    |> Result.get_ok)))
                           ~current_checksum:None
                           ~size:None
                           ~dimensions:(Some (120, 80))
                         |> Result.get_ok
                       ]
                     else [])
                ; next_cursor = None
                }
            | V2_insert_blocks { mutation_id; parent; roots = [ root ]; _ }
              when Option.is_some detail_capture ->
              Atomic.incr child_attempts;
              while not (Atomic.get child_release) do
                Eio.Time.Mono.sleep (W.Request_context.clock context) 0.001
              done;
              if detail_capture = Some "failure" && Atomic.get child_attempts = 1
              then
                V2_failed
                  { code = Logseq_db_worker.Error.code_string Invalid_request
                  ; message = "Fixture child write failed" }
              else (
                Atomic.set detail_captures (Atomic.get detail_captures @ [ parent, root ]);
                V2_mutation_committed
                  { mutation_id
                  ; status = V2_applied
                  ; generation = "g"
                  ; before_projection_revision = "p"
                  ; after_projection_revision = "p2"
                  })
            | V2_insert_blocks { mutation_id; parent; roots = [ root ]; _ }
              when check_capture_imports ->
              let page = Atomic.get capture_page |> Option.get in
              Alcotest.(check string)
                "capture mutation targets its requested journal page"
                (G.Uuid.to_string page.uuid)
                (G.Uuid.to_string parent);
              Atomic.set capture_root (Some root);
              V2_mutation_committed
                { mutation_id
                ; status = V2_applied
                ; generation = "g"
                ; before_projection_revision = "p"
                ; after_projection_revision = "p2"
                }
            | _ -> V2_failed { code = "unsupported"; message = "Unused fixture command" }
          in
          Ok
            (Service.Graph_response
               (P.V2_response
                  { api_version = 2; request_id = request.request_id; outcome })))
      ~shutdown:(fun () -> Atomic.set shutdown_called true)
      ()
  in
  let clipboard_requests = ref [] in
  let regions = Hashtbl.create 8 in
  let hooks =
    Application.For_testing.app_with_service
      ?calendar_sampler
      ~on_client:(fun value -> client := Some value)
      ~on_platform_request:(fun request ->
        if Bytes.length request >= 32 && Bytes.get_uint16_le request 6 = 25 then incr delete_notices;
        if Bytes.length request >= 32 && Bytes.get_uint16_le request 6 = 28
        then clipboard_requests := request :: !clipboard_requests)
      ~on_view_region:(fun name ->
        Hashtbl.replace
          regions
          name
          (1 + Option.value (Hashtbl.find_opt regions name) ~default:0))
      service
  in
  let props = Hashtbl.create 512
  and parents = Hashtbl.create 512 in
  let track_teardown = track_json_wire_teardown ~parents (Hashtbl.remove props) in
  let consume encoded =
    if encoded <> ""
    then
      let open Yojson.Safe.Util in
      Yojson.Safe.from_string encoded
      |> member "ops"
      |> to_list
      |> List.iter (fun op ->
        track_teardown op;
        match op |> member "op" |> to_string with
        | "create-node" ->
          Hashtbl.replace
            props
            (op |> member "id" |> to_int)
            [ "_kind", member "kind" op ]
        | "create-extension" ->
          Hashtbl.replace
            props
            (op |> member "id" |> to_int)
            [ "_extension", member "identifier" op ]
        | "set-prop" | "set-extension-prop" ->
          let id = op |> member "id" |> to_int in
          let previous = Option.value (Hashtbl.find_opt props id) ~default:[] in
          let key = op |> member "property" |> to_string in
          if
            key = "payload"
            && List.assoc_opt "_extension" previous = Some (`String "journal-list")
          then (
            let rec check_row row =
              Alcotest.(check bool)
                "production row has no swipe entry"
                true
                (member "swipe" row = `Null);
              match member "children" row with
              | `List children -> List.iter check_row children
              | _ -> ()
            in
            member "value" op
            |> to_string
            |> Yojson.Safe.from_string
            |> member "sections"
            |> to_list
            |> List.iter (fun section ->
              section |> member "rows" |> to_list |> List.iter check_row));
          Hashtbl.replace
            props
            id
            ((key, member "value" op) :: List.remove_assoc key previous)
        | _ -> ())
  in
  let find ?(accept = fun _ -> true) key value =
    let direct = Hashtbl.fold
      (fun id values found ->
         if accept id && List.assoc_opt key values = Some (`String value) then Some id else found)
      props
      None
    in
    match direct with
    | Some _ -> direct
    | None when key = "text" -> Hashtbl.fold (fun id values found ->
        match List.assoc_opt "payload" values with
        | Some (`String payload) ->
          let p = Yojson.Safe.from_string payload in
             if
               accept id
               && List.mem
                    (Yojson.Safe.Util.member "mode" p)
                    [ `String "detail-text"; `String "bounded-text" ]
             && Yojson.Safe.Util.member "text" p = `String value then Some id else found
        | _ -> found) props None
    | None -> None
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
  let load_all_favorites label =
    wait label (fun () -> Option.is_some (find "text" "Fixture 48"));
    if Option.is_none (find "text" "Fixture 64")
    then (
      let list_node = Option.get (find "accessibility-identifier" "favorites-native-list") in
      dispatch (Lui_protocol.VisibleRange (list_node,38,50)));
    wait "second Favorite page loaded" (fun () ->
      Option.is_some (find "text" "Fixture 64"))
  in
  let settle_worker () =
    let idle_rounds = ref 0 in
    wait "background hydration completes" (fun () ->
      let client = Option.get !client in
      let metrics = W.Private.metrics (W.Private.pack_client client) in
      if
        metrics.queued_requests = 0
        && metrics.active_request_fibers = 0
        && W.For_testing.pending_output_count client = 0
      then incr idle_rounds
      else idle_rounds := 0;
      !idle_rounds >= 12)
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
    ~finally:(fun () ->
      Atomic.set delete_release true;
      Atomic.set status_release true;
      Atomic.set child_release true;
      Atomic.set calendar_feed_release true;
      Atomic.set detail_wait_release true;
      Atomic.set import_release true;
      Atomic.set acquire_release true;
      ignore (hooks.dispose ());
      Option.iter Logseq_db_worker_lui.Journal_worker_runtime.stop !client;
      List.iter (fun path -> if Sys.file_exists path then Sys.remove path) (!staged_paths @ Atomic.get durable_paths);
      check_fixture_worker_idle ())
    (fun () ->
       hooks.init 2 2 startup |> consume;
       on_initialized ();
       if check_ios_capture || check_capture_imports || Option.is_some detail_capture
       then (
         let snapshot = { Journal_environment.fallback with platform = "ios" } in
         let payload =
           Journal_environment.encode_json snapshot |> Yojson.Basic.to_string
         in
         let packet = Bytes.make (32 + String.length payload) '\000' in
         Bytes.blit_string "LJP2" 0 packet 0 4;
         Bytes.set_uint16_le packet 4 2;
         Bytes.set_uint16_le packet 6 24;
         Bytes.set_int32_le packet 24 (Int32.of_int (String.length payload));
         Bytes.blit_string payload 0 packet 32 (String.length payload);
         hooks.platform_event (Bytes.to_string packet);
         hooks.pump () |> consume);
       wait "initial feed read" (fun () -> Atomic.get feed_queried);
       for _ = 1 to 3 do
         hooks.pump () |> consume;
         Unix.sleepf 0.001
       done;
       wait "Journals mounted" (fun () ->
         Option.is_some (find "accessibility-label" "Favorites")
         && Option.is_some (find "text" "Timeline fixture 2"));
       if check_reselect then (
         let list () = Option.get (find "_extension" "journal-list") in
         let request () =
           List.assoc "scroll_request" (Hashtbl.find props (list ()))
           |> Yojson.Safe.Util.to_string |> Yojson.Safe.from_string
         in
         let press label = dispatch (Lui_protocol.Press (Option.get (find "accessibility-label" label))) in
         let completion token outcome =
           let event = Yojson.Safe.to_string (`Assoc
             ["type", `String "scroll_completed"; "token", token; "outcome", `String outcome]) in
           consume (hooks.extension_event (list ()) "event"
             (Yojson.Safe.to_string (`Assoc ["id", `Int 1; "payload", `String event])))
         in
         Alcotest.(check bool) "mount has no unsolicited scroll" true (request () = `Null);
         let content = List.assoc "payload" (Hashtbl.find props (list ())) in
         Hashtbl.clear regions;
         press "Journals";
         let first = request () in
         Alcotest.(check bool) "reselect requests the first date" true (first <> `Null);
         Alcotest.(check bool) "section target includes empty Today" true
           (Yojson.Safe.Util.(member "row_path" (member "target" first)) = `List []);
         press "Journals";
         Alcotest.(check bool) "pending reselect coalesces" true (request () = first);
         let token = Yojson.Safe.Util.member "token" first in
         completion token "cancelled";
         Alcotest.(check bool) "drag cancellation clears request" true (request () = `Null);
         Alcotest.(check bool) "command cycle preserves serialized content" true
           (List.assoc "payload" (Hashtbl.find props (list ())) = content);
         List.iter (fun name ->
           Alcotest.(check int) ("command cycle does not rebuild " ^ name) 0
             (Option.value (Hashtbl.find_opt regions name) ~default:0))
           [ "timeline"; "timeline-item-compare"; "timeline-structure-change" ];
         press "Journals";
         let second = request () in
         completion token "succeeded";
         Alcotest.(check bool) "stale completion cannot clear newer request" true (request () = second);
         press "Favorites";
         press "Journals";
         Alcotest.(check bool) "returning to Timeline does not replay cancelled request" true (request () = `Null);
         press "Journals";
         let third = request () in
         completion (Yojson.Safe.Util.member "token" third) "succeeded";
         Alcotest.(check bool) "successful completion clears request" true (request () = `Null);
         (* Root_navigation's opaque public state has no route-open event or scroll
            observation. The mounted Application is the narrow public boundary. *)
         press "Journals";
         let label = Option.get (find "text" "Timeline fixture 1") in
         dispatch (Lui_protocol.Press (ancestor_property label "press-enabled"));
         wait "Detail loads during pending return" (fun () ->
           Option.is_some (find "accessibility-identifier"
             ("detail-block:" ^ G.Uuid.to_string (uuid 2))));
         let nav = Option.get (find "_extension" "navigation-stack") in
         let payload () =
           let revision = List.assoc "revision" (Hashtbl.find props nav)
             |> Yojson.Safe.Util.to_int in
           Yojson.Safe.to_string (`Assoc ["revision", `Int revision; "length", `Int 0])
         in
         hooks.extension_event nav "path-changed" (payload ()) |> consume;
         hooks.extension_event nav "settled" (payload ()) |> consume;
         (* A hidden/disabled native extension is allowed to drop its completion. *)
         Alcotest.(check bool) "Detail cancels without requiring a native completion" true (request () = `Null));
       (* OCaml event decoding belongs to the mounted view adapter, outside
          Root_navigation's public reducer events. Exercise the real decoder. *)
       Option.iter (fun mode ->
         let identifier, payload, operation = match mode with
           | `List -> "journal-list", "private-malformed-event", "decodeListEvent"
           | `Row -> "journal-list", {|{"type":"row_event","payload":"private-malformed-event"}|}, "decodeListRowEvent"
           | `Extension -> "journal-chrome", "private-malformed-event", "decodeExtensionEvent" in
         let native = if mode<>`Extension then Option.get (find "_extension" identifier)
           else Hashtbl.fold (fun id values found ->
             match List.assoc_opt "_extension" values, List.assoc_opt "payload" values with
             | Some (`String "journal-chrome"), Some (`String payload) ->
               if Yojson.Safe.Util.member "mode" (Yojson.Safe.from_string payload)=`String "page"
               then Some id else found
             | _ -> found) props None |> Option.get in
         consume (hooks.extension_event native "event" (Yojson.Safe.to_string
           (`Assoc ["id", `Int 1; "payload", `String payload])));
         dispatch (Lui_protocol.Press (Option.get (find "text" "Diagnostics")));
         wait "actual mounted decoder reports to Diagnostics" (fun () ->
           Option.is_some (find "text" operation));
         let expected_cause = if mode = `Extension then "Native event shape is invalid"
           else "Native event JSON syntax is invalid" in
         let expected_message = operation ^ ": Input could not be parsed. Cause: " ^ expected_cause ^ "." in
         Alcotest.(check bool) "decoder preserves safe specific cause" true
           (Option.is_some (find "text" expected_message));
         Alcotest.(check bool) "raw event never becomes diagnostic text" true
           (Option.is_none (find "text" "private-malformed-event"));
         dispatch (Lui_protocol.Press (Option.get
           (find "accessibility-identifier" "journal-diagnostics-close")));
         if mode = `List then (
           let list = Option.get (find "_extension" "journal-list") in
           let duplicate = {|{"type":"visible_range","first":0,"first":1,"last":2}|} in
           consume (hooks.extension_event list "event" (Yojson.Safe.to_string
             (`Assoc ["id", `Int 1; "payload", `String duplicate])));
           dispatch (Lui_protocol.Press (Option.get (find "text" "Diagnostics")));
           wait "same operation retains a later distinct decoding cause" (fun () ->
             Option.is_some (find "text"
               "decodeListEvent: Input could not be parsed. Cause: duplicate JSON field."));
           dispatch (Lui_protocol.Press (Option.get
             (find "accessibility-identifier" "journal-diagnostics-close")));
           let list = Option.get (find "_extension" "journal-list") in
           consume (hooks.extension_event list "event" (Yojson.Safe.to_string
             (`Assoc ["id", `Int 1; "payload", `String "private-malformed-event"])));
           dispatch (Lui_protocol.Press (Option.get (find "text" "Diagnostics")));
           let syntax_occurrences () = Hashtbl.fold (fun _ values count ->
             if List.assoc_opt "text" values = Some (`String expected_message)
             then count+1 else count) props 0 in
           wait "returning to an earlier cause becomes a new latest occurrence" (fun () -> syntax_occurrences ()=2);
           dispatch (Lui_protocol.Press (Option.get
             (find "accessibility-identifier" "journal-diagnostics-close"))))) malformed_native_event;
       (* Delete admission is private to Application, absent from Root_navigation's
          public pure events. Use its existing public bridge and controlled Worker
          fixture to execute the actual UI admission/completion boundary. *)
       Option.iter (fun scenario ->
         let send_delete () =
           let list = Option.get (find "_extension" "journal-list") in
           let row_payload = Yojson.Safe.to_string (`Assoc
             [ "key", `String "delete"; "row", `String ("block:" ^ G.Uuid.to_string (uuid 1)) ]) in
           let event = Yojson.Safe.to_string (`Assoc
             [ "type", `String "row_event"; "payload", `String row_payload ]) in
           hooks.extension_event list "event" (Yojson.Safe.to_string
             (`Assoc [ "id", `Int 1; "payload", `String event ])) |> consume
         in
         send_delete ();
         Alcotest.(check bool) "pending delete keeps content until commit" true
           (Option.is_some (find "text" "Timeline fixture 0"));
         Alcotest.(check int) "delete never requests an Undo notice" 0 !delete_notices;
         let immediate_deadline = Unix.gettimeofday () +. 0.5 in
         while Atomic.get delete_writes = 0 && Unix.gettimeofday () < immediate_deadline do
           hooks.pump () |> consume; Unix.sleepf 0.001
         done;
         Alcotest.(check int) "delete reaches Worker immediately without an Undo deadline" 1
           (Atomic.get delete_writes);
         send_delete ();
         Alcotest.(check int) "repeated pending row action sends once" 1 (Atomic.get delete_writes);
         Atomic.set delete_release true;
         wait "delete completion updates content or shows failure" (fun () ->
           if scenario = "failure" then Option.is_some (find "text" "Delete failed")
           else Option.is_none (find "text" "Timeline fixture 0"));
         Alcotest.(check bool) "failure preserves block; success removes it" (scenario = "failure")
           (Option.is_some (find "text" "Timeline fixture 0"));
         Alcotest.(check int) "completion cannot leave an Undo notice" 0 !delete_notices;
         if scenario = "failure" then (
           dispatch (Lui_protocol.Press (Option.get (find "accessibility-label" "Details")));
           wait "failure details explain recovery" (fun () ->
             Option.is_some (find "text" "The block is kept. Review it before trying Delete again."));
           Alcotest.(check bool) "failure includes worker reason" true
             (Option.is_some (find "text" "Fixture delete failed"));
           dispatch (Lui_protocol.Press (Option.get (find "accessibility-identifier" "journal-error-info-close")));
           send_delete ();
           wait "failure releases admission for explicit retry" (fun () -> Atomic.get delete_writes = 2))
         else (
           send_delete ();
           Alcotest.(check int) "deleted identity cannot submit again" 1 (Atomic.get delete_writes))) delete_scenario;
       Option.iter (fun scenario ->
            let option tag =
              find
                "accessibility-identifier"
                ("journal-status-sheet-option:"
                 ^ if tag = "clear" then tag else G.Uuid.to_string (status_uuid tag))
            in
         let close () = Option.get (find "accessibility-identifier" "journal-status-close") in
         let send_status () =
           let list = Option.get (find "_extension" "journal-list") in
           let row_payload = Yojson.Safe.to_string (`Assoc
             [ "key", `String "status"; "row", `String ("block:" ^ G.Uuid.to_string (uuid 1)) ]) in
           let event = Yojson.Safe.to_string (`Assoc
             [ "type", `String "row_event"; "payload", `String row_payload ]) in
           hooks.extension_event list "event" (Yojson.Safe.to_string
             (`Assoc [ "id", `Int 1; "payload", `String event ])) |> consume
         in
         let open_status () =
           send_status ();
           wait "status sheet opens from actual row action" (fun () -> Option.is_some (option "doing"))
         in
         open_status ();
         let tags = ["backlog"; "todo"; "doing"; "in-review"; "done"; "canceled"; "clear"] in
         List.iter (fun tag ->
           let node = Option.get (option tag) in
           Alcotest.(check bool) "every status is a direct pressable list row" true
             (List.assoc_opt "_kind" (Hashtbl.find props node) = Some (`String "list-item"));
           Alcotest.(check bool) "whole status row has a native press action" true
             (List.assoc_opt "press-enabled" (Hashtbl.find props node) = Some (`Bool true));
                 let expected =
                   match Atomic.get status_value with
                   | None -> tag = "clear"
                   | Some value -> tag = value
                 in
           Alcotest.(check bool) "current option is selected without aliasing other statuses" expected
             (List.assoc_opt "selected" (Hashtbl.find props node) = Some (`Bool true))) tags;
         let current = match Atomic.get status_value with
           | None -> "Current · No status" | Some "doing" -> "Current · Doing"
           | Some "now" -> "Current · Now" | Some "waiting" -> "Current · Waiting"
           | Some "later" -> "Current · Later" | Some value -> value in
         Alcotest.(check bool) "exact current state is visible" true (Option.is_some (find "text" current));
         let apply tag = dispatch (Lui_protocol.Press (Option.get (option tag))) in
         (match scenario with
          | "expanded" ->
            apply "doing";
            Alcotest.(check int) "current status never writes" 0 (List.length (Atomic.get status_writes));
            Alcotest.(check bool) "current status leaves sheet open" true (Option.is_some (option "doing"));
            dispatch (Lui_protocol.Press (close ()))
          | "dismiss" -> dispatch (Lui_protocol.Dismiss (Option.get (find "_kind" "sheet")))
          | "none" | "now" | "waiting" | "later" -> dispatch (Lui_protocol.Press (close ()))
             | "failure" | "duplicate" | "clear" | "select" | "custom" | "pagination" ->
               let target =
                 if scenario = "clear"
                 then "clear"
                 else if scenario = "custom"
                 then "b1000000-0000-4000-8000-000000001000"
                 else if scenario = "pagination"
                 then "b1000000-0000-4000-8000-000000001119"
                 else "done"
               in
               if scenario = "pagination"
               then
                 dispatch
                   (Lui_protocol.Press
                      (Option.get (find "accessibility-identifier" "journal-status-next")));
               let old = Option.get (option target) in
            dispatch (Lui_protocol.Press old);
            Alcotest.(check bool) "selection closes immediately before completion" true (Option.is_none (option "doing"));
            dispatch (Lui_protocol.Press old);
            wait "one real status mutation reaches Worker" (fun () -> Atomic.get status_writes <> []);
            if scenario = "duplicate" then (
              send_status ();
              Alcotest.(check bool) "pending status cannot reopen another operation" true (Option.is_none (option "doing"));
              Atomic.set status_release true);
            wait "status operation completes" (fun () ->
              if scenario = "failure" then Option.is_some (find "text" "Status not changed")
                 else
                   Atomic.get status_value
                   = if scenario = "clear" then None else Some target);
            wait "status owner accepts another menu after completion" (fun () ->
              if Option.is_none (option "doing") then send_status ();
              Option.is_some (option "doing"));
            Alcotest.(check int) "stale duplicate press submits once" 1 (List.length (Atomic.get status_writes));
               let expected = if scenario = "failure" then "doing" else target in
               if scenario = "pagination"
               then
                 dispatch
                   (Lui_protocol.Press
                      (Option.get (find "accessibility-identifier" "journal-status-next")));
            Alcotest.(check bool) "reopened menu shows the committed status or retains it on failure" true
              (List.assoc_opt "selected" (Hashtbl.find props (Option.get (option expected))) = Some (`Bool true));
            dispatch (Lui_protocol.Press (close ()))
          | _ -> Alcotest.fail "unknown status scenario");
         if List.mem scenario ["expanded"; "dismiss"; "none"; "now"; "waiting"; "later"] then (
           Alcotest.(check bool) "closing removes status UI" true (Option.is_none (option "doing"));
           Alcotest.(check int) "closing never submits" 0 (List.length (Atomic.get status_writes)))) status_scenario;
       if Option.is_none status_scenario && Option.is_none delete_scenario then (
       if Option.is_some calendar_change then (
         let label () = Hashtbl.fold (fun _ values found ->
           match List.assoc_opt "payload" values with
           | Some (`String payload) ->
             let props = Yojson.Safe.from_string payload in
             let open Yojson.Safe.Util in
             if member "mode" props = `String "header" && member "title" props = `String "2026.09.01"
                    then (
                      match member "text" props with
                      | `String text -> Some text
                      | _ -> None)
                    else found
           | _ -> found) props None in
         Alcotest.(check (option string)) "initial sampled date is today" (Some "today") (label ());
         let lifecycle kind =
           let packet = Bytes.make 48 '\000' in
           Bytes.blit_string "LJP2" 0 packet 0 4;
           Bytes.set_uint16_le packet 4 2;
           Bytes.set_uint16_le packet 6 15;
           Bytes.set_int32_le packet 24 16l;
           Bytes.blit_string "LJP1" 0 packet 32 4;
           Bytes.set_uint16_le packet 36 1;
           Bytes.set_uint16_le packet 38 kind;
           Bytes.set_int64_le packet 40 1L;
           hooks.platform_event (Bytes.to_string packet);
           hooks.pump () |> consume in
         lifecycle 1;
         (match calendar_change with
          | Some `Zone -> calendar_offset := 7_200.
          | Some `Day -> calendar_seconds := !calendar_seconds +. 86_400.
          | None -> ());
         let previous_reads = Atomic.get calendar_feed_reads in
         Atomic.set calendar_refresh_pending true;
         lifecycle 2;
         wait "calendar refresh starts with retained feed" (fun () -> Atomic.get calendar_feed_reads > previous_reads);
         Alcotest.(check bool) "feed is still pending" false (Atomic.get calendar_feed_release);
         Alcotest.(check (option string)) "sampled date updates before feed completion"
           (Some "yesterday") (label ());
         Atomic.set calendar_feed_release true;
         wait "failed refresh exposes current error" (fun () -> Option.is_some (find "accessibility-label" "Error info"));
         Alcotest.(check (option string)) "failed refresh retains the correct date suffix"
           (Some "yesterday") (label ());
         Alcotest.(check bool) "failed refresh keeps the existing Timeline visible" true
           (Option.is_some (find "text" "Timeline fixture 2"));
         Alcotest.(check int) "labels add no feed queries" (previous_reads + 1)
           (Atomic.get calendar_feed_reads));
       if check_detail_wait then (
         Atomic.set detail_fixture true;
         let root_list = Option.get (find "_extension" "journal-list") in
         let label = Option.get (find "text" "Timeline fixture 0") in
         dispatch (Lui_protocol.Press (ancestor_property label "press-enabled"));
         let more_id = "detail-more:" ^ G.Uuid.to_string (uuid 3) in
         wait "second unknown branch mounted" (fun () ->
           Option.is_some (find "accessibility-identifier" more_id));
         Alcotest.(check bool) "idle branch has no wait explanation" true
           (Option.is_none (find "text" "Waiting for another branch to finish"));
         let list = Hashtbl.fold (fun id values found ->
           if id <> root_list && List.assoc_opt "_extension" values = Some (`String "journal-list")
           then Some id else found) props None |> Option.get in
         let range first last = hooks.extension_event list "event"
               (Yojson.Safe.to_string
                  (`Assoc
                      [ "id", `Int 1
                      ; ( "payload"
                        , `String
                            (Yojson.Safe.to_string
                               (`Assoc
                                   [ "type", `String "visible_range"
                                   ; "first", `Int first
                                   ; "last", `Int last
                                   ])) )
                      ]))
             |> consume
           in
         let first_more = Option.get (find "accessibility-identifier"
           ("detail-more:" ^ G.Uuid.to_string (uuid 2))) in
         dispatch (Lui_protocol.Press first_more);
         wait "explicit first branch continuation is pending" (fun () ->
           Atomic.get discovery_reads = [128;128]);
         range 4 5;
         let more = Option.get (find "accessibility-identifier" more_id) in
         Alcotest.(check bool) "other branch stays disabled while first is pending" true
           (List.assoc_opt "enabled" (Hashtbl.find props more) = Some (`Bool false));
         Alcotest.(check bool) "disabled branch explains serialized wait" true
           (Option.is_some (find "text" "Waiting for another branch to finish"));
         Atomic.set detail_wait_release true;
         wait "wait explanation retires with pending read" (fun () ->
           Option.is_none (find "text" "Waiting for another branch to finish"));
         let navigator = Option.get (find "_extension" "navigation-stack") in
         List.iter (fun name ->
           let revision = List.assoc "revision" (Hashtbl.find props navigator)
             |> Yojson.Safe.Util.to_int in
           hooks.extension_event navigator name
             (Yojson.Safe.to_string (`Assoc ["revision", `Int revision; "length", `Int 0]))
           |> consume) ["path-changed"; "settled"];
         wait "wait scenario returns to root before shared checks" (fun () ->
           not (Hashtbl.mem props list));
         Atomic.set detail_fixture false);
       if check_detail_discovery
       then (
         Atomic.set detail_fixture true;
         let root_list = Option.get (find "_extension" "journal-list") in
         let label = Option.get (find "text" "Timeline fixture 0") in
         dispatch (Lui_protocol.Press (ancestor_property label "press-enabled"));
         wait "Detail initial projection mounted" (fun () ->
           Option.is_some
             (find
                "accessibility-identifier"
                ("detail-block:" ^ G.Uuid.to_string (uuid 2))));
         for _ = 1 to 10 do
           hooks.pump () |> consume;
           Unix.sleepf 0.001
         done;
         Alcotest.(check (list int))
           "bounded initial discovery completes before body publication"
           [128]
           (Atomic.get discovery_reads);
         Alcotest.(check bool)
           "authoritative empty child has no More at publication"
           true
           (Option.is_none (find "accessibility-identifier"
              ("detail-more:" ^ G.Uuid.to_string (uuid 2))));
         let list =
           Hashtbl.fold
             (fun id values found ->
                if
                  id <> root_list
                  && List.assoc_opt "_extension" values = Some (`String "journal-list")
                then Some id
                else found)
             props
             None
           |> Option.get
         in
         let range () =
           hooks.extension_event
             list
             "event"
             {|{"id":1,"payload":"{\"type\":\"visible_range\",\"first\":2,\"last\":3}"}|}
           |> consume
         in
         range ();
         wait "first native range preserves completed initial discovery" (fun () ->
           Atomic.get discovery_reads = [ 128 ]);
         wait "authoritative empty child retires More" (fun () ->
           Option.is_none (find "text" "Load more"));
         for _ = 1 to 10 do
           range ();
           hooks.pump () |> consume
         done;
         Alcotest.(check (list int))
           "duplicate native ranges do not reread"
           [ 128 ]
           (Atomic.get discovery_reads);
           Printf.printf
             "FOLLOWUP_APPLICATION initial_staging reads=1 limit=128 repeated_range=10 \
              duplicate_reads=0\n\
              %!";
         let navigator = Option.get (find "_extension" "navigation-stack") in
         let back name =
           let revision =
             List.assoc "revision" (Hashtbl.find props navigator)
             |> Yojson.Safe.Util.to_int
           in
           hooks.extension_event
             navigator
             name
             (Yojson.Safe.to_string
                (`Assoc [ "revision", `Int revision; "length", `Int 0 ]))
           |> consume
         in
         back "path-changed";
         back "settled";
         wait "native Back retires Detail visibility owner" (fun () ->
           not (Hashtbl.mem props list));
         range ();
         hooks.pump () |> consume;
         Alcotest.(check (list int))
           "retired range cannot activate hidden reads"
           [ 128 ]
           (Atomic.get discovery_reads);
         Atomic.set detail_fixture false);
       (* Detail/Routes already own text admission, retry, outline ordering and
          retained drafts, covered by their pure public reducer tests. They
          cannot reproduce native Capture placement, shared Composer wiring,
          picker callbacks or asynchronous Worker import ownership. Exercise
          only that missing boundary through the public mounted Application. *)
       Option.iter
         (fun scenario ->
            let all key value =
              Hashtbl.fold
                (fun id values ids ->
                   if List.assoc_opt key values = Some (`String value) then id :: ids else ids)
                props []
            in
            (* A child preview may repeat a top-level title. Select the
               retained UUID row before comparing its native content node. *)
            let timeline_title n =
              let row = "journal-row-label:" ^ G.Uuid.to_string (uuid (n + 1)) in
              let rec in_row id =
                let values = Option.value (Hashtbl.find_opt props id) ~default:[] in
                match List.assoc_opt "accessibility-identifier" values with
                | Some (`String value) when String.starts_with ~prefix:"journal-row-label:" value ->
                  value = row
                | _ -> Option.fold ~none:false ~some:in_row (Hashtbl.find_opt parents id)
              in
              find ~accept:in_row "text" (Printf.sprintf "Timeline fixture %d" n)
              |> Option.get
            in
            let enter n =
              let label = timeline_title n in
              dispatch (Lui_protocol.Press (ancestor_property label "press-enabled"));
              wait "Detail root loads" (fun () ->
                Option.is_some
                  (find
                     "accessibility-identifier"
                     ("detail-block:" ^ G.Uuid.to_string (uuid (n + 1)))))
            in
            let open_capture () =
              let scope = find "accessibility-identifier" "journal-detail-capture-open" in
              Alcotest.(check bool)
                "Detail has its own bottom Capture control"
                true
                (Option.is_some scope);
              let rec inside id root =
                id = root
                || Option.fold
                     ~none:false
                     ~some:(fun parent -> inside parent root)
                     (Hashtbl.find_opt parents id)
              in
              let label =
                all "accessibility-label" "Capture"
                |> List.find (fun id -> inside id (Option.get scope))
              in
              dispatch (Lui_protocol.Press label);
              wait "Detail expands the shared Composer" (fun () ->
                Option.is_some (find "accessibility-identifier" "journal-append-composer"))
            in
            let send () = Option.get (find "accessibility-label" "Send") in
            let edit text =
              dispatch
                (Lui_protocol.TextChanged
                   (Option.get (find "style-class" "composer-input"), text))
            in
            let collapse () =
              dispatch
                (Lui_protocol.Press
                   (Option.get
                      (find "accessibility-identifier" "journal-composer-dismiss")));
              wait "collapse removes Composer" (fun () ->
                Option.is_none (find "style-class" "composer-input"))
            in
            let back () =
              let nav = Option.get (find "_extension" "navigation-stack") in
              let payload () =
                let revision =
                  List.assoc "revision" (Hashtbl.find props nav)
                  |> Yojson.Safe.Util.to_int
                in
                Yojson.Safe.to_string
                  (`Assoc [ "revision", `Int revision; "length", `Int 0 ])
              in
              hooks.extension_event nav "path-changed" (payload ()) |> consume;
              hooks.extension_event nav "settled" (payload ()) |> consume
            in
            let original_root_content = timeline_title 1 in
            enter 0;
            if scenario = "legacy-interrupted" then (
              (* No pure reducer owns native completion copy or the Worker queue.
                 The existing non-staged adapter is tested via its public callback;
                 it has no visible iOS opener, so this is not a GUI claim. *)
              let adapter = Hashtbl.fold (fun id values found ->
                       match
                         ( List.assoc_opt "_extension" values
                         , List.assoc_opt "payload" values )
                       with
                | Some (`String "journal-asset-import"), Some (`String payload) ->
                  let request = Yojson.Safe.Util.member "request" (Yojson.Safe.from_string payload) in
                  if Yojson.Safe.Util.member "staged" request = `Bool false then Some id else found
                | _ -> found) props None |> Option.get in
              let operation = G.Uuid.to_string (uuid 34001) in
              let path = Filename.temp_file "journal-legacy-import-" ".txt" in
              Fun.protect ~finally:(fun () -> Sys.remove path) (fun () ->
                let picked = `Assoc [
                  "operation",`String operation;"asset",`String (G.Uuid.to_string (uuid 34002));
                  "localMutation",`String (G.Uuid.to_string (uuid 34003));
                  "metadataMutation",`String (G.Uuid.to_string (uuid 34004));
                  "path",`String path;"title",`String "First attachment";"type",`String "txt"] in
                hooks.extension_event adapter "event" (Yojson.Safe.to_string
                          (`Assoc
                              [ "id", `Int 1
                              ; ( "payload"
                                , `String
                                    (Yojson.Safe.to_string
                                       (`Assoc
                                           [ "action", `String "picked"
                                           ; "selection", picked
                                           ])) )
                              ]))
                     |> consume;
                Atomic.set import_release true;
                wait "non-staged interruption requires source reselection" (fun () ->
                  Hashtbl.fold (fun _ values found -> found ||
                    match List.assoc_opt "payload" values with
                    | Some (`String payload) ->
                      let json = Yojson.Safe.from_string payload in
                      Yojson.Safe.Util.member "completion" json = `String operation
                      && Yojson.Safe.Util.member "error" json =
                         `String "Import was interrupted. Select the file again."
                    | _ -> false) props false);
                Alcotest.(check bool) "non-staged import cannot offer retained-byte retry" true
                  (Option.is_none (find "accessibility-label" "Retry imports"))));
            Alcotest.(check bool)
              "old Append toolbar action is removed"
              true
              (Option.is_none (find "accessibility-label" "Append"));
            Alcotest.(check bool)
              "old Attach file toolbar action is removed"
              true
              (Option.is_none (find "accessibility-label" "Attach file"));
            open_capture ();
            dispatch (Lui_protocol.Press (send ()));
            edit "  \n ";
            dispatch (Lui_protocol.Press (send ()));
            settle_worker ();
            Alcotest.(check int)
              "empty and whitespace cannot insert a child"
              0
              (Atomic.get child_attempts);
            edit
              (if scenario = "attachment-only" then "" else "Detail child 中文\nsecond line");
            if
              List.mem
                scenario
                [ "attachments"; "attachment-only"; "offscreen-attachments"; "selection-error"; "picker-owner"; "retry-imports"; "attachment-limit"; "interrupted-imports" ]
            then (
              dispatch (Lui_protocol.Press (Option.get (find "accessibility-label" "Files")));
              let adapter, request =
                Hashtbl.fold
                  (fun id values found ->
                       match
                         ( List.assoc_opt "_extension" values
                         , List.assoc_opt "payload" values )
                     with
                     | Some (`String "journal-asset-import"), Some (`String payload) ->
                       let open Yojson.Safe.Util in
                       let request = member "request" (Yojson.Safe.from_string payload) in
                       if
                         member "staged" request = `Bool true
                         && member "id" request |> to_int > 0
                       then Some (id, request)
                       else found
                     | _ -> found)
                  props
                  None
                |> Option.get
              in
              let item index title =
                let path = Filename.temp_file "journal-import-" ".txt" in
                staged_paths := !staged_paths @ [ path ];
                `Assoc
                  [ "operation", `String (G.Uuid.to_string (uuid (30000 + index)))
                  ; "asset", `String (G.Uuid.to_string (uuid (31000 + index)))
                  ; "localMutation", `String (G.Uuid.to_string (uuid (32000 + index)))
                    ; ( "metadataMutation"
                      , `String (G.Uuid.to_string (uuid (33000 + index))) )
                  ; "path", `String path
                  ; "title", `String title
                  ; "type", `String "txt"
                  ; "sourceIdentity", `String title
                  ]
              in
              let first = item 1 "First attachment" in
              let second = item 2 "Second attachment" in
              let batch =
                `Assoc
                  [ "action", `String "picked-batch"
                  ; "request", request
                  ; ( "items"
                    , `List (if scenario = "attachment-limit" then
                        first :: second :: List.init 7 (fun i -> item (i + 3) (Printf.sprintf "Extra attachment %d" (i + 3)))
                        else [ first; second ]) )
                  ]
              in
                let batch =
                  if scenario = "selection-error"
                  then (
                    match batch with
                    | `Assoc values ->
                      `Assoc
                        (("error", `String "Fixture partial selection failed") :: values)
                    | _ -> assert false)
                else batch in
              if scenario = "picker-owner" then (
                collapse (); back (); enter 2; open_capture (); edit "Keep other root draft";
                let open Yojson.Safe.Util in
                wait "armed picker stays owned during another Composer" (fun () ->
                  match List.assoc_opt "payload" (Hashtbl.find props adapter) with
                  | Some (`String payload) -> member "id" (member "request" (Yojson.Safe.from_string payload)) = member "id" request
                  | _ -> false));
              hooks.extension_event
                adapter
                "event"
                (Yojson.Safe.to_string
                   (`Assoc
                       [ "id", `Int 1; "payload", `String (Yojson.Safe.to_string batch) ])) |> consume;
              if scenario = "picker-owner" then (
                settle_worker ();
                Alcotest.(check bool) "late selection cannot overwrite other draft" true
                  (Option.is_some (find "text" "Keep other root draft"));
                collapse (); back (); enter 0; open_capture ());
              wait "Detail stages both Composer attachments" (fun () ->
                List.length
                  (all
                     "accessibility-identifier"
                     ("composer-attachment:" ^ G.Uuid.to_string (uuid 30002)))
                = 1);
              if scenario = "attachment-limit" then (
                (* Capture.can_attach already rejects the tenth pick; only the
                   real view boundary owns disabled controls and cap feedback. *)
                let check enabled = List.iter (fun label ->
                  let node = Option.get (find "accessibility-label" label) in
                  Alcotest.(check (option bool)) (label ^ " enabled matches capacity")
                    (Some enabled)
                    (Option.map Yojson.Safe.Util.to_bool
                      (List.assoc_opt "enabled" (Hashtbl.find props node)))) ["Files";"Photos";"Camera"] in
                check false;
                Alcotest.(check bool) "cap explains how to add another attachment" true
                  (Option.is_some (find "text" "9 attachments maximum. Remove one to add another."));
                for i = 3 to 9 do
                  dispatch (Lui_protocol.Press (Option.get (find "accessibility-label" (Printf.sprintf "Remove Extra attachment %d" i))))
                done;
                check true;
                Alcotest.(check bool) "removal retires cap feedback" true
                  (Option.is_none (find "text" "9 attachments maximum. Remove one to add another.")));
              if scenario = "selection-error" then (
                wait "partial selection failure is visible on its owner" (fun () -> Option.is_some (find "text" "Fixture partial selection failed"));
                collapse (); back (); enter 2; open_capture ();
                Alcotest.(check bool) "other Detail cannot show prior picker failure" true
                  (Option.is_none (find "text" "Fixture partial selection failed"));
                collapse (); back (); enter 0; open_capture ()));
            collapse ();
            open_capture ();
            if scenario <> "attachment-only"
            then
              Alcotest.(check bool)
                "cancel/reopen retains exact multiline draft"
                true
                (Option.is_some (find "text" "Detail child 中文\nsecond line"));
            if scenario = "navigation"
            then (
              let stale_send = send () in
              back ();
              enter 2;
              dispatch (Lui_protocol.Press stale_send);
              settle_worker ();
              Alcotest.(check int)
                "old root Send cannot submit after navigation"
                0
                (Atomic.get child_attempts);
              open_capture ();
              edit "New root draft");
            dispatch (Lui_protocol.Press (send ()));
            wait "child command is admitted" (fun () -> Atomic.get child_attempts = 1);
            if scenario = "duplicate"
            then (
              dispatch (Lui_protocol.Press (send ()));
              Alcotest.(check int)
                "repeated Send while Saving cannot duplicate"
                1
                (Atomic.get child_attempts);
              Atomic.set child_release true);
            if scenario = "offscreen-attachments"
            then (
              back ();
              enter 2;
              open_capture ();
              edit "Keep new root draft";
              Atomic.set child_release true);
            if scenario = "failure"
            then (
              wait "write failure is visible in Composer" (fun () ->
                Option.is_some (find "text" "Fixture child write failed"));
              collapse ();
              open_capture ();
              dispatch (Lui_protocol.Press (send ())));
            wait "one committed child is retained" (fun () ->
              List.length (Atomic.get detail_captures) = 1);
            let parent, child = List.hd (Atomic.get detail_captures) in
            Alcotest.(check string)
              "Send targets current Detail root"
              (G.Uuid.to_string (uuid (if scenario = "navigation" then 3 else 1)))
              (G.Uuid.to_string parent);
            Alcotest.(check string)
              "child preserves source or attachment-only friendly title"
              (if scenario = "navigation"
               then "New root draft"
               else if scenario = "attachment-only"
               then "First attachment"
               else "Detail child 中文\nsecond line")
              child.title;
            if !staged_paths <> []
            then (
              wait "first import reaches Worker" (fun () ->
                Atomic.get imports_entered <> []);
              Alcotest.(check (list string))
                "second import waits for first terminal result"
                [ "First attachment" ]
                (Atomic.get imports_entered);
              Atomic.set import_release true;
              wait "both imports finish" (fun () -> Atomic.get imports_finished = 2);
              if List.mem scenario ["retry-imports";"interrupted-imports"]
              then (
                wait "failed import exposes target retry" (fun () ->
                  Option.is_some (find "accessibility-label" "Retry imports"));
                dispatch (Lui_protocol.Press (Option.get (find "accessibility-label" "Details")));
                wait "retained imports explain in-place retry" (fun () ->
                    Option.is_some
                      (find
                         "text"
                         "Your journal entry and other attachments are kept. Select \
                          Retry imports to try again."));
                if scenario = "interrupted-imports" then
                  Alcotest.(check bool) "interrupted retained import gives retry guidance" true
                    (Option.is_some (find "text" "Import was interrupted. Select Retry imports to try again."));
                Alcotest.(check bool) "retained import never requires reselection" true
                    (Option.is_none
                       (find
                          "text"
                          "Your journal entry and other attachments are kept. Select the \
                           file again to retry."));
                dispatch (Lui_protocol.Press (Option.get (find "accessibility-label" "Close")));
                (* Routes reducers own the path, but cannot express native
                   feedback ancestry or layout. Mount the real failure through the
                   public Application boundary; navigation must cover the
                   root feedback together with the root page. *)
                let rec navigation_page id =
                  let values = Option.value (Hashtbl.find_opt props id) ~default:[] in
                  if List.assoc_opt "_extension" values = Some (`String "navigation-page")
                  then List.assoc_opt "entry-id" values
                  else Option.bind (Hashtbl.find_opt parents id) navigation_page
                in
                let root_actions =
                  Option.get (find "accessibility-identifier" "root-operation-actions")
                in
                Alcotest.(check (option string))
                  "root feedback is retained inside the native root page"
                  (Some "root")
                  (Option.map Yojson.Safe.Util.to_string (navigation_page root_actions));
                let detail_actions =
                  all "accessibility-label" "Retry imports"
                  |> List.find (fun id -> navigation_page id <> Some (`String "root"))
                in
                Alcotest.(check bool)
                  "Detail feedback belongs to its native destination"
                  true
                  (match navigation_page detail_actions with
                   | Some (`String entry) -> entry <> "root"
                   | _ -> false);
                let rec inset_owner id =
                  let values = Option.value (Hashtbl.find_opt props id) ~default:[] in
                  if List.assoc_opt "_kind" values = Some (`String "edge-inset")
                  then id
                  else inset_owner (Hashtbl.find parents id)
                in
                let root_inset = inset_owner root_actions in
                let root_body =
                  Hashtbl.fold
                    (fun id parent found ->
                       if
                         parent = root_inset
                         && List.assoc_opt "_kind" (Hashtbl.find props id)
                            = Some (`String "stack")
                       then Some id
                       else found)
                    parents
                    None
                  |> Option.get
                in
                let rec inside_body id =
                  id = root_body
                  || Option.fold
                       ~none:false
                       ~some:inside_body
                       (Hashtbl.find_opt parents id)
                in
                let root_content = timeline_title 1 in
                Alcotest.(check bool)
                  "root feedback reserves space for the retained page content"
                  true
                  (inside_body root_content);
                Alcotest.(check int)
                  "showing feedback preserves the original root content node"
                  original_root_content
                  root_content;
                Alcotest.(check bool)
                  "failed import keeps its own staged file"
                  true
                  (Sys.file_exists (List.hd !staged_paths));
                let retained_root = root_content in
                back ();
                Alcotest.(check int)
                  "Back retains the root feedback owner and its unresolved error"
                  root_actions
                  (Option.get (find "accessibility-identifier" "root-operation-actions"));
                Alcotest.(check int)
                  "feedback updates retain the root content"
                  retained_root
                  (timeline_title 1);
                enter 0;
                dispatch (Lui_protocol.Press detail_actions);
                settle_worker ();
                Alcotest.(check int)
                  "retired Detail feedback cannot start an import retry"
                  2
                  (Atomic.get imports_finished);
                let current_retry =
                  all "accessibility-label" "Retry imports"
                  |> List.find (fun id ->
                    match navigation_page id with
                    | Some (`String entry) -> entry <> "root"
                    | _ -> false)
                in
                dispatch (Lui_protocol.Press current_retry);
                wait "same child import retries" (fun () ->
                  Atomic.get imports_finished = 3);
                wait "successful retry retires both feedback controls" (fun () ->
                  all "accessibility-label" "Retry imports" = []);
                Alcotest.(check int)
                  "import retry does not create another child"
                  1
                  (Atomic.get child_attempts));
              if not (List.mem scenario [ "retry-imports"; "interrupted-imports"; "selection-error" ]) then (
                wait "failed import offers explicit discard" (fun () -> Option.is_some (find "accessibility-label" "Dismiss"));
                dispatch (Lui_protocol.Press (Option.get (find "accessibility-label" "Dismiss"))));
              wait "all staging files are released" (fun () ->
                List.for_all (fun p -> not (Sys.file_exists p)) !staged_paths);
              Alcotest.(check (list string))
                "imports target the newly appended child"
                (List.init (if List.mem scenario ["retry-imports";"interrupted-imports"] then 3 else 2) (fun _ -> G.Uuid.to_string child.uuid))
                (List.map G.Uuid.to_string (Atomic.get import_targets));
              if scenario = "offscreen-attachments"
              then
                Alcotest.(check bool)
                  "old completion preserves new root Composer"
                  true
                  (Option.is_some (find "text" "Keep new root draft")));
            if scenario <> "offscreen-attachments"
            then (
              wait "completion closes Detail Composer" (fun () ->
                Option.is_none (find "style-class" "composer-input"));
              if scenario = "selection-error" then (
                open_capture ();
                Alcotest.(check bool) "completed Detail retires picker failure" true
                  (Option.is_none (find "text" "Fixture partial selection failed"));
                collapse (); back ();
                dispatch (Lui_protocol.Press (Option.get (find "accessibility-label" "Capture")));
                wait "Timeline Composer opens" (fun () -> Option.is_some (find "accessibility-identifier" "journal-capture-composer"));
                Alcotest.(check bool) "Detail picker failure cannot leak to Timeline" true
                  (Option.is_none (find "text" "Fixture partial selection failed")))))
         detail_capture;
       if Option.is_none detail_capture then (
       (* Routes reducers cannot own LUI mount/subscription retention. The
          public mounted Application boundary reproduces top-only teardown. *)
       if check_navigation
       then (
         let root_list = Option.get (find "_extension" "journal-list") in
         let root_label = Option.get (find "text" "Timeline fixture 1") in
         Hashtbl.clear regions;
         dispatch (Lui_protocol.Press (ancestor_property root_label "press-enabled"));
         wait "Detail reaches its actual block" (fun () ->
           Option.is_some
             (find
                "accessibility-identifier"
                ("detail-block:" ^ G.Uuid.to_string (uuid 2))));
         Alcotest.(check bool)
           "covered Timeline retains its original native List node"
           true
           (Hashtbl.mem props root_list);
         Alcotest.(check bool)
           "covered Timeline retains its original row text node"
           true
           (Hashtbl.mem props root_label);
         let navigator = Option.get (find "_extension" "navigation-stack") in
         let native_event name length =
           let revision =
             List.assoc "revision" (Hashtbl.find props navigator)
             |> Yojson.Safe.Util.to_int
           in
           hooks.extension_event
             navigator
             name
             (Yojson.Safe.to_string
                (`Assoc [ "revision", `Int revision; "length", `Int length ]))
           |> consume
         in
         if check_detail_row_action
         then (
           let list =
             Hashtbl.fold
               (fun id values result ->
                  if
                    id <> root_list
                    && List.assoc_opt "_extension" values = Some (`String "journal-list")
                  then Some id
                  else result)
               props
               None
             |> Option.get
           in
           let payload =
             Yojson.Safe.to_string
               (`Assoc
                   [ "key", `String "open"
                   ; "row", `String ("block:" ^ G.Uuid.to_string (uuid 2))
                   ])
           in
           hooks.extension_event
             list
             "event"
             (Yojson.Safe.to_string
                (`Assoc
                    [ "id", `Int 1
                    ; ( "payload"
                      , `String
                          (Yojson.Safe.to_string
                             (`Assoc
                                 [ "type", `String "row_event"
                                 ; "payload", `String payload
                                 ])) )
                    ]))
           |> consume;
           wait "native context menu pushes another Detail entry" (fun () ->
             List.assoc "path" (Hashtbl.find props navigator)
             |> Yojson.Safe.Util.to_string
             |> String.split_on_char ','
             |> List.length
             |> ( = ) 2));
         if check_covered_update
         then (
           let unchanged = Option.get (find "text" "Timeline fixture 2") in
           Hashtbl.clear regions;
           Atomic.set publish_block true;
           ignore (W.send (Option.get !client) Service.Get_graph_state);
           wait "covered target receives real Worker change" (fun () ->
             Hashtbl.fold
               (fun _ values count ->
                  if List.assoc_opt "text" values = Some (`String "Updated covered row")
                        ||
                        match List.assoc_opt "payload" values with
                        | Some (`String payload) ->
                          let p = Yojson.Safe.from_string payload in
                          List.mem
                            (Yojson.Safe.Util.member "mode" p)
                            [ `String "detail-text"; `String "bounded-text" ]
                          && Yojson.Safe.Util.member "text" p = `String "Updated covered row"
                        | _ -> false
                  then count + 1
                  else count)
               props
               0
             = 2);
           List.iter
             (fun name ->
                Alcotest.(check int)
                  ("covered update keeps " ^ name ^ " builder idle")
                  0
                  (Option.value (Hashtbl.find_opt regions name) ~default:0))
             [ "root"; "timeline" ];
           Alcotest.(check int)
             "covered data rebuilds one Timeline row"
             1
             (Option.value (Hashtbl.find_opt regions "timeline-row") ~default:0);
           Alcotest.(check int)
             "covered data notifies one indexed row"
             1
             (Option.value (Hashtbl.find_opt regions "timeline-item-notify") ~default:0);
           Alcotest.(check bool)
             "unrelated row node survives covered update"
             true
             (Hashtbl.mem props unchanged);
           Alcotest.(check bool)
             "native List survives covered update"
             true
             (Hashtbl.mem props root_list);
           Hashtbl.clear regions);
         native_event "path-changed" 0;
         native_event "settled" 0;
         Alcotest.(check bool)
           "native Back retains Timeline List identity"
           true
           (Hashtbl.mem props root_list);
         List.iter
           (fun name ->
              Alcotest.(check int)
                ("push/pop does not rebuild " ^ name)
                0
                (Option.value (Hashtbl.find_opt regions name) ~default:0))
           [ "root"; "timeline"; "timeline-row" ]);
       (* Media reducers own transfer state, but cannot reproduce the defect:
          only the public mounted Application owns LUI subscription invalidation.
          Drive actual Worker notices/completions and native appearance events. *)
       if check_copy
       then (
         (* The pure Copy owner verifies traversal. This boundary verifies the
            mounted menus and Worker cancellation ownership before clipboard I/O. *)
         let send_copy list row =
           let payload =
             Yojson.Safe.to_string (`Assoc [ "key", `String "copy"; "row", `String row ])
           in
           let action =
             Yojson.Safe.to_string
               (`Assoc [ "type", `String "row_event"; "payload", `String payload ])
           in
           hooks.extension_event
             list
             "event"
             (Yojson.Safe.to_string (`Assoc [ "id", `Int 1; "payload", `String action ]))
           |> consume
         in
         let check_copy_text list row text =
           clipboard_requests := [];
           send_copy list row;
           wait "menu reaches clipboard" (fun () -> !clipboard_requests <> []);
           let request = List.hd !clipboard_requests in
           let json =
             Bytes.sub_string request 32 (Bytes.length request - 32)
             |> Yojson.Safe.from_string
           in
           Alcotest.(check string)
             "copied menu target"
             text
             Yojson.Safe.Util.(json |> member "text" |> to_string)
         in
         let list = Option.get (find "_extension" "journal-list") in
         let row = "block:" ^ G.Uuid.to_string (uuid 2) in
         check_copy_text list row "Timeline fixture 1";
         clipboard_requests := [];
         send_copy list row;
         send_copy list row;
         wait "replacement ignores cancelled request response" (fun () ->
           !clipboard_requests <> []);
         dispatch
           (Lui_protocol.Press (Option.get (find "accessibility-label" "Favorites")));
         load_all_favorites "copy Favorites loaded";
         clipboard_requests := [];
         let favorite_row_node=Option.get (find "accessibility-identifier"
           ("favorite-open:" ^ G.Uuid.to_string (uuid 1001))) in
         let rec below id node = id=node || match Hashtbl.find_opt parents node with
           | Some parent->below id parent | None->false in
         let copy=Option.get (find ~accept:(below favorite_row_node) "text" "Copy") in
         dispatch (Lui_protocol.Press copy);
         wait "LUI Favorites menu reaches clipboard" (fun () -> !clipboard_requests<>[]);
         let page_row=Option.get (find "accessibility-identifier"
           ("favorite-open:" ^ G.Uuid.to_string (uuid 1000))) in
         Alcotest.(check bool) "page favorite has no Copy menu" false
           (Option.is_some (find ~accept:(below page_row) "text" "Copy"));
         dispatch
           (Lui_protocol.Press (Option.get (find "accessibility-label" "Journals")));
         let root_list = Option.get (find "_extension" "journal-list") in
         Atomic.set detail_fixture true;
         let label = Option.get (find "text" "Timeline fixture 0") in
         dispatch (Lui_protocol.Press (ancestor_property label "press-enabled"));
         wait "copy Detail loaded" (fun () ->
           Option.is_some
             (find
                "accessibility-identifier"
                ("detail-block:" ^ G.Uuid.to_string (uuid 1))));
         (* Pure routes retain navigation but do not issue Application's
            ordinary Open block read; inspect that public worker boundary. *)
         Alcotest.(check (option int)) "ordinary Detail first-page budget"
           (Some 128) (Atomic.get detail_initial_limit);
         let detail_list =
           Hashtbl.fold
             (fun id values found ->
                if
                  id <> root_list
                  && List.assoc_opt "_extension" values = Some (`String "journal-list")
                then Some id
                else found)
             props
             None
           |> Option.get
         in
         check_copy_text detail_list row "Timeline fixture 1";
         (* Copy's pure reducer cannot reproduce the Detail toolbar binding or
            host acknowledgement feedback. Exercise their public app boundary. *)
         let current_root = ref (uuid 1) in
         let rec under owner id =
           id = owner || match Hashtbl.find_opt parents id with
           | None -> false | Some parent -> under owner parent
         in
         let rec chrome mode id =
           let values = Option.value (Hashtbl.find_opt props id) ~default:[] in
           match List.assoc_opt "payload" values with
           | Some (`String payload) when Yojson.Safe.Util.member "mode" (Yojson.Safe.from_string payload) = `String mode -> id
           | _ -> chrome mode (Hashtbl.find parents id)
         in
         let detail_body root = Hashtbl.fold (fun id values found ->
           match List.assoc_opt "_extension" values, List.assoc_opt "payload" values with
           | Some (`String "journal-list"), Some (`String payload) ->
             let open Yojson.Safe.Util in
             let p = Yojson.Safe.from_string payload in
             (match p |> member "sections" |> to_list with
              | section :: _ -> (match section |> member "rows" |> to_list with
                | row :: _ when member "style" p = `String "detail"
                  && member "key" row = `String ("block:" ^ G.Uuid.to_string root) -> Some id
                | _ -> found)
              | _ -> found)
           | _ -> found) props None in
         let current_body () =
           Option.get (detail_body !current_root)
         in
         let find_current key value =
           let rec owning_inset id =
             let values = Option.value (Hashtbl.find_opt props id) ~default:[] in
             if List.assoc_opt "edge" values = Some (`String "bottom")
             then id else owning_inset (Hashtbl.find parents id)
           in
           let owner = owning_inset (current_body ()) in
           Hashtbl.fold (fun id values found ->
             if under owner id && List.assoc_opt key values = Some (`String value)
             then Some id else found) props None
         in
         let header_copy () =
           let owner = chrome "detail" (current_body ()) in
           let trigger = Option.get (Hashtbl.fold (fun id values found ->
             if under owner id && List.assoc_opt "accessibility-label" values = Some (`String "Block options")
             then Some id else found) props None) in
           let under id = under trigger id in
           let entries = Hashtbl.fold (fun id values acc ->
             if under id && List.mem_assoc "text" values then
               (id, List.assoc "text" values) :: acc else acc) props [] in
           Alcotest.(check int) "Detail menu has only Copy" 1 (List.length entries);
           match entries with
           | [ (id, `String "Copy") ] -> id
           | _ -> Alcotest.fail "Detail menu must contain only Copy"
         in
         let respond_copy copied =
           let json = Yojson.Safe.to_string (`Assoc [ "copied", `Bool copied ]) in
           let response = Bytes.make (32 + String.length json) '\000' in
           Bytes.blit_string "LJP2" 0 response 0 4;
           Bytes.set_uint16_le response 4 2;
           Bytes.set_uint16_le response 6 29;
           Bytes.set_int32_le response 24 (Int32.of_int (String.length json));
           Bytes.blit_string json 0 response 32 (String.length json);
           hooks.platform_response (Bytes.to_string response)
         in
         let copy_header expected =
           clipboard_requests := [];
           dispatch (Lui_protocol.Press (header_copy ()));
           wait "Detail Copy progress" (fun () ->
             Option.is_some (find_current "text" "Copying block and descendants…"));
           wait "Detail header reaches shared clipboard chain" (fun () -> !clipboard_requests <> []);
           let request = List.hd !clipboard_requests in
           let json = Bytes.sub_string request 32 (Bytes.length request - 32) |> Yojson.Safe.from_string in
           Alcotest.(check string) "header targets current Detail subtree" expected
             Yojson.Safe.Util.(json |> member "text" |> to_string)
         in
         copy_header "Timeline fixture 0\n  - Timeline fixture 1";
         respond_copy true;
         wait "Detail Copy success after host acknowledgement" (fun () ->
           Option.is_some (find_current "text" "Copied block and descendants"));
         copy_header "Timeline fixture 0\n  - Timeline fixture 1";
         let retired_copy = header_copy () in
         let payload = Yojson.Safe.to_string (`Assoc [ "key", `String "open"; "row", `String row ]) in
         let action = Yojson.Safe.to_string (`Assoc [ "type", `String "row_event"; "payload", `String payload ]) in
         hooks.extension_event detail_list "event"
           (Yojson.Safe.to_string (`Assoc [ "id", `Int 1; "payload", `String action ])) |> consume;
         wait "nested Detail has its own root" (fun () ->
           Option.is_some (detail_body (uuid 2)));
         current_root := uuid 2;
         respond_copy false;
         for _ = 1 to 5 do hooks.pump () |> consume done;
         Alcotest.(check bool) "old failure never becomes a new Detail/global notice" true
           (Option.is_none (find "text" "Copy failed"));
         Alcotest.(check bool) "old success is scoped to its Detail" true
           (Option.is_none (find_current "text" "Copied block and descendants"));
         clipboard_requests := [];
         dispatch (Lui_protocol.Press retired_copy);
         for _ = 1 to 5 do hooks.pump () |> consume done;
         Alcotest.(check int) "retired toolbar cannot copy previous root" 0 (List.length !clipboard_requests);
         copy_header "Timeline fixture 1";
         respond_copy false;
         wait "Detail Copy failure remains visible" (fun () ->
           Option.is_some (find_current "text" "Copy failed: Clipboard write was not acknowledged."));
         copy_header "Timeline fixture 1";
         respond_copy true;
         wait "retry succeeds without the previous failure" (fun () ->
           Option.is_some (find_current "text" "Copied block and descendants")
           && Option.is_none (find_current "text" "Copy failed: Clipboard write was not acknowledged.")))
       else if Option.is_some media_rows
       then (
         let count = Option.get media_rows in
         let all key value =
           Hashtbl.fold
             (fun id values ids ->
                if List.assoc_opt key values = Some (`String value)
                   || (key = "text" && match List.assoc_opt "payload" values with
                          | Some (`String payload) ->
                            let p = Yojson.Safe.from_string payload in
                            List.mem
                              (Yojson.Safe.Util.member "mode" p)
                              [ `String "detail-text"; `String "bounded-text" ]
                         && Yojson.Safe.Util.member "text" p = `String value
                       | _ -> false)
                then id :: ids
                else ids)
             props
             []
         in
         let settle () =
           for _ = 1 to 12 do
             hooks.pump () |> consume;
             Unix.sleepf 0.001
           done
         in
         let list_node = Option.get (find "_extension" "journal-list") in
         for n = 0 to count - 1 do
           let label =
             Option.get (find "text" (Printf.sprintf "Timeline fixture %d" n))
           in
           dispatch (Lui_protocol.Appear (ancestor_property label "appear-enabled"));
           wait "metadata delivered to mounted root" (fun () ->
             List.mem (List.nth roots n) (Atomic.get queried));
           settle ()
         done;
         let waiting = all "text" "Waiting for file" in
         Alcotest.(check int)
           "one mounted asset slot per root"
           count
           (List.length waiting);
         (* Show one descriptor (two independent consumers for a shared asset). *)
         let shown_count = if shared_media then 2 else 1 in
         let rec within node ancestor =
           node = ancestor
           ||
           match Hashtbl.find_opt parents node with
           | None -> false
           | Some parent -> within parent ancestor
         in
         let rec waiting_for_row node =
           match
             List.find_opt (fun id -> within id node) (all "text" "Waiting for file")
           with
           | Some id -> id
           | None -> waiting_for_row (Hashtbl.find parents node)
         in
         for n = 0 to shown_count - 1 do
           let title =
             Option.get (find "text" (Printf.sprintf "Timeline fixture %d" n))
           in
           let id = waiting_for_row title in
           dispatch (Lui_protocol.Appear (ancestor_property id "appear-enabled"));
           wait "foreground demand delivered" (fun () ->
             List.length (Atomic.get demands) = n + 1);
           settle ()
         done;
         settle ();
         let title_ids =
           List.init count (fun n ->
             let title = Printf.sprintf "Timeline fixture %d" n in
             title, Option.get (find "text" title))
         in
         let publish availability =
           let delivered = Atomic.get media_delivered in
           Atomic.set
             media_notices
             (List.map
                (fun (consumer, asset) ->
                   Service.Asset_availability { consumer; asset; availability })
                (Atomic.get demands));
           ignore (W.send (Option.get !client) Service.Get_graph_state);
           wait "public media notices delivered" (fun () ->
             Atomic.get media_delivered = delivered + shown_count)
         in
         let check_isolated label =
           List.iter
             (fun name ->
                Alcotest.(check int)
                  (label ^ " " ^ name)
                  0
                  (Option.value (Hashtbl.find_opt regions name) ~default:0))
             [ "root"; "timeline"; "timeline-row" ];
           Alcotest.(check bool)
             (label ^ " retained native list")
             true
             (Hashtbl.mem props list_node);
           List.iter
             (fun (title, id) ->
                Alcotest.(check bool)
                  (label ^ " retains row text " ^ title)
                  true
                  (let values = Hashtbl.find props id in
                   List.assoc_opt "text" values = Some (`String title)
                   || match List.assoc_opt "payload" values with
                      | Some (`String payload) ->
                        Yojson.Safe.Util.member "text" (Yojson.Safe.from_string payload) = `String title
                      | _ -> false))
             title_ids
         in
         let check_media_counts label changed =
           List.iter
             (fun (name, expected) ->
                Alcotest.(check int)
                  (label ^ " " ^ name)
                  expected
                  (Option.value (Hashtbl.find_opt regions name) ~default:0))
             [ "media-structure-compare", changed
             ; "media-structure-notify", 0
             ; "media-structure-build", 0
             ; "media-item-compare", changed
             ; "media-item-notify", changed
             ; "media-item-build", changed
             ];
           check_isolated label
         in
         let record label =
           Printf.printf "MEDIA_PHASE N=%d shared=%b %s" count shared_media label;
           Hashtbl.to_seq regions
           |> List.of_seq
           |> List.sort compare
           |> List.iter (fun (name, n) -> Printf.printf " %s=%d" name n);
           Printf.printf "\n%!"
         in
         match media_navigation with
         | Some scenario ->
           let native_range first last =
             hooks.extension_event
               list_node
               "event"
               (Yojson.Safe.to_string
                  (`Assoc
                      [ "id", `Int 1
                      ; ( "payload"
                        , `String
                            (Yojson.Safe.to_string
                               (`Assoc
                                   [ "type", `String "visible_range"
                                   ; "first", `Int first
                                   ; "last", `Int last
                                   ])) )
                      ]))
             |> consume;
             settle ()
           in
           let native_path length =
             let navigator = Option.get (find "_extension" "navigation-stack") in
             let payload () =
               let revision =
                 List.assoc "revision" (Hashtbl.find props navigator)
                 |> Yojson.Safe.Util.to_int
               in
               Yojson.Safe.to_string
                 (`Assoc [ "revision", `Int revision; "length", `Int length ])
             in
             hooks.extension_event navigator "path-changed" (payload ()) |> consume;
             (* Swift completes with the latest owner reply revision, since
                path-changed synchronously publishes a new authoritative path. *)
             hooks.extension_event navigator "settled" (payload ()) |> consume;
             settle ()
           in
           let previews () = all "_extension" "journal-image-preview" in
           let preview_has_path id =
             let open Yojson.Safe.Util in
             match List.assoc_opt "payload" (Hashtbl.find props id) with
             | Some (`String json) ->
               Yojson.Safe.from_string json
               |> member "paths"
               |> to_list
               |> List.mem (`String "/tmp/targeted-media.png")
             | _ -> false
           in
           let files () =
             all "path" "/tmp/targeted-media.png"
             @ List.filter preview_has_path (previews ())
           in
           let dismiss_preview node =
             hooks.extension_event
               node
               "event"
               (Yojson.Safe.to_string
                  (`Assoc [ "id", `Int 1; "payload", `String {|{"type":"dismiss"}|} ]))
             |> consume
           in
           let push () =
             if
               List.mem
                 scenario
                 [ `Detail_range_exit
                 ; `Detail_range_reentry
                 ; `Detail_shared
                 ; `Detail_pending
                 ; `Detail_offscreen
                 ; `Detail_graph
                 ; `Detail_preview
                 ]
             then Atomic.set detail_fixture true;
             let title = List.assoc "Timeline fixture 0" title_ids in
             dispatch (Lui_protocol.Press (ancestor_property title "press-enabled"));
             settle ()
           in
           let appear_with_ancestors id boundary =
             let rec chain id result =
               if id = boundary
               then result
               else (
                 let result =
                   if
                     List.assoc_opt
                       "appear-enabled"
                       (Option.value (Hashtbl.find_opt props id) ~default:[])
                     = Some (`Bool true)
                   then id :: result
                   else result
                 in
                 match Hashtbl.find_opt parents id with
                 | None -> result
                 | Some parent -> chain parent result)
             in
             let nodes = chain id [] in
             let nodes = if scenario = `Leaf_first then List.rev nodes else nodes in
             List.iter (fun node -> dispatch (Lui_protocol.Appear node)) nodes
           in
           let appear_detail () =
             let detail_list =
               List.find (fun id -> id <> list_node) (all "_extension" "journal-list")
             in
             (* Public native appearance of the retained Detail media slot. *)
             List.iter
               (fun id ->
                  if within id detail_list then appear_with_ancestors id detail_list)
               (files ());
             settle ()
           in
           publish (Ready "fixture-ready");
           wait "Acquire has entered" (fun () -> Atomic.get acquire_entered >= 1);
           if scenario = `Opening
           then (
             push ();
             (* Native List ranges precede navigation callbacks on real Back. *)
             native_range 0 (count + 1);
             native_path 0);
           let stale_acquire = scenario = `Late || scenario = `Late_graph in
           if scenario = `Late then native_range 2 (count + 1);
           if scenario = `Late_graph
           then (
             push ();
             W.Session_context.emit
               (Option.get !worker_context)
               ~topic:Service.graph_state_topic
               (Service.Graph_state_changed
                  { generation = 2
                  ; graph_id = Some (uuid 900)
                  ; phase = Graph_open
                  ; error = None
                  });
             settle ());
           Atomic.set acquire_release true;
           if stale_acquire
           then (
             wait "retired acquire releases returned file" (fun () ->
               Atomic.get released_files = 1);
             Alcotest.(check int)
               "retired acquire cannot publish path"
               0
               (List.length (files ())))
           else (
             wait "navigation retains Acquire completion" (fun () ->
               List.length (files ()) = shown_count);
             let ready_ids = files () in
             let acquired = Atomic.get acquire_entered in
             let assert_ready label =
               Alcotest.(check int)
                 (label ^ " releases no retained file")
                 0
                 (Atomic.get released_files);
               Alcotest.(check int)
                 (label ^ " releases no retained demand")
                 0
                 (Atomic.get released_demands);
               Alcotest.(check int)
                 (label ^ " does not reacquire")
                 acquired
                 (Atomic.get acquire_entered);
               List.iter
                 (fun id ->
                    Alcotest.(check bool)
                      (label ^ " preserves original ready leaf")
                      true
                      (Hashtbl.mem props id))
                 ready_ids;
               check_isolated label
             in
             Hashtbl.clear regions;
             assert_ready "Acquire across navigation";
             match scenario with
             | `Ready | `Opening ->
               for _ = 1 to 3 do
                 push ();
                 assert_ready "covered ready Timeline";
                 native_range 0 (count + 1);
                 native_path 0;
                 assert_ready "natural Back without appearance replay"
               done
             | `Detail_range_exit
             | `Detail_range_reentry
             | `Detail_shared
             | `Detail_pending
             | `Detail_offscreen
             | `Detail_graph
             | `Detail_preview ->
               push ();
               wait "Detail with child mounts" (fun () ->
                 List.length (all "_extension" "journal-list") = 2);
               appear_detail ();
               let detail_list =
                 List.find (fun id -> id <> list_node) (all "_extension" "journal-list")
               in
               let child_label () =
                 List.find
                   (fun id -> within id detail_list)
                   (all "text" "Timeline fixture 1")
               in
               if scenario = `Detail_shared
               then (
                 let timeline_child =
                   List.find
                     (fun id -> within id list_node)
                     (all "text" "Timeline fixture 1")
                 in
                 appear_with_ancestors (waiting_for_row timeline_child) list_node);
               let hidden = waiting_for_row (child_label ()) in
               appear_with_ancestors hidden detail_list;
               wait "child has real demand" (fun () ->
                 List.length (Atomic.get demands) = 2);
               let consumer, asset =
                 List.find
                   (fun (_, asset) -> not (G.Uuid.equal asset (uuid 20000)))
                   (Atomic.get demands)
               in
               let child_ready () =
                 W.Session_context.emit
                   (Option.get !worker_context)
                   ~topic:Service.asset_topic
                   (Service.Asset_notice
                      ( scope
                      , Service.Asset_availability
                          { consumer; asset; availability = Ready "child-ready" } ))
               in
               let child_files () =
                 List.filter
                   (fun id -> within id detail_list)
                   (all "accessibility-identifier" ("journal-media:" ^ consumer))
               in
               if scenario = `Detail_pending then Atomic.set acquire_release false;
               child_ready ();
               wait "child Acquire entered" (fun () -> Atomic.get acquire_entered = 2);
               if scenario <> `Detail_pending
               then
                 wait "child Ready acquired" (fun () -> List.length (child_files ()) = 1);
               let old_leaf =
                 if scenario = `Detail_pending then hidden else List.hd (child_files ())
               in
               if scenario = `Detail_preview
               then (
                 dispatch (Lui_protocol.Press old_leaf);
                 settle ();
                 Alcotest.(check int) "child preview opens" 1 (List.length (previews ())));
               native_range 2 (count + 1);
               let before_released = Atomic.get released_files in
               let before_demands = Atomic.get released_demands in
               let detail_event payload =
                 hooks.extension_event
                   detail_list
                   "event"
                   (Yojson.Safe.to_string
                      (`Assoc
                          [ "id", `Int 1
                          ; "payload", `String (Yojson.Safe.to_string payload)
                          ]))
                 |> consume;
                 settle ()
               in
               let child_range visible =
                 detail_event
                   (`Assoc
                       [ "type", `String "visible_range"
                       ; "first", `Int 0
                       ; "last", `Int (if visible then 2 else 1)
                       ])
               in
               child_range false;
               if scenario = `Detail_preview
               then (
                 Alcotest.(check int) "offscreen preview retains its child lease"
                   0 (Atomic.get released_files - before_released);
                 Alcotest.(check int) "offscreen child keeps its open preview"
                   1 (List.length (previews ()));
                 dismiss_preview (List.hd (previews ()));
                 settle ());
               if scenario = `Detail_pending
               then (
                 Alcotest.(check int)
                   "pending retired child cannot publish a file"
                   2
                   (List.length (files ()));
                 Atomic.set acquire_release true);
               if scenario = `Detail_shared
               then (
                 Alcotest.(check int)
                   "Timeline owner retains shared child lease"
                   0
                   (Atomic.get released_files - before_released);
                 Alcotest.(check bool)
                   "shared asset stays Ready in Timeline"
                   true
                   (List.exists
                      (fun id -> within id list_node)
                      (all "accessibility-identifier" ("journal-media:" ^ consumer)));
                 native_range 3 (count + 1));
               wait "retired child releases last file" (fun () ->
                 Atomic.get released_files - before_released = 1);
               Alcotest.(check int)
                 "retired child releases last demand once"
                 1
                 (Atomic.get released_demands - before_demands);
                   Printf.printf
                     "REVIEW_RANGE_EXIT acquired=%d released=%d range_release_delta=%d \
                      files=%d\n\
                      %!"
                 (Atomic.get acquire_entered)
                 (Atomic.get released_files)
                 (Atomic.get released_files - before_released)
                 (List.length (files ()));
               dispatch (Lui_protocol.Appear old_leaf);
               child_ready ();
               settle ();
               Alcotest.(check int)
                 "removed leaf and late Ready cannot reacquire"
                 2
                 (Atomic.get acquire_entered);
               if scenario = `Detail_preview
               then
                 Alcotest.(check int)
                   "dismissed offscreen child removes preview path"
                   0
                   (List.length (previews ()));
               if scenario = `Detail_range_reentry
               then (
                 child_range true;
                 wait "visible child remounts" (fun () ->
                   all "text" "Timeline fixture 1"
                   |> List.exists (fun id -> within id detail_list));
                 appear_with_ancestors (waiting_for_row (child_label ())) detail_list;
                 wait "visible child sends one new demand" (fun () ->
                   List.length (Atomic.get demands) = 3);
                 child_ready ();
                 wait "visible child acquires fresh lease" (fun () ->
                   Atomic.get acquire_entered = 3 && List.length (child_files ()) = 1);
                 Alcotest.(check bool)
                   "visible child gets a fresh native leaf"
                   true
                   (List.hd (child_files ()) <> old_leaf);
                 child_range false;
                 wait "second range exit releases fresh child lease" (fun () ->
                   Atomic.get released_files = before_released + 2));
               if scenario = `Detail_graph
               then (
                 Atomic.set graph_generation 2;
                 ignore (W.send (Option.get !client) Service.Get_graph_state);
                 wait "graph invalidation removes all old paths" (fun () -> files () = []);
                 wait "graph invalidation releases remaining root" (fun () ->
                   Atomic.get released_files = 2);
                 child_ready ();
                 settle ();
                 Alcotest.(check int)
                   "old child notice cannot cross graph"
                   2
                   (Atomic.get acquire_entered))
               else (
                 native_path 0;
                 wait "entry retirement releases remaining root" (fun () ->
                   Atomic.get released_files = if scenario = `Detail_range_reentry then 3 else 2))
             | `Preview_offscreen
             | `Preview_navigation
             | `Preview_detail_pop
             | `Preview_graph
             | `Preview_invalidated
             | `Preview_repeat
             | `Preview_replaced
             | `Preview_duplicate ->
               let image =
                 if scenario = `Preview_detail_pop
                 then (
                   push ();
                   appear_detail ();
                   let detail_list =
                     List.find
                       (fun id -> id <> list_node)
                       (all "_extension" "journal-list")
                   in
                   List.find (fun id -> within id detail_list) (files ()))
                 else List.hd (files ())
               in
               let open_preview () =
                 dispatch (Lui_protocol.Press image);
                 settle ();
                 List.hd (previews ())
               in
               let preview = open_preview () in
               Alcotest.(check bool)
                 "preview publishes acquired path"
                 true
                 (preview_has_path preview);
               if scenario = `Preview_repeat
               then
                 for _ = 1 to 3 do
                   dismiss_preview (List.hd (previews ()));
                   settle ();
                   Alcotest.(check int)
                     "closing preview keeps visible row file"
                     0
                     (Atomic.get released_files);
                   ignore (open_preview ())
                 done;
               if scenario = `Preview_navigation
               then (
                 push ();
                 appear_detail ());
               if scenario = `Preview_invalidated
               then (
                 publish
                   (Service.Asset.Failed
                      { failure = Network; attempts = 1; retry_scheduled = false });
                 settle ();
                 Alcotest.(check bool)
                   "late Failed retains successful preview URL"
                   true
                   (List.mem preview (previews ()) && preview_has_path preview);
                 Alcotest.(check int)
                   "late Failed releases no successful file"
                   0
                   (Atomic.get released_files);
                 Alcotest.(check int)
                   "late Failed releases no preview demand"
                   0
                   (Atomic.get released_demands);
                 Alcotest.(check int)
                   "late Failed cannot reacquire successful file"
                   acquired
                   (Atomic.get acquire_entered))
               else (
                 native_range 2 (count + 1);
                 settle ();
                 Alcotest.(check int)
                   "open preview retains valid file reference"
                   0
                   (Atomic.get released_files);
                 Alcotest.(check int)
                   "open preview retains its demand"
                   0
                   (Atomic.get released_demands);
                 Alcotest.(check int)
                   "preview reuses current acquired file"
                   acquired
                   (Atomic.get acquire_entered));
               if scenario = `Preview_duplicate
               then (
                 ignore (open_preview ());
                 Alcotest.(check int)
                   "repeated offscreen selection retains its lease"
                   0
                   (Atomic.get released_files);
                 Alcotest.(check bool)
                   "repeated selection publishes valid preview"
                   true
                   (List.for_all preview_has_path (previews ())));
               if scenario = `Preview_replaced
               then (
                 let reads = List.length (Atomic.get queried) in
                 Atomic.set changes_acknowledged false;
                 Atomic.set media_checksum 'b';
                 Atomic.set media_metadata_changed true;
                 W.Session_context.emit
                   (Option.get !worker_context)
                   ~topic:Service.invalidation_topic
                   (Service.Graph_push
                      (P.V2_changes_available
                         { api_version = 2; generation = "g"; through = "p2" }));
                 wait "metadata changes acknowledged" (fun () ->
                   Atomic.get changes_acknowledged);
                 settle ();
                 Alcotest.(check bool)
                   "same UUID metadata retains preview URL"
                   true
                   (List.mem preview (previews ()) && preview_has_path preview);
                 Alcotest.(check int)
                   "metadata window does not read successful File again"
                   reads
                   (List.length (Atomic.get queried));
                 Alcotest.(check int)
                   "metadata window releases no file"
                   0
                   (Atomic.get released_files);
                 Alcotest.(check int)
                   "metadata window releases no demand"
                   0
                   (Atomic.get released_demands);
                 Alcotest.(check int)
                   "metadata window cannot reacquire successful file"
                   acquired
                   (Atomic.get acquire_entered));
               if scenario = `Preview_graph
               then (
                 Atomic.set graph_generation 2;
                 ignore (W.send (Option.get !client) Service.Get_graph_state);
                 wait "graph retirement clears preview and row paths" (fun () ->
                   files () = []))
               else if scenario = `Preview_detail_pop
               then native_path 0
               else (
                 let current = previews () in
                 List.iter (fun node -> dismiss_preview node) current;
                 settle ();
                 if scenario = `Preview_navigation
                 then (
                   Alcotest.(check int)
                     "closing preview retains Detail owner"
                     0
                     (Atomic.get released_files);
                   native_path 0);
                 if scenario = `Preview_invalidated then native_range 2 (count + 1));
               wait "closing last preview releases file" (fun () ->
                 Atomic.get released_files = 1);
               Alcotest.(check int)
                 "closed preview leaves no path"
                 0
                 (List.length (files ()));
               Alcotest.(check int)
                 "closed preview releases demand once"
                 1
                 (Atomic.get released_demands);
               dismiss_preview preview;
               publish (Ready "fixture-ready");
               settle ();
               Alcotest.(check int)
                 "duplicate dismissal and stale Ready cannot reacquire"
                 acquired
                 (Atomic.get acquire_entered);
               Alcotest.(check int)
                 "duplicate dismissal releases exactly once"
                 1
                 (Atomic.get released_files)
             | `Restore_early ->
               push ();
               wait "Detail mounts" (fun () ->
                 List.length (all "_extension" "journal-list") = 2);
               appear_detail ();
               native_range 2 (count + 1);
               Alcotest.(check int)
                 "Detail retains root after Timeline offscreen"
                 0
                 (Atomic.get released_files);
               (* On return, root range/appearance arrive before path-changed.
                  Root and leaf are real retained Timeline nodes, not forged events. *)
               native_range 0 (count + 1);
               List.iter
                 (fun id ->
                    if within id list_node then appear_with_ancestors id list_node)
                 (files ());
               settle ();
               native_path 0;
               Printf.printf
                 "REVIEW_EARLY_RETURN releases=%d demands_released=%d files=%d\n%!"
                 (Atomic.get released_files)
                 (Atomic.get released_demands)
                 (List.length (files ()));
               Alcotest.(check int)
                 "visible returning Timeline retains acquired lease"
                 0
                 (Atomic.get released_files);
               Alcotest.(check int)
                 "visible returning Timeline stays Ready"
                 shown_count
                 (List.length (files ()));
               Alcotest.(check int)
                 "returning Timeline preserves its demand"
                 0
                 (Atomic.get released_demands);
               Alcotest.(check int)
                 "returning Timeline does not reacquire"
                 acquired
                 (Atomic.get acquire_entered);
               List.iter
                 (fun id ->
                    Alcotest.(check bool)
                      "returning Timeline keeps original ready leaf"
                      true
                      (Hashtbl.mem props id))
                 ready_ids
             | `Owners | `Leaf_first ->
               push ();
               wait "Detail mounts" (fun () ->
                 List.length (all "_extension" "journal-list") = 2);
               appear_detail ();
               let detail_list =
                 List.find (fun id -> id <> list_node) (all "_extension" "journal-list")
               in
               hooks.extension_event
                 detail_list
                 "event"
                 (Yojson.Safe.to_string
                    (`Assoc
                        [ "id", `Int 1
                        ; ( "payload"
                          , `String
                              (Yojson.Safe.to_string
                                 (`Assoc
                                     [ "type", `String "row_event"
                                     ; ( "payload"
                                       , `String
                                           (Yojson.Safe.to_string
                                              (`Assoc
                                                  [ "key", `String "open"
                                                  ; ( "row"
                                                    , `String
                                                        ("block:"
                                                         ^ G.Uuid.to_string (uuid 1)) )
                                                  ])) )
                                     ])) )
                        ]))
               |> consume;
               wait "same block has two distinct entries" (fun () ->
                 List.length (all "_extension" "journal-list") = 3);
               let upper =
                 List.find
                   (fun id -> id <> list_node && id <> detail_list)
                   (all "_extension" "journal-list")
               in
               List.iter
                 (fun id -> if within id upper then appear_with_ancestors id upper)
                 (files ());
               settle ();
               native_range 2 (count + 1);
               Alcotest.(check int)
                 "covered entries keep one shared controller acquire"
                 acquired
                 (Atomic.get acquire_entered);
               Alcotest.(check int)
                 "root offscreen cannot release live Detail lease"
                 0
                 (Atomic.get released_files);
               native_path 1;
               Alcotest.(check int)
                 "one retired entry preserves other Detail lease"
                 0
                 (Atomic.get released_files);
               native_path 0;
               wait "last presentation releases shared root lease" (fun () ->
                 Atomic.get released_files = 1);
               Alcotest.(check int)
                 "last owner releases one demand"
                 1
                 (Atomic.get released_demands);
               Alcotest.(check int) "released path is absent" 0 (List.length (files ()))
             | `Offscreen | `Shared ->
               native_range 2 (count + 1);
               wait "true offscreen releases exactly one file" (fun () ->
                 Atomic.get released_files = 1);
               Alcotest.(check int)
                 "true offscreen releases one consumer"
                 1
                 (Atomic.get released_demands);
               Alcotest.(check int)
                 "other shared-root consumer survives"
                 (shown_count - 1)
                 (List.length (files ()));
               publish (Ready "fixture-ready");
               settle ();
               Alcotest.(check int)
                 "old offscreen Ready cannot reacquire"
                 acquired
                 (Atomic.get acquire_entered)
             | `Late | `Late_graph -> assert false
             | `Disposed ->
               ignore (hooks.dispose ());
               Logseq_db_worker_lui.Journal_worker_runtime.stop (Option.get !client);
               Alcotest.(check bool)
                 "disposing closes Worker resource owner"
                 true
                 (Atomic.get shutdown_called);
               Alcotest.(check int) "disposing removes native root" 0 (hooks.root_node ())
             | `Graph ->
               push ();
               Atomic.set graph_generation 2;
               ignore (W.send (Option.get !client) Service.Get_graph_state);
               wait "graph switch releases all retained leases" (fun () ->
                 Atomic.get released_files = shown_count);
               wait "graph switch removes old paths" (fun () -> files () = []);
               publish (Ready "fixture-ready");
               settle ();
               Alcotest.(check int)
                 "old graph Ready cannot reacquire"
                 acquired
                 (Atomic.get acquire_entered))
         | None ->
           Hashtbl.clear regions;
           publish
             (Service.Asset.Failed
                { failure = Network; attempts = 1; retry_scheduled = false });
           settle ();
           wait "Failed updates only the demanded slots" (fun () ->
             List.length (all "text" "Unable to download file") = shown_count);
           settle ();
           record "failed";
           check_media_counts "Failed" shown_count;
           (* Retry uses the current UI action and the public Worker command.
            Ready is a separate notice; hold Acquire to observe both phases. *)
           Hashtbl.clear regions;
           let failed = Option.get (find "text" "Unable to download file") in
           let failed_parent = Hashtbl.find parents failed in
           let retry =
             List.find
               (fun id -> Hashtbl.find_opt parents id = Some failed_parent)
               (all "text" "Retry")
           in
           dispatch (Lui_protocol.Press retry);
           wait "Retry sends a real asset retry command" (fun () ->
             Atomic.get retries = 1);
           wait "Retry restores waiting presentation" (fun () ->
             List.length (all "text" "Unable to download file") = shown_count - 1);
           settle ();
           record "retry";
           check_media_counts "Retry" 1;
           Hashtbl.clear regions;
           publish (Ready "fixture-ready");
           wait "Ready enters real Acquire before completion" (fun () ->
             Atomic.get acquire_entered >= 1
             && List.length (all "text" "Loading") = shown_count);
           settle ();
           record "ready";
           check_media_counts "Ready" shown_count;
           Alcotest.(check int)
             "Acquire held: file is not installed yet"
             0
             (List.length (all "path" "/tmp/targeted-media.png"));
           Hashtbl.clear regions;
           Atomic.set acquire_release true;
           wait "Acquire completion installs file" (fun () ->
             List.length (all "path" "/tmp/targeted-media.png") = shown_count);
           settle ();
           record "acquired";
           check_media_counts "Acquire" shown_count;
           let acquired = Atomic.get acquire_entered in
           Hashtbl.clear regions;
           publish (Ready "fixture-ready");
           settle ();
           record "duplicate";
           check_media_counts "duplicate Ready" 0;
           Alcotest.(check int)
             "duplicate Ready does not reacquire"
             acquired
             (Atomic.get acquire_entered);
           List.iter
             (fun name ->
                Alcotest.(check int)
                  ("duplicate " ^ name)
                  0
                  (Option.value (Hashtbl.find_opt regions name) ~default:0))
             [ "media-structure-notify"
             ; "media-structure-build"
             ; "media-item-notify"
             ; "media-item-build"
             ];
           dispatch
             (Lui_protocol.Press (Option.get (find "accessibility-label" "Favorites")));
           wait "unmount removes acquired images" (fun () ->
             all "path" "/tmp/targeted-media.png" = []);
           Hashtbl.clear regions;
           publish (Ready "fixture-ready");
           settle ();
           Alcotest.(check int)
             "unmounted late Ready cannot recreate images"
             0
             (List.length (all "path" "/tmp/targeted-media.png"));
           Atomic.set graph_generation 2;
           ignore (W.send (Option.get !client) Service.Get_graph_state);
           settle ();
           wait "graph reset releases acquired leases" (fun () ->
             Atomic.get released_files >= shown_count);
           publish (Ready "fixture-ready");
           settle ();
           Alcotest.(check int)
             "old generation notice cannot reacquire"
             acquired
             (Atomic.get acquire_entered))
       else (
         if check_capture_imports
         then (
           (* Application owns the asynchronous import queue; its pure navigation
              reducer cannot observe Worker handler overlap or file release.
              Two Worker lanes make accidental parallel submission observable. *)
           dispatch
             (Lui_protocol.Press (Option.get (find "accessibility-label" "Capture")));
           dispatch (Lui_protocol.Press (Option.get (find "accessibility-label" "Files")));
           let adapter =
             Hashtbl.fold
               (fun id values found ->
                      match
                        ( List.assoc_opt "_extension" values
                        , List.assoc_opt "payload" values )
                  with
                  | Some (`String "journal-asset-import"), Some (`String payload) ->
                    let request =
                      Yojson.Safe.from_string payload |> Yojson.Safe.Util.member "request"
                    in
                    if
                      Yojson.Safe.Util.(member "id" request |> to_int) > 0
                      && Yojson.Safe.Util.member "staged" request = `Bool true
                    then Some id
                    else found
                  | _ -> found)
               props
               None
             |> Option.get
           in
           let request =
             List.assoc "payload" (Hashtbl.find props adapter)
             |> Yojson.Safe.Util.to_string
             |> Yojson.Safe.from_string
             |> Yojson.Safe.Util.member "request"
           in
           let item index title =
             let path = Filename.temp_file "journal-import-" ".txt" in
             staged_paths := !staged_paths @ [ path ];
             `Assoc
               [ "operation", `String (G.Uuid.to_string (uuid (30000 + index)))
               ; "asset", `String (G.Uuid.to_string (uuid (31000 + index)))
               ; "localMutation", `String (G.Uuid.to_string (uuid (32000 + index)))
               ; "metadataMutation", `String (G.Uuid.to_string (uuid (33000 + index)))
               ; "path", `String path
               ; "title", `String title
               ; "type", `String "txt"
               ; "sourceIdentity", `String title
               ]
           in
           let first = item 1 "First attachment" in
           let second = item 2 "Second attachment" in
           let batch =
             `Assoc
               [ "action", `String "picked-batch"
               ; "request", request
               ; "items", `List [ first; second ]
               ]
           in
           hooks.extension_event
             adapter
             "event"
             (Yojson.Safe.to_string
                (`Assoc [ "id", `Int 1; "payload", `String (Yojson.Safe.to_string batch) ]))
           |> consume;
           Alcotest.(check bool)
             "picker batch mounts pending attachment"
             true
             (Option.is_some
                (find
                   "accessibility-identifier"
                   ("composer-attachment:" ^ G.Uuid.to_string (uuid 30001))));
           dispatch (Lui_protocol.Press (Option.get (find "accessibility-label" "Send")));
           wait "first attachment enters actual Worker handler" (fun () ->
             Atomic.get imports_entered <> []);
           Atomic.set import_probe true;
           ignore (W.send (Option.get !client) Service.Get_graph_state);
           wait "second Worker lane reaches ordered request barrier" (fun () ->
             Atomic.get import_probed);
           Alcotest.(check (list string))
             "second import waits for first terminal response"
             [ "First attachment" ]
             (Atomic.get imports_entered);
           Alcotest.(check bool)
             "in-flight and queued staging files remain owned"
             true
             (List.for_all Sys.file_exists !staged_paths);
           Atomic.set import_release true;
           wait "second attachment continues after first failure" (fun () ->
             Atomic.get imports_finished = 2);
           wait "success releases staging while failure retains retry bytes" (fun () ->
             match !staged_paths with
             | [failed; successful] -> Sys.file_exists failed && not (Sys.file_exists successful)
             | _ -> false);
           settle_worker ();
           Alcotest.(check bool) "durable original remains present" true
             (List.for_all Sys.file_exists (Atomic.get durable_paths));
           (* Application owns async owner admission. A pure navigation/media
              test cannot execute this completion gate; returning a valid receipt
              through the public Worker service reproduces it without injecting
              an incorrect current flag. No upload or network operation exists. *)
           Alcotest.(check int) "Capture retains local lease before any upload" 0
             (Atomic.get released_files);
           Alcotest.(check (list string))
             "batch preserves picker order"
             [ "First attachment"; "Second attachment" ]
             (Atomic.get imports_entered);
           wait "first failure exposes Error info after later success" (fun () ->
             Option.is_some (find "accessibility-label" "Error info"));
           dispatch
             (Lui_protocol.Press (Option.get (find "accessibility-label" "Error info")));
           wait "Error info retains the first batch failure" (fun () ->
             Option.is_some (find "text" "Fixture first attachment failed"));
           dispatch (Lui_protocol.Press (Option.get (find "accessibility-label" "Close")));
           dispatch (Lui_protocol.Press (Option.get (find "accessibility-label" "Dismiss")));
           wait "explicit discard releases failed retry bytes" (fun () ->
             List.for_all (fun path -> not (Sys.file_exists path)) !staged_paths));
         if check_ios_capture
         then (
           dispatch
             (Lui_protocol.Press (Option.get (find "accessibility-label" "Capture")));
           let label = Option.get (find "text" "Timeline fixture 1") in
           dispatch (Lui_protocol.Appear (ancestor_property label "appear-enabled"));
           for _ = 1 to 10 do
             hooks.pump () |> consume;
             Unix.sleepf 0.001
           done;
           Alcotest.(check bool)
             "iOS composer persists after opening and settling"
             true
             (Option.is_some (find "style-class" "composer-input"));
           let editor = Option.get (find "style-class" "composer-input") in
           (* Navigation/Capture reducers cannot express the native keyboard label. *)
           Alcotest.(check (option bool)) "multiline composer requests Return"
             (Some false)
             (Option.map Yojson.Safe.Util.to_bool
                (List.assoc_opt "submit-on-enter" (Hashtbl.find props editor)));
           Hashtbl.clear regions;
           dispatch (Lui_protocol.TextChanged (editor, "iOS persistent draft"));
           for _ = 1 to 10 do
             hooks.pump () |> consume;
             Unix.sleepf 0.001
           done;
           Alcotest.(check bool)
             "iOS edit is delivered and persists"
             true
             (Option.is_some (find "text" "iOS persistent draft"));
           Alcotest.(check int)
             "iOS draft does not rebuild Timeline"
             0
             (Option.value (Hashtbl.find_opt regions "timeline") ~default:0);
           let dismiss =
             Hashtbl.fold
               (fun id values found ->
                  if
                    List.assoc_opt "press-enabled" values = Some (`Bool true)
                    &&
                    match List.assoc_opt "grow" values with
                    | Some (`Int 1) | Some (`Float 1.) -> true
                    | _ -> false
                  then Some id
                  else found)
               props
               None
           in
           dispatch (Lui_protocol.Press (Option.get dismiss));
           wait "iOS collapse removes editor" (fun () ->
             Option.is_none (find "style-class" "composer-input"));
           dispatch
             (Lui_protocol.Press (Option.get (find "accessibility-label" "Capture")));
           for _ = 1 to 10 do
             hooks.pump () |> consume;
             Unix.sleepf 0.001
           done;
           Alcotest.(check bool)
             "iOS reopen retains latest draft"
             true
             (Option.is_some (find "text" "iOS persistent draft"));
           dispatch
             (Lui_protocol.Press (Option.get (find "accessibility-label" "Discard draft"))));
         let connecting () =
           Hashtbl.fold
             (fun _ values found ->
                match
                  List.assoc_opt "_extension" values, List.assoc_opt "payload" values
                with
                | Some (`String "journal-chrome"), Some (`String payload) ->
                  let open Yojson.Safe.Util in
                  let json = Yojson.Safe.from_string payload in
                  found
                  || (member "mode" json = `String "page"
                      && member "connecting" json = `Bool true)
                | _ -> found)
             props
             false
         in
         let publish sync_phase =
           Atomic.set publish_phase (Some sync_phase);
           ignore (W.send (Option.get !client) Service.Get_graph_state)
         in
         if check_chrome
         then (
           Hashtbl.clear regions;
           publish Service.Connecting;
           wait "page chrome observes Connecting" connecting;
           Alcotest.(check int)
             "Connecting does not construct Timeline"
             0
             (Option.value (Hashtbl.find_opt regions "timeline") ~default:0);
           Alcotest.(check int)
             "Connecting does not construct Timeline rows"
             0
             (Option.value (Hashtbl.find_opt regions "timeline-row") ~default:0));
         if check_error_control
         then (
           Alcotest.(check bool)
             "error control initially absent"
             true
             (Option.is_none (find "accessibility-label" "Error info"));
           let list_node = Option.get (find "_extension" "journal-list") in
           Hashtbl.clear regions;
           Atomic.set publish_error (Some (Some "Fixture sync error"));
           ignore (W.send (Option.get !client) Service.Get_graph_state);
           wait "new manager error exposes current Error info action" (fun () ->
             Option.is_some (find "accessibility-label" "Error info"));
           Alcotest.(check int)
             "error control does not construct Timeline"
             0
             (Option.value (Hashtbl.find_opt regions "timeline") ~default:0);
           Alcotest.(check int)
             "chrome error preserves list identity"
             list_node
             (Option.get (find "_extension" "journal-list"));
           dispatch
             (Lui_protocol.Press (Option.get (find "accessibility-label" "Error info")));
           wait "current Error info action opens latest error" (fun () ->
             Option.is_some (find "text" "Fixture sync error"));
           dispatch
             (Lui_protocol.Press
                (Option.get (find "accessibility-identifier" "journal-error-info-close")));
           Hashtbl.clear regions;
           Atomic.set publish_error (Some None);
           ignore (W.send (Option.get !client) Service.Get_graph_state);
           wait "cleared error removes control" (fun () ->
             Option.is_none (find "accessibility-label" "Error info"));
           Alcotest.(check int)
             "clearing error does not construct Timeline"
             0
             (Option.value (Hashtbl.find_opt regions "timeline") ~default:0);
           let issue attention message =
             Atomic.set publish_error (Some message);
             Atomic.set publish_attention (Some attention);
             ignore (W.send (Option.get !client) Service.Get_graph_state);
             settle_worker ();
             for _ = 1 to 10 do hooks.pump () |> consume; Unix.sleepf 0.001 done
           in
           issue (Some Service.Transient_connection) (Some "Synthetic connection timeout");
           Alcotest.(check bool) "transient connection does not expose error control" true
             (Option.is_none (find "accessibility-label" "Error info"));
           Alcotest.(check bool) "transient connection does not show short error notice" true
             (Option.is_none (find "text" "Synthetic connection timeout"));
           issue (Some Service.Requires_attention) (Some "Synthetic integrity failure");
           wait "integrity failure requires attention" (fun () ->
             Option.is_some (find "accessibility-label" "Error info"));
           for n = 1 to 40 do
             issue (Some Service.Transient_connection) (Some ("Synthetic connection reset " ^ string_of_int n))
           done;
           Alcotest.(check bool) "transient repetition cannot hide integrity attention" true
             (Option.is_some (find "accessibility-label" "Error info"));
           dispatch (Lui_protocol.Press (Option.get (find "accessibility-label" "Error info")));
           wait "error details retain serious cause during transient interruption" (fun () ->
             Option.is_some (find "text" "Synthetic integrity failure"));
           dispatch (Lui_protocol.Press (Option.get (find "accessibility-identifier" "journal-error-info-close")));
           issue None None;
           wait "matching recovery clears attention" (fun () ->
             Option.is_none (find "accessibility-label" "Error info"));
           List.iter (fun message ->
             issue (Some Service.Requires_attention) (Some message);
             wait "security/authentication failures remain visible" (fun () ->
               Option.is_some (find "accessibility-label" "Error info"));
             issue None None)
             ["Synthetic TLS certificate failure"; "Synthetic authentication needs sign-in"];
           issue None (Some "Synthetic unknown failure");
           wait "unknown classification is conservative" (fun () ->
             Option.is_some (find "accessibility-label" "Error info"));
           Atomic.set graph_generation 2;
           issue (Some Service.Transient_connection) (Some "Synthetic new-graph timeout");
           wait "new graph does not inherit serious attention" (fun () ->
             Option.is_none (find "accessibility-label" "Error info"));
           Atomic.set graph_generation 3;
           Atomic.set reported_graph_generation (Some 2);
           issue (Some Service.Requires_attention) (Some "Synthetic new-scope integrity failure");
           Atomic.set reported_graph_generation (Some 3);
           ignore (W.send (Option.get !client) Service.Get_graph_state);
           settle_worker ();
           for _ = 1 to 10 do hooks.pump () |> consume; Unix.sleepf 0.001 done;
           wait "manager-first graph replacement preserves its own attention" (fun () ->
             Option.is_some (find "accessibility-label" "Error info"));
           dispatch (Lui_protocol.Press (Option.get (find "accessibility-label" "Error info")));
           wait "manager-first graph notice preserves the new reason" (fun () ->
             Option.is_some (find "text" "Synthetic new-scope integrity failure"));
           dispatch (Lui_protocol.Press (Option.get (find "accessibility-identifier" "journal-error-info-close")));
           Atomic.set graph_generation 4;
           Atomic.set reported_graph_generation None;
           issue None None;
           wait "healthy replacement clears previous graph attention" (fun () ->
             Option.is_none (find "accessibility-label" "Error info"));
           Atomic.set graph_generation 5;
           Atomic.set publish_graph_first true;
           issue (Some Service.Requires_attention) (Some "Synthetic graph-first TLS failure");
           wait "graph-first replacement receives its own attention" (fun () ->
             Option.is_some (find "accessibility-label" "Error info")));

         if check_generation
         then (
           let previous = Option.get (find "_extension" "journal-list") in
           Atomic.set graph_generation 2;
           ignore (W.send (Option.get !client) Service.Get_graph_state);
           wait "graph generation replaces native list identity" (fun () ->
             match find "_extension" "journal-list" with
             | Some current ->
               current <> previous && Option.is_some (find "text" "Timeline fixture 2")
             | None -> false));
         if check_favorite_targets then
           Alcotest.(check bool) "Timeline root retains Capture" true
             (Option.is_some (find "accessibility-identifier" "journal-capture-open"));
         (* A retained draft starts through the Journals opener; Favorites no longer
            has a Capture opener of its own. *)
         if check_draft then
           dispatch (Lui_protocol.Press (Option.get (find "accessibility-label" "Capture")));
         let favorites = Option.get (find "accessibility-label" "Favorites") in
         if check_visible
         then (
           Hashtbl.clear regions;
           let list_node = Option.get (find "_extension" "journal-list") in
           hooks.extension_event
             list_node
             "event"
             {|{"id":1,"payload":"{\"type\":\"visible_range\",\"first\":1,\"last\":2}"}|}
           |> consume;
           Alcotest.(check int)
             "visible demand does not construct Timeline"
             0
             (Option.value (Hashtbl.find_opt regions "timeline") ~default:0));
         Hashtbl.clear regions;
         dispatch (Lui_protocol.Press favorites);
         load_all_favorites "Favorites loaded";
         settle_worker ();
         if check_favorite_targets then (
           Alcotest.(check bool) "Favorites root omits Capture" true
             (Option.is_none (find "accessibility-identifier" "journal-capture-open"));
           let original=Option.get (find "accessibility-identifier" "favorites-native-list") in
           List.iter (fun n ->
             let row=Option.get (find "accessibility-identifier"
               ("favorite-open:" ^ G.Uuid.to_string (uuid (1000+n)))) in
             dispatch (Lui_protocol.Press row);
             wait "Favorites opens exact page or outline target" (fun () ->
               Option.is_some (find "accessibility-identifier"
                 ("detail-block:" ^ G.Uuid.to_string (favorite_target_uuid n))));
             Alcotest.(check bool) "Favorites page and outline detail retain Capture" true
               (Option.is_some (find "accessibility-identifier" "journal-detail-capture-open"));
             let navigator=Option.get (find "_extension" "navigation-stack") in
             List.iter (fun event ->
               let revision=List.assoc "revision" (Hashtbl.find props navigator)
                 |> Yojson.Safe.Util.to_int in
               hooks.extension_event navigator event (Yojson.Safe.to_string
                 (`Assoc ["revision",`Int revision;"length",`Int 0])) |> consume)
               ["path-changed";"settled"];
             wait "native Back returns to Favorites" (fun () ->
               find "accessibility-identifier" "favorites-native-list" = Some original);
             Alcotest.(check bool) "Back to Favorites still omits root Capture" true
               (Option.is_none (find "accessibility-identifier" "journal-capture-open"))) [0;1];
           dispatch (Lui_protocol.Press (Option.get (find "accessibility-label" "Journals")));
           wait "Timeline Capture returns after native Back" (fun () ->
             Option.is_some (find "accessibility-identifier" "journal-capture-open"));
           dispatch (Lui_protocol.Press (Option.get (find "accessibility-label" "Favorites"))));
         if check_chrome
         then (
           Hashtbl.clear regions;
           publish Service.Current;
           wait "Favorites chrome clears Connecting" (fun () -> not (connecting ()));
           Alcotest.(check int)
             "Current does not construct Favorites"
             0
             (Option.value (Hashtbl.find_opt regions "favorites") ~default:0));
         if check_hidden
         then
           Alcotest.(check int)
             "hidden Timeline is not constructed"
             0
             (Option.value (Hashtbl.find_opt regions "timeline") ~default:0);
         if check_draft
         then (
           let editor = Option.get (find "style-class" "composer-input") in
           Hashtbl.clear regions;
           dispatch (Lui_protocol.TextChanged (editor, "first"));
           Alcotest.(check bool)
             "input is delivered to composer"
             true
             (Option.is_some (find "text" "first"));
           Alcotest.(check int)
             "draft input does not construct Favorites"
             0
             (Option.value (Hashtbl.find_opt regions "favorites") ~default:0);
           let journals = Option.get (find "accessibility-label" "Journals") in
           dispatch (Lui_protocol.Press journals);
           let editor = Option.get (find "style-class" "composer-input") in
           Hashtbl.clear regions;
           dispatch (Lui_protocol.TextChanged (editor, "second"));
           Alcotest.(check bool)
             "second edit uses current draft"
             true
             (Option.is_some (find "text" "second"));
           Alcotest.(check int)
             "draft input does not construct Timeline"
             0
             (Option.value (Hashtbl.find_opt regions "timeline") ~default:0);
           (* Return to Favorites so this fixture's native visibility checks still apply. *)
           let favorites = Option.get (find "accessibility-label" "Favorites") in
           dispatch (Lui_protocol.Press favorites));
         if check_detail
         then (
           let journals = Option.get (find "accessibility-label" "Journals") in
           dispatch (Lui_protocol.Press journals);
           let text = Option.get (find "text" "Timeline fixture 1") in
           dispatch (Lui_protocol.Press (ancestor_property text "press-enabled"));
           wait "Detail loaded" (fun () ->
             Option.is_some
               (find
                  "accessibility-identifier"
                  ("detail-block:" ^ G.Uuid.to_string (List.nth roots 1))));
           dispatch
             (Lui_protocol.Press
                (let scope = Option.get (find "accessibility-identifier" "journal-detail-capture-open") in
                 let rec under id =
                   id = scope || Option.fold ~none:false ~some:under (Hashtbl.find_opt parents id)
                 in
                 Hashtbl.fold (fun id values found ->
                   if under id && List.assoc_opt "accessibility-label" values = Some (`String "Capture")
                   then Some id else found) props None |> Option.get));
           let editor = Option.get (find "style-class" "composer-input") in
           Alcotest.(check bool)
             "append sheet title is present"
             true
             (Option.is_some (find "text" "Append"));
           Hashtbl.clear regions;
           dispatch (Lui_protocol.TextChanged (editor, "child draft"));
           Alcotest.(check bool)
             "append sheet title survives subscribed edit"
             true
             (Option.is_some (find "text" "Append"));
           Alcotest.(check bool)
             "append input uses current draft"
             true
             (Option.is_some (find "text" "child draft"));
           Alcotest.(check int)
             "append input does not construct retained Timeline"
             0
             (Option.value (Hashtbl.find_opt regions "timeline") ~default:0);
           Alcotest.(check int)
             "append input does not construct outline"
             0
             (Option.value (Hashtbl.find_opt regions "detail") ~default:0));
         if (not check_detail) && not check_generation
         then (
           let before=Atomic.get queried in
           let list_node=Option.get (find "accessibility-identifier" "favorites-native-list") in
           dispatch (Lui_protocol.VisibleRange (list_node,64,65));
           for _=1 to 5 do hooks.pump () |> consume done;
           Alcotest.(check int) "Favorites has no media body or lease acquisition" 0
             (if Option.is_some (find "path" "/tmp/targeted-media.png") then 1 else 0);
           Alcotest.(check bool) "Favorites visible range does not hydrate media roots" true
             (Atomic.get queried=before))))))

;;

(* The root reducer has no Worker accepted-ID/terminal-event boundary. This
   fixture exercises the production adapter with a real Worker Domain and a
   controlled service, without a database, native host, or cloud peer. *)
let test_reference_outer_terminals cancel =
  let module W = Logseq_db_worker_lui.Journal_worker in
  let module P = Logseq_db_worker.Protocol in
  let module G = Logseq_db_types.Graph_types in
  let uuid n =
    G.Uuid.of_string (Printf.sprintf "83000000-0000-4000-8000-%012d" n) |> Result.get_ok
  in
  let targets = Array.init 8 (fun n -> uuid (n + 1)) in
  let attempts = Array.init 8 (fun _ -> Atomic.make 0) in
  let worker_ids = Array.init 4 (fun _ -> Atomic.make None) in
  let release = Atomic.make false in
  let refresh = Atomic.make false in
  let late_returns = Atomic.make 0 in
  let terminal_count = ref 0 in
  let client = ref None in
  let page : G.page =
    { uuid = uuid 100
    ; name = "20260901"
    ; title = "Sep 1st, 2026"
    ; kind = Journal_page { journal_day = 20260901 }
    ; created_at_ms = 1_788_192_000_000L
    ; updated_at_ms = 1_788_192_000_000L
    ; recycled = false
    ; tags = []
    ; properties = []
    }
  in
  let source =
    String.concat
      " | "
      (Array.to_list targets |> List.map (fun id -> "[[" ^ G.Uuid.to_string id ^ "]]"))
  in
  let block : G.block =
    { uuid = uuid 200
    ; title = source
    ; parent = page.uuid
    ; page = page.uuid
    ; order = "a"
    ; created_at_ms = 1_788_192_000_000L
    ; updated_at_ms = 1_788_192_000_000L
    ; refs = []
    ; tags = []
    ; properties = []
    }
  in
  let record block : P.v2_block_record =
    { block; task_status = None; rendered_page_title = page.title; tag_titles = [] }
  in
  let manager : Service.state =
    { snapshot =
        { sync_phase = Current
        ; catalog = []
        ; selected_graph = Some (uuid 900)
        ; applied_server_t = Some (server_cursor_of_int 0)
        ; unlock = Logseq_sync_pure_reducer.Core.Unlock_inactive
        ; timeline_presentation_pending = false
        ; startup =
            { authenticated = true; local_access=Service.Local_available; network_phase=Service.Online_by_user
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
        ; last_error_attention = None; last_error = None
        ; local_deletion = None
        }
    ; diagnostics = { groups = [] }
    }
  in
  let graph_state : Logseq_db_worker.graph_state =
    { generation = 1; graph_id = Some (uuid 900); phase = Graph_open; error = None }
  in
  let service =
    W.Service.create
      ~push_topic_count:6
      ~concurrency:(Concurrent { max_in_flight = 16 })
      ~init:(fun context _ ->
        W.Session_context.emit
          context
          ~topic:Service.manager_topic
          (Service.Client_state_changed manager);
        Ok ())
      ~handle:(fun context () request ->
        let completed request outcome =
          Ok
            (Service.Graph_response
               (P.V2_response
                  { api_version = P.api_version
                  ; request_id = request.P.request_id
                  ; outcome
                  }))
        in
        match request with
        | Service.Inspect_local_copy _ | Service.Delete_local_copy _ -> Error "Unused fixture local-copy query"
        | Service.Get_graph_state ->
          if Atomic.exchange refresh false
          then
            W.Request_context.emit
              context
              ~topic:Service.invalidation_topic
              (Service.Graph_push
                 (P.V2_changes_available
                    { api_version = P.api_version; generation = "g"; through = "r2" }));
          Ok (Service.Graph_state graph_state)
        | Client_command _ | Asset_command _ | Release_asset_file _ ->
          Ok Service.Client_command_completed
        | Acquire_asset_file _ | Acquire_imported_file _ -> Ok (Service.Asset_file None)
        | Import_asset _ -> Error "unused import"
        | Graph_request request ->
          (match request.command with
           | P.V2_get_outline_block { block = target; _ }
             when not (Array.exists (G.Uuid.equal target) targets) ->
             completed
               request
               (V2_block_outcome
                  (if G.Uuid.equal target block.uuid
                   then V2_present_block { value = record block; revision = "root" }
                   else V2_missing_block { uuid = target; revision = "p" }))
           | P.V2_get_page { page = target; _ }
             when Array.exists (G.Uuid.equal target) targets ->
             let index =
               Array.to_list targets
               |> List.mapi (fun i id -> i, id)
               |> List.find (fun (_, id) -> G.Uuid.equal id target)
               |> fst
             in
             let attempt = Atomic.fetch_and_add attempts.(index) 1 in
             if index < 4 && attempt = 0
             then (
               Atomic.set worker_ids.(index) (Some (W.Request_context.request_id context));
               let wait () =
                 while not (Atomic.get release) do
                   Eio.Time.Mono.sleep (W.Request_context.clock context) 0.001
                 done
               in
               if cancel
               then (
                 (* Return an old value even after cancel was requested. The real
                   Worker must emit Cancelled and suppress this late completion. *)
                 Eio.Cancel.protect wait;
                 Atomic.incr late_returns;
                 completed
                   request
                   (V2_page_outcome
                      (V2_present_page
                         { page = { page with uuid = target; title = "Late cancelled target"; kind = Ordinary_page }
                         ; revision = "old"
                         })))
               else (
                 wait ();
                 Error "Injected outer Worker failure"))
             else
               completed
                 request
                 (V2_page_outcome
                    (V2_present_page
                       { page = { page with uuid = target; title = Printf.sprintf "Fresh target %d" index; kind = Ordinary_page }
                       ; revision = "fresh"
                       }))
           | V2_graph_info ->
             completed
               request
               (V2_graph_info_outcome
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
                  })
           | V2_list_journals _ ->
             completed
               request
               (V2_journals_outcome
                  { items = [ { page; journal_day = 20260901; revision = "p" } ]
                  ; next_cursor = None
                  })
           | V2_get_page_tree _ ->
             completed
               request
               (V2_page_tree_outcome
                  { page = page.uuid
                  ; maximum_depth = 1
                  ; items =
                      [ { value = record block
                        ; revision = "root"
                        ; depth = 0
                        ; parent = page.uuid
                        }
                      ]
                  ; next_cursor = None
                  })
           | V2_get_children {parent;_} ->
             completed request (V2_children_outcome
               {parent;revision_scope=V2_children_revision parent;scope_revision="children";items=[];next_cursor=None})
           | V2_pull_changes _ ->
             completed
               request
               (V2_changes
                  { generation = "g"
                  ; from_exclusive = Some "p"
                  ; through = "r2"
                  ; next = None
                  ; windows =
                      [ { id = "c1"
                        ; predecessor = "p"
                        ; successor = "r2"
                        ; block_uuids = Array.to_list (Array.sub targets 0 4)
                        ; page_uuids = []
                        ; structure_interests = []
                        }
                      ]
                  })
           | V2_ack_changes { generation; through } ->
             completed request (V2_changes_acknowledged { generation; through })
           | V2_list_assets _ ->
             completed
               request
               (V2_assets_outcome
                  { generation = "g"
                  ; projection_revision = "p"
                  ; items = []
                  ; next_cursor = None
                  })
           | _ ->
             completed
               request
               (V2_failed { code = "InvalidRequest"; message = "unused fixture query" })))
      ~shutdown:(fun () -> ())
      ()
  in
  let sampler =
    Journal_calendar.Sampler.create
      ~clock:(fun () -> 1_788_192_000.)
      ~localtime:Unix.gmtime
      ()
  in
  let hooks =
    Application.For_testing.app_with_service
      ~calendar_sampler:sampler
      ~on_client:(fun value ->
        client := Some value;
        W.on_event value (function
          | W.Response { outcome = Failed _ | Cancelled; _ } -> incr terminal_count
          | _ -> ()))
      service
  in
  let texts = Hashtbl.create 128 in
  let track_teardown = track_json_wire_teardown (Hashtbl.remove texts) in
  let saw_late = ref false in
  let consume encoded =
    if encoded <> ""
    then
      let open Yojson.Safe.Util in
      Yojson.Safe.from_string encoded
      |> member "ops"
      |> to_list
      |> List.iter (fun op ->
        track_teardown op;
        match op |> member "op" |> to_string with
        | ("set-prop" | "set-extension-prop")
          when member "property" op = `String "text"
               || (member "property" op = `String "payload"
                   && member "text" (Yojson.Safe.from_string (member "value" op |> to_string)) <> `Null) ->
          let text =
            if member "property" op = `String "text" then member "value" op |> to_string
            else member "text" (Yojson.Safe.from_string (member "value" op |> to_string)) |> to_string in
          if
            List.exists
              (fun value -> String.trim value = "Late cancelled target")
              (String.split_on_char '|' text)
          then saw_late := true;
          Hashtbl.replace texts (member "id" op |> to_int) text
        | _ -> ())
  in
  let wait label predicate =
    let deadline = Unix.gettimeofday () +. 5. in
    while (not (predicate ())) && Unix.gettimeofday () < deadline do
      consume (hooks.pump ());
      Unix.sleepf 0.001
    done;
    if not (predicate ())
    then
      Printf.eprintf
        "reference timeout=%s attempts=[%s] terminals=%d\n%!"
        label
        (String.concat
           ";"
           (Array.to_list attempts |> List.map (fun a -> string_of_int (Atomic.get a))))
        !terminal_count;
    Alcotest.(check bool) label true (predicate ())
  in
  let startup =
    Logseq_db_worker.Config.create
      ~application_support_directory:"/tmp/journal-reference-terminal-fixture"
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
    ~finally:(fun () ->
      Atomic.set release true;
      ignore (hooks.dispose ());
      Option.iter Logseq_db_worker_lui.Journal_worker_runtime.stop !client)
    (fun () ->
       consume (hooks.init 2 2 startup);
       wait "four accepted reference reads occupy hydration window" (fun () ->
         Array.for_all (fun id -> Option.is_some (Atomic.get id)) worker_ids);
       Alcotest.(check int)
         "remaining references wait for slots"
         0
         (Atomic.get attempts.(4));
       if cancel
       then
         Array.iter
           (fun id ->
              W.cancel (Option.get !client) ~request_id:(Option.get (Atomic.get id)))
           worker_ids;
       Atomic.set release true;
       wait "four real Worker outer terminals delivered" (fun () -> !terminal_count >= 4);
       wait "queued references resume after four terminal outcomes" (fun () ->
         Array.for_all (fun attempt -> Atomic.get attempt = 1) attempts);
       if cancel
       then
         Alcotest.(check int)
           "cancelled handlers attempted late return"
           4
           (Atomic.get late_returns);
       Atomic.set refresh true;
       ignore (W.send (Option.get !client) Service.Get_graph_state);
       wait "terminated targets can be read again" (fun () ->
         Array.for_all (fun attempt -> Atomic.get attempt = 2) (Array.sub attempts 0 4));
       let expected =
         String.concat " | " (List.init 8 (Printf.sprintf "Fresh target %d"))
       in
       wait "resolved label recovers after termination and refresh" (fun () ->
         Hashtbl.fold (fun _ text found -> found || text = expected) texts false);
       Alcotest.(check bool) "late cancelled completion never rendered" false !saw_late)
;;

(* Media scope belongs to rendering, which Root_navigation's pure boundary
   does not expose. Mount the actual row renderer and drive public route events;
   no Worker service or copied scope calculation is needed. *)
let with_timeline_media_row run =
  let block =
    Journal_model.create
      ~id:"84000000-0000-4000-8000-000000000001"
      ~page_id:"84000000-0000-4000-8000-000000000002"
      ~journal_day:20260908
      ~parent_id:None
      ~sibling_order:"a"
      ~source:(String.make 300 'x')
      ~task_state:Journal_model.No_status
      ~child_count:0
      ~creation_time:
        (Journal_time.create
           ~instant_unix_ms:1_788_825_600_000L
           ~local_day:20260908
           ~local_minute_of_day:0
         |> Result.get_ok)
      ~revision:"fixture"
      ~last_mutation_id:"84000000-0000-4000-8000-000000000003"
    |> Result.get_ok
  in
  let entry = { Journal_graph_projection.block; child_summaries = [] } in
  let batches = ref [] in
  let texts = Hashtbl.create 32 in
  let track_teardown = track_wire_teardown (Hashtbl.remove texts) in
  let backend : Lui_protocol.backend =
    { backend_profile = Lui_protocol.profile IOS SwiftUIHost
    ; apply_batch =
        (fun batch ->
          batches := batch :: !batches;
          List.iter
            (fun op ->
               track_teardown op;
               match op with
               | Lui_protocol.SetProp (id, TextValue, StringValue text) ->
                 Hashtbl.replace texts id text
               | Lui_protocol.SetExtensionProp (id, "payload", StringValue json) ->
                 (match Yojson.Basic.Util.member "text" (Yojson.Basic.from_string json) with
                  | `String text -> Hashtbl.replace texts id text | _ -> ())
               | _ -> ())
            batch.ops;
          true)
    }
  in
  let dispatch = Journal_view.Event.Handler.create (fun _ -> ()) in
  let app =
    Lui_app.create_with_extensions
      backend
      Journal_lui_native.registry
      (Journal_routes.create (), 1)
      (fun _ next -> next)
      (fun _ source _ ->
         Lui_elements.dyn
           ~equal:( == )
           (fun (routes, graph_generation) ->
              Journal_view.mount
                (Application.For_testing.timeline_media_row
                   ~routes
                   ~graph_generation
                   entry
                   dispatch))
           source)
  in
  let find_text text =
    Hashtbl.fold
      (fun id value result -> if value = text then Some id else result)
      texts
      None
    |> function
    | Some id -> id
    | None -> Alcotest.failf "Missing rendered text: %s" text
  in
  let update routes graph_generation =
    batches := [];
    ignore (Lui_app.send app (routes, graph_generation));
    ignore (Lui_app.flush app)
  in
  let ops () =
    List.concat_map (fun (batch : Lui_protocol.patch_batch) -> batch.ops) !batches
  in
  Fun.protect
    ~finally:(fun () -> ignore (Lui_app.dispose app))
    (fun () ->
       Alcotest.(check bool) "mounted" true (Lui_app.start app);
       ignore (Lui_app.flush app);
       run app block find_text update ops)
;;

let test_timeline_media_identity_across_detail_routes () =
  List.iter
    (fun destination ->
       with_timeline_media_row (fun _ block find_text update ops ->
         let initial =
           Journal_routes.select_destination (Journal_routes.create ()) destination
         in
         update initial 1;
         let source = Journal_model.source block in
         let original = find_text source in
         let loading =
           Journal_routes.open_detail
             initial
             ~block_id:(Journal_model.id block)
             ~request_generation:10L
         in
         let loaded =
           Journal_routes.apply_detail_response
             loading
             ~request_generation:10L
             { root = block; children = { blocks = []; continuation = None } }
         in
         let failed =
           Journal_routes.apply_detail_failure
             loading
             ~request_generation:10L
             ~missing:false
             ~message:"Retry"
         in
         let missing =
           Journal_routes.apply_missing_detail loading ~request_generation:10L
         in
         let reopened =
           Journal_routes.open_detail
             loaded
             ~block_id:(Journal_model.id block)
             ~request_generation:11L
         in
         List.iter
           (fun (label, routes) ->
              update routes 1;
              Alcotest.(check int)
                (label ^ " retains text identity")
                original
                (find_text source);
              let drops =
                List.filter
                  (function
                    | Lui_protocol.DropNode _ | DetachSubtree _ -> true
                    | _ -> false)
                  (ops ())
              in
              Alcotest.(check int)
                (label ^ " drops no retained media nodes")
                0
                (List.length drops))
           [ "loading", loading
           ; "loaded", loaded
           ; "failed", failed
           ; "missing", missing
           ; "reopened", reopened
           ; ( "runtime replacement while Detail is retained"
             , Journal_routes.runtime_replaced loaded )
           ; "back", Journal_routes.back reopened
           ]))
    [ Journal_routes.Journals; Favorites ]
;;

let test_timeline_media_bounded_body_and_owner_replacement () =
  with_timeline_media_row (fun _ block find_text update ops ->
    let initial = Journal_routes.create () in
    let no_expansion () =
      Alcotest.(check bool) "no local expansion action" false
        (List.exists (function
          | Lui_protocol.SetProp (_, TextValue, StringValue ("Show more" | "Show less")) -> true
          | _ -> false) (ops ())) in
    no_expansion ();
    let loading =
      Journal_routes.open_detail
        initial
        ~block_id:(Journal_model.id block)
        ~request_generation:10L
    in
    update loading 1;
    no_expansion ();
    update (Journal_routes.back loading) 1;
    no_expansion ();
    let original = find_text (Journal_model.source block) in
    update initial 2;
    Alcotest.(check bool)
      "new graph/runtime generation replaces the row body"
      true
      (original <> find_text (Journal_model.source block));
    no_expansion ();
    let journals = find_text (Journal_model.source block) in
    update (Journal_routes.select_destination initial Favorites) 2;
    Alcotest.(check bool)
      "Favorites is an independent presentation owner"
      true
      (journals <> find_text (Journal_model.source block)))
;;

let with_chrome_payloads initial build run =
  let payloads = Hashtbl.create 16 in
  let track = track_wire_teardown (Hashtbl.remove payloads) in
  let backend : Lui_protocol.backend =
    { backend_profile = Lui_protocol.profile IOS SwiftUIHost
    ; apply_batch = (fun batch ->
        List.iter (fun op ->
          track op;
          match op with
          | Lui_protocol.SetExtensionProp (id, "payload", StringValue value) ->
            Hashtbl.replace payloads id (Yojson.Safe.from_string value)
          | _ -> ()) batch.Lui_protocol.ops;
        true)
    }
  in
  let app = Lui_app.create_with_extensions backend Journal_lui_native.registry
      initial (fun _ next -> next)
      (fun _ signal _ -> Lui_elements.dyn ~equal:( = )
        (fun state -> Journal_view.mount (build state)) signal)
  in
  Fun.protect ~finally:(fun () -> ignore (Lui_app.dispose app)) (fun () ->
    Alcotest.(check bool) "chrome mounts" true (Lui_app.start app);
    ignore (Lui_app.flush app);
    run app payloads)
;;

(* Property naming/deduplication is owned by the renderer, with no public pure
   reducer presentation boundary. Mount that renderer using public route/model
   values; page children intentionally retain their canonical parent_id=None. *)
let test_detail_page_property_value_presentation () =
  let module G = Logseq_db_types.Graph_types in
  let id n = Printf.sprintf "86000000-0000-4000-8000-%012d" n in
  let uuid n = G.Uuid.of_string (id n) |> Result.get_ok in
  let property : G.property_summary =
    { ident="user.property/summary"; uuid=uuid 4; title="Summary"
    ; schema={property_type=Node;cardinality=One;hidden=false;public=false}
    ; values=[Entity_value (uuid 3)]; values_truncated=false } in
  let marker : G.property_summary =
    { property with ident="logseq.property/created-from-property"
    ; schema={property.schema with hidden=true}; values=[Entity_value (uuid 4)] } in
  let make n ~parent_id ~source ~properties ~child_count =
    Journal_model.create_on_page ~id:(id n) ~page_id:(id 1) ~journal_day:None
      ~parent_id ~sibling_order:"a" ~source ~task_state:No_status ~child_count
      ~revision:"r1" ~last_mutation_id:(id 9)
      ~creation_time:(Journal_time.create ~instant_unix_ms:0L ~local_day:20260908
        ~local_minute_of_day:0 |> Result.get_ok)
    |> Result.get_ok |> fun block -> Journal_model.with_properties block ~properties in
  List.iter (fun page_root ->
    let root_id = if page_root then 1 else 2 in
    let root=make root_id ~parent_id:None ~source:"Selected root"
      ~properties:[property] ~child_count:1 in
    let child=make 3 ~parent_id:(if page_root then None else Some (id root_id))
      ~source:"Property value body" ~properties:[marker] ~child_count:0 in
    let routes=Journal_routes.open_detail (Journal_routes.create ())
      ~block_id:(id root_id) ~request_generation:1L
      |> fun routes -> Journal_routes.apply_detail_response routes ~request_generation:1L
        {root;children={blocks=[child];continuation=None}} in
    let routes, reads=Journal_routes.load_initial routes in
    let routes=List.fold_left (fun routes -> function
      | Journal_graph_request.Load_detail request ->
        Alcotest.(check string) "prepare the property's complete leaf body"
          (id 3) request.block_id;
        Journal_routes.apply_detail_response routes ~request_generation:request.request_generation
          {root=child;children={blocks=[];continuation=None}}
      | _ -> Alcotest.fail "unexpected initial detail request") routes reads in
    Alcotest.(check bool) "initial body is prepared before rendering" true
      (Option.is_some (Journal_routes.detail routes));
    let texts=Hashtbl.create 16 in
    let track=track_wire_teardown (Hashtbl.remove texts) in
    let backend : Lui_protocol.backend =
      {backend_profile=Lui_protocol.profile IOS SwiftUIHost
      ;apply_batch=(fun batch -> List.iter (fun op -> track op; match op with
        | Lui_protocol.SetProp(id,TextValue,StringValue text) -> Hashtbl.replace texts id text
        | Lui_protocol.SetExtensionProp(id,"payload",StringValue json) ->
          (match Yojson.Safe.Util.member "text" (Yojson.Safe.from_string json) with
           | `String text -> Hashtbl.replace texts id text | _ -> ())
        | _ -> ()) batch.Lui_protocol.ops; true)} in
    let app=Lui_app.create_with_extensions backend Journal_lui_native.registry ()
      (fun () () -> ()) (fun _ _ _ -> Application.For_testing.detail_page
        ~routes ~write_enabled:false (fun _ -> ())
        |> Journal_view.View.Body.Private.to_widget |> Journal_view.mount) in
    Fun.protect ~finally:(fun () -> ignore (Lui_app.dispose app)) (fun () ->
      Alcotest.(check bool) "property detail mounts" true (Lui_app.start app);
      ignore (Lui_app.flush app);
      let count text=Hashtbl.fold (fun _ value n -> if text=value then n+1 else n) texts 0 in
      Alcotest.(check int) "owned value keeps its property name" 0 (count "Property");
      Alcotest.(check int) "owned value appears under one named field" 1 (count "Summary");
      Alcotest.(check int) "property value body appears once" 1 (count "Property value body")))
    [true;false]
;;

(* The public Favorites mount has no shared-lookup input. Exercise the narrow
   Application ownership/renderer boundary with a real Worker and correct page
   data; Runtime discovery itself is covered by its pure owner regressions. *)
let test_favorite_page_uses_shared_reference_lookup () =
  let module W = Logseq_db_worker_lui.Journal_worker in
  let module P = Logseq_db_worker.Protocol in
  let module G = Logseq_db_types.Graph_types in
  let uuid n = G.Uuid.of_string
    (Printf.sprintf "86000000-0000-4000-8000-%012d" n) |> Result.get_ok in
  let token = "[[" ^ G.Uuid.to_string (uuid 3) ^ "]]" in
  let page : G.page =
    { uuid = uuid 1; name = "favorite"; title = "Page " ^ token; kind = Ordinary_page
    ; created_at_ms = 0L; updated_at_ms = 0L; recycled = false; tags = []; properties = [] } in
  let block : G.block =
    { uuid = uuid 2; title = "Block " ^ token; parent = page.uuid; page = page.uuid
    ; order = "a"; created_at_ms = 0L; updated_at_ms = 0L; refs = []; tags = []; properties = [] } in
  let manager : Service.state =
    { snapshot =
        { sync_phase = Current; catalog = []; selected_graph = Some (uuid 9)
        ; applied_server_t = Some (server_cursor_of_int 0); unlock = Logseq_sync_pure_reducer.Core.Unlock_inactive
        ; timeline_presentation_pending = false
        ; startup = { authenticated = true; local_access=Service.Local_available; network_phase=Service.Online_by_user; catalog_loading = false; awaiting_selection = false
            ; restoring_local = false; bootstrapping = false; awaiting_e2ee_password = false
            ; failure = None; account_generation = 1; graph_generation = 1; presentation_generation = 1 }
        ; last_error_attention = None; last_error = None; local_deletion = None }
    ; diagnostics = { groups = [] } } in
  let target_reads = Atomic.make 0 in
  let service = W.Service.create ~push_topic_count:6 ~concurrency:(Concurrent { max_in_flight = 2 })
    ~init:(fun context _ ->
      W.Session_context.emit context ~topic:Service.manager_topic (Service.Client_state_changed manager);
      Ok ())
    ~handle:(fun _ () -> function
      | Service.Get_graph_state -> Ok (Service.Graph_state
          { generation = 1; graph_id = Some (uuid 9); phase = Graph_open; error = None })
      | Client_command _ -> Ok Service.Client_command_completed
      | Graph_request request ->
        let open P in
        let outcome = match request.command with
          | V2_graph_info -> V2_graph_info_outcome
              { graph_uuid = uuid 9; graph_name = "Fixture"; schema = { major = 65; minor = 33 }
              ; admission_facts = []; journal_title_format = None; generation = "g"; projection_revision = "p"
              ; limits = { response_budget_bytes = maximum_response_bytes; outbox_max_records = 4096
                  ; outbox_max_bytes = 8388608; change_max_items = 4096; change_max_bytes = 1048576
                  ; dispatcher_capacity = 256; wire_batch_max_bytes = 262144 } }
          | V2_list_journals _ -> V2_journals_outcome { items = []; next_cursor = None }
          | V2_list_favorites _ -> V2_favorites_outcome
              { favorites_page = None; generation = "g"; projection_revision = "p"; next_cursor = None
              ; items =
                  [{ membership_uuid = uuid 10; membership_order = "a"; membership_revision = "m"
                   ; target = V2_favorite_page { uuid = page.uuid; title = page.title; revision = "p" } }
                  ;{ membership_uuid = uuid 11; membership_order = "b"; membership_revision = "m"
                   ; target = V2_favorite_block
                       { uuid = block.uuid; title = block.title; task_status = None; revision = "b" } }] }
          | V2_get_page { page = requested; _ } ->
            if G.Uuid.equal requested (uuid 3) then Atomic.incr target_reads;
            V2_page_outcome (V2_present_page
                    { page =
                        (if G.Uuid.equal requested page.uuid
                         then page
                         else
                           { page with
                             uuid = requested
                           ; title = "Resolved"
                           ; name = "resolved"
                           })
              ; revision = "p" })
          | V2_get_outline_block { block = requested; _ } when G.Uuid.equal requested block.uuid ->
            V2_block_outcome (V2_present_block
              { value = { block; task_status = None; rendered_page_title = page.title; tag_titles = [] }
              ; revision = "b" })
          | V2_list_assets _ -> V2_assets_outcome
              { generation = "g"; projection_revision = "p"; items = []; next_cursor = None }
          | _ -> V2_failed { code = "InvalidRequest"; message = "Unused fixture operation" }
        in
        Ok (Service.Graph_response (V2_response
          { api_version; request_id = request.request_id; outcome }))
      | _ -> Error "Unused fixture service operation")
    ~shutdown:(fun () -> ()) () in
  let client = ref None in
  let hooks = Application.For_testing.app_with_service
    ~on_client:(fun c -> client := Some c)
    ~calendar_sampler:(Journal_calendar.Sampler.create
      ~clock:(fun () -> 1_788_192_000.) ~localtime:Unix.gmtime ()) service in
  let props = Hashtbl.create 64 in
  let track = track_json_wire_teardown (Hashtbl.remove props) in
  let consume encoded =
    if encoded <> ""
    then
    let open Yojson.Safe.Util in
    Yojson.Safe.from_string encoded |> member "ops" |> to_list |> List.iter (fun op ->
      track op;
      match member "op" op |> to_string with
      | "set-prop" | "set-extension-prop" ->
        let id = member "id" op |> to_int in
        let key = member "property" op |> to_string in
        let old = Hashtbl.find_opt props id |> Option.value ~default:[] in
        Hashtbl.replace props id ((key, member "value" op) :: List.remove_assoc key old)
        | _ -> ())
  in
  let find key text = Hashtbl.fold (fun id pairs found ->
    if List.assoc_opt key pairs = Some (`String text) then Some id else found) props None in
  let wait label predicate =
    let deadline = Unix.gettimeofday () +. 3. in
    while (not (predicate ())) && Unix.gettimeofday () < deadline do
      consume (hooks.pump ()); Unix.sleepf 0.001
    done;
    Alcotest.(check bool) label true (predicate ()) in
  Fun.protect ~finally:(fun () ->
    ignore (hooks.dispose ()); Option.iter Logseq_db_worker_lui.Journal_worker_runtime.stop !client)
    (fun () ->
      let startup = Logseq_db_worker.Config.create
        ~application_support_directory:"/tmp/journal-favorite-page-reference-fixture"
        ~target:(Managed_sync { base_url = "https://example.invalid" })
        ~compatibility_profile:Logseq_65_33_or_newer
        ~response_budget_bytes:P.maximum_response_bytes ~default_page_size:P.default_page_size
        |> Result.get_ok |> Journal_startup.encode |> Result.get_ok |> Bytes.to_string in
      consume (hooks.init 2 2 startup);
      wait "Favorites navigation mounts" (fun () -> Option.is_some (find "accessibility-label" "Favorites"));
      consume (hooks.dispatch (Lui_protocol.Press (Option.get (find "accessibility-label" "Favorites"))));
      wait "block proves shared lookup is populated" (fun () -> Option.is_some (find "text" "Block Resolved"));
      wait "Favorite Page uses the same populated lookup" (fun () -> Option.is_some (find "text" "Page Resolved"));
      Alcotest.(check int) "shared target is queried once" 1 (Atomic.get target_reads))
;;

let test_favorites_compact_shared_titles () =
  let module G=Logseq_db_types.Graph_types in
  let module P=Logseq_db_worker.Protocol in
  let id n=G.Uuid.of_string (Printf.sprintf "85000000-0000-4000-8000-%012d" n) |> Result.get_ok in
  let items=List.init 2 (fun n ->
    {P.membership_uuid=id (n+1);membership_order=string_of_int n;membership_revision="m";
     target=(if n=0 then V2_favorite_page {uuid=id 10;title="Page";revision="p"}
           else
             V2_favorite_block
               { uuid = id 11
               ; title = "**Favorite** [[Named page]]"
               ; revision = "b"
               ; task_status =
                   Some
                     (Logseq_db_types.Graph_types.Uuid.of_string
                        "00000002-1615-5853-7700-000000000000"
                      |> Result.get_ok)
               })
      })
  in
  let ops=ref [] in
  let backend : Lui_protocol.backend =
    {backend_profile=Lui_protocol.profile IOS SwiftUIHost;
     apply_batch=(fun batch->ops:=List.rev_append batch.Lui_protocol.ops !ops;true)} in
  let app=Lui_app.create_with_extensions backend Journal_lui_native.registry () (fun () ()->())
    (fun _ _ _ -> Journal_view.mount (Application.For_testing.favorites_page items)) in
  Fun.protect ~finally:(fun ()->ignore(Lui_app.dispose app)) (fun () ->
    Alcotest.(check bool) "Favorites mounts" true (Lui_app.start app);
    ignore(Lui_app.flush app);
       let has prop value =
         List.exists
           (function
             | Lui_protocol.SetProp (_, p, v) -> p = prop && v = value
             | _ -> false)
           !ops
       in
    Alcotest.(check bool) "shared mldoc title is plain text" true
      (has TextValue (StringValue "Favorite [[Named page]]"));
    Alcotest.(check int) "both title nodes use existing single-line policy" 2
      (List.length (List.filter (function
        | Lui_protocol.SetProp (_,StyleClass,StringValue "single-line") -> true
        | _ -> false) !ops));
    Alcotest.(check bool) "status is omitted" false (has TextValue (StringValue "Todo"));
    Alcotest.(check bool) "page icon" true (has IconName (StringValue "app:doc-text"));
    let bullet = List.find_map (function
      | Lui_protocol.SetProp (id,IconName,StringValue "app:circle-fill") -> Some id
      | _ -> None) !ops in
    Alcotest.(check bool) "block uses a solid text bullet" true (Option.is_some bullet);
    let bullet = Option.get bullet in
    List.iter (fun key ->
      let size = List.find_map (function
        | Lui_protocol.SetProp (id,p,Lui_protocol.IntValue value)
          when id=bullet && p=key -> Some value
        | _ -> None) !ops in
      Alcotest.(check bool) "bullet is smaller than a task control" true
        (Option.fold ~none:false ~some:(fun value -> value>0 && value<=8) size))
      [Lui_protocol.WidthValue;HeightValue];
    Alcotest.(check bool) "no hollow task-like circle" false (has IconName (StringValue "app:circle"));
    Alcotest.(check bool) "no trailing arrow" false (has IconName (StringValue "app:chevron-right"));
       Alcotest.(check int)
         "uses LUI list"
         1
         (List.length
            (List.filter
               (function
                 | Lui_protocol.CreateNode (_, ListContainer) -> true
                 | _ -> false)
               !ops));
    Alcotest.(check bool) "no Journal list extension" false
         (List.exists
            (function
              | Lui_protocol.CreateExtension (_, "journal-list", _) -> true
              | _ -> false)
            !ops))
;;

(* Header control placement has no public reducer event/state; exercise the
   public OCaml header mount, including disabled and enabled capture gates. *)
let test_root_capture_placement () =
  List.iter (fun platform ->
    List.iter (fun favorites ->
      List.iter (fun capture_enabled ->
        let ops = ref [] in
        let backend : Lui_protocol.backend =
          { backend_profile = Lui_protocol.profile IOS SwiftUIHost
          ; apply_batch = (fun batch -> ops := batch.Lui_protocol.ops @ !ops; true) } in
        let noop = Journal_view.Event.Handler.create (fun _ -> ()) in
        let app = Lui_app.create_with_extensions backend Journal_lui_native.registry ()
          (fun () () -> ()) (fun _ _ _ ->
            Journal_view.mount (Journal_header.view
              ~key:(Journal_view.Key.string "capture-placement") ~platform
              ~context:(if favorites then Journal_header.Context.favorites else Journal_header.Context.journals)
              ~sync_phase:None ~sync_error:None ~on_error_info:None ~on_account_action:None
              ~local_deletion_available:false ~on_journals:noop ~on_favorites:noop
              ~on_capture:noop ~capture_enabled ~capture_expanded:None
              ~body:(Journal_view.View.text "Root body"))) in
        Fun.protect ~finally:(fun () -> ignore (Lui_app.dispose app)) (fun () ->
          Alcotest.(check bool) "root header mounts" true (Lui_app.start app);
          ignore (Lui_app.flush app);
          let has key value = List.exists (function
            | Lui_protocol.SetProp (_,p,Lui_protocol.StringValue text) -> p=key && text=value
            | _ -> false) !ops in
          Alcotest.(check bool) "Capture is only mounted in Journals root" (not favorites)
            (has AccessibilityIdentifier "journal-capture-open");
          Alcotest.(check bool) "Favorites has no Capture action/semantics" (not favorites)
            (has AccessibilityLabel "Capture");
          List.iter (fun destination ->
            Alcotest.(check bool) "destination navigation remains mounted" true
              (has AccessibilityLabel destination)) ["Journals";"Favorites"])) [false;true])
      [false;true]) ["ios";"macos"]
;;

let test_timeline_relative_date_headers () =
  let noop = Journal_view.Event.Handler.create (fun _ -> ()) in
  let check ~today ~yesterday ~other =
    let module T = Journal_timeline_state in
    let days = [today; yesterday; other] in
    let block day =
      Journal_model.create ~id:(Printf.sprintf "%08d-0000-4000-8000-000000000001" day)
        ~page_id:(Printf.sprintf "%08d-0000-4000-8000-000000000002" day)
        ~journal_day:day ~parent_id:None ~sibling_order:"a" ~source:"Date fixture"
        ~task_state:No_status ~child_count:0 ~revision:"r1"
        ~last_mutation_id:"00000001-0000-4000-8000-000000000003"
        ~creation_time:(Journal_time.create ~instant_unix_ms:0L ~local_day:day
          ~local_minute_of_day:0 |> Result.get_ok) |> Result.get_ok
    in
    let feed : Journal_graph_projection.feed =
      { days = List.map (fun day ->
          { Journal_graph_projection.page =
              { id = string_of_int day; day; title = "fallback" }
          ; entries = [{block=block day; child_summaries=[]}]; has_more_entries = false; continuation = None }) days
      ; slot_count = 5; continuation = None; prioritized_day = None }
    in
    let state = T.empty ~today
      |> fun state -> T.begin_request state ~generation:1L (Feed { cursor = None })
      |> fun state -> T.apply_feed state ~generation:1L feed
    in
    let build state = Journal_timeline.view ~state
      ~render_source:Fun.id ~render_media:(fun ~title:_ ~root:_ ~image_children:_ child -> child)
      ~day_presentation:(fun day -> Journal_calendar.present_journal_day day |> Result.to_option)
      ~on_visible_range:noop ~on_scroll_completed:noop ~on_retry_day:noop
      ~on_open_block:noop ~delete_enabled:false ~actions_enabled:false
      ~on_status:noop ~on_delete:noop ~on_copy:noop ()
      |> Journal_view.View.Body.Private.to_widget
    in
    with_chrome_payloads state build (fun app payloads ->
      let header day =
        let title = (Journal_calendar.present_journal_day day |> Result.get_ok).date_text in
        Hashtbl.fold (fun _ props found ->
          let open Yojson.Safe.Util in
          if member "mode" props = `String "header" && member "title" props = `String title
          then Some props else found) payloads None |> Option.get
      in
      let assert_label day expected =
        let actual = Yojson.Safe.Util.member "text" (header day) in
        Alcotest.(check (option string)) (Printf.sprintf "relative label %d today %d" day today)
          expected
          (match actual with
           | `String text -> Some text
           | _ -> None)
      in
      assert_label today (Some "today");
      assert_label yesterday (Some "yesterday");
      assert_label other None;
      ignore (Lui_app.send app (T.set_today state ~today:yesterday));
      ignore (Lui_app.flush app);
      assert_label yesterday (Some "today");
      assert_label today None)
  in
  List.iter (fun (today, yesterday, other) -> check ~today ~yesterday ~other)
    [20261014,20261013,20261012; 20261001,20260930,20261002;
     20270101,20261231,20261230; 20240301,20240229,20240228;
     20260301,20260228,20260302; 20260309,20260308,20260307;
     20261102,20261101,20261031];
  let sample seconds offset = Journal_calendar.Sampler.create
      ~clock:(fun () -> seconds) ~localtime:(fun instant -> Unix.gmtime (instant +. offset)) ()
    |> Journal_calendar.Sampler.sample |> Result.get_ok |> Journal_calendar.local_day in
  (* The same instant is yesterday in UTC-8 and today in UTC+8. *)
  check ~today:(sample 1_788_537_600. (-28_800.)) ~yesterday:20260903 ~other:20260905;
  check ~today:(sample 1_788_537_600. 28_800.) ~yesterday:20260904 ~other:20260903;
  (* Before/after local midnight, independent of UTC midnight. *)
  check ~today:(sample 1_786_204_740. 28_800.) ~yesterday:20260807 ~other:20260809;
  check ~today:(sample 1_786_204_800. 28_800.) ~yesterday:20260808 ~other:20260807
;;

let test_detail_empty_navigation_title () =
  let noop = Journal_view.Event.Handler.create (fun _ -> ()) in
  let build () = Journal_header.detail ~capture_enabled:true ~on_capture:noop
      ~copy_enabled:true ~on_copy:noop ~copy_feedback:None (Journal_view.View.text "Detail body")
    |> Journal_view.View.Body.Private.to_widget
  in
  with_chrome_payloads () build (fun _ payloads ->
    let detail = Hashtbl.fold (fun _ props found ->
      if Yojson.Safe.Util.member "mode" props = `String "detail" then Some props else found)
      payloads None |> Option.get in
    Alcotest.(check string) "native Detail bar has an empty title" ""
      (Yojson.Safe.Util.member "title" detail |> Yojson.Safe.Util.to_string))
;;

let test_reactive_header_current_controls () =
  let props = Hashtbl.create 128 in
  let track_teardown =
    track_wire_teardown (fun id ->
      Hashtbl.filter_map_inplace
        (fun (node, _) value -> if node = id then None else Some value)
        props)
  in
  let backend : Lui_protocol.backend =
    { backend_profile = Lui_protocol.profile IOS SwiftUIHost
    ; apply_batch =
        (fun batch ->
          List.iter
            (fun op ->
               track_teardown op;
               match op with
               | Lui_protocol.SetProp (id, key, value) ->
                 Hashtbl.replace props (id, key) value
               | RemoveProp (id, key) -> Hashtbl.remove props (id, key)
               | _ -> ())
            batch.Lui_protocol.ops;
          true)
    }
  in
  let find key text =
    Hashtbl.fold
      (fun (id, property) value found ->
         if key = property && value = Lui_protocol.StringValue text
         then Some id
         else found)
      props
      None
  in
  let capture_count = ref 0
  and error_count = ref 0 in
  let handler f = Journal_view.Event.Handler.create (fun _ -> f ()) in
  let noop = handler (fun () -> ()) in
  let initial : Journal_header.presentation =
    { sync_phase = None
    ; sync_error = None
    ; error_available = false
    ; local_deletion_available = false
    ; capture_enabled = true
    }
  in
  let app =
    Lui_app.create_with_extensions
      backend
      Journal_lui_native.registry
      initial
      (fun _ next -> next)
      (fun _ signal _ ->
         Journal_view.mount
           (Journal_header.reactive_view
              ~presentation_signal:signal
              ~key:(Journal_view.Key.string "reactive-header")
              ~platform:"ios"
              ~context:Journal_header.Context.journals
              ~sync_phase:None
              ~sync_error:None
              ~on_error_info:(Some (handler (fun () -> incr error_count)))
              ~on_account_action:(Some (fun _ -> ()))
              ~local_deletion_available:false
              ~on_journals:noop
              ~on_favorites:noop
              ~on_capture:(handler (fun () -> incr capture_count))
              ~capture_enabled:false
              ~capture_expanded:None
              ~body:(Journal_view.View.text "Persistent header body")))
  in
  Fun.protect
    ~finally:(fun () -> ignore (Lui_app.dispose app))
    (fun () ->
       Alcotest.(check bool) "reactive header mounts" true (Lui_app.start app);
       ignore (Lui_app.flush app);
       let body = Option.get (find TextValue "Persistent header body") in
       let capture = Option.get (find AccessibilityLabel "Capture") in
       ignore
         (Lui_app.send
            app
            { initial with
              capture_enabled = false
            ; error_available = true
            ; local_deletion_available = true
            });
       ignore (Lui_app.flush app);
       ignore (Lui_app.dispatch_event app (Lui_protocol.Press capture));
       ignore (Lui_app.flush app);
       Alcotest.(check int) "Capture consults current disabled gate" 0 !capture_count;
       Alcotest.(check bool)
         "current graph cannot be deleted from the account menu"
         true
         (Option.is_none (find TextValue "Delete local graph copy"));
       ignore
         (Lui_app.dispatch_event
            app
            (Press (Option.get (find AccessibilityLabel "Error info"))));
       ignore (Lui_app.flush app);
       Alcotest.(check int)
         "newly visible error control invokes its handler"
         1
         !error_count;
       ignore (Lui_app.send app initial);
       ignore (Lui_app.flush app);
       ignore (Lui_app.dispatch_event app (Press capture));
       ignore (Lui_app.flush app);
       Alcotest.(check int)
         "same Capture handler reads newly enabled gate"
         1
         !capture_count;
       Alcotest.(check bool)
         "removed cache capability removes menu action"
         true
         (Option.is_none (find TextValue "Delete local graph copy"));
       Alcotest.(check bool)
         "cleared error capability removes error action"
         true
         (Option.is_none (find AccessibilityLabel "Error info"));
       let spinner = ref None in
       List.iter (fun phase ->
         ignore (Lui_app.send app {initial with sync_phase=Some phase});
         ignore (Lui_app.flush app);
         let current = find AccessibilityIdentifier "journal-header-sync-progress" in
         (match !spinner with
          | None -> spinner := current
          | Some id -> Alcotest.(check (option int))
              "all active phases retain the same existing spinner" (Some id) current);
         Alcotest.(check bool) "shared active phase shows header progress" true
           (Option.is_some current))
         [Service.Connecting; Pulling; Submitting];
       ignore (Lui_app.send app {initial with sync_phase=Some Service.Current});
       ignore (Lui_app.flush app);
       Alcotest.(check bool) "settled shared owner removes progress" true
         (Option.is_none (find AccessibilityIdentifier "journal-header-sync-progress"));
       Alcotest.(check int)
         "control changes preserve body node identity"
         body
         (Option.get (find TextValue "Persistent header body")))
;;

let test_favorites_native_visibility_retires_media () = run_favorites_native_visibility ()

let test_application_region_visible () =
  run_favorites_native_visibility ~check_visible:true ()
;;

let test_application_region_hidden () =
  run_favorites_native_visibility ~check_hidden:true ()
;;

let test_application_region_draft () =
  run_favorites_native_visibility ~check_draft:true ()
;;

let test_application_region_detail () =
  run_favorites_native_visibility ~check_detail:true ()
;;

let test_application_region_error_control () =
  run_favorites_native_visibility ~check_error_control:true ()
;;

let test_application_region_chrome () =
  run_favorites_native_visibility ~check_chrome:true ()
;;

let test_application_region_generation () =
  run_favorites_native_visibility ~check_generation:true ()
;;

let test_application_ios_capture () =
  run_favorites_native_visibility ~check_ios_capture:true ()
;;

let test_fixture_exception_cleanup exception_ =
  let observed =
    try
      run_favorites_native_visibility ~on_initialized:(fun () -> raise exception_) ();
      false
    with
    | actual when actual == exception_ -> true
  in
  Alcotest.(check bool) "fixture preserves its original exit" true observed;
  check_fixture_worker_idle ()
;;

(* Build opaque unlock evidence through the production reducer, including its
   actual key-package and attachment owners. No boolean-to-receipt fixture. *)
let synthetic_unlock_prompt graph_id =
  let module C = Logseq_sync_pure_reducer.Core in
  let limits = C.limits ~maximum_response_bytes:Logseq_db_types.Limits.maximum_response_bytes
    ~maximum_artifact_bytes:1048576 ~submission_batch_size:32 |> Result.get_ok in
  let initial = C.config ~managed_sync_origin:(Uri.of_string "https://example.invalid") ~limits
    |> Result.get_ok |> C.initial |> Result.get_ok in
  let permitted = C.step initial (C.Sign_in_requested
    { account_generation = 0; presentation_generation = 0 }) in
  let auth = C.step permitted.next (C.Account_authenticated { user_id = Some "synthetic-user" }) in
  let graph : C.graph = { graph_id; name = "Private Journal"; encrypted = true
    ; schema = { major = 65; minor = 33; exact = true } } in
  let catalog = List.find_map (function
    | C.Run (C.Request (ticket, C.Fetch_catalog _)) -> Some (C.step auth.next
        (C.Runner_completed (C.Completion (ticket, Ok [graph]))))
    | _ -> None) auth.effects |> Option.get in
  let selected = C.step catalog.next (C.Graph_selected graph_id) in
  let mirror = List.find_map (function C.Delegate (C.Inspect_mirror request) -> Some request
    | _ -> None) selected.effects |> Option.get in
  let local = C.step selected.next (C.Mirror_inspected (C.Mirror_available mirror)) in
  let prepare = List.find_map (function
    | C.Run (C.Request (ticket, C.Load_and_unlock_graph_key _)) -> Some (C.step local.next
        (C.Runner_completed (C.Completion (ticket, Error (C.Effect_failed "synthetic missing key")))))
    | _ -> None) local.effects |> Option.get in
  let wrapped = List.find_map (function
    | C.Run (C.Request (ticket, C.Fetch_e2ee_graph_key _)) -> Some (C.step prepare.next
        (C.Runner_completed (C.Completion (ticket, Ok "synthetic-wrapped"))))
    | _ -> None) prepare.effects |> Option.get in
  List.find_map (function
    | C.Run (C.Request (ticket, C.Fetch_e2ee_user_keys _)) -> Some (C.step wrapped.next
        (C.Runner_completed (C.Completion (ticket, Ok "synthetic-package"))))
    | _ -> None) wrapped.effects |> Option.get
;;

(* Application owns password admission and UI. No public pure root event exists
   for E2EE; this fixture exercises mounted Application through its public hooks. *)
let unlock_fixture ?(worker_failure = false) ?(queue_full = false) ?(fail_init = false) ?(cold_start = false)
    ?(attach_mirror = false) ?(graph_first = false)
    ?(attachment_stage = Atomic.make 0) ?(finish_attachment = Atomic.make true)
    ?(on_timeline_presented = fun _ -> ())
    ?on_platform_request ?(on_auth_classified = fun _ -> ())
    ?(on_auth_handled = fun _ _ -> ()) () =
  let module W = Logseq_db_worker_lui.Journal_worker in
  let graph_id =
    Logseq_db_types.Graph_types.Uuid.of_string "00000000-0000-0000-0000-000000000901"
    |> Result.get_ok
  in
  let module C = Logseq_sync_pure_reducer.Core in
  let prompt = synthetic_unlock_prompt graph_id in
  let core = ref prompt.next in
  let manager : Service.state =
    { snapshot =
        { sync_phase = Offline
        ; catalog =
            [ { graph_id
              ; name = "Private Journal"
              ; schema = { major = 65; minor = 33; exact = true }
              ; encrypted = true
              }
            ]
        ; selected_graph = Some graph_id
        ; applied_server_t = None
        ; unlock = (C.state !core).snapshot.unlock
        ; timeline_presentation_pending = false
        ; startup =
            { authenticated = true; local_access=Service.Local_available; network_phase=Service.Online_by_user
            ; catalog_loading = false
            ; awaiting_selection = false
            ; restoring_local = false
            ; bootstrapping = false
            ; awaiting_e2ee_password = true
            ; failure = None
            ; account_generation = 1
            ; graph_generation = 1
            ; presentation_generation = (C.state !core).snapshot.startup.presentation_generation
            }
        ; last_error_attention = None; last_error = None
        ; local_deletion = None
        }
    ; diagnostics = { groups = [] }
    }
  in
  let manager = if cold_start then
    { manager with snapshot = { manager.snapshot with startup =
      { manager.snapshot.startup with authenticated = false; local_access = Service.Local_pending
      ; network_phase = Service.Local_only; awaiting_e2ee_password = false }
      ; unlock = C.Unlock_inactive } }
    else manager in
  let graph_reads = Atomic.make 0 in
  let current = Atomic.make manager in
  let graph_phase = Atomic.make Logseq_db_worker.Graph_closed in
  let submissions = Atomic.make [] in
  let release = Atomic.make false in
  let client = ref None in
  let worker =
    W.Service.create
      ~push_topic_count:6
      ~merge_push:Service.coalesce_push
      ~concurrency:Serial
      ~control_topic_count:2
      ~classify_control:(function
        | Service.Client_command (Reconcile_authenticated_user {user_id}) ->
          on_auth_classified user_id;
          Some (W.Latest {topic=1; key=Option.value user_id ~default:"none"; invalidates=Some 0})
        | _ -> None)
      ~handle_control:(fun () _ -> ())
      ~init:(fun context _ ->
        W.Session_context.emit
          context
          ~topic:Service.manager_topic
          (Service.Client_state_changed manager);
        Ok ())
      ~handle:(fun context () request ->
        let publish value =
          Atomic.set current value;
          W.Request_context.emit
            context
            ~topic:Service.manager_topic
            (Service.Client_state_changed value)
        in
        match request with
        | Service.Inspect_local_copy _ | Service.Delete_local_copy _ -> Error "Unused fixture local-copy query"
        | Service.Get_graph_state ->
          if queue_full && Atomic.fetch_and_add graph_reads 1 > 0
          then
            while not (Atomic.get release) do
              Eio.Time.Mono.sleep (W.Request_context.clock context) 0.001
            done;
          Ok
            (Service.Graph_state
               { generation = 1
               ; graph_id = (Atomic.get current).snapshot.selected_graph
               ; phase = Atomic.get graph_phase
               ; error = None
               })
        | Client_command (Submit_e2ee_password _) when worker_failure ->
          Error "Synthetic unlock worker failure"
        | Client_command (Submit_e2ee_password (challenge, password)) ->
          let unlocking = C.step !core (C.E2ee_password_submitted (challenge, password)) in
          core := unlocking.next;
          Atomic.set submissions (password :: Atomic.get submissions);
          let old = Atomic.get current in
          publish
            { old with
              snapshot =
                { old.snapshot with
                  unlock = (C.state !core).snapshot.unlock
                ; startup =
                    { old.snapshot.startup with
                      awaiting_e2ee_password = false
                    ; failure = None
                    }
                ; last_error_attention = None; last_error = None
                }
            };
          let delay =
            if Sys.getenv_opt "JOURNAL_UNLOCK_SYNTHETIC_HOST" = Some "1" then 30. else 8.
          in
          let deadline = Unix.gettimeofday () +. delay in
          while (not (Atomic.get release)) && Unix.gettimeofday () < deadline do
            Eio.Time.Mono.sleep (W.Request_context.clock context) 0.01
          done;
          if attach_mirror then (
            let private_key = List.find_map (function
              | C.Run (C.Request (ticket, C.Unlock_private_key _)) -> Some (C.step !core
                  (C.Runner_completed (C.Completion (ticket, Ok ()))))
              | _ -> None) unlocking.effects |> Option.get in
            let graph_key = List.find_map (function
              | C.Run (C.Request (ticket, C.Fetch_and_unlock_graph_key request)) ->
                Some (C.step private_key.next (C.Runner_completed (C.Completion
                  (ticket, Ok (C.graph_key_handle ~id:"synthetic-key" ~scope:request.scope)))))
              | _ -> None) private_key.effects |> Option.get in
            let attach = List.find_map (function C.Delegate (C.Attach_graph request) -> Some request
              | _ -> None) graph_key.effects |> Option.get in
            let token = Logseq_overlay_db.Types.sync_token_of_string "sync-token:v1:synthetic-unlock"
              |> Result.get_ok in
            let sync = Logseq_overlay_db.Types.sync_view ~token
              ~checkpoint:(server_cursor_of_int 51) ~submissions:[] in
            let completed = C.step graph_key.next (C.Graph_attached { scope = attach.scope; sync }) in
            core := completed.next;
            let attached =
              { old with snapshot = { old.snapshot with
                  unlock = (C.state !core).snapshot.unlock
                ; applied_server_t = Some (server_cursor_of_int 51)
                ; timeline_presentation_pending = true
                ; startup = { old.snapshot.startup with
                    awaiting_e2ee_password = false; restoring_local = false
                  ; local_access = Service.Local_available; failure = None }
                ; last_error_attention = None; last_error = None } }
            in
            let manager_changed () = publish attached in
            let graph_changed () =
              Atomic.set graph_phase Logseq_db_worker.Graph_open;
              W.Request_context.emit context ~topic:Service.graph_state_topic
                (Service.Graph_state_changed
                   { generation = 1; graph_id = Some graph_id; phase = Graph_open; error = None })
            in
            (if graph_first then graph_changed else manager_changed) ();
            Atomic.set attachment_stage 1;
            while not (Atomic.get finish_attachment) do
              Eio.Time.Mono.sleep (W.Request_context.clock context) 0.001
            done;
            (if graph_first then manager_changed else graph_changed) ();
            Atomic.set attachment_stage 2)
          else (
            let failed = List.find_map (function
              | C.Run (C.Request (ticket, C.Unlock_private_key _)) -> Some (C.step !core
                  (C.Runner_completed (C.Completion (ticket,
                    Error (C.Effect_failed "Could not unlock the graph. Check your encryption password and try again.")))))
              | _ -> None) unlocking.effects |> Option.get in
            core := failed.next;
            publish
            { manager with
              snapshot =
                { manager.snapshot with
                  unlock = (C.state !core).snapshot.unlock
                ; startup = { manager.snapshot.startup with failure = Some During_e2ee }
                ; last_error =
                    Some
                      "Could not unlock the graph. Check your encryption password and \
                       try again."
                }
            });
          Ok Service.Client_command_completed
        | Client_command (Acknowledge_timeline_presented scope) ->
          on_timeline_presented scope;
          let value = Atomic.get current in
          publish { value with snapshot = { value.snapshot with timeline_presentation_pending = false } };
          Ok Service.Client_command_completed
        | Client_command Return_to_graph_picker ->
          publish
            { manager with
              snapshot =
                { manager.snapshot with
                  selected_graph = None
                ; unlock = C.Unlock_inactive
                ; startup =
                    { manager.snapshot.startup with
                      awaiting_selection = true
                    ; awaiting_e2ee_password = false
                    }
                }
            };
          Ok Service.Client_command_completed
        | Client_command (Request_sign_in scope) ->
          let value = Atomic.get current in
          let startup = value.snapshot.startup in
          if scope.account_generation = startup.account_generation
             && scope.presentation_generation = startup.presentation_generation
          then publish value;
          Ok Service.Client_command_completed
        | Client_command (Select_graph _) ->
          publish manager;
          Ok Service.Client_command_completed
        | Client_command (Reconcile_authenticated_user { user_id }) ->
          on_auth_handled user_id (W.Request_context.request_id context);
          Ok Service.Client_command_completed
        | Client_command _ | Asset_command _ | Release_asset_file _ ->
          Ok Service.Client_command_completed
        | Acquire_asset_file _ | Acquire_imported_file _ -> Ok (Service.Asset_file None)
        | Graph_request request when attach_mirror ->
          let module P = Logseq_db_worker.Protocol in
          let outcome = match request.command with
            | P.V2_graph_info -> P.V2_graph_info_outcome
                { graph_uuid = graph_id; graph_name = "Synthetic"
                ; schema = { major = 65; minor = 33 }; admission_facts = []
                ; journal_title_format = None
                ; limits = { response_budget_bytes = P.maximum_response_bytes
                  ; outbox_max_records = 4096; outbox_max_bytes = 8388608
                  ; change_max_items = 4096; change_max_bytes = 1048576
                  ; dispatcher_capacity = 256; wire_batch_max_bytes = 262144 }
                ; generation = "g"; projection_revision = "p" }
            | V2_list_journals _ -> P.V2_journals_outcome { items = []; next_cursor = None }
            | _ -> P.V2_failed { code = "UnusedFixtureRead"; message = "Unused unlock fixture read" }
          in
          Ok (Service.Graph_response (P.V2_response
            { api_version = P.api_version; request_id = request.request_id; outcome }))
        | Import_asset _ | Graph_request _ ->
          Error "Unused isolated password fixture command")
      ~shutdown:(fun () -> ())
      ()
  in
  let hooks =
    Application.For_testing.app_with_service
      ~on_client:(fun value -> client := Some value; if fail_init then failwith "synthetic init failure")
      ?on_platform_request
      worker
  in
  hooks, submissions, release, client
;;

let test_failed_init_disposes_context () =
  (* Startup failure belongs to the public native hook, outside Root_navigation. *)
  let hooks, _, release, client = unlock_fixture ~fail_init:true () in
  let startup = Logseq_db_worker.Config.create
      ~application_support_directory:"/tmp/journal-init-synthetic"
      ~target:(Managed_sync {base_url="https://example.invalid"})
      ~compatibility_profile:Logseq_65_33_or_newer
      ~response_budget_bytes:Logseq_db_worker.Protocol.maximum_response_bytes
      ~default_page_size:Logseq_db_worker.Protocol.default_page_size
      |> Result.get_ok |> Journal_startup.encode |> Result.get_ok |> Bytes.to_string in
  Fun.protect ~finally:(fun () -> Atomic.set release true; ignore(hooks.dispose());
    Option.iter Logseq_db_worker_lui.Journal_worker_runtime.stop !client) (fun () ->
      let failed = try ignore(hooks.init 2 2 startup); false with Failure _ -> true in
      Alcotest.(check bool) "init exception reaches native boundary" true failed;
      Alcotest.(check int) "failed startup releases its mounted context" 0 (hooks.root_node ()))
;;

let test_repeated_native_sign_in_intent_receives_permission () =
  let requests = ref [] in
  let hooks, _, release, client =
    unlock_fixture ~on_platform_request:(fun bytes -> requests := Bytes.copy bytes :: !requests) ()
  in
  let permit_count () =
    List.fold_left (fun count bytes ->
      if Bytes.length bytes >= 8 && Bytes.get_uint16_le bytes 6 = 30 then count + 1 else count)
      0 !requests
  in
  let wait label predicate =
    let deadline = Unix.gettimeofday () +. 2. in
    while not (predicate ()) && Unix.gettimeofday () < deadline do
      ignore (hooks.pump ());
      Unix.sleepf 0.001
    done;
    Alcotest.(check bool) label true (predicate ())
  in
  let startup =
    Logseq_db_worker.Config.create
      ~application_support_directory:"/tmp/journal-online-permission-synthetic"
      ~target:(Managed_sync { base_url = "https://example.invalid" })
      ~compatibility_profile:Logseq_65_33_or_newer
      ~response_budget_bytes:Logseq_db_worker.Protocol.maximum_response_bytes
      ~default_page_size:Logseq_db_worker.Protocol.default_page_size
    |> Result.get_ok |> Journal_startup.encode |> Result.get_ok |> Bytes.to_string
  in
  let send_intent ?(tag = 34) account_generation presentation_generation =
    let scope : Service.startup_scope = { account_generation; presentation_generation } in
    let bytes = Journal_platform.scoped_online_requested_request scope |> Bytes.copy in
    Bytes.set_uint16_le bytes 6 tag;
    hooks.platform_event (Bytes.to_string bytes)
  in
  Fun.protect
    ~finally:(fun () ->
      Atomic.set release true;
      ignore (hooks.dispose ());
      Option.iter Logseq_db_worker_lui.Journal_worker_runtime.stop !client)
    (fun () ->
      ignore (hooks.init 2 2 startup);
      wait "initial Online_by_user permission" (fun () -> permit_count () >= 1);
      requests := [];
      send_intent 1 2;
      wait "same-phase sign-in receives permission" (fun () -> permit_count () >= 1);
      send_intent 1 2;
      wait "reopened sign-in receives permission" (fun () -> permit_count () >= 2);
      let before = permit_count () in
      send_intent 0 0;
      for _ = 1 to 100 do ignore (hooks.pump ()); Unix.sleepf 0.001 done;
      Alcotest.(check int) "stale startup intent cannot grant permission" before (permit_count ());
      send_intent ~tag:35 1 2;
      send_intent 1 2;
      for _ = 1 to 100 do ignore (hooks.pump ()); Unix.sleepf 0.001 done;
      Alcotest.(check int) "queued cancellation fences old-scope retry" before (permit_count ()))
;;

(* Local-account completion and request continuations belong to Application,
   not Root_navigation. Drive a genuine failed platform request and its Retry. *)
let test_local_account_failure_retries_local_discovery ?(typed_reason=false) ?(retired_scope=false) () =
  let requests = ref [] in
  let hooks, _, release, client = unlock_fixture ~cold_start:true
      ~on_platform_request:(fun bytes -> requests := !requests @ [Bytes.copy bytes]) () in
  let props = Hashtbl.create 32 in
  let teardown=track_json_wire_teardown (Hashtbl.remove props) in
  let consume patch = if patch <> "" then
    let open Yojson.Safe.Util in
    Yojson.Safe.from_string patch |> member "ops" |> to_list |> List.iter (fun op ->
      teardown op;
      match member "op" op |> to_string with
      | "create-node" | "create-extension" -> Hashtbl.replace props (member "id" op |> to_int) []
      | "set-prop" | "set-extension-prop" ->
        let id=member "id" op |> to_int in
        let key=member "property" op |> to_string in
        let old=Option.value (Hashtbl.find_opt props id) ~default:[] in
        Hashtbl.replace props id ((key,member "value" op)::List.remove_assoc key old)
      | _ -> ()) in
  let find name = Hashtbl.fold (fun id props found ->
    if List.assoc_opt "accessibility-identifier" props = Some (`String name) then Some id else found) props None in
  let local_requests () = List.filter (fun bytes -> Bytes.get_uint16_le bytes 6 = 20) !requests in
  let wait label predicate =
    let deadline=Unix.gettimeofday () +. 2. in
    while not (predicate ()) && Unix.gettimeofday () < deadline do consume (hooks.pump ()); Unix.sleepf 0.001 done;
    Alcotest.(check bool) label true (predicate ()) in
  let config=Logseq_db_worker.Config.create ~application_support_directory:"/tmp/journal-local-retry-synthetic"
      ~target:(Managed_sync {base_url="https://example.invalid"}) ~compatibility_profile:Logseq_65_33_or_newer
      ~response_budget_bytes:Logseq_db_worker.Protocol.maximum_response_bytes
      ~default_page_size:Logseq_db_worker.Protocol.default_page_size
      |> Result.get_ok |> Journal_startup.encode |> Result.get_ok |> Bytes.to_string in
  Fun.protect ~finally:(fun () -> Atomic.set release true; ignore(hooks.dispose ());
      Option.iter Logseq_db_worker_lui.Journal_worker_runtime.stop !client) (fun () ->
    consume (hooks.init 2 2 config);
    wait "local discovery requested" (fun () -> local_requests () <> []);
    let typed_failure account =
      let bytes=Bytes.make 24 '\000' in
      Bytes.blit_string "LJF1" 0 bytes 0 4;
      Bytes.set_uint16_le bytes 4 20; Bytes.set_uint16_le bytes 6 9;
      Bytes.set_int64_le bytes 8 account;
      Bytes.to_string bytes in
    if retired_scope then (
      hooks.platform_failure (typed_failure 999L);
      for _=1 to 20 do consume(hooks.pump()); Unix.sleepf 0.001 done;
      Alcotest.(check bool) "retired native scope cannot fail current discovery" true
        (Option.is_none(find "journal-startup-retry")));
    hooks.platform_failure (if typed_reason then typed_failure 0L
      else Bytes.to_string (List.hd (local_requests ())));
    wait "transient local failure retains a local Retry" (fun () -> Option.is_some (find "journal-startup-retry"));
    if typed_reason then (
      consume(hooks.dispatch(Lui_protocol.Press(Option.get(find "journal-startup-diagnostics"))));
      wait "typed platform reason reaches mounted diagnostics" (fun () -> Hashtbl.fold (fun _ props found -> found ||
        List.assoc_opt "text" props=Some(`String "native.platform.network · The native account request could not connect. Check your connection and retry.")) props false))
    else (
      let before=List.length (local_requests ()) in
      consume (hooks.dispatch (Lui_protocol.Press (Option.get (find "journal-startup-retry"))));
      wait "Retry reissues local discovery" (fun () -> List.length (local_requests ()) = before+1));
    Alcotest.(check bool) "local retry requests no online permission" false
      (List.exists (fun bytes -> Bytes.get_uint16_le bytes 6 = 30) !requests))
;;

(* The App owns deferred admission; public Worker delivery lets a newer native
   event run before a capacity-release callback, without replacing either owner. *)
let test_pending_auth_never_replays_older_identity ~newer_accepted () =
  let module W = Logseq_db_worker_lui.Journal_worker in
  let observed = ref [] in
  let ready = ref false in
  let newer_request = Atomic.make None in
  let hooks, _, release, client = unlock_fixture ~queue_full:true
      ~on_platform_request:(fun bytes -> if Bytes.length bytes >= 8 && Bytes.get_uint16_le bytes 6 = 30 then ready := true)
      ~on_auth_classified:(fun user -> observed := !observed @ [user])
      ~on_auth_handled:(fun user request_id ->
        if user = Some "B" then Atomic.set newer_request (Some request_id)) () in
  let wait label predicate =
    let deadline = Unix.gettimeofday () +. 2. in
    while not (predicate ()) && Unix.gettimeofday () < deadline do Unix.sleepf 0.001 done;
    Alcotest.(check bool) label true (predicate ())
  in
  let payload user =
    let json = Yojson.Safe.to_string (`Assoc ["userId",`String user;
      "startupScope",`Assoc ["accountGeneration",`Int 1;"presentationGeneration",`Int 2]]) |> Bytes.of_string in
    let bytes = Bytes.make (32 + Bytes.length json) '\000' in
    Bytes.blit_string "LJP2" 0 bytes 0 4;
    Bytes.set_uint16_le bytes 4 2; Bytes.set_uint16_le bytes 6 7;
    Bytes.set_int32_le bytes 24 (Int32.of_int (Bytes.length json));
    Bytes.blit json 0 bytes 32 (Bytes.length json);
    Bytes.to_string bytes
  in
  let idle client =
    let metrics = W.Private.metrics (W.Private.pack_client client) in
    metrics.queued_requests = 0 && metrics.active_request_fibers = 0
    && W.For_testing.pending_output_count client = 0
  in
  let startup = Logseq_db_worker.Config.create
    ~application_support_directory:"/tmp/journal-auth-order-synthetic"
    ~target:(Managed_sync {base_url="https://example.invalid"})
    ~compatibility_profile:Logseq_65_33_or_newer
    ~response_budget_bytes:Logseq_db_worker.Protocol.maximum_response_bytes
    ~default_page_size:Logseq_db_worker.Protocol.default_page_size
    |> Result.get_ok |> Journal_startup.encode |> Result.get_ok |> Bytes.to_string in
  Fun.protect ~finally:(fun () -> Atomic.set release true; ignore (hooks.dispose ());
    Option.iter Logseq_db_worker_lui.Journal_worker_runtime.stop !client) (fun () ->
    ignore (hooks.init 2 2 startup);
    wait "initial manager available" (fun () -> ignore (hooks.pump ());
      !ready && (match !client with Some c -> idle c | None -> false));
    let client = Option.get !client in
    let completed_graph_reads = Hashtbl.create 64 in
    let completed_commands = Hashtbl.create 4 in
    W.on_event client (function
      | W.Response { request_id; outcome = Completed (Service.Graph_state _); _ } ->
        Hashtbl.replace completed_graph_reads request_id ()
      | W.Response { request_id; outcome = Completed Service.Client_command_completed; _ } ->
        Hashtbl.replace completed_commands request_id ()
      | _ -> ());
    let filled_requests = ref [] in
    let rec fill remaining = if remaining = 0 then failwith "fixture did not fill" else
      match W.send client Service.Get_graph_state with
      | Accepted request_id -> filled_requests := request_id :: !filled_requests; fill (remaining - 1)
      | Full -> () | _ -> failwith "fixture stopped" in
    fill 128;
    hooks.platform_event (payload "A"); ignore (hooks.pump ());
    Alcotest.(check bool) "older native identity reached Full admission" true (List.mem (Some "A") !observed);
    hooks.platform_event (payload "B");
    if newer_accepted then (
      Atomic.set release true;
      wait "response can release capacity" (fun () -> W.For_testing.pending_output_count client > 0);
      W.Private.deliver client ~max_events:1);
    ignore (hooks.pump ());
    Alcotest.(check bool) "newer native identity reached admission" true (List.mem (Some "B") !observed);
    Atomic.set release true;
    (* Queue/active/output counts can all be zero between dequeue and handler
       activation. Settle the actual accepted requests instead: B's response also
       proves its Latest control barrier was applied before its data handler. *)
    wait "deferred commands drained" (fun () ->
      ignore (hooks.pump ());
      List.for_all (Hashtbl.mem completed_graph_reads) !filled_requests
      && match Atomic.get newer_request with
         | None -> false
         | Some request_id -> Hashtbl.mem completed_commands request_id);
    let rec after_newer = function [] -> [] | Some "B" :: rest -> rest | _ :: rest -> after_newer rest in
    Alcotest.(check bool) "older identity never re-enters Latest after newer verification" false
      (List.mem (Some "A") (after_newer !observed)))
;;

let capture_unlock_logs run =
  let path = Filename.temp_file "journal-unlock-ui-log-" "" in
  let saved = Unix.dup Unix.stderr in
  let output = Unix.openfile path [ Unix.O_WRONLY; Unix.O_TRUNC ] 0o600 in
  let previous = Sys.getenv_opt "JOURNAL_UNLOCK_DIAGNOSTICS" in
  Unix.putenv "JOURNAL_UNLOCK_DIAGNOSTICS" "1";
  Unix.dup2 output Unix.stderr;
  Fun.protect
    ~finally:(fun () ->
      flush stderr;
      Unix.dup2 saved Unix.stderr;
      Unix.close saved;
      Unix.close output;
      Unix.putenv "JOURNAL_UNLOCK_DIAGNOSTICS" (Option.value previous ~default:"");
      Sys.remove path)
    (fun () ->
       run ();
       flush stderr;
       In_channel.with_open_bin path In_channel.input_all)
;;

let run_unlock_application ?(worker_failure = false) ?(queue_full = false)
    ?(stopping = false) ?(check_diagnostics = false) ?(native_report = false)
    ?(native_report_unknown = false) ?malformed_platform () =
  let hooks, submissions, release, client = unlock_fixture ~worker_failure ~queue_full () in
  let props = Hashtbl.create 64 in
  let track_teardown = track_json_wire_teardown (Hashtbl.remove props) in
  let consume encoded =
    if encoded <> ""
    then
      let open Yojson.Safe.Util in
      Yojson.Safe.from_string encoded
      |> member "ops"
      |> to_list
      |> List.iter (fun op ->
        track_teardown op;
        let id = op |> member "id" in
        match op |> member "op" |> to_string with
        | "create-node" | "create-extension" -> Hashtbl.replace props (to_int id) []
        | "set-prop" | "set-extension-prop" ->
          let id = to_int id in
          let previous = Option.value (Hashtbl.find_opt props id) ~default:[] in
          let key = op |> member "property" |> to_string in
          Hashtbl.replace
            props
            id
            ((key, member "value" op) :: List.remove_assoc key previous)
        | _ -> ())
  in
  let find key value =
    Hashtbl.fold
      (fun id values found ->
         if List.assoc_opt key values = Some (`String value) then Some id else found)
      props
      None
  in
  let node name =
    match find "accessibility-identifier" name with
    | Some id -> id
    | None -> failwith ("Missing " ^ name)
  in
  let property id key = List.assoc_opt key (Hashtbl.find props id) in
  let dispatch event = consume (hooks.dispatch event) in
  let wait label predicate =
    let deadline = Unix.gettimeofday () +. 5. in
    while (not (predicate ())) && Unix.gettimeofday () < deadline do
      consume (hooks.pump ());
      Unix.sleepf 0.001
    done;
    Alcotest.(check bool) label true (predicate ())
  in
  let startup =
    Logseq_db_worker.Config.create
      ~application_support_directory:"/tmp/journal-unlock-synthetic"
      ~target:(Managed_sync { base_url = "https://example.invalid" })
      ~compatibility_profile:Logseq_65_33_or_newer
      ~response_budget_bytes:Logseq_db_worker.Protocol.maximum_response_bytes
      ~default_page_size:Logseq_db_worker.Protocol.default_page_size
    |> Result.get_ok
    |> Journal_startup.encode
    |> Result.get_ok
    |> Bytes.to_string
  in
  Fun.protect
    ~finally:(fun () ->
      Atomic.set release true;
      ignore (hooks.dispose ());
      Option.iter Logseq_db_worker_lui.Journal_worker_runtime.stop !client)
    (fun () ->
       consume (hooks.init 2 2 startup);
       wait "password page mounts" (fun () ->
         Option.is_some (find "accessibility-identifier" "e2ee-password-editor"));
       dispatch (Lui_protocol.Submit (node "e2ee-password-editor"));
       Alcotest.(check int)
         "empty Return sends nothing"
         0
         (List.length (Atomic.get submissions));
       dispatch (Lui_protocol.TextChanged (node "e2ee-password-editor", "   "));
       dispatch (Lui_protocol.Submit (node "e2ee-password-editor"));
       Alcotest.(check int)
         "blank Return sends nothing"
         0
         (List.length (Atomic.get submissions));
       if stopping then Option.iter Logseq_db_worker_lui.Journal_worker_runtime.stop !client;
       if queue_full then (
         let client = Option.get !client in
         let module W = Logseq_db_worker_lui.Journal_worker in
         let rec fill remaining =
           if remaining = 0 then failwith "Unlock queue did not saturate"
           else (
             match W.send client Service.Get_graph_state with
             | W.Accepted _ -> fill (remaining - 1)
             | Full -> ()
             | Not_ready | Stopping -> failwith "Unlock queue unexpectedly unavailable")
         in
         fill 2048);
       dispatch
         (Lui_protocol.TextChanged (node "e2ee-password-editor", " synthetic-only "));
       dispatch (Lui_protocol.Submit (node "e2ee-password-editor"));
       if worker_failure || queue_full || stopping then (
         wait "worker failure releases unlock pending" (fun () ->
           property (node "e2ee-password-editor") "enabled" = Some (`Bool true));
         Alcotest.(check int) "failure bypasses no crypto service" 0
           (List.length (Atomic.get submissions));
         if native_report then (
           let extension = Hashtbl.fold (fun id values found ->
             if List.mem_assoc "payload" values then Some id else found) props None |> Option.get in
           consume (hooks.extension_event extension "event"
             (if native_report_unknown then
                {|{"id":-1,"payload":"diagnostic.nativePropsDecode.SECRET /private/token"}|}
              else {|{"id":-1,"payload":"diagnostic.nativePropsDecode.keyNotFound"}|})));
         Option.iter (fun kind ->
           (if kind="response" then hooks.platform_response else hooks.platform_failure) "short";
           consume(hooks.pump())) malformed_platform;
         if check_diagnostics || native_report || Option.is_some malformed_platform then (
           dispatch (Lui_protocol.Press (node "journal-startup-diagnostics"));
           wait "current failure is retained in existing Diagnostics" (fun () ->
             Option.is_some (find "text" (match malformed_platform with
               | Some "response" -> "decodePlatformResponse"
               | Some _ -> "decodePlatformFailure"
               | None -> if native_report then "decodeNativeProps" else "submitE2eePassword")));
           if native_report then (
             let message = if native_report_unknown then
               "native.decodeNativeProps.unknown · The native operation could not finish. Retry the operation."
               else "native.decodeNativeProps.keyNotFound · A required native field is missing." in
             wait "native finite reason reaches the mounted ledger" (fun () -> Option.is_some(find "text" message));
             Alcotest.(check bool) "unrecognized native suffix is not displayed" true
               (Option.is_none(find "text" "diagnostic.nativePropsDecode.SECRET /private/token")));
           Alcotest.(check bool) "diagnostic excludes submitted password" true
             (Option.is_none (find "text" " synthetic-only "))))
       else (
       wait "Return reaches worker" (fun () -> List.length (Atomic.get submissions) = 1);
       Alcotest.(check string)
         "password bytes preserved"
         " synthetic-only "
         (List.hd (Atomic.get submissions));
       wait "pending stays on password page" (fun () ->
         Option.is_some (find "accessibility-identifier" "e2ee-password-editor")
         && property (node "e2ee-password-editor") "enabled" = Some (`Bool false));
       Alcotest.(check (option bool))
         "pending editor disabled"
         (Some false)
         (Option.map
            Yojson.Safe.Util.to_bool
            (property (node "e2ee-password-editor") "enabled"));
       dispatch (Lui_protocol.Submit (node "e2ee-password-editor"));
       Alcotest.(check int)
         "pending duplicate sends nothing"
         1
         (List.length (Atomic.get submissions));
       Atomic.set release true;
       wait "retry field reenabled" (fun () ->
         property (node "e2ee-password-editor") "enabled" = Some (`Bool true));
       dispatch (Lui_protocol.Press (node "e2ee-password-cancel"));
       wait "cancel returns to picker" (fun () ->
         Option.is_none (find "accessibility-identifier" "e2ee-password-editor"));
       let graph = find "text" "Private Journal" |> Option.get in
       dispatch (Lui_protocol.Press graph);
       (* Native list activation is exercised on Simulator. Headless assertions
         above cover the shared Return/button admission and cancel boundary. *)
       ()))
;;

let test_unlock_application () =
  let logs = capture_unlock_logs (fun () -> run_unlock_application ()) in
  let has value =
    let n = String.length value in
    let rec loop i =
      i + n <= String.length logs
      && (String.sub logs i n = value || loop (i + 1))
    in
    loop 0
  in
  List.iter (fun value -> Alcotest.(check bool) value true (has value))
    [ "source=ui"; "phase=submit"; "pending=true"; "phase=queue result=accepted"
    ; "pending=false"; "failure=e2ee" ];
  List.iter (fun value -> Alcotest.(check bool) "sensitive UI value excluded" false (has value))
    [ "synthetic-only"; "Private Journal"; "Check your encryption password" ]
;;

let test_unlock_attached_mirror ~graph_first () =
  let attachment_stage = Atomic.make 0 and finish_attachment = Atomic.make false in
  let acknowledgements = Atomic.make [] in
  let hooks, submissions, release, client =
    unlock_fixture ~attach_mirror:true ~graph_first ~attachment_stage ~finish_attachment
      ~on_timeline_presented:(fun scope ->
        Atomic.set acknowledgements (scope :: Atomic.get acknowledgements)) ()
  in
  let props = Hashtbl.create 64 and parents = Hashtbl.create 64 in
  let track = track_json_wire_teardown ~parents (Hashtbl.remove props) in
  let consume encoded =
    if encoded <> "" then (
      let open Yojson.Safe.Util in
      Yojson.Safe.from_string encoded |> member "ops" |> to_list |> List.iter (fun op ->
        track op;
        match op |> member "op" |> to_string with
        | "create-node" -> Hashtbl.replace props (op |> member "id" |> to_int) []
        | "create-extension" -> Hashtbl.replace props (op |> member "id" |> to_int)
            ["_extension", member "identifier" op]
        | "set-prop" | "set-extension-prop" ->
          let id = op |> member "id" |> to_int in
          let key = op |> member "property" |> to_string in
          let previous = Option.value (Hashtbl.find_opt props id) ~default:[] in
          Hashtbl.replace props id ((key, member "value" op) :: List.remove_assoc key previous)
        | _ -> ()))
  in
  let find key value = Hashtbl.fold (fun id values found ->
    if List.assoc_opt key values = Some (`String value) then Some id else found) props None in
  let editor () = find "accessibility-identifier" "e2ee-password-editor" in
  let property id key = List.assoc_opt key (Hashtbl.find props id) in
  let dispatch event = consume (hooks.dispatch event) in
  let wait label predicate =
    let deadline = Unix.gettimeofday () +. 5. in
    while not (predicate ()) && Unix.gettimeofday () < deadline do
      consume (hooks.pump ()); Unix.sleepf 0.001
    done;
    Alcotest.(check bool) label true (predicate ())
  in
  let startup = Logseq_db_worker.Config.create
      ~application_support_directory:"/tmp/journal-attached-unlock-synthetic"
      ~target:(Managed_sync {base_url="https://example.invalid"})
      ~compatibility_profile:Logseq_65_33_or_newer
      ~response_budget_bytes:Logseq_db_worker.Protocol.maximum_response_bytes
      ~default_page_size:Logseq_db_worker.Protocol.default_page_size
      |> Result.get_ok |> Journal_startup.encode |> Result.get_ok |> Bytes.to_string in
  Fun.protect ~finally:(fun () ->
    Atomic.set release true; Atomic.set finish_attachment true;
    ignore (hooks.dispose ());
    Option.iter Logseq_db_worker_lui.Journal_worker_runtime.stop !client) (fun () ->
    consume (hooks.init 2 2 startup);
    wait "existing mirror asks for password" (fun () -> Option.is_some (editor ()));
    dispatch (Lui_protocol.TextChanged (Option.get (editor ()), "synthetic-only"));
    dispatch (Lui_protocol.Submit (Option.get (editor ())));
    wait "submission reaches worker" (fun () -> Atomic.get submissions <> []);
    wait "local availability alone keeps submission pending" (fun () ->
      Option.fold ~none:false ~some:(fun id -> property id "enabled" = Some (`Bool false)) (editor ()));
    Atomic.set release true;
    wait "first attachment notification" (fun () -> Atomic.get attachment_stage = 1);
    if not graph_first then
      wait "attached manager releases password before graph notification" (fun () -> Option.is_none (editor ()));
    Alcotest.(check int) "attachment cannot acknowledge a hidden Timeline" 0
      (List.length (Atomic.get acknowledgements));
    Atomic.set finish_attachment true;
    wait "attached mirror exits password page" (fun () -> Option.is_none (editor ()));
    wait "Timeline mounts before Ready acknowledgement" (fun () -> Option.is_some (find "_extension" "journal-list"));
    let rec appear id =
      let parent = Hashtbl.find_opt parents id in
      if property id "appear-enabled" = Some (`Bool true) then dispatch (Lui_protocol.Appear id);
      Option.iter appear parent
    in
    appear (Option.get (find "_extension" "journal-list"));
    wait "Timeline retains first appearance acknowledgement" (fun () -> Atomic.get acknowledgements <> []);
    let scope : Service.timeline_scope = List.hd (Atomic.get acknowledgements) in
    Alcotest.(check int) "acknowledgement uses current account" 1 scope.startup.account_generation;
    Alcotest.(check int) "acknowledgement uses current graph generation" 1 scope.graph_generation;
    Alcotest.(check string) "acknowledgement uses selected graph"
      "00000000-0000-0000-0000-000000000901"
      (Logseq_db_types.Graph_types.Uuid.to_string scope.graph_id))
;;

(* Root_navigation public reducer events do not own platform continuations,
   Worker.send admission, or token-cache effects. A pure reducer cannot produce
   Full here. Exercise the narrow production Application adapter with the real
   graph Service, a real opaque challenge and a valid host envelope. The token
   is invalid by design so token resolution occurs before any HTTP request. *)
let test_application_token_control ~saturated ~failure () =
  let module W = Logseq_db_worker_lui.Journal_worker in
  let module R = Logseq_db_worker_lui.Journal_worker_runtime in
  let module S = Logseq_db_worker_lui.Logseq_db_worker_lui_service in
  let module SyncR = Logseq_sync_effect_runner.Effect_runner in
  let support = Filename.temp_file "journal-token-control-" "" in
  Sys.remove support;
  Unix.mkdir support 0o700;
  let rec remove path =
    if Sys.is_directory path
    then (
      Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path)
    else Sys.remove path
  in
  let wait label f =
    let deadline = Unix.gettimeofday () +. 2. in
    while (not (f ())) && Unix.gettimeofday () < deadline do
      Unix.sleepf 0.002
    done;
    Alcotest.(check bool) label true (f ())
  in
  let crypto =
    SyncR.crypto
      ~encrypt_aes_gcm:(fun ~key:_ ~plaintext:_ -> Error "disabled")
      ~decrypt_aes_gcm:(fun ~key:_ ~iv:_ ~ciphertext:_ -> Error "disabled")
    |> Result.get_ok
  in
  let secrets =
    SyncR.secrets
      ~unlock_private_key:
        (fun
          ~managed_sync_origin:_ ~user_id:_ ~password:_ ~private_key_package:_ ->
        Error "disabled")
      ~unlock_graph_key:(fun ~managed_sync_origin:_ ~user_id:_ ~encrypted_graph_key:_ ->
        Error "disabled")
      ~load_wrapped_graph_key:(fun ~managed_sync_origin:_ ~user_id:_ ~graph_id:_ ->
        Error (SyncR.Wrapped_graph_key_unavailable "disabled"))
      ~verify_and_save_wrapped_graph_key:
        (fun
          ~managed_sync_origin:_ ~user_id:_ ~graph_id:_ ~encrypted_graph_key:_ ->
        Error "disabled")
      ~delete_account_secrets:(fun ~managed_sync_origin:_ ~user_id:_ -> Ok ())
    |> Result.get_ok
  in
  let overlay =
    Logseq_overlay_db.Database.dependencies
      ~epoch_ms:(fun () -> 1700000000000L)
      ~monotonic_ns:Mtime_clock.elapsed_ns
      ~limits:
        Logseq_overlay_db.Types.
          { response_budget_bytes = Logseq_db_worker.Protocol.maximum_response_bytes
          ; outbox_max_records = 4096
          ; outbox_max_bytes = 8388608
          ; change_max_items = Logseq_db_worker.Protocol.maximum_changed_uuids
          ; change_max_bytes = Logseq_db_worker.Protocol.maximum_push_bytes
          ; dispatcher_capacity = 256
          ; wire_batch_max_bytes = Logseq_db_worker.Protocol.maximum_response_bytes
          }
    |> Result.get_ok
  in
  let deps =
    S.dependencies
      ~overlay
      ~secrets
      ~crypto
      ~tls_authenticator:(SyncR.system_tls_authenticator () |> Result.get_ok)
  in
  let config =
    Logseq_db_worker.Config.create
      ~application_support_directory:support
      ~target:(Managed_sync { base_url = "https://invalid.example" })
      ~compatibility_profile:Logseq_65_33_or_newer
      ~response_budget_bytes:Logseq_db_worker.Protocol.maximum_response_bytes
      ~default_page_size:Logseq_db_worker.Protocol.default_page_size
    |> Result.get_ok
  in
  let client_ref = ref None in
  let hooks =
    Application.For_testing.app_with_service
      ~on_client:(fun c -> client_ref := Some c)
      (S.create ~dependencies:deps)
  in
  Fun.protect
    ~finally:(fun () ->
      ignore (hooks.dispose ());
      Option.iter R.stop !client_ref;
      remove support)
    (fun () ->
       let patch =
         hooks.init 1 2 (Journal_startup.encode config |> Result.get_ok |> Bytes.to_string)
       in
       Alcotest.(check bool)
         "real app has a root"
         true
         (patch <> "" && hooks.root_node () <> 0);
       let client = Option.get !client_ref in
       let challenge = ref None
       and manager = ref None
       and token_error = ref None in
       W.on_event client (function
         | W.Push { payload = S.Need_id_token value; _ } -> challenge := Some value
         | W.Push { payload = S.Client_state_changed state; _ } ->
           token_error := state.snapshot.last_error; manager := Some state.snapshot.startup
         | _ -> ());
       let send request =
         match W.send client request with
         | W.Accepted _ -> ()
         | _ -> Alcotest.fail "request not accepted"
       in
       send
         (S.Client_command (Restore_local_account { user_id = "synthetic-probe-user" }));
       wait "local account scope admitted" (fun () ->
         ignore (hooks.pump ());
         Option.fold ~none:false ~some:(fun (startup : S.startup_facts) -> startup.account_generation > 0) !manager);
       let startup = Option.get !manager in
       send (S.Client_command (Request_sign_in
         {account_generation=startup.account_generation; presentation_generation=startup.presentation_generation}));
       wait "explicit online permission admitted" (fun () ->
         ignore (hooks.pump ());
         Option.fold ~none:false ~some:(fun (startup : S.startup_facts) -> startup.network_phase = S.Online_by_user) !manager);
       send
         (S.Client_command
            (Reconcile_authenticated_user { user_id = Some "synthetic-probe-user" }));
       wait "real token challenge" (fun () ->
         ignore (hooks.pump ());
         Option.is_some !challenge);
       let request = Option.get !challenge in
       let packet = Journal_platform.id_token_request request |> Bytes.to_string in
       if saturated
       then (
         for _ = 1 to 32 do
           send S.Get_graph_state
         done;
         wait "32 undrained data responses" (fun () ->
           W.For_testing.pending_output_count client = 32);
         Alcotest.(check bool)
           "ordinary lane is Full"
           true
           (W.send client S.Get_graph_state = W.Full));
       if failure
       then hooks.platform_failure packet
       else (
         let json =
           Yojson.Safe.to_string
             (`Assoc
                 [ "challengeId", `String (S.token_request_id request)
                 ; "token", `String "synthetic-invalid-token"
                 ])
         in
         let response = Bytes.make (32 + String.length json) '\000' in
         Bytes.blit_string "LJP2" 0 response 0 4;
         Bytes.set_uint16_le response 4 2;
         Bytes.set_uint16_le response 6 9;
         Bytes.set_int32_le response 24 (Int32.of_int (String.length json));
         Bytes.blit_string json 0 response 32 (String.length json);
         Alcotest.(check bool)
           "valid host envelope"
           true
           (Journal_platform.decode_id_token_response
              ~challenge_id:(S.token_request_id request)
              response
            = Ok "synthetic-invalid-token");
         hooks.platform_response (Bytes.to_string response));
       wait "token answer reaches cache without an explicit resend" (fun () ->
         ignore (hooks.pump ());
         Option.is_some !token_error);
       Alcotest.(check (option string))
         "real token wait resolved"
         (Some
            (if failure
             then "ID token is unavailable."
             else "ID token response is invalid."))
         !token_error)
;;

(* Picker presentation and native controls are owned by Application; Root_navigation
   has no public picker event. Exercise its mounted public hooks and worker lane. *)
let test_graph_picker_controls scenario () =
  let module W = Logseq_db_worker_lui.Journal_worker in
  let module P = Logseq_db_worker.Protocol in
  let uuid n = Logseq_db_types.Graph_types.Uuid.of_string
      (Printf.sprintf "94000000-0000-4000-8000-%012d" n) |> Result.get_ok in
  let first = uuid 1 and second = uuid 2 in
  let long_name = "Synthetic very long graph name — 工作笔记 and attachments across multiple lines" in
  let graph graph_id name : Service.graph =
    { graph_id; name; schema = { major = 65; minor = 33; exact = true }; encrypted = false } in
  let manager : Service.state =
    { snapshot =
        { sync_phase = Current; catalog = [graph first "Current synthetic graph"; graph second long_name]
        ; selected_graph = Some first; applied_server_t = Some (server_cursor_of_int 0)
        ; unlock = Logseq_sync_pure_reducer.Core.Unlock_inactive
        ; timeline_presentation_pending = false
        ; startup = { authenticated = scenario <> `Offline; local_access=Service.Local_available; network_phase=(if scenario = `Offline then Service.Local_only else Service.Online_by_user); catalog_loading = false; awaiting_selection = false
          ; restoring_local = false; bootstrapping = false; awaiting_e2ee_password = false
          ; failure = None; account_generation = 1; graph_generation = 1; presentation_generation = 1 }
        ; last_error_attention = None; last_error = None; local_deletion = None }
    ; diagnostics = { groups = [] } } in
  let current = Atomic.make manager and commands = Atomic.make [] in
  let inspections = Atomic.make 0 and deletions = Atomic.make [] in
  let finish_deletion = Atomic.make false in
  let deletion_terminal = ref false in
  let release_automatic_inspection = Atomic.make false in
  let automatic_inspection_returned = Atomic.make false in
  let inspection_terminals = ref 0 in
  let graph_read_started = Atomic.make false and graph_read_finished = Atomic.make false in
  let release_graph_read = Atomic.make false and graph_read_cancellations = ref 0 in
  let graph_read_cancelling = Atomic.make false and release_graph_terminal = Atomic.make false in
  let graph_read_worker = Atomic.make None in
  let graph_opens = Atomic.make 0 in
  let root_renders = ref 0 in
  let client = ref None in
  let service = W.Service.create ~push_topic_count:6
      ~concurrency:(if scenario = `Late_presence || scenario = `Late_graph_cancel
                    then Concurrent { max_in_flight = 2 } else Serial)
      ~init:(fun context _ ->
        W.Session_context.emit context ~topic:Service.manager_topic (Service.Client_state_changed manager);
        Ok ())
      ~handle:(fun context () request ->
        let publish value =
          Atomic.set current value;
          W.Request_context.emit context ~topic:Service.manager_topic (Service.Client_state_changed value) in
        match request with
        | Service.Inspect_local_copy request ->
          let index = Atomic.fetch_and_add inspections 1 in
          if scenario = `Late_presence && index = 0
          then
            Fun.protect
              ~finally:(fun () -> Atomic.set automatic_inspection_returned true)
              (fun () ->
                 while not (Atomic.get release_automatic_inspection) do
                   Eio.Fiber.yield ()
                 done);
          Ok (Service.Local_copy_inspected (request,
            if scenario = `Presence_failure || scenario = `Refresh_after_presence_failure then Error "Synthetic presence read failed. Try again."
            else Ok (if scenario = `Visible then Service.Not_downloaded else Service.Downloaded)))
        | Service.Delete_local_copy request ->
          Atomic.set deletions (request :: Atomic.get deletions);
          if scenario = `During_delete then (
            let previous = Atomic.get current in
            publish { previous with snapshot = { previous.snapshot with
              local_deletion = Some (Deletion_in_progress Deleting_mirror) } };
            while not (Atomic.get finish_deletion) do Unix.sleepf 0.001 done);
          Ok (Service.Local_copy_deleted (request, if scenario = `Failure_select then Error "Synthetic delete failed. Try again." else Ok ()))
        | Service.Get_graph_state ->
          let value = Atomic.get current in
          Ok (Service.Graph_state { generation = value.snapshot.startup.graph_generation
            ; graph_id = value.snapshot.selected_graph; phase = Graph_open; error = None })
        | Client_command command ->
          Atomic.set commands (command :: Atomic.get commands);
          let previous = Atomic.get current in
          (match command with
           | Return_to_graph_picker ->
             publish { previous with snapshot = { previous.snapshot with selected_graph = None
               ; startup = { previous.snapshot.startup with awaiting_selection = true } } }
           | Refresh_catalog _ when scenario = `Offline ->
             publish { previous with snapshot = { previous.snapshot with startup =
               { previous.snapshot.startup with authenticated = not previous.snapshot.startup.authenticated } } }
           | Refresh_catalog _ when scenario = `Refresh_failure || scenario = `Refresh_after_presence_failure ->
             publish { previous with snapshot = { previous.snapshot with
               last_error = Some "Synthetic catalog refresh failed. Try again." } }
           | Select_graph id ->
             let generation = previous.snapshot.startup.graph_generation + 1 in
             publish { previous with snapshot = { previous.snapshot with selected_graph = Some id
               ; startup = { previous.snapshot.startup with awaiting_selection = false; graph_generation = generation } } };
             W.Request_context.emit context ~topic:Service.graph_state_topic
               (Service.Graph_state_changed { generation; graph_id = Some id; phase = Graph_open; error = None })
           | _ -> ());
          Ok Service.Client_command_completed
        | Asset_command _ | Release_asset_file _ -> Ok Service.Client_command_completed
        | Acquire_asset_file _ | Acquire_imported_file _ -> Ok (Service.Asset_file None)
        | Graph_request request ->
          let outcome = match request.P.command with
            | V2_graph_info -> Atomic.incr graph_opens; P.V2_graph_info_outcome
                { graph_uuid = Option.get (Atomic.get current).snapshot.selected_graph
                ; graph_name = "Synthetic"; schema = { major = 65; minor = 33 }
                ; admission_facts = []; journal_title_format = None
                ; limits = { response_budget_bytes = P.maximum_response_bytes
                  ; outbox_max_records = 4096; outbox_max_bytes = 8388608
                  ; change_max_items = 4096; change_max_bytes = 1048576
                  ; dispatcher_capacity = 256; wire_batch_max_bytes = 262144 }
                ; generation = "g"; projection_revision = "p" }
            | V2_list_journals _ -> P.V2_journals_outcome { items = []; next_cursor = None }
            | V2_list_favorites _ when scenario = `Late_graph_cancel
                && (Atomic.get current).snapshot.selected_graph = Some first ->
              Fun.protect ~finally:(fun () ->
                Atomic.set graph_read_cancelling true;
                Eio.Cancel.protect (fun () ->
                  while not (Atomic.get release_graph_terminal) do Eio.Fiber.yield () done);
                Atomic.set graph_read_finished true) (fun () ->
                Atomic.set graph_read_worker (Some (W.Request_context.request_id context));
                Atomic.set graph_read_started true;
                while not (Atomic.get release_graph_read) do Eio.Fiber.yield () done;
                P.V2_favorites_outcome { favorites_page = None; generation = "g"
                  ; projection_revision = "p"; items = []; next_cursor = None })
            | V2_list_favorites _ when scenario = `Late_graph_cancel -> P.V2_favorites_outcome
                { favorites_page = None; generation = "g"
                ; projection_revision = "p"; items = []; next_cursor = None }
            | V2_get_asset_descriptors _ | V2_list_assets _ ->
              P.V2_assets_outcome { generation = "g"; projection_revision = "p"; items = []; next_cursor = None }
            | _ -> P.V2_failed { code = "UnusedFixtureRead"; message = "Unused graph-picker fixture read" } in
          Ok (Service.Graph_response (P.V2_response
            { api_version = P.api_version; request_id = request.request_id; outcome }))
        | Import_asset _ -> Error "Unused graph-picker fixture import")
      ~shutdown:(fun () -> ()) () in
  let hooks = Application.For_testing.app_with_service
    ~on_view_region:(fun region -> if region = "root" then incr root_renders)
    ~on_client:(fun value ->
      client := Some value;
      W.on_event value (function
        | W.Response { outcome = Completed (Service.Local_copy_deleted _); _ } ->
          deletion_terminal := true
        | W.Response { request_id; outcome = Cancelled; _ } ->
          incr inspection_terminals;
          if Atomic.get graph_read_worker = Some request_id then incr graph_read_cancellations
        | W.Response { outcome = Completed (Service.Local_copy_inspected _); _ } ->
          incr inspection_terminals
        | _ -> ())) service in
  let props = Hashtbl.create 128 in
  let retained_select = ref None and select_detached = ref false in
  let teardown = track_json_wire_teardown (fun id ->
    if !retained_select = Some id then select_detached := true;
    Hashtbl.remove props id) in
  let consume source =
    if source <> "" then
      let open Yojson.Safe.Util in
      Yojson.Safe.from_string source |> member "ops" |> to_list |> List.iter (fun op ->
        teardown op;
        match member "op" op |> to_string with
        | "create-node" | "create-extension" ->
          Hashtbl.replace props (member "id" op |> to_int) ["__kind", member "kind" op; "_extension", member "identifier" op]
        | "set-prop" | "set-extension-prop" ->
          let id = member "id" op |> to_int in
          let key = member "property" op |> to_string in
          let old = Option.value (Hashtbl.find_opt props id) ~default:[] in
          Hashtbl.replace props id ((key, member "value" op) :: List.remove_assoc key old)
        | _ -> ()) in
  let find key value = Hashtbl.fold (fun id values found ->
    if List.assoc_opt key values = Some (`String value) then Some id else found) props None in
  let node name = match find "accessibility-identifier" name with
    | Some id -> id | None -> failwith ("Missing " ^ name) in
  let press id = consume (hooks.dispatch (Lui_protocol.Press id)) in
  let wait label predicate =
    let deadline = Unix.gettimeofday () +. 3. in
    while (not (predicate ())) && Unix.gettimeofday () < deadline do
      consume (hooks.pump ()); Unix.sleepf 0.001
    done;
    Alcotest.(check bool) label true (predicate ()) in
  let config = Logseq_db_worker.Config.create
      ~application_support_directory:"/tmp/journal-graph-picker-synthetic"
      ~target:(Managed_sync { base_url = "https://example.invalid" })
      ~compatibility_profile:Logseq_65_33_or_newer
      ~response_budget_bytes:P.maximum_response_bytes ~default_page_size:P.default_page_size
      |> Result.get_ok |> Journal_startup.encode |> Result.get_ok |> Bytes.to_string in
  Fun.protect ~finally:(fun () ->
    Atomic.set finish_deletion true;
    Atomic.set release_automatic_inspection true;
    Atomic.set release_graph_read true;
    Atomic.set release_graph_terminal true;
    ignore (hooks.dispose ()); Option.iter Logseq_db_worker_lui.Journal_worker_runtime.stop !client)
    (fun () ->
      consume (hooks.init 2 2 config);
      wait "Switch graph action mounts" (fun () -> Option.is_some (find "text" "Switch graph"));
      if scenario = `Late_graph_cancel then (
        wait "Favorites action mounts" (fun () -> Option.is_some (find "accessibility-label" "Favorites"));
        press (Option.get (find "accessibility-label" "Favorites"));
        wait "old graph Favorite read is genuinely in flight" (fun () -> Atomic.get graph_read_started));
      press (Option.get (find "text" "Switch graph"));
      wait "graph list mounts" (fun () -> Option.is_some (find "accessibility-identifier" "graph-picker-list"));
      if scenario = `Late_presence then (
        let list = Option.get (find "_extension" "journal-list") in
        consume (hooks.extension_event list "event"
          {|{"id":1,"payload":"{\"type\":\"visible_range\",\"first\":1,\"last\":2}"}|});
        wait "automatic inspection is held in flight" (fun () -> Atomic.get inspections = 1));
      match scenario with
      | `Offline ->
        let delete = node ("graph-picker-delete:" ^ Logseq_db_types.Graph_types.Uuid.to_string second) in
        Alcotest.(check (option bool)) "offline deletion is disabled" (Some false)
          (Option.map Yojson.Safe.Util.to_bool (List.assoc_opt "enabled" (Hashtbl.find props delete)));
        Alcotest.(check bool) "offline deletion explains authentication" true
          (Option.is_some (find "text" "Connect your account to manage local copies."));
        (* Authentication is the only changed public manager field. Renderer
           ownership cannot be reproduced by a pure navigation reducer. *)
        press (node "graph-picker-refresh");
        wait "authenticated menu enables deletion" (fun () ->
          let delete=node ("graph-picker-delete:" ^ Logseq_db_types.Graph_types.Uuid.to_string second) in
          List.assoc_opt "enabled" (Hashtbl.find props delete) = Some (`Bool true));
        Alcotest.(check bool) "authenticated menu removes stale connection explanation" false
          (Option.is_some (find "text" "Connect your account to manage local copies."));
        press (node "graph-picker-refresh");
        wait "offline transition restores its explanation" (fun () ->
          Option.is_some (find "text" "Connect your account to manage local copies."));
        let delete=node ("graph-picker-delete:" ^ Logseq_db_types.Graph_types.Uuid.to_string second) in
        Alcotest.(check (option bool)) "offline transition disables deletion again" (Some false)
          (Option.map Yojson.Safe.Util.to_bool (List.assoc_opt "enabled" (Hashtbl.find props delete)))
      | `Refresh_failure ->
        press (node "graph-picker-refresh");
        wait "catalog refresh failure is visible" (fun () ->
          Option.is_some (find "text" "Synthetic catalog refresh failed. Try again."));
        Alcotest.(check bool) "catalog rows remain available after refresh failure" true
          (Option.is_some (find "text" long_name))
      | `Visible ->
        let before = !root_renders in
        let list = Option.get (find "_extension" "journal-list") in
        let range () = consume (hooks.extension_event list "event"
          {|{"id":1,"payload":"{\"type\":\"visible_range\",\"first\":0,\"last\":9223372036854775807}"}|}) in
        range ();
        wait "visible rows are inspected" (fun () -> Atomic.get inspections = 2
          && Option.is_some (find "text" "Download and open"));
        for _ = 1 to 10 do range (); consume (hooks.pump ()) done;
        Alcotest.(check int) "same viewport reuses presence observations" 2 (Atomic.get inspections);
        Alcotest.(check int) "presence does not reconstruct the graph catalog" before !root_renders
      | `Current ->
        Alcotest.(check bool) "current marker stays in catalog row" true
          (Option.is_some (find "text" "Current graph"));
        Alcotest.(check bool) "long name is preserved" true (Option.is_some (find "text" long_name));
        Alcotest.(check bool) "opening picker keeps selected graph" true
          ((Atomic.get current).snapshot.selected_graph = Some first)
      | `Close ->
        press (node "graph-picker-close");
        wait "close returns to retained graph" (fun () ->
          Option.is_none (find "accessibility-identifier" "graph-picker-list"));
        Alcotest.(check bool) "picker never detaches current graph" false
           (List.exists
              (function
                | Service.Return_to_graph_picker -> true
                | _ -> false)
              (Atomic.get commands))
      | `Select ->
        press (node ("graph-picker:" ^ Logseq_db_types.Graph_types.Uuid.to_string second));
        wait "name selection reaches worker" (fun () ->
           List.exists
             (function
               | Service.Select_graph id -> id = second
               | _ -> false)
             (Atomic.get commands))
      | `Late_graph_cancel ->
        press (node ("graph-picker:" ^ Logseq_db_types.Graph_types.Uuid.to_string second));
        wait "new graph is visible while old cancellation cleanup is held" (fun () ->
          Atomic.get graph_read_cancelling
          && Atomic.get graph_opens >= 2
          && Option.is_some (find "accessibility-label" "Favorites"));
        Alcotest.(check int) "old cancellation has not been delivered yet" 0 !graph_read_cancellations;
        press (Option.get (find "accessibility-label" "Favorites"));
        Atomic.set release_graph_terminal true;
        wait "real old Worker cancellation is delivered after scope switch" (fun () ->
          Atomic.get graph_read_finished && !graph_read_cancellations > 0);
        consume (hooks.pump ());
        Alcotest.(check bool) "selected scope is current" true
          ((Atomic.get current).snapshot.selected_graph = Some second);
        Alcotest.(check bool) "old graph cancellation does not publish a current sync error" true
          (Option.is_none (find "text" "Worker unavailable"))
       | `Delete_menu
       | `Cancel
       | `Confirm
       | `Reopen
       | `Failure_select
       | `Presence_failure
       | `Refresh_after_presence_failure
       | `During_delete
       | `Late_presence ->
        let stable_select = node ("graph-picker:" ^ Logseq_db_types.Graph_types.Uuid.to_string second) in
        if scenario = `Failure_select then retained_select := Some stable_select;
        ignore (node ("graph-picker-options:" ^ Logseq_db_types.Graph_types.Uuid.to_string second));
        wait "row action is exposed" (fun () -> Option.is_some (find "text" "Delete local copy"));
        press (node ("graph-picker-delete:" ^ Logseq_db_types.Graph_types.Uuid.to_string second));
        if scenario = `Presence_failure || scenario = `Refresh_after_presence_failure then (
          wait "presence failure is visible" (fun () -> Option.is_some (find "text" "Synthetic presence read failed. Try again."));
          Alcotest.(check int) "one bounded presence request" 1 (Atomic.get inspections);
          if scenario = `Refresh_after_presence_failure then (
            press (node "graph-picker-refresh");
            wait "refresh failure replaces previous local-copy message" (fun () ->
              Option.is_some (find "text" "Synthetic catalog refresh failed. Try again."))))
        else (
        wait "confirm names data loss" (fun () ->
          Hashtbl.fold (fun _ values found -> found || List.exists (fun (_, value) ->
                          match value with
                          | `String text ->
                            String.starts_with ~prefix:"Remove “" text
              && String.contains text '\n' | _ -> false) values) props false);
        Alcotest.(check bool) "requesting confirmation does not delete" false
             (List.exists
                (function
                  | Service.Delete_local_cache _ -> true
                  | _ -> false)
                (Atomic.get commands));
        let expected_inspections = if scenario = `Late_presence then 2 else 1 in
        wait "bounded presence request completes" (fun () -> Atomic.get inspections = expected_inspections);
        for _ = 1 to 8 do consume (hooks.pump ()) done;
        Alcotest.(check int) "rendering never repeats presence IO" expected_inspections (Atomic.get inspections);
        if scenario = `Cancel then (
          press (Option.get (find "text" "Cancel"));
          Alcotest.(check int) "Cancel sends no deletion" 0 (List.length (Atomic.get deletions)))
        else if scenario = `Confirm || scenario = `Reopen || scenario = `Failure_select || scenario = `During_delete || scenario = `Late_presence then (
          let confirm = Hashtbl.fold (fun id values found ->
            if List.assoc_opt "text" values = Some (`String "Delete local copy")
              && List.assoc_opt "__kind" values <> Some (`String "menu-item")
            then Some id else found) props None |> Option.get in
          press confirm;
          wait "confirmed delete reaches account-scoped worker request" (fun () -> Atomic.get deletions <> []);
          let deleted = List.hd (Atomic.get deletions) in
          Alcotest.(check bool) "deletion identity is exact" true
            (deleted.graph_id = second && deleted.account_generation = 1);
          if scenario = `During_delete then (
            wait "worker publishes deletion in flight" (fun () ->
              (Atomic.get current).snapshot.local_deletion <> None);
            for _ = 1 to 8 do consume (hooks.pump ()) done;
            press (node "graph-picker-close");
            wait "Timeline is reachable while another graph deletes" (fun () ->
              Option.is_some (find "accessibility-label" "Capture"));
            press (Option.get (find "accessibility-label" "Capture"));
            wait "current graph Capture responds during noncurrent deletion" (fun () ->
              Option.is_some (find "accessibility-identifier" "journal-capture-composer"));
            Atomic.set finish_deletion true;
            wait "noncurrent deletion reaches its terminal" (fun () -> !deletion_terminal);
            Alcotest.(check bool) "deletion completion preserves current graph composer" true
              (Option.is_some (find "accessibility-identifier" "journal-capture-composer")))
          else if scenario = `Failure_select then (
            wait "delete failure is visible" (fun () -> Option.is_some (find "text" "Synthetic delete failed. Try again."));
               Alcotest.(check bool)
                 "native List retains live interactive row during operation status \
                  changes"
                 false
                 !select_detached;
            press stable_select;
            wait "existing row callback retains its graph after failure" (fun () ->
                 List.exists
                   (function
                     | Service.Select_graph id -> id = second
                     | _ -> false)
                   (Atomic.get commands)))
          else wait "deleted graph stays available to download" (fun () -> Option.is_some (find "text" "Download and open"));
          if scenario = `Late_presence then (
            Atomic.set release_automatic_inspection true;
            wait "automatic inspection retires" (fun () ->
              Atomic.get automatic_inspection_returned && !inspection_terminals = 2);
            Alcotest.(check bool) "late pre-delete inspection cannot restore Downloaded" true
              (Option.is_some (find "text" "Download and open")));
          if scenario = `Reopen then (
            let switch id =
              let before = Atomic.get graph_opens in
              press (node ("graph-picker:" ^ Logseq_db_types.Graph_types.Uuid.to_string id));
              wait "reopened graph becomes current" (fun () -> (Atomic.get current).snapshot.selected_graph = Some id);
              wait "reopened graph handshake runs" (fun () -> Atomic.get graph_opens > before);
              wait "reopened graph presents timeline" (fun () -> Option.is_none (find "accessibility-identifier" "graph-picker-list")
                && Option.is_some (find "text" "Switch graph"));
              press (Option.get (find "text" "Switch graph"));
              wait "picker returns after reopening" (fun () -> Option.is_some (find "accessibility-identifier" "graph-picker-list")) in
            switch second;
            switch first;
            Alcotest.(check bool) "reopened copy does not keep the stale not-downloaded label" true
              (Option.is_none (find "text" "Download and open")))))
      | `Current_menu ->
        ignore (node ("graph-picker-options:" ^ Logseq_db_types.Graph_types.Uuid.to_string first));
        Alcotest.(check bool) "current protection explains switching first" true
          (Option.is_some (find "text" "Switch graphs first.")))
;;

(* Compose the production runtime's public completions with the Application
   reducer. The injected clock is a host capability, not an injected issue. *)
let test_detail_reconciliation_diagnostics mode =
  let module G = Logseq_db_types.Graph_types in
  let module P = Logseq_db_worker.Protocol in
  let module R = Journal_graph_runtime in
  let module A = Application.Root_navigation in
  let uuid s = G.Uuid.of_string s |> Result.get_ok in
  let page_id = uuid "f1000000-0000-4000-8000-000000000001" in
  let block_id = uuid "f1000000-0000-4000-9000-000000000001" in
  let fail_clock = ref false in
  let runtime = R.create ~localtime:(fun instant ->
    let tm = Unix.gmtime instant in
    if !fail_clock then {tm with tm_mday=0} else tm) () in
  let calendar = Journal_calendar.Sampler.create ~clock:(fun () -> 1_788_192_000.)
    ~localtime:Unix.gmtime () |> Journal_calendar.Sampler.sample |> Result.get_ok in
  if mode <> `Calendar then R.set_calendar runtime calendar;
  let page : G.page = {uuid=page_id; name="private-page-sentinel"; title="private-page-sentinel";
    kind=Ordinary_page; created_at_ms=1_788_192_000_000L; updated_at_ms=1_788_192_000_000L;
    recycled=false; tags=[]; properties=[]} in
  let block : G.block = {uuid=block_id; title="private-block-sentinel"; parent=page_id;
    page=page_id; order="a"; created_at_ms=1_788_192_000_000L;
    updated_at_ms=1_788_192_000_000L; refs=[]; tags=[]; properties=[]} in
  let one label = function [x] -> x | _ -> Alcotest.fail label in
  let reply request outcome = P.V2_response {api_version=P.api_version;
    request_id=request.P.request_id; outcome} in
  let step request outcome = R.receive runtime (reply request outcome) in
  let read = R.submit runtime (Journal_graph_request.Load_detail
    {block_id=G.Uuid.to_string block_id; after=None; limit=32; request_generation=9L})
    |> fun o -> one "root read" o.requests in
  let read = step read (P.V2_block_outcome (V2_present_block
    {value={block; task_status=None; rendered_page_title=page.title; tag_titles=[]}; revision="r1"}))
    |> fun o -> one "page read" o.requests in
  let read = step read (P.V2_page_outcome (V2_present_page {page; revision="p1"}))
    |> fun o -> one "children read" o.requests in
  ignore(step read (P.V2_children_outcome {parent=block_id;
    revision_scope=V2_children_revision block_id; scope_revision="c1"; items=[]; next_cursor=None}));
  let pull = R.reconcile_push runtime ~request_generation:10L
    (P.V2_changes_available {api_version=P.api_version; generation="g"; through="p2"})
    |> fun o -> one "changes read" o.requests in
  let output = step pull (P.V2_changes {generation="g"; from_exclusive=None; through="p2";
    next=None; windows=[{id="w"; predecessor="p1"; successor="p2"; block_uuids=[];
      page_uuids=[page_id]; structure_interests=[]}]}) in
  let read = List.find (fun (r:P.request) -> match r.command with
    | V2_get_page _ -> true | _ -> false) output.requests in
  if mode=`Projection then fail_clock:=true;
  if mode=`Retired then R.reset runtime;
  let completed = step read (P.V2_page_outcome (V2_present_page {page; revision="p2"})) in
  let state = A.create ~graph_generation:7 |> fun s -> A.step s (Capture_edited "retained draft") in
  let apply state = List.fold_left (fun s response -> A.step s (Completed response)) state completed.responses in
  let state = apply state in
  let rows = A.diagnostic_rows state in
  if mode=`Healthy || mode=`Retired then
    Alcotest.(check (list (pair string string))) "no false current issue" [] rows
  else (
    let operation = if mode=`Calendar then "reconcileDetailCalendar" else "reconcileDetail" in
    Alcotest.(check (option string)) "actual producer reaches Diagnostics operation"
      (Some operation) (List.assoc_opt "Operation" rows);
    Alcotest.(check (option string)) "presentation phase" (Some "presentation")
      (List.assoc_opt "Stage" rows);
    Alcotest.(check (option string)) "current graph scope" (Some "graph generation=7")
      (List.assoc_opt "Scope" rows);
    Alcotest.(check (option string)) "specific safe failure reason"
      (Some (if mode=`Calendar then "The host calendar is unavailable, so this detail refresh could not finish."
        else "The entry time could not be converted to a valid local date and time."))
      (List.assoc_opt "Reason" rows);
    Alcotest.(check bool) "usable recovery" true (Option.is_some(List.assoc_opt "Recovery" rows));
    Alcotest.(check bool) "no content" false (List.exists (fun (_,s) -> s=page.title || s=block.title) rows);
    Alcotest.(check (list (pair string string))) "active issue deduplicated" rows
      (A.diagnostic_rows (apply state));
    Alcotest.(check (list (pair string string))) "account change clears issues" []
      (A.diagnostic_rows (A.step state Account_cleared)));
  Alcotest.(check string) "nonfatal completion retains draft" "retained draft"
    (A.capture state |> Option.get |> Journal_capture.source);
  Alcotest.(check int) "duplicate completion remains retired" 0
    (List.length (step read (P.V2_page_outcome (V2_present_page {page; revision="p2"}))).responses)
;;

(* Root_navigation owns acceptance of feed completions and its issue ledger.
   Generate the failure through the real graph runtime, then retire its owner. *)
let test_integrity_attention_survives_unrelated_read_success () =
  let module A = Application.Root_navigation in
  let module G = Logseq_db_types.Graph_types in
  let request_id = G.Uuid.of_string "e1000000-0000-4000-8000-000000000001" |> Result.get_ok in
  let error = Logseq_db_worker.Error.create ~code:Corrupt_storage
    ~message:"Synthetic integrity issue" ~details:[] |> Result.get_ok in
  let failed = A.step (A.create ~graph_generation:7)
    (Completed {payload=Rejected (Worker_failure {operation="applyAuthoritative"; request_id; error})}) in
  let read_success = A.step failed (Completed {payload=Graph_ready}) in
  Alcotest.(check (option string)) "ordinary read cannot resolve integrity attention"
    (Some "Active") (List.assoc_opt "Status" (A.diagnostic_rows read_success));
  let busy = Logseq_db_worker.Error.create ~code:Storage_busy
    ~message:"Synthetic retryable read" ~details:[] |> Result.get_ok in
  let flooded = List.fold_left (fun state _ -> A.step state
    (Completed {payload=Rejected (Worker_failure {operation="read"; request_id; error=busy})}))
    read_success (List.init 40 Fun.id) in
  Alcotest.(check bool) "bounded history retains active integrity evidence" true
    (List.mem ("Reason", "Synthetic integrity issue") (A.diagnostic_rows flooded));
  Alcotest.(check (list (pair string string))) "scope retirement clears diagnostics" []
    (A.diagnostic_rows (A.step flooded Account_cleared))
;;

let test_retired_feed_failure_does_not_publish_diagnostics projection =
  let module R = Journal_graph_runtime in
  let module A = Application.Root_navigation in
  let runtime = R.create () in
  let output = R.submit runtime (Journal_graph_request.Load_feed
    {cursor=None; day_limit=(if projection then 0 else 7); root_limit = 32; request_generation=9L}) in
  let responses = if projection then output.responses else
    match output.requests with
    | [request] -> (R.fail_request runtime request ~message:"Retired transport failed.").responses
    | _ -> Alcotest.fail "expected admitted feed request" in
  Alcotest.(check int) "real producer emitted one failure" 1 (List.length responses);
  let state = A.create ~graph_generation:7
    |> fun state -> A.step state (Capture_edited "retained draft") in
  let state = A.step state (Graph_replaced {generation=8; graph_id=None}) in
  let state = List.fold_left (fun state response -> A.step state (Completed response)) state responses in
  Alcotest.(check (list (pair string string))) "retired feed cannot create a current issue" []
    (A.diagnostic_rows state)
;;

let () =
  if Sys.getenv_opt "JOURNAL_UNLOCK_SYNTHETIC_HOST" = Some "1"
  then (
    let hooks, _, _, _ = unlock_fixture () in
    Journal_bridge.register hooks)
  else Alcotest.run
    "application view"
    [ ( "diagnostic identity", [ Alcotest.test_case "actual worker identity" `Quick test_diagnostic_identity_comes_from_worker ])
    ; ( "diagnostic failure", [
      Alcotest.test_case "integrity attention survives read success and bounded history" `Quick test_integrity_attention_survives_unrelated_read_success;
      Alcotest.test_case "retired feed Worker failure is ignored" `Quick
        (fun () -> test_retired_feed_failure_does_not_publish_diagnostics false);
      Alcotest.test_case "retired feed projection failure is ignored" `Quick
        (fun () -> test_retired_feed_failure_does_not_publish_diagnostics true);
      Alcotest.test_case "mounted malformed list reaches Diagnostics" `Quick (fun () -> run_favorites_native_visibility ~malformed_native_event:`List ());
      Alcotest.test_case "mounted malformed row reaches Diagnostics" `Quick (fun () -> run_favorites_native_visibility ~malformed_native_event:`Row ());
      Alcotest.test_case "mounted malformed extension reaches Diagnostics" `Quick (fun () -> run_favorites_native_visibility ~malformed_native_event:`Extension ());
      Alcotest.test_case "reconcile calendar producer to ledger" `Quick (fun () -> test_detail_reconciliation_diagnostics `Calendar);
      Alcotest.test_case "reconcile projection producer to ledger" `Quick (fun () -> test_detail_reconciliation_diagnostics `Projection);
      Alcotest.test_case "healthy reconciliation has no issue" `Quick (fun () -> test_detail_reconciliation_diagnostics `Healthy);
      Alcotest.test_case "retired reconciliation has no issue" `Quick (fun () -> test_detail_reconciliation_diagnostics `Retired);
 Alcotest.test_case "failed init disposes context" `Quick test_failed_init_disposes_context; Alcotest.test_case "current error and clearing" `Quick test_diagnostic_phase_rows_retain_current_error
        ; Alcotest.test_case "current admission failure reaches Diagnostics" `Quick
            (fun () -> run_unlock_application ~queue_full:true ~check_diagnostics:true ())
        ; Alcotest.test_case "native extension failure reaches Diagnostics" `Quick
            (fun () -> run_unlock_application ~worker_failure:true ~native_report:true ())
        ; Alcotest.test_case "unknown native suffix uses a safe reason" `Quick
            (fun () -> run_unlock_application ~worker_failure:true ~native_report:true ~native_report_unknown:true ())
        ; Alcotest.test_case "short platform response reaches Diagnostics" `Quick
            (fun () -> run_unlock_application ~worker_failure:true ~malformed_platform:"response" ())
        ; Alcotest.test_case "short platform failure reaches Diagnostics" `Quick
            (fun () -> run_unlock_application ~worker_failure:true ~malformed_platform:"failure" ()) ])
    ; ( "direct delete", List.map (fun scenario ->
        Alcotest.test_case scenario `Quick (fun () -> run_favorites_native_visibility ~delete_scenario:scenario ()))
        ["success"; "failure"])
    ; ( "status list", List.map (fun scenario ->
        Alcotest.test_case scenario `Quick (fun () -> run_favorites_native_visibility ~status_scenario:scenario ()))
            [ "expanded"
            ; "none"
            ; "now"
            ; "waiting"
            ; "later"
            ; "select"
            ; "clear"
            ; "dismiss"
            ; "failure"
            ; "duplicate"
            ; "custom"
            ; "pagination"
            ] )
    ; ("Favorites compact title",[Alcotest.test_case "Favorite Page uses shared reference lookup" `Quick test_favorite_page_uses_shared_reference_lookup; Alcotest.test_case "page property values keep name without duplication" `Quick test_detail_page_property_value_presentation; Alcotest.test_case "root Capture only in Journals" `Quick test_root_capture_placement; Alcotest.test_case "LUI titles icons and no arrow" `Quick test_favorites_compact_shared_titles; Alcotest.test_case "page outline click and native Back" `Quick (fun () -> run_favorites_native_visibility ~check_favorite_targets:true ())])
    ; ( "local account retry", [
        Alcotest.test_case "transient failure retries local discovery" `Quick (fun () -> test_local_account_failure_retries_local_discovery ());
        Alcotest.test_case "typed native reason completes local discovery" `Quick (fun () -> test_local_account_failure_retries_local_discovery ~typed_reason:true ());
        Alcotest.test_case "retired native scope cannot fail local discovery" `Quick (fun () -> test_local_account_failure_retries_local_discovery ~retired_scope:true ())])
    ; ( "graph picker", [
        Alcotest.test_case "offline deletion is disabled with explanation" `Quick (test_graph_picker_controls `Offline);
        Alcotest.test_case "refresh failure replaces old presence failure" `Quick (test_graph_picker_controls `Refresh_after_presence_failure);
        Alcotest.test_case "catalog refresh failure is visible" `Quick (test_graph_picker_controls `Refresh_failure);
        Alcotest.test_case "current marker and long names" `Quick (test_graph_picker_controls `Current);
        Alcotest.test_case "close retains current session" `Quick (test_graph_picker_controls `Close);
        Alcotest.test_case "name switches graph" `Quick (test_graph_picker_controls `Select);
        Alcotest.test_case "old graph cancellation cannot publish a new-scope error" `Quick
          (test_graph_picker_controls `Late_graph_cancel);
        Alcotest.test_case "row deletion confirmation" `Quick (test_graph_picker_controls `Delete_menu);
        Alcotest.test_case "current row deletion protection" `Quick (test_graph_picker_controls `Current_menu);
        Alcotest.test_case "cancel deletion keeps local copy" `Quick (test_graph_picker_controls `Cancel);
        Alcotest.test_case "confirmed deletion preserves downloadable row" `Quick (test_graph_picker_controls `Confirm);
        Alcotest.test_case "presence failure is bounded and visible" `Quick (test_graph_picker_controls `Presence_failure);
        Alcotest.test_case "visible presence is bounded and cached" `Quick (test_graph_picker_controls `Visible);
        Alcotest.test_case "reopened copy invalidates absence observation" `Quick (test_graph_picker_controls `Reopen);
        Alcotest.test_case "deletion failure keeps live row callback identity" `Quick (test_graph_picker_controls `Failure_select);
        Alcotest.test_case "noncurrent deletion keeps current Timeline interactive" `Quick (test_graph_picker_controls `During_delete);
        Alcotest.test_case "late inspection cannot overwrite deletion" `Quick (test_graph_picker_controls `Late_presence)])
    ; ( "relative date chrome", [
        Alcotest.test_case "calendar boundaries and date updates" `Quick test_timeline_relative_date_headers;
        Alcotest.test_case "empty Detail navigation title" `Quick test_detail_empty_navigation_title;
        Alcotest.test_case "foreground day updates before delayed or failed feed" `Quick
          (fun () -> run_favorites_native_visibility ~calendar_change:`Day ());
        Alcotest.test_case "foreground zone updates before delayed or failed feed" `Quick
          (fun () -> run_favorites_native_visibility ~calendar_change:`Zone ())] )
    ; ( "token control transport"
      , [ Alcotest.test_case
            "full data lane host response"
            `Quick
            (test_application_token_control ~saturated:true ~failure:false)
        ; Alcotest.test_case
            "full data lane host failure"
            `Quick
            (test_application_token_control ~saturated:true ~failure:true)
        ; Alcotest.test_case
            "normal host response"
            `Quick
            (test_application_token_control ~saturated:false ~failure:false)
        ; Alcotest.test_case
            "normal host failure"
            `Quick
            (test_application_token_control ~saturated:false ~failure:true)
        ] )
    ; ( "native auth admission"
      , [ Alcotest.test_case "Full older auth is superseded by accepted newer auth" `Quick
            (fun () -> test_pending_auth_never_replays_older_identity ~newer_accepted:true ())
        ; Alcotest.test_case "Full auth retains only latest identity" `Quick
            (fun () -> test_pending_auth_never_replays_older_identity ~newer_accepted:false ()) ] )
    ; ( "native online permission"
      , [ Alcotest.test_case "same-phase sign-in acknowledges every current intent" `Quick
            test_repeated_native_sign_in_intent_receives_permission ] )
    ; ( "E2EE input"
      , [ Alcotest.test_case "Application admission and recovery" `Quick test_unlock_application
        ; Alcotest.test_case "existing mirror attach manager first" `Quick
            (test_unlock_attached_mirror ~graph_first:false)
        ; Alcotest.test_case "existing mirror attach graph first" `Quick
            (test_unlock_attached_mirror ~graph_first:true)
        ; Alcotest.test_case "Application unlock worker failure releases pending" `Quick
            (fun () -> run_unlock_application ~worker_failure:true ())
        ; Alcotest.test_case "Application unlock Full releases pending" `Quick
            (fun () -> run_unlock_application ~queue_full:true ())
        ; Alcotest.test_case "Application unlock Stopping releases pending" `Quick
            (fun () -> run_unlock_application ~stopping:true ()) ] )
    ; ( "native navigation"
      , [ Alcotest.test_case
            "retained root across actual push and native Back"
            `Quick
            (fun () -> run_favorites_native_visibility ~check_navigation:true ())
        ; Alcotest.test_case "covered target row at N=50" `Quick (fun () ->
            run_favorites_native_visibility
              ~check_navigation:true
              ~check_covered_update:true
              ~timeline_rows:50
              ())
        ; Alcotest.test_case "Detail initial staging and native range ownership" `Quick (fun () ->
            run_favorites_native_visibility ~check_detail_discovery:true ())
        ; Alcotest.test_case "Detail disabled branch explains serialized wait" `Quick (fun () ->
            run_favorites_native_visibility ~check_detail_wait:true ())
        ; Alcotest.test_case "Copy menus and replacement ownership" `Quick (fun () ->
            run_favorites_native_visibility ~check_copy:true ())
        ; Alcotest.test_case "Detail native context menu dispatch" `Quick (fun () ->
            run_favorites_native_visibility
              ~check_navigation:true
              ~check_detail_row_action:true
              ())
        ] )
    ; ( "application regions"
      , [ Alcotest.test_case
            "visible demand isolation"
            `Quick
            test_application_region_visible
        ; Alcotest.test_case
            "hidden Timeline is not constructed"
            `Quick
            test_application_region_hidden
        ; Alcotest.test_case
            "draft isolation on both destinations"
            `Quick
            test_application_region_draft
        ; Alcotest.test_case
            "append draft isolation"
            `Quick
            test_application_region_detail
        ; Alcotest.test_case "chrome sync isolation" `Quick test_application_region_chrome
        ; Alcotest.test_case
            "current chrome error action"
            `Quick
            test_application_region_error_control
        ; Alcotest.test_case
            "current reactive header controls"
            `Quick
            test_reactive_header_current_controls
        ; Alcotest.test_case
            "graph generation replaces native list"
            `Quick
            test_application_region_generation
        ; Alcotest.test_case "iOS Capture persists" `Quick test_application_ios_capture
        ; Alcotest.test_case "fixture failure releases Worker" `Quick (fun () ->
            test_fixture_exception_cleanup (Failure "fixture body failure"))
        ; Alcotest.test_case "fixture early exit releases Worker" `Quick (fun () ->
            test_fixture_exception_cleanup Exit)
        ] )
    ; ( "Detail shared Composer"
      , List.map
          (fun scenario ->
             Alcotest.test_case scenario `Quick (fun () ->
               run_favorites_native_visibility ~detail_capture:scenario ()))
          [ "text"
          ; "navigation"
          ; "duplicate"
          ; "failure"
          ; "attachments"
          ; "attachment-only"
          ; "offscreen-attachments"
          ; "selection-error"
          ; "picker-owner"
          ; "retry-imports"
          ; "attachment-limit"
          ; "interrupted-imports"
          ; "legacy-interrupted"
          ] )
    ; ( "Capture attachment imports"
      , [ Alcotest.test_case
            "ordered partial failure and staging release"
            `Quick
            (fun () -> run_favorites_native_visibility ~check_capture_imports:true ())
        ] )
    ; ( "targeted media subscriptions"
      , [ Alcotest.test_case "single Ready and Acquire N=3" `Quick (fun () ->
            run_favorites_native_visibility ~media_rows:3 ())
        ; Alcotest.test_case "single Ready and Acquire N=50" `Quick (fun () ->
            run_favorites_native_visibility ~media_rows:50 ())
        ; Alcotest.test_case "shared asset independent consumers" `Quick (fun () ->
            run_favorites_native_visibility ~media_rows:3 ~shared_media:true ())
        ; Alcotest.test_case "ready push/Back and pre-path range" `Quick (fun () ->
            run_favorites_native_visibility ~media_rows:3 ~media_navigation:`Ready ())
        ; Alcotest.test_case "in-flight acquire through Back" `Quick (fun () ->
            run_favorites_native_visibility ~media_rows:3 ~media_navigation:`Opening ())
        ; Alcotest.test_case
            "same block multiple Detail owners and final release"
            `Quick
            (fun () ->
               run_favorites_native_visibility ~media_rows:3 ~media_navigation:`Owners ())
        ; Alcotest.test_case "actual offscreen release and stale Ready" `Quick (fun () ->
            run_favorites_native_visibility ~media_rows:3 ~media_navigation:`Offscreen ())
        ; Alcotest.test_case
            "shared asset root consumers release independently"
            `Quick
            (fun () ->
               run_favorites_native_visibility
                 ~media_rows:3
                 ~shared_media:true
                 ~media_navigation:`Shared
                 ())
        ; Alcotest.test_case "graph switch retires covered owners" `Quick (fun () ->
            run_favorites_native_visibility ~media_rows:3 ~media_navigation:`Graph ())
        ; Alcotest.test_case
            "offscreen pending acquire releases stale result"
            `Quick
            (fun () ->
               run_favorites_native_visibility ~media_rows:3 ~media_navigation:`Late ())
        ; Alcotest.test_case
            "graph replacement during acquire fences old result"
            `Quick
            (fun () ->
               run_favorites_native_visibility
                 ~media_rows:3
                 ~media_navigation:`Late_graph
                 ())
        ; Alcotest.test_case
            "disposing retained navigation closes resource owner"
            `Quick
            (fun () ->
               run_favorites_native_visibility
                 ~media_rows:3
                 ~media_navigation:`Disposed
                 ())
        ; Alcotest.test_case "Detail asset appears before its root" `Quick (fun () ->
            run_favorites_native_visibility ~media_rows:3 ~media_navigation:`Leaf_first ())
        ; Alcotest.test_case
            "returning root appearance precedes Back path"
            `Quick
            (fun () ->
               run_favorites_native_visibility
                 ~media_rows:3
                 ~media_navigation:`Restore_early
                 ())
        ; Alcotest.test_case "Detail range exit retires media ownership" `Quick (fun () ->
            run_favorites_native_visibility
              ~media_rows:3
              ~media_navigation:`Detail_range_exit
              ())
        ; Alcotest.test_case "review preview offscreen reference" `Quick (fun () ->
            run_favorites_native_visibility
              ~media_rows:3
              ~media_navigation:`Preview_offscreen
              ())
        ; Alcotest.test_case "Detail range reentry after media retirement" `Quick (fun () ->
            run_favorites_native_visibility
              ~media_rows:3
              ~media_navigation:`Detail_range_reentry
              ())
        ; Alcotest.test_case
            "Detail range exit preserves Timeline shared owner"
            `Quick
            (fun () ->
               run_favorites_native_visibility
                 ~media_rows:3
                 ~media_navigation:`Detail_shared
                 ())
        ; Alcotest.test_case "Detail range exit fences pending Acquire" `Quick (fun () ->
            run_favorites_native_visibility
              ~media_rows:3
              ~media_navigation:`Detail_pending
              ())
        ; Alcotest.test_case
            "Detail actual offscreen releases child media"
            `Quick
            (fun () ->
               run_favorites_native_visibility
                 ~media_rows:3
                 ~media_navigation:`Detail_offscreen
                 ())
        ; Alcotest.test_case "Detail retirement followed by graph reset" `Quick (fun () ->
            run_favorites_native_visibility
              ~media_rows:3
              ~media_navigation:`Detail_graph
              ())
        ; Alcotest.test_case "Detail offscreen preview retains until dismissal" `Quick (fun () ->
            run_favorites_native_visibility
              ~media_rows:3
              ~media_navigation:`Detail_preview
              ())
        ; Alcotest.test_case
            "preview closes while Detail still owns file"
            `Quick
            (fun () ->
               run_favorites_native_visibility
                 ~media_rows:3
                 ~media_navigation:`Preview_navigation
                 ())
        ; Alcotest.test_case "Detail pop retires its open preview" `Quick (fun () ->
            run_favorites_native_visibility
              ~media_rows:3
              ~media_navigation:`Preview_detail_pop
              ())
        ; Alcotest.test_case "graph reset retires open preview" `Quick (fun () ->
            run_favorites_native_visibility
              ~media_rows:3
              ~media_navigation:`Preview_graph
              ())
        ; Alcotest.test_case "late Failed preserves successful preview URL" `Quick (fun () ->
            run_favorites_native_visibility
              ~media_rows:3
              ~media_navigation:`Preview_invalidated
              ())
        ; Alcotest.test_case
            "repeated preview open and close does not leak"
            `Quick
            (fun () ->
               run_favorites_native_visibility
                 ~media_rows:3
                 ~media_navigation:`Preview_repeat
                 ())
        ; Alcotest.test_case "same UUID metadata preserves preview" `Quick (fun () ->
            run_favorites_native_visibility
              ~media_rows:3
              ~media_navigation:`Preview_replaced
              ())
        ; Alcotest.test_case
            "repeated offscreen preview selection remains valid"
            `Quick
            (fun () ->
               run_favorites_native_visibility
                 ~media_rows:3
                 ~media_navigation:`Preview_duplicate
                 ())
        ] )
    ; ( "stable media identity"
      , [ Alcotest.test_case
            "retained Timeline route transitions"
            `Quick
            test_timeline_media_identity_across_detail_routes
        ; Alcotest.test_case
            "bounded body and presentation replacement"
            `Quick
            test_timeline_media_bounded_body_and_owner_replacement
        ] )
    ; ( "reference Worker terminals"
      , [ Alcotest.test_case "outer Failed releases hydration" `Quick (fun () ->
            test_reference_outer_terminals false)
        ; Alcotest.test_case
            "outer Cancelled fences late return and drains"
            `Quick
            (fun () -> test_reference_outer_terminals true)
        ] )
    ; ( "root navigation"
      , [ Alcotest.test_case "Timeline reselect ownership" `Quick
            (fun () -> run_favorites_native_visibility ~check_reselect:true ())
        ; Alcotest.test_case
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
            "current diagnostic rows are preserved"
            `Quick
            test_current_diagnostic_rows
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
