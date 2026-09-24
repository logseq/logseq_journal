module Ui = Journal_view

type row =
  { id : string
  ; section : string
  ; header : bool
  ; slot_index : int option
  ; block_id : string option
  }

val view
  :  key:Ui.Key.t
  -> test_id:Ui.Test_id.t
  -> rows:row list
  -> scroll_target:(int64 * string * string) option
  -> on_scroll_completed:Ui.Event.Handler.t
  -> actions_enabled:bool
  -> on_visible_range:Ui.Event.Handler.t
  -> on_open:Ui.Event.Handler.t
  -> on_status:Ui.Event.Handler.t
  -> on_delete:Ui.Event.Handler.t
  -> children:Ui.View.t list
  -> Ui.View.Viewport.Vertical.t
