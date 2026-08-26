module Ui = Bonsai_flutter_ui
module Tokens = Journal_visual_tokens

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
  let semantics_label t = t.title ^ ", " ^ t.subtitle
end

let test_id value widget = Ui.Widget.with_test_id (Ui.Test_id.string value) widget

let text_style (token : Tokens.text_token) =
  Ui.Style.Text_style.create
    ~font_size:token.font_size
    ~font_weight:token.weight
    ~line_height:(token.line_height /. token.font_size)
    ()
;;

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

let extents ~typography ~text_scale ~divider_height =
  let scale = Float.max 1. text_scale in
  let title_height = typography.Tokens.header_title.line_height *. scale in
  let subtitle_height = typography.header_subtitle.line_height *. scale in
  let toolbar_height = Float.max 56. (title_height +. 16.) in
  let expanded_content_height = Float.max 96. (title_height +. subtitle_height +. 24.) in
  let expanded_height = expanded_content_height +. divider_height in
  let collapsed_height = toolbar_height +. divider_height in
  toolbar_height, collapsed_height, expanded_height, subtitle_height
;;

let sliver
      ~typography
      ~text_scale
      ~top_inset
      ~device_pixel_ratio
      ~context
      ~on_account_menu
  =
  let thickness = Tokens.physical_divider_thickness ~device_pixel_ratio in
  let toolbar_height, collapsed_height, expanded_height, subtitle_height =
    extents ~typography ~text_scale ~divider_height:thickness
  in
  let leading = Ui.Widget.empty () |> shell ~id:"journal-header-leading-placeholder" in
  let title =
    Ui.Widget.text
      ~style:(text_style typography.header_title)
      ~max_lines:1
      ~overflow:Ui.Style.Text_overflow.Clip
      (Context.title context)
    |> test_id "journal-header-title"
    |> Ui.Widget.semantics
         ~properties:
           (Ui.Semantics.create ~label:(Context.semantics_label context) ~sort_key:2. ())
    |> test_id "journal-date-context"
  in
  let subtitle =
    Ui.Widget.text
      ~style:(text_style typography.header_subtitle)
      ~max_lines:1
      ~text_align:Ui.Style.Text_align.Center
      ~overflow:Ui.Style.Text_overflow.Clip
      (Context.subtitle context)
    |> test_id "journal-header-subtitle"
    |> Ui.Widget.center
    |> Ui.Widget.sized_box ~height:subtitle_height
  in
  let flexible_space =
    Ui.Widget.Stack.create
      [ Ui.Widget.Stack.positioned
          ~left:0.
          ~top:(top_inset +. toolbar_height)
          ~right:0.
          subtitle
      ; Ui.Widget.Stack.positioned
          ~left:0.
          ~right:0.
          ~bottom:0.
          (Ui.Material.divider ~thickness ()
           |> test_id "journal-header-divider"
           |> Ui.Widget.sized_box ~height:thickness)
      ]
    |> test_id "journal-header-flexible-space"
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
                ~sort_key:3.
                ())
      |> shell ~id:"journal-account-menu-target"
  in
  Ui.Widget.Sliver.app_bar
    ~key:(Ui.Key.string "journal-header-app-bar")
    ~pinned:true
    ~expanded_height
    ~collapsed_height
    ~floating:false
    ~snap:false
    ~stretch:false
    ~toolbar_height
    ~force_elevated:false
    ~automatically_imply_leading:false
    ~center_title:true
    ~elevation:0.
    ~leading
    ~flexible_space
    ~actions:[ account ]
    ~title
    ()
  |> Ui.Widget.Sliver.with_test_id (Ui.Test_id.string "journal-header")
;;
