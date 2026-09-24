module Ui = Journal_view

type t =
  | Journals
  | Favorites
  | Account
  | Add
  | Save
  | Back
  | Open
  | Done
  | Dot
  | Delete
  | Error
  | Expand
  | Todo
  | Refresh
  | No_status
  | Doing

let for_task_state = function
  | Journal_model.No_status | Canceled -> No_status
  | Todo | Backlog | Later -> Todo
  | Doing | In_review | Now | Waiting -> Doing
  | Done -> Done
;;

let name = function
  | Journals -> "calendar"
  | Favorites -> "star"
  | Account -> "person.crop.circle"
  | Add -> "plus"
  | Save -> "arrow.up"
  | Back -> "chevron.left"
  | Open -> "chevron.right"
  | Done -> "checkmark.circle"
  | Dot -> "circle.fill"
  | Delete -> "trash"
  | Error -> "exclamationmark.circle"
  | Expand -> "chevron.down"
  | Todo -> "circle"
  | Refresh -> "arrow.clockwise"
  | No_status -> "minus.circle"
  | Doing -> "clock"
;;

let create ?key ?size ?color role = Ui.View.symbol ?key ?size ?color ~name:(name role) ()
