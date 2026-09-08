module Ui = Bonsai_flutter_ui

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

let for_task_state = function
  | Journal_model.No_status -> Remove_circle_outline
  | Todo | Backlog | Later -> Radio_button_unchecked
  | Doing | In_review | Now | Waiting -> Timelapse
  | Done -> Check_circle_outline
  | Canceled -> Remove_circle_outline
;;

let code_point = function
  | View_day -> 0xf495
  | Star -> 0xe5f9
  | Account_circle -> 0xe043
  | Add -> 0xe047
  | Arrow_upward -> 0xe0a0
  | Chevron_left -> 0xe15e
  | Chevron_right -> 0xe15f
  | Check_circle_outline -> 0xe15a
  | Circle -> 0xe163
  | Delete -> 0xe1b9
  | Error_outline -> 0xe237
  | Expand_more -> 0xe246
  | Radio_button_unchecked -> 0xe504
  | Refresh -> 0xe514
  | Remove_circle_outline -> 0xe518
  | Timelapse -> 0xe660
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
