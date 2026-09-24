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

val for_task_state : Journal_model.task_state -> t
val name : t -> string

val create
  :  ?key:Journal_view.Key.t
  -> ?size:float
  -> ?color:Journal_view.Style.Color.t
  -> t
  -> Journal_view.View.t
