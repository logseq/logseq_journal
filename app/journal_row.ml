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
    ; task_state = Journal_model.Not_a_task
    ; child_count = 0
    ; time = None
    ; supporting = []
    }
  ;;

  let source_for_detail t = t.source
  let id t = t.id
  let display_source t = Option.value t.source ~default:"Unavailable journal entry"

  let line_count source =
    let lines = ref 1 in
    String.iter (fun character -> if Char.equal character '\n' then incr lines) source;
    !lines
  ;;

  let preview t =
    let source_lines = Int.min 3 (line_count (display_source t)) in
    let rec take_supporting remaining reversed = function
      | [] -> List.rev reversed
      | _ when remaining = 0 -> List.rev reversed
      | source :: rest ->
        let lines = Int.min remaining (line_count source) in
        take_supporting (remaining - lines) ((source, lines) :: reversed) rest
    in
    source_lines, take_supporting (3 - source_lines) [] t.supporting
  ;;

  let semantic_label t =
    match t.time with
    | Some time -> display_source t ^ ", created at " ^ time
    | None -> display_source t
  ;;

  let semantic_label_for_state t ~expanded =
    let source =
      match expanded with
      | true -> display_source t
      | false ->
        let _, supporting = preview t in
        List.fold_left
          (fun label (supporting, _) -> label ^ ", " ^ supporting)
          (display_source t)
          supporting
    in
    match t.time with Some time -> source ^ ", created at " ^ time | None -> source
  ;;
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
      ~role
      ~checked
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
            ?value
            ~role
            ?checked
            ~sort_key
            ~enabled:true
            ~focusable:true
            ~actions:[ Ui.Semantics.Action.Tap ]
            ())
;;

type task_control = { target : Ui.Widget.t }

let task_control ~tokens ~reduced_motion ~sort_base item on_task_toggle =
  let palette = Tokens.palette tokens in
  match item.Item.task_state with
  | Journal_model.Not_a_task -> None
  | (Todo | Done) as state ->
    let done_ = state = Journal_model.Done in
    let source = Item.display_source item in
    let glyph =
      Ui.Widget.icon
        ~font_family:"MaterialIcons"
        ~size:(if done_ then 10. else Tokens.row_geometry.task_visual)
        ~color:(if done_ then palette.on_success else palette.text_primary)
        ~code_point:(if done_ then 0xe156 else 0xe504)
        ()
      |> test_id ("journal-row-task-icon:" ^ Item.id item)
    in
    let visual =
      (if done_
       then
         glyph
         |> Ui.Widget.center
         |> Ui.Widget.decorated_box
              ~decoration:
                (Ui.Style.Decoration.create
                   ~background:palette.success
                   ~border_radius:(Tokens.row_geometry.task_visual /. 2.)
                   ())
         |> test_id ("journal-row-task-visual:" ^ Item.id item)
         |> Ui.Widget.sized_box
              ~width:Tokens.row_geometry.task_visual
              ~height:Tokens.row_geometry.task_visual
       else glyph)
      |> Ui.Widget.center
      |> Ui.Widget.sized_box
           ~width:(Tokens.row_geometry.task_visual +. Tokens.spacing.x1)
           ~height:Tokens.hit_regions.minimum_target
      |> test_id ("journal-row-task-slot:" ^ Item.id item)
    in
    let target =
      visual
      |> pressable
           ~tokens
           ~reduced_motion
           ~control_id:("journal-row-task:" ^ Item.id item)
           ~label:((if done_ then "Mark as todo: " else "Mark as done: ") ^ source)
           ~hint:"Toggle task completion"
           ~value:(Some (if done_ then "Done" else "Todo"))
           ~role:Ui.Semantics.Role.Checkbox
           ~checked:(Some done_)
           ~sort_key:(sort_base +. 1.)
           ~on_press:on_task_toggle
      |> minimum_target
      |> test_id ("journal-row-task-target:" ^ Item.id item)
    in
    Some { target }
;;

let disclosure_indicator ~tokens ~rtl ~expanded item =
  if item.Item.child_count = 0
  then None
  else (
    let palette = Tokens.palette tokens in
    let glyph =
      Ui.Widget.icon
        ~font_family:"MaterialIcons"
        ~size:Tokens.row_geometry.disclosure_visual
        ~color:palette.text_secondary
        ~code_point:(if expanded then 0xe246 else if rtl then 0xe15e else 0xe15f)
        ()
      |> test_id ("journal-row-disclosure-icon:" ^ Item.id item)
    in
    glyph
    |> Ui.Widget.center
    |> Ui.Widget.sized_box ~width:Tokens.row_geometry.disclosure_visual
    |> test_id ("journal-row-disclosure-indicator:" ^ Item.id item)
    |> Option.some)
;;

let source_text tokens item ~max_lines =
  Ui.Widget.text
    ~style:(text_style Tokens.typography.entry (Tokens.palette tokens).text_primary)
    ~max_lines
    ~overflow:Ui.Style.Text_overflow.Ellipsis
    (Item.display_source item)
  |> test_id ("journal-row-source:" ^ Item.id item)
;;

let time_slot tokens profile item ~show_timestamp =
  let child =
    match item.Item.time, show_timestamp with
    | None, _ -> Ui.Widget.empty ()
    | Some _, false -> Ui.Widget.empty ()
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
      ~on_task_toggle
      ~on_toggle_children
  =
  let divider_thickness = Tokens.physical_divider_thickness ~device_pixel_ratio in
  let row_extent =
    if expanded
    then
      Tokens.expanded_parent_extent ~profile ~source:(Item.display_source item)
    else profile.top_level_extent
  in
  let body_height =
    row_extent -. if show_divider then divider_thickness else 0.
  in
  let source =
    let source_lines, supporting = Item.preview item in
    let supporting = if expanded then [] else supporting in
    let primary =
      source_text tokens item ~max_lines:source_lines
      |> Ui.Widget.padding
           ~insets:
             (Ui.Layout.Edge_insets.only
                ~left:(if rtl then Tokens.spacing.x2 else 0.)
                ~right:(if rtl then 0. else Tokens.spacing.x2)
                ())
      |> test_id ("journal-row-source-gap:" ^ Item.id item)
    in
    let text_lines =
      Ui.Widget.Flex.fixed primary
      :: List.mapi
           (fun index (supporting, max_lines) ->
              Ui.Widget.text
                ~style:
                  (text_style
                     Tokens.typography.supporting
                     (Tokens.palette tokens).text_secondary)
                ~max_lines
                ~overflow:Ui.Style.Text_overflow.Ellipsis
                supporting
              |> test_id
                   (Printf.sprintf "journal-row-supporting:%s:%d" (Item.id item) index)
              |> Ui.Widget.Flex.fixed)
           supporting
    in
    Ui.Widget.Flex.column text_lines
    |> test_id ("journal-row-text-stack:" ^ Item.id item)
    |> Ui.Widget.align ~alignment:Ui.Layout.Alignment.Top_start
    |> test_id ("journal-row-body-content:" ^ Item.id item)
  in
  let task = task_control ~tokens ~reduced_motion ~sort_base item on_task_toggle in
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
    match profile.Tokens.kind with
    | Tokens.Compact ->
      Ui.Widget.Flex.row
        ~key:(Ui.Key.string ("journal-row-compact-layout:" ^ Item.id item))
        ([ Ui.Widget.Flex.expanded inline; Ui.Widget.Flex.fixed time ]
         @ fixed_options [ disclosure ])
      |> test_id ("journal-row-compact:" ^ Item.id item)
    | Tokens.Adaptive ->
      Ui.Widget.Flex.row
        ~key:(Ui.Key.string ("journal-row-adaptive-layout:" ^ Item.id item))
        ([ Ui.Widget.Flex.expanded inline; Ui.Widget.Flex.fixed time ]
         @ fixed_options [ disclosure ])
      |> test_id ("journal-row-adaptive:" ^ Item.id item)
  in
  let body =
    let profile_key =
      Printf.sprintf
        "journal-row-body:%s:%.0f:%.0f"
        (Item.id item)
        row_extent
        profile.time_slot_width
    in
    let height = body_height in
    let trailing = Tokens.row_geometry.trailing_inset in
    let leading =
      match task with
      | None -> profile.Tokens.content_leading
      | Some _ -> Tokens.spacing.x1
    in
    let content =
      layout
      |> Ui.Widget.padding
           ~insets:
             (Ui.Layout.Edge_insets.only
                ~left:(if rtl then trailing else leading)
                ~right:(if rtl then leading else trailing)
                ~top:Tokens.spacing.x2
                ~bottom:Tokens.spacing.x2
                ())
      |> test_id ("journal-row-body-padding:" ^ Item.id item)
      |> Ui.Widget.sized_box ~key:(Ui.Key.string profile_key) ~height
      |> test_id ("journal-row-body-surface:" ^ Item.id item)
    in
    let body =
      if item.Item.child_count > 0
      then
        let target =
          content
          |> pressable
               ~tokens
               ~reduced_motion
               ~control_id:("journal-row-toggle-children:" ^ Item.id item)
               ~label:(Item.semantic_label_for_state item ~expanded)
               ~hint:
                 (if expanded
                  then "Hide direct child blocks"
                  else "Show direct child blocks")
               ~value:(Some (if expanded then "Expanded" else "Collapsed"))
               ~role:Ui.Semantics.Role.Button
               ~checked:None
               ~sort_key:(sort_base +. 2.)
               ~on_press:on_toggle_children
        in
        (if expanded then target else minimum_target target)
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
    match task with
    | None -> body
    | Some control ->
      let task_slot = Tokens.row_geometry.task_visual +. Tokens.spacing.x1 in
      let leading_offset =
        profile.Tokens.content_leading
        +. ((task_slot -. Tokens.hit_regions.minimum_target) /. 2.)
      in
      let body_offset = leading_offset +. Tokens.hit_regions.minimum_target in
      let target =
        let top = (height -. Tokens.hit_regions.minimum_target) /. 2. in
        if rtl
        then Ui.Widget.Stack.positioned ~right:leading_offset ~top control.target
        else Ui.Widget.Stack.positioned ~left:leading_offset ~top control.target
      in
      let body =
        if rtl
        then Ui.Widget.Stack.positioned ~left:0. ~right:body_offset ~top:0. body
        else Ui.Widget.Stack.positioned ~left:body_offset ~right:0. ~top:0. body
      in
      Ui.Widget.Stack.create [ body; target ] |> Ui.Widget.sized_box ~height
  in
  let divider =
    Ui.Widget.empty ()
    |> Ui.Widget.decorated_box
         ~decoration:
           (Ui.Style.Decoration.create ~background:(Tokens.palette tokens).divider ())
    |> Ui.Widget.sized_box ~height:divider_thickness
    |> test_id ("journal-row-divider:" ^ Item.id item)
    |> Ui.Widget.padding
         ~insets:
           (Ui.Layout.Edge_insets.only ~left:0. ~right:0. ())
    |> test_id ("journal-row-divider-padding:" ^ Item.id item)
  in
  Ui.Widget.Flex.column
    ([ Ui.Widget.Flex.fixed body ]
     @ if show_divider then [ Ui.Widget.Flex.fixed divider ] else [])
  |> Ui.Widget.sized_box ~height:row_extent
  |> test_id ("journal-row-extent:" ^ Item.id item)
  |> Ui.Widget.decorated_box
       ~decoration:(Ui.Style.Decoration.create ~background:(Tokens.palette tokens).background ())
  |> Ui.Widget.environment_boundary
  |> test_id ("journal-row:" ^ Item.id item)
;;
