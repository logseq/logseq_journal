module Graph_service = Logseq_db_worker_bonsai.Logseq_db_worker_bonsai_service
module ID = Bonsai_flutter_spec.Id
module Protocol = Bonsai_flutter_protocol
module Test = Bonsai_flutter_test
module Tokens = Journal_visual_tokens
module Ui = Bonsai_flutter_ui
module Graph = Logseq_db_types.Graph_types

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
    ~revision:"block-4"
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
    ~revision:"block-4"
    ~child_count:0
    ~time_context:{ localtime = (fun seconds -> Unix.gmtime (seconds +. 28_800.)) }
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
  let tokens =
    Tokens.resolve ~brightness:Bonsai_flutter.Environment.Light ~high_contrast
  in
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
  match
    Test.Handle.find_all
      handle
      (if String.equal label "2026.08.09"
       then Test.Query.test_id "journal-date-context"
       else Test.Query.semantics_label label)
  with
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

let require_clipped_text handle test_id ~expected ~max_lines =
  let (Av view) = Ui.Widget.Private.view (node handle test_id).widget in
  match view.node with
  | Ui.Widget.Private.Text
      { value
      ; max_lines = Some actual_max_lines
      ; overflow = Ui.Style.Text_overflow.Clip
      ; text_align = Ui.Style.Text_align.Start
      ; _
      } ->
    require
      (String.equal value expected && actual_max_lines = max_lines)
      "%s text or max-lines changed"
      test_id
  | _ -> fail "%s is not clipped, start-aligned Text" test_id
;;

let require_tail_fade handle test_id ~line_height ~fade_width =
  let (Av view) = Ui.Widget.Private.view (node handle test_id).widget in
  match view.node with
  | Ui.Widget.Private.Native_widget { kind_id; version; capabilities; payload } ->
    require
      (Bonsai_flutter_spec.Id.Native_widget.Kind_id.to_int kind_id = 1001)
      "%s uses native widget kind %d"
      test_id
      (Bonsai_flutter_spec.Id.Native_widget.Kind_id.to_int kind_id);
    require (version = 1 && Int64.equal capabilities 0L) "%s protocol changed" test_id;
    require
      (Bytes.length payload = 16)
      "%s payload has %d bytes"
      test_id
      (Bytes.length payload);
    require
      (Float.equal (Int64.float_of_bits (Bytes.get_int64_le payload 0)) line_height
       && Float.equal (Int64.float_of_bits (Bytes.get_int64_le payload 8)) fade_width)
      "%s fade geometry changed"
      test_id
  | _ -> fail "%s is not the native trailing-edge fade" test_id
;;

let require_alignment handle test_id expected =
  let (Av view) = Ui.Widget.Private.view (node handle test_id).widget in
  match view.node with
  | Ui.Widget.Private.Align { alignment } ->
    require (alignment = expected) "%s alignment changed" test_id
  | _ -> fail "%s is not Align" test_id
;;

let require_opacity handle test_id expected =
  let (Av view) = Ui.Widget.Private.view (node handle test_id).widget in
  match view.node with
  | Ui.Widget.Private.Opacity { opacity } ->
    require (Float.equal opacity expected) "%s opacity is %.2f" test_id opacity
  | _ -> fail "%s is not Opacity" test_id
;;

let require_text_style handle test_id ~font_size ~line_height =
  let (Av view) = Ui.Widget.Private.view (node handle test_id).widget in
  match view.node with
  | Ui.Widget.Private.Text { style = Some style; _ } ->
    require
      (style.font_size = Some font_size && style.line_height = Some line_height)
      "%s typography changed"
      test_id
  | _ -> fail "%s is not styled Text" test_id
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
          Ui.Widget.Private.view (node handle ("journal-row-source:" ^ block_id)).widget
        in
        match view.node with
        | Ui.Widget.Private.Text
            { value; max_lines = Some 3; overflow = Ui.Style.Text_overflow.Clip; _ } ->
          require (String.equal value source) "literal source was parsed or changed"
        | _ -> fail "Timeline source is not three-line clipped Text");
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
       require_clipped_text
         long_handle
         ("journal-row-source:" ^ block_id)
         ~expected:long_source
         ~max_lines:3;
       require_tail_fade
         long_handle
         ("journal-row-source-tail-fade:" ^ block_id)
         ~line_height:22.
         ~fade_width:24.;
       require_sized_height long_handle ("journal-row-extent:" ^ block_id) 78.;
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
    [ "logseq.property/status.todo", "Todo", 0xff585c7el
    ; "logseq.property/status.doing", "Doing", 0xff00677cl
    ; "logseq.property/status.done", "Done", 0xff006b57l
    ; "logseq.property/status.backlog", "Backlog", 0xff7c3aedl
    ]
  in
  List.iter
    (fun high_contrast ->
       let colors = ref [] in
       List.iter
         (fun (ident, status_name, expected_background) ->
            let block = projected_block ~status_ident:ident () in
            let item = Journal_row.Item.of_block block in
            let handle, _profile = create_handle ~high_contrast item in
            Fun.protect
              ~finally:(fun () -> Test.Handle.shutdown handle)
              (fun () ->
                 let rail_id = "journal-row-status-rail:" ^ block_id in
                 if String.equal status_name "Todo"
                 then (
                   let (Av view) = Ui.Widget.Private.view (node handle rail_id).widget in
                   match view.node with
                   | Ui.Widget.Private.Column -> ()
                   | _ -> fail "TODO rail must contain bounded dash segments");
                 let decoration_id =
                   if String.equal status_name "Todo"
                   then rail_id ^ ":segment:0"
                   else rail_id
                 in
                 require_decoration handle decoration_id ~background:0l ~border_radius:2.;
                 (let (Av view) =
                    Ui.Widget.Private.view (node handle decoration_id).widget
                  in
                  match view.node with
                  | Ui.Widget.Private.Decorated_box { background = Some color; _ } ->
                    let actual = color in
                    require
                      (Int32.equal actual expected_background)
                      "%s rail background is %lx, expected %lx"
                      status_name
                      actual
                      expected_background;
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

let test_title_and_children_have_independent_bounded_tail_fade_previews () =
  let source = "Source one\nSource two\nSource three\nSource four" in
  let parent = block ~source () in
  let entry : Journal_graph_projection.timeline_entry =
    { block = parent
    ; child_summaries =
        [ { block_id = "20000000-0000-4000-a000-000000000101"; source = "Child one" }
        ; { block_id = "20000000-0000-4000-a000-000000000102"; source = "Child two" }
        ; { block_id = "20000000-0000-4000-a000-000000000103"; source = "Child three" }
        ]
    }
  in
  let item = Journal_row.Item.of_timeline_entry entry in
  let handle, _profile = create_handle item in
  Fun.protect
    ~finally:(fun () -> Test.Handle.shutdown handle)
    (fun () ->
       require_clipped_text
         handle
         ("journal-row-source:" ^ block_id)
         ~expected:source
         ~max_lines:3;
       require_tail_fade
         handle
         ("journal-row-source-tail-fade:" ^ block_id)
         ~line_height:22.
         ~fade_width:24.;
       require_clipped_text
         handle
         ("journal-row-supporting:" ^ block_id ^ ":0")
         ~expected:"Child one"
         ~max_lines:1;
       require_clipped_text
         handle
         ("journal-row-supporting:" ^ block_id ^ ":1")
         ~expected:"Child two"
         ~max_lines:1;
       require_tail_fade
         handle
         ("journal-row-supporting-tail-fade:" ^ block_id ^ ":1")
         ~line_height:20.
         ~fade_width:21.;
       require_opacity handle ("journal-row-supporting-opacity:" ^ block_id ^ ":0") 0.65;
       require_opacity handle ("journal-row-supporting-opacity:" ^ block_id ^ ":1") 0.65;
       require_text_style
         handle
         ("journal-row-supporting:" ^ block_id ^ ":0")
         ~font_size:14.
         ~line_height:(20. /. 14.);
       require
         (Option.is_none
            (Test.Handle.find handle (Test.Query.visible_text "Child three")))
         "collapsed preview exceeded its two child-line budget";
       require_sized_height handle ("journal-row-supporting-gap:" ^ block_id) 4.;
       require_alignment
         handle
         ("journal-row-metadata-align:" ^ block_id)
         Ui.Layout.Alignment.Top_end;
       require_sized_height handle ("journal-row-extent:" ^ block_id) 126.);
  let expanded, _profile = create_handle ~expanded:true item in
  Fun.protect
    ~finally:(fun () -> Test.Handle.shutdown expanded)
    (fun () ->
       require_clipped_text
         expanded
         ("journal-row-source:" ^ block_id)
         ~expected:source
         ~max_lines:3;
       require
         (Option.is_none
            (Test.Handle.find expanded (Test.Query.visible_text "Child one")))
         "expanded parent retained collapsed child summaries";
       require_sized_height expanded ("journal-row-extent:" ^ block_id) 78.)
;;

let test_wrapping_estimate_bounds_latin_cjk_emoji_and_explicit_lines () =
  let cases =
    [ String.make 240 'W'
    ; String.concat "" (List.init 80 (fun _ -> "你"))
    ; String.concat "" (List.init 80 (fun _ -> "🙂"))
    ; "One\nTwo\nThree\nFour\nFive"
    ]
  in
  List.iter
    (fun source ->
       let item = Journal_row.Item.of_block (block ~source ()) in
       let handle, _profile = create_handle ~width:320. item in
       Fun.protect
         ~finally:(fun () -> Test.Handle.shutdown handle)
         (fun () ->
            require_clipped_text
              handle
              ("journal-row-source:" ^ block_id)
              ~expected:source
              ~max_lines:3;
            require_tail_fade
              handle
              ("journal-row-source-tail-fade:" ^ block_id)
              ~line_height:22.
              ~fade_width:24.;
            require_sized_height handle ("journal-row-extent:" ^ block_id) 78.))
    cases;
  let exact = Journal_row.Item.of_block (block ~source:"One\nTwo\nThree" ()) in
  let exact_handle, _profile = create_handle ~width:320. exact in
  Fun.protect
    ~finally:(fun () -> Test.Handle.shutdown exact_handle)
    (fun () ->
       require_clipped_text
         exact_handle
         ("journal-row-source:" ^ block_id)
         ~expected:"One\nTwo\nThree"
         ~max_lines:3;
       require
         (Option.is_none
            (Test.Handle.find
               exact_handle
               (Test.Query.test_id ("journal-row-source-tail-fade:" ^ block_id))))
         "an exactly three-line title incorrectly advertises hidden content")
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
  check ~scale:1. [ 44.; 56.; 78.; 78. ];
  check ~scale:3.2 [ 153.; 224.; 224.; 224. ]
;;

let header_component sync_phase handlers _graph =
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
          ~viewport_width:390.
          ~tokens:
            (Tokens.resolve
               ~brightness:Bonsai_flutter.Environment.Light
               ~high_contrast:false)
          ~typography:(Tokens.typography Tokens.Balanced)
          ~text_scale:1.
          ~top_inset:0.
          ~device_pixel_ratio:3.
          ~context:
            (Journal_header.Context.today
               ~date:(Journal_calendar.present_journal_day 20260809 |> Result.to_option))
          ~sync_phase
          ~on_error_info:None
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
      (header_component None)
  in
  Fun.protect
    ~finally:(fun () -> Test.Handle.shutdown handle)
    (fun () ->
       Test.Handle.present handle;
       (let (Av header_view) =
          Ui.Widget.Private.view (node handle "journal-header").widget
        in
        match header_view.node with
        | Ui.Widget.Private.Sliver_app_bar
            { pinned = true
            ; floating = false
            ; snap = false
            ; center_title = true
            ; expanded_height = Some 64.
            ; collapsed_height = Some 64.
            ; toolbar_height = 56.
            ; _
            } -> ()
        | Sliver_app_bar _ ->
          fail "Journal header does not use the selected Material app-bar configuration"
        | _ -> fail "Journal header is not a Material sliver app bar");
       List.iter
         (fun test_id -> ignore (node handle test_id))
         [ "journal-header-leading-placeholder"
         ; "journal-account-menu-target"
         ; "journal-account-menu-button"
         ; "journal-account-icon"
         ];
       require_icon handle "journal-account-icon" ~code_point:0xe043 ~color:0x00000000l;
       require
         (Option.is_some (Test.Handle.find handle (Test.Query.visible_text "2026.08.09")))
         "Journal header lost its visible date context";
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
           (props.hint = Some "Switch graphs, delete the local copy, or sign out")
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
         require (props.sort_key = Some 4.) "account menu semantic order changed");
       require_semantics handle "2026.08.09" (fun props ->
         require (props.role = Ui.Semantics.Role.Generic) "date context is still a button";
         require (props.enabled = None) "view-only date exposes enabled state";
         require (props.focusable <> Some true) "view-only date is keyboard focusable";
         require (props.actions = []) "view-only date exposes an activation action";
         require (props.sort_key = Some 2.) "date semantic order changed"))
;;

let test_header_sync_progress_tracks_every_sync_phase () =
  let render sync_phase =
    let time_source = Bonsai.Time_source.create ~start:Core.Time_ns.epoch in
    let handle =
      Test.Handle.create
        ~runtime_epoch:(ID.Runtime.Epoch.of_int64 7_003L)
        ~time_source
        (header_component sync_phase)
    in
    Test.Handle.present handle;
    handle
  in
  let progress_id = "journal-header-sync-progress" in
  List.iter
    (fun sync_phase ->
       let handle = render sync_phase in
       Fun.protect
         ~finally:(fun () -> Test.Handle.shutdown handle)
         (fun () ->
            let connecting = sync_phase = Some Graph_service.Connecting in
            let (Av header) =
              Ui.Widget.Private.view (node handle "journal-header").widget
            in
            (match header.node with
             | Ui.Widget.Private.Sliver_app_bar
                 { has_bottom = true; bottom_height = Some 2.; _ } -> ()
             | _ -> fail "every sync phase must reserve a two-pixel app-bar bottom");
            let (Av bottom) =
              Ui.Widget.Private.view
                header.children.(Array.length header.children - 1).widget
            in
            (match connecting, bottom.node with
             | true, Ui.Widget.Private.Clip _ ->
               let (Av progress) = Ui.Widget.Private.view bottom.children.(0).widget in
               (match progress.node with
                | Ui.Widget.Private.Material_linear_progress_indicator
                    { value = None; wavy = false } -> ()
                | _ -> fail "connecting bottom must contain flat indeterminate progress")
             | false, Ui.Widget.Private.Empty -> ()
             | _ ->
               fail
                 "app-bar bottom must clip connecting progress or contain an empty widget");
            require
              (List.length (Test.Handle.find_all handle (Test.Query.test_id progress_id))
               = if connecting then 1 else 0)
              "progress visibility must match exactly Connecting";
            require
              (Option.is_some
                 (Test.Handle.find handle (Test.Query.visible_text "2026.08.09")))
              "sync phase changed the date-only title"))
    [ None
    ; Some Graph_service.Connecting
    ; Some Offline
    ; Some Pulling
    ; Some Submitting
    ; Some Current
    ; Some Paused
    ; Some Failed
    ]
;;

let export_timeline_preview directory =
  let render ~width ~scale ~high_contrast ~dark ~rtl ~preset =
    let make_block ~day ~ordinal ~parent_id ~child_count ~task_state source =
      Journal_model.create
        ~id:(Printf.sprintf "30000000-0000-4000-a000-%012d" ordinal)
        ~page_id:(Printf.sprintf "30000000-0000-4000-b000-%012d" day)
        ~journal_day:day
        ~parent_id
        ~sibling_order:(Printf.sprintf "%012d" ordinal)
        ~source
        ~task_state
        ~child_count
        ~creation_time:
          (Journal_time.create
             ~instant_unix_ms:1788652800000L
             ~local_day:day
             ~local_minute_of_day:545
           |> require_ok)
        ~revision:"preview-revision"
        ~last_mutation_id:mutation_id
      |> require_ok
    in
    let root =
      make_block
        ~day:20260906
        ~ordinal:1
        ~parent_id:None
        ~child_count:1
        ~task_state:Journal_model.Todo
        "Plan the week\nChoose one small next step"
    in
    let child =
      make_block
        ~day:20260906
        ~ordinal:2
        ~parent_id:(Some (Journal_model.id root))
        ~child_count:0
        ~task_state:Journal_model.Todo
        "Review the notes"
    in
    let older =
      make_block
        ~day:20260905
        ~ordinal:3
        ~parent_id:None
        ~child_count:0
        ~task_state:Journal_model.Done
        "A quiet afternoon walk"
    in
    let day day entries more : Journal_graph_projection.day_feed =
      { page =
          { id = Printf.sprintf "30000000-0000-4000-b000-%012d" day
          ; day
          ; title = "Journal"
          }
      ; entries =
          List.map
            (fun block -> { Journal_graph_projection.block; child_summaries = [] })
            entries
      ; has_more_entries = more
      ; continuation = None
      }
    in
    let state =
      Journal_timeline_state.empty ~today:20260906
      |> fun state ->
      Journal_timeline_state.begin_request
        state
        ~generation:1L
        (Feed { before_day = None })
      |> fun state ->
      Journal_timeline_state.apply_feed
        state
        ~generation:1L
        { days =
            [ day 20260906 [ root ] false
            ; day 20260905 [ older ] false
            ; day 20260904 [] false
            ; day 20260903 [] false
            ; day 20260902 [] true
            ]
        ; slot_count = 8
        ; has_more_days = false
        }
      |> fun state ->
      Journal_timeline_state.expand state ~parent_id:(Journal_model.id root)
      |> fun state ->
      Journal_timeline_state.reconcile_detail
        state
        { root; children = { blocks = [ child ]; continuation = None } }
    in
    let component handlers _graph =
      let ignored =
        Bonsai_flutter.Driver.Handler.create
          handlers
          ~name:"preview"
          ~equal:(fun () () -> true)
          (Bonsai.Cont.return ())
          ~f:(fun () _ -> Bonsai.Effect.Ignore)
      in
      Bonsai.Cont.map ignored ~f:(fun ignored ->
        let tokens =
          Tokens.resolve
            ~brightness:(if dark then Bonsai_flutter.Environment.Dark else Light)
            ~high_contrast
        in
        let typography = Tokens.typography preset in
        Ui.Widget.Scroll_view.vertical
          ~on_scroll:ignored
          [ Journal_header.sliver
              ~tokens
              ~typography
              ~text_scale:scale
              ~viewport_width:width
              ~top_inset:0.
              ~device_pixel_ratio:1.
              ~context:
                (Journal_header.Context.today
                   ~date:
                     (Journal_calendar.present_journal_day 20260906 |> Result.to_option))
              ~sync_phase:None
              ~on_error_info:None
              ~on_account_menu:(Some ignored)
          ; Journal_timeline.view
              ~tokens
              ~typography
              ~profile:
                (Tokens.select_row_profile
                   ~preset
                   ~viewport_width:width
                   ~text_scale:scale)
              ~device_pixel_ratio:1.
              ~end_padding:0.
              ~rtl
              ~state
              ~day_presentation:(fun day ->
                Journal_calendar.present_journal_day day |> Result.to_option)
              ~reduced_motion:true
              ~on_visible_range:ignored
              ~on_retry_day:ignored
              ~on_toggle_children:ignored
              ~delete_enabled:false
              ~actions_enabled:false
              ~on_status:ignored
              ~on_delete:ignored
          ]
          ()
        |> Ui.Widget.Viewport.Vertical.with_height ~height:844.)
    in
    let handle =
      Test.Handle.create
        ~runtime_epoch:(ID.Runtime.Epoch.of_int64 7009L)
        ~time_source:(Bonsai.Time_source.create ~start:Core.Time_ns.epoch)
        component
    in
    Fun.protect
      ~finally:(fun () -> Test.Handle.shutdown handle)
      (fun () ->
         Test.Handle.present handle;
         let path =
           Filename.concat
             directory
             (Printf.sprintf
                "timeline-%g-%g-%b-%b-%b-%s.bin"
                width
                scale
                high_contrast
                dark
                rtl
                (Tokens.stored_value_of_typography_preset preset))
         in
         let channel = open_out_bin path in
         Fun.protect
           ~finally:(fun () -> close_out channel)
           (fun () ->
              output_bytes channel (Option.get (Test.Handle.last_frame handle)).bytes))
  in
  List.iter
    (fun dark ->
       List.iter
         (fun high_contrast ->
            List.iter
              (fun (width, scale, rtl) ->
                 List.iter
                   (fun preset -> render ~width ~scale ~high_contrast ~dark ~rtl ~preset)
                   [ Tokens.Dense; Balanced; Comfortable ])
              [ 390., 1., false; 320., 3.2, true ])
         [ false; true ])
    [ false; true ]
;;

(* Export real application header frames for Flutter renderer geometry tests. *)
let export_header_frames directory =
  let export width scale high_contrast =
    let phases =
      [| None; Some Graph_service.Connecting; Some Current; Some Connecting; None |]
    in
    List.iter
      (fun with_error ->
         let component handlers graph =
           let index, set_index = Bonsai_v017.state ~equal:Int.equal 0 graph in
           let next =
             Bonsai_flutter.Driver.Handler.create
               handlers
               ~name:"next-header-phase"
               ~equal:( == )
               set_index
               ~f:(fun set_index _ -> set_index (fun index -> index + 1))
           in
           Bonsai.Cont.map2 index next ~f:(fun index next ->
             Ui.Widget.Scroll_view.vertical
               ~on_scroll:(Ui.Event.Handler.create (fun _ -> ()))
               [ Journal_header.sliver
                   ~viewport_width:width
                   ~tokens:
                     (Tokens.resolve
                        ~brightness:Bonsai_flutter.Environment.Light
                        ~high_contrast)
                   ~typography:(Tokens.typography Tokens.Balanced)
                   ~text_scale:scale
                   ~top_inset:0.
                   ~device_pixel_ratio:1.
                   ~context:
                     (Journal_header.Context.today
                        ~date:
                          (Journal_calendar.present_journal_day 20260809
                           |> Result.to_option))
                   ~sync_phase:phases.(index)
                   ~on_error_info:(if with_error then Some next else None)
                   ~on_account_menu:(Some next)
               ; Ui.Widget.text "Timeline anchor" |> Ui.Widget.Sliver.box
               ; Ui.Widget.empty ()
                 |> Ui.Widget.sized_box ~height:2000.
                 |> Ui.Widget.Sliver.box
               ]
               ()
             |> Ui.Widget.Viewport.Vertical.with_height ~height:600.)
         in
         let handle =
           Test.Handle.create
             ~runtime_epoch:(ID.Runtime.Epoch.of_int64 7_008L)
             ~time_source:(Bonsai.Time_source.create ~start:Core.Time_ns.epoch)
             component
         in
         Fun.protect
           ~finally:(fun () -> Test.Handle.shutdown handle)
           (fun () ->
              Test.Handle.present handle;
              Array.iteri
                (fun index _ ->
                   Test.Handle.present handle;
                   if index > 0
                   then
                     Test.Handle.click
                       handle
                       (Test.Query.test_id "journal-account-menu-button");
                   let frame = Option.get (Test.Handle.last_frame handle) in
                   let path =
                     Filename.concat
                       directory
                       (Printf.sprintf
                          "header-%g-%g-%b-%s-%d.bin"
                          width
                          scale
                          high_contrast
                          (if with_error then "error" else "account")
                          index)
                   in
                   let channel = open_out_bin path in
                   Fun.protect
                     ~finally:(fun () -> close_out channel)
                     (fun () -> output_bytes channel frame.bytes))
                phases))
      [ false; true ]
  in
  List.iter
    (fun high_contrast ->
       List.iter
         (fun (width, scale) -> export width scale high_contrast)
         [ 390., 1.; 320., 1.; 320., 3.2 ])
    [ false; true ]
;;

let require_row_shape width scale expected_kind expected_extent expected_time_width =
  let item = Journal_row.Item.of_block (block ~source:"Short" ()) in
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
        | Ui.Widget.Private.Constrained_box { min_width; max_width = Some max_width; _ }
          ->
          require
            (min_width = expected_time_width && max_width = expected_time_width)
            "time slot is %.1f..%.1f, expected %.1f"
            min_width
            max_width
            expected_time_width
        | Ui.Widget.Private.Constrained_box { max_width = None; _ } ->
          fail "time slot has no maximum width"
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
        | _ -> fail "top-level content is not a bounded preview stack");
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
  require_row_shape 744. 2. "journal-row-adaptive" 56. 104.;
  require_row_shape 1_200. 3.2 "journal-row-adaptive" 83. 167.
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
       require_alignment
         handle
         ("journal-row-metadata-align:" ^ block_id)
         Ui.Layout.Alignment.Top_start;
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

let delete_timeline_component
      ?(task_state = Journal_model.Done)
      ~delete_enabled
      handlers
      _graph
  =
  let ignored =
    Bonsai_flutter.Driver.Handler.create
      handlers
      ~name:"delete-timeline-ignored"
      ~equal:(fun () () -> true)
      (Bonsai.Cont.return ())
      ~f:(fun () _ -> Bonsai.Effect.Ignore)
  in
  Bonsai.Cont.map ignored ~f:(fun ignored ->
    let block = block ~task_state () in
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
          ~tokens:
            (Tokens.resolve
               ~brightness:Bonsai_flutter.Environment.Light
               ~high_contrast:false)
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
          ~on_retry_day:(Ui.Event.Handler.create (fun _ -> ()))
          ~day_presentation:(fun day ->
            Journal_calendar.present_journal_day day |> Result.to_option)
          ~reduced_motion:false
          ~delete_enabled
          ~actions_enabled:delete_enabled
          ~on_status:ignored
          ~on_delete:ignored
          ~on_visible_range:ignored
          ~on_toggle_children:ignored
      ]
      ()
    |> Ui.Widget.Viewport.Vertical.with_height ~height:600.)
;;

let test_non_picker_exact_statuses_remain_readable_on_the_status_button () =
  List.iter
    (fun (task_state, expected_background, expected_icon) ->
       let handle =
         Test.Handle.create
           ~runtime_epoch:(ID.Runtime.Epoch.of_int64 7_002L)
           ~time_source:(Bonsai.Time_source.create ~start:Core.Time_ns.epoch)
           (delete_timeline_component ~task_state ~delete_enabled:true)
       in
       Fun.protect
         ~finally:(fun () -> Test.Handle.shutdown handle)
         (fun () ->
            Test.Handle.present handle;
            require_semantics
              handle
              ("Change status, current status " ^ Journal_model.status_name task_state)
              (fun props ->
                 require (props.role = Ui.Semantics.Role.Button) "status role changed";
                 require (props.enabled = Some true) "status button is disabled");
            require_text
              handle
              ("journal-row-status-action-label:" ^ block_id)
              (Journal_model.status_name task_state);
            let (Av icon) =
              Ui.Widget.Private.view
                (node handle ("journal-row-status-action-icon:" ^ block_id)).widget
            in
            (match icon.node with
             | Ui.Widget.Private.Icon { code_point; _ } ->
               require
                 (code_point = expected_icon)
                 "%s status icon changed"
                 (Journal_model.status_name task_state)
             | _ ->
               fail "%s status action has no icon" (Journal_model.status_name task_state));
            let (Av slidable) =
              Ui.Widget.Private.view
                (node handle ("journal-row-slidable:" ^ block_id)).widget
            in
            match slidable.node with
            | Ui.Widget.Private.Native_widget { payload; _ } ->
              let props =
                Ui.Native_widget.Slidable.For_testing.decode_props_exn payload
              in
              (match props.start_action_pane with
               | Some { actions = [ action ]; _ } ->
                 require
                   (Int32.equal
                      (Ui.Style.Color.Private.to_argb32 action.background)
                      expected_background)
                   "%s status category color changed"
                   (Journal_model.status_name task_state)
               | None | Some _ -> fail "status pane does not contain exactly one action")
            | _ -> fail "status row is not a Slidable"))
    [ Journal_model.Now, 0xff00677cl, 0xe660
    ; Waiting, 0xff7c3aedl, 0xe660
    ; Later, 0xff7c3aedl, 0xe504
    ]
;;

let test_slidable_has_one_exact_status_button_and_non_dismissible_delete_action () =
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
       let icon_test_id = "journal-row-status-action-icon:" ^ block_id in
       let (Av icon_view) = Ui.Widget.Private.view (node handle icon_test_id).widget in
       (match icon_view.node with
        | Ui.Widget.Private.Icon { code_point; font_family = Some font_family; _ } ->
          require
            (code_point = 0xe15a)
            "%s rendered U+%04X instead of Done U+E15A"
            icon_test_id
            code_point;
          require
            (String.equal font_family "MaterialIcons")
            "%s does not use MaterialIcons"
            icon_test_id
        | _ -> fail "%s is not a Material icon" icon_test_id);
       require_semantics handle "Change status, current status Done" (fun props ->
         require (props.role = Ui.Semantics.Role.Button) "status action role changed";
         require (props.enabled = Some true) "status action is not enabled";
         require (props.focusable = Some true) "status action is not focusable");
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
          (match props.start_action_pane with
           | None -> fail "status Slidable omitted its logical-start pane"
           | Some pane ->
             require (Float.equal pane.extent_ratio 0.25) "status pane extent changed";
             require (pane.motion = Ui.Native_widget.Slidable.Behind) "status pane moved";
             require (Option.is_none pane.dismissible) "status swipe can dismiss the row";
             require
               (not pane.drag_dismissible)
               "full-width status drag can dismiss the row";
             (match pane.actions with
              | [ action ] ->
                let argb = Ui.Style.Color.Private.to_argb32 in
                require (action.id = 6) "status button retained an obsolete action ID";
                require action.enabled "status button is disabled for the current state";
                require action.auto_close "status button does not auto-close";
                require
                  (Float.equal action.border_radius 0.)
                  "status button retained rounded corners";
                require
                  (Option.is_none action.padding)
                  "status button retained inset card spacing";
                require
                  (Option.equal
                     Int32.equal
                     (Option.map argb action.foreground)
                     (Some 0xffffffffl))
                  "Done status button foreground differs";
                require
                  (Int32.equal (argb action.background) 0xff006b57l)
                  "Done status button background differs"
              | actions ->
                fail "status pane has %d actions instead of one" (List.length actions)));
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
                  Tokens.destructive_swipe_action
                    (Tokens.resolve
                       ~brightness:Bonsai_flutter.Environment.Light
                       ~high_contrast:false)
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
            | Ui.Widget.Private.Material_divider { thickness; _ } ->
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

let warm_start_test_service () =
  Worker.Service.create
    ~push_topic_count:5
    ~concurrency:Worker.Service.Serial
    ~init:(fun _context (_config : Journal_startup.t) -> Ok ())
    ~handle:(fun _context () request ->
      match (request : Graph_service.request) with
      | Get_graph_state ->
        Ok
          (Graph_service.Graph_state
             { generation = 0; graph_id = None; phase = Graph_closed; error = None })
      | Client_command _ -> Ok Client_command_completed
      | Graph_request request ->
        let error =
          Logseq_db_worker.Error.create
            ~code:Closed_session
            ~message:"The test graph is closed."
            ~details:[]
          |> Result.get_ok
        in
        Ok
          (Graph_response
             (Logseq_db_worker.Protocol.failed ~request_id:request.request_id error)))
    ~shutdown:(fun () -> ())
    ()
;;

let warm_start_application_payload () =
  Logseq_db_worker.Config.create
    ~application_support_directory:"/tmp/logseq-journal-warm-start-ordering"
    ~target:(Managed_sync { base_url = "https://api.logseq.io" })
    ~compatibility_profile:Logseq_65_33_or_newer
    ~response_budget_bytes:Logseq_db_worker.Protocol.maximum_response_bytes
    ~default_page_size:Logseq_db_worker.Protocol.default_page_size
  |> Result.get_ok
  |> Journal_startup.encode
  |> Result.fold ~ok:Fun.id ~error:(fun error ->
    fail "%s" (Journal_startup.Error.to_string error))
;;

let application_requests handle =
  match Test.Handle.last_frame handle with
  | None -> fail "warm-start application emitted no frame"
  | Some frame ->
    (match Bonsai_flutter_protocol.Binary_codec.decode frame.bytes with
     | Error error -> fail "warm-start frame did not decode: %s" error.message
     | Ok wire ->
       List.filter_map
         (function
           | Bonsai_flutter_protocol.Wire_frame.Application_request
               { request_id; payload } -> Some (request_id, payload)
           | _ -> None)
         wire.operations)
;;

let request_id_for_payload requests payload =
  List.find_map
    (fun (request_id, request_payload) ->
       if Bytes.equal request_payload payload then Some request_id else None)
    requests
;;

let network_lifecycle_packet ~kind ~generation =
  let payload = Bytes.make 16 '\000' in
  Bytes.blit_string "LJP1" 0 payload 0 4;
  Bytes.set_uint16_le payload 4 1;
  Bytes.set_uint16_le payload 6 kind;
  Bytes.set_int64_le payload 8 generation;
  let envelope = Bytes.make 48 '\000' in
  Bytes.blit_string "LJP2" 0 envelope 0 4;
  Bytes.set_uint16_le envelope 4 2;
  Bytes.set_uint16_le envelope 6 15;
  Bytes.set_int32_le envelope 24 16l;
  Bytes.blit payload 0 envelope 32 16;
  envelope
;;

let application_event_batch ~runtime_epoch ~revision ~sequence payload =
  Protocol.Inbound_event.
    { runtime_epoch
    ; events =
        [ { sequence = ID.Runtime.Event_sequence.of_int64 sequence
          ; displayed_revision = revision
          ; node_id = ID.Ui.Node_id.zero
          ; handler_id = ID.Ui.Handler_id.zero
          ; event_tag = Protocol.Generated_protocol.Event_tag.application_event
          ; payload = Application_event payload
          }
        ]
    }
;;

let with_warm_start_app ?calendar_sampler runtime_epoch run =
  let handle =
    Test.Handle.create_app
      ~runtime_epoch
      ~time_source:(Bonsai.Time_source.create ~start:Core.Time_ns.epoch)
      (Application.For_testing.app_with_service
         ?calendar_sampler
         (warm_start_test_service ()))
      ~application_payload:(warm_start_application_payload ())
  in
  Fun.protect ~finally:(fun () -> Test.Handle.shutdown handle) (fun () -> run handle)
;;

let test_warm_start_samples_calendar_before_requesting_local_binding () =
  let runtime_epoch = ID.Runtime.Epoch.of_int64 7_005L in
  let calendar_sampler =
    Journal_calendar.Sampler.create
      ~clock:(fun () -> 1_788_508_800.)
      ~localtime:(fun seconds -> Unix.gmtime (seconds +. 28_800.))
      ()
  in
  with_warm_start_app ~calendar_sampler runtime_epoch (fun handle ->
    let initial_requests = application_requests handle in
    require
      (Option.is_some
         (request_id_for_payload
            initial_requests
            Journal_platform.local_account_binding_request))
      "OCaml calendar sampling did not release managed warm startup synchronously";
    require
      (List.for_all
         (fun (_, payload) -> Bytes.get_uint16_le payload 6 <> 1)
         initial_requests)
      "warm startup emitted the deleted calendar platform request")
;;

let test_calendar_failure_does_not_start_graph_restoration () =
  let runtime_epoch = ID.Runtime.Epoch.of_int64 7_006L in
  let calendar_sampler =
    Journal_calendar.Sampler.create
      ~clock:(fun () -> raise (Failure "calendar unavailable"))
      ~localtime:Unix.localtime
      ()
  in
  with_warm_start_app ~calendar_sampler runtime_epoch (fun handle ->
    let initial_requests = application_requests handle in
    require
      (Option.is_none
         (request_id_for_payload
            initial_requests
            Journal_platform.local_account_binding_request))
      "failed calendar prerequisite still started graph restoration")
;;

let test_foreground_resume_resamples_calendar_in_ocaml () =
  let runtime_epoch = ID.Runtime.Epoch.of_int64 7_007L in
  let samples = ref 0 in
  let calendar_sampler =
    Journal_calendar.Sampler.create
      ~clock:(fun () ->
        incr samples;
        1_788_508_800. +. (Float.of_int !samples *. 60.))
      ~localtime:(fun seconds -> Unix.gmtime (seconds +. 28_800.))
      ()
  in
  with_warm_start_app ~calendar_sampler runtime_epoch (fun handle ->
    require (!samples = 1) "warm startup sampled the calendar more than once";
    Test.Handle.present handle;
    let events =
      network_lifecycle_packet ~kind:2 ~generation:1L
      |> application_event_batch
           ~runtime_epoch
           ~revision:(Test.Handle.revision handle)
           ~sequence:1L
    in
    Test.Handle.pump_next handle ~events ();
    require (!samples = 2) "foreground resume did not re-sample the OCaml calendar")
;;

let () =
  (match Sys.getenv_opt "JOURNAL_HEADER_FRAME_DIR" with
   | None -> ()
   | Some directory ->
     export_header_frames directory;
     export_timeline_preview directory;
     exit 0);
  test_literal_source_time_completion_and_full_access ();
  test_long_source_and_corrupt_surfaces ();
  test_four_status_rails_replace_timeline_task_controls ();
  test_title_and_children_have_independent_bounded_tail_fade_previews ();
  test_wrapping_estimate_bounds_latin_cjk_emoji_and_explicit_lines ();
  test_line_count_drives_exact_scaled_row_extent ();
  test_header_account_action_and_view_only_date_have_truthful_semantics ();
  test_header_sync_progress_tracks_every_sync_phase ();
  test_compact_and_adaptive_shapes_at_required_extremes ();
  test_rtl_row_geometry_uses_logical_edges ();
  test_child_count_widths_and_long_parent_source_remain_bounded ();
  test_non_picker_exact_statuses_remain_readable_on_the_status_button ();
  test_slidable_has_one_exact_status_button_and_non_dismissible_delete_action ();
  test_warm_start_samples_calendar_before_requesting_local_binding ();
  test_calendar_failure_does_not_start_graph_restoration ();
  test_foreground_resume_resamples_calendar_in_ocaml ()
;;
