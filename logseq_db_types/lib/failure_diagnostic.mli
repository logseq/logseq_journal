(** Bounded diagnostic context with finite operation, reason and source classes.
    Arbitrary source text, exception arguments and paths are never retained.
    Unknown constructor descriptors normalize to fixed safe fallbacks. Messages
    use at most 512 bytes; source classification examines at most 4096 bytes. *)
type t

val create
  :  operation:string
  -> reason:string
  -> ?source:string
  -> ?cursor:int64
  -> ?http_status:int
  -> unit
  -> t

(** A valid carrier retains its safe lower reason, source class, cursor and
    bounded HTTP status; only the operation is replaced with the caller's
    normalized operation.
    Other input is classified without retaining arbitrary text. Only canonical
    producer-owned HTTP status messages retain their numeric status (100–599). *)
val of_source : operation:string -> reason:string -> string -> t

val operation : t -> string
val phase : t -> string
val code : t -> string
val reason : t -> string
val source_class : t -> string
val message : t -> string

(** Versioned carriers use at most 1024 bytes and reject unknown/duplicate fields
    and non-allowlisted values.
    A non-negative cursor is encoded as a canonical decimal string, never a JSON
    number. HTTP status is an optional integer in the range 100–599.
    Oversized or malformed carriers fail closed. *)
val encode : t -> string

val decode : string -> t option
val detail_name : string
val signal_prefix : string
