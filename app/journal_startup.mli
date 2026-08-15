module Error : sig
  type t

  val to_string : t -> string
end

type t = Logseq_db_worker.Config.t

(** Encode and decode the byte-exact LDB1 configuration envelope nested
    inside the framework-owned BFR1 runtime envelope. Decoding is bounded and
    performs no filesystem or database work. *)
val encode : t -> (bytes, Error.t) result
val decode : bytes -> (t, Error.t) result
