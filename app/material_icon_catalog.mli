type t =
  | View_day
  | Star
  | Account_circle
  | Add
  | Arrow_upward
  | Chevron_left
  | Chevron_right
  | Check_circle_outline
  | Circle
  | Delete
  | Error_outline
  | Expand_more
  | Radio_button_unchecked
  | Refresh
  | Remove_circle_outline
  | Timelapse

val for_task_state : Journal_model.task_state -> t

val create
  :  ?key:Bonsai_flutter_ui.Key.t
  -> ?size:float
  -> ?color:Bonsai_flutter_ui.Style.Color.t
  -> t
  -> Bonsai_flutter_ui.Widget.t
