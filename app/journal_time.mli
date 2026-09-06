type t

val create
  :  instant_unix_ms:int64
  -> local_day:int
  -> local_minute_of_day:int
  -> (t, string) result

val of_instant_unix_ms : instant_unix_ms:int64 -> (t, string) result

val of_instant_unix_ms_with
  :  localtime:(float -> Unix.tm)
  -> instant_unix_ms:int64
  -> (t, string) result

val of_calendar : Journal_calendar.t -> (t, string) result
val equal : t -> t -> bool
val instant_unix_ms : t -> int64
val local_day : t -> int
val local_minute_of_day : t -> int
val format_hh_mm : t -> string
