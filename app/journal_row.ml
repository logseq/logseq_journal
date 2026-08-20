module Tokens = Journal_visual_tokens
module Ui = Bonsai_flutter_ui

module Item = struct
  type t =
    { id : string
    ; source : string option
    ; task_state : Journal_model.task_state
    ; child_count : int
    ; time : string option
    ; supporting : string list
    }

  let of_block block =
    { id = Journal_model.id block
    ; source = Some (Journal_model.source block)
    ; task_state = Journal_model.task_state block
    ; child_count = Journal_model.child_count block
    ; time = Some (Journal_time.format_hh_mm (Journal_model.creation_time block))
    ; supporting = []
    }
  ;;

  let of_timeline_entry (entry : Journal_graph_projection.timeline_entry) =
    let item = of_block entry.block in
    { item with
      supporting =
        List.map
          (fun (summary : Journal_graph_projection.child_summary) -> summary.source)
          entry.child_summaries
    }
  ;;

  let corrupt ~id ~source =
    let source =
      match source with
      | Some source when Result.is_ok (Journal_validation.validate_source source) ->
        Some source
      | Some _ | None -> None
    in
    { id
    ; source
    ; task_state = Journal_model.No_status
    ; child_count = 0
    ; time = None
    ; supporting = []
    }
  ;;

  let source_for_detail t = t.source
  let id t = t.id
  let display_source t = Option.value t.source ~default:"Unavailable journal entry"
  let logical_lines source = String.split_on_char '\n' source

  let take count values =
    let rec loop remaining reversed = function
      | _ when remaining <= 0 -> List.rev reversed
      | [] -> List.rev reversed
      | value :: rest -> loop (remaining - 1) (value :: reversed) rest
    in
    loop count [] values
  ;;

  let preview t ~expanded =
    let source = take 4 (logical_lines (display_source t)) in
    if expanded || List.length source = 4
    then source, []
    else (
      let remaining = 4 - List.length source in
      let supporting = t.supporting |> List.concat_map logical_lines |> take remaining in
      source, supporting)
  ;;

  let visible_line_count t ~expanded =
    let source, supporting = preview t ~expanded in
    Int.max 1 (List.length source + List.length supporting)
  ;;

  let semantic_label_for_state t ~expanded =
    let source, supporting = preview t ~expanded in
    let text = String.concat ", " (source @ supporting) in
    let status =
      match t.task_state with
      | Journal_model.No_status -> ""
      | status -> ", status " ^ Journal_model.status_name status
    in
    match t.time with
    | Some time -> text ^ status ^ ", created at " ^ time
    | None -> text ^ status
  ;;

  let semantic_label t = semantic_label_for_state t ~expanded:true
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

let minimum_target child =
  Ui.Widget.constrained_box
    ~constraints:
      (Ui.Layout.Box_constraints.create
         ~min_width:Tokens.hit_regions.minimum_target
         ~min_height:Tokens.hit_regions.minimum_target
         ())
    child
;;

let pressable
      ~tokens
      ~reduced_motion
      ~control_id
      ~label
      ~hint
      ~value
      ~sort_key
      ~on_press
      child
  =
  let motion = Tokens.motion ~reduced_motion in
  Ui.Widget.pressable
    ~overlay_color:(Tokens.interaction tokens).pressed
    ~release_delay_ms:motion.press_release_ms
    ~on_press
    ~child
    ()
  |> test_id control_id
  |> Ui.Widget.semantics
       ~on_action:on_press
       ~properties:
         (Ui.Semantics.create
            ~label
            ~hint
            ~value
            ~role:Ui.Semantics.Role.Button
            ~sort_key
            ~enabled:true
            ~focusable:true
            ~actions:[ Ui.Semantics.Action.Tap ]
            ())
;;

let disclosure_indicator ~tokens ~rtl ~expanded item =
  if item.Item.child_count = 0
  then None
  else
    Ui.Widget.icon
      ~font_family:"MaterialIcons"
      ~size:Tokens.row_geometry.disclosure_visual
      ~color:(Tokens.palette tokens).text_secondary
      ~code_point:(if expanded then 0xe246 else if rtl then 0xe15e else 0xe15f)
      ()
    |> test_id ("journal-row-disclosure-icon:" ^ Item.id item)
    |> Ui.Widget.center
    |> Ui.Widget.sized_box ~width:Tokens.row_geometry.disclosure_visual
    |> test_id ("journal-row-disclosure-indicator:" ^ Item.id item)
    |> Option.some
;;

let text_line ~tokens ~item ~kind ~index source =
  let token, color, prefix =
    match kind with
    | `Source -> Tokens.typography.entry, (Tokens.palette tokens).text_primary, "source"
    | `Supporting ->
      Tokens.typography.supporting, (Tokens.palette tokens).text_secondary, "supporting"
  in
  Ui.Widget.text
    ~style:(text_style token color)
    ~max_lines:1
    ~overflow:Ui.Style.Text_overflow.Ellipsis
    ~text_align:Ui.Style.Text_align.Start
    source
  |> test_id (Printf.sprintf "journal-row-%s:%s:%d" prefix (Item.id item) index)
;;

let time_slot tokens profile item ~show_timestamp =
  let child =
    match item.Item.time, show_timestamp with
    | None, _ | Some _, false -> Ui.Widget.empty ()
    | Some time, true ->
      Ui.Widget.text
        ~style:
          (text_style Tokens.typography.timestamp (Tokens.palette tokens).text_timestamp)
        ~max_lines:1
        ~text_align:Ui.Style.Text_align.End
        time
      |> test_id ("journal-row-time:" ^ Item.id item)
  in
  Ui.Widget.constrained_box
    ~constraints:
      (Ui.Layout.Box_constraints.create
         ~min_width:profile.Tokens.time_slot_width
         ~max_width:profile.time_slot_width
         ())
    child
  |> test_id ("journal-row-time-slot:" ^ Item.id item)
;;

let status_rail ~tokens ~profile item ~visible_lines =
  Option.map
    (fun color ->
       Ui.Widget.empty ()
       |> Ui.Widget.decorated_box
            ~decoration:
              (Ui.Style.Decoration.create
                 ~background:color
                 ~border_radius:Tokens.row_geometry.status_rail_radius
                 ())
       |> test_id ("journal-row-status-rail:" ^ Item.id item)
       |> Ui.Widget.sized_box
            ~width:Tokens.row_geometry.status_rail_width
            ~height:(float_of_int visible_lines *. profile.Tokens.block_line_height)
       |> test_id ("journal-row-status-rail-size:" ^ Item.id item))
    (Tokens.status_rail_color tokens item.Item.task_state)
;;

let view
      ~tokens
      ~profile
      ~device_pixel_ratio
      ~rtl
      ~item
      ~show_timestamp
      ~expanded
      ~show_divider
      ~sort_base
      ~reduced_motion
      ~on_toggle_children
  =
  let source_lines, supporting_lines = Item.preview item ~expanded in
  let visible_lines = Item.visible_line_count item ~expanded in
  let row_extent = Tokens.block_extent ~profile ~visible_lines in
  let source =
    let source_widgets =
      List.mapi
        (fun index line -> text_line ~tokens ~item ~kind:`Source ~index line)
        source_lines
    in
    let supporting_widgets =
      List.mapi
        (fun index line -> text_line ~tokens ~item ~kind:`Supporting ~index line)
        supporting_lines
    in
    List.map Ui.Widget.Flex.fixed (source_widgets @ supporting_widgets)
    |> Ui.Widget.Flex.column
    |> test_id ("journal-row-text-stack:" ^ Item.id item)
    |> Ui.Widget.align ~alignment:Ui.Layout.Alignment.Top_start
    |> test_id ("journal-row-body-content:" ^ Item.id item)
    |> Ui.Widget.padding
         ~insets:
           (Ui.Layout.Edge_insets.only
              ~left:(if rtl then Tokens.spacing.x2 else 0.)
              ~right:(if rtl then 0. else Tokens.spacing.x2)
              ())
    |> test_id ("journal-row-source-gap:" ^ Item.id item)
  in
  let disclosure = disclosure_indicator ~tokens ~rtl ~expanded item in
  let time = time_slot tokens profile item ~show_timestamp in
  let fixed_options widgets = List.filter_map (Option.map Ui.Widget.Flex.fixed) widgets in
  let inline =
    Ui.Widget.Flex.row
      ~key:(Ui.Key.string ("journal-row-inline-layout:" ^ Item.id item))
      [ Ui.Widget.Flex.flexible source ]
    |> test_id ("journal-row-inline:" ^ Item.id item)
  in
  let layout =
    Ui.Widget.Flex.row
      ~key:(Ui.Key.string ("journal-row-layout:" ^ Item.id item))
      ([ Ui.Widget.Flex.expanded inline; Ui.Widget.Flex.fixed time ]
       @ fixed_options [ disclosure ])
    |> test_id
         ((match profile.Tokens.kind with
           | Tokens.Compact -> "journal-row-compact:"
           | Tokens.Adaptive -> "journal-row-adaptive:")
          ^ Item.id item)
  in
  let content =
    layout
    |> Ui.Widget.padding
         ~insets:
           (Ui.Layout.Edge_insets.only
              ~left:
                (if rtl
                 then Tokens.row_geometry.trailing_inset
                 else profile.content_leading)
              ~right:
                (if rtl
                 then profile.content_leading
                 else Tokens.row_geometry.trailing_inset)
              ~top:Tokens.spacing.x2
              ~bottom:Tokens.spacing.x2
              ())
    |> test_id ("journal-row-body-padding:" ^ Item.id item)
    |> Ui.Widget.sized_box
         ~key:
           (Ui.Key.string
              (Printf.sprintf
                 "journal-row-body:%s:%.0f:%.0f"
                 (Item.id item)
                 row_extent
                 profile.time_slot_width))
         ~height:row_extent
    |> test_id ("journal-row-body-surface:" ^ Item.id item)
  in
  let body =
    if item.Item.child_count > 0
    then
      content
      |> pressable
           ~tokens
           ~reduced_motion
           ~control_id:("journal-row-toggle-children:" ^ Item.id item)
           ~label:(Item.semantic_label_for_state item ~expanded)
           ~hint:
             (if expanded then "Hide direct child blocks" else "Show direct child blocks")
           ~value:(if expanded then "Expanded" else "Collapsed")
           ~sort_key:(sort_base +. 2.)
           ~on_press:on_toggle_children
      |> fun target ->
      if expanded
      then target
      else
        minimum_target target
        |> test_id ("journal-row-toggle-children-target:" ^ Item.id item)
    else
      content
      |> Ui.Widget.semantics
           ~properties:
             (Ui.Semantics.create
                ~label:(Item.semantic_label_for_state item ~expanded)
                ~role:Ui.Semantics.Role.Generic
                ~sort_key:(sort_base +. 2.)
                ())
  in
  let children = ref [ Ui.Widget.Stack.child body ] in
  (match status_rail ~tokens ~profile item ~visible_lines with
   | None -> ()
   | Some rail ->
     let offset = profile.Tokens.content_leading -. Tokens.spacing.x3 in
     children
     := (if rtl
         then Ui.Widget.Stack.positioned ~right:offset ~top:Tokens.spacing.x2 rail
         else Ui.Widget.Stack.positioned ~left:offset ~top:Tokens.spacing.x2 rail)
        :: !children);
  if show_divider
  then (
    let divider =
      Ui.Widget.empty ()
      |> Ui.Widget.decorated_box
           ~decoration:
             (Ui.Style.Decoration.create ~background:(Tokens.palette tokens).divider ())
      |> Ui.Widget.sized_box
           ~height:(Tokens.physical_divider_thickness ~device_pixel_ratio)
      |> test_id ("journal-row-divider:" ^ Item.id item)
      |> Ui.Widget.padding ~insets:(Ui.Layout.Edge_insets.only ~left:0. ~right:0. ())
      |> test_id ("journal-row-divider-padding:" ^ Item.id item)
    in
    children
    := Ui.Widget.Stack.positioned ~left:0. ~right:0. ~bottom:0. divider :: !children);
  Ui.Widget.Stack.create (List.rev !children)
  |> Ui.Widget.sized_box ~height:row_extent
  |> test_id ("journal-row-extent:" ^ Item.id item)
  |> Ui.Widget.decorated_box
       ~decoration:
         (Ui.Style.Decoration.create ~background:(Tokens.palette tokens).background ())
  |> Ui.Widget.environment_boundary
  |> test_id ("journal-row:" ^ Item.id item)
;;
