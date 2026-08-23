type operation_id
type t

val create : unit -> t

val register
  :  t
  -> account_generation:int
  -> graph_generation:int option
  -> cancel:(unit -> unit)
  -> operation_id

val complete : t -> operation_id -> unit
val cancel_obsolete : t -> account_generation:int -> graph_generation:int -> unit
val cancel_graph : t -> account_generation:int -> graph_generation:int -> unit
val cancel_all : t -> unit
val active_count : t -> int
