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
  :  ?key:Bonsai_swiftui_ui.Key.t
  -> ?size:float
  -> ?color:Bonsai_swiftui_ui.Style.Color.t
  -> t
  -> Bonsai_swiftui_ui.View.t
