(** Shared, allocation-bounded validation primitives for stable IDs, UTF-8,
    and locale-neutral civil days. *)

val is_uuid : string -> bool
val is_valid_utf_8 : string -> bool
val is_journal_day : int -> bool
val contains_nul : string -> bool
val validate_block_source : string -> (unit, string) result
