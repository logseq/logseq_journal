module ID = Bonsai_flutter_spec.Id
module Test = Bonsai_flutter_test
module Tokens = Journal_visual_tokens
module Ui = Bonsai_flutter_ui

let fail format = Printf.ksprintf failwith format

let require condition format =
  Printf.ksprintf (fun message -> if not condition then failwith message) format
;;

let require_ok = function
  | Ok value -> value
  | Error error -> fail "unexpected fixture rejection: %s" error
;;

let block_id = "20000000-0000-4000-a000-000000000001"
let page_id = "20000000-0000-4000-b000-000000000001"
let mutation_id = "20000000-0000-4000-9000-000000000001"

let creation_time =
  Journal_time.create
    ~instant_unix_ms:1_786_237_500_000L
    ~local_day:20260809
    ~local_minute_of_day:545
    ~time_zone_id:"Asia/Shanghai"
    ~utc_offset_seconds:28_800
  |> require_ok
;;

let block
      ?(source = "Literal #journal @person 👩🏽‍💻")
      ?(task_state = Journal_model.Done)
      ?(child_count = 3)
      ()
  =
  Journal_model.create
    ~id:block_id
    ~page_id
    ~journal_day:20260809
    ~parent_id:None
    ~sibling_order:"000000000001"
    ~source
    ~task_state
    ~child_count
    ~creation_time
    ~revision:4
    ~last_mutation_id:mutation_id
  |> require_ok
;;

type counters =
  { task : int
  ; toggle : int
  }

let component ~tokens ~profile ~rtl ~item ~expanded handlers graph =
  let counters, set_counters =
    Bonsai_v017.state ~equal:( = ) { task = 0; toggle = 0 } graph
  in
  let handler name update =
    Bonsai_flutter.Driver.Handler.create
      handlers
      ~name
      ~equal:( == )
      set_counters
      ~f:(fun set_counters -> function
      | Ui.Event.Payload.Unit | Int64 _ -> set_counters update
      | _ -> Bonsai.Effect.Ignore)
  in
  let task =
    handler "row-test-task" (fun state -> { state with task = state.task + 1 })
  in
  let toggle =
    handler "row-test-toggle" (fun state -> { state with toggle = state.toggle + 1 })
  in
  Bonsai.Cont.map2
    counters
    (Bonsai.Cont.both task toggle)
    ~f:(fun counters (task, toggle) ->
      Ui.Widget.Flex.column
        [ Ui.Widget.Flex.fixed
            (Journal_row.view
               ~tokens
               ~profile
               ~device_pixel_ratio:3.
               ~rtl
               ~item
               ~expanded
               ~sort_base:0.
               ~reduced_motion:false
               ~on_task_toggle:task
               ~on_toggle_children:toggle)
        ; Ui.Widget.Flex.fixed
            (Ui.Widget.text
               (Printf.sprintf "task=%d toggle=%d" counters.task counters.toggle))
        ])
;;

let create_handle ?(width = 390.) ?(scale = 1.) ?(rtl = false) ?(expanded = false) item =
  let tokens = Tokens.resolve ~high_contrast:false in
  let profile = Tokens.select_row_profile ~viewport_width:width ~text_scale:scale in
  let time_source = Bonsai.Time_source.create ~start:Core.Time_ns.epoch in
  let handle =
    Test.Handle.create
      ~runtime_epoch:(ID.Runtime.Epoch.of_int64 7_001L)
      ~time_source
      (component ~tokens ~profile ~rtl ~item ~expanded)
  in
  Test.Handle.present handle;
  handle, profile
;;

let node handle test_id =
  match Test.Handle.find handle (Test.Query.test_id test_id) with
  | Some node -> node
  | None -> fail "missing test ID %S\n%s" test_id (Test.Handle.show handle)
;;

let require_text handle test_id expected =
  match (node handle test_id).props with
  | Ui.Widget.Private.Text_props { value; _ } ->
    require (String.equal value expected) "%s text changed" test_id
  | _ -> fail "%s is not Text" test_id
;;

type semantics_view =
  { role : Ui.Semantics.Role.t
  ; hint : string option
  ; value : string option
  ; checked : bool option
  ; enabled : bool option
  ; focusable : bool option
  ; live_region : bool
  ; heading_level : int option
  ; sort_key : float option
  ; actions : Ui.Semantics.Action.t list
  }

let require_semantics handle label check =
  match Test.Handle.find_all handle (Test.Query.semantics_label label) with
  | [ { props =
          Ui.Widget.Private.Semantics_props
            { role
            ; hint
            ; value
            ; checked
            ; enabled
            ; focusable
            ; live_region
            ; heading_level
            ; sort_key
            ; actions
            ; _
            }
      ; _
      }
    ] ->
    check
      { role
      ; hint
      ; value
      ; checked
      ; enabled
      ; focusable
      ; live_region
      ; heading_level
      ; sort_key
      ; actions
      }
  | [ _ ] -> fail "%S is not attached to Semantics" label
  | [] -> fail "missing semantics label %S\n%s" label (Test.Handle.show handle)
  | matches -> fail "%S has %d duplicate semantic nodes" label (List.length matches)
;;

let require_target handle test_id =
  match (node handle test_id).props with
  | Ui.Widget.Private.Constrained_box_props { min_width; min_height; _ } ->
    require
      (Float.compare min_width 44. >= 0 && Float.compare min_height 44. >= 0)
      "%s is %.1fx%.1f, expected at least 44x44"
      test_id
      min_width
      min_height
  | _ -> fail "%s is not a constrained target" test_id
;;

let require_pressable handle test_id ~release_delay_ms =
  match (node handle test_id).props with
  | Ui.Widget.Private.Pressable_props { overlay_color; release_delay_ms = actual } ->
    require
      (Int32.equal (Ui.Style.Color.Private.to_argb32 overlay_color) 0x1f0d142fl
       && actual = release_delay_ms)
      "%s pressed feedback differs"
      test_id
  | _ -> fail "%s is not Pressable" test_id
;;

let require_sized_width handle test_id expected =
  match (node handle test_id).props with
  | Ui.Widget.Private.Sized_box_props { width = Some actual; _ } ->
    require (Float.equal actual expected) "%s width is %.1f" test_id actual
  | _ -> fail "%s is not a width-constrained SizedBox" test_id
;;

let require_padding handle test_id ~left ~right =
  match (node handle test_id).props with
  | Ui.Widget.Private.Padding_props { left = actual_left; right = actual_right; _ } ->
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

let require_icon handle test_id ~code_point ~color =
  match (node handle test_id).props with
  | Ui.Widget.Private.Icon_props
      { code_point = actual_code_point
      ; font_family = Some "MaterialIcons"
      ; color = Some actual_color
      ; _
      } ->
    require
      (actual_code_point = code_point && Int32.equal actual_color color)
      "%s icon differs"
      test_id
  | _ -> fail "%s is not a Material icon" test_id
;;

let require_decoration handle test_id ~background ~border_radius =
  match (node handle test_id).props with
  | Ui.Widget.Private.Decorated_box_props
      { background = Some actual_background; border_radius = actual_radius } ->
    require
      (Int32.equal actual_background background && Float.equal actual_radius border_radius)
      "%s decoration differs"
      test_id
  | _ -> fail "%s is not a colored DecoratedBox" test_id
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
    require (earlier_index < later_index) "%S must precede %S\n%s" earlier later tree
  | _ -> fail "missing %S or %S\n%s" earlier later tree
;;

let test_literal_source_time_completion_and_full_access () =
  let source = "Literal #journal @person 👩🏽‍💻" in
  let item = Journal_row.Item.of_block (block ~source ()) in
  let handle, _profile = create_handle item in
  Fun.protect
    ~finally:(fun () -> Test.Handle.shutdown handle)
    (fun () ->
       (match (node handle ("journal-row-source:" ^ block_id)).props with
        | Ui.Widget.Private.Text_props
            { value; max_lines = Some 1; overflow = Ui.Style.Text_overflow.Ellipsis; _ }
          -> require (String.equal value source) "literal source was parsed or changed"
        | _ -> fail "Timeline source is not one-line ellipsized Text");
       require_text handle ("journal-row-time:" ^ block_id) "09:05";
       require_target handle ("journal-row-toggle-children-target:" ^ block_id);
       require
         (Journal_row.Item.source_for_detail item = Some source)
         "Detail lost the complete source";
       let label = source ^ ", created at 09:05" in
       require_semantics handle label (fun props ->
         require (props.role = Ui.Semantics.Role.Button) "row role changed";
         require (props.enabled = Some true) "row is not enabled";
         require (props.focusable = Some true) "row is not focusable";
         require (props.sort_key = Some 2.) "row focus order changed";
         require (props.value = Some "Collapsed") "row collapsed state is missing";
         require
           (props.hint = Some "Show direct child blocks")
           "row disclosure hint changed";
         require (not props.live_region) "row was incorrectly made a live region";
         require (props.heading_level = None) "row was incorrectly made a heading";
         require
           (props.actions = [ Ui.Semantics.Action.Tap ])
           "row lost its sole Tap action");
       List.iter
         (fun forbidden ->
            require
              (Option.is_none
                 (Test.Handle.find handle (Test.Query.visible_text forbidden)))
              "forbidden row surface %S is visible"
              forbidden)
         [ "Attachment"; "Thumbnail"; "Styled token" ])
;;

let test_long_source_and_corrupt_surfaces () =
  let long_source = String.make 65_536 'x' in
  let long_item = Journal_row.Item.of_block (block ~source:long_source ()) in
  let long_handle, _profile = create_handle long_item in
  Fun.protect
    ~finally:(fun () -> Test.Handle.shutdown long_handle)
    (fun () ->
       require_text long_handle ("journal-row-source:" ^ block_id) long_source;
       require
         (Journal_row.Item.source_for_detail long_item = Some long_source)
         "long Detail source was truncated";
       require_semantics long_handle (long_source ^ ", created at 09:05") (fun _ -> ()));
  let missing_time =
    Journal_row.Item.corrupt ~id:"corrupt-time" ~source:(Some "Recovered source")
  in
  let missing_handle, _profile = create_handle missing_time in
  Fun.protect
    ~finally:(fun () -> Test.Handle.shutdown missing_handle)
    (fun () ->
       require_text missing_handle "journal-row-source:corrupt-time" "Recovered source";
       require
         (Journal_row.Item.source_for_detail missing_time = Some "Recovered source")
         "recoverable source was discarded";
       require
         (Option.is_none
            (Test.Handle.find missing_handle (Test.Query.visible_text "00:00")))
         "missing time was fabricated as 00:00";
       ignore (node missing_handle "journal-row-time-slot:corrupt-time"));
  let malformed = Bytes.unsafe_to_string (Bytes.of_string "\255") in
  let corrupt = Journal_row.Item.corrupt ~id:"corrupt-source" ~source:(Some malformed) in
  let corrupt_handle, _profile = create_handle corrupt in
  Fun.protect
    ~finally:(fun () -> Test.Handle.shutdown corrupt_handle)
    (fun () ->
       require_text
         corrupt_handle
         "journal-row-source:corrupt-source"
         "Unavailable journal entry";
       require
         (Journal_row.Item.source_for_detail corrupt = None)
         "corrupt source leaked into Detail";
       require_semantics corrupt_handle "Unavailable journal entry" (fun _ -> ()))
;;

let test_independent_task_and_row_body_actions () =
  let source = "Grocery list" in
  let item =
    Journal_row.Item.of_block (block ~source ~task_state:Journal_model.Done ())
  in
  let handle, _profile = create_handle item in
  Fun.protect
    ~finally:(fun () -> Test.Handle.shutdown handle)
    (fun () ->
       require_target handle ("journal-row-task-target:" ^ block_id);
       require_target handle ("journal-row-toggle-children-target:" ^ block_id);
       require_pressable handle ("journal-row-task:" ^ block_id) ~release_delay_ms:80;
       require_pressable
         handle
         ("journal-row-toggle-children:" ^ block_id)
         ~release_delay_ms:80;
       require
         (Option.is_none
            (Test.Handle.find
               handle
               (Test.Query.test_id ("journal-row-disclosure-target:" ^ block_id))))
         "passive disclosure retained an independent target";
       require
         (Option.is_none
            (Test.Handle.find
               handle
               (Test.Query.test_id ("journal-row-open-target:" ^ block_id))))
         "obsolete row-open target still exists";
       require_decoration
         handle
         ("journal-row-task-visual:" ^ block_id)
         ~background:0xff058e46l
         ~border_radius:7.;
       require_icon
         handle
         ("journal-row-task-icon:" ^ block_id)
         ~code_point:0xe156
         ~color:0xffffffffl;
       require_icon
         handle
         ("journal-row-disclosure-icon:" ^ block_id)
         ~code_point:0xe15f
         ~color:0xff656b8fl;
       require_sized_width handle ("journal-row-task-slot:" ^ block_id) 18.;
       require_tree_order
         handle
         ("test_id=journal-row-source:" ^ block_id)
         ("test_id=journal-row-disclosure-icon:" ^ block_id);
       require_tree_order
         handle
         ("test_id=journal-row-disclosure-icon:" ^ block_id)
         ("test_id=journal-row-time-slot:" ^ block_id);
       require_semantics handle ("Mark as todo: " ^ source) (fun props ->
         require (props.role = Ui.Semantics.Role.Checkbox) "task role changed";
         require (props.checked = Some true) "Done task is not checked";
         require (props.value = Some "Done") "Done task value changed";
         require (props.sort_key = Some 1.) "task focus order changed";
         require (props.actions = [ Ui.Semantics.Action.Tap ]) "task action changed");
       require_semantics handle (source ^ ", created at 09:05") (fun props ->
         require (props.role = Ui.Semantics.Role.Button) "row-body role changed";
         require (props.value = Some "Collapsed") "collapsed value changed";
         require (props.sort_key = Some 2.) "row-body focus order changed";
         require (props.hint = Some "Show direct child blocks") "collapsed hint changed";
         require
           (props.actions = [ Ui.Semantics.Action.Tap ])
           "row body must expose only Tap");
       Test.Handle.click handle (Test.Query.test_id ("journal-row-task:" ^ block_id));
       require
         (Option.is_some
            (Test.Handle.find handle (Test.Query.visible_text "task=1 toggle=0")))
         "task action propagated into another row action";
       Test.Handle.present handle;
       Test.Handle.click
         handle
         (Test.Query.test_id ("journal-row-toggle-children:" ^ block_id));
       require
         (Option.is_some
            (Test.Handle.find handle (Test.Query.visible_text "task=1 toggle=1")))
         "row-body action propagated into another action";
       Test.Handle.present handle);
  let expanded_handle, _profile = create_handle ~expanded:true item in
  Fun.protect
    ~finally:(fun () -> Test.Handle.shutdown expanded_handle)
    (fun () ->
       require_icon
         expanded_handle
         ("journal-row-disclosure-icon:" ^ block_id)
         ~code_point:0xe246
         ~color:0xff656b8fl;
       require_semantics expanded_handle (source ^ ", created at 09:05") (fun props ->
         require (props.value = Some "Expanded") "expanded value changed";
         require (props.hint = Some "Hide direct child blocks") "expanded hint changed"))
;;

let test_conditional_task_leading_slot_and_todo_icon () =
  let plain =
    Journal_row.Item.of_block
      (block ~task_state:Journal_model.Not_a_task ~child_count:0 ())
  in
  let plain_handle, _profile = create_handle plain in
  Fun.protect
    ~finally:(fun () -> Test.Handle.shutdown plain_handle)
    (fun () ->
       let body = node plain_handle ("journal-row-compact:" ^ block_id) in
       require
         (Array.length body.children = 2)
         "plain compact row has unexpected fixed control space";
       (match (node plain_handle ("journal-row-inline:" ^ block_id)).props with
        | Ui.Widget.Private.Linear_props -> ()
        | _ -> fail "plain source does not use the bounded inline row");
       require
         (Option.is_none
            (Test.Handle.find
               plain_handle
               (Test.Query.test_id ("journal-row-task-target:" ^ block_id))))
         "plain row exposed a task target";
       require
         (Option.is_none
            (Test.Handle.find
               plain_handle
               (Test.Query.test_id ("journal-row-task-slot:" ^ block_id))))
         "plain row retained a task visual slot";
       require_padding
         plain_handle
         ("journal-row-body-padding:" ^ block_id)
         ~left:28.
         ~right:24.);
  let todo =
    Journal_row.Item.of_block (block ~task_state:Journal_model.Todo ~child_count:0 ())
  in
  let todo_handle, _profile = create_handle todo in
  Fun.protect
    ~finally:(fun () -> Test.Handle.shutdown todo_handle)
    (fun () ->
       require_target todo_handle ("journal-row-task-target:" ^ block_id);
       require_icon
         todo_handle
         ("journal-row-task-icon:" ^ block_id)
         ~code_point:0xe504
         ~color:0xff0d142fl;
       require_sized_width todo_handle ("journal-row-task-slot:" ^ block_id) 18.;
       require
         (Option.is_none
            (Test.Handle.find
               todo_handle
               (Test.Query.test_id ("journal-row-toggle-children:" ^ block_id))))
         "task leaf body is actionable";
       require_semantics
         todo_handle
         "Literal #journal @person 👩🏽‍💻, created at 09:05"
         (fun props ->
            require (props.role = Ui.Semantics.Role.Generic) "leaf body is not static";
            require (props.actions = []) "leaf body exposes Tap");
       match (node todo_handle ("journal-row-body-content:" ^ block_id)).props with
       | Ui.Widget.Private.Sized_box_props { height = Some 44.; width = None } -> ()
       | _ -> fail "leaf body does not use a finite center slot")
;;

let header_component ~tokens _handlers _graph =
  Bonsai.Cont.return
    (Journal_header.view
       ~tokens
       ~text_scale:1.
       ~device_pixel_ratio:3.
       ~context:(Journal_header.Context.today ~subtitle:"Sunday, August 9"))
;;

let test_header_shells_and_view_only_date_have_truthful_semantics () =
  let tokens = Tokens.resolve ~high_contrast:false in
  let time_source = Bonsai.Time_source.create ~start:Core.Time_ns.epoch in
  let handle =
    Test.Handle.create
      ~runtime_epoch:(ID.Runtime.Epoch.of_int64 7_002L)
      ~time_source
      (header_component ~tokens)
  in
  Fun.protect
    ~finally:(fun () -> Test.Handle.shutdown handle)
    (fun () ->
       Test.Handle.present handle;
       List.iter
         (fun label ->
            require
              (Option.is_none
                 (Test.Handle.find handle (Test.Query.semantics_label label)))
              "%s visual shell exposes actionable semantics"
              label)
         [ "Menu"; "More" ];
       List.iter
         (fun test_id -> ignore (node handle test_id))
         [ "journal-menu-shell"
         ; "journal-menu-icon"
         ; "journal-more-shell"
         ; "journal-more-icon"
         ];
       List.iter
         (fun test_id ->
            require
              (Option.is_none (Test.Handle.find handle (Test.Query.test_id test_id)))
              "%s obsolete Header decoration still exists"
              test_id)
         [ "journal-header-handle"; "journal-more-surface" ];
       List.iter
         (fun test_id ->
            require
              (Option.is_none (Test.Handle.find handle (Test.Query.test_id test_id)))
              "%s deferred interaction path still exists"
              test_id)
         [ "journal-menu"; "journal-menu-target"; "journal-more"; "journal-more-target" ];
       require_semantics handle "Today, Sunday, August 9" (fun props ->
         require (props.role = Ui.Semantics.Role.Generic) "date context is still a button";
         require (props.enabled = None) "view-only date exposes enabled state";
         require (props.focusable <> Some true) "view-only date is keyboard focusable";
         require (props.actions = []) "view-only date exposes an activation action";
         require (props.sort_key = Some 2.) "date semantic order changed"))
;;

let require_row_shape
      ?expected_metadata_height
      ?(expected_source_height = 44.)
      width
      scale
      expected_kind
      expected_extent
      expected_time_width
  =
  let item = Journal_row.Item.of_block (block ()) in
  let handle, profile = create_handle ~width ~scale item in
  Fun.protect
    ~finally:(fun () -> Test.Handle.shutdown handle)
    (fun () ->
       require (profile.block_extent = expected_extent) "profile extent changed";
       (match (node handle ("journal-row-extent:" ^ block_id)).props with
        | Ui.Widget.Private.Sized_box_props { height = Some height; _ } ->
          require (height = expected_extent) "row extent is %.1f" height
        | _ -> fail "row does not publish an exact extent");
       (match (node handle (expected_kind ^ ":" ^ block_id)).props with
        | Ui.Widget.Private.Linear_props -> ()
        | _ -> fail "%s layout is not a Flex node" expected_kind);
       (match (node handle ("journal-row-time-slot:" ^ block_id)).props with
        | Ui.Widget.Private.Constrained_box_props { min_width; max_width; _ } ->
          require
            (min_width = expected_time_width && max_width = expected_time_width)
            "time slot is %.1f..%.1f, expected %.1f"
            min_width
            max_width
            expected_time_width
        | _ -> fail "time slot is not reserved");
       (match (node handle ("journal-row-body-content:" ^ block_id)).props with
        | Ui.Widget.Private.Sized_box_props { height = Some height; _ } ->
          require
            (Float.equal height expected_source_height)
            "source center slot is %.1f, expected %.1f"
            height
            expected_source_height
        | _ -> fail "source center slot does not publish a finite height");
       Option.iter
         (fun expected_height ->
            match
              (node handle ("journal-row-adaptive-metadata-slot:" ^ block_id)).props
            with
            | Ui.Widget.Private.Sized_box_props { height = Some height; _ } ->
              require
                (height = expected_height)
                "adaptive metadata height is %.1f, expected %.1f"
                height
                expected_height
            | _ -> fail "adaptive metadata does not publish a finite height")
         expected_metadata_height;
       match (node handle ("journal-row-divider:" ^ block_id)).props with
       | Ui.Widget.Private.Sized_box_props { height = Some height; _ } ->
         require
           (Float.equal height (1. /. 3.))
           "row divider is %.3f logical pixels at 3x, expected one physical pixel"
           height
       | _ -> fail "row divider does not publish an exact physical-pixel height")
;;

let test_compact_and_adaptive_shapes_at_required_extremes () =
  require_row_shape 390. 1. "journal-row-compact" 48. 52.;
  require_row_shape 320. 1. "journal-row-adaptive" 80. 52.;
  require_row_shape
    ~expected_metadata_height:(383. /. 6.)
    ~expected_source_height:(383. /. 6.)
    744.
    2.
    "journal-row-adaptive"
    128.
    104.;
  require_row_shape
    ~expected_metadata_height:(557. /. 6.)
    ~expected_source_height:(557. /. 6.)
    1_200.
    3.2
    "journal-row-adaptive"
    186.
    167.
;;

let test_rtl_row_geometry_uses_logical_edges () =
  let item = Journal_row.Item.of_block (block ()) in
  let handle, _profile = create_handle ~rtl:true item in
  Fun.protect
    ~finally:(fun () -> Test.Handle.shutdown handle)
    (fun () ->
       require_icon
         handle
         ("journal-row-disclosure-icon:" ^ block_id)
         ~code_point:0xe15e
         ~color:0xff656b8fl;
       require_padding handle ("journal-row-body-padding:" ^ block_id) ~left:24. ~right:4.;
       require_padding handle ("journal-row-source-gap:" ^ block_id) ~left:8. ~right:0.;
       require_padding
         handle
         ("journal-row-divider-padding:" ^ block_id)
         ~left:0.
         ~right:18.)
;;

let test_child_count_widths_and_long_parent_source_remain_bounded () =
  List.iter
    (fun child_count ->
       let source =
         if child_count = 123
         then String.make 65_536 'x'
         else Printf.sprintf "Parent with %d children" child_count
       in
       let item = Journal_row.Item.of_block (block ~source ~child_count ()) in
       let handle, _profile = create_handle ~width:320. item in
       Fun.protect
         ~finally:(fun () -> Test.Handle.shutdown handle)
         (fun () ->
            require_semantics handle (source ^ ", created at 09:05") (fun props ->
              require
                (props.value = Some "Collapsed")
                "multi-digit child count lost collapsed state");
            require_tree_order
              handle
              ("test_id=journal-row-source:" ^ block_id)
              ("test_id=journal-row-disclosure-icon:" ^ block_id);
            require_tree_order
              handle
              ("test_id=journal-row-disclosure-icon:" ^ block_id)
              ("test_id=journal-row-time-slot:" ^ block_id)))
    [ 1; 12; 123 ]
;;

let delete_timeline_component ~delete_enabled handlers _graph =
  let ignored =
    Bonsai_flutter.Driver.Handler.create
      handlers
      ~name:"delete-timeline-ignored"
      ~equal:(fun () () -> true)
      (Bonsai.Cont.return ())
      ~f:(fun () _ -> Bonsai.Effect.Ignore)
  in
  Bonsai.Cont.map ignored ~f:(fun ignored ->
    let block = block () in
    let state = Journal_timeline_state.empty ~today:20260809 in
    let state =
      Journal_timeline_state.begin_request
        state
        ~generation:1L
        (Journal_timeline_state.Feed { before_day = None })
    in
    let state =
      Journal_timeline_state.apply_feed
        state
        ~generation:1L
        { Journal_repository.days =
            [ { page = { id = page_id; day = 20260809; title = "Today" }
              ; blocks = [ block ]
              ; has_more_blocks = false
              }
            ]
        ; slot_count = 1
        ; has_more_days = false
        }
    in
    match
      Journal_timeline.view
        ~tokens:(Tokens.resolve ~high_contrast:false)
        ~profile:(Tokens.select_row_profile ~viewport_width:390. ~text_scale:1.)
        ~device_pixel_ratio:3.
        ~rtl:false
        ~state
        ~day_label:(fun _ -> "Today")
        ~reduced_motion:false
        ~safe_bottom:34.
        ~delete_enabled
        ~on_delete:ignored
        ~on_visible_range:ignored
        ~on_task_toggle:ignored
        ~on_toggle_children:ignored
    with
    | Journal_timeline.Empty widget -> widget
    | Populated viewport -> Ui.Widget.Viewport.Vertical.with_height ~height:600. viewport)
;;

let test_swipe_delete_wrapper_has_only_square_logical_end_action () =
  let time_source = Bonsai.Time_source.create ~start:Core.Time_ns.epoch in
  let handle =
    Test.Handle.create
      ~runtime_epoch:(ID.Runtime.Epoch.of_int64 7_003L)
      ~time_source
      (delete_timeline_component ~delete_enabled:true)
  in
  Fun.protect
    ~finally:(fun () -> Test.Handle.shutdown handle)
    (fun () ->
       Test.Handle.present handle;
       let swipe = node handle ("journal-row-swipe:" ^ block_id) in
       (match swipe.props with
        | Ui.Widget.Private.Native_widget_props { payload; _ } ->
          require (Bytes.length payload > 44) "swipe payload omitted action label";
          require (Char.code (Bytes.get payload 0) = 2) "swipe enabled the start action";
          require (Char.code (Bytes.get payload 2) = 0) "end action is not Dismiss";
          require
            (Float.equal (Int64.float_of_bits (Bytes.get_int64_le payload 20)) 0.)
            "delete action feedback is not square";
          let start_length = Int32.to_int (Bytes.get_int32_le payload 36) in
          let end_length = Int32.to_int (Bytes.get_int32_le payload 40) in
          let label = Bytes.sub_string payload (44 + start_length) end_length in
          require
            (String.equal label "Delete block and all descendants")
            "delete action label changed: %S"
            label;
          require (start_length = 0) "start action label is not empty"
        | _ -> fail "delete wrapper is not native");
       (match (node handle ("journal-row-delete-icon:" ^ block_id)).props with
        | Ui.Widget.Private.Icon_props
            { code_point = 0xe1b9; font_family = Some "MaterialIcons"; _ } -> ()
        | Icon_props _ -> fail "delete feedback does not use the Material delete icon"
        | _ -> fail "delete feedback is not an icon");
       ignore (node handle ("journal-row-task:" ^ block_id));
       ignore (node handle ("journal-row-toggle-children:" ^ block_id)));
  let disabled =
    Test.Handle.create
      ~runtime_epoch:(ID.Runtime.Epoch.of_int64 7_004L)
      ~time_source:(Bonsai.Time_source.create ~start:Core.Time_ns.epoch)
      (delete_timeline_component ~delete_enabled:false)
  in
  Fun.protect
    ~finally:(fun () -> Test.Handle.shutdown disabled)
    (fun () ->
       Test.Handle.present disabled;
       require
         (Option.is_none
            (Test.Handle.find
               disabled
               (Test.Query.test_id ("journal-row-swipe:" ^ block_id))))
         "write-disabled row retained swipe wrapper")
;;

let test_delete_and_snackbar_tokens_are_explicit_and_accessible () =
  let normal = Tokens.palette (Tokens.resolve ~high_contrast:false) in
  let high_contrast = Tokens.palette (Tokens.resolve ~high_contrast:true) in
  require
    (Ui.Style.Color.Private.to_argb32 normal.destructive
     <> Ui.Style.Color.Private.to_argb32 normal.background)
    "normal destructive surface blends into background";
  require
    (Ui.Style.Color.Private.to_argb32 high_contrast.destructive
     <> Ui.Style.Color.Private.to_argb32 high_contrast.background)
    "high-contrast destructive surface blends into background";
  require
    (Ui.Style.Color.Private.to_argb32 normal.snackbar_surface
     <> Ui.Style.Color.Private.to_argb32 normal.snackbar_primary_text)
    "snackbar text lacks contrast";
  require
    (Tokens.snackbar_geometry.minimum_height >= 48.)
    "snackbar cannot contain a 48-point Undo target";
  require
    (Tokens.snackbar_geometry.maximum_width <= Tokens.timeline_max_width)
    "snackbar exceeds timeline maximum width"
;;

let () =
  test_literal_source_time_completion_and_full_access ();
  test_long_source_and_corrupt_surfaces ();
  test_independent_task_and_row_body_actions ();
  test_conditional_task_leading_slot_and_todo_icon ();
  test_header_shells_and_view_only_date_have_truthful_semantics ();
  test_compact_and_adaptive_shapes_at_required_extremes ();
  test_rtl_row_geometry_uses_logical_edges ();
  test_child_count_widths_and_long_parent_source_remain_bounded ();
  test_swipe_delete_wrapper_has_only_square_logical_end_action ();
  test_delete_and_snackbar_tokens_are_explicit_and_accessible ()
;;
