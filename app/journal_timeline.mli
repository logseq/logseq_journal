module Ui = Bonsai_flutter_ui

val loading_view : typography:Journal_visual_tokens.typography -> unit -> Ui.Widget.t

val view
  :  tokens:Journal_visual_tokens.t
  -> typography:Journal_visual_tokens.typography
  -> profile:Journal_visual_tokens.row_profile
  -> device_pixel_ratio:float
  -> end_padding:float
  -> rtl:bool
  -> state:Journal_timeline_state.t
  -> day_presentation:(int -> Journal_calendar.date_presentation option)
  -> reduced_motion:bool
  -> on_visible_range:Ui.Event.Handler.t
  -> on_retry_day:Ui.Event.Handler.t
  -> on_toggle_children:Ui.Event.Handler.t
  -> delete_enabled:bool
  -> actions_enabled:bool
  -> on_status:Ui.Event.Handler.t
  -> on_delete:Ui.Event.Handler.t
  -> Ui.Widget.Sliver.t
