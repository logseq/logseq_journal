module Ui = Bonsai_flutter_ui

type swipe_action_colors =
  { background : Ui.Style.Color.t
  ; foreground : Ui.Style.Color.t
  }

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

type t

val resolve : brightness:Bonsai_flutter.Environment.brightness -> high_contrast:bool -> t
val typography : typography_preset -> typography
val typography_preset_of_stored_value : string option -> typography_preset
val stored_value_of_typography_preset : typography_preset -> string
val spacing : spacing
val hit_regions : hit_regions
val header_geometry : header_geometry
val composer_geometry : composer_geometry
val row_geometry : row_geometry
val supporting_preview_gap : float
val preview_geometry : preview_geometry
val motion : reduced_motion:bool -> motion
val physical_divider_thickness : device_pixel_ratio:float -> float
val timeline_max_width : float

val select_row_profile
  :  preset:typography_preset
  -> viewport_width:float
  -> text_scale:float
  -> row_profile

val block_extent : profile:row_profile -> visible_lines:int -> float

val measure_text
  :  profile:row_profile
  -> font_size:float
  -> max_lines:int
  -> string
  -> text_measurement

val fixed_extent : profile:row_profile -> fixed_extent_role -> float
val status_rail_color : t -> Journal_model.task_state -> Ui.Style.Color.t option
val destructive_swipe_action : t -> swipe_action_colors
val status_swipe_action : t -> Journal_model.task_state -> swipe_action_colors
val weekday_opacity : t -> float
val date_gap : float
val date_scale : viewport_width:float -> text_scale:float -> float
