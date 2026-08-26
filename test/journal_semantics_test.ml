module ID = Bonsai_flutter_spec.Id
module Test = Bonsai_flutter_test
module Tokens = Journal_visual_tokens
module Ui = Bonsai_flutter_ui
module Graph = Logseq_db_worker.Graph_types

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

let projected_block ?status_ident ?(source = "Projected status block") () =
  let status_properties =
    match status_ident with
    | None -> []
    | Some ident ->
      [ { Graph.ident = "logseq.property/status"
        ; uuid = Graph.Uuid.of_string "20000000-0000-4000-c000-000000000001" |> require_ok
        ; title = "Status"
        ; schema =
            { property_type = Default; cardinality = One; hidden = false; public = true }
        ; values = [ Default_value ident ]
        ; values_truncated = false
        }
      ]
  in
  let page : Journal_graph_projection.page =
    { id = page_id; day = 20260809; title = "Today" }
  in
  let graph_block : Graph.block =
    { uuid = Graph.Uuid.of_string block_id |> require_ok
    ; title = source
    ; parent = Graph.Uuid.of_string page_id |> require_ok
    ; page = Graph.Uuid.of_string page_id |> require_ok
    ; order = "000000000001"
    ; created_at_ms = 1_786_204_800_000L
    ; updated_at_ms = 1_786_204_800_000L
    ; refs = []
    ; tags = []
    ; properties = status_properties
    }
  in
  Journal_graph_projection.block
    ~page
    ~basis:4L
    ~child_count:0
    ~time_context:{ time_zone_id = "Asia/Shanghai"; utc_offset_seconds = 28_800 }
    graph_block
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
  let toggle =
    handler "row-test-toggle" (fun state -> { state with toggle = state.toggle + 1 })
  in
  Bonsai.Cont.map2 counters toggle ~f:(fun counters toggle ->
    Ui.Widget.Flex.column
      [ Ui.Widget.Flex.fixed
          (Journal_row.view
             ~tokens
             ~typography:(Tokens.typography Tokens.Balanced)
             ~profile
             ~device_pixel_ratio:3.
             ~rtl
             ~item
             ~show_timestamp:true
             ~expanded
             ~show_divider:true
             ~sort_base:0.
             ~reduced_motion:false
             ~on_toggle_children:toggle)
      ; Ui.Widget.Flex.fixed
          (Ui.Widget.text
             (Printf.sprintf "task=%d toggle=%d" counters.task counters.toggle))
      ])
;;

let create_handle
      ?(width = 390.)
      ?(scale = 1.)
      ?(rtl = false)
      ?(expanded = false)
      ?(high_contrast = false)
      item
  =
  let tokens = Tokens.resolve ~high_contrast in
  let profile =
    Tokens.select_row_profile
      ~preset:Tokens.Balanced
      ~viewport_width:width
      ~text_scale:scale
  in
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
  let (Av view) = Ui.Widget.Private.view (node handle test_id).widget in
  match view.node with
  | Ui.Widget.Private.Text { value; _ } ->
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
  | [ node ] ->
    let (Av view) = Ui.Widget.Private.view node.widget in
    (match view.node with
     | Ui.Widget.Private.Semantics
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
         } ->
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
     | _ -> fail "%S is not attached to Semantics" label)
  | [] -> fail "missing semantics label %S\n%s" label (Test.Handle.show handle)
  | matches -> fail "%S has %d duplicate semantic nodes" label (List.length matches)
;;

let require_target handle test_id =
  let (Av view) = Ui.Widget.Private.view (node handle test_id).widget in
  match view.node with
  | Ui.Widget.Private.Constrained_box { min_width; min_height; _ } ->
    require
      (Float.compare min_width 44. >= 0 && Float.compare min_height 44. >= 0)
      "%s is %.1fx%.1f, expected at least 44x44"
      test_id
      min_width
      min_height
  | _ -> fail "%s is not a constrained target" test_id
;;

let require_pressable handle test_id ~release_delay_ms =
  let (Av view) = Ui.Widget.Private.view (node handle test_id).widget in
  match view.node with
  | Ui.Widget.Private.Pressable { overlay_color; release_delay_ms = actual } ->
    require
      (Int32.equal (Ui.Style.Color.Private.to_argb32 overlay_color) 0x00000000l
       && actual = release_delay_ms)
      "%s retains an application-owned pressed color"
      test_id
  | _ -> fail "%s is not Pressable" test_id
;;

let require_sized_width handle test_id expected =
  let (Av view) = Ui.Widget.Private.view (node handle test_id).widget in
  match view.node with
  | Ui.Widget.Private.Sized_box { width = Some actual; _ } ->
    require (Float.equal actual expected) "%s width is %.1f" test_id actual
  | _ -> fail "%s is not a width-constrained SizedBox" test_id
;;

let require_sized_height handle test_id expected =
  let (Av view) = Ui.Widget.Private.view (node handle test_id).widget in
  match view.node with
  | Ui.Widget.Private.Sized_box { height = Some actual; _ } ->
    require (Float.equal actual expected) "%s height is %.1f" test_id actual
  | _ -> fail "%s is not a height-constrained SizedBox" test_id
;;

let require_single_line_start_text handle test_id expected =
  let (Av view) = Ui.Widget.Private.view (node handle test_id).widget in
  match view.node with
  | Ui.Widget.Private.Text
      { value
      ; max_lines = Some 1
      ; overflow = Ui.Style.Text_overflow.Ellipsis
      ; text_align = Ui.Style.Text_align.Start
      ; _
      } -> require (String.equal value expected) "%s text changed" test_id
  | _ -> fail "%s is not one-line, ellipsized, start-aligned Text" test_id
;;

let require_padding handle test_id ~left ~right =
  let (Av view) = Ui.Widget.Private.view (node handle test_id).widget in
  match view.node with
  | Ui.Widget.Private.Padding { left = actual_left; right = actual_right; _ } ->
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

let require_icon handle test_id ~code_point ~color:_ =
  let (Av view) = Ui.Widget.Private.view (node handle test_id).widget in
  match view.node with
  | Ui.Widget.Private.Icon
      { code_point = actual_code_point; font_family = Some "MaterialIcons"; color; _ } ->
    require
      (actual_code_point = code_point && Option.is_none color)
      "%s icon differs or overrides its inherited theme color"
      test_id
  | _ -> fail "%s is not a Material icon" test_id
;;

let require_decoration handle test_id ~background:_ ~border_radius =
  let (Av view) = Ui.Widget.Private.view (node handle test_id).widget in
  match view.node with
  | Ui.Widget.Private.Decorated_box { background = Some _; border_radius = actual_radius }
    -> require (Float.equal actual_radius border_radius) "%s decoration differs" test_id
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
       (let (Av view) =
          Ui.Widget.Private.view
            (node handle ("journal-row-source:" ^ block_id ^ ":0")).widget
        in
        match view.node with
        | Ui.Widget.Private.Text
            { value; max_lines = Some 1; overflow = Ui.Style.Text_overflow.Ellipsis; _ }
          -> require (String.equal value source) "literal source was parsed or changed"
        | _ -> fail "Timeline source is not one-line ellipsized Text");
       require_text handle ("journal-row-time:" ^ block_id) "09:05";
       require_target handle ("journal-row-toggle-children-target:" ^ block_id);
       require
         (Journal_row.Item.source_for_detail item = Some source)
         "Detail lost the complete source";
       let label = source ^ ", status Done, created at 09:05" in
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
       require_text long_handle ("journal-row-source:" ^ block_id ^ ":0") long_source;
       require
         (Journal_row.Item.source_for_detail long_item = Some long_source)
         "long Detail source was truncated";
       require_semantics
         long_handle
         (long_source ^ ", status Done, created at 09:05")
         (fun _ -> ()));
  let missing_time =
    Journal_row.Item.corrupt ~id:"corrupt-time" ~source:(Some "Recovered source")
  in
  let missing_handle, _profile = create_handle missing_time in
  Fun.protect
    ~finally:(fun () -> Test.Handle.shutdown missing_handle)
    (fun () ->
       require_text missing_handle "journal-row-source:corrupt-time:0" "Recovered source";
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
         "journal-row-source:corrupt-source:0"
         "Unavailable journal entry";
       require
         (Journal_row.Item.source_for_detail corrupt = None)
         "corrupt source leaked into Detail";
       require_semantics corrupt_handle "Unavailable journal entry" (fun _ -> ()))
;;

let _test_independent_task_and_row_body_actions () =
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
               (Test.Query.test_id ("journal-row-surface:" ^ block_id))))
         "flat row retained a rounded app-owned surface";
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
         ("test_id=journal-row-time-slot:" ^ block_id);
       require_tree_order
         handle
         ("test_id=journal-row-time-slot:" ^ block_id)
         ("test_id=journal-row-disclosure-icon:" ^ block_id);
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

let _test_conditional_task_leading_slot_and_todo_icon () =
  let plain =
    Journal_row.Item.of_block
      (block ~task_state:Journal_model.No_status ~child_count:0 ())
  in
  let plain_handle, _profile = create_handle plain in
  Fun.protect
    ~finally:(fun () -> Test.Handle.shutdown plain_handle)
    (fun () ->
       let body = node plain_handle ("journal-row-compact:" ^ block_id) in
       require
         (Array.length body.children = 2)
         "plain compact row has unexpected fixed control space";
       (let (Av view) =
          Ui.Widget.Private.view
            (node plain_handle ("journal-row-inline:" ^ block_id)).widget
        in
        match view.node with
        | Ui.Widget.Private.Row
        | Ui.Widget.Private.Column
        | Ui.Widget.Private.Flex_row
        | Ui.Widget.Private.Flex_column -> ()
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
         ~left:32.
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
       let (Av view) =
         Ui.Widget.Private.view
           (node todo_handle ("journal-row-body-content:" ^ block_id)).widget
       in
       match view.node with
       | Ui.Widget.Private.Align _ -> ()
       | _ -> fail "leaf body does not use a bounded center alignment")
;;

let test_four_status_rails_replace_timeline_task_controls () =
  let cases =
    [ "logseq.property/status.todo", "Todo"
    ; "logseq.property/status.doing", "Doing"
    ; "logseq.property/status.done", "Done"
    ; "logseq.property/status.backlog", "Backlog"
    ]
  in
  List.iter
    (fun high_contrast ->
       let colors = ref [] in
       List.iter
         (fun (ident, status_name) ->
            let block = projected_block ~status_ident:ident () in
            let item = Journal_row.Item.of_block block in
            let handle, _profile = create_handle ~high_contrast item in
            Fun.protect
              ~finally:(fun () -> Test.Handle.shutdown handle)
              (fun () ->
                 require_decoration
                   handle
                   ("journal-row-status-rail:" ^ block_id)
                   ~background:0l
                   ~border_radius:2.;
                 (let (Av view) =
                    Ui.Widget.Private.view
                      (node handle ("journal-row-status-rail:" ^ block_id)).widget
                  in
                  match view.node with
                  | Ui.Widget.Private.Decorated_box { background = Some color; _ } ->
                    colors := color :: !colors
                  | _ -> assert false);
                 require_sized_width
                   handle
                   ("journal-row-status-rail-size:" ^ block_id)
                   4.;
                 require
                   (Option.is_none
                      (Test.Handle.find
                         handle
                         (Test.Query.test_id ("journal-row-task:" ^ block_id))))
                   "status rail retained the task press target";
                 require
                   (Option.is_none
                      (Test.Handle.find
                         handle
                         (Test.Query.test_id ("journal-row-task-icon:" ^ block_id))))
                   "status rail retained the task glyph";
                 require_semantics
                   handle
                   ("Projected status block, status " ^ status_name ^ ", created at 00:00")
                   (fun props ->
                      require (props.checked = None) "status rail exposes checkbox state";
                      require
                        (props.actions = [])
                        "status leaf exposes a transparent activation target")))
         cases;
       require
         (List.length (List.sort_uniq Int32.compare !colors) = 4)
         "four status roles are not visually distinguishable in %s presentation"
         (if high_contrast then "high-contrast" else "normal"))
    [ false; true ];
  let plain = Journal_row.Item.of_block (projected_block ()) in
  let status =
    Journal_row.Item.of_block
      (projected_block ~status_ident:"logseq.property/status.doing" ())
  in
  let require_common_leading item =
    let handle, _profile = create_handle item in
    Fun.protect
      ~finally:(fun () -> Test.Handle.shutdown handle)
      (fun () ->
         require_padding
           handle
           ("journal-row-body-padding:" ^ block_id)
           ~left:32.
           ~right:24.)
  in
  require_common_leading plain;
  require_common_leading status
;;

let test_preview_uses_deterministic_one_to_four_logical_lines () =
  let source = "Source one\nSource two" in
  let parent = block ~source () in
  let entry : Journal_graph_projection.timeline_entry =
    { block = parent
    ; child_summaries =
        [ { block_id = "20000000-0000-4000-a000-000000000101"
          ; source = "Child one\nChild two"
          }
        ; { block_id = "20000000-0000-4000-a000-000000000102"; source = "Child three" }
        ]
    }
  in
  let item = Journal_row.Item.of_timeline_entry entry in
  let handle, _profile = create_handle item in
  Fun.protect
    ~finally:(fun () -> Test.Handle.shutdown handle)
    (fun () ->
       require_single_line_start_text
         handle
         ("journal-row-source:" ^ block_id ^ ":0")
         "Source one";
       require_single_line_start_text
         handle
         ("journal-row-source:" ^ block_id ^ ":1")
         "Source two";
       require_single_line_start_text
         handle
         ("journal-row-supporting:" ^ block_id ^ ":0")
         "Child one";
       require_single_line_start_text
         handle
         ("journal-row-supporting:" ^ block_id ^ ":1")
         "Child two";
       require
         (Option.is_none
            (Test.Handle.find handle (Test.Query.visible_text "Child three")))
         "collapsed preview exceeded its four-line budget";
       require_sized_height handle ("journal-row-extent:" ^ block_id) 104.);
  let expanded, _profile = create_handle ~expanded:true item in
  Fun.protect
    ~finally:(fun () -> Test.Handle.shutdown expanded)
    (fun () ->
       require_single_line_start_text
         expanded
         ("journal-row-source:" ^ block_id ^ ":0")
         "Source one";
       require_single_line_start_text
         expanded
         ("journal-row-source:" ^ block_id ^ ":1")
         "Source two";
       require
         (Option.is_none
            (Test.Handle.find expanded (Test.Query.visible_text "Child one")))
         "expanded parent retained collapsed child summaries";
       require_sized_height expanded ("journal-row-extent:" ^ block_id) 60.);
  let five_lines =
    Journal_row.Item.of_block (block ~source:"One\nTwo\nThree\nFour\nFive" ())
  in
  let clamped, _profile = create_handle five_lines in
  Fun.protect
    ~finally:(fun () -> Test.Handle.shutdown clamped)
    (fun () ->
       List.iteri
         (fun index expected ->
            require_single_line_start_text
              clamped
              (Printf.sprintf "journal-row-source:%s:%d" block_id index)
              expected)
         [ "One"; "Two"; "Three"; "Four" ];
       require
         (Option.is_none (Test.Handle.find clamped (Test.Query.visible_text "Five")))
         "source preview exceeded four logical lines";
       require_sized_height clamped ("journal-row-extent:" ^ block_id) 104.)
;;

let test_line_count_drives_exact_scaled_row_extent () =
  let check ~scale expected =
    List.iteri
      (fun offset extent ->
         let line_count = offset + 1 in
         let source =
           List.init line_count (fun index -> Printf.sprintf "Line %d" (index + 1))
           |> String.concat "\n"
         in
         let item = Journal_row.Item.of_block (block ~source ()) in
         let handle, _profile = create_handle ~scale item in
         Fun.protect
           ~finally:(fun () -> Test.Handle.shutdown handle)
           (fun () ->
              require_sized_height handle ("journal-row-extent:" ^ block_id) extent))
      expected
  in
  check ~scale:1. [ 44.; 60.; 82.; 104. ];
  check ~scale:3.2 [ 87.; 157.; 228.; 298. ]
;;

let header_component handlers _graph =
  let on_account_menu =
    Bonsai_flutter.Driver.Handler.create
      handlers
      ~name:"open-account-menu"
      ~equal:(fun () () -> true)
      (Bonsai.Cont.return ())
      ~f:(fun () _ -> Bonsai.Effect.Ignore)
  in
  Bonsai.Cont.map on_account_menu ~f:(fun on_account_menu ->
    Ui.Widget.Scroll_view.vertical
      ~on_scroll:(Ui.Event.Handler.create (fun _ -> ()))
      [ Journal_header.sliver
          ~typography:(Tokens.typography Tokens.Balanced)
          ~text_scale:1.
          ~top_inset:0.
          ~device_pixel_ratio:3.
          ~context:(Journal_header.Context.today ~subtitle:"Sunday, August 9")
          ~on_account_menu:(Some on_account_menu)
      ]
      ()
    |> Ui.Widget.Viewport.Vertical.with_height ~height:144.)
;;

let test_header_account_action_and_view_only_date_have_truthful_semantics () =
  let time_source = Bonsai.Time_source.create ~start:Core.Time_ns.epoch in
  let handle =
    Test.Handle.create
      ~runtime_epoch:(ID.Runtime.Epoch.of_int64 7_002L)
      ~time_source
      header_component
  in
  Fun.protect
    ~finally:(fun () -> Test.Handle.shutdown handle)
    (fun () ->
       Test.Handle.present handle;
       List.iter
         (fun test_id -> ignore (node handle test_id))
         [ "journal-header-leading-placeholder"
         ; "journal-account-menu-target"
         ; "journal-account-menu-button"
         ; "journal-account-icon"
         ];
       require_icon handle "journal-account-icon" ~code_point:0xe043 ~color:0x00000000l;
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
       require_semantics handle "Account menu" (fun props ->
         require (props.role = Ui.Semantics.Role.Button) "account menu is not a button";
         require
           (props.hint = Some "Switch graphs, reset the local copy, or sign out")
           "account menu hint changed";
         require (props.enabled = Some true) "account menu is disabled";
         require (props.focusable = Some true) "account menu is not focusable";
         require
           (List.exists
              (function
                | Ui.Semantics.Action.Tap -> true
                | _ -> false)
              props.actions)
           "account menu has no tap action";
         require (props.sort_key = Some 3.) "account menu semantic order changed");
       require_semantics handle "Today, Sunday, August 9" (fun props ->
         require (props.role = Ui.Semantics.Role.Generic) "date context is still a button";
         require (props.enabled = None) "view-only date exposes enabled state";
         require (props.focusable <> Some true) "view-only date is keyboard focusable";
         require (props.actions = []) "view-only date exposes an activation action";
         require (props.sort_key = Some 2.) "date semantic order changed"))
;;

let require_row_shape width scale expected_kind expected_extent expected_time_width =
  let item = Journal_row.Item.of_block (block ()) in
  let handle, profile = create_handle ~width ~scale item in
  Fun.protect
    ~finally:(fun () -> Test.Handle.shutdown handle)
    (fun () ->
       require
         (Tokens.block_extent ~profile ~visible_lines:1 = expected_extent)
         "profile extent changed";
       (let (Av view) =
          Ui.Widget.Private.view (node handle ("journal-row-extent:" ^ block_id)).widget
        in
        match view.node with
        | Ui.Widget.Private.Sized_box { height = Some height; _ } ->
          require (height = expected_extent) "row extent is %.1f" height
        | _ -> fail "row does not publish an exact extent");
       (let (Av view) =
          Ui.Widget.Private.view (node handle (expected_kind ^ ":" ^ block_id)).widget
        in
        match view.node with
        | Ui.Widget.Private.Row
        | Ui.Widget.Private.Column
        | Ui.Widget.Private.Flex_row
        | Ui.Widget.Private.Flex_column -> ()
        | _ -> fail "%s layout is not a Flex node" expected_kind);
       (let (Av view) =
          Ui.Widget.Private.view
            (node handle ("journal-row-time-slot:" ^ block_id)).widget
        in
        match view.node with
        | Ui.Widget.Private.Constrained_box { min_width; max_width; _ } ->
          require
            (min_width = expected_time_width && max_width = expected_time_width)
            "time slot is %.1f..%.1f, expected %.1f"
            min_width
            max_width
            expected_time_width
        | _ -> fail "time slot is not reserved");
       (let (Av view) =
          Ui.Widget.Private.view
            (node handle ("journal-row-text-stack:" ^ block_id)).widget
        in
        match view.node with
        | Ui.Widget.Private.Row
        | Ui.Widget.Private.Column
        | Ui.Widget.Private.Flex_row
        | Ui.Widget.Private.Flex_column -> ()
        | _ -> fail "top-level content is not a bounded two-line stack");
       let (Av divider_view) =
         Ui.Widget.Private.view (node handle ("journal-row-divider:" ^ block_id)).widget
       in
       (match divider_view.node with
        | Ui.Widget.Private.Material_divider _ -> ()
        | _ -> fail "row separator is not a Material Divider");
       let (Av view) =
         Ui.Widget.Private.view
           (node handle ("journal-row-divider-extent:" ^ block_id)).widget
       in
       match view.node with
       | Ui.Widget.Private.Sized_box { height = Some height; _ } ->
         require
           (Float.equal height (1. /. 3.))
           "row divider is %.3f logical pixels at 3x, expected one physical pixel"
           height
       | _ -> fail "row divider does not publish an exact physical-pixel height")
;;

let test_compact_and_adaptive_shapes_at_required_extremes () =
  require_row_shape 390. 1. "journal-row-compact" 44. 52.;
  require_row_shape 320. 1. "journal-row-adaptive" 44. 52.;
  require_row_shape 744. 2. "journal-row-adaptive" 60. 104.;
  require_row_shape 1_200. 3.2 "journal-row-adaptive" 87. 167.
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
       require_padding
         handle
         ("journal-row-body-padding:" ^ block_id)
         ~left:24.
         ~right:32.;
       require_padding handle ("journal-row-source-gap:" ^ block_id) ~left:8. ~right:0.;
       require_padding
         handle
         ("journal-row-divider-padding:" ^ block_id)
         ~left:0.
         ~right:0.)
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
            require_semantics
              handle
              (source ^ ", status Done, created at 09:05")
              (fun props ->
                 require
                   (props.value = Some "Collapsed")
                   "multi-digit child count lost collapsed state");
            require_tree_order
              handle
              ("test_id=journal-row-source:" ^ block_id)
              ("test_id=journal-row-time-slot:" ^ block_id);
            require_tree_order
              handle
              ("test_id=journal-row-time-slot:" ^ block_id)
              ("test_id=journal-row-disclosure-icon:" ^ block_id);
            require
              (Option.is_none
                 (Test.Handle.find
                    handle
                    (Test.Query.test_id ("journal-row-child-count:" ^ block_id))))
              "row retained the passive child-count badge"))
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
        { Journal_graph_projection.days =
            [ { page = { id = page_id; day = 20260809; title = "Today" }
              ; entries = [ { block; child_summaries = [] } ]
              ; has_more_entries = false
              ; continuation = None
              }
            ]
        ; slot_count = 1
        ; has_more_days = false
        }
    in
    Ui.Widget.Scroll_view.vertical
      ~on_scroll:ignored
      [ Journal_timeline.view
          ~tokens:(Tokens.resolve ~high_contrast:false)
          ~typography:(Tokens.typography Tokens.Balanced)
          ~profile:
            (Tokens.select_row_profile
               ~preset:Tokens.Balanced
               ~viewport_width:390.
               ~text_scale:1.)
          ~device_pixel_ratio:3.
          ~end_padding:0.
          ~rtl:false
          ~state
          ~day_label:(fun _ -> "Today")
          ~reduced_motion:false
          ~delete_enabled
          ~on_delete:ignored
          ~on_visible_range:ignored
          ~on_toggle_children:ignored
      ]
      ()
    |> Ui.Widget.Viewport.Vertical.with_height ~height:600.)
;;

let test_slidable_delete_wrapper_has_only_non_dismissible_logical_end_action () =
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
       require
         (Option.is_none
            (Test.Handle.find handle (Test.Query.test_id "journal-bottom-clearance")))
         "timeline retained obsolete composer bottom clearance";
       let slidable = node handle ("journal-row-slidable:" ^ block_id) in
       (let (Av view) = Ui.Widget.Private.view slidable.widget in
        match view.node with
        | Ui.Widget.Private.Native_widget { kind_id; payload; _ }
          when kind_id = Ui.Native_widget.Slidable.kind_id ->
          let props = Ui.Native_widget.Slidable.For_testing.decode_props_exn payload in
          require props.enabled "delete Slidable is disabled";
          require props.close_on_scroll "delete Slidable remains open while scrolling";
          require
            (props.direction = Ui.Layout.Axis.Horizontal)
            "delete Slidable is not horizontal";
          require props.use_text_direction "delete Slidable ignores text direction";
          require
            (Option.equal String.equal props.group_tag (Some "journal-timeline"))
            "delete Slidable group tag changed";
          require (Option.is_none props.start_action_pane) "start action pane is enabled";
          (match props.end_action_pane with
           | None -> fail "delete Slidable omitted its logical-end pane"
           | Some pane ->
             require (Float.equal pane.extent_ratio 0.25) "delete pane extent changed";
             require (pane.motion = Ui.Native_widget.Slidable.Behind) "delete pane moved";
             require (Option.is_none pane.dismissible) "swipe can dismiss the row";
             require (not pane.drag_dismissible) "full-width drag can dismiss the row";
             require
               (Option.equal Float.equal pane.open_threshold (Some 0.125))
               "delete pane open threshold changed";
             require
               (Option.equal Float.equal pane.close_threshold (Some 0.125))
               "delete pane close threshold changed";
             (match pane.actions with
              | [ action ] ->
                let colors =
                  Tokens.destructive_swipe_action (Tokens.resolve ~high_contrast:false)
                in
                let argb = Ui.Style.Color.Private.to_argb32 in
                require (action.id = 1) "delete action ID changed";
                require action.enabled "delete action is disabled";
                require (action.flex = 1) "delete action flex changed";
                require action.auto_close "delete action does not auto-close";
                require
                  (Int32.equal (argb action.background) (argb colors.background))
                  "delete action background changed";
                require
                  (Option.equal
                     (fun actual expected -> Int32.equal (argb actual) (argb expected))
                     action.foreground
                     (Some colors.foreground))
                  "delete action foreground changed";
                require
                  (Float.equal action.border_radius 0.)
                  "delete action retained rounded corners"
              | actions -> fail "delete pane has %d actions" (List.length actions)))
        | _ -> fail "delete wrapper is not a Slidable");
       List.iter
         (fun edge ->
            let (Av view) =
              Ui.Widget.Private.view
                (node handle ("journal-row-delete-" ^ edge ^ "-divider:" ^ block_id))
                  .widget
            in
            match view.node with
            | Ui.Widget.Private.Material_divider { thickness } ->
              require
                (Float.equal
                   thickness
                   (Tokens.physical_divider_thickness ~device_pixel_ratio:3.))
                "delete %s divider is not one physical pixel"
                edge
            | _ -> fail "delete %s boundary is not a Material divider" edge)
         [ "top"; "bottom" ];
       let surface = node handle ("journal-row-slidable-surface:" ^ block_id) in
       (let (Av view) = Ui.Widget.Private.view surface.widget in
        match view.node with
        | Ui.Widget.Private.Native_widget { kind_id; payload; _ }
          when kind_id = Ui.Native_widget.Morphing_surface.kind_id ->
          let props =
            Ui.Native_widget.Morphing_surface.For_testing.decode_props_exn payload
          in
          require (not props.expanded) "Slidable foreground changed resting geometry"
        | _ -> fail "Slidable foreground is not a theme-owned Material surface");
       (let (Av view) =
          Ui.Widget.Private.view
            (node handle ("journal-row-delete-icon:" ^ block_id)).widget
        in
        match view.node with
        | Ui.Widget.Private.Icon
            { code_point = 0xe1b9; font_family = Some "MaterialIcons"; _ } -> ()
        | Icon _ -> fail "delete feedback does not use the Material delete icon"
        | _ -> fail "delete feedback is not an icon");
       require
         (Option.is_some (Test.Handle.find handle (Test.Query.visible_text "Delete")))
         "delete action omitted its visible label";
       require
         (Option.is_some
            (Test.Handle.find
               handle
               (Test.Query.semantics_label "Delete block and all descendants")))
         "delete action omitted subtree accessibility semantics";
       require
         (Option.is_none
            (Test.Handle.find
               handle
               (Test.Query.test_id ("journal-row-task:" ^ block_id))))
         "swipe row retained a timeline task action";
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
               (Test.Query.test_id ("journal-row-slidable:" ^ block_id))))
         "write-disabled row retained Slidable wrapper")
;;

let () =
  test_literal_source_time_completion_and_full_access ();
  test_long_source_and_corrupt_surfaces ();
  test_four_status_rails_replace_timeline_task_controls ();
  test_preview_uses_deterministic_one_to_four_logical_lines ();
  test_line_count_drives_exact_scaled_row_extent ();
  test_header_account_action_and_view_only_date_have_truthful_semantics ();
  test_compact_and_adaptive_shapes_at_required_extremes ();
  test_rtl_row_geometry_uses_logical_edges ();
  test_child_count_widths_and_long_parent_source_remain_bounded ();
  test_slidable_delete_wrapper_has_only_non_dismissible_logical_end_action ()
;;
