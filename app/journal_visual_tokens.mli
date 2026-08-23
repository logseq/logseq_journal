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
  ; status_todo : Ui.Style.Color.t
  ; status_doing : Ui.Style.Color.t
  ; status_done : Ui.Style.Color.t
  ; status_later : Ui.Style.Color.t
  ; sheet_surface : Ui.Style.Color.t
  ; sheet_outline : Ui.Style.Color.t
  ; modal_scrim : Ui.Style.Color.t
  ; sheet_primary_action : Ui.Style.Color.t
  ; sheet_secondary_action : Ui.Style.Color.t
  ; sheet_error : Ui.Style.Color.t
  ; destructive : Ui.Style.Color.t
  ; on_destructive : Ui.Style.Color.t
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
  ; maximum_lines : int
  ; expanded_vertical_overhead : float
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
  ; capture_sheet_enter_ms : int
  ; capture_sheet_exit_ms : int
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
  | Bottom_clearance

type t

val resolve : high_contrast:bool -> t
val palette : t -> palette
val interaction : t -> interaction
val typography : typography
val spacing : spacing
val hit_regions : hit_regions
val header_geometry : header_geometry
val composer_geometry : composer_geometry
val row_geometry : row_geometry
val preview_geometry : preview_geometry
val motion : reduced_motion:bool -> motion
val physical_divider_thickness : device_pixel_ratio:float -> float
val timeline_max_width : float
val select_row_profile : viewport_width:float -> text_scale:float -> row_profile
val block_extent : profile:row_profile -> visible_lines:int -> float
val fixed_extent : profile:row_profile -> safe_bottom:float -> fixed_extent_role -> float
val status_rail_color : t -> Journal_model.task_state -> Ui.Style.Color.t option
