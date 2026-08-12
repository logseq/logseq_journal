module ID = Bonsai_flutter_spec.Id
module Environment = Bonsai_flutter.Environment
module Protocol = Bonsai_flutter_protocol
module Runtime = Bonsai_flutter_runtime
module Test = Bonsai_flutter_test
module Ui = Bonsai_flutter_ui

let fail format = Printf.ksprintf failwith format

let require condition format =
  Printf.ksprintf (fun message -> if not condition then failwith message) format
;;

let rec remove_tree path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Sys.readdir path |> Array.iter (fun name -> remove_tree (Filename.concat path name));
    Unix.rmdir path
  | _ -> Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
;;

let with_startup test =
  let root = Filename.temp_file "journal-timeline-view-" "" in
  Sys.remove root;
  Unix.mkdir root 0o700;
  Unix.mkdir (Filename.concat root "logseq_journal") 0o700;
  let startup : Journal_startup.t =
    { application_support_root = Unix.realpath root
    ; expected_schema_version = Journal_schema.version
    ; initial_calendar =
        { instant_unix_ms = 1_786_259_700_000L
        ; local_day = 20260809
        ; local_minute_of_day = 915
        ; locale = "en_US"
        ; time_zone_id = "Asia/Shanghai"
        ; utc_offset_seconds = 28_800
        ; generation = 1L
        ; lifecycle_generation = 0L
        }
    ; access_mode = Read_write
    ; diagnostic_mode = Operational_only
    }
  in
  Fun.protect ~finally:(fun () -> remove_tree root) (fun () -> test startup)
;;

let encode_startup startup =
  match Journal_startup.encode startup with
  | Ok bytes -> bytes
  | Error error ->
    fail "startup encode failed: %s" (Journal_startup.Error.to_string error)
;;

let create_handle startup =
  let time_source = Bonsai.Time_source.create ~start:Core.Time_ns.epoch in
  Test.Handle.create_app
    ~runtime_epoch:(ID.Runtime.Epoch.of_int64 9_001L)
    ~time_source
    Application.app
    ~application_payload:(encode_startup startup)
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
  handle, ref 0L
;;

let advance_clock handle monotonic_now_ns seconds =
  Test.Handle.present handle;
  monotonic_now_ns
  := Int64.add !monotonic_now_ns (Int64.of_float (seconds *. 1_000_000_000.));
  ignore (Test.Handle.pump handle ~monotonic_now_ns:!monotonic_now_ns ());
  Test.Handle.presentation_succeeded handle ~monotonic_now_ns:!monotonic_now_ns
;;

let database_path startup =
  match
    Journal_storage_path.resolve
      ~support_root:startup.Journal_startup.application_support_root
      ~relative_path:Journal_startup.database_relative_path
  with
  | Ok path -> path
  | Error error ->
    fail
      "database path resolution failed: %s"
      (Journal_storage_path.Error.to_string error)
;;

let open_store startup =
  match Journal_storage.open_store ~canonical_path:(database_path startup) with
  | Ok (store, _) -> store
  | Error error -> fail "store open failed: %s" (Journal_storage.Error.to_string error)
;;

let close_store store =
  match Journal_storage.close store with
  | Ok () -> ()
  | Error error -> fail "store close failed: %s" (Journal_storage.Error.to_string error)
;;

let fixture_time day index =
  let midnight =
    match day with
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

let capture ?(day = 20260809) ?(task_state = Journal_model.Not_a_task) index source
  : Journal_repository.capture
  =
  { mutation_id = Printf.sprintf "70000000-0000-4000-9000-%012d" index
  ; block_id = Printf.sprintf "70000000-0000-4000-a000-%012d" index
  ; sibling_order = Printf.sprintf "%012d" index
  ; source
  ; task_state
  ; creation_time = fixture_time day (index mod 1_440)
  }
;;

let seed startup captures =
  let store = open_store startup in
  Fun.protect
    ~finally:(fun () -> close_store store)
    (fun () ->
       List.iter
         (fun command ->
            match
              Journal_repository.prepare_capture
                (Journal_storage.current_db store)
                command
            with
            | Error error ->
              fail "capture prepare failed: %s" (Journal_repository.Error.to_string error)
            | Ok (Journal_repository.Already_applied _) ->
              fail "fresh capture fixture was already applied"
            | Ok (Journal_repository.Apply transaction) ->
              (match Journal_storage.transact store transaction with
               | Ok _ -> ()
               | Error error ->
                 fail
                   "capture transact failed: %s"
                   (Journal_storage.Error.to_string error)))
         captures)
;;

let seed_child startup ~(parent : Journal_repository.capture) index source =
  let store = open_store startup in
  Fun.protect
    ~finally:(fun () -> close_store store)
    (fun () ->
       let db = Journal_storage.current_db store in
       let parent_block =
         match Journal_repository.find_block db ~id:parent.block_id with
         | Ok (Some block) -> block
         | Ok None -> fail "seed parent does not exist"
         | Error error ->
           fail "seed parent lookup failed: %s" (Journal_repository.Error.to_string error)
       in
       let command : Journal_repository.create_child =
         { mutation_id = Printf.sprintf "71000000-0000-4000-9000-%012d" index
         ; block_id = Printf.sprintf "71000000-0000-4000-a000-%012d" index
         ; parent_block_id = parent.block_id
         ; expected_parent_revision = Journal_model.revision parent_block
         ; sibling_order = Printf.sprintf "%012d" index
         ; source
         ; task_state = Journal_model.Not_a_task
         ; creation_time = fixture_time 20260809 (index mod 1_440)
         }
       in
       match Journal_repository.prepare_create_child db command with
       | Error error ->
         fail "child prepare failed: %s" (Journal_repository.Error.to_string error)
       | Ok (Journal_repository.Child_already_applied _) ->
         fail "fresh child fixture was already applied"
       | Ok (Journal_repository.Create_child transaction) ->
         (match Journal_storage.transact store transaction with
          | Ok _ -> command
          | Error error ->
            fail "child transact failed: %s" (Journal_storage.Error.to_string error)))
;;

let pump_worker handle =
  Test.Handle.present handle;
  Test.Handle.pump_next handle ()
;;

let environment
      ?(viewport_width = 390.)
      ?(viewport_height = 844.)
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
  ; device_pixel_ratio = 3.
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
    match node.props with
    | Ui.Widget.Private.Native_widget_props { kind_id; _ } -> kind_id
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
  | [ { props = Ui.Widget.Private.Semantics_props { role; live_region; heading_level; _ }
      ; _
      }
    ] -> check { role; live_region; heading_level }
  | [ _ ] -> fail "%S is not Semantics" label
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
  match (node_by_test_id handle test_id).props with
  | Ui.Widget.Private.Text_input_props { value; _ } -> value
  | _ -> fail "%s is not a Material text field" test_id
;;

let timeline_props handle =
  match (node_by_test_id handle "journal-timeline").props with
  | Ui.Widget.Private.Native_widget_props { kind_id; payload; _ } ->
    require
      (kind_id = Ui.Native_widget.Sparse_extent_list.kind_id)
      "journal timeline uses the wrong native widget kind";
    Ui.Native_widget.Sparse_extent_list.For_testing.decode_props_exn payload
  | _ -> fail "journal timeline is not a Sparse_extent_list"
;;

let send_visible_range handle ~first_index ~last_exclusive =
  Test.Handle.present handle;
  Test.Handle.native_event
    handle
    (Test.Query.test_id "journal-timeline")
    ~kind_id:Ui.Native_widget.Sparse_extent_list.kind_id
    ~version:1
    ~event_id:Ui.Native_widget.Sparse_extent_list.visible_range_event_id
    ~payload:
      (Ui.Native_widget.Sparse_extent_list.For_testing.encode_visible_range
         ~first_index
         ~last_exclusive)
;;

let require_decoration handle test_id expected =
  match (node_by_test_id handle test_id).props with
  | Ui.Widget.Private.Decorated_box_props { background = Some actual; _ } ->
    require
      (Int32.equal actual expected)
      "%s background expected 0x%lx, got 0x%lx"
      test_id
      expected
      actual
  | _ -> fail "%s is not a colored DecoratedBox" test_id
;;

let require_decoration_shape handle test_id ~background ~border_radius =
  match (node_by_test_id handle test_id).props with
  | Ui.Widget.Private.Decorated_box_props
      { background = Some actual_background; border_radius = actual_radius } ->
    require
      (Int32.equal actual_background background && Float.equal actual_radius border_radius)
      "%s decoration expected 0x%lx/r%.1f, got 0x%lx/r%.1f"
      test_id
      background
      border_radius
      actual_background
      actual_radius
  | _ -> fail "%s is not a colored DecoratedBox" test_id
;;

let require_decoration_without_shape handle test_id ~background =
  match (node_by_test_id handle test_id).props with
  | Ui.Widget.Private.Decorated_box_props
      { background = Some actual_background; border_radius } ->
    require
      (Int32.equal actual_background background && Float.equal border_radius 0.)
      "%s must leave outer sheet shape to the Flutter modal route"
      test_id
  | _ -> fail "%s is not a colored DecoratedBox" test_id
;;

let require_icon ?size handle test_id ~code_point ~color =
  match (node_by_test_id handle test_id).props with
  | Ui.Widget.Private.Icon_props
      { code_point = actual_code_point
      ; font_family = Some "MaterialIcons"
      ; size = actual_size
      ; color = Some actual_color
      } ->
    require
      (actual_code_point = code_point
       && Int32.equal actual_color color
       &&
       match size with
       | None -> true
       | Some expected -> actual_size = Some expected)
      "%s icon differs"
      test_id
  | _ -> fail "%s is not a Material icon" test_id
;;

let require_sized_height handle test_id expected =
  match (node_by_test_id handle test_id).props with
  | Ui.Widget.Private.Sized_box_props { height = Some actual; _ } ->
    require (Float.equal actual expected) "%s height is %.3f" test_id actual
  | _ -> fail "%s is not a height-constrained SizedBox" test_id
;;

let require_sized_size handle test_id ~width ~height =
  match (node_by_test_id handle test_id).props with
  | Ui.Widget.Private.Sized_box_props
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

let require_pressable handle test_id ~release_delay_ms =
  match (node_by_test_id handle test_id).props with
  | Ui.Widget.Private.Pressable_props { overlay_color; release_delay_ms = actual } ->
    require
      (Int32.equal (Ui.Style.Color.Private.to_argb32 overlay_color) 0x00000000l
       && actual = release_delay_ms)
      "%s pressed feedback differs"
      test_id
  | _ -> fail "%s is not Pressable" test_id
;;

let require_animated_opacity handle test_id ~opacity ~duration_ms ~curve =
  match (node_by_test_id handle test_id).props with
  | Ui.Widget.Private.Animated_opacity_props { opacity = actual_opacity; animation } ->
    require
      (Float.equal actual_opacity opacity)
      "%s opacity is %.2f, expected %.2f"
      test_id
      actual_opacity
      opacity;
    require
      (Ui.Animation.Private.duration_ms animation = duration_ms)
      "%s duration differs"
      test_id;
    require
      (Ui.Animation.Curve.equal (Ui.Animation.Private.curve animation) curve)
      "%s curve differs"
      test_id
  | _ -> fail "%s is not AnimatedOpacity" test_id
;;

let require_stack_position handle test_id ~left ~top =
  match (node_by_test_id handle test_id).parent_data with
  | Ui.Widget.Private.Stack_position position ->
    require
      (Option.equal Float.equal position.left (Some left)
       && Option.equal Float.equal position.top (Some top))
      "%s stack position differs"
      test_id
  | _ -> fail "%s is not a positioned Stack child" test_id
;;

let send_pointer_event handle ~sequence ~ui_tag ~protocol_tag test_id =
  Test.Handle.present handle;
  let node = node_by_test_id handle test_id in
  let binding =
    Array.find_opt
      (fun (binding : Runtime.Mounted_tree.Mounted_binding.t) ->
         Ui.Event.Tag.equal binding.event_tag ui_tag)
      node.event_bindings
    |> function
    | Some binding -> binding
    | None -> fail "%s does not bind %s" test_id (Ui.Event.Tag.to_string ui_tag)
  in
  let event =
    Protocol.Inbound_event.
      { sequence = ID.Runtime.Event_sequence.of_int64 sequence
      ; displayed_revision = Test.Handle.revision handle
      ; node_id = node.node_id
      ; handler_id = binding.handler_id
      ; event_tag = protocol_tag
      ; payload =
          Pointer
            { pointer_id = ID.Input.Pointer_id.of_int64 1L
            ; local_x = 28.
            ; local_y = 28.
            ; global_x = 195.
            ; global_y = 780.
            ; pointer_kind = Touch
            ; buttons = 1
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

let require_button_enabled handle test_id expected =
  match (node_by_test_id handle test_id).props with
  | Ui.Widget.Private.Material_button_props { enabled; _ } ->
    require (Bool.equal enabled expected) "%s enabled state differs" test_id
  | _ -> fail "%s is not a Material button" test_id
;;

let capture_sheet_page_props handle =
  match (node_by_test_id handle "journal-capture-sheet").props with
  | Ui.Widget.Private.Page_props { page_key; presentation; can_pop; restoration_id } ->
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

let require_capture_position handle ~viewport_width =
  let positioned = node_by_test_id handle "journal-capture-safe-area" in
  let content_width = Float.min viewport_width Journal_visual_tokens.timeline_max_width in
  let expected_left =
    (content_width -. Journal_visual_tokens.hit_regions.fab_target) /. 2.
  in
  match positioned.parent_data with
  | Ui.Widget.Private.Stack_position { left; right; top; bottom } ->
    require
      (top = None && bottom = Some 20. && left = Some expected_left && right = None)
      "Capture overlay is not centered across the content viewport"
  | _ -> fail "Capture is not a positioned overlay child"
;;

let require_capture_plus handle =
  require_sized_size handle "journal-capture-plus" ~width:18. ~height:18.;
  require_sized_size handle "journal-capture-plus-horizontal" ~width:18. ~height:1.5;
  require_sized_size handle "journal-capture-plus-vertical" ~width:1.5 ~height:18.;
  require_decoration_shape
    handle
    "journal-capture-plus-horizontal-surface"
    ~background:0xfffcfcfdl
    ~border_radius:0.;
  require_decoration_shape
    handle
    "journal-capture-plus-vertical-surface"
    ~background:0xfffcfcfdl
    ~border_radius:0.
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
  match (node_by_test_id handle test_id).props with
  | Ui.Widget.Private.Text_props { style = Some style; _ } ->
    require
      (style.font_size = Some size
       && style.line_height = Some line_height
       && style.font_weight = Some weight
       && style.color = Some color)
      "%s has unexpected typography"
      test_id
  | _ -> fail "%s is not styled Text" test_id
;;

let require_header_geometry handle =
  (match (node_by_test_id handle "journal-header-safe-area").props with
   | Ui.Widget.Private.Safe_area_props { top; bottom; _ } ->
     require (top && not bottom) "header safe-area edges changed"
   | _ -> fail "journal-header-safe-area is not SafeArea");
  (match (node_by_test_id handle "journal-header-stack").props with
   | Ui.Widget.Private.Stack_props -> ()
   | _ -> fail "journal-header-stack is not Stack");
  require_sized_height handle "journal-header-content-height" 48.;
  (match (node_by_test_id handle "journal-header-center").props with
   | Ui.Widget.Private.Center_props _ -> ()
   | _ -> fail "journal-header-center is not an independent Center");
  (match (node_by_test_id handle "journal-header-padding").props with
   | Ui.Widget.Private.Padding_props { left; right; top; bottom } ->
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
  require_sized_size handle "journal-menu-shell" ~width:44. ~height:44.;
  require_sized_size handle "journal-more-shell" ~width:44. ~height:44.
;;

let require_stack_bottom handle test_id expected =
  match (node_by_test_id handle test_id).parent_data with
  | Ui.Widget.Private.Stack_position { left = _; right = _; top = None; bottom } ->
    require (bottom = Some expected) "%s bottom is not %.1f" test_id expected
  | _ -> fail "%s is not bottom-positioned" test_id
;;

let require_content_width_padding handle ~horizontal =
  match (node_by_test_id handle "journal-content-width-padding").props with
  | Ui.Widget.Private.Padding_props { left; right; top; bottom } ->
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
         require_semantics handle "Capture";
         require_test_id handle "journal-header";
         require_test_id handle "journal-date-context";
         require_test_id handle "journal-menu-shell";
         require_test_id handle "journal-more-shell";
         require_no_test_id handle "journal-menu";
         require_no_test_id handle "journal-menu-target";
         require_no_test_id handle "journal-more";
         require_no_test_id handle "journal-more-target";
         require_no_test_id handle "journal-date-target";
         require_test_id handle "journal-timeline";
         require_test_id handle "journal-capture";
         require_no_visible_text handle "Search";
         require_no_visible_text handle "Search journal";
         require_no_visible_text handle "Search journal entries";
         require_no_visible_text handle "Preview";
         require_no_visible_text handle "Attachment";
         require_no_visible_text handle "Thumbnail";
         require_no_visible_text handle "Styled token"))
;;

let test_capture_is_an_ocaml_contextual_modal_sheet () =
  with_startup (fun startup ->
    let handle = create_handle startup in
    Fun.protect
      ~finally:(fun () -> Test.Handle.shutdown handle)
      (fun () ->
         set_environment handle (environment ());
         pump_until_text handle "No journal entries yet";
         Test.Handle.present handle;
         Test.Handle.click handle (Test.Query.test_id "journal-capture");
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
         (match (node_by_test_id handle "capture-primary-scroll").props with
          | Ui.Widget.Private.Scroll_view_props
              { axis = Ui.Layout.Axis.Vertical; primary = true; reverse = false } -> ()
          | _ -> fail "Capture editor region is not the one primary vertical scrollable");
         (match (node_by_test_id handle "capture-editor").props with
          | Ui.Widget.Private.Text_input_props
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
         click_test_id handle "journal-capture";
         let original = text_field_value handle "capture-editor" in
         let original_session =
           match (node_by_test_id handle "capture-editor").props with
           | Ui.Widget.Private.Text_input_props { session_id; _ } -> session_id
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
         require_visible_text handle "To do";
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
         (match (node_by_test_id handle "capture-editor").props with
          | Ui.Widget.Private.Text_input_props { session_id; _ } ->
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
         require_icon
           ~size:18.
           handle
           "journal-menu-icon"
           ~code_point:0xe3dc
           ~color:0xff0d142fl;
         require_icon
           ~size:18.
           handle
           "journal-more-icon"
           ~code_point:0xe402
           ~color:0xff0d142fl;
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
         require_test_id handle "journal-menu-shell";
         require_test_id handle "journal-more-shell";
         require_no_test_id handle "journal-menu-target";
         require_no_test_id handle "journal-more-target";
         (match (node_by_test_id handle "journal-capture-safe-area").props with
          | Ui.Widget.Private.Safe_area_props { left; top; right; bottom; _ } ->
            require
              ((not left) && (not top) && (not right) && bottom)
              "Capture safe-area edges changed"
          | _ -> fail "journal-capture-safe-area is not SafeArea");
         require_sized_size handle "journal-capture-visual" ~width:48. ~height:48.;
         require_decoration_shape
           handle
           "journal-capture-circle"
           ~background:0xff181e34l
           ~border_radius:24.;
         require_capture_plus handle;
         require_sized_size handle "journal-capture-shadow" ~width:52. ~height:52.;
         require_decoration_shape
           handle
           "journal-capture-shadow-outer"
           ~background:0x120d142fl
           ~border_radius:26.;
         require_no_test_id handle "journal-capture-shadow-inner";
         require_no_test_id handle "journal-capture-elevation";
         require_sized_size handle "journal-capture-target" ~width:56. ~height:56.;
         require_pressable handle "journal-capture" ~release_delay_ms:80;
         require_capture_position handle ~viewport_width:390.;
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
         require_capture_position handle ~viewport_width:390.))
;;

let test_capture_soft_press_has_tactile_down_and_ease_out_release () =
  with_startup (fun startup ->
    let handle = create_handle startup in
    Fun.protect
      ~finally:(fun () -> Test.Handle.shutdown handle)
      (fun () ->
         set_environment handle (environment ());
         pump_until_text handle "No journal entries yet";
         require_pressable handle "journal-capture" ~release_delay_ms:80;
         require_animated_opacity
           handle
           "journal-capture-resting-feedback"
           ~opacity:1.
           ~duration_ms:160
           ~curve:Ui.Animation.Curve.Ease_out;
         require_animated_opacity
           handle
           "journal-capture-pressed-feedback"
           ~opacity:0.
           ~duration_ms:160
           ~curve:Ui.Animation.Curve.Ease_out;
         require_sized_size
           handle
           "journal-capture-pressed-visual"
           ~width:44.16
           ~height:44.16;
         require_decoration_shape
           handle
           "journal-capture-pressed-circle"
           ~background:0xff181e34l
           ~border_radius:22.08;
         require_stack_position
           handle
           "journal-capture-pressed-visual"
           ~left:3.92
           ~top:3.92;
         require_sized_size handle "journal-capture-pressed-shadow" ~width:50. ~height:50.;
         require_decoration_shape
           handle
           "journal-capture-pressed-shadow-surface"
           ~background:0x120d142fl
           ~border_radius:25.;
         send_pointer_event
           handle
           ~sequence:10_000L
           ~ui_tag:Ui.Event.Tag.Pointer_down
           ~protocol_tag:Protocol.Generated_protocol.Event_tag.pointer_down
           "journal-capture-gesture";
         require_animated_opacity
           handle
           "journal-capture-resting-feedback"
           ~opacity:0.
           ~duration_ms:0
           ~curve:Ui.Animation.Curve.Ease_out;
         require_animated_opacity
           handle
           "journal-capture-pressed-feedback"
           ~opacity:1.
           ~duration_ms:0
           ~curve:Ui.Animation.Curve.Ease_out;
         require_no_test_id handle "journal-capture-sheet";
         send_pointer_event
           handle
           ~sequence:10_001L
           ~ui_tag:Ui.Event.Tag.Pointer_down
           ~protocol_tag:Protocol.Generated_protocol.Event_tag.pointer_down
           "journal-capture-gesture";
         require_animated_opacity
           handle
           "journal-capture-pressed-feedback"
           ~opacity:1.
           ~duration_ms:0
           ~curve:Ui.Animation.Curve.Ease_out;
         send_pointer_event
           handle
           ~sequence:10_002L
           ~ui_tag:Ui.Event.Tag.Pointer_up
           ~protocol_tag:Protocol.Generated_protocol.Event_tag.pointer_up
           "journal-capture-gesture";
         require_animated_opacity
           handle
           "journal-capture-resting-feedback"
           ~opacity:1.
           ~duration_ms:160
           ~curve:Ui.Animation.Curve.Ease_out;
         require_animated_opacity
           handle
           "journal-capture-pressed-feedback"
           ~opacity:0.
           ~duration_ms:160
           ~curve:Ui.Animation.Curve.Ease_out))
;;

let test_capture_soft_press_respects_reduced_motion () =
  with_startup (fun startup ->
    let handle = create_handle startup in
    Fun.protect
      ~finally:(fun () -> Test.Handle.shutdown handle)
      (fun () ->
         set_environment handle (environment ~reduced_motion:true ());
         pump_until_text handle "No journal entries yet";
         require_animated_opacity
           handle
           "journal-capture-resting-feedback"
           ~opacity:1.
           ~duration_ms:0
           ~curve:Ui.Animation.Curve.Ease_out;
         send_pointer_event
           handle
           ~sequence:20_000L
           ~ui_tag:Ui.Event.Tag.Pointer_down
           ~protocol_tag:Protocol.Generated_protocol.Event_tag.pointer_down
           "journal-capture-gesture";
         require_animated_opacity
           handle
           "journal-capture-pressed-feedback"
           ~opacity:1.
           ~duration_ms:0
           ~curve:Ui.Animation.Curve.Ease_out;
         send_pointer_event
           handle
           ~sequence:20_001L
           ~ui_tag:Ui.Event.Tag.Pointer_up
           ~protocol_tag:Protocol.Generated_protocol.Event_tag.pointer_up
           "journal-capture-gesture";
         require_animated_opacity
           handle
           "journal-capture-pressed-feedback"
           ~opacity:0.
           ~duration_ms:0
           ~curve:Ui.Animation.Curve.Ease_out))
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
           (Float.equal props.default_item_extent 48.)
           "timeline default extent is %.1f, expected 48"
           props.default_item_extent;
         require (props.overscan = 4) "timeline overscan is %d, expected 4" props.overscan;
         require
           (Array.length node.children <= Journal_timeline_state.maximum_supplied_rows)
           "timeline supplied %d rows"
           (Array.length node.children);
         require
           (List.exists
              (fun (override : Ui.Native_widget.Sparse_extent_list.extent_override) ->
                 override.index = 65 && Float.equal override.extent 114.)
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
         click_test_id handle "journal-capture";
         require_test_id handle "capture-editor";
         require_test_id handle "capture-save";
         require_test_id handle "capture-task";
         require_no_test_id handle "capture-attachment";
         require_no_test_id handle "capture-token-action";
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

let test_capture_allocates_fresh_block_identity_after_restart () =
  with_startup (fun startup ->
    let persisted : Journal_repository.capture =
      { mutation_id = "80000000-0000-4000-9000-000000000002"
      ; block_id = "80000000-0000-4000-a000-000000000002"
      ; sibling_order = "000000000002"
      ; source = "Persisted before restart"
      ; task_state = Journal_model.Not_a_task
      ; creation_time = fixture_time 20260809 2
      }
    in
    seed startup [ persisted ];
    let save_capture handle source =
      click_test_id handle "journal-capture";
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
    then fail "timed out waiting for formatted-day generation %Ld" generation
    else (
      match latest_application_request handle with
      | Some (_request_id, payload) as request
        when Bytes.length payload >= 16 && Bytes.get_int64_le payload 8 = generation ->
        Option.get request
      | None | Some _ ->
        Unix.sleepf 0.001;
        pump_worker handle;
        loop (attempts - 1))
  in
  loop 500
;;

let respond_to_application_request ?(sequence = 1L) handle request_id payload =
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

let calendar_event ~generation ~local_day ~locale ~time_zone_id ~utc_offset_seconds =
  let header_size = 56 in
  let bytes =
    Bytes.make (header_size + String.length locale + String.length time_zone_id) '\000'
  in
  Bytes.blit_string "LJP1" 0 bytes 0 4;
  Bytes.set_uint16_le bytes 4 1;
  Bytes.set_uint16_le bytes 6 3;
  Bytes.set_uint16_le bytes 8 4;
  Bytes.set_uint16_le bytes 10 (String.length locale);
  Bytes.set_uint16_le bytes 12 (String.length time_zone_id);
  Bytes.set_int64_le bytes 16 1_786_321_800_000L;
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
  bytes
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
  bytes
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
           (Bytes.get_int64_le payload 8 = 1L)
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
           ~sequence:1L
           (calendar_event
              ~generation:2L
              ~local_day:20260810
              ~locale:"zh_CN"
              ~time_zone_id:"Asia/Shanghai"
              ~utc_offset_seconds:28_800);
         let new_request_id, new_payload =
           pump_until_application_request_generation handle 2L
         in
         require
           (Bytes.get_int64_le new_payload 8 = 2L)
           "locale event did not issue a generation-2 formatting request";
         respond_to_application_request
           ~sequence:2L
           handle
           old_request_id
           (formatted_response
              ~generation:1L
              [ 20260809, "stale locale today"; 20260808, "stale locale older" ]);
         Test.Handle.present handle;
         require_no_visible_text handle "stale locale today";
         require_no_visible_text handle "stale locale older";
         respond_to_application_request
           ~sequence:3L
           handle
           new_request_id
           (formatted_response
              ~generation:2L
              [ 20260810, "周一，8月10日"; 20260808, "周六，8月8日" ]);
         Test.Handle.present handle;
         require_visible_text handle "周一，8月10日";
         require_visible_text handle "周六，8月8日"))
;;

let test_timeline_task_and_row_body_toggle_are_independent () =
  with_startup (fun startup ->
    let parent = capture ~task_state:Journal_model.Todo 90 "Parent task source" in
    seed startup [ parent ];
    let child = seed_child startup ~parent 91 "Existing direct child" in
    let handle = create_handle startup in
    Fun.protect
      ~finally:(fun () -> Test.Handle.shutdown handle)
      (fun () ->
         pump_until_text handle parent.source;
         let task_id = "journal-row-task:" ^ parent.block_id in
         click_test_id handle task_id;
         pump_until handle "durable task completion" (fun () ->
           Option.is_some
             (Test.Handle.find
                handle
                (Test.Query.semantics_label ("Mark as todo: " ^ parent.source))));
         click_test_id handle ("journal-row-toggle-children:" ^ parent.block_id);
         pump_until_text handle child.source;
         require_no_test_id handle ("journal-row-open:" ^ parent.block_id);
         require_no_test_id handle ("journal-row-disclosure:" ^ parent.block_id);
         click_test_id handle ("journal-row-toggle-children:" ^ parent.block_id);
         pump_until handle "row-body collapse" (fun () ->
           Option.is_none (Test.Handle.find handle (Test.Query.visible_text child.source)))))
;;

let test_loading_recovery_and_adaptive_environment_surfaces_are_truthful () =
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
                (Float.equal props.default_item_extent expected.block_extent)
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
            require (not transition.enabled) "reduced motion kept list animation enabled";
            require
              (transition.expand_duration_ms = 0 && transition.collapse_duration_ms = 0)
              "reduced motion kept nonzero list durations"
          | None -> fail "Timeline omitted its explicit transition policy");
         require_no_test_id handle ("journal-row-open:" ^ parent.block_id)));
  with_startup (fun startup ->
    let handle = create_handle startup in
    let competing = ref None in
    Fun.protect
      ~finally:(fun () ->
        Option.iter
          (fun database ->
             ignore (Sqlite3.exec database "ROLLBACK");
             require (Sqlite3.db_close database) "failed to close competing SQLite handle")
          !competing;
        Test.Handle.shutdown handle)
      (fun () ->
         pump_until_text handle "No journal entries yet";
         let database = Sqlite3.db_open (database_path startup) in
         competing := Some database;
         let result = Sqlite3.exec database "BEGIN EXCLUSIVE" in
         require
           (Sqlite3.Rc.is_success result)
           "failed to acquire competing SQLite lock: %s"
           (Sqlite3.Rc.to_string result);
         click_test_id handle "journal-capture";
         Test.Handle.input_text
           handle
           (Test.Query.test_id "capture-editor")
           "Cannot persist in recovery";
         Test.Handle.present handle;
         click_test_id handle "capture-save";
         pump_until_text handle "Journal is read-only";
         require_live_region handle "Journal is read-only";
         require_no_test_id handle "capture-retry"))
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
         require_stack_bottom handle "journal-delete-snackbar-position" 122.;
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
    require_no_test_id handle "journal-delete-undo";
    Test.Handle.shutdown handle;
    let store = open_store startup in
    Fun.protect
      ~finally:(fun () -> close_store store)
      (fun () ->
         match
           Journal_repository.find_block
             (Journal_storage.current_db store)
             ~id:command.block_id
         with
         | Ok None -> ()
         | Ok (Some _) -> fail "deadline delete was not durable"
         | Error error ->
           fail
             "deadline delete lookup failed: %s"
             (Journal_repository.Error.to_string error)))
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
  test_capture_is_an_ocaml_contextual_modal_sheet ();
  test_capture_sheet_protects_dirty_state_and_reconciles_environment ();
  test_header_uses_tokens_safe_area_and_independent_center ();
  test_header_adapts_without_exposing_deferred_actions ();
  test_capture_soft_press_has_tactile_down_and_ease_out_release ();
  test_capture_soft_press_respects_reduced_motion ();
  test_header_stays_light_when_the_system_uses_dark_appearance ();
  test_timeline_uses_exact_sparse_extent_window ();
  test_timeline_uses_truthful_fallback_labels_without_duplicate_today ();
  test_view_only_date_and_capture_route_own_plain_text_mutation_behavior ();
  test_capture_allocates_fresh_block_identity_after_restart ();
  test_localized_day_request_updates_only_matching_generation ();
  test_locale_event_invalidates_labels_and_rejects_in_flight_response ();
  test_timeline_task_and_row_body_toggle_are_independent ();
  test_loading_recovery_and_adaptive_environment_surfaces_are_truthful ();
  test_swipe_delete_stages_undoes_and_commits_only_after_deadline ();
  test_swipe_delete_accessibility_duration_and_single_mutation_gate ()
;;
