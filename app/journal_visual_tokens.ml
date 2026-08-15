module Ui = Bonsai_flutter_ui

type palette =
  { background : Ui.Style.Color.t
  ; header : Ui.Style.Color.t
  ; text_primary : Ui.Style.Color.t
  ; text_secondary : Ui.Style.Color.t
  ; text_timestamp : Ui.Style.Color.t
  ; divider : Ui.Style.Color.t
  ; neutral_badge : Ui.Style.Color.t
  ; fab : Ui.Style.Color.t
  ; on_fab : Ui.Style.Color.t
  ; success : Ui.Style.Color.t
  ; on_success : Ui.Style.Color.t
  ; sheet_surface : Ui.Style.Color.t
  ; sheet_outline : Ui.Style.Color.t
  ; modal_scrim : Ui.Style.Color.t
  ; sheet_primary_action : Ui.Style.Color.t
  ; sheet_secondary_action : Ui.Style.Color.t
  ; sheet_error : Ui.Style.Color.t
  ; destructive : Ui.Style.Color.t
  ; on_destructive : Ui.Style.Color.t
  ; snackbar_surface : Ui.Style.Color.t
  ; snackbar_primary_text : Ui.Style.Color.t
  ; snackbar_action_text : Ui.Style.Color.t
  }

type interaction =
  { pressed : Ui.Style.Color.t
  ; focused : Ui.Style.Color.t
  ; disabled : Ui.Style.Color.t
  ; error : Ui.Style.Color.t
  }

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
  ; disclosure : text_token
  ; timestamp : text_token
  }

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
  ; bottom_inset : float
  ; minimum_height : float
  ; reserved_extent : float
  }

type row_geometry =
  { time_slot_base : float
  ; trailing_inset : float
  ; task_visual : float
  ; disclosure_visual : float
  }

type preview_geometry =
  { connector_leading : float
  ; bullet_center_leading : float
  ; bullet_diameter : float
  ; text_leading : float
  ; narrow_leading_delta : float
  }

type snackbar_geometry =
  { margin : float
  ; maximum_width : float
  ; minimum_height : float
  ; corner_radius : float
  ; vertical_gap : float
  }

type motion =
  { press_release_ms : int
  ; route_transition_ms : int
  ; capture_sheet_enter_ms : int
  ; capture_sheet_exit_ms : int
  }

type profile_kind =
  | Compact
  | Adaptive

type row_profile =
  { kind : profile_kind
  ; top_level_extent : float
  ; child_extent : float
  ; continuation_extent : float
  ; day_header_extent : float
  ; content_leading : float
  ; time_slot_width : float
  }


type extent_role =
  | Top_level
  | Child_preview
  | Children_loading
  | Children_more
  | Day_heading
  | Day_continuation
  | Feed_continuation
  | Bottom_clearance

type t =
  { palette : palette
  ; interaction : interaction
  }

let rgb red green blue = Ui.Style.Color.rgb ~red ~green ~blue
let argb alpha red green blue = Ui.Style.Color.argb ~alpha ~red ~green ~blue

let light_palette =
  { background = rgb 253 253 253
  ; header = rgb 253 253 253
  ; text_primary = rgb 13 20 47
  ; text_secondary = rgb 101 107 143
  ; text_timestamp = rgb 110 115 136
  ; divider = rgb 232 233 237
  ; neutral_badge = rgb 241 242 245
  ; fab = rgb 24 30 52
  ; on_fab = rgb 252 252 253
  ; success = rgb 5 142 70
  ; on_success = rgb 255 255 255
  ; sheet_surface = rgb 255 255 255
  ; sheet_outline = rgb 232 233 237
  ; modal_scrim = argb 71 13 20 47
  ; sheet_primary_action = rgb 24 30 52
  ; sheet_secondary_action = rgb 245 245 246
  ; sheet_error = rgb 179 38 30
  ; destructive = rgb 220 77 86
  ; on_destructive = rgb 255 255 255
  ; snackbar_surface = rgb 24 30 52
  ; snackbar_primary_text = rgb 252 252 253
  ; snackbar_action_text = rgb 110 153 255
  }
;;

let light_high_contrast_palette =
  { background = rgb 255 255 255
  ; header = rgb 255 255 255
  ; text_primary = rgb 0 0 0
  ; text_secondary = rgb 49 49 49
  ; text_timestamp = rgb 49 49 49
  ; divider = rgb 102 102 102
  ; neutral_badge = rgb 238 238 238
  ; fab = rgb 0 0 0
  ; on_fab = rgb 255 255 255
  ; success = rgb 0 107 51
  ; on_success = rgb 255 255 255
  ; sheet_surface = rgb 255 255 255
  ; sheet_outline = rgb 102 102 102
  ; modal_scrim = argb 140 0 0 0
  ; sheet_primary_action = rgb 0 0 0
  ; sheet_secondary_action = rgb 238 238 238
  ; sheet_error = rgb 128 0 0
  ; destructive = rgb 153 0 0
  ; on_destructive = rgb 255 255 255
  ; snackbar_surface = rgb 0 0 0
  ; snackbar_primary_text = rgb 255 255 255
  ; snackbar_action_text = rgb 153 204 255
  }
;;

let light_interaction =
  { pressed = argb 31 13 20 47
  ; focused = rgb 49 94 245
  ; disabled = rgb 165 168 182
  ; error = rgb 179 38 30
  }
;;

let light_high_contrast_interaction =
  { pressed = argb 51 0 0 0
  ; focused = rgb 0 56 168
  ; disabled = rgb 89 89 89
  ; error = rgb 128 0 0
  }
;;

let resolve ~high_contrast =
  match high_contrast with
  | false -> { palette = light_palette; interaction = light_interaction }
  | true ->
    { palette = light_high_contrast_palette
    ; interaction = light_high_contrast_interaction
    }
;;

let palette t = t.palette
let interaction t = t.interaction

let typography =
  { header_title =
      { font_size = 22.; line_height = 28.; weight = Ui.Style.Font_weight.Bold }
  ; header_subtitle =
      { font_size = 15.; line_height = 20.; weight = Ui.Style.Font_weight.Medium }
  ; entry = { font_size = 15.; line_height = 20.; weight = Ui.Style.Font_weight.Normal }
  ; supporting =
      { font_size = 14.; line_height = 20.; weight = Ui.Style.Font_weight.Normal }
  ; disclosure =
      { font_size = 11.; line_height = 16.; weight = Ui.Style.Font_weight.Medium }
  ; timestamp =
      { font_size = 13.; line_height = 18.; weight = Ui.Style.Font_weight.Normal }
  }
;;

let spacing = { x1 = 4.; x2 = 8.; x3 = 12.; x4 = 16.; x5 = 20.; x6 = 24.; x7 = 28. }

let hit_regions =
  { header_visual = 30.
  ; minimum_target = 44.
  }
;;

let header_geometry =
  { content_height = 48.; horizontal_inset = 12.; vertical_inset = 4. }
;;

let composer_geometry =
  { horizontal_margin = 12.
  ; bottom_inset = 12.
  ; minimum_height = 56.
  ; reserved_extent = 80.
  }
;;

let row_geometry =
  { time_slot_base = 52.
  ; trailing_inset = 24.
  ; task_visual = 14.
  ; disclosure_visual = 14.
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

let snackbar_geometry =
  { margin = 12.
  ; maximum_width = 720.
  ; minimum_height = 52.
  ; corner_radius = 12.
  ; vertical_gap = spacing.x3
  }
;;

let motion ~reduced_motion =
  if reduced_motion
  then
    { press_release_ms = 0
    ; route_transition_ms = 0
    ; capture_sheet_enter_ms = 0
    ; capture_sheet_exit_ms = 0
    }
  else
    { press_release_ms = 80
    ; route_transition_ms = 180
    ; capture_sheet_enter_ms = 220
    ; capture_sheet_exit_ms = 180
    }
;;

let physical_divider_thickness ~device_pixel_ratio = 1. /. Float.max 1. device_pixel_ratio
let timeline_max_width = 720.

let select_row_profile ~viewport_width ~text_scale =
  let narrow = Float.compare viewport_width 360. < 0 in
  let content_leading = if narrow then 24. else 32. in
  let scale = Float.max 1. text_scale in
  if (not narrow) && Float.compare scale 1.3 <= 0
  then
    { kind = Compact
    ; top_level_extent = Float.ceil (36. +. (40. *. scale))
    ; child_extent = Float.ceil (16. +. (20. *. scale))
    ; continuation_extent = Float.ceil (28. +. (20. *. scale))
    ; day_header_extent = 36.
    ; content_leading
    ; time_slot_width = row_geometry.time_slot_base
    }
  else (
    let top_level_extent =
      if Float.compare scale 1.3 <= 0
      then Float.ceil (44. +. (40. *. scale))
      else Float.ceil (24. +. (58. *. scale))
    in
    { kind = Adaptive
    ; top_level_extent
    ; child_extent = Float.ceil (16. +. (20. *. scale))
    ; continuation_extent = Float.ceil (28. +. (20. *. scale))
    ; day_header_extent = Float.ceil (24. +. (24. *. scale))
    ; content_leading
    ; time_slot_width = Float.ceil (row_geometry.time_slot_base *. scale)
    })
;;

let extent_for_role ~profile ~safe_bottom = function
  | Top_level -> profile.top_level_extent
  | Child_preview | Children_loading | Children_more -> profile.child_extent
  | Day_heading -> profile.day_header_extent
  | Day_continuation | Feed_continuation -> profile.continuation_extent
  | Bottom_clearance -> composer_geometry.reserved_extent +. max 0. safe_bottom
;;

let expanded_parent_extent ~profile ~source =
  let source_lines =
    String.fold_left
      (fun lines character ->
         if lines < 3 && Char.equal character '\n' then lines + 1 else lines)
      1
      source
  in
  let additional_line_extent = profile.child_extent -. spacing.x4 in
  profile.child_extent +. (float_of_int (source_lines - 1) *. additional_line_extent)
;;
