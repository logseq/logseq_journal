(** The validated calendar day shared by original spec queries and mutations. *)
type t
val create : int -> (t,string)result
val value : t -> int
