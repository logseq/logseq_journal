type reason =
  | Requested
  | Resumed
  | Significant_time_changed
  | Time_zone_changed
  | Locale_changed

type calendar =
  { snapshot : Journal_calendar.t
  ; reason : reason
  }

type formatted_journal_days =
  { generation : int64
  ; headings : (int * string) list
  }

(** Byte-exact LJP1 request for a fresh host calendar snapshot. *)
val get_calendar_request : bytes

(** Decode one bounded LJP1 calendar response or event containing an exact
    instant, local day and minute, zone snapshot, calendar generation, and
    lifecycle generation. *)
val decode_calendar : bytes -> (calendar, string) result

(** Encode one generation-fenced request for 1 to 64 distinct journal days. *)
val format_journal_days_request : generation:int64 -> int list -> (bytes, string) result

(** Decode a bounded host-formatted heading batch. *)
val decode_formatted_journal_days : bytes -> (formatted_journal_days, string) result
