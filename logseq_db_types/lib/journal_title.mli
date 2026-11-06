val default_format : string

val format
  :  pattern:string
  -> year:int
  -> month:int
  -> day:int
  -> string option

(** Render a journal date with the configured pattern, falling back to the
    upstream default when absent or unsupported. Invalid dates remain None. *)
val for_journal_day : pattern:string option -> int -> string option
