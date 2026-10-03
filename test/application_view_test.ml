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

let run_favorites_native_visibility
      ?(check_visible = false)
      ?(check_hidden = false)
      ?(check_draft = false)
      ?(check_detail = false)
      ?(check_generation = false)
      ?(check_chrome = false)
      ?(check_error_control = false)
      ?(check_ios_capture = false)
      ?media_rows
      ?(shared_media = false)
      ()
  =
  let module W = Logseq_db_worker_lui.Journal_worker in
  let module P = Logseq_db_worker.Protocol in
  let module G = Logseq_db_types.Graph_types in
  let uuid n =
    G.Uuid.of_string (Printf.sprintf "82000000-0000-4000-8000-%012d" n) |> Result.get_ok
  in
  let roots = List.init 65 (fun n -> uuid (n + 1)) in
  let graph_generation = Atomic.make 1 in
  let client = ref None in
  let publish_phase = Atomic.make None in
  let publish_error = Atomic.make None in
  let queried = Atomic.make [] in
  let feed_queried = Atomic.make false in
  let media_notices = Atomic.make [] in
  let media_delivered = Atomic.make 0 in
  let demands = Atomic.make [] in
  let retries = Atomic.make 0 in
  let acquire_entered = Atomic.make 0 in
  let acquire_release = Atomic.make false in
  let released_files = Atomic.make 0 in
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
  let timeline_block n : P.v2_block_record =
    { block =
        { uuid = List.nth roots n
        ; title = Printf.sprintf "Timeline fixture %d" n
        ; parent = page.uuid
        ; page = page.uuid
        ; order = Printf.sprintf "%03d" n
        ; created_at_ms = 1_788_192_000_000L
        ; updated_at_ms = 1_788_192_000_000L
        ; refs = []
        ; tags = []
        ; properties = []
        }
    ; task_status = None
    ; rendered_page_title = page.title
    ; tag_titles = []
    }
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
      ~merge_push:Service.coalesce_push
      ~concurrency:Serial
      ~init:(fun context _ ->
        W.Session_context.emit
          context
          ~topic:Service.manager_topic
          (Service.Client_state_changed manager);
        Ok ())
      ~handle:(fun context () request ->
        match request with
        | Service.Get_graph_state ->
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
          if sync_phase <> None || error <> None
          then
            W.Request_context.emit
              context
              ~topic:Service.manager_topic
              (Service.Client_state_changed
                 { manager with
                   snapshot =
                     { manager.snapshot with
                       sync_phase = Option.value sync_phase ~default:Service.Current
                     ; last_error = Option.value error ~default:None
                     }
                 });
          Ok
            (Service.Graph_state
               { generation = Atomic.get graph_generation
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
              V2_journals_outcome
                { items = [ { page; journal_day = 20260901; revision = "p" } ]
                ; next_cursor = None
                }
            | V2_get_page_tree _ ->
              V2_page_tree_outcome
                { page = page.uuid
                ; maximum_depth = 1
                ; items =
                    List.init (Option.value media_rows ~default:3) (fun n ->
                      { P.value = timeline_block n
                      ; revision = "root"
                      ; depth = 0
                      ; parent = page.uuid
                      })
                ; next_cursor = None
                }
            | V2_get_block { block; _ } ->
              let n = List.find_index (G.Uuid.equal block) roots |> Option.get in
              V2_block_outcome
                (V2_present_block { value = timeline_block n; revision = "root" })
            | V2_get_page _ -> V2_page_outcome (V2_present_page { page; revision = "p" })
            | V2_get_children { parent; _ } ->
              V2_children_outcome
                { parent
                ; revision_scope = V2_children_revision parent
                ; scope_revision = "children"
                ; items = []
                ; next_cursor = None
                }
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
                                      ~checksum:(String.make 64 'a')
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
            | _ -> V2_failed { code = "unsupported"; message = "Unused fixture command" }
          in
          Ok
            (Service.Graph_response
               (P.V2_response
                  { api_version = 2; request_id = request.request_id; outcome })))
      ~shutdown:(fun () -> ())
      ()
  in
  let regions = Hashtbl.create 8 in
  let hooks =
    Application.For_testing.app_with_service
      ~on_client:(fun value -> client := Some value)
      ~on_view_region:(fun name ->
        Hashtbl.replace
          regions
          name
          (1 + Option.value (Hashtbl.find_opt regions name) ~default:0))
      service
  in
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
        | "set-prop" | "set-extension-prop" ->
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
    ~finally:(fun () ->
      Atomic.set acquire_release true;
      ignore (hooks.dispose ());
      if Option.is_some media_rows
      then Option.iter Logseq_db_worker_lui.Journal_worker_runtime.stop !client)
    (fun () ->
       hooks.init 2 2 startup |> consume;
       if check_ios_capture
       then (
         let snapshot =
           { Journal_environment.fallback with
             platform = "ios"
           ; viewport_width = 390.
           ; viewport_height = 844.
           ; device_pixel_ratio = 3.
           }
         in
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
       (* Media reducers own transfer state, but cannot reproduce the defect:
          only the public mounted Application owns LUI subscription invalidation.
          Drive actual Worker notices/completions and native appearance events. *)
       if Option.is_some media_rows
       then (
         let count = Option.get media_rows in
         let all key value =
           Hashtbl.fold
             (fun id values ids ->
                if List.assoc_opt key values = Some (`String value)
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
           Alcotest.(check int)
             (label ^ " retained native list")
             list_node
             (Option.get (find "_extension" "journal-list"));
           List.iter
             (fun (title, id) ->
                Alcotest.(check int)
                  (label ^ " retains row text " ^ title)
                  id
                  (Option.get (find "text" title)))
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
         wait "Retry sends a real asset retry command" (fun () -> Atomic.get retries = 1);
         wait "Retry restores waiting presentation" (fun () ->
           List.length (all "text" "Unable to download file") = shown_count - 1);
         settle ();
         record "retry";
         check_media_counts "Retry" 1;
         Hashtbl.clear regions;
         publish (Ready "fixture-ready");
         wait "Ready enters real Acquire before completion" (fun () ->
           Atomic.get acquire_entered >= 1
           && List.length (all "text" "Opening file") = shown_count);
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
             (Option.value (Hashtbl.find_opt regions "timeline") ~default:0));
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
         wait "Favorites loaded" (fun () -> Option.is_some (find "text" "Fixture 64"));
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
           let capture = Option.get (find "accessibility-label" "Capture") in
           dispatch (Lui_protocol.Press capture);
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
             (Lui_protocol.Press (Option.get (find "accessibility-label" "Append")));
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
                (List.filter (G.Uuid.equal (List.nth roots 64)) (Atomic.get queried))))))
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
           | P.V2_get_block { block = target; _ } ->
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
                   (V2_block_outcome
                      (V2_present_block
                         { value =
                             record
                               { block with
                                 uuid = target
                               ; title = "Late cancelled target"
                               }
                         ; revision = "old"
                         })))
               else (
                 wait ();
                 Error "Injected outer Worker failure"))
             else
               completed
                 request
                 (V2_block_outcome
                    (V2_present_block
                       { value =
                           record
                             { block with
                               uuid = target
                             ; title = Printf.sprintf "Fresh target %d" index
                             }
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
           | V2_pull_changes _ ->
             completed
               request
               (V2_changes
                  { generation = "g"
                  ; from_exclusive = Some "r1"
                  ; through = "r2"
                  ; next = None
                  ; windows =
                      [ { id = "c1"
                        ; predecessor = "r1"
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
  let saw_late = ref false in
  let consume encoded =
    if encoded <> ""
    then
      let open Yojson.Safe.Util in
      Yojson.Safe.from_string encoded
      |> member "ops"
      |> to_list
      |> List.iter (fun op ->
        match op |> member "op" |> to_string with
        | "set-prop" when member "property" op = `String "text" ->
          let text = member "value" op |> to_string in
          if
            List.exists
              (fun value -> String.trim value = "Late cancelled target")
              (String.split_on_char '|' text)
          then saw_late := true;
          Hashtbl.replace texts (member "id" op |> to_int) text
        | "drop-node" -> Hashtbl.remove texts (member "id" op |> to_int)
        | _ -> ())
  in
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
  let backend : Lui_protocol.backend =
    { backend_profile = Lui_protocol.profile IOS SwiftUIHost
    ; apply_batch =
        (fun batch ->
          batches := batch :: !batches;
          List.iter
            (function
              | Lui_protocol.SetProp (id, TextValue, StringValue text) ->
                Hashtbl.replace texts id text
              | DropNode id -> Hashtbl.remove texts id
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
                    | Lui_protocol.DropNode _ -> true
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

let test_timeline_media_disclosure_and_owner_replacement () =
  with_timeline_media_row (fun app block find_text update _ ->
    let initial = Journal_routes.create () in
    ignore (Lui_app.dispatch_event app (Lui_protocol.Press (find_text "Show more")));
    ignore (Lui_app.flush app);
    ignore (find_text "Show less");
    let loading =
      Journal_routes.open_detail
        initial
        ~block_id:(Journal_model.id block)
        ~request_generation:10L
    in
    update loading 1;
    ignore (find_text "Show less");
    update (Journal_routes.back loading) 1;
    ignore (find_text "Show less");
    let original = find_text (Journal_model.source block) in
    update initial 2;
    Alcotest.(check bool)
      "new graph/runtime generation replaces the row body"
      true
      (original <> find_text (Journal_model.source block));
    ignore (find_text "Show more");
    let journals = find_text (Journal_model.source block) in
    update (Journal_routes.select_destination initial Favorites) 2;
    Alcotest.(check bool)
      "Favorites is an independent presentation owner"
      true
      (journals <> find_text (Journal_model.source block)))
;;

let test_reactive_header_current_controls () =
  let props = Hashtbl.create 128 in
  let backend : Lui_protocol.backend =
    { backend_profile = Lui_protocol.profile IOS SwiftUIHost
    ; apply_batch =
        (fun batch ->
          List.iter
            (function
              | Lui_protocol.SetProp (id, key, value) ->
                Hashtbl.replace props (id, key) value
              | RemoveProp (id, key) -> Hashtbl.remove props (id, key)
              | DropNode id ->
                Hashtbl.filter_map_inplace
                  (fun (node, _) value -> if node = id then None else Some value)
                  props
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
              ~on_account_action:(Some noop)
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
         "current cache capability exposes menu action"
         true
         (Option.is_some (find TextValue "Delete local graph copy"));
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

let () =
  Alcotest.run
    "application view"
    [ ( "application regions"
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
        ] )
    ; ( "targeted media subscriptions"
      , [ Alcotest.test_case "single Ready and Acquire N=3" `Quick (fun () ->
            run_favorites_native_visibility ~media_rows:3 ())
        ; Alcotest.test_case "single Ready and Acquire N=50" `Quick (fun () ->
            run_favorites_native_visibility ~media_rows:50 ())
        ; Alcotest.test_case "shared asset independent consumers" `Quick (fun () ->
            run_favorites_native_visibility ~media_rows:3 ~shared_media:true ())
        ] )
    ; ( "stable media identity"
      , [ Alcotest.test_case
            "retained Timeline route transitions"
            `Quick
            test_timeline_media_identity_across_detail_routes
        ; Alcotest.test_case
            "disclosure and presentation replacement"
            `Quick
            test_timeline_media_disclosure_and_owner_replacement
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
