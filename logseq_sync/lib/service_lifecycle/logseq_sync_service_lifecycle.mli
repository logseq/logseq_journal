type lifecycle =
  | Running
  | Closing
  | Closed

type t

type close_error =
  | Reentrant
  | Already_called

val initial : t
val lifecycle : t -> lifecycle
val request_close : inside_callback:bool -> t -> (t, close_error) result
val begin_cleanup : t -> t
val complete : t -> t
