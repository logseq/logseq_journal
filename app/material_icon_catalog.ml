module Ui = Bonsai_flutter_ui

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

let code_point = function
  | Account_circle -> 0xe043
  | Add -> 0xe047
  | Arrow_upward -> 0xe0a0
  | Chevron_left -> 0xe15e
  | Chevron_right -> 0xe15f
  | Circle -> 0xe163
  | Delete -> 0xe1b9
  | Expand_more -> 0xe246
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
