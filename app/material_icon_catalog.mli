type t =
  | Account_circle
  | Add
  | Arrow_upward
  | Chevron_left
  | Chevron_right
  | Circle
  | Delete
  | Expand_more
  | Refresh

val create
  :  ?key:Bonsai_flutter_ui.Key.t
  -> ?size:float
  -> ?color:Bonsai_flutter_ui.Style.Color.t
  -> t
  -> Bonsai_flutter_ui.Widget.t
