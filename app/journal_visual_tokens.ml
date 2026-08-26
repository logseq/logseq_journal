module Ui = Bonsai_flutter_ui

type destructive_swipe_action =
  { background : Ui.Style.Color.t
  ; foreground : Ui.Style.Color.t
  }

module Color_exceptions = struct
  type presentation =
    | Normal
    | High_contrast

  type status_rails =
    { todo : Ui.Style.Color.t
    ; doing : Ui.Style.Color.t
    ; done_ : Ui.Style.Color.t
    ; later : Ui.Style.Color.t
    }

  let rgb red green blue = Ui.Style.Color.rgb ~red ~green ~blue

  let status_rails =
    { todo = rgb 100 116 139
    ; doing = rgb 37 99 235
    ; done_ = rgb 5 142 70
    ; later = rgb 124 58 237
    }
  ;;

  let destructive_swipe = { background = rgb 186 26 26; foreground = rgb 255 255 255 }

  let status_rail_color ~presentation:_ = function
    | Journal_model.No_status -> None
    | status ->
      (match Journal_model.status_category status with
       | None -> None
       | Some Todo_category -> Some status_rails.todo
       | Some Doing_category -> Some status_rails.doing
       | Some Done_category -> Some status_rails.done_
       | Some Later_category -> Some status_rails.later)
  ;;

  let destructive_swipe_action ~presentation:_ = destructive_swipe
end

type text_token =
  { font_size : float
  ; line_height : float
  ; weight : Ui.Style.Font_weight.t
  }

type typography =
  { header_title : text_token
  ; header_subtitle : text_token
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
  }

type fixed_extent_role =
  | Children_loading
  | Children_more
  | Day_heading
  | Day_continuation
  | Feed_continuation

type t = Color_exceptions.presentation

let resolve ~high_contrast =
  if high_contrast then Color_exceptions.High_contrast else Color_exceptions.Normal
;;

let text_token font_size line_height weight = { font_size; line_height; weight }

let typography = function
  | Dense ->
    { header_title = text_token 22. 28. Ui.Style.Font_weight.Semi_bold
    ; header_subtitle = text_token 15. 20. Ui.Style.Font_weight.Medium
    ; entry = text_token 15. 20. Ui.Style.Font_weight.Normal
    ; supporting = text_token 14. 20. Ui.Style.Font_weight.Normal
    ; timestamp = text_token 13. 18. Ui.Style.Font_weight.Normal
    ; input = text_token 16. 24. Ui.Style.Font_weight.Normal
    ; button_label = text_token 14. 20. Ui.Style.Font_weight.Medium
    ; dialog_title = text_token 20. 26. Ui.Style.Font_weight.Semi_bold
    ; manager_title = text_token 24. 32. Ui.Style.Font_weight.Semi_bold
    }
  | Balanced ->
    { header_title = text_token 22. 28. Ui.Style.Font_weight.Semi_bold
    ; header_subtitle = text_token 15. 20. Ui.Style.Font_weight.Medium
    ; entry = text_token 16. 22. Ui.Style.Font_weight.Normal
    ; supporting = text_token 14. 20. Ui.Style.Font_weight.Normal
    ; timestamp = text_token 13. 18. Ui.Style.Font_weight.Normal
    ; input = text_token 16. 24. Ui.Style.Font_weight.Normal
    ; button_label = text_token 14. 20. Ui.Style.Font_weight.Medium
    ; dialog_title = text_token 20. 26. Ui.Style.Font_weight.Semi_bold
    ; manager_title = text_token 24. 32. Ui.Style.Font_weight.Semi_bold
    }
  | Comfortable ->
    { header_title = text_token 24. 32. Ui.Style.Font_weight.Semi_bold
    ; header_subtitle = text_token 16. 22. Ui.Style.Font_weight.Medium
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
  ; disclosure_visual = 14.
  ; status_rail_width = 4.
  ; status_rail_radius = 2.
  }
;;

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

let select_row_profile ~preset ~viewport_width ~text_scale =
  let typography = typography preset in
  let narrow = Float.compare viewport_width 360. < 0 in
  let content_leading = if narrow then 24. else 32. in
  let scale = Float.max 1. text_scale in
  let block_line_height = typography.entry.line_height *. scale in
  let supporting_line_height = typography.supporting.line_height *. scale in
  if (not narrow) && Float.compare scale 1.3 <= 0
  then
    { kind = Compact
    ; block_line_height
    ; continuation_extent = Float.ceil (28. +. supporting_line_height)
    ; day_header_extent = 36.
    ; content_leading
    ; time_slot_width = row_geometry.time_slot_base
    }
  else
    { kind = Adaptive
    ; block_line_height
    ; continuation_extent = Float.ceil (28. +. supporting_line_height)
    ; day_header_extent = Float.ceil (24. +. supporting_line_height)
    ; content_leading
    ; time_slot_width = Float.ceil (row_geometry.time_slot_base *. scale)
    }
;;

let block_extent ~profile ~visible_lines =
  let visible_lines = Int.max 1 (Int.min 4 visible_lines) in
  Float.ceil
    (Float.max
       hit_regions.minimum_target
       (spacing.x4 +. (float_of_int visible_lines *. profile.block_line_height)))
;;

let fixed_extent ~profile = function
  | Children_loading | Children_more -> block_extent ~profile ~visible_lines:1
  | Day_heading -> profile.day_header_extent
  | Day_continuation | Feed_continuation -> profile.continuation_extent
;;

let status_rail_color t status = Color_exceptions.status_rail_color ~presentation:t status
let destructive_swipe_action t = Color_exceptions.destructive_swipe_action ~presentation:t
