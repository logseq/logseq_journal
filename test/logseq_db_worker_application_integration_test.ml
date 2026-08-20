module Adapter_fixture = Logseq_db_worker_test_support.Adapter_fixture
module Graph = Logseq_db_worker.Graph_types
module Host_protocol = Bonsai_flutter_protocol
module ID = Bonsai_flutter_spec.Id
module Protocol = Logseq_db_worker.Protocol
module Test = Bonsai_flutter_test
module Ui = Bonsai_flutter_ui

let fail format = Printf.ksprintf failwith format

let require condition format =
  Printf.ksprintf (fun message -> if not condition then failwith message) format
;;

let rec repository_root directory =
  if Sys.file_exists (Filename.concat directory ".git")
  then directory
  else (
    let parent = Filename.dirname directory in
    if String.equal parent directory
    then fail "unable to locate repository root"
    else repository_root parent)
;;

let source_root = repository_root (Sys.getcwd ())
let source_path relative = Filename.concat source_root relative
let uuid value = Graph.Uuid.of_string value |> Result.get_ok
let cursor value = Graph.Cursor.of_string value |> Result.get_ok

let only = function
  | [ value ] -> value
  | values -> fail "expected exactly one value, got %d" (List.length values)
;;

let request_id (request : Protocol.request) = request.request_id

let succeeded request ~basis success =
  Protocol.Succeeded { request_id = request_id request; basis; success }
;;

let page_summary ?(day = 20260809) value : Graph.page_summary =
  { uuid = uuid value
  ; name = Printf.sprintf "%08d" day
  ; title =
      Printf.sprintf "%04d-%02d-%02d" (day / 10_000) (day / 100 mod 100) (day mod 100)
  ; kind = Journal_page { journal_day = day }
  ; recycled = false
  }
;;

let block ~page ~parent ~order value : Graph.block =
  { uuid = uuid value
  ; title = "Projected journal block"
  ; parent
  ; page
  ; order
  ; created_at_ms = 1_786_204_800_000L
  ; updated_at_ms = 1_786_204_800_000L
  ; refs = []
  ; tags = []
  ; properties = []
  }
;;

let seed_fatal_test_block (fixture : Adapter_fixture.t) =
  let engine =
    Logseq_db_worker.Engine.open_
      ~dependencies:Adapter_fixture.dependencies
      fixture.config
    |> Result.get_ok
  in
  let page_uuid = uuid "00000001-2026-0809-0000-000000000000" in
  let block_uuid = uuid "95000000-0000-4000-a000-000000000001" in
  let execute mutation_id mutation =
    let request =
      Protocol.{ api_version; request_id = uuid mutation_id; command = Mutate mutation }
    in
    match Logseq_db_worker.Engine.execute engine request with
    | Succeeded _ -> ()
    | Failed failure ->
      fail "fatal test seed failed: %s" (Logseq_db_worker.Error.message failure.error)
  in
  let context mutation_id =
    Protocol.
      { mutation_id = uuid mutation_id
      ; expected_basis = Option.value (Logseq_db_worker.Engine.basis engine) ~default:0L
      }
  in
  execute
    "95000000-0000-4000-9000-000000000001"
    (Page
       (Create_page
          { title = "2026-08-09"
          ; kind =
              Create_journal_page
                { journal_day = 20260809; supplied_uuid = Some page_uuid }
          ; context = context "95000000-0000-4000-9000-000000000002"
          }));
  execute
    "95000000-0000-4000-9000-000000000003"
    (Structural
       (Insert_blocks
          { roots =
              [ { Protocol.uuid = block_uuid
                ; title = "Fatal mutation row"
                ; children = []
                }
              ]
          ; position = Relative (Last_child page_uuid)
          ; context = context "95000000-0000-4000-9000-000000000004"
          }));
  (match Logseq_db_worker.Engine.close engine with
   | Ok () -> ()
   | Error message -> fail "fatal test seed close failed: %s" message);
  Graph.Uuid.to_string block_uuid
;;

let seed_startup_feed_days (fixture : Adapter_fixture.t) count =
  let engine =
    Logseq_db_worker.Engine.open_
      ~dependencies:Adapter_fixture.dependencies
      fixture.config
    |> Result.get_ok
  in
  let execute serial mutation =
    let request_id =
      uuid (Printf.sprintf "97000000-0000-4000-9000-%012d" (serial + 1_000))
    in
    let request = Protocol.{ api_version; request_id; command = Mutate mutation } in
    match Logseq_db_worker.Engine.execute engine request with
    | Succeeded _ -> ()
    | Failed failure ->
      fail
        "startup feed seed failed: %s"
        (Logseq_db_worker.Error.message failure.error)
  in
  let context serial =
    Protocol.
      { mutation_id =
          uuid (Printf.sprintf "97000000-0000-4000-a000-%012d" (serial + 2_000))
      ; expected_basis =
          Option.value (Logseq_db_worker.Engine.basis engine) ~default:0L
      }
  in
  List.init count Fun.id
  |> List.iter (fun index ->
    let day = 20260809 - index in
    let page_uuid =
      let text = Printf.sprintf "%08d" day in
      uuid
        (Printf.sprintf
           "00000001-%s-%s-0000-000000000000"
           (String.sub text 0 4)
           (String.sub text 4 4))
    in
    let block_uuid =
      uuid (Printf.sprintf "97000000-0000-4000-b000-%012d" (index + 1))
    in
    execute
      (index * 2)
      (Page
         (Create_page
            { title = Printf.sprintf "%04d-%02d-%02d" (day / 10_000) (day / 100 mod 100) (day mod 100)
            ; kind = Create_journal_page { journal_day = day; supplied_uuid = Some page_uuid }
            ; context = context (index * 2)
            }));
    execute
      ((index * 2) + 1)
      (Structural
         (Insert_blocks
            { roots =
                [ { Protocol.uuid = block_uuid
                  ; title = Printf.sprintf "Startup feed day %d" (index + 1)
                  ; children = []
                  }
                ]
            ; position = Relative (Last_child page_uuid)
            ; context = context ((index * 2) + 1)
            })));
  match Logseq_db_worker.Engine.close engine with
  | Ok () -> ()
  | Error message -> fail "startup feed seed close failed: %s" message
;;

let encode_startup config =
  match Journal_startup.encode config with
  | Ok payload -> payload
  | Error error ->
    fail "startup encode failed: %s" (Journal_startup.Error.to_string error)
;;

let initial_calendar_packet =
  let locale = "en_US" in
  let time_zone_id = "Asia/Shanghai" in
  let header_size = 56 in
  let bytes =
    Bytes.make (header_size + String.length locale + String.length time_zone_id) '\000'
  in
  Bytes.blit_string "LJP1" 0 bytes 0 4;
  Bytes.set_uint16_le bytes 4 1;
  Bytes.set_uint16_le bytes 6 2;
  Bytes.set_uint16_le bytes 8 0;
  Bytes.set_uint16_le bytes 10 (String.length locale);
  Bytes.set_uint16_le bytes 12 (String.length time_zone_id);
  Bytes.set_int64_le bytes 16 1_786_204_800_000L;
  Bytes.set_int32_le bytes 24 20260809l;
  Bytes.set_uint16_le bytes 28 0;
  Bytes.set_int32_le bytes 32 28_800l;
  Bytes.set_int64_le bytes 40 1L;
  Bytes.set_int64_le bytes 48 0L;
  Bytes.blit_string locale 0 bytes header_size (String.length locale);
  Bytes.blit_string
    time_zone_id
    0
    bytes
    (header_size + String.length locale)
    (String.length time_zone_id);
  bytes
;;

let initialize_test_calendar handle =
  let rec wait_for_request remaining =
    if remaining = 0
    then fail "timed out waiting for the initial calendar request"
    else (
      Test.Handle.present handle;
      let request =
        match Test.Handle.last_frame handle with
        | None -> None
        | Some frame ->
          (match Host_protocol.Binary_codec.decode frame.bytes with
           | Error error -> fail "application frame did not decode: %s" error.message
           | Ok wire ->
             List.find_map
               (function
                 | Host_protocol.Wire_frame.Application_request { request_id; payload }
                   when Bytes.equal payload Journal_platform.get_calendar_request ->
                   Some request_id
                 | _ -> None)
               wire.operations)
      in
      match request with
      | Some request_id -> request_id
      | None ->
        Test.Handle.pump_next handle ();
        wait_for_request (remaining - 1))
  in
  let request_id = wait_for_request 500 in
  let event =
    Host_protocol.Inbound_event.
      { sequence = ID.Runtime.Event_sequence.of_int64 1L
      ; displayed_revision = Test.Handle.revision handle
      ; node_id = ID.Ui.Node_id.zero
      ; handler_id = ID.Ui.Handler_id.zero
      ; event_tag = Host_protocol.Generated_protocol.Event_tag.application_response
      ; payload = Application_response { request_id; payload = initial_calendar_packet }
      }
  in
  Test.Handle.pump_next
    handle
    ~events:
      Host_protocol.Inbound_event.
        { runtime_epoch = ID.Runtime.Epoch.of_int64 9_001L; events = [ event ] }
    ();
  Test.Handle.present handle;
  Test.Handle.resize handle ~width:390. ~height:844.;
  Test.Handle.present handle;
  Test.Handle.resize handle ~width:390. ~height:844.;
  Test.Handle.present handle
;;

let create_handle config =
  let handle =
    Test.Handle.create_app
      ~runtime_epoch:(ID.Runtime.Epoch.of_int64 9_001L)
      ~time_source:(Bonsai.Time_source.create ~start:Core.Time_ns.epoch)
      Application.app
      ~application_payload:(encode_startup config)
  in
  initialize_test_calendar handle;
  handle
;;

let pump_worker handle =
  Test.Handle.present handle;
  Test.Handle.pump_next handle ()
;;

let wait_for handle description predicate =
  let rec loop remaining =
    if predicate ()
    then ()
    else if remaining = 0
    then fail "timed out waiting for %s\n%s" description (Test.Handle.show handle)
    else (
      Unix.sleepf 0.001;
      pump_worker handle;
      loop (remaining - 1))
  in
  loop 1_000
;;

let has_test_id handle value =
  Option.is_some (Test.Handle.find handle (Test.Query.test_id value))
;;

let has_text handle value =
  Option.is_some (Test.Handle.find handle (Test.Query.visible_text value))
;;

let capture_composer_enabled handle =
  match Test.Handle.find handle (Test.Query.test_id "journal-capture-composer") with
  | Some node ->
    (let Av view = Ui.Widget.Private.view node.widget in
     match view.node with
     | Ui.Widget.Private.Native_widget { kind_id; payload; _ }
       when kind_id = Ui.Native_widget.Message_composer.kind_id ->
       (Ui.Native_widget.Message_composer.For_testing.decode_props_exn payload).enabled
     | _ -> fail "Capture composer is not a Message_composer")
  | None -> fail "Capture composer is not mounted"
;;

let commit_end_swipe handle block_id =
  Test.Handle.present handle;
  let query = Test.Query.test_id ("journal-row-swipe:" ^ block_id) in
  let node =
    match Test.Handle.find handle query with
    | Some node -> node
    | None -> fail "missing swipe wrapper for %s\n%s" block_id (Test.Handle.show handle)
  in
  let kind_id =
    let Av view = Ui.Widget.Private.view node.widget in
    (match view.node with
     | Ui.Widget.Private.Native_widget { kind_id; _ } -> kind_id
     | _ -> fail "delete wrapper is not a native widget")
  in
  Test.Handle.native_event
    handle
    query
    ~kind_id
    ~version:2
    ~event_id:(ID.Native_widget.Event_id.of_int 1)
    ~payload:(Bytes.make 1 '\001')
;;

let advance_clock handle seconds =
  let now = Int64.of_float (seconds *. 1_000_000_000.) in
  Test.Handle.present handle;
  ignore (Test.Handle.pump handle ~monotonic_now_ns:now ());
  Test.Handle.presentation_succeeded handle ~monotonic_now_ns:now
;;

let read_file path =
  let channel = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr channel)
    (fun () -> really_input_string channel (in_channel_length channel))
;;

let contains text needle =
  let rec loop offset =
    if offset + String.length needle > String.length text
    then false
    else if String.sub text offset (String.length needle) = needle
    then true
    else loop (offset + 1)
  in
  String.length needle = 0 || loop 0
;;

let count text needle =
  let rec loop offset total =
    if offset + String.length needle > String.length text
    then total
    else if String.sub text offset (String.length needle) = needle
    then loop (offset + String.length needle) (total + 1)
    else loop (offset + 1) total
  in
  loop 0 0
;;

let rec files directory =
  Sys.readdir directory
  |> Array.to_list
  |> List.concat_map (fun name ->
    let path = Filename.concat directory name in
    if Sys.is_directory path then files path else [ path ])
;;

let test_application_owns_exactly_one_graph_worker () =
  let source = read_file (source_path "app/application.ml") in
  require
    (count source "App.create_with_worker" = 1)
    "Application must own exactly one Worker service";
  require
    (contains source "~service:Graph_service.service")
    "Application is not wired to Logseq_db_worker_bonsai_service"
;;

let test_startup_selects_typed_target_before_worker_startup () =
  Adapter_fixture.with_snapshot (fun fixture ->
    let payload = encode_startup fixture.config in
    require (Bytes.sub_string payload 0 4 = "LDB1") "startup magic is not LDB1";
    match Journal_startup.decode payload with
    | Error error ->
      fail "typed startup did not decode: %s" (Journal_startup.Error.to_string error)
    | Ok { Logseq_db_worker.Config.target = Snapshot { token }; _ } ->
      require (Graph.Uuid.equal token fixture.token) "startup changed the snapshot token"
    | Ok _ -> fail "startup changed the typed graph target")
;;

let test_initial_graph_info_drives_headless_application () =
  Adapter_fixture.with_snapshot (fun fixture ->
    let handle = create_handle fixture.config in
    Fun.protect
      ~finally:(fun () -> Test.Handle.shutdown handle)
      (fun () ->
         wait_for handle "initial graph feed" (fun () ->
           has_text handle "No journal entries yet");
         require
           (capture_composer_enabled handle)
           "Graph_info did not enable capture"))
;;

let test_initial_feed_loads_at_most_seven_days () =
  Adapter_fixture.with_snapshot (fun fixture ->
    seed_startup_feed_days fixture 8;
    let handle = create_handle fixture.config in
    Fun.protect
      ~finally:(fun () -> Test.Handle.shutdown handle)
      (fun () ->
         wait_for handle "seven-day startup feed" (fun () ->
           has_text handle "Startup feed day 1");
         require
           (has_text handle "Startup feed day 7")
           "startup feed omitted its seventh day";
         require
           (not (has_text handle "Startup feed day 8"))
           "startup feed loaded more than seven days"))
;;

let test_open_failed_renders_without_crashing_worker_runtime () =
  Adapter_fixture.with_snapshot (fun fixture ->
    let config = Adapter_fixture.missing_config fixture.support in
    let handle = create_handle config in
    Fun.protect
      ~finally:(fun () -> Test.Handle.shutdown handle)
      (fun () ->
         wait_for handle "typed graph open failure" (fun () ->
           has_test_id handle "logseq-graph-open-failed");
         require
           (not (capture_composer_enabled handle))
           "Open_failed left graph interaction enabled"))
;;

let test_fatal_storage_error_terminalizes_application () =
  Adapter_fixture.with_snapshot (fun fixture ->
    let block_id = seed_fatal_test_block fixture in
    let fixture = Adapter_fixture.clone_with_mutation_write_failure fixture in
    let handle = create_handle fixture.config in
    Fun.protect
      ~finally:(fun () -> Test.Handle.shutdown handle)
      (fun () ->
         wait_for handle "seeded graph row" (fun () ->
           has_text handle "Fatal mutation row");
         commit_end_swipe handle block_id;
         advance_clock handle 5.;
         wait_for handle "terminal fatal graph state" (fun () ->
           has_test_id handle "logseq-graph-open-failed");
         require
           (not (capture_composer_enabled handle))
           "fatal storage state allowed another graph mutation"))
;;

let test_projection_uses_stable_uuid_and_is_bounded () =
  let page = page_summary "91000000-0000-4000-8000-000000000001" in
  let projected_page = Journal_graph_projection.page_of_summary page |> Option.get in
  let graph_block =
    block
      ~page:page.uuid
      ~parent:page.uuid
      ~order:"a"
      "91000000-0000-4000-a000-000000000001"
  in
  match
    let time_context : Journal_graph_projection.time_context =
      { time_zone_id = "UTC"; utc_offset_seconds = 0 }
    in
    Journal_graph_projection.block
      ~page:projected_page
      ~basis:7L
      ~child_count:0
      ~time_context
      graph_block
  with
  | Error message -> fail "bounded projection failed: %s" message
  | Ok projected ->
    require
      (String.equal (Journal_model.id projected) (Graph.Uuid.to_string graph_block.uuid))
      "projection did not preserve stable UUID identity";
    require
      (Journal_model.revision projected = 7)
      "projection did not preserve graph basis"
;;

let test_feed_projection_ignores_blank_logseq_roots () =
  let summary = page_summary "91100000-0000-4000-8000-000000000001" in
  let page = Journal_graph_projection.page_of_summary summary |> Option.get in
  let blank =
    { (block
         ~page:summary.uuid
         ~parent:summary.uuid
         ~order:"a"
         "91100000-0000-4000-a000-000000000001") with
      title = ""
    }
  in
  let visible =
    block
      ~page:summary.uuid
      ~parent:summary.uuid
      ~order:"b"
      "91100000-0000-4000-a000-000000000002"
  in
  let time_context : Journal_graph_projection.time_context =
    { time_zone_id = "UTC"; utc_offset_seconds = 0 }
  in
  match
    Journal_graph_projection.timeline_entry_page
      ~page
      ~basis:7L
      ~time_context
      { items = [ { Graph.block = blank; depth = 0 }; { block = visible; depth = 0 } ]
      ; continuation = None
      }
  with
  | Ok { entries = [ entry ]; _ } ->
    require
      (String.equal (Journal_model.id entry.block) (Graph.Uuid.to_string visible.uuid))
      "feed projection retained the wrong root"
  | Ok _ -> fail "feed projection did not discard exactly one blank root"
  | Error message -> fail "blank Logseq root rejected the feed: %s" message
;;

let test_feed_paginates_until_filtered_day_limit_is_satisfied () =
  let runtime = Journal_graph_runtime.create () in
  let first =
    Journal_graph_runtime.submit
      runtime
      (Journal_graph_request.Load_feed
         { before_day = Some 20260809
         ; day_limit = 1
         ; blocks_per_day = 64
         ; slot_limit = 128
         ; request_generation = 41L
         })
    |> fun output -> only output.requests
  in
  let next_cursor = cursor "authenticated-next-page" in
  let output =
    Journal_graph_runtime.receive
      runtime
      (succeeded
         first
         ~basis:5L
         (Pages_result
            { items =
                [ page_summary ~day:20260810 "92000000-0000-4000-8000-000000000001" ]
            ; continuation = Some next_cursor
            }))
  in
  require (output.responses = []) "filtered first page completed the feed too early";
  match output.requests with
  | [ { Protocol.command = Read (List_pages { cursor = Some actual; _ }); _ } ] ->
    require
      (String.equal (Graph.Cursor.to_string actual) (Graph.Cursor.to_string next_cursor))
      "feed pagination changed the opaque Worker cursor"
  | _ -> fail "feed did not continue List_pages after a filtered page"
;;

let set_utc_calendar runtime =
  Journal_graph_runtime.set_calendar
    runtime
    { Journal_calendar.instant_unix_ms = 1_786_204_800_000L
    ; local_day = 20260809
    ; local_minute_of_day = 0
    ; locale = "en_US"
    ; time_zone_id = "UTC"
    ; utc_offset_seconds = 0
    ; generation = 1L
    ; lifecycle_generation = 0L
    }
;;

let require_rejected_output description (output : Journal_graph_runtime.output) =
  require (output.requests = []) "%s emitted a Worker request" description;
  match output.responses with
  | [ { Journal_graph_runtime.payload = Rejected _; _ } ] -> ()
  | _ -> fail "%s did not return one local Rejected response" description
;;

let test_feed_rejects_nonpositive_limits_and_unusable_slot_budget () =
  let cases =
    [ ( "zero day limit"
      , Journal_graph_request.Load_feed
          { before_day = None
          ; day_limit = 0
          ; blocks_per_day = 1
          ; slot_limit = 2
          ; request_generation = 61L
          } )
    ; ( "zero blocks-per-day limit"
      , Load_feed
          { before_day = None
          ; day_limit = 1
          ; blocks_per_day = 0
          ; slot_limit = 2
          ; request_generation = 62L
          } )
    ; ( "zero slot limit"
      , Load_feed
          { before_day = None
          ; day_limit = 1
          ; blocks_per_day = 1
          ; slot_limit = 0
          ; request_generation = 63L
          } )
    ; ( "heading-only slot budget"
      , Load_feed
          { before_day = None
          ; day_limit = 1
          ; blocks_per_day = 1
          ; slot_limit = 1
          ; request_generation = 64L
          } )
    ]
  in
  List.iter
    (fun (description, request) ->
       Journal_graph_runtime.submit (Journal_graph_runtime.create ()) request
       |> require_rejected_output description)
    cases
;;

let budget_pages =
  [ page_summary ~day:20260809 "96000000-0000-4000-8000-000000000001"
  ; page_summary ~day:20260808 "96000000-0000-4000-8000-000000000002"
  ; page_summary ~day:20260807 "96000000-0000-4000-8000-000000000003"
  ]
;;

let root_for page index =
  block
    ~page
    ~parent:page
    ~order:(Printf.sprintf "a%d" index)
    (Printf.sprintf "96000000-0000-4000-a000-%012d" index)
;;

let page_tree_limit (request : Protocol.request) =
  match request.command with
  | Read (Get_page_tree { page; limit; _ }) -> page, limit
  | _ -> fail "feed emitted a non-page-tree request"
;;

let respond_to_bounded_page runtime request block_offset =
  let page, limit = page_tree_limit request in
  let items =
    List.init limit (fun index ->
      { Graph.block = root_for page (block_offset + index); depth = 0 })
  in
  Journal_graph_runtime.receive
    runtime
    (succeeded request ~basis:9L (Page_tree_result { items; continuation = None }))
;;

let rec complete_sequential_feed runtime next_offset limits output =
  match output.Journal_graph_runtime.requests with
  | [] -> List.rev limits, output
  | [ request ] ->
    let _, limit = page_tree_limit request in
    complete_sequential_feed
      runtime
      (next_offset + 10)
      (limit :: limits)
      (respond_to_bounded_page runtime request next_offset)
  | _ -> fail "feed emitted concurrent page-tree requests"
;;

let test_feed_allocates_page_requests_within_slot_budget () =
  let runtime = Journal_graph_runtime.create () in
  set_utc_calendar runtime;
  let list_request =
    Journal_graph_runtime.submit
      runtime
      (Journal_graph_request.Load_feed
         { before_day = None
         ; day_limit = 3
         ; blocks_per_day = 4
         ; slot_limit = 7
         ; request_generation = 65L
         })
    |> fun output -> only output.requests
  in
  let first_page =
    Journal_graph_runtime.receive
      runtime
      (succeeded
         list_request
         ~basis:9L
         (Pages_result { items = budget_pages; continuation = None }))
  in
  let limits, final = complete_sequential_feed runtime 10 [] first_page in
  let request_count = List.length limits in
  require (request_count = 3) "slot budget unexpectedly dropped a journal day";
  require
    (List.for_all (fun limit -> limit >= 1 && limit <= 4) limits)
    "feed emitted an invalid per-day allocation";
  require
    (request_count + List.fold_left ( + ) 0 limits <= 7)
    "page requests can project beyond the seven-slot budget";
  match final.responses with
  | [ { payload = Feed_loaded { feed; _ }; _ } ] ->
    let entry_count =
      List.fold_left
        (fun total (day : Journal_graph_projection.day_feed) ->
           total + List.length day.entries)
        0
        feed.days
    in
    require
      (feed.slot_count = 7)
      "feed reported %d slots instead of seven"
      feed.slot_count;
    require
      (List.length feed.days + entry_count = 7)
      "feed projection exceeded its budget"
  | _ -> fail "bounded feed did not complete"
;;

let test_large_feed_emits_one_worker_request_at_a_time () =
  let runtime = Journal_graph_runtime.create () in
  set_utc_calendar runtime;
  let list_request =
    Journal_graph_runtime.submit
      runtime
      (Journal_graph_request.Load_feed
         { before_day = None
         ; day_limit = 31
         ; blocks_per_day = 64
         ; slot_limit = 128
         ; request_generation = 650L
         })
    |> fun output -> only output.requests
  in
  let pages =
    List.init 31 (fun index ->
      page_summary
        ~day:(20260831 - index)
        (Printf.sprintf "96100000-0000-4000-8000-%012d" (index + 1)))
  in
  let first_page =
    Journal_graph_runtime.receive
      runtime
      (succeeded
         list_request
         ~basis:9L
         (Pages_result { items = pages; continuation = None }))
  in
  let limits, final = complete_sequential_feed runtime 100 [] first_page in
  require (List.length limits = 31) "large feed did not load all journal days";
  match final.responses with
  | [ { payload = Feed_loaded { feed; _ }; _ } ] ->
    require
      (List.length feed.days = 31)
      "large sequential feed returned the wrong day count"
  | _ -> fail "large sequential feed did not complete"
;;

let test_feed_caps_days_when_each_day_cannot_receive_one_block () =
  let runtime = Journal_graph_runtime.create () in
  set_utc_calendar runtime;
  let list_request =
    Journal_graph_runtime.submit
      runtime
      (Journal_graph_request.Load_feed
         { before_day = None
         ; day_limit = 3
         ; blocks_per_day = 4
         ; slot_limit = 4
         ; request_generation = 66L
         })
    |> fun output -> only output.requests
  in
  let first_page =
    Journal_graph_runtime.receive
      runtime
      (succeeded
         list_request
         ~basis:9L
         (Pages_result { items = budget_pages; continuation = None }))
  in
  let limits, final = complete_sequential_feed runtime 40 [] first_page in
  require (List.length limits = 2) "four slots must retain exactly two journal days";
  match final.responses with
  | [ { payload = Feed_loaded { feed; _ }; _ } ] ->
    require
      feed.has_more_days
      "dropped journal days were not exposed through continuation";
    require (feed.slot_count = 4) "capped feed did not consume exactly four slots"
  | _ -> fail "day-capped feed did not complete"
;;

let test_feed_rejects_worker_page_response_above_allocated_limit () =
  let runtime = Journal_graph_runtime.create () in
  set_utc_calendar runtime;
  let list_request =
    Journal_graph_runtime.submit
      runtime
      (Journal_graph_request.Load_feed
         { before_day = None
         ; day_limit = 1
         ; blocks_per_day = 4
         ; slot_limit = 2
         ; request_generation = 67L
         })
    |> fun output -> only output.requests
  in
  let page_request =
    Journal_graph_runtime.receive
      runtime
      (succeeded
         list_request
         ~basis:9L
         (Pages_result { items = [ List.hd budget_pages ]; continuation = None }))
    |> fun output -> only output.requests
  in
  let page, allocated = page_tree_limit page_request in
  require (allocated = 1) "two-slot feed did not allocate one block";
  let oversized =
    [ { Graph.block = root_for page 70; depth = 0 }
    ; { Graph.block = root_for page 71; depth = 0 }
    ]
  in
  Journal_graph_runtime.receive
    runtime
    (succeeded
       page_request
       ~basis:9L
       (Page_tree_result { items = oversized; continuation = None }))
  |> require_rejected_output "oversized Worker page response"
;;

let test_child_projection_retains_page_for_later_mutation () =
  let runtime = Journal_graph_runtime.create () in
  let list_request =
    Journal_graph_runtime.submit
      runtime
      (Journal_graph_request.Load_feed
         { before_day = None
         ; day_limit = 1
         ; blocks_per_day = 64
         ; slot_limit = 128
         ; request_generation = 51L
         })
    |> fun output -> only output.requests
  in
  let page = page_summary "93000000-0000-4000-8000-000000000001" in
  let tree_request =
    Journal_graph_runtime.receive
      runtime
      (succeeded
         list_request
         ~basis:6L
         (Pages_result { items = [ page ]; continuation = None }))
    |> fun output -> only output.requests
  in
  let root =
    block
      ~page:page.uuid
      ~parent:page.uuid
      ~order:"a"
      "93000000-0000-4000-a000-000000000001"
  in
  let child =
    block
      ~page:page.uuid
      ~parent:root.uuid
      ~order:"a"
      "93000000-0000-4000-a000-000000000002"
  in
  ignore
    (Journal_graph_runtime.receive
       runtime
       (succeeded
          tree_request
          ~basis:6L
          (Page_tree_result
             { items = [ { Graph.block = root; depth = 0 }; { block = child; depth = 1 } ]
             ; continuation = None
             })));
  let output =
    Journal_graph_runtime.submit
      runtime
      (Journal_graph_request.Update_source
         { mutation_id = "93000000-0000-4000-9000-000000000001"
         ; block_id = Graph.Uuid.to_string child.uuid
         ; expected_revision = 6
         ; source = "Updated child"
         })
  in
  require (output.responses = []) "retained child page lookup was rejected";
  match output.requests with
  | [ { Protocol.command = Mutate (Structural (Save_block { block; _ })); _ } ] ->
    require (Graph.Uuid.equal block child.uuid) "child mutation targeted the wrong block"
  | _ -> fail "child projection did not retain its page for a later mutation"
;;

let test_stale_worker_response_cannot_update_runtime () =
  let runtime = Journal_graph_runtime.create () in
  let request = Journal_graph_runtime.start runtime in
  let stale_request =
    { request with request_id = uuid "94000000-0000-4000-8000-000000000001" }
  in
  let info : Graph.graph_info =
    { local_graph_uuid = uuid "94000000-0000-4000-8000-000000000002"
    ; graph_name = "stale"
    ; graph_dir = "/tmp/stale"
    ; schema = { major = 65; minor = 33 }
    ; basis = 1L
    ; mode = Snapshot
    ; admission_facts = []
    }
  in
  let output =
    Journal_graph_runtime.receive
      runtime
      (succeeded stale_request ~basis:1L (Graph_info_result info))
  in
  require
    (output = Journal_graph_runtime.{ requests = []; responses = [] })
    "uncorrelated Worker response updated application runtime"
;;

let test_transport_preserves_immediate_runtime_rejection () =
  let runtime = Journal_graph_runtime.create () in
  let output =
    Journal_graph_runtime.submit runtime (Journal_graph_request.Find_block "not-a-uuid")
  in
  let send_called = ref false in
  let delivery =
    Journal_graph_transport.deliver
      ~runtime
      ~send:(fun _ ->
        send_called := true;
        Accepted)
      output
  in
  require (not !send_called) "local rejection attempted a Worker send";
  require (delivery.error = None) "local rejection became a transport error";
  match delivery.responses with
  | [ { Journal_graph_runtime.payload = Rejected _; _ } ] -> ()
  | _ -> fail "transport discarded the runtime's immediate Rejected response"
;;

let response_for_find request =
  let page = uuid "97000000-0000-4000-8000-000000000001" in
  succeeded
    request
    ~basis:11L
    (Block_result
       (block ~page ~parent:page ~order:"a" "97000000-0000-4000-a000-000000000001"))
;;

let test_transport_handles_send_failures_and_abandons_pending_requests () =
  let cases =
    [ Journal_graph_transport.Full, "Worker request queue is full"
    ; Not_ready, "Worker is not ready"
    ; Stopping, "Worker is stopping"
    ]
  in
  List.iteri
    (fun index (send_result, expected_error) ->
       let runtime = Journal_graph_runtime.create () in
       let request_output =
         Journal_graph_runtime.submit
           runtime
           (Journal_graph_request.Find_block
              (Printf.sprintf "97000000-0000-4000-a000-%012d" (index + 10)))
       in
       let request = only request_output.requests in
       let delivery =
         Journal_graph_transport.deliver
           ~runtime
           ~send:(fun _ -> send_result)
           request_output
       in
       require
         (delivery.error = Some expected_error)
         "transport did not classify %s"
         expected_error;
       require (delivery.responses = []) "%s fabricated a graph response" expected_error;
       let late = Journal_graph_runtime.receive runtime (response_for_find request) in
       require
         (late = Journal_graph_runtime.{ requests = []; responses = [] })
         "%s left the unaccepted request pending"
         expected_error)
    cases
;;

let test_transport_stops_after_first_send_failure_and_abandons_the_tail () =
  let runtime = Journal_graph_runtime.create () in
  let requests =
    List.init 3 (fun index ->
      Journal_graph_runtime.submit
        runtime
        (Journal_graph_request.Find_block
           (Printf.sprintf "97200000-0000-4000-a000-%012d" (index + 1)))
      |> fun output -> only output.requests)
  in
  let output = Journal_graph_runtime.{ requests; responses = [] } in
  let attempts = ref 0 in
  let delivery =
    Journal_graph_transport.deliver
      ~runtime
      ~send:(fun _ ->
        incr attempts;
        if !attempts = 1 then Accepted else Full)
      output
  in
  require (!attempts = 2) "transport sent requests after the first failure";
  require
    (delivery.error = Some "Worker request queue is full")
    "partial delivery did not report backpressure";
  let unaccepted = List.tl requests in
  List.iter
    (fun request ->
       let late = Journal_graph_runtime.receive runtime (response_for_find request) in
       require
         (late = Journal_graph_runtime.{ requests = []; responses = [] })
         "transport left an unaccepted tail request pending")
    unaccepted
;;

let graph_info ~basis : Graph.graph_info =
  { local_graph_uuid = uuid "98000000-0000-4000-8000-000000000001"
  ; graph_name = "reconciliation"
  ; graph_dir = "/tmp/reconciliation"
  ; schema = { major = 65; minor = 33 }
  ; basis
  ; mode = Snapshot
  ; admission_facts = []
  }
;;

let invalidation basis : Protocol.invalidation =
  { basis
  ; changed_uuids = [ uuid "98000000-0000-4000-a000-000000000001" ]
  ; changed_uuids_truncated = false
  ; invalidate_graph_info = true
  ; invalidate_pages = true
  ; invalidate_tags = true
  ; invalidate_properties = true
  ; invalidate_tasks = true
  ; invalidate_references = true
  }
;;

let seed_runtime_basis runtime basis =
  let request = Journal_graph_runtime.start runtime in
  ignore
    (Journal_graph_runtime.receive
       runtime
       (succeeded request ~basis (Graph_info_result (graph_info ~basis))))
;;

let test_invalidation_at_or_below_observed_basis_is_already_reconciled () =
  let runtime = Journal_graph_runtime.create () in
  seed_runtime_basis runtime 5L;
  List.iter
    (fun basis ->
       let output =
         Journal_graph_runtime.reconcile_invalidation
           runtime
           ~request_generation:71L
           (invalidation basis)
       in
       require
         (output = Journal_graph_runtime.{ requests = []; responses = [] })
         "basis %Ld invalidation reloaded state already observed at basis 5"
         basis)
    [ 4L; 5L ]
;;

let test_new_invalidation_without_feed_reconciles_graph_basis_once () =
  let runtime = Journal_graph_runtime.create () in
  seed_runtime_basis runtime 5L;
  let output =
    Journal_graph_runtime.reconcile_invalidation
      runtime
      ~request_generation:72L
      (invalidation 6L)
  in
  let request = only output.requests in
  (match output.requests with
   | [ { Protocol.command = Read Graph_info; _ } ] -> ()
   | _ -> fail "new invalidation without feed did not request Graph_info");
  let duplicate =
    Journal_graph_runtime.reconcile_invalidation
      runtime
      ~request_generation:73L
      (invalidation 6L)
  in
  require
    (duplicate = Journal_graph_runtime.{ requests = []; responses = [] })
    "duplicate in-flight invalidation emitted another reconciliation read";
  ignore
    (Journal_graph_runtime.receive
       runtime
       (succeeded request ~basis:6L (Graph_info_result (graph_info ~basis:6L))));
  let observed =
    Journal_graph_runtime.reconcile_invalidation
      runtime
      ~request_generation:74L
      (invalidation 6L)
  in
  require
    (observed = Journal_graph_runtime.{ requests = []; responses = [] })
    "Graph_info reconciliation did not record the durable basis"
;;

let test_new_invalidation_reloads_last_initial_feed_with_fresh_generation () =
  let runtime = Journal_graph_runtime.create () in
  seed_runtime_basis runtime 5L;
  ignore
    (Journal_graph_runtime.submit
       runtime
       (Journal_graph_request.Load_feed
          { before_day = None
          ; day_limit = 3
          ; blocks_per_day = 4
          ; slot_limit = 7
          ; request_generation = 74L
          }));
  let first =
    Journal_graph_runtime.reconcile_invalidation
      runtime
      ~request_generation:75L
      (invalidation 6L)
  in
  let first_request = only first.requests in
  (match first_request.command with
   | Read (List_pages { kind = Only_journals; cursor = None; _ }) -> ()
   | _ -> fail "invalidation did not reload the initial journal feed");
  let duplicate =
    Journal_graph_runtime.reconcile_invalidation
      runtime
      ~request_generation:76L
      (invalidation 6L)
  in
  require (duplicate.requests = []) "duplicate invalidation bypassed latest-wins fence";
  let newer =
    Journal_graph_runtime.reconcile_invalidation
      runtime
      ~request_generation:77L
      (invalidation 7L)
  in
  let newer_request = only newer.requests in
  let completed =
    Journal_graph_runtime.receive
      runtime
      (succeeded
         newer_request
         ~basis:7L
         (Pages_result { items = []; continuation = None }))
  in
  (match completed.responses with
   | [ { payload = Feed_loaded { request_generation = 77L; _ }; _ } ] -> ()
   | _ -> fail "reconciliation did not preserve its fresh generation");
  ignore
    (Journal_graph_runtime.receive
       runtime
       (succeeded
          first_request
          ~basis:6L
          (Pages_result { items = []; continuation = None })));
  let observed =
    Journal_graph_runtime.reconcile_invalidation
      runtime
      ~request_generation:78L
      (invalidation 7L)
  in
  require
    (observed = Journal_graph_runtime.{ requests = []; responses = [] })
    "a late lower-basis response regressed the reconciled basis"
;;

let test_domain_zero_and_obsolete_storage_boundaries () =
  let app_files =
    files (source_path "app")
    |> List.filter (fun path ->
      Filename.check_suffix path ".ml" || Filename.check_suffix path ".mli")
  in
  List.iter
    (fun path ->
       let source = read_file path in
       List.iter
         (fun forbidden ->
            require
              (not (contains source forbidden))
              "%s contains forbidden domain-0 persistence dependency %s"
              path
              forbidden)
         [ "Datascript"; "Sqlite3"; "Journal_storage"; "Journal_worker" ])
    app_files;
  List.iter
    (fun path ->
       let source = read_file path in
       List.iter
         (fun obsolete ->
            require
              (not (contains source obsolete))
              "%s retains obsolete access-mode state %s"
              path
              obsolete)
         [ "Recovery_only"; "recovery_only"; "Journal is read-only" ])
    app_files;
  List.iter
    (fun path ->
       require
         (not (Sys.file_exists (source_path path)))
         "obsolete storage path still exists: %s"
         path)
    [ "app/journal_storage.ml"
    ; "app/journal_repository.ml"
    ; "app/journal_worker.ml"
    ; "app/journal_process_recovery.ml"
    ]
;;

let failures = ref []

let run name test =
  Printf.printf "running %s\n%!" name;
  try test () with
  | exception_ -> failures := (name ^ ": " ^ Printexc.to_string exception_) :: !failures
;;

let () =
  run "single graph Worker service" test_application_owns_exactly_one_graph_worker;
  run "typed target startup" test_startup_selects_typed_target_before_worker_startup;
  run "initial Graph_info" test_initial_graph_info_drives_headless_application;
  run "seven-day initial feed" test_initial_feed_loads_at_most_seven_days;
  run "Open_failed UI" test_open_failed_renders_without_crashing_worker_runtime;
  run "fatal storage UI" test_fatal_storage_error_terminalizes_application;
  run "bounded stable projection" test_projection_uses_stable_uuid_and_is_bounded;
  run "blank feed roots" test_feed_projection_ignores_blank_logseq_roots;
  run "filtered feed pagination" test_feed_paginates_until_filtered_day_limit_is_satisfied;
  run
    "feed rejects invalid budgets"
    test_feed_rejects_nonpositive_limits_and_unusable_slot_budget;
  run "feed slot allocation" test_feed_allocates_page_requests_within_slot_budget;
  run "feed serial backpressure" test_large_feed_emits_one_worker_request_at_a_time;
  run "feed day cap" test_feed_caps_days_when_each_day_cannot_receive_one_block;
  run
    "feed rejects oversized page response"
    test_feed_rejects_worker_page_response_above_allocated_limit;
  run "child page retention" test_child_projection_retains_page_for_later_mutation;
  run "stale response fence" test_stale_worker_response_cannot_update_runtime;
  run
    "transport preserves immediate rejection"
    test_transport_preserves_immediate_runtime_rejection;
  run
    "transport handles send failures"
    test_transport_handles_send_failures_and_abandons_pending_requests;
  run
    "transport abandons unsent tail"
    test_transport_stops_after_first_send_failure_and_abandons_the_tail;
  run
    "observed invalidation basis"
    test_invalidation_at_or_below_observed_basis_is_already_reconciled;
  run
    "graph-info invalidation reconciliation"
    test_new_invalidation_without_feed_reconciles_graph_basis_once;
  run
    "feed invalidation reconciliation"
    test_new_invalidation_reloads_last_initial_feed_with_fresh_generation;
  run
    "domain-zero and obsolete boundaries"
    test_domain_zero_and_obsolete_storage_boundaries;
  match List.rev !failures with
  | [] -> ()
  | failures -> fail "application integration failures:\n%s" (String.concat "\n" failures)
;;
