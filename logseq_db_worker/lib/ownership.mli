type t

type error =
  | Already_owned
  | Ambiguous_stale_lock
  | Identity_changed
  | Not_owner
  | Invalid_sentinel

val acquire : graph_dir:string -> (t, error) result
val revalidate : t -> (unit, error) result
val release : t -> (unit, error) result
val generation : t -> string
val graph_dir : t -> string
