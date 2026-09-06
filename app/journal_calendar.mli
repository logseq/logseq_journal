type t
type projection_fingerprint

type error =
  | Clock_failed of string
  | Invalid_instant of string
  | Local_time_failed of string

type change =
  | Current_time_changed
  | Local_day_changed
  | Local_projection_changed

module Sampler : sig
  type calendar = t
  type t

  val create : ?clock:(unit -> float) -> ?localtime:(float -> Unix.tm) -> unit -> t
  val localtime : t -> float -> Unix.tm
  val sample : t -> (calendar, error) result
end

val error_message : error -> string
val instant_unix_ms : t -> int64
val local_day : t -> int
val local_minute_of_day : t -> int
val generation : t -> int64
val projection_fingerprint : t -> projection_fingerprint

val equal_projection_fingerprint
  :  projection_fingerprint
  -> projection_fingerprint
  -> bool

val classify_change : previous:t -> t -> change
val is_newer : than:t -> t -> bool

type date_presentation =
  { date_text : string
  ; weekday_text : string
  ; accessibility_label : string
  }

val present_journal_day : int -> (date_presentation, string) result
