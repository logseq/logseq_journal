module Graph_service = Logseq_db_worker_bonsai.Logseq_db_worker_bonsai_service
module Ui = Bonsai_flutter_ui
module Tokens = Journal_visual_tokens

let sync_progress_height = 2.

module Context = struct
  type t =
    { title : string
    ; subtitle : string
    ; is_today : bool
    }

  let today ~subtitle = { title = "Today"; subtitle; is_today = true }
  let selected ~title ~subtitle = { title; subtitle; is_today = false }
  let is_today t = t.is_today
  let title t = t.title
  let subtitle t = t.subtitle
  let display_title t = t.title ^ " · " ^ t.subtitle
  let semantics_label t = t.title ^ ", " ^ t.subtitle
end

let test_id value widget = Ui.Widget.with_test_id (Ui.Test_id.string value) widget

let glyph ~id icon =
  Material_icon_catalog.create ~size:18. icon
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
      ~typography:_
      ~text_scale:_
      ~top_inset:_
      ~device_pixel_ratio:_
      ~context
      ~sync_phase
      ~on_error_info
      ~on_account_menu
  =
  let leading = Ui.Widget.empty () |> shell ~id:"journal-header-leading-placeholder" in
  let date_context =
    Ui.Widget.text
      ~max_lines:1
      ~overflow:Ui.Style.Text_overflow.Clip
      (Context.display_title context)
    |> test_id "journal-header-title"
    |> Ui.Widget.semantics
         ~properties:
           (Ui.Semantics.create ~label:(Context.semantics_label context) ~sort_key:2. ())
    |> test_id "journal-date-context"
  in
  let title =
    if sync_progress_visible sync_phase
    then
      Ui.Widget.column
        [ date_context
        ; Ui.Material.linear_progress_indicator ~kind:Ui.Material.Flat ()
          |> test_id "journal-header-sync-progress"
          |> Ui.Widget.sized_box ~height:sync_progress_height
          |> test_id "journal-header-sync-progress-extent"
        ]
    else date_context
  in
  let account =
    match on_account_menu with
    | None -> Ui.Widget.empty () |> shell ~id:"journal-header-account-placeholder"
    | Some on_press ->
      let icon = glyph ~id:"journal-account-icon" Material_icon_catalog.Account_circle in
      Ui.Material.icon_button ~on_press ~icon ()
      |> Ui.Widget.with_test_id (Ui.Test_id.string "journal-account-menu-button")
      |> Ui.Widget.semantics
           ~on_action:on_press
           ~properties:
             (Ui.Semantics.create
                ~label:"Account menu"
                ~hint:"Switch graphs, reset the local copy, or sign out"
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
        glyph ~id:"journal-error-info-icon" Material_icon_catalog.Error_outline
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
    ~variant:Ui.Material.App_bar.Small
    ~shape:Ui.Material.App_bar.Square
    ~density:Ui.Material.App_bar.Compact
    ~leading
    ~actions:(Option.to_list error_info @ [ account ])
    ~title
    ()
  |> Ui.Widget.Sliver.with_test_id (Ui.Test_id.string "journal-header")
;;
