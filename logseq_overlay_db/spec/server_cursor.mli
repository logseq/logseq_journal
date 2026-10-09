(** A non-negative authoritative server transaction cursor. *)
type t = Logseq_db_types.Server_cursor.t

val zero : t
val of_int64 : int64 -> (t, [ `Negative_cursor ]) result
val to_int64 : t -> int64
val equal : t -> t -> bool
val compare : t -> t -> int
