module Ui = Bonsai_flutter_ui

val loading_view : unit -> Ui.Widget.t

val view
  :  tokens:Journal_visual_tokens.t
  -> profile:Journal_visual_tokens.row_profile
  -> device_pixel_ratio:float
  -> end_padding:float
  -> rtl:bool
  -> state:Journal_timeline_state.t
  -> day_label:(int -> string)
  -> reduced_motion:bool
  -> on_visible_range:Ui.Event.Handler.t
  -> on_toggle_children:Ui.Event.Handler.t
  -> delete_enabled:bool
  -> on_delete:Ui.Event.Handler.t
  -> Ui.Widget.Sliver.t
