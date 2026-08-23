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

let text_style (token : Tokens.text_token) color =
  Ui.Style.Text_style.create
    ~font_size:token.font_size
    ~font_weight:token.weight
    ~line_height:(token.line_height /. token.font_size)
    ~color
    ()
;;

let glyph ~tokens ~id ~code_point =
  let palette = Tokens.palette tokens in
  Ui.Widget.icon
    ~font_family:"MaterialIcons"
    ~size:18.
    ~color:palette.text_primary
    ~code_point
    ()
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

let view ~tokens ~text_scale ~device_pixel_ratio ~context ~on_account_menu =
  let palette = Tokens.palette tokens in
  let scale = Float.max 1. text_scale in
  let content_height = Tokens.header_geometry.content_height *. scale in
  let leading =
    Ui.Widget.empty ()
    |> shell ~id:"journal-header-leading-placeholder"
  in
  let title =
    Ui.Widget.text
      ~style:(text_style Tokens.typography.header_title palette.text_primary)
      ~max_lines:1
      ~overflow:Ui.Style.Text_overflow.Clip
      (Context.title context)
    |> test_id "journal-header-title"
    |> Ui.Widget.sized_box ~height:(Tokens.typography.header_title.line_height *. scale)
  in
  let subtitle =
    Ui.Widget.text
      ~style:(text_style Tokens.typography.header_subtitle palette.text_secondary)
      ~max_lines:1
      ~overflow:Ui.Style.Text_overflow.Clip
      (Context.subtitle context)
    |> test_id "journal-header-subtitle"
    |> Ui.Widget.sized_box ~height:(Tokens.typography.header_subtitle.line_height *. scale)
  in
  let date =
    Ui.Widget.Flex.column [ Ui.Widget.Flex.fixed title; Ui.Widget.Flex.fixed subtitle ]
    |> test_id "journal-date-context"
    |> Ui.Widget.semantics
         ~properties:
           (Ui.Semantics.create ~label:(Context.semantics_label context) ~sort_key:2. ())
    |> Ui.Widget.center
    |> test_id "journal-header-center"
  in
  let account =
    match on_account_menu with
    | None ->
      Ui.Widget.empty ()
      |> shell ~id:"journal-header-account-placeholder"
    | Some on_press ->
      let icon =
        glyph ~tokens ~id:"journal-account-icon" ~code_point:0xe853
      in
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
  let sides =
    Ui.Widget.Flex.row
      [ Ui.Widget.Flex.expanded
          (Ui.Widget.align ~alignment:Ui.Layout.Alignment.Center_start leading)
      ; Ui.Widget.Flex.expanded
          (Ui.Widget.align ~alignment:Ui.Layout.Alignment.Center_end account)
      ]
  in
  let stack =
    Ui.Widget.Stack.create [ Ui.Widget.Stack.child sides; Ui.Widget.Stack.child date ]
    |> test_id "journal-header-stack"
    |> Ui.Widget.sized_box ~height:content_height
    |> test_id "journal-header-content-height"
  in
  let divider =
    Ui.Widget.empty ()
    |> Ui.Widget.decorated_box
         ~decoration:(Ui.Style.Decoration.create ~background:palette.divider ())
    |> Ui.Widget.sized_box ~height:(Tokens.physical_divider_thickness ~device_pixel_ratio)
    |> test_id "journal-header-divider"
  in
  let content =
    stack
    |> Ui.Widget.padding
         ~insets:
           (Ui.Layout.Edge_insets.symmetric
              ~horizontal:Tokens.header_geometry.horizontal_inset
              ~vertical:Tokens.header_geometry.vertical_inset
              ())
    |> test_id "journal-header-padding"
    |> Ui.Widget.safe_area ~bottom:false
    |> test_id "journal-header-safe-area"
  in
  Ui.Widget.Flex.column [ Ui.Widget.Flex.fixed content; Ui.Widget.Flex.fixed divider ]
  |> Ui.Widget.decorated_box
       ~decoration:(Ui.Style.Decoration.create ~background:palette.header ())
  |> test_id "journal-header-surface"
  |> Ui.Widget.environment_boundary
  |> test_id "journal-header"
;;
