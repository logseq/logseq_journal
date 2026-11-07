(** {1 TLDR}

    Represent a non-negative authoritative server transaction cursor without I/O.
    Validate incoming integers with [of_int64]; [zero] is the initial baseline. *)
type t = Logseq_db_types.Server_cursor.t

val zero : t
val of_int64 : int64 -> (t, [ `Negative_cursor ]) result
val to_int64 : t -> int64

(** {1 Minimal usage example}

    The caller supplies the integer [wire_cursor]:
    {[
      match of_int64 wire_cursor with
      | Ok cursor -> Ok (to_int64 cursor)
      | Error `Negative_cursor -> Error `Negative_cursor
    ]} *)

(** {1 Observation and helpers}

    Compare validated cursors without converting them back to integers. *)
val equal : t -> t -> bool
val compare : t -> t -> int
