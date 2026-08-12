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

let day_heading ~tokens ~profile ~rtl ~sort_key ~label (page : Journal_repository.page) =
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

let render_slot
      ~tokens
      ~profile
      ~device_pixel_ratio
      ~rtl
      ~state
      ~day_label
      ~reduced_motion
      ~on_task_toggle
      ~on_toggle_children
      ~delete_enabled
      ~on_delete
      ~sort_base
  = function
  | Timeline.Day_heading page ->
    day_heading ~tokens ~profile ~rtl ~sort_key:sort_base ~label:(day_label page.day) page
  | Timeline.Block { block; depth } ->
    let id = Journal_model.id block in
    let row =
      Journal_row.view
        ~tokens
        ~profile
        ~device_pixel_ratio
        ~rtl
        ~item:(Journal_row.Item.of_block block)
        ~expanded:(Timeline.is_expanded state ~block_id:id)
        ~sort_base
        ~reduced_motion
        ~on_task_toggle:(for_block on_task_toggle id)
        ~on_toggle_children:(for_block on_toggle_children id)
    in
    let row =
      if depth = 0
      then row
      else
        Ui.Widget.padding
          ~insets:
            (Ui.Layout.Edge_insets.only
               ~left:(float_of_int depth *. Tokens.spacing.x4)
               ())
          row
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
    Ui.Widget.sized_box ~height:profile.block_extent row
    |> Ui.Widget.focus_scope
         ~key:(Ui.Key.string ("journal-row-focus:" ^ id))
         ~autofocus:(should_restore_focus state id)
         ~on_focus_changed:
           (Ui.Event.Handler.create ~name:("journal-row-focus-change:" ^ id) (fun _ -> ()))
    |> Ui.Widget.with_test_id (Ui.Test_id.string ("journal-row-focus:" ^ id))
  | Timeline.Day_continuation { day; _ } ->
    continuation
      ~tokens
      ~key:("journal-day-continuation:" ^ string_of_int day)
      ~label:"Loading more journal entries"
  | Timeline.Children_continuation { parent_id; _ } ->
    continuation
      ~tokens
      ~key:("journal-children-continuation:" ^ parent_id)
      ~label:"Loading direct child blocks"
  | Timeline.Feed_continuation { before_day } ->
    continuation
      ~tokens
      ~key:("journal-feed-continuation:" ^ string_of_int before_day)
      ~label:"Loading older journal days"
  | Timeline.Bottom_clearance ->
    Ui.Widget.empty ~key:(Ui.Key.string "journal-bottom-clearance") ()
    |> Ui.Widget.with_test_id (Ui.Test_id.string "journal-bottom-clearance")
;;

let transition ~reduced_motion =
  let motion = Tokens.motion ~reduced_motion in
  Ui.Native_widget.Sparse_extent_list.Transition.create
    ~enabled:(not reduced_motion)
    ~expand_duration_ms:motion.route_transition_ms
    ~collapse_duration_ms:motion.route_transition_ms
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
    let items =
      List.mapi
        (fun offset slot ->
           let sort_base = 100. +. (float_of_int (window.first_index + offset) *. 10.) in
           render_slot
             ~tokens
             ~profile
             ~device_pixel_ratio
             ~rtl
             ~state
             ~day_label
             ~reduced_motion
             ~on_task_toggle
             ~on_toggle_children
             ~delete_enabled
             ~on_delete
             ~sort_base
             slot)
        slots
    in
    Ui.Native_widget.Sparse_extent_list.vertical
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
    |> Ui.Widget.Viewport.Vertical.with_test_id (Ui.Test_id.string "journal-timeline")
    |> fun list -> Populated list
;;
