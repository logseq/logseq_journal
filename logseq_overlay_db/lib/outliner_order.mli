module Graph = Logseq_db_types.Graph_types

(** Validate a base-62 key. Invalid keys raise [Invalid_argument]. *)
val validate : string -> unit

(** Generate strictly inside the bounds; [None] leaves that side open.
    Malformed or non-increasing bounds raise [Invalid_argument]. *)
val generate : lower:string option -> upper:string option -> string

(** Generate an increasing batch. Zero is empty; negative counts are invalid.
    Bounds are validated even for an empty batch. *)
val generate_n : lower:string option -> upper:string option -> int -> string list

val compare_member : string * Graph.Uuid.t -> string * Graph.Uuid.t -> int
