module ID = Bonsai_flutter_spec.Id
module Environment = Bonsai_flutter.Environment
module Protocol = Bonsai_flutter_protocol
module Runtime = Bonsai_flutter_runtime
module Test = Bonsai_flutter_test
module Ui = Bonsai_flutter_ui
module Adapter_fixture = Logseq_db_worker_test_support.Adapter_fixture

let fail format = Printf.ksprintf failwith format

let require condition format =
  Printf.ksprintf (fun message -> if not condition then failwith message) format
;;

module Graph = Logseq_db_worker.Graph_types
module Graph_protocol = Logseq_db_worker.Protocol

let with_startup test =
  Adapter_fixture.with_snapshot (fun fixture -> test fixture.Adapter_fixture.config)
;;

let encode_startup startup =
  match Journal_startup.encode startup with
  | Ok bytes -> bytes
  | Error error ->
    fail "startup encode failed: %s" (Journal_startup.Error.to_string error)
;;

let platform_envelope tag payload =
  let header_size = 32 in
  let bytes = Bytes.make (header_size + Bytes.length payload) '\000' in
  Bytes.blit_string "LJP2" 0 bytes 0 4;
  Bytes.set_uint16_le bytes 4 2;
  Bytes.set_uint16_le bytes 6 tag;
  Bytes.set_int32_le bytes 24 (Int32.of_int (Bytes.length payload));
  Bytes.blit payload 0 bytes header_size (Bytes.length payload);
  bytes
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
  platform_envelope 2 bytes
;;

let initialize_test_calendar ?(packet = initial_calendar_packet) handle =
  (match Journal_platform.decode_calendar packet with
   | Ok _ -> ()
   | Error message -> fail "initial calendar fixture is invalid: %s" message);
  let rec wait_for_request remaining =
    if remaining = 0
    then fail "timed out waiting for the initial calendar request"
    else (
      Test.Handle.present handle;
      let request =
        match Test.Handle.last_frame handle with
        | None -> None
        | Some frame ->
          (match Protocol.Binary_codec.decode frame.bytes with
           | Error error -> fail "application frame did not decode: %s" error.message
           | Ok wire ->
             List.find_map
               (function
                 | Protocol.Wire_frame.Application_request { request_id; payload }
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
    Protocol.Inbound_event.
      { sequence = ID.Runtime.Event_sequence.of_int64 1L
      ; displayed_revision = Test.Handle.revision handle
      ; node_id = ID.Ui.Node_id.zero
      ; handler_id = ID.Ui.Handler_id.zero
      ; event_tag = Protocol.Generated_protocol.Event_tag.application_response
      ; payload = Application_response { request_id; payload = packet }
      }
  in
  Test.Handle.pump_next
    handle
    ~events:
      Protocol.Inbound_event.
        { runtime_epoch = ID.Runtime.Epoch.of_int64 9_001L; events = [ event ] }
    ();
  Test.Handle.present handle;
  Test.Handle.resize handle ~width:390. ~height:844.;
  Test.Handle.present handle;
  Test.Handle.resize handle ~width:390. ~height:844.;
  Test.Handle.present handle
;;

let create_handle startup =
  let time_source = Bonsai.Time_source.create ~start:Core.Time_ns.epoch in
  let handle =
    Test.Handle.create_app
      ~runtime_epoch:(ID.Runtime.Epoch.of_int64 9_001L)
      ~time_source
      Application.app
      ~application_payload:(encode_startup startup)
  in
  initialize_test_calendar handle;
  handle
;;

let create_handle_with_calendar startup packet =
  let time_source = Bonsai.Time_source.create ~start:Core.Time_ns.epoch in
  let handle =
    Test.Handle.create_app
      ~runtime_epoch:(ID.Runtime.Epoch.of_int64 9_001L)
      ~time_source
      Application.app
      ~application_payload:(encode_startup startup)
  in
  initialize_test_calendar ~packet handle;
  handle
;;

let create_timed_handle startup =
  let time_source = Bonsai.Time_source.create ~start:Core.Time_ns.epoch in
  let handle =
    Test.Handle.create_app
      ~runtime_epoch:(ID.Runtime.Epoch.of_int64 9_001L)
      ~time_source
      Application.app
      ~application_payload:(encode_startup startup)
  in
  initialize_test_calendar handle;
  handle, ref 0L
;;

let advance_clock handle monotonic_now_ns seconds =
  Test.Handle.present handle;
  monotonic_now_ns
  := Int64.add !monotonic_now_ns (Int64.of_float (seconds *. 1_000_000_000.));
  ignore (Test.Handle.pump handle ~monotonic_now_ns:!monotonic_now_ns ());
  Test.Handle.presentation_succeeded handle ~monotonic_now_ns:!monotonic_now_ns
;;

let fixture_time day index =
  let midnight =
    match day with
    | 20260806 -> 1_785_945_600_000L
    | 20260807 -> 1_786_032_000_000L
    | 20260808 -> 1_786_118_400_000L
    | 20260809 -> 1_786_204_800_000L
    | _ -> fail "unsupported fixture day %d" day
  in
  Journal_time.create
    ~instant_unix_ms:Int64.(add midnight (of_int (index * 60_000)))
    ~local_day:day
    ~local_minute_of_day:index
    ~time_zone_id:"Asia/Shanghai"
    ~utc_offset_seconds:28_800
  |> function
  | Ok value -> value
  | Error error -> fail "fixture time failed: %s" error
;;

let capture ?(day = 20260809) ?(task_state = Journal_model.No_status) index source
  : Journal_graph_projection.capture
  =
  { mutation_id = Printf.sprintf "70000000-0000-4000-9000-%012d" index
  ; block_id = Printf.sprintf "70000000-0000-4000-a000-%012d" index
  ; sibling_order = Printf.sprintf "%012d" index
  ; source
  ; task_state
  ; creation_time = fixture_time day (index mod 1_440)
  ; children = []
  }
;;

let fixture_request_sequence = ref 100_000L

let fresh_fixture_uuid () =
  fixture_request_sequence := Int64.succ !fixture_request_sequence;
  Graph.Uuid.of_string
    (Printf.sprintf "a0000000-0000-4000-8000-%012Lx" !fixture_request_sequence)
  |> Result.get_ok
;;

let uuid value = Graph.Uuid.of_string value |> Result.get_ok

let graph_request command =
  Graph_protocol.{ api_version; request_id = fresh_fixture_uuid (); command }
;;

let execute engine command =
  match Logseq_db_worker.Engine.execute engine (graph_request command) with
  | Graph_protocol.Succeeded { success; _ } -> success
  | Failed failure ->
    fail "graph fixture request failed: %s" (Logseq_db_worker.Error.message failure.error)
;;

let context engine mutation_id =
  Graph_protocol.
    { mutation_id = uuid mutation_id
    ; expected_basis = Option.value (Logseq_db_worker.Engine.basis engine) ~default:0L
    }
;;

let journal_page_uuid day =
  let text = Printf.sprintf "%08d" day in
  Graph.Uuid.of_string
    (Printf.sprintf
       "00000001-%s-%s-0000-000000000000"
       (String.sub text 0 4)
       (String.sub text 4 4))
  |> Result.get_ok
;;

let ensure_journal engine day =
  let page = journal_page_uuid day in
  match
    Logseq_db_worker.Engine.execute
      engine
      (graph_request (Read (Get_page { page = Graph.Page_by_uuid page })))
  with
  | Succeeded _ -> page
  | Failed failure when Logseq_db_worker.Error.code failure.error = Not_found ->
    ignore
      (execute
         engine
         (Mutate
            (Page
               (Create_page
                  { title =
                      Printf.sprintf
                        "%04d-%02d-%02d"
                        (day / 10_000)
                        (day / 100 mod 100)
                        (day mod 100)
                  ; kind =
                      Create_journal_page { journal_day = day; supplied_uuid = Some page }
                  ; context =
                      { mutation_id = fresh_fixture_uuid ()
                      ; expected_basis =
                          Option.value (Logseq_db_worker.Engine.basis engine) ~default:0L
                      }
                  }))));
    page
  | Failed failure ->
    fail "journal lookup failed: %s" (Logseq_db_worker.Error.message failure.error)
;;

let set_task engine block task_state =
  match task_state with
  | Journal_model.No_status -> ()
  | Todo | Doing | In_review | Now | Done | Canceled | Backlog | Waiting | Later ->
    let value = Graph.Default_value (Journal_model.status_name task_state) in
    ignore
      (execute
         engine
         (Mutate
            (Property
               (Set_property
                  { block
                  ; property = Property_by_ident "logseq.property/status"
                  ; value
                  ; context =
                      { mutation_id = fresh_fixture_uuid ()
                      ; expected_basis =
                          Option.value (Logseq_db_worker.Engine.basis engine) ~default:0L
                      }
                  }))))
;;

let seed startup captures =
  List.iter
    (fun (command : Journal_graph_projection.capture) ->
       let epoch_ms = Journal_time.instant_unix_ms command.creation_time in
       let dependencies : Logseq_db_worker.Engine.dependencies =
         { clocks =
             { epoch_ms = (fun () -> epoch_ms); monotonic_ns = (fun () -> 1_000_000L) }
         ; cursor_authentication_key = Bytes.make 32 'a'
         ; crypto = Logseq_db_worker.Sync_e2ee.unavailable_crypto
         ; unlock_graph_key =
             (fun ~user_id:_ ~encrypted_graph_key:_ -> Error "crypto unavailable")
         }
       in
       let engine =
         Logseq_db_worker.Engine.open_ ~dependencies startup |> Result.get_ok
       in
       Fun.protect
         ~finally:(fun () ->
           match Logseq_db_worker.Engine.close engine with
           | Ok () -> ()
           | Error message -> fail "graph fixture close failed: %s" message)
         (fun () ->
            let page =
              ensure_journal engine (Journal_time.local_day command.creation_time)
            in
            let tree : Graph_protocol.block_tree =
              { uuid = uuid command.block_id
              ; title = command.source
              ; children =
                  List.map
                    (fun (child : Journal_graph_projection.capture_child) ->
                       { Graph_protocol.uuid = uuid child.block_id
                       ; title = child.source
                       ; children = []
                       })
                    command.children
              }
            in
            ignore
              (execute
                 engine
                 (Mutate
                    (Structural
                       (Insert_blocks
                          { roots = [ tree ]
                          ; position = Relative (Last_child page)
                          ; context = context engine command.mutation_id
                          }))));
            set_task engine tree.uuid command.task_state))
    captures
;;

let seed_child_by_parent_id
      startup
      ~parent_block_id
      ?(task_state = Journal_model.No_status)
      index
      source
  =
  let engine =
    Logseq_db_worker.Engine.open_ ~dependencies:Adapter_fixture.dependencies startup
    |> Result.get_ok
  in
  Fun.protect
    ~finally:(fun () -> ignore (Logseq_db_worker.Engine.close engine))
    (fun () ->
       let command : Journal_graph_projection.create_child =
         { mutation_id = Printf.sprintf "71000000-0000-4000-9000-%012d" index
         ; block_id = Printf.sprintf "71000000-0000-4000-a000-%012d" index
         ; parent_block_id
         ; expected_parent_revision = 1
         ; sibling_order = Printf.sprintf "%012d" index
         ; source
         ; task_state
         ; creation_time = fixture_time 20260809 (index mod 1_440)
         }
       in
       let child = uuid command.block_id in
       ignore
         (execute
            engine
            (Mutate
               (Structural
                  (Insert_blocks
                     { roots = [ { uuid = child; title = source; children = [] } ]
                     ; position = Relative (Last_child (uuid parent_block_id))
                     ; context = context engine command.mutation_id
                     }))));
       set_task engine child task_state;
       command)
;;

let seed_child
      startup
      ~(parent : Journal_graph_projection.capture)
      ?(task_state = Journal_model.No_status)
      index
      source
  =
  seed_child_by_parent_id
    startup
    ~parent_block_id:parent.block_id
    ~task_state
    index
    source
;;

let pump_worker handle =
  Test.Handle.present handle;
  Test.Handle.pump_next handle ()
;;

let environment
      ?(viewport_width = 390.)
      ?(viewport_height = 844.)
      ?(device_pixel_ratio = 3.)
      ?(text_scale = 1.)
      ?(brightness = Environment.Light)
      ?(high_contrast = false)
      ?(safe_area_top = 47.)
      ?(safe_area_bottom = 0.)
      ?(platform = "ios")
      ?(locale = "en_US")
      ?(reduced_motion = false)
      ?(keyboard_inset_bottom = 0.)
      ?(accessible_navigation = false)
      ?(disable_animations = false)
      ()
  : Environment.snapshot
  =
  let zero : Environment.edge_insets = { left = 0.; top = 0.; right = 0.; bottom = 0. } in
  { viewport_width
  ; viewport_height
  ; device_pixel_ratio
  ; text_scale
  ; brightness
  ; platform
  ; locale
  ; safe_area = { zero with top = safe_area_top; bottom = safe_area_bottom }
  ; keyboard_insets = { zero with bottom = keyboard_inset_bottom }
  ; accessible_navigation
  ; bold_text = false
  ; invert_colors = false
  ; disable_animations
  ; reduced_motion
  ; high_contrast
  ; orientation = Environment.Portrait
  ; pointer_kinds = 1
  }
;;

let set_environment handle snapshot =
  Test.Handle.present handle;
  Test.Handle.set_environment handle snapshot
;;

let pump_until_text handle text =
  let rec loop attempts =
    if attempts = 0
    then fail "timed out waiting for %S\n%s" text (Test.Handle.show handle)
    else if Option.is_some (Test.Handle.find handle (Test.Query.visible_text text))
    then ()
    else (
      Unix.sleepf 0.001;
      pump_worker handle;
      loop (attempts - 1))
  in
  loop 500
;;

let pump_until handle description predicate =
  let rec loop attempts =
    if attempts = 0
    then fail "timed out waiting for %s\n%s" description (Test.Handle.show handle)
    else if predicate ()
    then ()
    else (
      Unix.sleepf 0.001;
      pump_worker handle;
      loop (attempts - 1))
  in
  loop 500
;;

let click_test_id handle test_id =
  Test.Handle.present handle;
  Test.Handle.click handle (Test.Query.test_id test_id);
  Test.Handle.present handle
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
    let (Av view) = Ui.Widget.Private.view node.widget in
    match view.node with
    | Ui.Widget.Private.Native_widget { kind_id; _ } -> kind_id
    | _ -> fail "delete wrapper is not a native widget"
  in
  Test.Handle.native_event
    handle
    query
    ~kind_id
    ~version:2
    ~event_id:(ID.Native_widget.Event_id.of_int 1)
    ~payload:(Bytes.make 1 '\001')
;;

let require_visible_text handle text =
  require
    (Option.is_some (Test.Handle.find handle (Test.Query.visible_text text)))
    "expected visible text %S\n%s"
    text
    (Test.Handle.show handle)
;;

let require_no_visible_text handle text =
  require
    (Option.is_none (Test.Handle.find handle (Test.Query.visible_text text)))
    "unexpected visible text %S\n%s"
    text
    (Test.Handle.show handle)
;;

let require_visible_text_count handle text expected =
  let actual = List.length (Test.Handle.find_all handle (Test.Query.visible_text text)) in
  require
    (actual = expected)
    "visible text %S has %d nodes, expected %d\n%s"
    text
    actual
    expected
    (Test.Handle.show handle)
;;

let require_semantics handle label =
  require
    (Option.is_some (Test.Handle.find handle (Test.Query.semantics_label label)))
    "expected semantics label %S\n%s"
    label
    (Test.Handle.show handle)
;;

let require_no_semantics handle label =
  require
    (Option.is_none (Test.Handle.find handle (Test.Query.semantics_label label)))
    "unexpected semantics label %S\n%s"
    label
    (Test.Handle.show handle)
;;

type semantics_view =
  { role : Ui.Semantics.Role.t
  ; live_region : bool
  ; heading_level : int option
  }

let require_semantics_view handle label check =
  match Test.Handle.find_all handle (Test.Query.semantics_label label) with
  | [ node ] ->
    let (Av view) = Ui.Widget.Private.view node.widget in
    (match view.node with
     | Ui.Widget.Private.Semantics { role; live_region; heading_level; _ } ->
       check { role; live_region; heading_level }
     | _ -> fail "%S is not Semantics" label)
  | [] -> fail "expected semantics label %S\n%s" label (Test.Handle.show handle)
  | nodes -> fail "%S has %d duplicate semantic nodes" label (List.length nodes)
;;

let require_live_region handle label =
  require_semantics_view handle label (fun view ->
    require view.live_region "%S is not announced as a live region" label)
;;

let require_test_id handle test_id =
  require
    (Option.is_some (Test.Handle.find handle (Test.Query.test_id test_id)))
    "expected test ID %S\n%s"
    test_id
    (Test.Handle.show handle)
;;

let require_no_test_id handle test_id =
  require
    (Option.is_none (Test.Handle.find handle (Test.Query.test_id test_id)))
    "unexpected test ID %S\n%s"
    test_id
    (Test.Handle.show handle)
;;

let test_initial_feed_has_a_truthful_loading_state () =
  with_startup (fun startup ->
    let handle = create_handle startup in
    Fun.protect
      ~finally:(fun () -> Test.Handle.shutdown handle)
      (fun () ->
         Test.Handle.present handle;
         require_visible_text handle "Loading journal";
         require_live_region handle "Loading journal";
         require_no_visible_text handle "No journal entries yet";
         pump_until_text handle "No journal entries yet";
         require_no_visible_text handle "Loading journal"))
;;

let node_by_test_id handle test_id =
  match Test.Handle.find handle (Test.Query.test_id test_id) with
  | Some node -> node
  | None -> fail "expected test ID %S\n%s" test_id (Test.Handle.show handle)
;;

let text_field_value handle test_id =
  let (Av view) = Ui.Widget.Private.view (node_by_test_id handle test_id).widget in
  match view.node with
  | Ui.Widget.Private.Text_input { value; _ } -> value
  | _ -> fail "%s is not a Material text field" test_id
;;

type timeline_props_record =
  { total_count : int
  ; first_index : int
  ; default_item_extent : float
  ; extent_overrides : Ui.Widget.Sparse_extent_override.t list
  ; overscan : int
  ; transition : Ui.Widget.Sparse_extent_transition.t option
  }

let timeline_props handle =
  let (Av view) =
    Ui.Widget.Private.view (node_by_test_id handle "journal-timeline").widget
  in
  match view.node with
  | Ui.Widget.Private.Sliver_varied_extent
      { total_count
      ; first_index
      ; default_item_extent
      ; extent_overrides
      ; overscan
      ; transition
      } ->
    { total_count
    ; first_index
    ; default_item_extent
    ; extent_overrides
    ; overscan
    ; transition
    }
  | _ -> fail "journal timeline is not a Sliver_varied_extent"
;;

let timeline_item_keys handle =
  let (Av view) =
    Ui.Widget.Private.view (node_by_test_id handle "journal-timeline").widget
  in
  Array.to_list view.children
  |> List.mapi (fun index (child : Ui.Widget.Private.child) ->
    match Ui.Widget.For_testing.key child.widget with
    | Some key -> key
    | None -> fail "journal timeline item %d has no root key" index)
;;

let require_unique_timeline_item_keys keys =
  let sorted = List.sort Ui.Key.compare keys in
  let rec require_unique = function
    | left :: (right :: _ as rest) ->
      require
        (not (Ui.Key.equal left right))
        "journal timeline has duplicate root key %s"
        (Ui.Key.to_debug_string left);
      require_unique rest
    | [] | [ _ ] -> ()
  in
  require_unique sorted
;;

let capture_composer_props handle =
  let (Av view) =
    Ui.Widget.Private.view (node_by_test_id handle "journal-capture-composer").widget
  in
  match view.node with
  | Ui.Widget.Private.Native_widget { kind_id; payload; _ } ->
    require
      (kind_id = Ui.Native_widget.Message_composer.kind_id)
      "Capture composer uses the wrong native widget kind";
    Ui.Native_widget.Message_composer.For_testing.decode_props_exn payload
  | _ -> fail "journal-capture-composer is not a Message_composer"
;;

let send_capture_composer_button handle ~button_id ~text =
  let payload = Bytes.make (4 + String.length text) '\000' in
  Bytes.set_int32_le payload 0 (Int32.of_int button_id);
  Bytes.blit_string text 0 payload 4 (String.length text);
  Test.Handle.present handle;
  Test.Handle.native_event
    handle
    (Test.Query.test_id "journal-capture-composer")
    ~kind_id:Ui.Native_widget.Message_composer.kind_id
    ~version:1
    ~event_id:Ui.Native_widget.Message_composer.button_pressed_event_id
    ~payload;
  Test.Handle.present handle
;;

let open_capture handle = send_capture_composer_button handle ~button_id:1 ~text:""

let send_visible_range handle ~first_index ~last_exclusive =
  Test.Handle.present handle;
  Test.Handle.visible_range
    handle
    (Test.Query.test_id "journal-timeline")
    ~first_index:(Int64.of_int first_index)
    ~last_exclusive:(Int64.of_int last_exclusive)
;;

type stale_native_binding =
  { displayed_revision : ID.Runtime.renderer_revision
  ; node_id : ID.Ui.node_id
  ; handler_id : ID.Ui.handler_id
  }

let capture_native_binding handle test_id =
  Test.Handle.present handle;
  let node = node_by_test_id handle test_id in
  let binding =
    Array.find_opt
      (fun (binding : Runtime.Mounted_tree.Mounted_binding.t) ->
         Ui.Event.Tag.equal binding.event_tag Ui.Event.Tag.Visible_range_changed)
      node.event_bindings
    |> function
    | Some binding -> binding
    | None -> fail "%s does not bind visible range events" test_id
  in
  { displayed_revision = Test.Handle.revision handle
  ; node_id = node.node_id
  ; handler_id = binding.handler_id
  }
;;

let send_stale_visible_range
      handle
      (binding : stale_native_binding)
      ~first_index
      ~last_exclusive
  =
  Test.Handle.present handle;
  let event =
    Protocol.Inbound_event.
      { sequence = ID.Runtime.Event_sequence.of_int64 9_000L
      ; displayed_revision = binding.displayed_revision
      ; node_id = binding.node_id
      ; handler_id = binding.handler_id
      ; event_tag = Protocol.Generated_protocol.Event_tag.visible_range_changed
      ; payload =
          Visible_range
            { first_index = Int64.of_int first_index
            ; last_exclusive = Int64.of_int last_exclusive
            }
      }
  in
  Test.Handle.pump_next
    handle
    ~events:
      Protocol.Inbound_event.
        { runtime_epoch = ID.Runtime.Epoch.of_int64 9_001L; events = [ event ] }
    ()
;;

let require_decoration handle test_id expected =
  let (Av view) = Ui.Widget.Private.view (node_by_test_id handle test_id).widget in
  match view.node with
  | Ui.Widget.Private.Decorated_box { background = Some actual; _ } ->
    require
      (Int32.equal actual expected)
      "%s background expected 0x%lx, got 0x%lx"
      test_id
      expected
      actual
  | _ -> fail "%s is not a colored DecoratedBox" test_id
;;

let require_decoration_without_shape handle test_id ~background =
  let (Av view) = Ui.Widget.Private.view (node_by_test_id handle test_id).widget in
  match view.node with
  | Ui.Widget.Private.Decorated_box { background = Some actual_background; border_radius }
    ->
    require
      (Int32.equal actual_background background && Float.equal border_radius 0.)
      "%s must leave outer sheet shape to the Flutter modal route"
      test_id
  | _ -> fail "%s is not a colored DecoratedBox" test_id
;;

let require_sized_height handle test_id expected =
  let (Av view) = Ui.Widget.Private.view (node_by_test_id handle test_id).widget in
  match view.node with
  | Ui.Widget.Private.Sized_box { height = Some actual; _ } ->
    require (Float.equal actual expected) "%s height is %.3f" test_id actual
  | _ -> fail "%s is not a height-constrained SizedBox" test_id
;;

let require_sized_size handle test_id ~width ~height =
  let (Av view) = Ui.Widget.Private.view (node_by_test_id handle test_id).widget in
  match view.node with
  | Ui.Widget.Private.Sized_box
      { width = Some actual_width; height = Some actual_height; _ } ->
    require
      (Float.equal actual_width width && Float.equal actual_height height)
      "%s size is %.1fx%.1f, expected %.1fx%.1f"
      test_id
      actual_width
      actual_height
      width
      height
  | _ -> fail "%s is not a size-constrained SizedBox" test_id
;;

let require_horizontal_padding handle test_id ~left ~right =
  let (Av view) = Ui.Widget.Private.view (node_by_test_id handle test_id).widget in
  match view.node with
  | Ui.Widget.Private.Padding
      { left = actual_left; right = actual_right; top = _; bottom = _ } ->
    require
      (Float.equal actual_left left && Float.equal actual_right right)
      "%s horizontal padding is %.1f/%.1f, expected %.1f/%.1f"
      test_id
      actual_left
      actual_right
      left
      right
  | _ -> fail "%s is not Padding" test_id
;;

let require_button_enabled handle test_id expected =
  let (Av view) = Ui.Widget.Private.view (node_by_test_id handle test_id).widget in
  match view.node with
  | Ui.Widget.Private.Material_elevated_button { enabled; _ }
  | Ui.Widget.Private.Material_text_button { enabled; _ }
  | Ui.Widget.Private.Material_icon_button { enabled; _ } ->
    require (Bool.equal enabled expected) "%s enabled state differs" test_id
  | _ -> fail "%s is not a Material button" test_id
;;

let capture_sheet_page_props handle =
  let (Av view) =
    Ui.Widget.Private.view (node_by_test_id handle "journal-capture-sheet").widget
  in
  match view.node with
  | Ui.Widget.Private.Page { page_key; presentation; can_pop; restoration_id } ->
    page_key, presentation, can_pop, restoration_id
  | _ -> fail "journal-capture-sheet is not a Navigator page"
;;

let require_capture_modal_page handle ~can_pop ~enter_ms ~exit_ms =
  let page_key, presentation, actual_can_pop, restoration_id =
    capture_sheet_page_props handle
  in
  require
    (String.equal (ID.Navigation.Page_key.to_string page_key) "journal-capture-sheet")
    "Capture sheet page key changed";
  require (Bool.equal actual_can_pop can_pop) "Capture sheet can_pop differs";
  (match restoration_id with
   | Some id ->
     require
       (String.equal (ID.Navigation.Restoration_id.to_string id) "journal-capture-sheet")
       "Capture sheet restoration identity changed"
   | None -> fail "Capture sheet has no restoration identity");
  match presentation with
  | Ui.Navigation.Standard _ -> fail "Capture still uses an opaque standard page"
  | Modal_bottom_sheet modal ->
    let modal = Ui.Navigation.Modal_bottom_sheet.Private.view modal in
    require (not modal.barrier_dismissible) "Capture barrier became dismissible";
    require modal.use_safe_area "Capture modal does not use the safe area";
    require modal.request_focus "Capture modal does not request route focus";
    require
      (modal.transition_duration_ms = enter_ms
       && modal.reverse_transition_duration_ms = exit_ms)
      "Capture modal motion differs";
    (match modal.barrier_color with
     | Some color ->
       require
         (Int32.equal (Ui.Style.Color.Private.to_argb32 color) 0x470d142fl
          || Int32.equal (Ui.Style.Color.Private.to_argb32 color) 0x7a000000l
          || Int32.equal (Ui.Style.Color.Private.to_argb32 color) 0x8c000000l)
         "Capture modal uses an unknown scrim"
     | None -> fail "Capture modal did not provide a semantic scrim color");
    (match modal.sizing with
     | Ui.Navigation.Modal_bottom_sheet.Sizing.Scroll_controlled -> ()
     | Content_bounded | Detented _ ->
       fail "Capture modal is not the fixed-large scroll-controlled sheet")
;;

let require_capture_composer_position handle =
  let positioned = node_by_test_id handle "journal-capture-composer-safe-area" in
  match positioned.parent_data with
  | Ui.Widget.Private.Stack_position { left; right; top; bottom } ->
    require
      (top = None && bottom = Some 12. && left = Some 12. && right = Some 12.)
      "Capture composer does not span the content viewport margins"
  | _ -> fail "Capture composer is not a positioned overlay child"
;;

let substring_index text needle =
  let rec loop index =
    if index + String.length needle > String.length text
    then None
    else if String.sub text index (String.length needle) = needle
    then Some index
    else loop (index + 1)
  in
  loop 0
;;

let require_tree_order handle earlier later =
  let tree = Test.Handle.show handle in
  match substring_index tree earlier, substring_index tree later with
  | Some earlier_index, Some later_index ->
    require
      (earlier_index < later_index)
      "%S must precede %S in the logical tree\n%s"
      earlier
      later
      tree
  | _ -> fail "missing %S or %S in the logical tree\n%s" earlier later tree
;;

let require_text_style handle test_id ~size ~line_height ~weight ~color =
  let (Av view) = Ui.Widget.Private.view (node_by_test_id handle test_id).widget in
  match view.node with
  | Ui.Widget.Private.Text { style = Some style; _ } ->
    require
      (style.font_size = Some size
       && style.line_height = Some line_height
       && style.font_weight = Some weight
       && style.color = Some color)
      "%s has unexpected typography"
      test_id
  | _ -> fail "%s is not styled Text" test_id
;;

let require_text_max_lines handle test_id expected =
  let (Av view) = Ui.Widget.Private.view (node_by_test_id handle test_id).widget in
  match view.node with
  | Ui.Widget.Private.Text { max_lines; _ } ->
    require (max_lines = Some expected) "%s max_lines differs from %d" test_id expected
  | _ -> fail "%s is not Text" test_id
;;

let require_padding handle test_id ~left ~top ~right ~bottom =
  let (Av view) = Ui.Widget.Private.view (node_by_test_id handle test_id).widget in
  match view.node with
  | Ui.Widget.Private.Padding
      { left = actual_left
      ; top = actual_top
      ; right = actual_right
      ; bottom = actual_bottom
      } ->
    require
      (Float.equal actual_left left
       && Float.equal actual_top top
       && Float.equal actual_right right
       && Float.equal actual_bottom bottom)
      "%s padding is %.1f/%.1f/%.1f/%.1f, expected %.1f/%.1f/%.1f/%.1f"
      test_id
      actual_left
      actual_top
      actual_right
      actual_bottom
      left
      top
      right
      bottom
  | _ -> fail "%s is not Padding" test_id
;;

let require_header_geometry handle =
  (let (Av view) =
     Ui.Widget.Private.view (node_by_test_id handle "journal-header-safe-area").widget
   in
   match view.node with
   | Ui.Widget.Private.Safe_area { top; bottom; _ } ->
     require (top && not bottom) "header safe-area edges changed"
   | _ -> fail "journal-header-safe-area is not SafeArea");
  (let (Av view) =
     Ui.Widget.Private.view (node_by_test_id handle "journal-header-stack").widget
   in
   match view.node with
   | Ui.Widget.Private.Stack -> ()
   | _ -> fail "journal-header-stack is not Stack");
  require_sized_height handle "journal-header-content-height" 48.;
  (let (Av view) =
     Ui.Widget.Private.view (node_by_test_id handle "journal-header-center").widget
   in
   match view.node with
   | Ui.Widget.Private.Center _ -> ()
   | _ -> fail "journal-header-center is not an independent Center");
  (let (Av view) =
     Ui.Widget.Private.view (node_by_test_id handle "journal-header-padding").widget
   in
   match view.node with
   | Ui.Widget.Private.Padding { left; right; top; bottom } ->
     require
       (Float.equal left 12.
        && Float.equal right 12.
        && Float.equal top 4.
        && Float.equal bottom 4.)
       "header inset is %.1f/%.1f/%.1f/%.1f, expected 12.0/4.0/12.0/4.0"
       left
       top
       right
       bottom
   | _ -> fail "journal-header-padding is not Padding");
  require_sized_size
    handle
    "journal-header-leading-placeholder"
    ~width:44.
    ~height:44.;
  require_sized_size
    handle
    "journal-header-account-placeholder"
    ~width:44.
    ~height:44.
;;

let require_stack_bottom handle test_id expected =
  match (node_by_test_id handle test_id).parent_data with
  | Ui.Widget.Private.Stack_position { left = _; right = _; top = None; bottom } ->
    require (bottom = Some expected) "%s bottom is not %.1f" test_id expected
  | _ -> fail "%s is not bottom-positioned" test_id
;;

let require_content_width_padding handle ~horizontal =
  let (Av view) =
    Ui.Widget.Private.view (node_by_test_id handle "journal-content-width-padding").widget
  in
  match view.node with
  | Ui.Widget.Private.Padding { left; right; top; bottom } ->
    require
      (Float.equal left horizontal
       && Float.equal right horizontal
       && Float.equal top 0.
       && Float.equal bottom 0.)
      "content width padding is %.1f/%.1f/%.1f/%.1f, expected horizontal %.1f"
      left
      top
      right
      bottom
      horizontal
  | _ -> fail "journal-content-width-padding is not Padding"
;;

let test_root_is_owned_by_the_ocaml_timeline () =
  with_startup (fun startup ->
    let handle = create_handle startup in
    Fun.protect
      ~finally:(fun () -> Test.Handle.shutdown handle)
      (fun () ->
         pump_until_text handle "No journal entries yet";
         require_live_region handle "No journal entries yet";
         require_visible_text handle "Today";
         require_no_semantics handle "Menu";
         require_no_semantics handle "More";
         require_test_id handle "journal-capture-composer";
         require_test_id handle "journal-header";
         require_test_id handle "journal-date-context";
         require_test_id handle "journal-header-leading-placeholder";
         require_test_id handle "journal-header-account-placeholder";
         require_no_test_id handle "journal-menu";
         require_no_test_id handle "journal-menu-target";
         require_no_test_id handle "journal-more";
         require_no_test_id handle "journal-more-target";
         require_no_test_id handle "journal-date-target";
         require_test_id handle "journal-timeline";
         require_no_test_id handle "journal-capture";
         require_no_visible_text handle "Search";
         require_no_visible_text handle "Search journal";
         require_no_visible_text handle "Search journal entries";
         require_no_visible_text handle "Preview";
         require_no_visible_text handle "Attachment";
         require_no_visible_text handle "Thumbnail";
         require_no_visible_text handle "Styled token"))
;;

let test_capture_composer_replaces_the_center_orb_and_prefills_capture () =
  with_startup (fun startup ->
    let handle = create_handle startup in
    Fun.protect
      ~finally:(fun () -> Test.Handle.shutdown handle)
      (fun () ->
         pump_until_text handle "No journal entries yet";
         let props = capture_composer_props handle in
         require props.enabled "Capture composer is disabled after graph startup";
         require (not props.autofocus) "Capture composer unexpectedly steals focus";
         require (props.max_lines = 5) "Capture composer max-lines policy changed";
         require
           (String.equal props.hint_text "Capture a thought")
           "Capture composer hint changed";
         (match props.buttons with
          | [ plus; submit ] ->
            require (plus.id = 1) "Capture composer plus button ID changed";
            require
              (plus.position = Ui.Native_widget.Message_composer.Leading
               && plus.visibility = Always
               && plus.style = Plain)
              "Capture composer plus button policy changed";
            require (submit.id = 2) "Capture composer submit button ID changed";
            require
              (submit.position = Ui.Native_widget.Message_composer.Trailing
               && submit.visibility = When_non_empty
               && submit.style = Filled)
              "Capture composer submit button policy changed"
          | _ -> fail "Capture composer must expose plus and submit actions");
         require_no_test_id handle "journal-capture-target";
         require_no_test_id handle "journal-capture-feedback";
         send_capture_composer_button handle ~button_id:2 ~text:"   \n";
         require_no_test_id handle "journal-capture-sheet";
         let source = "Composer 中文 👩🏽‍💻 #literal" in
         send_capture_composer_button handle ~button_id:2 ~text:source;
         require_test_id handle "journal-capture-sheet";
         require
           (String.equal
              (Ui.Text_editing.Value.text (text_field_value handle "capture-editor"))
              source)
           "MessageComposer text was not transferred to Capture";
         require_button_enabled handle "capture-save" true))
;;

let test_capture_is_an_ocaml_contextual_modal_sheet () =
  with_startup (fun startup ->
    let handle = create_handle startup in
    Fun.protect
      ~finally:(fun () -> Test.Handle.shutdown handle)
      (fun () ->
         set_environment handle (environment ());
         pump_until_text handle "No journal entries yet";
         open_capture handle;
         require_visible_text handle "New block";
         require_test_id handle "capture-editor";
         require_test_id handle "capture-sheet-surface";
         require_decoration_without_shape
           handle
           "capture-sheet-surface"
           ~background:0xffffffffl;
         require_test_id handle "capture-close";
         require_test_id handle "capture-date-context";
         require_test_id handle "capture-task";
         require_test_id handle "capture-save";
         require_test_id handle "capture-status";
         require_test_id handle "capture-action-row";
         require_test_id handle "capture-primary-scroll";
         require_test_id handle "journal-timeline-page";
         require_test_id handle "journal-timeline";
         require_no_test_id handle "journal-capture-route";
         require_no_test_id handle "capture-toolbar";
         require_no_test_id handle "capture-cancel";
         require_no_visible_text handle "New entry";
         require_no_visible_text handle "Attach";
         require_capture_modal_page handle ~can_pop:true ~enter_ms:220 ~exit_ms:180;
         (let (Av view) =
            Ui.Widget.Private.view
              (node_by_test_id handle "capture-primary-scroll").widget
          in
          match view.node with
          | Ui.Widget.Private.Scroll_view
              { axis = Ui.Layout.Axis.Vertical; primary = true; reverse = false; _ } -> ()
          | _ -> fail "Capture editor region is not the one primary vertical scrollable");
         (let (Av view) =
            Ui.Widget.Private.view (node_by_test_id handle "capture-editor").widget
          in
          match view.node with
          | Ui.Widget.Private.Text_input
              { keyboard_type = Ui.Text_editing.Multiline
              ; input_action = Ui.Text_editing.Newline
              ; autofocus = true
              ; max_utf8_bytes = Some 65_536
              ; _
              } -> ()
          | _ -> fail "Capture editor lost multiline, autofocus, or byte-limit behavior");
         require_button_enabled handle "capture-save" false;
         require_tree_order handle "test_id=capture-close" "test_id=capture-editor";
         require_tree_order handle "test_id=capture-editor" "test_id=capture-task";
         require_tree_order handle "test_id=capture-task" "test_id=capture-save";
         click_test_id handle "capture-close";
         require_no_test_id handle "journal-capture-sheet";
         require_test_id handle "journal-timeline-page"))
;;

let test_capture_sheet_protects_dirty_state_and_reconciles_environment () =
  with_startup (fun startup ->
    let handle = create_handle startup in
    Fun.protect
      ~finally:(fun () -> Test.Handle.shutdown handle)
      (fun () ->
         set_environment handle (environment ());
         pump_until_text handle "No journal entries yet";
         open_capture handle;
         let original = text_field_value handle "capture-editor" in
         let original_session =
           let (Av view) =
             Ui.Widget.Private.view (node_by_test_id handle "capture-editor").widget
           in
           match view.node with
           | Ui.Widget.Private.Text_input { session_id; _ } -> session_id
           | _ -> fail "capture-editor is not TextInput"
         in
         let source = "中文 👩🏽‍💻 e\204\129 #literal @mention" in
         Test.Handle.apply_text_edit
           handle
           (Test.Query.test_id "capture-editor")
           ~local_revision:(ID.Text_input.Local_revision.of_int64 1L)
           ~base_document_revision:ID.Text_input.Document_revision.zero
           ~text:source
           ~selection_start:3
           ~selection_end:10
           ~composing_start:0
           ~composing_end:2
           ();
         Test.Handle.present handle;
         require_button_enabled handle "capture-save" true;
         require_capture_modal_page handle ~can_pop:false ~enter_ms:220 ~exit_ms:180;
         click_test_id handle "capture-task";
         require_visible_text handle "Todo";
         require_no_visible_text handle "Task: todo";
         set_environment
           handle
           (environment
              ~keyboard_inset_bottom:320.
              ~text_scale:2.
              ~locale:"ar_SA"
              ~brightness:Environment.Dark
              ~high_contrast:true
              ~reduced_motion:true
              ~accessible_navigation:true
              ~disable_animations:true
              ());
         pump_worker handle;
         require_capture_modal_page handle ~can_pop:false ~enter_ms:0 ~exit_ms:0;
         let current = text_field_value handle "capture-editor" in
         require
           (String.equal (Ui.Text_editing.Value.text current) source)
           "environment reconciliation lost Capture source";
         (match Ui.Text_editing.Value.composing current with
          | Some range ->
            require
              (Ui.Text_editing.Range.start_utf16 range = 0
               && Ui.Text_editing.Range.end_utf16 range = 2)
              "environment reconciliation changed composing range"
          | None -> fail "environment reconciliation lost composing range");
         (let (Av view) =
            Ui.Widget.Private.view (node_by_test_id handle "capture-editor").widget
          in
          match view.node with
          | Ui.Widget.Private.Text_input { session_id; _ } ->
            require
              (ID.Text_input.Session_id.equal original_session session_id)
              "detent reconciliation allocated a new text-input session"
          | _ -> fail "capture-editor is not TextInput after environment update");
         require
           (String.equal (Ui.Text_editing.Value.text original) "")
           "initial editor fixture was unexpectedly dirty";
         click_test_id handle "capture-close";
         require_test_id handle "capture-discard-dialog";
         require_no_test_id handle "capture-close";
         click_test_id handle "capture-keep-editing";
         require_test_id handle "capture-close";
         require
           (String.equal
              (Ui.Text_editing.Value.text (text_field_value handle "capture-editor"))
              source)
           "Keep Editing lost the complete Capture draft";
         click_test_id handle "capture-close";
         click_test_id handle "capture-discard";
         require_no_test_id handle "journal-capture-sheet";
         require_test_id handle "journal-timeline-page"))
;;

let test_header_uses_tokens_safe_area_and_independent_center () =
  with_startup (fun startup ->
    let handle = create_handle startup in
    Fun.protect
      ~finally:(fun () -> Test.Handle.shutdown handle)
      (fun () ->
         set_environment handle (environment ());
         pump_until_text handle "No journal entries yet";
         require_decoration handle "journal-root-surface" 0xfffdfdfdl;
         require_decoration handle "journal-header-surface" 0xfffdfdfdl;
         require_no_test_id handle "journal-header-handle";
         require_no_test_id handle "journal-more-surface";
         require_sized_height handle "journal-header-divider" (1. /. 3.);
         require_header_geometry handle;
         require_text_style
           handle
           "journal-header-title"
           ~size:22.
           ~line_height:(28. /. 22.)
           ~weight:Ui.Style.Font_weight.Bold
           ~color:0xff0d142fl;
         require_text_style
           handle
           "journal-header-subtitle"
           ~size:15.
           ~line_height:(20. /. 15.)
           ~weight:Ui.Style.Font_weight.Medium
           ~color:0xff656b8fl;
         require_no_semantics handle "Menu";
         require_no_semantics handle "More";
         require_test_id handle "journal-header-leading-placeholder";
         require_test_id handle "journal-header-account-placeholder";
         require_no_test_id handle "journal-menu-target";
         require_no_test_id handle "journal-more-target";
         (let (Av view) =
            Ui.Widget.Private.view
              (node_by_test_id handle "journal-capture-composer-safe-area").widget
          in
          match view.node with
          | Ui.Widget.Private.Safe_area { left; top; right; bottom; _ } ->
            require
              ((not left) && (not top) && (not right) && bottom)
              "Capture composer safe-area edges changed"
          | _ -> fail "journal-capture-composer-safe-area is not SafeArea");
         require_capture_composer_position handle;
         require_test_id handle "journal-capture-composer-plus";
         require_test_id handle "journal-capture-composer-submit";
         require_no_visible_text handle "Search"))
;;

let test_header_adapts_without_exposing_deferred_actions () =
  with_startup (fun startup ->
    let handle = create_handle startup in
    Fun.protect
      ~finally:(fun () -> Test.Handle.shutdown handle)
      (fun () ->
         set_environment handle (environment ~viewport_width:320. ());
         pump_until_text handle "No journal entries yet";
         require_header_geometry handle;
         require_no_semantics handle "Menu";
         require_no_semantics handle "More";
         set_environment handle (environment ~viewport_width:1_200. ~platform:"macos" ());
         pump_worker handle;
         require_header_geometry handle;
         require_no_semantics handle "Menu";
         require_no_semantics handle "More";
         require_no_visible_text handle "Search";
         set_environment handle (environment ~locale:"ar_SA" ());
         pump_worker handle;
         require_capture_composer_position handle))
;;

let test_timeline_content_is_capped_and_centered () =
  with_startup (fun startup ->
    let handle = create_handle startup in
    Fun.protect
      ~finally:(fun () -> Test.Handle.shutdown handle)
      (fun () ->
         let require_case ~viewport_width ~platform ~horizontal =
           set_environment handle (environment ~viewport_width ~platform ());
           pump_until_text handle "No journal entries yet";
           require_content_width_padding handle ~horizontal
         in
         require_case ~viewport_width:320. ~platform:"ios" ~horizontal:0.;
         require_case ~viewport_width:719.5 ~platform:"ios" ~horizontal:0.;
         require_case ~viewport_width:720. ~platform:"macos" ~horizontal:0.;
         require_case ~viewport_width:744. ~platform:"ios" ~horizontal:12.;
         require_case ~viewport_width:1_200. ~platform:"macos" ~horizontal:240.))
;;

let test_header_stays_light_when_the_system_uses_dark_appearance () =
  with_startup (fun startup ->
    let handle = create_handle startup in
    Fun.protect
      ~finally:(fun () -> Test.Handle.shutdown handle)
      (fun () ->
         set_environment handle (environment ~brightness:Environment.Dark ());
         pump_until_text handle "No journal entries yet";
         require_decoration handle "journal-root-surface" 0xfffdfdfdl;
         require_decoration handle "journal-header-surface" 0xfffdfdfdl;
         require_text_style
           handle
           "journal-header-title"
           ~size:22.
           ~line_height:(28. /. 22.)
           ~weight:Ui.Style.Font_weight.Bold
           ~color:0xff0d142fl;
         set_environment
           handle
           (environment ~brightness:Environment.Dark ~high_contrast:true ());
         pump_worker handle;
         require_decoration handle "journal-root-surface" 0xffffffffl;
         require_text_style
           handle
           "journal-header-title"
           ~size:22.
           ~line_height:(28. /. 22.)
           ~weight:Ui.Style.Font_weight.Bold
           ~color:0xff000000l))
;;

let test_timeline_uses_exact_sparse_extent_window () =
  with_startup (fun startup ->
    seed
      startup
      (List.init 70 (fun offset ->
         let number = offset + 1 in
         capture number (Printf.sprintf "Paged journal row %02d" number)));
    let handle = create_handle startup in
    Fun.protect
      ~finally:(fun () -> Test.Handle.shutdown handle)
      (fun () ->
         set_environment handle (environment ~safe_area_bottom:34. ());
         pump_until_text handle "Paged journal row 01";
         require_no_visible_text handle "Paged journal row 70";
         let node = node_by_test_id handle "journal-timeline" in
         let props = timeline_props handle in
         require
           (props.total_count = 66)
           "initial feed count is %d, expected 66"
           props.total_count;
         require (props.first_index = 0) "initial timeline does not start at zero";
         require
           (Float.equal props.default_item_extent 44.)
           "timeline default extent is %.1f, expected 44"
           props.default_item_extent;
         require (props.overscan = 4) "timeline overscan is %d, expected 4" props.overscan;
         require
           (Array.length node.children <= Journal_timeline_state.maximum_supplied_rows)
           "timeline supplied %d rows"
           (Array.length node.children);
         require
           (List.exists
              (fun (override : Ui.Widget.Sparse_extent_override.t) ->
                 override.index = 65 && Float.equal override.extent 102.)
              props.extent_overrides)
           "timeline is missing exact final FAB and safe-bottom clearance";
         send_visible_range handle ~first_index:58 ~last_exclusive:65;
         pump_until_text handle "Paged journal row 70";
         require_no_visible_text handle "Paged journal row 01";
         let paged_node = node_by_test_id handle "journal-timeline" in
         let paged = timeline_props handle in
         require (paged.total_count = 71) "paged timeline count is %d" paged.total_count;
         require
           (Array.length paged_node.children
            <= Journal_timeline_state.maximum_supplied_rows)
           "paged timeline supplied %d rows"
           (Array.length paged_node.children)))
;;

let test_timeline_preserves_stable_slot_keys_across_window_shifts () =
  with_startup (fun startup ->
    let captures =
      List.init 70 (fun offset ->
        let number = offset + 1 in
        capture number (Printf.sprintf "Stable key row %02d" number))
    in
    seed startup captures;
    let handle = create_handle startup in
    Fun.protect
      ~finally:(fun () -> Test.Handle.shutdown handle)
      (fun () ->
         pump_until_text handle "Stable key row 01";
         let initial_keys = timeline_item_keys handle in
         require_unique_timeline_item_keys initial_keys;
         let overlapping_capture = List.nth captures 9 in
         let logical_key = Ui.Key.string ("block:" ^ overlapping_capture.block_id) in
         require
           (List.exists (Ui.Key.equal logical_key) initial_keys)
           "timeline root keys do not include logical slot %s"
           (Ui.Key.to_debug_string logical_key);
         let initial_node =
           match Test.Handle.find handle (Test.Query.key logical_key) with
           | Some node -> node
           | None -> fail "missing keyed timeline slot before window shift"
         in
         send_visible_range handle ~first_index:8 ~last_exclusive:16;
         pump_worker handle;
         let shifted = timeline_props handle in
         require
           (shifted.first_index > 0)
           "timeline window did not shift away from its initial origin";
         let shifted_keys = timeline_item_keys handle in
         require_unique_timeline_item_keys shifted_keys;
         require
           (List.exists (Ui.Key.equal logical_key) shifted_keys)
           "overlapping logical slot lost its stable root key";
         let shifted_node =
           match Test.Handle.find handle (Test.Query.key logical_key) with
           | Some node -> node
           | None -> fail "missing keyed timeline slot after window shift"
         in
         require
           (ID.Ui.Node_id.equal initial_node.node_id shifted_node.node_id)
           "overlapping logical slot did not preserve its mounted node identity"))
;;

let test_one_visible_range_drains_multiple_day_continuations () =
  with_startup (fun startup ->
    let one day index label = capture ~day index label in
    let many day first_index prefix =
      List.init 70 (fun offset ->
        let row = offset + 1 in
        one day (first_index + offset) (Printf.sprintf "%s row %02d" prefix row))
    in
    seed
      startup
      ([ one 20260809 200 "Demand today"; one 20260808 201 "Demand yesterday" ]
       @ many 20260807 300 "Demand day seven"
       @ many 20260806 400 "Demand day six");
    let handle = create_handle startup in
    Fun.protect
      ~finally:(fun () -> Test.Handle.shutdown handle)
      (fun () ->
         set_environment handle (environment ~platform:"macos" ());
         pump_until_text handle "Demand day seven row 01";
         require_test_id handle "journal-day-continuation:20260807";
         require_test_id handle "journal-day-continuation:20260806";
         let initial = timeline_props handle in
         require
           (initial.total_count = 10)
           "multi-continuation feed has %d slots, expected 10"
           initial.total_count;
         send_visible_range handle ~first_index:0 ~last_exclusive:10;
         pump_until handle "all initial visible continuation requests" (fun () ->
           (timeline_props handle).total_count = 138);
         require_no_test_id handle "journal-day-continuation:20260807";
         require
           ((timeline_props handle).total_count = 138)
           "one visible range event did not drain both continuation pages"))
;;

let test_collapsed_group_divider_is_full_width_and_one_physical_pixel () =
  with_startup (fun startup ->
    let leaf = capture 75 "Full width divider row" in
    seed startup [ leaf ];
    let handle = create_handle startup in
    Fun.protect
      ~finally:(fun () -> Test.Handle.shutdown handle)
      (fun () ->
         pump_until_text handle leaf.source;
         List.iter
           (fun device_pixel_ratio ->
              set_environment handle (environment ~device_pixel_ratio ());
              pump_worker handle;
              require_test_id handle ("journal-group-divider:" ^ leaf.block_id);
              require_horizontal_padding
                handle
                ("journal-group-divider-padding:" ^ leaf.block_id)
                ~left:0.
                ~right:0.;
              require_sized_height
                handle
                ("journal-group-divider:" ^ leaf.block_id)
                (1. /. device_pixel_ratio))
           [ 1.; 2.; 3.; 4. ]))
;;

let test_timeline_uses_truthful_fallback_labels_without_duplicate_today () =
  with_startup (fun startup ->
    seed startup [ capture 80 "Today row"; capture ~day:20260808 81 "Older row" ];
    let handle = create_handle startup in
    Fun.protect
      ~finally:(fun () -> Test.Handle.shutdown handle)
      (fun () ->
         pump_until_text handle "Older row";
         require_semantics_view handle "2026-08-08" (fun view ->
           require (view.role = Ui.Semantics.Role.Header) "day heading role changed";
           require (view.heading_level = Some 2) "day heading level changed");
         require
           (List.length (Test.Handle.find_all handle (Test.Query.visible_text "Today"))
            = 1)
           "Today heading was duplicated inside the timeline"))
;;

let test_timeline_deemphasizes_repeated_and_historical_timestamps () =
  with_startup (fun startup ->
    let at_minute day minute index source =
      let capture = capture ~day index source in
      { capture with creation_time = fixture_time day minute }
    in
    let first = at_minute 20260809 600 80 "First at ten" in
    let duplicate = at_minute 20260809 600 81 "Also at ten" in
    let next_minute = at_minute 20260809 601 82 "At ten oh one" in
    let repeated_later = at_minute 20260809 600 83 "Back at ten" in
    let historical = at_minute 20260808 602 84 "Historical entry" in
    seed startup [ first; duplicate; next_minute; repeated_later; historical ];
    let handle = create_handle startup in
    Fun.protect
      ~finally:(fun () -> Test.Handle.shutdown handle)
      (fun () ->
         pump_until_text handle historical.source;
         require_test_id handle ("journal-row-time:" ^ first.block_id);
         require_no_test_id handle ("journal-row-time:" ^ duplicate.block_id);
         require_test_id handle ("journal-row-time:" ^ next_minute.block_id);
         require_test_id handle ("journal-row-time:" ^ repeated_later.block_id);
         require_no_test_id handle ("journal-row-time:" ^ historical.block_id);
         require_semantics handle (duplicate.source ^ ", created at 10:00");
         require_semantics handle (historical.source ^ ", created at 10:02")))
;;

let test_timeline_projects_creation_time_across_a_negative_offset_day_boundary () =
  with_startup (fun startup ->
    let creation_time =
      Journal_time.create
        ~instant_unix_ms:1_786_239_000_000L
        ~local_day:20260808
        ~local_minute_of_day:1_290
        ~time_zone_id:"America/New_York"
        ~utc_offset_seconds:(-14_400)
      |> function
      | Ok value -> value
      | Error error -> fail "negative-offset fixture time failed: %s" error
    in
    let entry = { (capture ~day:20260808 85 "New York evening") with creation_time } in
    seed startup [ entry ];
    let packet =
      let locale = "en_US" in
      let time_zone_id = "America/New_York" in
      let header_size = 56 in
      let bytes =
        Bytes.make
          (header_size + String.length locale + String.length time_zone_id)
          '\000'
      in
      Bytes.blit_string "LJP1" 0 bytes 0 4;
      Bytes.set_uint16_le bytes 4 1;
      Bytes.set_uint16_le bytes 6 2;
      Bytes.set_uint16_le bytes 8 0;
      Bytes.set_uint16_le bytes 10 (String.length locale);
      Bytes.set_uint16_le bytes 12 (String.length time_zone_id);
      Bytes.set_int64_le bytes 16 1_786_239_000_000L;
      Bytes.set_int32_le bytes 24 20260808l;
      Bytes.set_uint16_le bytes 28 1_290;
      Bytes.set_int32_le bytes 32 (-14_400l);
      Bytes.set_int64_le bytes 40 1L;
      Bytes.set_int64_le bytes 48 0L;
      Bytes.blit_string locale 0 bytes header_size (String.length locale);
      Bytes.blit_string
        time_zone_id
        0
        bytes
        (header_size + String.length locale)
        (String.length time_zone_id);
      platform_envelope 2 bytes
    in
    let handle = create_handle_with_calendar startup packet in
    Fun.protect
      ~finally:(fun () -> Test.Handle.shutdown handle)
      (fun () ->
         pump_until_text handle entry.source;
         require_semantics handle (entry.source ^ ", created at 21:30")))
;;

let test_virtualized_timeline_does_not_repeat_time_at_window_boundary () =
  with_startup (fun startup ->
    let captures =
      List.init 70 (fun offset ->
        let number = 300 + offset in
        let capture =
          capture number (Printf.sprintf "Repeated minute row %02d" (offset + 1))
        in
        { capture with creation_time = fixture_time 20260809 600 })
    in
    seed startup captures;
    let handle = create_handle startup in
    Fun.protect
      ~finally:(fun () -> Test.Handle.shutdown handle)
      (fun () ->
         set_environment handle (environment ~safe_area_bottom:34. ());
         pump_until_text handle "Repeated minute row 01";
         require_visible_text handle "10:00";
         require_no_test_id handle ("journal-row-time:" ^ (List.nth captures 1).block_id);
         send_visible_range handle ~first_index:58 ~last_exclusive:65;
         pump_until_text handle "Repeated minute row 70";
         require_no_visible_text handle "10:00"))
;;

let test_view_only_date_and_capture_route_own_plain_text_mutation_behavior () =
  with_startup (fun startup ->
    let handle = create_handle startup in
    Fun.protect
      ~finally:(fun () -> Test.Handle.shutdown handle)
      (fun () ->
         pump_until_text handle "No journal entries yet";
         require_test_id handle "journal-date-context";
         require_no_test_id handle "journal-date-target";
         require_no_test_id handle "journal-date-dialog";
         require_no_test_id handle "journal-date-selection";
         open_capture handle;
         require_test_id handle "capture-editor";
         require_test_id handle "capture-save";
         require_test_id handle "capture-task";
         require_no_test_id handle "capture-attachment";
         require_no_test_id handle "capture-token-action";
         let source = "中文 👩🏽‍💻 e\204\129 literal-token @mention" in
         Test.Handle.apply_text_edit
           handle
           (Test.Query.test_id "capture-editor")
           ~local_revision:(ID.Text_input.Local_revision.of_int64 1L)
           ~base_document_revision:ID.Text_input.Document_revision.zero
           ~text:source
           ~selection_start:3
           ~selection_end:10
           ~composing_start:0
           ~composing_end:2
           ();
         Test.Handle.present handle;
         let value = text_field_value handle "capture-editor" in
         require
           (String.equal (Ui.Text_editing.Value.text value) source)
           "Capture changed literal IME source";
         (match Ui.Text_editing.Value.composing value with
          | Some range ->
            require
              (Ui.Text_editing.Range.start_utf16 range = 0
               && Ui.Text_editing.Range.end_utf16 range = 2)
              "Capture changed composing range"
          | None -> fail "Capture dropped composing state");
         click_test_id handle "capture-close";
         require_test_id handle "capture-discard-dialog";
         click_test_id handle "capture-keep-editing";
         require
           (String.equal
              (Ui.Text_editing.Value.text (text_field_value handle "capture-editor"))
              source)
           "Keep editing discarded the Capture draft";
         click_test_id handle "capture-save";
         pump_until_text handle source;
         require
           (List.length (Test.Handle.find_all handle (Test.Query.visible_text source)) = 1)
           "rapid presentation duplicated the captured row"))
;;

let test_capture_adds_multiple_children_and_persists_them_with_the_parent () =
  with_startup (fun startup ->
    let handle = create_handle startup in
    Fun.protect
      ~finally:(fun () -> Test.Handle.shutdown handle)
      (fun () ->
         pump_until_text handle "No journal entries yet";
         open_capture handle;
         Test.Handle.input_text
           handle
           (Test.Query.test_id "capture-editor")
           "Captured parent";
         Test.Handle.present handle;
         require_test_id handle "capture-add-child";
         click_test_id handle "capture-add-child";
         require_test_id handle "capture-child-editor:0";
         require_button_enabled handle "capture-save" false;
         Test.Handle.input_text
           handle
           (Test.Query.test_id "capture-child-editor:0")
           "Captured first child";
         Test.Handle.present handle;
         require_button_enabled handle "capture-save" true;
         click_test_id handle "capture-add-child";
         require_test_id handle "capture-child-editor:1";
         require_button_enabled handle "capture-save" false;
         Test.Handle.input_text
           handle
           (Test.Query.test_id "capture-child-editor:1")
           "Captured second child";
         Test.Handle.present handle;
         require_button_enabled handle "capture-save" true;
         click_test_id handle "capture-save";
         pump_until_text handle "Captured parent";
         require_visible_text handle "Captured first child";
         require_visible_text handle "Captured second child";
         require_no_test_id handle "journal-capture-sheet"))
;;

let test_capture_allocates_fresh_block_identity_after_restart () =
  with_startup (fun startup ->
    let persisted : Journal_graph_projection.capture =
      { mutation_id = "80000000-0000-4000-9000-000000000002"
      ; block_id = "80000000-0000-4000-a000-000000000002"
      ; sibling_order = "000000000002"
      ; source = "Persisted before restart"
      ; task_state = Journal_model.No_status
      ; creation_time = fixture_time 20260809 2
      ; children = []
      }
    in
    seed startup [ persisted ];
    let save_capture handle source =
      open_capture handle;
      Test.Handle.input_text handle (Test.Query.test_id "capture-editor") source;
      Test.Handle.present handle;
      click_test_id handle "capture-save";
      pump_until_text handle source
    in
    let first_source = "Captured after first restart" in
    let first_handle = create_handle startup in
    Fun.protect
      ~finally:(fun () -> Test.Handle.shutdown first_handle)
      (fun () ->
         pump_until_text first_handle persisted.source;
         save_capture first_handle first_source;
         require
           (List.length
              (Test.Handle.find_all
                 first_handle
                 (Test.Query.visible_text persisted.source))
            = 1)
           "first restart duplicated the persisted row";
         require
           (List.length
              (Test.Handle.find_all first_handle (Test.Query.visible_text first_source))
            = 1)
           "first restart did not render exactly one fresh row");
    let second_source = "Captured after second restart" in
    let second_handle = create_handle startup in
    Fun.protect
      ~finally:(fun () -> Test.Handle.shutdown second_handle)
      (fun () ->
         pump_until_text second_handle first_source;
         save_capture second_handle second_source;
         List.iter
           (fun source ->
              require
                (List.length
                   (Test.Handle.find_all second_handle (Test.Query.visible_text source))
                 = 1)
                "second restart did not render exactly one row for %S"
                source)
           [ persisted.source; first_source; second_source ]))
;;

let latest_application_request handle =
  let open Protocol.Wire_frame in
  match Test.Handle.last_frame handle with
  | None -> None
  | Some frame ->
    (match Protocol.Binary_codec.decode frame.bytes with
     | Error error -> fail "application frame did not decode: %s" error.message
     | Ok wire ->
       List.find_map
         (function
           | Application_request { request_id; payload } -> Some (request_id, payload)
           | _ -> None)
         wire.operations)
;;

let pump_until_application_request handle =
  let rec loop attempts =
    if attempts = 0
    then fail "timed out waiting for the localized-day platform request"
    else (
      match latest_application_request handle with
      | Some request -> request
      | None ->
        Unix.sleepf 0.001;
        pump_worker handle;
        loop (attempts - 1))
  in
  loop 500
;;

let pump_until_application_request_generation handle generation =
  let rec loop attempts =
    if attempts = 0
    then
      fail
        "timed out waiting for formatted-day generation %Ld\n%s"
        generation
        (Test.Handle.show handle)
    else (
      match latest_application_request handle with
      | Some (_request_id, payload) as request
        when Bytes.length payload >= 48 && Bytes.get_int64_le payload 40 = generation ->
        Option.get request
      | None | Some _ ->
        Unix.sleepf 0.001;
        pump_worker handle;
        loop (attempts - 1))
  in
  loop 500
;;

let respond_to_application_request ?(sequence = 3L) handle request_id payload =
  Test.Handle.present handle;
  let event =
    Protocol.Inbound_event.
      { sequence = ID.Runtime.Event_sequence.of_int64 sequence
      ; displayed_revision = Test.Handle.revision handle
      ; node_id = ID.Ui.Node_id.zero
      ; handler_id = ID.Ui.Handler_id.zero
      ; event_tag = Protocol.Generated_protocol.Event_tag.application_response
      ; payload = Application_response { request_id; payload }
      }
  in
  Test.Handle.pump_next
    handle
    ~events:
      Protocol.Inbound_event.
        { runtime_epoch = ID.Runtime.Epoch.of_int64 9_001L; events = [ event ] }
    ()
;;

let calendar_event
      ~reason
      ~generation
      ~local_day
      ~locale
      ~time_zone_id
      ~utc_offset_seconds
  =
  let header_size = 56 in
  let utc_midnight =
    match local_day with
    | 20260809 -> 1_786_233_600_000L
    | 20260810 -> 1_786_320_000_000L
    | _ -> fail "unsupported calendar-event day %d" local_day
  in
  let instant_unix_ms =
    Int64.(sub (add utc_midnight 30_600_000L) (of_int (utc_offset_seconds * 1_000)))
  in
  let bytes =
    Bytes.make (header_size + String.length locale + String.length time_zone_id) '\000'
  in
  Bytes.blit_string "LJP1" 0 bytes 0 4;
  Bytes.set_uint16_le bytes 4 1;
  Bytes.set_uint16_le bytes 6 3;
  Bytes.set_uint16_le bytes 8 reason;
  Bytes.set_uint16_le bytes 10 (String.length locale);
  Bytes.set_uint16_le bytes 12 (String.length time_zone_id);
  Bytes.set_int64_le bytes 16 instant_unix_ms;
  Bytes.set_int32_le bytes 24 (Int32.of_int local_day);
  Bytes.set_uint16_le bytes 28 510;
  Bytes.set_int32_le bytes 32 (Int32.of_int utc_offset_seconds);
  Bytes.set_int64_le bytes 40 generation;
  Bytes.set_int64_le bytes 48 1L;
  Bytes.blit_string locale 0 bytes header_size (String.length locale);
  Bytes.blit_string
    time_zone_id
    0
    bytes
    (header_size + String.length locale)
    (String.length time_zone_id);
  platform_envelope 3 bytes
;;

let send_application_event handle ~sequence payload =
  Test.Handle.present handle;
  let event =
    Protocol.Inbound_event.
      { sequence = ID.Runtime.Event_sequence.of_int64 sequence
      ; displayed_revision = Test.Handle.revision handle
      ; node_id = ID.Ui.Node_id.zero
      ; handler_id = ID.Ui.Handler_id.zero
      ; event_tag = Protocol.Generated_protocol.Event_tag.application_event
      ; payload = Application_event payload
      }
  in
  Test.Handle.pump_next
    handle
    ~events:
      Protocol.Inbound_event.
        { runtime_epoch = ID.Runtime.Epoch.of_int64 9_001L; events = [ event ] }
    ()
;;

let formatted_response ~generation headings =
  let size =
    20
    + List.fold_left
        (fun total (_, heading) -> total + 8 + String.length heading)
        0
        headings
  in
  let bytes = Bytes.make size '\000' in
  Bytes.blit_string "LJP1" 0 bytes 0 4;
  Bytes.set_uint16_le bytes 4 1;
  Bytes.set_uint16_le bytes 6 5;
  Bytes.set_int64_le bytes 8 generation;
  Bytes.set_uint16_le bytes 16 (List.length headings);
  ignore
    (List.fold_left
       (fun offset (day, heading) ->
          Bytes.set_int32_le bytes offset (Int32.of_int day);
          Bytes.set_uint16_le bytes (offset + 4) (String.length heading);
          Bytes.blit_string heading 0 bytes (offset + 8) (String.length heading);
          offset + 8 + String.length heading)
       20
       headings);
  platform_envelope 5 bytes
;;

let require_populated_timeline_during_calendar_event handle ~source ~sequence event =
  send_application_event handle ~sequence event;
  for _ = 1 to 8 do
    Test.Handle.present handle;
    require_visible_text handle source;
    require_no_visible_text handle "Loading journal";
    pump_worker handle
  done
;;

let test_same_context_resume_keeps_the_populated_timeline () =
  with_startup (fun startup ->
    let row = capture 85 "Same-context resume row" in
    seed startup [ row ];
    let handle = create_handle startup in
    Fun.protect
      ~finally:(fun () -> Test.Handle.shutdown handle)
      (fun () ->
         pump_until_text handle row.source;
         require_populated_timeline_during_calendar_event
           handle
           ~source:row.source
           ~sequence:3L
           (calendar_event
              ~reason:1
              ~generation:2L
              ~local_day:20260809
              ~locale:"en_US"
              ~time_zone_id:"Asia/Shanghai"
              ~utc_offset_seconds:28_800)))
;;

let test_locale_only_change_reformats_without_reloading () =
  with_startup (fun startup ->
    let row = capture ~day:20260808 86 "Locale-only row" in
    seed startup [ row ];
    let handle = create_handle startup in
    Fun.protect
      ~finally:(fun () -> Test.Handle.shutdown handle)
      (fun () ->
         pump_until_text handle row.source;
         require_populated_timeline_during_calendar_event
           handle
           ~source:row.source
           ~sequence:3L
           (calendar_event
              ~reason:4
              ~generation:2L
              ~local_day:20260809
              ~locale:"zh_CN"
              ~time_zone_id:"Asia/Shanghai"
              ~utc_offset_seconds:28_800)))
;;

let test_day_rollover_refreshes_without_blanking_content () =
  with_startup (fun startup ->
    let row = capture 87 "Day-rollover row" in
    seed startup [ row ];
    let handle = create_handle startup in
    Fun.protect
      ~finally:(fun () -> Test.Handle.shutdown handle)
      (fun () ->
         pump_until_text handle row.source;
         require_populated_timeline_during_calendar_event
           handle
           ~source:row.source
           ~sequence:3L
           (calendar_event
              ~reason:2
              ~generation:2L
              ~local_day:20260810
              ~locale:"en_US"
              ~time_zone_id:"Asia/Shanghai"
              ~utc_offset_seconds:28_800);
         pump_until_text handle row.source;
         require_no_visible_text handle "Loading journal"))
;;

let test_time_zone_refresh_reprojects_without_blanking_content () =
  with_startup (fun startup ->
    let row = capture 88 "Time-zone refresh row" in
    seed startup [ row ];
    let handle = create_handle startup in
    Fun.protect
      ~finally:(fun () -> Test.Handle.shutdown handle)
      (fun () ->
         pump_until_text handle row.source;
         require_semantics handle (row.source ^ ", created at 01:28");
         require_populated_timeline_during_calendar_event
           handle
           ~source:row.source
           ~sequence:3L
           (calendar_event
              ~reason:3
              ~generation:2L
              ~local_day:20260809
              ~locale:"en_US"
              ~time_zone_id:"UTC"
              ~utc_offset_seconds:0);
         pump_until handle "UTC timestamp reprojection" (fun () ->
           Option.is_some
             (Test.Handle.find
                handle
                (Test.Query.semantics_label (row.source ^ ", created at 17:28"))));
         require_no_visible_text handle "Loading journal"))
;;

let test_localized_day_request_updates_only_matching_generation () =
  with_startup (fun startup ->
    seed startup [ capture ~day:20260808 82 "Localized older row" ];
    let handle = create_handle startup in
    Fun.protect
      ~finally:(fun () -> Test.Handle.shutdown handle)
      (fun () ->
         let request = pump_until_application_request handle in
         let request_id, payload = request in
         require
           (Bytes.get_uint16_le payload 6 = 4)
           "application did not request formatted journal days";
         require
           (Bytes.get_int64_le payload 40 = 1L)
           "formatted-day request used the wrong calendar generation";
         respond_to_application_request
           handle
           request_id
           (formatted_response
              ~generation:0L
              [ 20260809, "stale today"; 20260808, "stale older" ]);
         Test.Handle.present handle;
         require_no_visible_text handle "stale today";
         require_no_visible_text handle "stale older"));
  with_startup (fun startup ->
    seed startup [ capture ~day:20260808 83 "Accepted localized older row" ];
    let handle = create_handle startup in
    Fun.protect
      ~finally:(fun () -> Test.Handle.shutdown handle)
      (fun () ->
         let request = pump_until_application_request handle in
         let request_id, _payload = request in
         respond_to_application_request
           handle
           request_id
           (formatted_response
              ~generation:1L
              [ 20260809, "Sun, Aug 9"; 20260808, "Sat, Aug 8" ]);
         Test.Handle.present handle;
         require_visible_text handle "Sun, Aug 9";
         require_visible_text handle "Sat, Aug 8";
         require_no_visible_text handle "2026-08-09";
         require_no_visible_text handle "2026-08-08"))
;;

let test_locale_event_invalidates_labels_and_rejects_in_flight_response () =
  with_startup (fun startup ->
    seed startup [ capture ~day:20260808 84 "Locale event older row" ];
    let handle = create_handle startup in
    Fun.protect
      ~finally:(fun () -> Test.Handle.shutdown handle)
      (fun () ->
         let old_request_id, _old_payload = pump_until_application_request handle in
         send_application_event
           handle
           ~sequence:3L
           (calendar_event
              ~reason:4
              ~generation:2L
              ~local_day:20260810
              ~locale:"zh_CN"
              ~time_zone_id:"Asia/Shanghai"
              ~utc_offset_seconds:28_800);
         let new_request_id, new_payload =
           pump_until_application_request_generation handle 2L
         in
         require
           (Bytes.get_int64_le new_payload 40 = 2L)
           "locale event did not issue a generation-2 formatting request";
         respond_to_application_request
           ~sequence:4L
           handle
           old_request_id
           (formatted_response
              ~generation:1L
              [ 20260809, "stale locale today"; 20260808, "stale locale older" ]);
         Test.Handle.present handle;
         require_no_visible_text handle "stale locale today";
         require_no_visible_text handle "stale locale older";
         respond_to_application_request
           ~sequence:5L
           handle
           new_request_id
           (formatted_response
              ~generation:2L
              [ 20260810, "周一，8月10日"; 20260808, "周六，8月8日" ]);
         Test.Handle.present handle;
         require_visible_text handle "周一，8月10日";
         pump_until_text handle "周六，8月8日"))
;;

let test_timeline_status_rail_has_no_task_action () =
  with_startup (fun startup ->
    let parent = capture ~task_state:Journal_model.Todo 90 "Parent task source" in
    seed startup [ parent ];
    let child = seed_child startup ~parent 91 "Existing direct child" in
    let handle = create_handle startup in
    Fun.protect
      ~finally:(fun () -> Test.Handle.shutdown handle)
      (fun () ->
         pump_until_text handle parent.source;
         require_no_test_id handle ("journal-row-task:" ^ parent.block_id);
         require_no_test_id handle ("journal-row-task-target:" ^ parent.block_id);
         require_no_test_id handle ("journal-row-task-icon:" ^ parent.block_id);
         require_test_id handle ("journal-row-status-rail:" ^ parent.block_id);
         click_test_id handle ("journal-row-toggle-children:" ^ parent.block_id);
         pump_until handle "direct child preview" (fun () ->
           Option.is_some
             (Test.Handle.find
                handle
                (Test.Query.test_id ("journal-child-preview:" ^ child.block_id))));
         require_no_test_id handle ("journal-row-open:" ^ parent.block_id);
         require_no_test_id handle ("journal-row-disclosure:" ^ parent.block_id);
         click_test_id handle ("journal-row-toggle-children:" ^ parent.block_id);
         pump_until handle "row-body collapse" (fun () ->
           Option.is_none
             (Test.Handle.find
                handle
                (Test.Query.test_id ("journal-child-preview:" ^ child.block_id))))))
;;

let test_pending_day_response_drains_expanded_parent_without_renderer_input () =
  with_startup (fun startup ->
    let parent = capture 660 "Queued expansion parent" in
    let row number =
      capture number (Printf.sprintf "Queued expansion page row %03d" number)
    in
    let before_parent = List.init 35 (fun offset -> row (600 + offset)) in
    let after_parent = List.init 35 (fun offset -> row (661 + offset)) in
    seed startup (before_parent @ (parent :: after_parent));
    let child = seed_child startup ~parent 700 "Queued expansion persisted child" in
    let handle = create_handle startup in
    Fun.protect
      ~finally:(fun () -> Test.Handle.shutdown handle)
      (fun () ->
         pump_until_text handle parent.source;
         let initial = timeline_props handle in
         require
           (initial.total_count = 65)
           "queued expansion fixture has %d slots, expected 65"
           initial.total_count;
         send_visible_range handle ~first_index:30 ~last_exclusive:65;
         click_test_id handle ("journal-row-toggle-children:" ^ parent.block_id);
         require_test_id handle ("journal-children-loading:" ^ parent.block_id);
         pump_until handle "queued child request after accepted day response" (fun () ->
           Option.is_some
             (Test.Handle.find
                handle
                (Test.Query.test_id ("journal-child-preview:" ^ child.block_id))));
         require_no_test_id handle ("journal-children-loading:" ^ parent.block_id)))
;;

let test_loaded_children_survive_a_stale_ios_visible_range_event () =
  with_startup (fun startup ->
    let parent = capture 118 "iOS child loading parent" in
    seed startup [ parent ];
    let child = seed_child startup ~parent 119 "iOS loaded direct child" in
    let handle = create_handle startup in
    Fun.protect
      ~finally:(fun () -> Test.Handle.shutdown handle)
      (fun () ->
         set_environment handle (environment ~platform:"ios" ());
         pump_until_text handle parent.source;
         click_test_id handle ("journal-row-toggle-children:" ^ parent.block_id);
         require_test_id handle ("journal-children-loading:" ^ parent.block_id);
         let stale_binding = capture_native_binding handle "journal-timeline" in
         pump_until handle "loaded iOS direct child" (fun () ->
           Option.is_some
             (Test.Handle.find
                handle
                (Test.Query.test_id ("journal-child-preview:" ^ child.block_id))));
         send_stale_visible_range handle stale_binding ~first_index:0 ~last_exclusive:3;
         Test.Handle.present handle;
         require_test_id handle ("journal-child-preview:" ^ child.block_id);
         require_no_test_id handle ("journal-children-loading:" ^ parent.block_id)))
;;

let test_collapsed_parent_receives_truthful_child_summaries_in_initial_feed () =
  with_startup (fun startup ->
    let parent = capture 120 "Parent summary source" in
    let leaf = capture 121 "Leaf without summary" in
    seed startup [ parent; leaf ];
    let child = seed_child startup ~parent 122 "First direct child summary" in
    let handle = create_handle startup in
    Fun.protect
      ~finally:(fun () -> Test.Handle.shutdown handle)
      (fun () ->
         pump_until_text handle parent.source;
         require_visible_text handle child.source;
         require_test_id handle ("journal-row-supporting:" ^ parent.block_id ^ ":0");
         require_visible_text_count handle child.source 1;
         require_visible_text_count handle leaf.source 1;
         require_no_test_id handle ("journal-row-supporting:" ^ leaf.block_id ^ ":0");
         require_no_test_id handle ("journal-children-loading:" ^ parent.block_id);
         require_semantics
           handle
           (parent.source ^ ", " ^ child.source ^ ", created at 02:00");
         require_no_semantics handle ("Direct child: " ^ child.source)))
;;

let _test_collapsed_rows_share_three_lines_between_parent_and_child_content () =
  with_startup (fun startup ->
    let two_line_parent = capture 123 "Parent line one\nParent line two" in
    let one_line_parent = capture 126 "Single parent line" in
    let three_line_parent = capture 131 "Line one\nLine two\nLine three\nLine four" in
    seed startup [ two_line_parent; one_line_parent; three_line_parent ];
    let first_for_two =
      seed_child startup ~parent:two_line_parent 124 "Two-line child one"
    in
    let second_for_two =
      seed_child startup ~parent:two_line_parent 125 "Two-line child two"
    in
    let first_for_one =
      seed_child startup ~parent:one_line_parent 127 "One-line child one"
    in
    let second_for_one =
      seed_child startup ~parent:one_line_parent 128 "One-line child two"
    in
    let third_for_one =
      seed_child startup ~parent:one_line_parent 129 "One-line child three"
    in
    let hidden_for_three =
      seed_child startup ~parent:three_line_parent 132 "Three-line hidden child"
    in
    let handle = create_handle startup in
    Fun.protect
      ~finally:(fun () -> Test.Handle.shutdown handle)
      (fun () ->
         pump_until_text handle one_line_parent.source;
         require_text_max_lines
           handle
           ("journal-row-source:" ^ two_line_parent.block_id)
           2;
         require_visible_text handle first_for_two.source;
         require_no_visible_text handle second_for_two.source;
         require_text_max_lines
           handle
           ("journal-row-source:" ^ one_line_parent.block_id)
           1;
         require_visible_text handle first_for_one.source;
         require_visible_text handle second_for_one.source;
         require_no_visible_text handle third_for_one.source;
         require_text_max_lines
           handle
           ("journal-row-source:" ^ three_line_parent.block_id)
           3;
         require_no_visible_text handle hidden_for_three.source;
         require_padding
           handle
           ("journal-row-body-padding:" ^ one_line_parent.block_id)
           ~left:32.
           ~top:8.
           ~right:24.
           ~bottom:8.))
;;

let test_expanded_children_are_static_previews_without_group_separator () =
  with_startup (fun startup ->
    let parent =
      capture
        ~task_state:Journal_model.Todo
        130
        "Bounded preview parent\nSecond parent line"
    in
    seed startup [ parent ];
    let first = seed_child startup ~parent 131 "Preview child one" in
    let second =
      seed_child startup ~parent ~task_state:Journal_model.Todo 132 "Preview task child"
    in
    let third = seed_child startup ~parent 133 "Preview child with descendant" in
    let fourth = seed_child startup ~parent 134 "Preview child beyond bound" in
    ignore
      (seed_child_by_parent_id
         startup
         ~parent_block_id:third.block_id
         135
         "Nested child must not appear");
    let handle = create_handle startup in
    Fun.protect
      ~finally:(fun () -> Test.Handle.shutdown handle)
      (fun () ->
         pump_until_text handle "Bounded preview parent";
         require_visible_text_count handle first.source 1;
         click_test_id handle ("journal-row-toggle-children:" ^ parent.block_id);
         pump_until handle "three child previews and static More" (fun () ->
           Option.is_some
             (Test.Handle.find
                handle
                (Test.Query.test_id ("journal-children-more:" ^ parent.block_id))));
         require_visible_text_count handle first.source 1;
         require_visible_text_count handle second.source 1;
         require_no_test_id handle ("journal-row-supporting:" ^ parent.block_id ^ ":0");
         require_no_test_id handle ("journal-row-supporting:" ^ parent.block_id ^ ":1");
         List.iter
           (fun (child : Journal_graph_projection.create_child) ->
              require_test_id handle ("journal-child-preview:" ^ child.block_id);
              require_no_test_id handle ("journal-row-swipe:" ^ child.block_id);
              require_no_test_id handle ("journal-row-task:" ^ child.block_id);
              require_no_test_id handle ("journal-row-toggle-children:" ^ child.block_id))
           [ first; second; third ];
         require_test_id handle ("journal-child-status-rail:" ^ second.block_id);
         require_no_test_id handle ("journal-child-status-rail:" ^ first.block_id);
         require_no_test_id handle ("journal-child-status-rail:" ^ third.block_id);
         require_no_visible_text handle fourth.source;
         require_no_visible_text handle "Nested child must not appear";
         require_semantics handle ("Direct child: " ^ first.source);
         require_semantics handle ("Direct child: " ^ second.source ^ ", status Todo");
         require_semantics handle ("Direct child: " ^ third.source);
         require_semantics handle "More direct child blocks are not shown";
         require_semantics_view
           handle
           "More direct child blocks are not shown"
           (fun view -> require (not view.live_region) "static More is a live region");
         require_no_semantics
           handle
           ("Bounded preview parent, Second parent line, "
            ^ first.source
            ^ ", status Todo, created at 02:10");
         require_semantics
           handle
           "Bounded preview parent, Second parent line, status Todo, created at 02:10";
         require_no_test_id handle ("journal-group-divider:" ^ first.block_id);
         require_no_test_id handle ("journal-group-divider:" ^ second.block_id);
         require_no_test_id handle ("journal-group-divider:" ^ parent.block_id);
         require_sized_height handle ("journal-row-extent:" ^ parent.block_id) 56.;
         click_test_id handle ("journal-row-toggle-children:" ^ parent.block_id);
         pump_until handle "preview collapse" (fun () ->
           Option.is_none
             (Test.Handle.find
                handle
                (Test.Query.test_id ("journal-child-preview:" ^ third.block_id))));
         require_visible_text_count handle first.source 1;
         require_visible_text_count handle second.source 1;
         require_no_visible_text handle third.source))
;;

let test_loading_and_adaptive_environment_surfaces_are_truthful () =
  with_startup (fun startup ->
    let parent = capture 100 "Adaptive application row" in
    seed startup [ parent ];
    let handle = create_handle startup in
    Fun.protect
      ~finally:(fun () -> Test.Handle.shutdown handle)
      (fun () ->
         pump_until_text handle parent.source;
         List.iter
           (fun (width, scale, platform, locale) ->
              let snapshot =
                environment
                  ~viewport_width:width
                  ~text_scale:scale
                  ~platform
                  ~locale
                  ~safe_area_bottom:34.
                  ()
              in
              set_environment handle snapshot;
              pump_worker handle;
              let expected =
                Journal_visual_tokens.select_row_profile
                  ~viewport_width:width
                  ~text_scale:scale
              in
              let props = timeline_props handle in
              require
                (Float.equal
                   props.default_item_extent
                   (Journal_visual_tokens.block_extent ~profile:expected ~visible_lines:1))
                "Application profile changed at %.0f/%.1f on %s/%s"
                width
                scale
                platform
                locale;
              require_no_semantics handle "Menu";
              require_no_semantics handle "More")
           [ 320., 1., "macos", "en_US"
           ; 390., 1.3, "ios", "en_US"
           ; 744., 2., "ios", "ar_SA"
           ; 1_200., 3.2, "macos", "ar_SA"
           ];
         set_environment
           handle
           (environment ~reduced_motion:true ~safe_area_bottom:34. ());
         pump_worker handle;
         (match (timeline_props handle).transition with
          | Some transition ->
            require
              (not (Ui.Widget.Sparse_extent_transition.enabled transition))
              "reduced motion kept list animation enabled";
            require
              (Ui.Widget.Sparse_extent_transition.expand_duration_ms transition = 0
               && Ui.Widget.Sparse_extent_transition.collapse_duration_ms transition = 0)
              "reduced motion kept nonzero list durations"
          | None -> fail "Timeline omitted its explicit transition policy");
         require_no_test_id handle ("journal-row-open:" ^ parent.block_id)))
;;

let test_swipe_delete_stages_undoes_and_commits_only_after_deadline () =
  with_startup (fun startup ->
    let command = capture 110 "Undoable delete row" in
    seed startup [ command ];
    let handle, monotonic_now_ns = create_timed_handle startup in
    Fun.protect
      ~finally:(fun () -> Test.Handle.shutdown handle)
      (fun () ->
         set_environment handle (environment ~safe_area_bottom:34. ());
         pump_until_text handle command.source;
         require_test_id handle ("journal-row-swipe:" ^ command.block_id);
         commit_end_swipe handle command.block_id;
         require_no_visible_text handle command.source;
         require_live_region handle "Block and descendants removed";
         require_test_id handle "journal-delete-snackbar-position";
         require_stack_bottom handle "journal-delete-snackbar-position" 106.;
         require_test_id handle "journal-delete-undo";
         require_button_enabled handle "journal-delete-undo" true;
         advance_clock handle monotonic_now_ns 4.9;
         click_test_id handle "journal-delete-undo";
         require_visible_text handle command.source;
         require_no_test_id handle "journal-delete-snackbar";
         advance_clock handle monotonic_now_ns 1.;
         require_visible_text handle command.source));
  with_startup (fun startup ->
    let command = capture 111 "Committed delete row" in
    seed startup [ command ];
    let handle, monotonic_now_ns = create_timed_handle startup in
    pump_until_text handle command.source;
    commit_end_swipe handle command.block_id;
    require_no_visible_text handle command.source;
    advance_clock handle monotonic_now_ns 5.;
    pump_until handle "durable subtree delete" (fun () ->
      Option.is_none
        (Test.Handle.find handle (Test.Query.test_id "journal-delete-snackbar")));
    for _ = 1 to 64 do
      pump_worker handle
    done;
    require_no_test_id handle "journal-delete-undo";
    Test.Handle.shutdown handle;
    let engine =
      Logseq_db_worker.Engine.open_ ~dependencies:Adapter_fixture.dependencies startup
      |> Result.get_ok
    in
    Fun.protect
      ~finally:(fun () -> ignore (Logseq_db_worker.Engine.close engine))
      (fun () ->
         match
           Logseq_db_worker.Engine.execute
             engine
             (graph_request (Read (Get_block { block = uuid command.block_id })))
         with
         | Failed failure when Logseq_db_worker.Error.code failure.error = Not_found -> ()
         | Succeeded _ -> fail "deadline delete was not durable"
         | Failed failure ->
           fail
             "deadline delete lookup failed: %s"
             (Logseq_db_worker.Error.message failure.error)))
;;

let test_swipe_delete_accessibility_duration_and_single_mutation_gate () =
  with_startup (fun startup ->
    let first = capture 112 "First delete row" in
    let second = capture 113 "Second delete row" in
    seed startup [ first; second ];
    let handle, monotonic_now_ns = create_timed_handle startup in
    Fun.protect
      ~finally:(fun () -> Test.Handle.shutdown handle)
      (fun () ->
         set_environment handle (environment ~accessible_navigation:true ());
         pump_until_text handle first.source;
         commit_end_swipe handle first.block_id;
         require_no_test_id handle ("journal-row-swipe:" ^ second.block_id);
         require_no_semantics handle "Delete block and all descendants";
         advance_clock handle monotonic_now_ns 5.;
         require_test_id handle "journal-delete-undo";
         advance_clock handle monotonic_now_ns 5.;
         pump_until handle "accessible delete deadline" (fun () ->
           Option.is_none
             (Test.Handle.find handle (Test.Query.test_id "journal-delete-undo")))))
;;

let () =
  test_initial_feed_has_a_truthful_loading_state ();
  test_timeline_content_is_capped_and_centered ();
  test_root_is_owned_by_the_ocaml_timeline ();
  test_capture_composer_replaces_the_center_orb_and_prefills_capture ();
  test_capture_is_an_ocaml_contextual_modal_sheet ();
  test_capture_sheet_protects_dirty_state_and_reconciles_environment ();
  test_header_uses_tokens_safe_area_and_independent_center ();
  test_header_adapts_without_exposing_deferred_actions ();
  test_header_stays_light_when_the_system_uses_dark_appearance ();
  test_timeline_uses_exact_sparse_extent_window ();
  test_timeline_preserves_stable_slot_keys_across_window_shifts ();
  test_one_visible_range_drains_multiple_day_continuations ();
  test_pending_day_response_drains_expanded_parent_without_renderer_input ();
  test_collapsed_group_divider_is_full_width_and_one_physical_pixel ();
  test_timeline_uses_truthful_fallback_labels_without_duplicate_today ();
  test_timeline_deemphasizes_repeated_and_historical_timestamps ();
  test_timeline_projects_creation_time_across_a_negative_offset_day_boundary ();
  test_virtualized_timeline_does_not_repeat_time_at_window_boundary ();
  test_view_only_date_and_capture_route_own_plain_text_mutation_behavior ();
  test_capture_adds_multiple_children_and_persists_them_with_the_parent ();
  test_capture_allocates_fresh_block_identity_after_restart ();
  test_localized_day_request_updates_only_matching_generation ();
  test_locale_event_invalidates_labels_and_rejects_in_flight_response ();
  test_same_context_resume_keeps_the_populated_timeline ();
  test_locale_only_change_reformats_without_reloading ();
  test_day_rollover_refreshes_without_blanking_content ();
  test_time_zone_refresh_reprojects_without_blanking_content ();
  test_timeline_status_rail_has_no_task_action ();
  test_loaded_children_survive_a_stale_ios_visible_range_event ();
  test_collapsed_parent_receives_truthful_child_summaries_in_initial_feed ();
  test_expanded_children_are_static_previews_without_group_separator ();
  test_loading_and_adaptive_environment_surfaces_are_truthful ();
  test_swipe_delete_stages_undoes_and_commits_only_after_deadline ();
  test_swipe_delete_accessibility_duration_and_single_mutation_gate ()
;;
