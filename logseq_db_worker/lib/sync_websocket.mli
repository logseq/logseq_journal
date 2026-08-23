type t

type incoming =
  | Ignore_late
  | Deliver of string
  | Pull_hint of int

val create
  :  account_generation:int
  -> graph_generation:int
  -> connection_generation:int
  -> applied_server_t:int
  -> t

val opened
  :  t
  -> account_generation:int
  -> graph_generation:int
  -> connection_generation:int
  -> string list

val receive
  :  t
  -> account_generation:int
  -> graph_generation:int
  -> connection_generation:int
  -> string
  -> (incoming, string) result

val reconnect : t -> t
val connection_generation : t -> int
val applied_server_t : t -> int
val set_applied_server_t : t -> int -> t
