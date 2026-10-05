module Ui = Journal_view

type status_colors =
  { background : Ui.Style.Color.t
  ; foreground : Ui.Style.Color.t
  }

type t

val resolve : brightness:Journal_environment.brightness -> high_contrast:bool -> t
val status_colors : t -> Journal_model.task_state -> status_colors
