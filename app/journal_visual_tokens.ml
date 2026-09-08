module Ui = Bonsai_flutter_ui

type swipe_action_colors =
  { background : Ui.Style.Color.t
  ; foreground : Ui.Style.Color.t
  }

module Color_exceptions = struct
  type presentation =
    | Light
    | Dark

  type status_palette =
    { no_status : swipe_action_colors
    ; todo : swipe_action_colors
    ; doing : swipe_action_colors
    ; done_ : swipe_action_colors
    ; backlog : swipe_action_colors
    }

  let rgb red green blue = Ui.Style.Color.rgb ~red ~green ~blue
  let transparent = Ui.Style.Color.argb ~alpha:0 ~red:0 ~green:0 ~blue:0

  let light_status =
    { no_status = { background = transparent; foreground = rgb 0 38 47 }
    ; todo = { background = rgb 88 92 126; foreground = rgb 255 255 255 }
    ; doing = { background = rgb 0 103 124; foreground = rgb 255 255 255 }
    ; done_ = { background = rgb 0 107 87; foreground = rgb 255 255 255 }
    ; backlog = { background = rgb 124 58 237; foreground = rgb 255 255 255 }
    }
  ;;

  let dark_status =
    { no_status = { background = transparent; foreground = rgb 167 184 188 }
    ; todo = { background = rgb 192 196 235; foreground = rgb 42 46 80 }
    ; doing = { background = rgb 134 209 233; foreground = rgb 0 54 66 }
    ; done_ = { background = rgb 131 214 189; foreground = rgb 0 56 43 }
    ; backlog = { background = rgb 124 58 237; foreground = rgb 255 255 255 }
    }
  ;;

  let destructive_swipe = { background = rgb 186 26 26; foreground = rgb 255 255 255 }

  let status_palette = function
    | Light -> light_status
    | Dark -> dark_status
  ;;

  let status_rail_color ~presentation status =
    let palette = status_palette presentation in
    match status with
    | Journal_model.No_status -> None
    | status ->
      (match Journal_model.status_category status with
       | None -> None
       | Some Todo_category -> Some palette.todo.background
       | Some Doing_category -> Some palette.doing.background
       | Some Done_category -> Some palette.done_.background
       | Some Later_category -> Some palette.backlog.background)
  ;;

  let destructive_swipe_action ~presentation:_ = destructive_swipe

  let status_swipe_action ~presentation =
    let palette = status_palette presentation in
    function
    | Journal_model.No_status -> palette.no_status
    | Todo -> palette.todo
    | Doing | In_review | Now -> palette.doing
    | Done | Canceled -> palette.done_
    | Backlog | Waiting | Later -> palette.backlog
  ;;
end

type text_token =
  { font_size : float
  ; line_height : float
  ; weight : Ui.Style.Font_weight.t
  }

type typography =
  { header_title : text_token
  ; header_subtitle : text_token
  ; day_heading : text_token
  ; date_weekday : text_token
  ; entry : text_token
  ; supporting : text_token
  ; timestamp : text_token
  ; input : text_token
  ; button_label : text_token
  ; dialog_title : text_token
  ; manager_title : text_token
  }

type typography_preset =
  | Dense
  | Balanced
  | Comfortable

type spacing =
  { x1 : float
  ; x2 : float
  ; x3 : float
  ; x4 : float
  ; x5 : float
  ; x6 : float
  ; x7 : float
  }

type hit_regions =
  { header_visual : float
  ; minimum_target : float
  }

type header_geometry =
  { content_height : float
  ; horizontal_inset : float
  ; vertical_inset : float
  }

type composer_geometry =
  { horizontal_margin : float
  ; maximum_lines : int
  }

type row_geometry =
  { time_slot_base : float
  ; trailing_inset : float
  ; day_heading_before : float
  ; day_heading_after : float
  ; entry_vertical_padding : float
  ; disclosure_visual : float
  ; status_rail_width : float
  ; status_rail_radius : float
  }

type preview_geometry =
  { connector_leading : float
  ; bullet_center_leading : float
  ; bullet_diameter : float
  ; text_leading : float
  ; narrow_leading_delta : float
  }

type motion =
  { press_release_ms : int
  ; route_transition_ms : int
  }

type profile_kind =
  | Compact
  | Adaptive

type row_profile =
  { kind : profile_kind
  ; block_line_height : float
  ; continuation_extent : float
  ; day_header_extent : float
  ; content_leading : float
  ; time_slot_width : float
  ; source_text_width : float
  ; text_scale : float
  ; date_text_scale : float
  ; entry_font_size : float
  ; supporting_font_size : float
  }

type fixed_extent_role =
  | Children_loading
  | Children_more
  | Day_heading
  | Day_continuation
  | Feed_continuation

type text_measurement =
  { visible_lines : int
  ; did_overflow : bool
  }

type t =
  { presentation : Color_exceptions.presentation
  ; high_contrast : bool
  }

let resolve ~brightness ~high_contrast =
  let presentation =
    match brightness with
    | Bonsai_flutter.Environment.Light -> Color_exceptions.Light
    | Bonsai_flutter.Environment.Dark -> Color_exceptions.Dark
  in
  { presentation; high_contrast }
;;

let weekday_opacity t = if t.high_contrast then 0.85 else 0.50
let text_token font_size line_height weight = { font_size; line_height; weight }

let typography = function
  | Dense ->
    { header_title = text_token 24. 27.6 Ui.Style.Font_weight.Semi_bold
    ; header_subtitle = text_token 15. 20. Ui.Style.Font_weight.Medium
    ; day_heading = text_token 20. 24. Ui.Style.Font_weight.Normal
    ; date_weekday = text_token 12. 14.4 Ui.Style.Font_weight.Medium
    ; entry = text_token 15. 20. Ui.Style.Font_weight.Normal
    ; supporting = text_token 14. 20. Ui.Style.Font_weight.Normal
    ; timestamp = text_token 13. 18. Ui.Style.Font_weight.Normal
    ; input = text_token 16. 24. Ui.Style.Font_weight.Normal
    ; button_label = text_token 14. 20. Ui.Style.Font_weight.Medium
    ; dialog_title = text_token 20. 26. Ui.Style.Font_weight.Semi_bold
    ; manager_title = text_token 24. 32. Ui.Style.Font_weight.Semi_bold
    }
  | Balanced ->
    { header_title = text_token 24. 27.6 Ui.Style.Font_weight.Semi_bold
    ; header_subtitle = text_token 15. 20. Ui.Style.Font_weight.Medium
    ; day_heading = text_token 20. 24. Ui.Style.Font_weight.Normal
    ; date_weekday = text_token 12. 14.4 Ui.Style.Font_weight.Medium
    ; entry = text_token 16. 22. Ui.Style.Font_weight.Normal
    ; supporting = text_token 14. 20. Ui.Style.Font_weight.Normal
    ; timestamp = text_token 13. 18. Ui.Style.Font_weight.Normal
    ; input = text_token 16. 24. Ui.Style.Font_weight.Normal
    ; button_label = text_token 14. 20. Ui.Style.Font_weight.Medium
    ; dialog_title = text_token 20. 26. Ui.Style.Font_weight.Semi_bold
    ; manager_title = text_token 24. 32. Ui.Style.Font_weight.Semi_bold
    }
  | Comfortable ->
    { header_title = text_token 24. 27.6 Ui.Style.Font_weight.Semi_bold
    ; header_subtitle = text_token 16. 22. Ui.Style.Font_weight.Medium
    ; day_heading = text_token 20. 24. Ui.Style.Font_weight.Normal
    ; date_weekday = text_token 12. 14.4 Ui.Style.Font_weight.Medium
    ; entry = text_token 17. 24. Ui.Style.Font_weight.Normal
    ; supporting = text_token 15. 22. Ui.Style.Font_weight.Normal
    ; timestamp = text_token 14. 20. Ui.Style.Font_weight.Normal
    ; input = text_token 16. 24. Ui.Style.Font_weight.Normal
    ; button_label = text_token 15. 20. Ui.Style.Font_weight.Medium
    ; dialog_title = text_token 22. 28. Ui.Style.Font_weight.Semi_bold
    ; manager_title = text_token 28. 34. Ui.Style.Font_weight.Semi_bold
    }
;;

let typography_preset_of_stored_value = function
  | Some "dense" -> Dense
  | Some "balanced" -> Balanced
  | Some "comfortable" -> Comfortable
  | None | Some _ -> Balanced
;;

let stored_value_of_typography_preset = function
  | Dense -> "dense"
  | Balanced -> "balanced"
  | Comfortable -> "comfortable"
;;

let spacing = { x1 = 4.; x2 = 8.; x3 = 12.; x4 = 16.; x5 = 20.; x6 = 24.; x7 = 28. }
let hit_regions = { header_visual = 30.; minimum_target = 44. }

let header_geometry =
  { content_height = 48.; horizontal_inset = 12.; vertical_inset = 4. }
;;

let composer_geometry = { horizontal_margin = 12.; maximum_lines = 5 }

let row_geometry =
  { time_slot_base = 52.
  ; trailing_inset = 24.
  ; day_heading_before = 20.
  ; day_heading_after = 10.
  ; entry_vertical_padding = 6.
  ; disclosure_visual = 14.
  ; status_rail_width = 4.
  ; status_rail_radius = 2.
  }
;;

let supporting_preview_gap = spacing.x1

let preview_geometry =
  { connector_leading = 32.
  ; bullet_center_leading = 50.
  ; bullet_diameter = 3.
  ; text_leading = 68.
  ; narrow_leading_delta = 8.
  }
;;

let motion ~reduced_motion =
  if reduced_motion
  then { press_release_ms = 0; route_transition_ms = 0 }
  else { press_release_ms = 80; route_transition_ms = 180 }
;;

let physical_divider_thickness ~device_pixel_ratio = 1. /. Float.max 1. device_pixel_ratio
let timeline_max_width = 720.
let date_gap = 14.

let date_scale ~viewport_width ~text_scale =
  (* Reserve both native header actions so sync/error changes do not resize dates.
     The date and weekday occupy at most 130dp in the supported default font. *)
  let available_width =
    Float.min timeline_max_width viewport_width -. 56. -. 32. -. 88.
  in
  Float.min
    (Float.max 1. text_scale)
    (Float.max 1. ((available_width -. date_gap) /. 130.))
;;

let select_row_profile ~preset ~viewport_width ~text_scale =
  let typography = typography preset in
  let narrow = Float.compare viewport_width 360. < 0 in
  let content_leading = if narrow then 24. else 32. in
  let scale = Float.max 1. text_scale in
  let block_line_height = typography.entry.line_height *. scale in
  let supporting_line_height = typography.supporting.line_height *. scale in
  let date_text_scale = date_scale ~viewport_width ~text_scale in
  let day_heading_line_height = typography.day_heading.line_height *. date_text_scale in
  let day_header_extent =
    Float.ceil
      (row_geometry.day_heading_before
       +. day_heading_line_height
       +. row_geometry.day_heading_after)
  in
  let time_slot_width =
    if (not narrow) && Float.compare scale 1.3 <= 0
    then row_geometry.time_slot_base
    else Float.ceil (row_geometry.time_slot_base *. scale)
  in
  let source_text_width =
    Float.max
      1.
      (Float.min timeline_max_width viewport_width
       -. content_leading
       -. row_geometry.trailing_inset
       -. time_slot_width
       -. spacing.x2
       -. row_geometry.disclosure_visual)
  in
  if (not narrow) && Float.compare scale 1.3 <= 0
  then
    { kind = Compact
    ; block_line_height
    ; continuation_extent = Float.ceil (28. +. supporting_line_height)
    ; day_header_extent
    ; content_leading
    ; time_slot_width
    ; source_text_width
    ; text_scale = scale
    ; date_text_scale
    ; entry_font_size = typography.entry.font_size
    ; supporting_font_size = typography.supporting.font_size
    }
  else
    { kind = Adaptive
    ; block_line_height
    ; continuation_extent = Float.ceil (28. +. supporting_line_height)
    ; day_header_extent
    ; content_leading
    ; time_slot_width
    ; source_text_width
    ; text_scale = scale
    ; date_text_scale
    ; entry_font_size = typography.entry.font_size
    ; supporting_font_size = typography.supporting.font_size
    }
;;

let block_extent ~profile ~visible_lines =
  let visible_lines = Int.max 1 (Int.min 5 visible_lines) in
  Float.ceil
    (Float.max
       hit_regions.minimum_target
       ((2. *. row_geometry.entry_vertical_padding)
        +. (float_of_int visible_lines *. profile.block_line_height)))
;;

let scalar_em_width scalar =
  if scalar = 0x0a || scalar = 0x0d
  then 0.
  else if scalar = 0x09 || scalar = 0x20
  then 0.33
  else if
    (scalar >= 0x0300 && scalar <= 0x036f)
    || (scalar >= 0x1ab0 && scalar <= 0x1aff)
    || (scalar >= 0x1dc0 && scalar <= 0x1dff)
    || (scalar >= 0x20d0 && scalar <= 0x20ff)
    || (scalar >= 0xfe00 && scalar <= 0xfe0f)
  then 0.
  else if
    (scalar >= 0x2e80 && scalar <= 0x9fff)
    || (scalar >= 0xac00 && scalar <= 0xd7af)
    || (scalar >= 0xf900 && scalar <= 0xfaff)
    || (scalar >= 0x1f000 && scalar <= 0x1faff)
  then 1.
  else if scalar >= Char.code 'A' && scalar <= Char.code 'Z'
  then 0.68
  else if
    (scalar >= Char.code 'a' && scalar <= Char.code 'z')
    || (scalar >= Char.code '0' && scalar <= Char.code '9')
  then 0.55
  else if scalar < 0x80
  then 0.4
  else 0.65
;;

let measure_text ~profile ~font_size ~max_lines value =
  let max_lines = Int.max 1 max_lines in
  let available_em =
    profile.source_text_width /. (Float.max 1. font_size *. profile.text_scale)
    |> Float.max 0.5
  in
  let length = String.length value in
  let rec loop offset lines occupied_em =
    if lines > max_lines
    then { visible_lines = max_lines; did_overflow = true }
    else if offset >= length
    then { visible_lines = lines; did_overflow = false }
    else (
      let decoded = String.get_utf_8_uchar value offset in
      let valid = Uchar.utf_decode_is_valid decoded in
      let scalar =
        if valid then Uchar.to_int (Uchar.utf_decode_uchar decoded) else Char.code '?'
      in
      let next_offset = offset + if valid then Uchar.utf_decode_length decoded else 1 in
      if scalar = 0x0a
      then loop next_offset (lines + 1) 0.
      else (
        let width = scalar_em_width scalar in
        if
          Float.compare occupied_em 0. > 0
          && Float.compare (occupied_em +. width) available_em > 0
        then loop next_offset (lines + 1) width
        else loop next_offset lines (occupied_em +. width)))
  in
  loop 0 1 0.
;;

let fixed_extent ~profile = function
  | Children_loading | Children_more -> block_extent ~profile ~visible_lines:1
  | Day_heading -> profile.day_header_extent
  | Day_continuation | Feed_continuation -> profile.continuation_extent
;;

let status_rail_color t status =
  Color_exceptions.status_rail_color ~presentation:t.presentation status
;;

let destructive_swipe_action t =
  Color_exceptions.destructive_swipe_action ~presentation:t.presentation
;;

let status_swipe_action t status =
  Color_exceptions.status_swipe_action ~presentation:t.presentation status
;;
