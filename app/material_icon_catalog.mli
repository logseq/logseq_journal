type t =
  | Account_circle
  | Add
  | Arrow_upward
  | Chevron_left
  | Chevron_right
  | Check_box_outline_blank
  | Check_circle
  | Circle
  | Circle_outlined
  | Delete
  | Error_outline
  | Expand_more
  | Pending
  | Task_alt
  | Refresh

val create
  :  ?key:Bonsai_flutter_ui.Key.t
  -> ?size:float
  -> ?color:Bonsai_flutter_ui.Style.Color.t
  -> t
  -> Bonsai_flutter_ui.Widget.t
