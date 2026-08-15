type t

val create
  :  instant_unix_ms:int64
  -> local_day:int
  -> local_minute_of_day:int
  -> time_zone_id:string
  -> utc_offset_seconds:int
  -> (t, string) result

val of_instant_unix_ms
  :  instant_unix_ms:int64
  -> time_zone_id:string
  -> utc_offset_seconds:int
  -> (t, string) result

val equal : t -> t -> bool
val instant_unix_ms : t -> int64
val local_day : t -> int
val local_minute_of_day : t -> int
val time_zone_id : t -> string
val utc_offset_seconds : t -> int
val format_hh_mm : t -> string
