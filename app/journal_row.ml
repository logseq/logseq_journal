module Tokens = Journal_visual_tokens
module Ui = Bonsai_flutter_ui
module ID = Bonsai_flutter_spec.Id

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
  let accessible_text value = String.split_on_char '\n' value |> String.concat ", "

  type preview_text =
    { text : string
    ; max_lines : int
    ; did_overflow : bool
    }

  type preview =
    { source : preview_text
    ; supporting : preview_text list
    }

  let supporting_preview (t : t) ~profile =
    let rec allocate remaining = function
      | _ when remaining <= 0 -> []
      | [] -> []
      | text :: rest ->
        let measurement =
          Tokens.measure_text
            ~profile
            ~font_size:profile.Tokens.supporting_font_size
            ~max_lines:remaining
            text
        in
        let remaining = remaining - measurement.visible_lines in
        let tail = allocate remaining rest in
        let did_overflow = measurement.did_overflow || (remaining = 0 && rest <> []) in
        { text; max_lines = measurement.visible_lines; did_overflow } :: tail
    in
    allocate 2 t.supporting
  ;;

  let preview (t : t) ~profile ~expanded =
    let source = display_source t in
    let source_measurement =
      Tokens.measure_text
        ~profile
        ~font_size:profile.Tokens.entry_font_size
        ~max_lines:3
        source
    in
    { source =
        { text = source
        ; max_lines = source_measurement.visible_lines
        ; did_overflow = source_measurement.did_overflow
        }
    ; supporting = (if expanded then [] else supporting_preview t ~profile)
    }
  ;;

  let preview_line_count preview =
    List.fold_left
      (fun count supporting -> count + supporting.max_lines)
      preview.source.max_lines
      preview.supporting
  ;;

  let preview_extent ~profile preview =
    Tokens.block_extent ~profile ~visible_lines:(preview_line_count preview)
    +. if preview.supporting = [] then 0. else Tokens.supporting_preview_gap
  ;;

  let visible_extent (t : t) ~profile ~expanded =
    preview t ~profile ~expanded |> preview_extent ~profile
  ;;

  let semantic_label_for_state (t : t) ~preview =
    let text =
      accessible_text preview.source.text
      :: List.map (fun supporting -> accessible_text supporting.text) preview.supporting
      |> String.concat ", "
    in
    let status =
      match t.task_state with
      | Journal_model.No_status -> ""
      | status -> ", status " ^ Journal_model.status_name status
    in
    match t.time with
    | Some time -> text ^ status ^ ", created at " ^ time
    | None -> text ^ status
  ;;

  let semantic_label (t : t) =
    let status =
      match t.task_state with
      | Journal_model.No_status -> ""
      | status -> ", status " ^ Journal_model.status_name status
    in
    match t.time with
    | Some time -> accessible_text (display_source t) ^ status ^ ", created at " ^ time
    | None -> accessible_text (display_source t) ^ status
  ;;
end

let test_id value widget = Ui.Widget.with_test_id (Ui.Test_id.string value) widget

module Tail_fade = struct
  type props =
    { line_height : float
    ; fade_width : float
    }

  let encode_props props =
    let payload = Bytes.make 16 '\000' in
    Bytes.set_int64_le payload 0 (Int64.bits_of_float props.line_height);
    Bytes.set_int64_le payload 8 (Int64.bits_of_float props.fade_width);
    payload
  ;;

  let extension =
    Ui.Native_widget.Extension.create
      ~kind_id:(ID.Native_widget.Kind_id.of_int 1001)
      ~version:1
      ~capabilities:[]
      ~encode_props
      ~decode_event:(fun ~event_id:_ _ -> Error "Tail fade emits no events")
      ()
  ;;

  let wrap ~line_height ~fade_width child =
    Ui.Native_widget.widget
      extension
      ~props:{ line_height; fade_width }
      ~on_event:(fun _ -> ())
      ~children:[ child ]
      ()
  ;;
end

let text_style (token : Tokens.text_token) =
  Ui.Style.Text_style.create
    ~font_size:token.font_size
    ~font_weight:token.weight
    ~line_height:(token.line_height /. token.font_size)
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

let pressable ~reduced_motion ~control_id ~label ~hint ~value ~sort_key ~on_press child =
  let motion = Tokens.motion ~reduced_motion in
  Ui.Widget.pressable ~release_delay_ms:motion.press_release_ms ~on_press ~child ()
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

let disclosure_indicator ~rtl ~expanded item =
  if item.Item.child_count = 0
  then None
  else
    Material_icon_catalog.create
      ~size:Tokens.row_geometry.disclosure_visual
      (if expanded
       then Material_icon_catalog.Expand_more
       else if rtl
       then Material_icon_catalog.Chevron_left
       else Material_icon_catalog.Chevron_right)
    |> test_id ("journal-row-disclosure-icon:" ^ Item.id item)
    |> Ui.Widget.center
    |> Ui.Widget.sized_box ~width:Tokens.row_geometry.disclosure_visual
    |> test_id ("journal-row-disclosure-indicator:" ^ Item.id item)
    |> Option.some
;;

let preview_text ~token ~profile ~id ~fade_id ~max_lines ~did_overflow source =
  let text =
    Ui.Widget.text
      ~style:(text_style token)
      ~max_lines
      ~overflow:Ui.Style.Text_overflow.Clip
      ~text_align:Ui.Style.Text_align.Start
      source
    |> test_id id
  in
  if not did_overflow
  then text
  else
    text
    |> Tail_fade.wrap
         ~line_height:(token.Tokens.line_height *. profile.Tokens.text_scale)
         ~fade_width:(token.font_size *. profile.text_scale *. 1.5)
    |> test_id fade_id
;;

let time_slot typography profile item ~show_timestamp =
  let child =
    match item.Item.time, show_timestamp with
    | None, _ | Some _, false -> Ui.Widget.empty ()
    | Some time, true ->
      Ui.Widget.text
        ~style:(text_style typography.Tokens.timestamp)
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

let rail_body ~color ~task_state ~height ~id =
  match task_state with
  | Journal_model.Todo ->
    let gap_height = 4. in
    let maximum_dash_height = 10. in
    let dash_count =
      max
        2
        (int_of_float
           (Float.ceil ((height +. gap_height) /. (maximum_dash_height +. gap_height))))
    in
    let dash_height =
      (height -. (gap_height *. float_of_int (dash_count - 1))) /. float_of_int dash_count
    in
    let rec segments index =
      if index = dash_count
      then []
      else (
        let dash =
          Ui.Widget.empty ()
          |> Ui.Widget.decorated_box
               ~decoration:
                 (Ui.Style.Decoration.create
                    ~background:color
                    ~border_radius:Tokens.row_geometry.status_rail_radius
                    ())
          |> test_id (Printf.sprintf "%s:segment:%d" id index)
          |> Ui.Widget.sized_box
               ~width:Tokens.row_geometry.status_rail_width
               ~height:dash_height
        in
        dash
        ::
        (if index = dash_count - 1
         then []
         else
           (Ui.Widget.empty () |> Ui.Widget.sized_box ~height:gap_height)
           :: segments (index + 1)))
    in
    Ui.Widget.column (segments 0) |> test_id id
  | _ ->
    Ui.Widget.empty ()
    |> Ui.Widget.decorated_box
         ~decoration:
           (Ui.Style.Decoration.create
              ~background:color
              ~border_radius:Tokens.row_geometry.status_rail_radius
              ())
    |> test_id id
;;

let status_rail ~tokens ~profile item ~visible_lines =
  Option.map
    (fun color ->
       rail_body
         ~color
         ~task_state:item.Item.task_state
         ~height:(float_of_int visible_lines *. profile.Tokens.block_line_height)
         ~id:("journal-row-status-rail:" ^ Item.id item)
       |> Ui.Widget.sized_box
            ~width:Tokens.row_geometry.status_rail_width
            ~height:(float_of_int visible_lines *. profile.Tokens.block_line_height)
       |> test_id ("journal-row-status-rail-size:" ^ Item.id item))
    (Tokens.status_rail_color tokens item.Item.task_state)
;;

let view
      ~tokens
      ~typography
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
  let preview = Item.preview item ~profile ~expanded in
  let visible_lines = Item.preview_line_count preview in
  let row_extent = Item.preview_extent ~profile preview in
  let source =
    let source_widget =
      preview_text
        ~token:typography.Tokens.entry
        ~profile
        ~id:("journal-row-source:" ^ Item.id item)
        ~fade_id:("journal-row-source-tail-fade:" ^ Item.id item)
        ~max_lines:3
        ~did_overflow:preview.source.did_overflow
        preview.source.text
    in
    let supporting_widgets =
      List.mapi
        (fun index (supporting : Item.preview_text) ->
           let id = Printf.sprintf "journal-row-supporting:%s:%d" (Item.id item) index in
           preview_text
             ~token:typography.supporting
             ~profile
             ~id
             ~fade_id:
               (Printf.sprintf
                  "journal-row-supporting-tail-fade:%s:%d"
                  (Item.id item)
                  index)
             ~max_lines:supporting.max_lines
             ~did_overflow:supporting.did_overflow
             supporting.text
           |> Ui.Widget.opacity 0.65
           |> test_id
                (Printf.sprintf
                   "journal-row-supporting-opacity:%s:%d"
                   (Item.id item)
                   index)
           |> Ui.Widget.Flex.flexible ~flex:supporting.max_lines)
        preview.supporting
    in
    let gap =
      if supporting_widgets = []
      then []
      else
        [ Ui.Widget.empty ()
          |> Ui.Widget.sized_box ~height:Tokens.supporting_preview_gap
          |> test_id ("journal-row-supporting-gap:" ^ Item.id item)
          |> Ui.Widget.Flex.fixed
        ]
    in
    [ Ui.Widget.Flex.flexible ~flex:preview.source.max_lines source_widget ]
    @ gap
    @ supporting_widgets
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
  let disclosure = disclosure_indicator ~rtl ~expanded item in
  let time = time_slot typography profile item ~show_timestamp in
  let inline =
    Ui.Widget.Flex.row
      ~key:(Ui.Key.string ("journal-row-inline-layout:" ^ Item.id item))
      [ Ui.Widget.Flex.flexible source ]
    |> test_id ("journal-row-inline:" ^ Item.id item)
  in
  let metadata_alignment =
    if rtl then Ui.Layout.Alignment.Top_start else Ui.Layout.Alignment.Top_end
  in
  let metadata_line_extent =
    Float.max profile.Tokens.block_line_height Tokens.row_geometry.disclosure_visual
  in
  let metadata_slot child =
    child
    |> Ui.Widget.align ~alignment:metadata_alignment
    |> Ui.Widget.sized_box ~height:metadata_line_extent
    |> Ui.Widget.Flex.fixed
  in
  let metadata =
    Ui.Widget.Flex.row
      (metadata_slot time :: List.filter_map (Option.map metadata_slot) [ disclosure ])
    |> test_id ("journal-row-metadata:" ^ Item.id item)
    |> Ui.Widget.align ~alignment:metadata_alignment
    |> test_id ("journal-row-metadata-align:" ^ Item.id item)
    |> Ui.Widget.sized_box
         ~height:(row_extent -. (2. *. Tokens.row_geometry.entry_vertical_padding))
  in
  let layout =
    Ui.Widget.Flex.row
      ~key:(Ui.Key.string ("journal-row-layout:" ^ Item.id item))
      [ Ui.Widget.Flex.expanded inline; Ui.Widget.Flex.fixed metadata ]
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
              ~top:Tokens.row_geometry.entry_vertical_padding
              ~bottom:Tokens.row_geometry.entry_vertical_padding
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
           ~reduced_motion
           ~control_id:("journal-row-toggle-children:" ^ Item.id item)
           ~label:(Item.semantic_label_for_state item ~preview)
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
                ~label:(Item.semantic_label_for_state item ~preview)
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
         then
           Ui.Widget.Stack.positioned
             ~right:offset
             ~top:Tokens.row_geometry.entry_vertical_padding
             rail
         else
           Ui.Widget.Stack.positioned
             ~left:offset
             ~top:Tokens.row_geometry.entry_vertical_padding
             rail)
        :: !children);
  if show_divider
  then (
    let divider =
      let thickness = Tokens.physical_divider_thickness ~device_pixel_ratio in
      Ui.Material.divider ~thickness ()
      |> test_id ("journal-row-divider:" ^ Item.id item)
      |> Ui.Widget.sized_box ~height:thickness
      |> test_id ("journal-row-divider-extent:" ^ Item.id item)
      |> Ui.Widget.padding ~insets:(Ui.Layout.Edge_insets.only ~left:0. ~right:0. ())
      |> test_id ("journal-row-divider-padding:" ^ Item.id item)
    in
    children
    := Ui.Widget.Stack.positioned ~left:0. ~right:0. ~bottom:0. divider :: !children);
  Ui.Widget.Stack.create (List.rev !children)
  |> Ui.Widget.sized_box ~height:row_extent
  |> test_id ("journal-row-extent:" ^ Item.id item)
  |> Ui.Widget.environment_boundary
  |> test_id ("journal-row:" ^ Item.id item)
;;
