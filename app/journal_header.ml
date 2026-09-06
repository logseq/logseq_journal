module Graph_service = Logseq_db_worker_bonsai.Logseq_db_worker_bonsai_service
module Ui = Bonsai_flutter_ui
module Tokens = Journal_visual_tokens

let sync_progress_height = 2.

module Context = struct
  type t = Journal_calendar.date_presentation option

  let today ~date = date
  let date t = t

  let semantics_label = function
    | None -> "Date unavailable"
    | Some date -> date.Journal_calendar.accessibility_label
  ;;
end

let test_id value widget = Ui.Widget.with_test_id (Ui.Test_id.string value) widget

let glyph ~scale ~id icon =
  Material_icon_catalog.create ~size:(18. /. scale) icon
  |> test_id id
  |> Ui.Widget.center
  |> Ui.Widget.sized_box
       ~width:Tokens.hit_regions.header_visual
       ~height:Tokens.hit_regions.header_visual
;;

let shell ~id child =
  child
  |> Ui.Widget.center
  |> Ui.Widget.sized_box
       ~width:Tokens.hit_regions.minimum_target
       ~height:Tokens.hit_regions.minimum_target
  |> test_id id
;;

let sync_progress_visible = function
  | Some Graph_service.Connecting -> true
  | None
  | Some Offline
  | Some Pulling
  | Some Submitting
  | Some Current
  | Some Paused
  | Some Failed -> false
;;

let sliver
      ~tokens
      ~typography
      ~text_scale
      ~viewport_width
      ~top_inset:_
      ~device_pixel_ratio:_
      ~context
      ~sync_phase
      ~on_error_info
      ~on_account_menu
  =
  let leading = Ui.Widget.empty () |> shell ~id:"journal-header-leading-placeholder" in
  let available_width =
    viewport_width -. 56. -. 32. -. if Option.is_some on_error_info then 88. else 44.
  in
  let requested_scale = Float.max 1. text_scale in
  (* The native Material app bar clamps title scaling before laying out Text. *)
  let native_title_scale = Float.min 1.34 requested_scale in
  let date_scale =
    Float.min native_title_scale (Float.max 1. (available_width /. 140.))
  in
  let line token label =
    Ui.Widget.text
      ~max_lines:1
      ~style:
        (Ui.Style.Text_style.create
           ~font_size:(token.Tokens.font_size *. date_scale /. native_title_scale)
           ~font_weight:token.weight
           ~line_height:(token.line_height /. token.font_size)
           ())
      label
    |> Ui.Widget.center ~width_factor:1. ~height_factor:1.
  in
  let title_height = (42. *. date_scale) +. 2. in
  let toolbar_height = Float.max 56. (title_height +. 12.) in
  let date_context =
    (match Context.date context with
     | None -> line typography.Tokens.header_subtitle "Date unavailable"
     | Some date ->
       Ui.Widget.column
         [ line typography.header_title date.Journal_calendar.date_text
           |> test_id "journal-header-title"
         ; Ui.Widget.empty () |> Ui.Widget.sized_box ~height:2.
         ; line typography.date_weekday date.weekday_text
           |> Ui.Widget.opacity (Tokens.weekday_opacity tokens ~current:true)
           |> test_id "journal-header-weekday"
         ])
    |> Ui.Widget.sized_box ~height:title_height
    |> Ui.Widget.semantics ~properties:(Ui.Semantics.create ~sort_key:2. ())
    |> test_id "journal-date-context"
  in
  let progress_or_empty =
    if sync_progress_visible sync_phase
    then
      Ui.Material.linear_progress_indicator ~kind:Ui.Material.Flat ()
      |> test_id "journal-header-sync-progress"
      |> Ui.Widget.clip ~behavior:Ui.Style.Clip.Hard_edge
    else Ui.Widget.empty ()
  in
  let account =
    match on_account_menu with
    | None -> Ui.Widget.empty () |> shell ~id:"journal-header-account-placeholder"
    | Some on_press ->
      let icon =
        glyph
          ~scale:requested_scale
          ~id:"journal-account-icon"
          Material_icon_catalog.Account_circle
      in
      Ui.Material.icon_button ~on_press ~icon ()
      |> Ui.Widget.with_test_id (Ui.Test_id.string "journal-account-menu-button")
      |> Ui.Widget.semantics
           ~on_action:on_press
           ~properties:
             (Ui.Semantics.create
                ~label:"Account menu"
                ~hint:"Switch graphs, delete the local copy, or sign out"
                ~role:Ui.Semantics.Role.Button
                ~enabled:true
                ~focusable:true
                ~actions:[ Ui.Semantics.Action.Tap ]
                ~sort_key:4.
                ())
      |> Ui.Material.Tooltip.plain ~message:"Account menu"
      |> shell ~id:"journal-account-menu-target"
  in
  let error_info =
    match on_error_info with
    | None -> None
    | Some on_press ->
      let icon =
        glyph
          ~scale:requested_scale
          ~id:"journal-error-info-icon"
          Material_icon_catalog.Error_outline
      in
      Some
        (Ui.Material.icon_button ~on_press ~icon ()
         |> Ui.Widget.with_test_id (Ui.Test_id.string "journal-error-info-button")
         |> Ui.Widget.semantics
              ~on_action:on_press
              ~properties:
                (Ui.Semantics.create
                   ~label:"Error info"
                   ~hint:"Review Logseq DB worker errors"
                   ~role:Ui.Semantics.Role.Button
                   ~enabled:true
                   ~focusable:true
                   ~actions:[ Ui.Semantics.Action.Tap ]
                   ~sort_key:3.
                   ())
         |> Ui.Material.Tooltip.plain ~message:"Error info"
         |> shell ~id:"journal-error-info-target")
  in
  Ui.Material.App_bar.sliver
    ~key:(Ui.Key.string "journal-header-app-bar")
    ~pinned:true
    ~floating:false
    ~snap:false
    ~center_title:true
    ~toolbar_height
    ~expanded_height:(toolbar_height +. 8.)
    ~collapsed_height:(toolbar_height +. 8.)
    ~leading
    ~actions:(Option.to_list error_info @ [ account ])
    ~title:date_context
    ~bottom:(progress_or_empty, sync_progress_height)
    ()
  |> Ui.Widget.Sliver.with_test_id (Ui.Test_id.string "journal-header")
;;
