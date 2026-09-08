module Graph_service = Logseq_db_worker_bonsai.Logseq_db_worker_bonsai_service
module Ui = Bonsai_flutter_ui
module Tokens = Journal_visual_tokens

let sync_progress_height = 2.

module Context = struct
  type t =
    | Today of Journal_calendar.date_presentation option
    | Favorites

  let today ~date = Today date
  let favorites = Favorites

  let date = function
    | Today date -> date
    | Favorites -> None
  ;;

  let semantics_label = function
    | Favorites -> "Favorites"
    | Today None -> "Date unavailable"
    | Today (Some date) -> date.Journal_calendar.accessibility_label
  ;;
end

let test_id value widget = Ui.Widget.with_test_id (Ui.Test_id.string value) widget

let title_line ~effective_scale ~ambient_scale (token : Tokens.text_token) label =
  Ui.Widget.text
    ~max_lines:1
    ~style:
      (Ui.Style.Text_style.create
         ~font_size:(token.font_size *. effective_scale /. ambient_scale)
         ~font_weight:token.weight
         ~line_height:(token.line_height /. token.font_size)
         ())
    label
;;

module Date_row = struct
  let extension =
    Ui.Native_widget.Extension.create
      ~kind_id:(Bonsai_flutter_spec.Id.Native_widget.Kind_id.of_int 1004)
      ~version:1
      ~capabilities:[]
      ~encode_props:(fun () -> Bytes.empty)
      ~decode_event:(fun ~event_id:_ _ -> Error "Date rows emit no events")
      ()
  ;;

  let view ~tokens ~typography ~effective_scale ~ambient_scale ~date_id ~weekday_id date =
    let line = title_line ~effective_scale ~ambient_scale in
    let children =
      match date with
      | None -> [ line typography.Tokens.header_subtitle "Date unavailable" ]
      | Some date ->
        [ line typography.day_heading date.Journal_calendar.date_text |> test_id date_id
        ; Ui.Widget.empty () |> Ui.Widget.sized_box ~width:Tokens.date_gap
        ; line typography.date_weekday date.weekday_text
          |> Ui.Widget.opacity (Tokens.weekday_opacity tokens)
          |> test_id weekday_id
        ]
    in
    Ui.Native_widget.widget extension ~props:() ~on_event:(fun _ -> ()) ~children ()
    |> Ui.Widget.sized_box ~height:(typography.day_heading.line_height *. effective_scale)
  ;;
end

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
  let requested_scale = Float.max 1. text_scale in
  (* Compensate for the native Material app bar's title scale clamp. *)
  let native_title_scale = Float.min 1.34 requested_scale in
  let effective_scale = Tokens.date_scale ~viewport_width ~text_scale in
  let title_height = typography.Tokens.day_heading.line_height *. effective_scale in
  let title =
    match context with
    | Context.Favorites ->
      title_line
        ~effective_scale
        ~ambient_scale:native_title_scale
        typography.day_heading
        "Favorites"
      |> test_id "favorites-header-title"
    | Today date ->
      Date_row.view
        ~tokens
        ~typography
        ~effective_scale
        ~ambient_scale:native_title_scale
        ~date_id:"journal-header-title"
        ~weekday_id:"journal-header-weekday"
        date
  in
  let toolbar_height = Float.max 56. (title_height +. 12.) in
  let date_context =
    title
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
