module Ui = Bonsai_swiftui_ui

type swipe_action_colors =
  { background : Ui.Style.Color.t
  ; foreground : Ui.Style.Color.t
  }

type t

val resolve : brightness:Bonsai_swiftui.Environment.brightness -> high_contrast:bool -> t
val status_swipe_action : t -> Journal_model.task_state -> swipe_action_colors
val status_action_background : Ui.Style.Color.t
val delete_action_background : Ui.Style.Color.t
