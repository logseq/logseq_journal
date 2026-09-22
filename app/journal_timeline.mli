module Ui = Bonsai_swiftui_ui

val loading_view : unit -> Ui.View.t

val view
  :  render_media:(root:string -> Ui.View.t -> Ui.View.t)
  -> state:Journal_timeline_state.t
  -> day_presentation:(int -> Journal_calendar.date_presentation option)
  -> on_visible_range:Ui.Event.Handler.t
  -> on_scroll_completed:Ui.Event.Handler.t
  -> on_retry_day:Ui.Event.Handler.t
  -> on_open_block:Ui.Event.Handler.t
  -> delete_enabled:bool
  -> actions_enabled:bool
  -> on_status:Ui.Event.Handler.t
  -> on_delete:Ui.Event.Handler.t
  -> Ui.View.Body.t
