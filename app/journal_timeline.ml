module Tokens = Journal_visual_tokens
module Timeline = Journal_timeline_state
module Ui = Bonsai_flutter_ui

let text_style token =
  Ui.Style.Text_style.create
    ~font_size:token.Tokens.font_size
    ~font_weight:token.weight
    ~line_height:(token.line_height /. token.font_size)
    ()
;;

let day_heading
      ~tokens
      ~typography
      ~profile
      ~rtl
      ~state
      ~sort_key
      ~presentation
      (page : Journal_graph_projection.page)
  =
  let date_text, weekday_text =
    match presentation with
    | None -> "Date unavailable", None
    | Some (date : Journal_calendar.date_presentation) ->
      date.date_text, Some date.weekday_text
  in
  let line (token : Tokens.text_token) label =
    let ratio = profile.Tokens.date_text_scale /. profile.text_scale in
    let token =
      { token with
        font_size = token.font_size *. ratio
      ; line_height = token.line_height *. ratio
      }
    in
    Ui.Widget.text ~style:(text_style token) ~max_lines:1 label
  in
  let before, after = Timeline.heading_spacing state ~day:page.day in
  Ui.Widget.row
    ((line typography.Tokens.day_heading date_text
      |> Ui.Widget.with_test_id
           (Ui.Test_id.string ("journal-day-heading-label:" ^ string_of_int page.day)))
     ::
     (match weekday_text with
      | None -> []
      | Some weekday ->
        [ Ui.Widget.empty () |> Ui.Widget.sized_box ~width:14.
        ; line typography.date_weekday weekday
          |> Ui.Widget.opacity (Tokens.weekday_opacity tokens ~current:false)
        ]))
  |> Ui.Widget.sized_box ~height:(24. *. profile.Tokens.date_text_scale)
  |> Ui.Widget.align ~alignment:Ui.Layout.Alignment.Center_start
  |> Ui.Widget.padding
       ~insets:
         (Ui.Layout.Edge_insets.only
            ~left:(if rtl then Tokens.spacing.x4 else profile.Tokens.content_leading)
            ~right:(if rtl then profile.Tokens.content_leading else Tokens.spacing.x4)
            ~top:before
            ~bottom:after
            ())
  |> Ui.Widget.with_test_id
       (Ui.Test_id.string ("journal-day-heading-padding:" ^ string_of_int page.day))
  |> Ui.Widget.semantics
       ~properties:
         (Ui.Semantics.create
            ~role:Ui.Semantics.Role.Header
            ~heading_level:2
            ~sort_key
            ())
  |> Ui.Widget.with_test_id
       (Ui.Test_id.string ("journal-day-heading:" ^ string_of_int page.day))
;;

let continuation ~typography ~key ~label =
  Ui.Widget.text
    ~key:(Ui.Key.string key)
    ~style:(text_style typography.Tokens.supporting)
    ~max_lines:1
    label
  |> Ui.Widget.center
  |> Ui.Widget.semantics ~properties:(Ui.Semantics.create ~label ~live_region:true ())
  |> Ui.Widget.with_test_id (Ui.Test_id.string key)
;;

let for_block handler block_id =
  Ui.Event.Handler.create ~name:("journal-block:" ^ block_id) (function
    | Ui.Event.Payload.Unit ->
      Ui.Event.Handler.Private.invoke handler (Ui.Event.Payload.Text block_id)
    | _ -> ())
;;

let delete_action_id = 1
let status_action_id = 6

let for_slidable ~on_status ~on_delete block_id =
  Ui.Event.Handler.create ~name:("journal-row-action:" ^ block_id) (fun payload ->
    match Ui.Native_widget.Slidable.event_of_payload payload with
    | Some (Ui.Native_widget.Slidable.Action_pressed action_id)
      when action_id = delete_action_id ->
      Ui.Event.Handler.Private.invoke on_delete (Ui.Event.Payload.Text block_id)
    | Some (Ui.Native_widget.Slidable.Action_pressed action_id)
      when action_id = status_action_id ->
      Ui.Event.Handler.Private.invoke on_status (Ui.Event.Payload.Text block_id)
    | Some (Ui.Native_widget.Slidable.Action_pressed _) -> ()
    | Some (Ui.Native_widget.Slidable.Dismissed _) | None -> ())
;;

let delete_feedback ~foreground block =
  Material_icon_catalog.create ~size:16. ~color:foreground Material_icon_catalog.Delete
  |> Ui.Widget.with_test_id
       (Ui.Test_id.string ("journal-row-delete-icon:" ^ Journal_model.id block))
;;

let delete_action_divider ~device_pixel_ratio ~edge block =
  let thickness = Tokens.physical_divider_thickness ~device_pixel_ratio in
  Ui.Material.divider ~thickness ()
  |> Ui.Widget.with_test_id
       (Ui.Test_id.string
          ("journal-row-delete-" ^ edge ^ "-divider:" ^ Journal_model.id block))
  |> Ui.Widget.sized_box ~height:thickness
;;

let centered_action_feedback icon label =
  Ui.Widget.Flex.column
    [ Ui.Widget.empty () |> Ui.Widget.Flex.expanded
    ; Ui.Widget.Flex.fixed icon
    ; Ui.Widget.Flex.fixed label
    ; Ui.Widget.empty () |> Ui.Widget.Flex.expanded
    ]
;;

let centered_status_feedback icon label =
  Ui.Widget.Flex.column
    [ Ui.Widget.empty () |> Ui.Widget.Flex.expanded ~flex:5
    ; icon |> Ui.Widget.center |> Ui.Widget.Flex.expanded ~flex:90
    ; label |> Ui.Widget.center |> Ui.Widget.Flex.expanded ~flex:55
    ; Ui.Widget.empty () |> Ui.Widget.Flex.expanded ~flex:8
    ]
;;

let delete_action ~tokens ~typography ~device_pixel_ratio ~enabled block =
  let colors = Tokens.destructive_swipe_action tokens in
  let label =
    Ui.Widget.text
      ~style:(text_style typography.Tokens.supporting)
      ~max_lines:1
      ~text_align:Ui.Style.Text_align.Center
      "Delete"
    |> Ui.Widget.with_test_id
         (Ui.Test_id.string ("journal-row-delete-label:" ^ Journal_model.id block))
  in
  let feedback =
    centered_action_feedback (delete_feedback ~foreground:colors.foreground block) label
  in
  let child =
    Ui.Widget.Stack.create
      [ Ui.Widget.Stack.positioned ~left:0. ~top:0. ~right:0. ~bottom:0. feedback
      ; Ui.Widget.Stack.positioned
          ~left:0.
          ~top:0.
          ~right:0.
          (delete_action_divider ~device_pixel_ratio ~edge:"top" block)
      ; Ui.Widget.Stack.positioned
          ~left:0.
          ~right:0.
          ~bottom:0.
          (delete_action_divider ~device_pixel_ratio ~edge:"bottom" block)
      ]
    |> Ui.Widget.semantics
         ~properties:
           (Ui.Semantics.create
              ~label:"Delete block and all descendants"
              ~role:Ui.Semantics.Role.Button
              ~enabled
              ~focusable:enabled
              ())
  in
  Ui.Native_widget.Slidable.action
    ~id:delete_action_id
    ~enabled
    ~foreground:colors.foreground
    ~background:colors.background
    ~border_radius:0.
    ~child
    ()
;;

let delete_action_pane ~tokens ~typography ~device_pixel_ratio ~enabled block =
  Ui.Native_widget.Slidable.action_pane
    ~extent_ratio:0.25
    ~motion:Ui.Native_widget.Slidable.Behind
    ~drag_dismissible:false
    ~open_threshold:0.125
    ~close_threshold:0.125
    ~actions:[ delete_action ~tokens ~typography ~device_pixel_ratio ~enabled block ]
    ()
;;

let status_action ~tokens ~typography ~actions_enabled block =
  let task_state = Journal_model.task_state block in
  let colors = Tokens.status_swipe_action tokens task_state in
  let status_name = Journal_model.status_name task_state in
  let semantic_label = "Change status, current status " ^ status_name in
  let label =
    let supporting = typography.Tokens.supporting in
    Ui.Widget.text
      ~style:
        (Ui.Style.Text_style.create
           ~font_size:(Float.min 11. supporting.font_size)
           ~font_weight:supporting.weight
           ~line_height:1.
           ())
      ~max_lines:1
      ~overflow:Ui.Style.Text_overflow.Clip
      ~text_align:Ui.Style.Text_align.Center
      status_name
    |> Ui.Widget.with_test_id
         (Ui.Test_id.string ("journal-row-status-action-label:" ^ Journal_model.id block))
  in
  let icon =
    Material_icon_catalog.create
      ~size:18.
      ~color:colors.foreground
      (Material_icon_catalog.for_task_state task_state)
    |> Ui.Widget.with_test_id
         (Ui.Test_id.string ("journal-row-status-action-icon:" ^ Journal_model.id block))
  in
  let child =
    centered_status_feedback icon label
    |> Ui.Widget.semantics
         ~properties:
           (Ui.Semantics.create
              ~label:semantic_label
              ~role:Ui.Semantics.Role.Button
              ~enabled:actions_enabled
              ~focusable:actions_enabled
              ())
    |> Ui.Widget.with_test_id
         (Ui.Test_id.string ("journal-row-status-action:" ^ Journal_model.id block))
  in
  Ui.Native_widget.Slidable.action
    ~id:status_action_id
    ~enabled:actions_enabled
    ~foreground:colors.foreground
    ~background:colors.background
    ~auto_close:true
    ~border_radius:0.
    ~child
    ()
;;

let status_action_pane ~tokens ~typography ~actions_enabled block =
  Ui.Native_widget.Slidable.action_pane
    ~extent_ratio:0.25
    ~motion:Ui.Native_widget.Slidable.Behind
    ~drag_dismissible:false
    ~open_threshold:0.125
    ~close_threshold:0.125
    ~actions:[ status_action ~tokens ~typography ~actions_enabled block ]
    ()
;;

let should_restore_focus state block_id =
  Option.equal String.equal (Timeline.focus_restore_block_id state) (Some block_id)
;;

let same_creation_minute left right =
  let left = Journal_model.creation_time left in
  let right = Journal_model.creation_time right in
  Journal_time.local_day left = Journal_time.local_day right
  && Journal_time.local_minute_of_day left = Journal_time.local_minute_of_day right
;;

let should_show_timestamp ~today ~previous_slot = function
  | Timeline.Top_level entry when Journal_model.journal_day entry.block = today ->
    (match previous_slot with
     | Some (Timeline.Top_level previous) ->
       not (same_creation_minute previous.block entry.block)
     | Some _ | None -> true)
  | Timeline.Top_level _
  | Timeline.Child_preview _
  | Timeline.Day_heading _
  | Timeline.Day_continuation _
  | Timeline.Children_loading _
  | Timeline.Children_more _
  | Timeline.Feed_continuation _ -> false
;;

let child_preview ~tokens ~typography ~profile ~rtl ~block ~sort_key =
  let geometry = Tokens.preview_geometry in
  let leading_delta =
    if profile.Tokens.content_leading < 32. then geometry.narrow_leading_delta else 0.
  in
  let connector_leading = geometry.connector_leading -. leading_delta in
  let bullet_leading = geometry.bullet_center_leading -. leading_delta in
  let text_leading = geometry.text_leading -. leading_delta in
  let block_source = Journal_model.source block in
  let measurement =
    Tokens.measure_text
      ~profile
      ~font_size:profile.Tokens.supporting_font_size
      ~max_lines:3
      block_source
  in
  let extent = Tokens.block_extent ~profile ~visible_lines:measurement.visible_lines in
  let connector =
    Ui.Material.divider ~thickness:1. ()
    |> Ui.Widget.sized_box ~width:extent ~height:1.
    |> Ui.Widget.transform
         ~transform:
           (Ui.Style.Transform.matrix4
              [| 0.; 1.; 0.; 0.; -1.; 0.; 0.; 0.; 0.; 0.; 1.; 0.; 1.; 0.; 0.; 1. |])
    |> Ui.Widget.with_test_id
         (Ui.Test_id.string ("journal-child-connector:" ^ Journal_model.id block))
  in
  let bullet =
    Material_icon_catalog.create
      ~size:geometry.bullet_diameter
      Material_icon_catalog.Circle
    |> Ui.Widget.sized_box
         ~width:geometry.bullet_diameter
         ~height:geometry.bullet_diameter
    |> Ui.Widget.with_test_id
         (Ui.Test_id.string ("journal-child-bullet:" ^ Journal_model.id block))
  in
  let source =
    Journal_row.preview_text
      ~token:typography.Tokens.supporting
      ~profile
      ~id:("journal-child-source:" ^ Journal_model.id block)
      ~fade_id:("journal-child-source-tail-fade:" ^ Journal_model.id block)
      ~max_lines:3
      ~did_overflow:measurement.did_overflow
      block_source
    |> Ui.Widget.opacity 0.65
    |> Ui.Widget.with_test_id
         (Ui.Test_id.string ("journal-child-source-opacity:" ^ Journal_model.id block))
    |> Ui.Widget.align ~alignment:Ui.Layout.Alignment.Center_start
    |> Ui.Widget.padding
         ~insets:
           (Ui.Layout.Edge_insets.only
              ~left:(if rtl then Tokens.row_geometry.trailing_inset else text_leading)
              ~right:(if rtl then text_leading else Tokens.row_geometry.trailing_inset)
              ())
  in
  let positioned_connector =
    if rtl
    then Ui.Widget.Stack.positioned ~right:connector_leading ~top:0. connector
    else Ui.Widget.Stack.positioned ~left:connector_leading ~top:0. connector
  in
  let bullet_offset = bullet_leading -. (geometry.bullet_diameter /. 2.) in
  let positioned_bullet =
    if rtl
    then
      Ui.Widget.Stack.positioned
        ~right:bullet_offset
        ~top:((extent -. geometry.bullet_diameter) /. 2.)
        bullet
    else
      Ui.Widget.Stack.positioned
        ~left:bullet_offset
        ~top:((extent -. geometry.bullet_diameter) /. 2.)
        bullet
  in
  let semantic_label =
    match Journal_model.task_state block with
    | Journal_model.No_status -> "Direct child: " ^ Journal_model.source block
    | status ->
      "Direct child: "
      ^ Journal_model.source block
      ^ ", status "
      ^ Journal_model.status_name status
  in
  let children =
    ref [ Ui.Widget.Stack.child source; positioned_connector; positioned_bullet ]
  in
  (match Tokens.status_rail_color tokens (Journal_model.task_state block) with
   | None -> ()
   | Some color ->
     let rail =
       Journal_row.rail_body
         ~color
         ~task_state:(Journal_model.task_state block)
         ~height:
           (float_of_int measurement.visible_lines *. profile.Tokens.block_line_height)
         ~id:("journal-child-status-rail:" ^ Journal_model.id block)
       |> Ui.Widget.sized_box
            ~width:Tokens.row_geometry.status_rail_width
            ~height:
              (float_of_int measurement.visible_lines *. profile.Tokens.block_line_height)
     in
     children
     := (if rtl
         then
           Ui.Widget.Stack.positioned
             ~right:(text_leading -. Tokens.spacing.x3)
             ~top:Tokens.row_geometry.entry_vertical_padding
             rail
         else
           Ui.Widget.Stack.positioned
             ~left:(text_leading -. Tokens.spacing.x3)
             ~top:Tokens.row_geometry.entry_vertical_padding
             rail)
        :: !children);
  Ui.Widget.Stack.create (List.rev !children)
  |> Ui.Widget.sized_box ~height:extent
  |> Ui.Widget.semantics
       ~properties:
         (Ui.Semantics.create
            ~label:semantic_label
            ~role:Ui.Semantics.Role.Generic
            ~sort_key
            ())
  |> Ui.Widget.with_test_id
       (Ui.Test_id.string ("journal-child-preview:" ^ Journal_model.id block))
;;

let render_slot
      ~tokens
      ~typography
      ~profile
      ~device_pixel_ratio
      ~rtl
      ~state
      ~day_presentation
      ~show_timestamp
      ~reduced_motion
      ~on_retry_day
      ~on_toggle_children
      ~delete_enabled
      ~actions_enabled
      ~on_status
      ~on_delete
      ~sort_base
  = function
  | Timeline.Day_heading page ->
    day_heading
      ~tokens
      ~state
      ~typography
      ~profile
      ~rtl
      ~sort_key:sort_base
      ~presentation:(day_presentation page.day)
      page
  | Timeline.Top_level entry ->
    let block = entry.block in
    let id = Journal_model.id block in
    let expanded = Timeline.is_expanded state ~block_id:id in
    let row =
      Journal_row.view
        ~tokens
        ~typography
        ~profile
        ~device_pixel_ratio
        ~rtl
        ~item:(Journal_row.Item.of_timeline_entry entry)
        ~show_timestamp
        ~expanded
        ~show_divider:false
        ~sort_base
        ~reduced_motion
        ~on_toggle_children:(for_block on_toggle_children id)
    in
    let row =
      if delete_enabled
      then (
        let surface =
          Ui.Native_widget.Morphing_surface.create
            ~key:(Ui.Key.string ("journal-row-slidable-surface:" ^ id))
            ~expanded:false
            ~compact_content:row
            ~expanded_content:(Ui.Widget.empty ())
            ()
          |> Ui.Widget.with_test_id
               (Ui.Test_id.string ("journal-row-slidable-surface:" ^ id))
        in
        Ui.Native_widget.Slidable.create_with_handler
          ~key:(Ui.Key.string ("journal-row-slidable:" ^ id))
          ~enabled:actions_enabled
          ~group_tag:"journal-timeline"
          ~start_action_pane:
            (status_action_pane ~tokens ~typography ~actions_enabled block)
          ~end_action_pane:
            (delete_action_pane
               ~tokens
               ~typography
               ~device_pixel_ratio
               ~enabled:actions_enabled
               block)
          ~content:surface
          ~on_event:(for_slidable ~on_status ~on_delete id)
          ()
        |> Ui.Widget.with_test_id (Ui.Test_id.string ("journal-row-slidable:" ^ id)))
      else row
    in
    let extent =
      Journal_row.Item.visible_extent
        (Journal_row.Item.of_timeline_entry entry)
        ~profile
        ~expanded
    in
    Ui.Widget.sized_box ~height:extent row
    |> Ui.Widget.focus_scope
         ~key:(Ui.Key.string ("journal-row-focus:" ^ id))
         ~autofocus:(should_restore_focus state id)
         ~on_focus_changed:
           (Ui.Event.Handler.create ~name:("journal-row-focus-change:" ^ id) (fun _ -> ()))
    |> Ui.Widget.with_test_id (Ui.Test_id.string ("journal-row-focus:" ^ id))
  | Timeline.Child_preview { block; _ } ->
    child_preview ~tokens ~typography ~profile ~rtl ~block ~sort_key:sort_base
  | Timeline.Day_continuation { day; _ } ->
    (match Timeline.day_error state ~day with
     | None ->
       continuation
         ~typography
         ~key:("journal-day-continuation:" ^ string_of_int day)
         ~label:"Loading more journal entries"
     | Some _ ->
       let on_press =
         Ui.Event.Handler.create (fun _ ->
           Ui.Event.Handler.Private.invoke
             on_retry_day
             (Ui.Event.Payload.Text (string_of_int day)))
       in
       Ui.Material.text_button
         ~enabled:(Option.is_none (Timeline.pending_request state))
         ~on_press
         ~child:(Ui.Widget.text "Unable to load entries. Retry")
         ()
       |> Ui.Widget.center
       |> Ui.Widget.with_test_id
            (Ui.Test_id.string ("journal-day-retry:" ^ string_of_int day)))
    |> Ui.Widget.sized_box ~height:profile.continuation_extent
  | Timeline.Children_loading { parent_id; _ } ->
    continuation
      ~typography
      ~key:("journal-children-loading:" ^ parent_id)
      ~label:"Loading direct child blocks"
    |> Ui.Widget.sized_box ~height:(Tokens.fixed_extent ~profile Tokens.Children_loading)
  | Timeline.Children_more { parent_id } ->
    continuation ~typography ~key:("journal-children-more:" ^ parent_id) ~label:"More"
    |> Ui.Widget.semantics
         ~properties:
           (Ui.Semantics.create ~label:"More direct child blocks are not shown" ())
    |> Ui.Widget.sized_box ~height:(Tokens.fixed_extent ~profile Tokens.Children_more)
  | Timeline.Feed_continuation { before_day } ->
    continuation
      ~typography
      ~key:("journal-feed-continuation:" ^ string_of_int before_day)
      ~label:"Loading older journal days"
    |> Ui.Widget.sized_box ~height:profile.continuation_extent
;;

let transition ~reduced_motion:_ =
  Ui.Widget.Sparse_extent_transition.create
    ~enabled:false
    ~expand_duration_ms:0
    ~collapse_duration_ms:0
    ()
;;

let empty_view ~typography () =
  Ui.Widget.text ~style:(text_style typography.Tokens.supporting) "No journal entries yet"
  |> Ui.Widget.center
  |> Ui.Widget.semantics
       ~properties:
         (Ui.Semantics.create ~label:"No journal entries yet" ~live_region:true ())
;;

let loading_view ~typography () =
  Ui.Widget.text ~style:(text_style typography.Tokens.supporting) "Loading journal"
  |> Ui.Widget.center
  |> Ui.Widget.semantics
       ~properties:(Ui.Semantics.create ~label:"Loading journal" ~live_region:true ())
;;

let view
      ~tokens
      ~typography
      ~profile
      ~device_pixel_ratio
      ~end_padding
      ~rtl
      ~state
      ~day_presentation
      ~reduced_motion
      ~on_visible_range
      ~on_retry_day
      ~on_toggle_children
      ~delete_enabled
      ~actions_enabled
      ~on_status
      ~on_delete
  =
  let window = Timeline.current_window state in
  match window.slots with
  | [] ->
    Ui.Widget.Sliver.fill (empty_view ~typography ())
    |> Ui.Widget.Sliver.with_test_id (Ui.Test_id.string "journal-timeline")
  | slots ->
    let geometry = Timeline.extent_geometry state ~profile in
    let today = Timeline.today state in
    let retained_offset = window.first_index - Timeline.first_retained_index state in
    let previous_slot =
      if retained_offset <= 0
      then None
      else List.nth_opt (Timeline.retained_slots state) (retained_offset - 1)
    in
    let items =
      let rec render offset previous_slot = function
        | [] -> []
        | slot :: rest ->
          let sort_base = 100. +. (float_of_int (window.first_index + offset) *. 10.) in
          let item =
            render_slot
              ~tokens
              ~typography
              ~profile
              ~device_pixel_ratio
              ~rtl
              ~state
              ~day_presentation
              ~show_timestamp:(should_show_timestamp ~today ~previous_slot slot)
              ~reduced_motion
              ~on_retry_day
              ~on_toggle_children
              ~delete_enabled
              ~actions_enabled
              ~on_status
              ~on_delete
              ~sort_base
              slot
            |> Ui.Widget.Keyed.create ~key:(Ui.Key.string (Timeline.slot_key slot))
          in
          item :: render (offset + 1) (Some slot) rest
      in
      render 0 previous_slot slots
    in
    Ui.Widget.Sliver.varied_extent
      ~key:(Ui.Key.string "journal-timeline-list")
      ~total_count:window.total_count
      ~first_index:window.first_index
      ~default_item_extent:geometry.default_extent
      ~extent_overrides:geometry.overrides
      ~overscan:Timeline.overscan
      ~transition:(transition ~reduced_motion)
      ~items
      ~on_visible_range
      ()
    |> Ui.Widget.Sliver.with_test_id (Ui.Test_id.string "journal-timeline-list")
    |> Ui.Widget.Sliver.padding
         ~insets:(Ui.Layout.Edge_insets.only ~bottom:end_padding ())
    |> Ui.Widget.Sliver.with_test_id (Ui.Test_id.string "journal-timeline")
;;
