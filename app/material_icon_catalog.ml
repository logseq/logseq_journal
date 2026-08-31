module Ui = Bonsai_flutter_ui

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

let code_point = function
  | Account_circle -> 0xe043
  | Add -> 0xe047
  | Arrow_upward -> 0xe0a0
  | Chevron_left -> 0xe15e
  | Chevron_right -> 0xe15f
  | Check_box_outline_blank -> 0xe158
  | Check_circle -> 0xe159
  | Circle -> 0xe163
  | Circle_outlined -> 0xef53
  | Delete -> 0xe1b9
  | Error_outline -> 0xe237
  | Expand_more -> 0xe246
  | Pending -> 0xe484
  | Task_alt -> 0xe646
  | Refresh -> 0xe514
;;

let create ?key ?size ?color role =
  Ui.Widget.icon
    ?key
    ?size
    ?color
    ~font_family:"MaterialIcons"
    ~code_point:(code_point role)
    ()
;;
