module Tokens = Journal_visual_tokens
module Timeline = Journal_timeline_state
module Ui = Bonsai_flutter_ui

type content =
  | Empty of Ui.Widget.t
  | Populated of Ui.Widget.Viewport.Vertical.t

let text_style token color =
  Ui.Style.Text_style.create
    ~font_size:token.Tokens.font_size
    ~font_weight:token.weight
    ~line_height:(token.line_height /. token.font_size)
    ~color
    ()
;;

let day_heading ~tokens ~profile ~rtl ~sort_key ~label (page : Journal_graph_projection.page) =
  Ui.Widget.text
    ~key:(Ui.Key.string ("journal-day-heading:" ^ string_of_int page.day))
    ~style:
      (text_style Tokens.typography.supporting (Tokens.palette tokens).text_secondary)
    ~max_lines:1
    ~overflow:Ui.Style.Text_overflow.Ellipsis
    label
  |> Ui.Widget.align ~alignment:Ui.Layout.Alignment.Center_start
  |> Ui.Widget.padding
       ~insets:
         (Ui.Layout.Edge_insets.only
            ~left:(if rtl then Tokens.spacing.x4 else profile.Tokens.content_leading)
            ~right:(if rtl then profile.Tokens.content_leading else Tokens.spacing.x4)
            ())
  |> Ui.Widget.semantics
       ~properties:
         (Ui.Semantics.create
            ~label
            ~role:Ui.Semantics.Role.Header
            ~heading_level:2
            ~sort_key
            ())
  |> Ui.Widget.with_test_id
       (Ui.Test_id.string ("journal-day-heading:" ^ string_of_int page.day))
;;

let continuation ~tokens ~key ~label =
  Ui.Widget.text
    ~key:(Ui.Key.string key)
    ~style:
      (text_style Tokens.typography.supporting (Tokens.palette tokens).text_secondary)
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

let for_swipe handler block_id =
  Ui.Event.Handler.create ~name:("journal-delete:" ^ block_id) (fun payload ->
    match Ui.Native_widget.Swipe_action.direction_of_payload payload with
    | Some Ui.Native_widget.Swipe_action.End_to_start ->
      Ui.Event.Handler.Private.invoke handler (Ui.Event.Payload.Text block_id)
    | Some Start_to_end | None -> ())
;;

let delete_feedback ~tokens block =
  Ui.Widget.icon
    ~font_family:"MaterialIcons"
    ~size:24.
    ~color:(Tokens.palette tokens).on_destructive
    ~code_point:0xe1b9
    ()
  |> Ui.Widget.with_test_id
       (Ui.Test_id.string ("journal-row-delete-icon:" ^ Journal_model.id block))
;;

let delete_action ~tokens block =
  Ui.Native_widget.Swipe_action.action
    ~label:"Delete block and all descendants"
    ~background:(Tokens.palette tokens).destructive
    ~border_radius:0.
    ~disposition:Ui.Native_widget.Swipe_action.Dismiss
    ~icon:(delete_feedback ~tokens block)
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
  | Timeline.Feed_continuation _
  | Timeline.Bottom_clearance -> false
;;

let group_separator ~tokens ~device_pixel_ratio ~owner_id ~extent content =
  let thickness = Tokens.physical_divider_thickness ~device_pixel_ratio in
  let divider =
    Ui.Widget.empty ()
    |> Ui.Widget.decorated_box
         ~decoration:
           (Ui.Style.Decoration.create ~background:(Tokens.palette tokens).divider ())
    |> Ui.Widget.sized_box ~height:thickness
    |> Ui.Widget.with_test_id
         (Ui.Test_id.string ("journal-group-divider:" ^ owner_id))
    |> Ui.Widget.padding ~insets:(Ui.Layout.Edge_insets.only ~left:0. ~right:0. ())
    |> Ui.Widget.with_test_id
         (Ui.Test_id.string ("journal-group-divider-padding:" ^ owner_id))
  in
  Ui.Widget.Stack.create
    [ Ui.Widget.Stack.child content
    ; Ui.Widget.Stack.positioned ~left:0. ~right:0. ~bottom:0. divider
    ]
  |> Ui.Widget.sized_box ~height:extent
;;

let child_preview
      ~tokens
      ~profile
      ~rtl
      ~block
      ~sort_key
  =
  let geometry = Tokens.preview_geometry in
  let leading_delta = if profile.Tokens.content_leading < 32. then geometry.narrow_leading_delta else 0. in
  let connector_leading = geometry.connector_leading -. leading_delta in
  let bullet_leading = geometry.bullet_center_leading -. leading_delta in
  let text_leading = geometry.text_leading -. leading_delta in
  let connector =
    Ui.Widget.empty ()
    |> Ui.Widget.decorated_box
         ~decoration:
           (Ui.Style.Decoration.create ~background:(Tokens.palette tokens).divider ())
    |> Ui.Widget.sized_box ~width:1. ~height:profile.child_extent
    |> Ui.Widget.with_test_id
         (Ui.Test_id.string ("journal-child-connector:" ^ Journal_model.id block))
  in
  let bullet =
    Ui.Widget.empty ()
    |> Ui.Widget.decorated_box
         ~decoration:
           (Ui.Style.Decoration.create
              ~background:(Tokens.palette tokens).divider
              ~border_radius:(geometry.bullet_diameter /. 2.)
              ())
    |> Ui.Widget.sized_box
         ~width:geometry.bullet_diameter
         ~height:geometry.bullet_diameter
    |> Ui.Widget.with_test_id
         (Ui.Test_id.string ("journal-child-bullet:" ^ Journal_model.id block))
  in
  let source =
    Ui.Widget.text
      ~style:(text_style Tokens.typography.supporting (Tokens.palette tokens).text_primary)
      ~max_lines:1
      ~overflow:Ui.Style.Text_overflow.Ellipsis
      (Journal_model.source block)
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
        ~top:((profile.child_extent -. geometry.bullet_diameter) /. 2.)
        bullet
    else
      Ui.Widget.Stack.positioned
        ~left:bullet_offset
        ~top:((profile.child_extent -. geometry.bullet_diameter) /. 2.)
        bullet
  in
  let semantic_label =
    match Journal_model.task_state block with
    | Journal_model.Not_a_task -> "Direct child: " ^ Journal_model.source block
    | Todo -> "Direct child task Todo: " ^ Journal_model.source block
    | Done -> "Direct child task Done: " ^ Journal_model.source block
  in
  Ui.Widget.Stack.create
    [ Ui.Widget.Stack.child source; positioned_connector; positioned_bullet ]
  |> Ui.Widget.sized_box ~height:profile.child_extent
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

let matching_child_owner parent_id = function
  | Timeline.Child_preview candidate -> String.equal candidate.parent_id parent_id
  | Timeline.Children_loading candidate -> String.equal candidate.parent_id parent_id
  | Timeline.Children_more candidate -> String.equal candidate.parent_id parent_id
  | _ -> false
;;

let ends_group ~known_end slot next =
  match slot with
  | Timeline.Top_level entry ->
    (match next with
     | Some next -> not (matching_child_owner (Journal_model.id entry.block) next)
     | None -> known_end)
  | Timeline.Child_preview preview ->
    (match next with
     | Some next -> not (matching_child_owner preview.parent_id next)
     | None -> known_end)
  | Timeline.Children_loading _ | Timeline.Children_more _ -> true
  | Day_heading _ | Day_continuation _ | Feed_continuation _ | Bottom_clearance -> false
;;

let render_slot
      ~tokens
      ~profile
      ~device_pixel_ratio
      ~rtl
      ~state
      ~day_label
      ~show_timestamp
      ~reduced_motion
      ~on_task_toggle
      ~on_toggle_children
      ~delete_enabled
      ~on_delete
      ~sort_base
      ~ends_group
  = function
  | Timeline.Day_heading page ->
    day_heading ~tokens ~profile ~rtl ~sort_key:sort_base ~label:(day_label page.day) page
  | Timeline.Top_level entry ->
    let block = entry.block in
    let id = Journal_model.id block in
    let expanded = Timeline.is_expanded state ~block_id:id in
    let row =
      Journal_row.view
        ~tokens
        ~profile
        ~device_pixel_ratio
        ~rtl
        ~item:(Journal_row.Item.of_timeline_entry entry)
        ~show_timestamp
        ~expanded
        ~show_divider:false
        ~sort_base
        ~reduced_motion
        ~on_task_toggle:(for_block on_task_toggle id)
        ~on_toggle_children:(for_block on_toggle_children id)
    in
    let row =
      if delete_enabled
      then
        Ui.Native_widget.Swipe_action.create_with_handler
          ~key:(Ui.Key.string ("journal-row-swipe:" ^ id))
          ~end_action:(delete_action ~tokens block)
          ~content:row
          ~on_commit:(for_swipe on_delete id)
          ()
        |> Ui.Widget.with_test_id (Ui.Test_id.string ("journal-row-swipe:" ^ id))
      else row
    in
    Ui.Widget.sized_box
      ~height:
        (if expanded
         then
           Tokens.expanded_parent_extent
             ~profile
             ~source:(Journal_model.source block)
         else profile.top_level_extent)
      row
    |> Ui.Widget.focus_scope
         ~key:(Ui.Key.string ("journal-row-focus:" ^ id))
         ~autofocus:(should_restore_focus state id)
         ~on_focus_changed:
           (Ui.Event.Handler.create ~name:("journal-row-focus-change:" ^ id) (fun _ -> ()))
    |> Ui.Widget.with_test_id (Ui.Test_id.string ("journal-row-focus:" ^ id))
    |> fun row ->
    if ends_group
    then
      group_separator
        ~tokens
        ~device_pixel_ratio
        ~owner_id:id
        ~extent:profile.top_level_extent
        row
    else row
  | Timeline.Child_preview { block; _ } ->
    child_preview
      ~tokens
      ~profile
      ~rtl
      ~block
      ~sort_key:sort_base
  | Timeline.Day_continuation { day; _ } ->
    continuation
      ~tokens
      ~key:("journal-day-continuation:" ^ string_of_int day)
      ~label:"Loading more journal entries"
    |> Ui.Widget.sized_box ~height:profile.continuation_extent
  | Timeline.Children_loading { parent_id; _ } ->
    continuation
      ~tokens
      ~key:("journal-children-loading:" ^ parent_id)
      ~label:"Loading direct child blocks"
    |> Ui.Widget.sized_box ~height:profile.child_extent
  | Timeline.Children_more { parent_id } ->
    continuation ~tokens ~key:("journal-children-more:" ^ parent_id) ~label:"More"
    |> Ui.Widget.semantics
         ~properties:
           (Ui.Semantics.create ~label:"More direct child blocks are not shown" ())
    |> Ui.Widget.sized_box ~height:profile.child_extent
  | Timeline.Feed_continuation { before_day } ->
    continuation
      ~tokens
      ~key:("journal-feed-continuation:" ^ string_of_int before_day)
      ~label:"Loading older journal days"
    |> Ui.Widget.sized_box ~height:profile.continuation_extent
  | Timeline.Bottom_clearance ->
    Ui.Widget.empty ~key:(Ui.Key.string "journal-bottom-clearance") ()
    |> Ui.Widget.with_test_id (Ui.Test_id.string "journal-bottom-clearance")
;;

let transition ~reduced_motion:_ =
  Ui.Widget.Sparse_extent_transition.create
    ~enabled:false
    ~expand_duration_ms:0
    ~collapse_duration_ms:0
    ()
;;

let empty_view tokens =
  Ui.Widget.text
    ~style:
      (text_style Tokens.typography.supporting (Tokens.palette tokens).text_secondary)
    "No journal entries yet"
  |> Ui.Widget.center
  |> Ui.Widget.semantics
       ~properties:
         (Ui.Semantics.create ~label:"No journal entries yet" ~live_region:true ())
  |> Ui.Widget.with_test_id (Ui.Test_id.string "journal-timeline")
;;

let loading_view tokens =
  Ui.Widget.text
    ~style:
      (text_style Tokens.typography.supporting (Tokens.palette tokens).text_secondary)
    "Loading journal"
  |> Ui.Widget.center
  |> Ui.Widget.semantics
       ~properties:(Ui.Semantics.create ~label:"Loading journal" ~live_region:true ())
  |> Ui.Widget.with_test_id (Ui.Test_id.string "journal-timeline")
;;

let view
      ~tokens
      ~profile
      ~device_pixel_ratio
      ~rtl
      ~state
      ~day_label
      ~reduced_motion
      ~safe_bottom
      ~on_visible_range
      ~on_task_toggle
      ~on_toggle_children
      ~delete_enabled
      ~on_delete
  =
  let window = Timeline.current_window state in
  match window.slots with
  | [] -> Empty (empty_view tokens)
  | slots ->
    let geometry = Timeline.extent_geometry state ~profile ~safe_bottom in
    let today = Timeline.today state in
    let retained_offset = window.first_index - Timeline.first_retained_index state in
    let previous_slot =
      if retained_offset <= 0
      then None
      else List.nth_opt (Timeline.retained_slots state) (retained_offset - 1)
    in
    let items =
      let supplied_end = window.first_index + List.length slots in
      let rec render offset previous_slot = function
        | [] -> []
        | slot :: rest ->
          let sort_base = 100. +. (float_of_int (window.first_index + offset) *. 10.) in
          let item =
            render_slot
              ~tokens
              ~profile
              ~device_pixel_ratio
              ~rtl
              ~state
              ~day_label
              ~show_timestamp:(should_show_timestamp ~today ~previous_slot slot)
              ~reduced_motion
              ~on_task_toggle
              ~on_toggle_children
              ~delete_enabled
              ~on_delete
              ~sort_base
              ~ends_group:
                (ends_group
                   ~known_end:(rest = [] && supplied_end >= window.total_count)
                   slot
                   (match rest with [] -> None | next :: _ -> Some next))
              slot
          in
          item :: render (offset + 1) (Some slot) rest
      in
      render 0 previous_slot slots
    in
    Ui.Widget.Scroll_view.vertical
      ~on_scroll:(Ui.Event.Handler.create (fun _ -> ()))
      [ Ui.Widget.Sliver.varied_extent
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
        |> Ui.Widget.Sliver.with_test_id (Ui.Test_id.string "journal-timeline")
      ]
      ()
    |> fun list -> Populated list
;;
