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

let create_raw_handle startup =
  let time_source = Bonsai.Time_source.create ~start:Core.Time_ns.epoch in
  Test.Handle.create_app
    ~runtime_epoch:(ID.Runtime.Epoch.of_int64 9_001L)
    ~time_source
    Application.app
    ~application_payload:(encode_startup startup)
;;

let create_handle startup =
  let handle = create_raw_handle startup in
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

let send_slidable_event handle block_id ~event_id ~payload =
  Test.Handle.present handle;
  let query = Test.Query.test_id ("journal-row-slidable:" ^ block_id) in
  let node =
    match Test.Handle.find handle query with
    | Some node -> node
    | None ->
      fail "missing Slidable wrapper for %s\n%s" block_id (Test.Handle.show handle)
  in
  let kind_id =
    let (Av view) = Ui.Widget.Private.view node.widget in
    match view.node with
    | Ui.Widget.Private.Native_widget { kind_id; _ } -> kind_id
    | _ -> fail "delete Slidable is not a native widget"
  in
  Test.Handle.native_event handle query ~kind_id ~version:3 ~event_id ~payload
;;

let press_delete_action handle block_id =
  send_slidable_event
    handle
    block_id
    ~event_id:Ui.Native_widget.Slidable.action_pressed_event_id
    ~payload:(Ui.Native_widget.Slidable.For_testing.encode_action_pressed 1)
;;

let emit_unexpected_end_dismissal handle block_id =
  send_slidable_event
    handle
    block_id
    ~event_id:Ui.Native_widget.Slidable.dismissed_event_id
    ~payload:(Ui.Native_widget.Slidable.For_testing.encode_dismissed End)
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
         require_test_id handle "journal-scroll";
         require
           (List.length (Test.Handle.find_all handle (Test.Query.test_id "journal-scroll"))
            = 1)
           "loading state has more than one Journal scroll owner";
         require_visible_text handle "Loading journal";
         require_live_region handle "Loading journal";
         require_no_visible_text handle "No journal entries yet";
         pump_until_text handle "No journal entries yet";
         require_test_id handle "journal-scroll";
         require
           (List.length (Test.Handle.find_all handle (Test.Query.test_id "journal-scroll"))
            = 1)
           "empty state has more than one Journal scroll owner";
         require_no_visible_text handle "Loading journal"))
;;

let node_by_test_id handle test_id =
  match Test.Handle.find handle (Test.Query.test_id test_id) with
  | Some node -> node
  | None -> fail "expected test ID %S\n%s" test_id (Test.Handle.show handle)
;;

let require_material_icon handle test_id expected_code_point =
  let rec material_code_points widget =
    let (Av view) = Ui.Widget.Private.view widget in
    match view.node with
    | Ui.Widget.Private.Icon { code_point; font_family = Some "MaterialIcons"; _ } ->
      [ code_point ]
    | _ ->
      Array.to_list view.children
      |> List.concat_map (fun (child : Ui.Widget.Private.child) ->
        material_code_points child.widget)
  in
  match material_code_points (node_by_test_id handle test_id).widget with
  | [ code_point ] ->
    require
      (code_point = expected_code_point)
      "%s renders U+%04X instead of U+%04X"
      test_id
      code_point
      expected_code_point
  | [] -> fail "%s has no Material icon" test_id
  | code_points -> fail "%s has %d Material icons" test_id (List.length code_points)
;;

let last_wire handle =
  let frame =
    match Test.Handle.last_frame handle with
    | Some frame -> frame
    | None -> fail "headless runtime did not emit a frame"
  in
  match Protocol.Binary_codec.decode frame.bytes with
  | Ok wire -> wire
  | Error error -> fail "application frame did not decode: %s" error.message
;;

let application_theme_from_initial_frame handle =
  (last_wire handle).operations
  |> List.find_map (function
    | Protocol.Wire_frame.Set_application_theme { title; theme } -> Some (title, theme)
    | _ -> None)
  |> function
  | Some value -> value
  | None -> fail "initial frame omitted the application theme"
;;

type snack_bar_request =
  { request_id : ID.Host.request_id
  ; message : string
  ; action_label : string option
  ; duration_ms : int
  }

let snack_bar_request_from_last_frame handle =
  (last_wire handle).operations
  |> List.find_map (function
    | Protocol.Wire_frame.Host_request
        { request_id; payload = Show_snack_bar { message; action_label; duration_ms } } ->
      Some { request_id; message; action_label; duration_ms }
    | _ -> None)
  |> function
  | Some request -> request
  | None -> fail "frame omitted the expected show_snack_bar host request"
;;

let respond_to_snack_bar handle request close_reason =
  let payload = Bytes.make 1 (Char.chr close_reason) in
  Test.Handle.present handle;
  Test.Handle.respond_to_host_effect handle ~request_id:request.request_id payload;
  Test.Handle.present handle
;;

type timeline_props_record =
  { total_count : int
  ; first_index : int
  ; default_item_extent : float
  ; extent_overrides : Ui.Widget.Sparse_extent_override.t list
  ; overscan : int
  ; transition : Ui.Widget.Sparse_extent_transition.t option
  }

let timeline_list_widget handle = (node_by_test_id handle "journal-timeline-list").widget

let require_timeline_end_padding handle expected =
  let (Av view) =
    Ui.Widget.Private.view (node_by_test_id handle "journal-timeline").widget
  in
  match view.node with
  | Ui.Widget.Private.Sliver_padding { left; top; right; bottom } ->
    require
      (Float.equal left 0.
       && Float.equal top 0.
       && Float.equal right 0.
       && Float.equal bottom expected)
      "timeline end padding is %.1f, expected %.1f"
      bottom
      expected
  | _ -> fail "populated journal timeline has no scroll-content end padding"
;;

let timeline_props handle =
  let (Av view) = Ui.Widget.Private.view (timeline_list_widget handle) in
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
  let (Av view) = Ui.Widget.Private.view (timeline_list_widget handle) in
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

let capture_affordance_props handle =
  let (Av view) =
    Ui.Widget.Private.view (node_by_test_id handle "journal-capture-expandable").widget
  in
  match view.node with
  | Ui.Widget.Private.Native_widget { kind_id; payload; _ } ->
    require
      (kind_id = Ui.Native_widget.Expandable_message_composer.kind_id)
      "Capture affordance uses the wrong native widget kind";
    Ui.Native_widget.Expandable_message_composer.For_testing.decode_props_exn payload
  | _ -> fail "journal-capture-expandable is not an Expandable_message_composer"
;;

let send_capture_affordance_button handle ~button_id ~text =
  let payload = Bytes.make (4 + String.length text) '\000' in
  Bytes.set_int32_le payload 0 (Int32.of_int button_id);
  Bytes.blit_string text 0 payload 4 (String.length text);
  Test.Handle.present handle;
  Test.Handle.native_event
    handle
    (Test.Query.test_id "journal-capture-expandable")
    ~kind_id:Ui.Native_widget.Expandable_message_composer.kind_id
    ~version:1
    ~event_id:Ui.Native_widget.Expandable_message_composer.button_pressed_event_id
    ~payload;
  Test.Handle.present handle
;;

let send_visible_range handle ~first_index ~last_exclusive =
  Test.Handle.present handle;
  Test.Handle.visible_range
    handle
    (Test.Query.test_id "journal-timeline-list")
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

let require_not_colored_decoration handle test_id =
  let (Av view) = Ui.Widget.Private.view (node_by_test_id handle test_id).widget in
  match view.node with
  | Ui.Widget.Private.Decorated_box { background = Some _; _ } ->
    fail "%s still repaints a fixed surface" test_id
  | _ -> ()
;;

let require_material_divider handle test_id =
  let (Av view) = Ui.Widget.Private.view (node_by_test_id handle test_id).widget in
  match view.node with
  | Ui.Widget.Private.Material_divider _ -> ()
  | _ -> fail "%s is not a Material Divider" test_id
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

let require_capture_affordance_floating_action_button handle =
  let affordance = node_by_test_id handle "journal-capture-expandable" in
  (match affordance.parent_data with
   | Ui.Widget.Private.No_parent_data -> ()
   | Flex_parent_data _ | Stack_position _ ->
     fail "Capture affordance carries overlay or flex parent data");
  match Test.Handle.find_all handle (Test.Query.kind "Material_scaffold") with
  | [ scaffold ] ->
    let (Av view) = Ui.Widget.Private.view scaffold.widget in
    (match view.node with
     | Ui.Widget.Private.Material_scaffold
         { has_floating_action_button = true
         ; floating_action_button_location = End_float
         ; has_bottom_navigation_bar = false
         ; has_bottom_sheet = false
         ; _
         } -> ()
     | Material_scaffold _ ->
       fail "journal Scaffold does not exclusively own Capture as an end-floating FAB"
     | _ -> assert false)
  | [] -> fail "journal view has no Material scaffold"
  | scaffolds -> fail "journal view has %d Material scaffolds" (List.length scaffolds)
;;

let require_theme_owned_text_style handle test_id ~size ~line_height ~weight =
  let (Av view) = Ui.Widget.Private.view (node_by_test_id handle test_id).widget in
  match view.node with
  | Ui.Widget.Private.Text { style = Some style; _ } ->
    require
      (style.font_size = Some size
       && style.line_height = Some line_height
       && style.font_weight = Some weight
       && Option.is_none style.color)
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

type app_bar_props_record =
  { pinned : bool
  ; expanded_height : float option
  ; collapsed_height : float option
  ; floating : bool
  ; snap : bool
  ; stretch : bool
  ; toolbar_height : float
  ; has_leading : bool
  ; has_flexible_space : bool
  ; has_bottom : bool
  ; has_actions : bool
  ; force_elevated : bool
  ; automatically_imply_leading : bool
  ; center_title : bool option
  ; background_color : int32 option
  ; foreground_color : int32 option
  ; elevation : float option
  }

let app_bar_props handle =
  let (Av view) = Ui.Widget.Private.view (node_by_test_id handle "journal-header").widget in
  match view.node with
  | Ui.Widget.Private.Sliver_app_bar props ->
    { pinned = props.pinned
    ; expanded_height = props.expanded_height
    ; collapsed_height = props.collapsed_height
    ; floating = props.floating
    ; snap = props.snap
    ; stretch = props.stretch
    ; toolbar_height = props.toolbar_height
    ; has_leading = props.has_leading
    ; has_flexible_space = props.has_flexible_space
    ; has_bottom = props.has_bottom
    ; has_actions = props.has_actions
    ; force_elevated = props.force_elevated
    ; automatically_imply_leading = props.automatically_imply_leading
    ; center_title = props.center_title
    ; background_color = props.background_color
    ; foreground_color = props.foreground_color
    ; elevation = props.elevation
    }
  | _ -> fail "journal header is not a Sliver_app_bar"
;;

let require_journal_scroll handle ~expanded_height ~collapsed_height =
  let (Av scroll) = Ui.Widget.Private.view (node_by_test_id handle "journal-scroll").widget in
  (match scroll.node with
   | Ui.Widget.Private.Scroll_view { axis = Ui.Layout.Axis.Vertical; _ } -> ()
   | _ -> fail "Journal root is not one vertical Scroll_view");
  require
    (Array.length scroll.children = 2)
    "Journal scroll has %d slivers, expected app bar plus content"
    (Array.length scroll.children);
  require
    (Ui.Widget.For_testing.test_id scroll.children.(0).widget
     = Some (Ui.Test_id.string "journal-header"))
    "Journal app bar is not the first scroll sliver";
  require
    (Ui.Widget.For_testing.test_id scroll.children.(1).widget
     = Some (Ui.Test_id.string "journal-timeline"))
    "Journal content is not the second scroll sliver";
  let props = app_bar_props handle in
  require
    (props.pinned
     && not props.floating
     && not props.snap
     && not props.stretch
     && not props.force_elevated
     && not props.automatically_imply_leading
     && props.center_title = Some true)
    "Journal app bar behavior flags changed";
  let close expected = function
    | Some actual -> Float.abs (actual -. expected) < 0.001
    | None -> false
  in
  require
    (close expanded_height props.expanded_height
     && close collapsed_height props.collapsed_height
     && Float.abs (props.toolbar_height -. (collapsed_height -. (1. /. 3.))) < 0.001)
    "Journal app bar extents differ: expanded=%s collapsed=%s toolbar=%.1f"
    (Option.fold ~none:"none" ~some:string_of_float props.expanded_height)
    (Option.fold ~none:"none" ~some:string_of_float props.collapsed_height)
    props.toolbar_height;
  require
    (props.has_leading
     && props.has_flexible_space
     && not props.has_bottom
     && props.has_actions)
    "Journal app bar slot ownership changed";
  require
    (props.background_color = None
     && props.foreground_color = None
     && props.elevation = Some 0.)
    "Journal app bar stopped inheriting theme presentation";
  require_sized_size handle "journal-header-leading-placeholder" ~width:44. ~height:44.;
  require_sized_size handle "journal-header-account-placeholder" ~width:44. ~height:44.
;;

let test_graph_open_error_retains_the_journal_scroll_contract () =
  Adapter_fixture.with_snapshot (fun fixture ->
    let token =
      Graph.Uuid.of_string "ffffffff-ffff-4fff-8fff-ffffffffffff" |> Result.get_ok
    in
    let startup =
      { fixture.Adapter_fixture.config with
        target = Logseq_db_worker.Config.Snapshot { token }
      }
    in
    let handle = create_handle startup in
    Fun.protect
      ~finally:(fun () -> Test.Handle.shutdown handle)
      (fun () ->
         set_environment handle (environment ());
         pump_until handle "graph-open error" (fun () ->
           Option.is_some
             (Test.Handle.find handle (Test.Query.test_id "logseq-graph-open-failed")));
         require_journal_scroll
           handle
           ~expanded_height:(96. +. (1. /. 3.))
           ~collapsed_height:(56. +. (1. /. 3.))))
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

let test_application_owns_one_system_material_theme () =
  with_startup (fun startup ->
    let handle = create_raw_handle startup in
    Fun.protect
      ~finally:(fun () -> Test.Handle.shutdown handle)
      (fun () ->
         let title, theme = application_theme_from_initial_frame handle in
         require (title = Some "Logseq Journal") "application title changed";
         require
           (theme.mode = Protocol.Wire_frame.System)
           "application theme is not System";
         let require_data name brightness contrast_level data =
           require
             (data.Protocol.Wire_frame.brightness = brightness)
             "%s brightness differs"
             name;
           require
             (Int32.equal data.color_scheme.seed_argb 0xff00262fl)
             "%s does not use the one accepted seed"
             name;
           require
             (data.color_scheme.variant = Protocol.Wire_frame.Tonal_spot)
             "%s dynamic variant differs"
             name;
           require
             (Float.equal data.color_scheme.contrast_level contrast_level)
             "%s contrast level differs"
             name
         in
         require_data "light" Protocol.Wire_frame.Light 0. theme.light;
         require_data "dark" Protocol.Wire_frame.Dark 0. theme.dark;
         (match theme.high_contrast_light with
          | Some data ->
            require_data "high-contrast light" Protocol.Wire_frame.Light 1. data
          | None -> fail "application omitted high-contrast light theme data");
         match theme.high_contrast_dark with
         | Some data -> require_data "high-contrast dark" Protocol.Wire_frame.Dark 1. data
         | None -> fail "application omitted high-contrast dark theme data"))
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
         require_test_id handle "journal-capture-expandable";
         require_no_test_id handle "journal-capture-composer";
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
         require_no_test_id handle "journal-bottom-clearance";
         require_no_test_id handle "journal-capture";
         require_no_visible_text handle "Search";
         require_no_visible_text handle "Search journal";
         require_no_visible_text handle "Search journal entries";
         require_no_visible_text handle "Preview";
         require_no_visible_text handle "Attachment";
         require_no_visible_text handle "Thumbnail";
         require_no_visible_text handle "Styled token"))
;;

let test_capture_fab_directly_saves_one_plain_top_level_block () =
  with_startup (fun startup ->
    let handle = create_handle startup in
    Fun.protect
      ~finally:(fun () -> Test.Handle.shutdown handle)
      (fun () ->
         pump_until_text handle "No journal entries yet";
         let props = capture_affordance_props handle in
         require props.enabled "Capture FAB is disabled after graph startup";
         require (String.equal props.fab_label "Capture") "Capture FAB label changed";
         require
           (String.equal props.fab_tooltip "Open Capture")
           "Capture FAB tooltip changed";
         require
           (props.animation_duration_ms = 180)
           "Capture expansion duration differs from the application motion token";
         require
           (props.animation_curve = Ui.Animation.Curve.Ease_out)
           "Capture expansion curve changed";
         require (props.max_lines = 5) "Capture input max-lines policy changed";
         require
           (String.equal props.hint_text "Capture a thought")
           "Capture input hint changed";
         (match props.buttons with
          | [ save ] ->
            require (save.id = 1) "Capture Save button ID changed";
            require
              (String.equal save.tooltip "Save journal block")
              "Capture Save accessible label changed";
            require
              (save.position = Ui.Native_widget.Expandable_message_composer.Trailing
               && save.visibility = When_non_empty
               && save.style = Filled
               && save.enabled)
              "Capture Save button policy changed"
          | _ -> fail "Capture input must expose exactly one Save action");
         require_capture_affordance_floating_action_button handle;
         require_test_id handle "journal-capture-fab-icon";
         require_material_icon handle "journal-capture-fab-icon" 0xe047;
         require_no_test_id handle "journal-capture-composer-plus";
         require_test_id handle "journal-capture-composer-submit";
         require_material_icon handle "journal-capture-composer-submit" 0xe0a0;
         require_no_test_id handle "journal-capture-target";
         require_no_test_id handle "journal-capture-feedback";
         send_capture_affordance_button handle ~button_id:1 ~text:"   \n";
         require_no_test_id handle "journal-capture-sheet";
         require_no_visible_text handle "   \n";
         let source = "Composer 中文 👩🏽‍💻 literal" in
         send_capture_affordance_button handle ~button_id:1 ~text:source;
         let saving_props = capture_affordance_props handle in
         require
           (not saving_props.enabled)
           "direct Capture did not disable its editor while Saving";
         (match saving_props.buttons with
          | [ save ] ->
            require (not save.enabled) "direct Capture did not enter Saving";
            require
              (String.equal save.tooltip "Saving journal block")
              "direct Capture did not expose its accessible Saving state"
          | _ -> fail "Capture action count changed while Saving");
         pump_until_text handle source;
         require_no_test_id handle "journal-capture-sheet";
         require_no_visible_text handle "New block";
         require
           (List.length (Test.Handle.find_all handle (Test.Query.visible_text source)) = 1)
           "direct Capture did not persist the exact source exactly once";
         let props = capture_affordance_props handle in
         require props.enabled "Capture FAB did not recover after persistence";
         match props.buttons with
         | [ save ] -> require save.enabled "Capture Save stayed disabled after success"
         | _ -> fail "Capture action count changed after success"))
;;

let test_capture_fab_honors_reduced_motion_without_changing_its_slot () =
  with_startup (fun startup ->
    let handle = create_handle startup in
    Fun.protect
      ~finally:(fun () -> Test.Handle.shutdown handle)
      (fun () ->
         set_environment handle (environment ~reduced_motion:true ());
         pump_until_text handle "No journal entries yet";
         let props = capture_affordance_props handle in
         require
           (props.animation_duration_ms = 0)
           "reduced motion kept a nonzero Capture expansion duration";
         require
           (props.animation_curve = Ui.Animation.Curve.Ease_out)
           "reduced motion changed the Capture curve rather than its duration";
         require_capture_affordance_floating_action_button handle;
         require_no_test_id handle "journal-bottom-clearance"))
;;

let test_header_uses_pinned_theme_owned_sliver_app_bar () =
  with_startup (fun startup ->
    let handle = create_handle startup in
    Fun.protect
      ~finally:(fun () -> Test.Handle.shutdown handle)
      (fun () ->
         set_environment handle (environment ());
         pump_until_text handle "No journal entries yet";
         require_not_colored_decoration handle "journal-root-surface";
         require_journal_scroll
           handle
           ~expanded_height:(96. +. (1. /. 3.))
           ~collapsed_height:(56. +. (1. /. 3.));
         require_no_test_id handle "journal-header-surface";
         require_no_test_id handle "journal-header-safe-area";
         require_no_test_id handle "journal-header-stack";
         require_no_test_id handle "journal-header-handle";
         require_no_test_id handle "journal-more-surface";
         require_material_divider handle "journal-header-divider";
         require_no_test_id handle "journal-header-divider-extent";
         require_theme_owned_text_style
           handle
           "journal-header-title"
           ~size:22.
           ~line_height:(28. /. 22.)
           ~weight:Ui.Style.Font_weight.Bold;
         require_theme_owned_text_style
           handle
           "journal-header-subtitle"
           ~size:15.
           ~line_height:(20. /. 15.)
           ~weight:Ui.Style.Font_weight.Medium;
         require_no_semantics handle "Menu";
         require_no_semantics handle "More";
         require_test_id handle "journal-header-leading-placeholder";
         require_test_id handle "journal-header-account-placeholder";
         require_no_test_id handle "journal-menu-target";
         require_no_test_id handle "journal-more-target";
         require_no_test_id handle "journal-capture-composer-safe-area";
         require_capture_affordance_floating_action_button handle;
         require_test_id handle "journal-capture-fab-icon";
         require_no_test_id handle "journal-capture-composer-plus";
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
         require_journal_scroll
           handle
           ~expanded_height:(96. +. (1. /. 3.))
           ~collapsed_height:(56. +. (1. /. 3.));
         require_no_semantics handle "Menu";
         require_no_semantics handle "More";
         set_environment handle (environment ~viewport_width:1_200. ~platform:"macos" ());
         pump_worker handle;
         require_journal_scroll
           handle
           ~expanded_height:(96. +. (1. /. 3.))
           ~collapsed_height:(56. +. (1. /. 3.));
         require_no_semantics handle "Menu";
         require_no_semantics handle "More";
         require_no_visible_text handle "Search";
         set_environment handle (environment ~locale:"ar_SA" ());
         pump_worker handle;
         require_journal_scroll
           handle
           ~expanded_height:(96. +. (1. /. 3.))
           ~collapsed_height:(56. +. (1. /. 3.));
         set_environment handle (environment ~text_scale:3.2 ());
         pump_worker handle;
         require_journal_scroll
           handle
           ~expanded_height:(177.6 +. (1. /. 3.))
           ~collapsed_height:(105.6 +. (1. /. 3.));
         require_capture_affordance_floating_action_button handle))
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

let test_header_inherits_theme_colors_in_dark_and_high_contrast_appearance () =
  with_startup (fun startup ->
    let handle = create_handle startup in
    Fun.protect
      ~finally:(fun () -> Test.Handle.shutdown handle)
      (fun () ->
         set_environment handle (environment ~brightness:Environment.Dark ());
         pump_until_text handle "No journal entries yet";
         require_not_colored_decoration handle "journal-root-surface";
         require_journal_scroll
           handle
           ~expanded_height:(96. +. (1. /. 3.))
           ~collapsed_height:(56. +. (1. /. 3.));
         require_theme_owned_text_style
           handle
           "journal-header-title"
           ~size:22.
           ~line_height:(28. /. 22.)
           ~weight:Ui.Style.Font_weight.Bold;
         set_environment
           handle
           (environment ~brightness:Environment.Dark ~high_contrast:true ());
         pump_worker handle;
         require_not_colored_decoration handle "journal-root-surface";
         require_journal_scroll
           handle
           ~expanded_height:(96. +. (1. /. 3.))
           ~collapsed_height:(56. +. (1. /. 3.));
         require_theme_owned_text_style
           handle
           "journal-header-title"
           ~size:22.
           ~line_height:(28. /. 22.)
           ~weight:Ui.Style.Font_weight.Bold))
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
         require_journal_scroll
           handle
           ~expanded_height:(96. +. (1. /. 3.))
           ~collapsed_height:(56. +. (1. /. 3.));
         require_timeline_end_padding handle 98.;
         require_no_visible_text handle "Paged journal row 70";
         let props = timeline_props handle in
         require
           (props.total_count = 65)
           "initial feed count is %d, expected 65"
           props.total_count;
         require (props.first_index = 0) "initial timeline does not start at zero";
         require
           (Float.equal props.default_item_extent 44.)
           "timeline default extent is %.1f, expected 44"
           props.default_item_extent;
         require (props.overscan = 4) "timeline overscan is %d, expected 4" props.overscan;
         let supplied_count = List.length (timeline_item_keys handle) in
         require
           (supplied_count <= Journal_timeline_state.maximum_supplied_rows)
           "timeline supplied %d rows"
           supplied_count;
         require
           (not
              (List.exists
                 (fun (override : Ui.Widget.Sparse_extent_override.t) ->
                    override.index >= props.total_count)
                 props.extent_overrides))
           "timeline retained an extent override beyond its real content";
         send_visible_range handle ~first_index:58 ~last_exclusive:65;
         pump_until_text handle "Paged journal row 70";
         require_no_visible_text handle "Paged journal row 01";
         let paged = timeline_props handle in
         require (paged.total_count = 70) "paged timeline count is %d" paged.total_count;
         let paged_supplied_count = List.length (timeline_item_keys handle) in
         require
           (paged_supplied_count <= Journal_timeline_state.maximum_supplied_rows)
           "paged timeline supplied %d rows"
           paged_supplied_count))
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
           (initial.total_count = 9)
           "multi-continuation feed has %d slots, expected 9"
           initial.total_count;
         send_visible_range handle ~first_index:0 ~last_exclusive:9;
         pump_until handle "all initial visible continuation requests" (fun () ->
           (timeline_props handle).total_count = 137);
         require_no_test_id handle "journal-day-continuation:20260807";
         require
           ((timeline_props handle).total_count = 137)
           "one visible range event did not drain both continuation pages"))
;;

let test_timeline_does_not_repeat_group_dividers () =
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
              require_no_test_id handle ("journal-group-divider:" ^ leaf.block_id))
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
      send_capture_affordance_button handle ~button_id:1 ~text:source;
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
           (initial.total_count = 64)
           "queued expansion fixture has %d slots, expected 64"
           initial.total_count;
         send_visible_range handle ~first_index:30 ~last_exclusive:64;
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
         let stale_binding = capture_native_binding handle "journal-timeline-list" in
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
              require_material_icon
                handle
                ("journal-child-bullet:" ^ child.block_id)
                0xe163;
              require_no_test_id handle ("journal-row-slidable:" ^ child.block_id);
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

let test_delete_action_stages_undoes_and_commits_only_after_deadline () =
  with_startup (fun startup ->
    let command = capture 110 "Undoable delete row" in
    seed startup [ command ];
    let handle, monotonic_now_ns = create_timed_handle startup in
    Fun.protect
      ~finally:(fun () -> Test.Handle.shutdown handle)
      (fun () ->
         set_environment handle (environment ~safe_area_bottom:34. ());
         pump_until_text handle command.source;
         require_test_id handle ("journal-row-slidable:" ^ command.block_id);
         emit_unexpected_end_dismissal handle command.block_id;
         require_visible_text handle command.source;
         require
           (Test.Handle.pending_host_effect_count handle = 0)
           "unexpected Slidable dismissal staged deletion";
         press_delete_action handle command.block_id;
         require_no_visible_text handle command.source;
         pump_until handle "native deletion snackbar" (fun () ->
           Test.Handle.pending_host_effect_count handle = 1);
         let request = snack_bar_request_from_last_frame handle in
         require
           (String.equal request.message "Block and descendants removed")
           "delete snackbar message changed";
         require (request.action_label = Some "Undo") "delete snackbar action changed";
         require (request.duration_ms = 5_000) "delete snackbar duration changed";
         require_no_test_id handle "journal-delete-snackbar";
         for _ = 1 to 16 do
           pump_worker handle
         done;
         require
           (Test.Handle.pending_host_effect_count handle = 1)
           "ordinary recomputation replayed or cancelled the snackbar";
         respond_to_snack_bar handle request 0;
         pump_until_text handle command.source;
         require
           (Test.Handle.pending_host_effect_count handle = 0)
           "Undo left a pending snackbar host effect";
         advance_clock handle monotonic_now_ns 1.;
         require_visible_text handle command.source));
  with_startup (fun startup ->
    let command = capture 111 "Committed delete row" in
    seed startup [ command ];
    let handle, monotonic_now_ns = create_timed_handle startup in
    pump_until_text handle command.source;
    press_delete_action handle command.block_id;
    require_no_visible_text handle command.source;
    pump_until handle "native commit snackbar" (fun () ->
      Test.Handle.pending_host_effect_count handle = 1);
    let request = snack_bar_request_from_last_frame handle in
    respond_to_snack_bar handle request 5;
    advance_clock handle monotonic_now_ns 5.;
    for _ = 1 to 64 do
      pump_worker handle
    done;
    require
      (Test.Handle.pending_host_effect_count handle = 0)
      "timeout close reason retained or replayed Undo";
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

let test_non_action_snackbar_close_reasons_never_undo () =
  List.iter
    (fun close_reason ->
       with_startup (fun startup ->
         let command =
           capture
             (120 + close_reason)
             (Printf.sprintf "Non-action close reason %d" close_reason)
         in
         seed startup [ command ];
         let handle = create_handle startup in
         Fun.protect
           ~finally:(fun () -> Test.Handle.shutdown handle)
           (fun () ->
              pump_until_text handle command.source;
              press_delete_action handle command.block_id;
              pump_until handle "native deletion snackbar" (fun () ->
                Test.Handle.pending_host_effect_count handle = 1);
              let request = snack_bar_request_from_last_frame handle in
              respond_to_snack_bar handle request close_reason;
              require_no_visible_text handle command.source;
              require
                (Test.Handle.pending_host_effect_count handle = 0)
                "close reason %d retained the snackbar"
                close_reason;
              for _ = 1 to 8 do
                pump_worker handle
              done;
              require_no_visible_text handle command.source)))
    [ 1; 2; 3; 4; 5 ]
;;

let test_delete_action_accessibility_duration_and_single_mutation_gate () =
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
         press_delete_action handle first.block_id;
         pump_until handle "accessible deletion snackbar" (fun () ->
           Test.Handle.pending_host_effect_count handle = 1);
         let request = snack_bar_request_from_last_frame handle in
         require
           (request.duration_ms = 10_000)
           "accessible snackbar did not use the bounded Undo lifetime";
         require_no_test_id handle ("journal-row-slidable:" ^ second.block_id);
         require_no_semantics handle "Delete block and all descendants";
         advance_clock handle monotonic_now_ns 5.;
         require
           (Test.Handle.pending_host_effect_count handle = 1)
           "accessible snackbar ended before the Undo deadline";
         advance_clock handle monotonic_now_ns 5.;
         pump_until handle "accessible delete deadline" (fun () ->
           Test.Handle.pending_host_effect_count handle = 0)))
;;

let () =
  test_application_owns_one_system_material_theme ();
  test_initial_feed_has_a_truthful_loading_state ();
  test_graph_open_error_retains_the_journal_scroll_contract ();
  test_timeline_content_is_capped_and_centered ();
  test_root_is_owned_by_the_ocaml_timeline ();
  test_capture_fab_directly_saves_one_plain_top_level_block ();
  test_capture_fab_honors_reduced_motion_without_changing_its_slot ();
  test_header_uses_pinned_theme_owned_sliver_app_bar ();
  test_header_adapts_without_exposing_deferred_actions ();
  test_header_inherits_theme_colors_in_dark_and_high_contrast_appearance ();
  test_timeline_uses_exact_sparse_extent_window ();
  test_timeline_preserves_stable_slot_keys_across_window_shifts ();
  test_one_visible_range_drains_multiple_day_continuations ();
  test_pending_day_response_drains_expanded_parent_without_renderer_input ();
  test_timeline_does_not_repeat_group_dividers ();
  test_timeline_uses_truthful_fallback_labels_without_duplicate_today ();
  test_timeline_deemphasizes_repeated_and_historical_timestamps ();
  test_timeline_projects_creation_time_across_a_negative_offset_day_boundary ();
  test_virtualized_timeline_does_not_repeat_time_at_window_boundary ();
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
  test_delete_action_stages_undoes_and_commits_only_after_deadline ();
  test_non_action_snackbar_close_reasons_never_undo ();
  test_delete_action_accessibility_duration_and_single_mutation_gate ()
;;
