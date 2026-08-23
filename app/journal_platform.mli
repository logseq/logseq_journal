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

type network_lifecycle =
  | Backgrounded of { generation : int64 }
  | Foreground_resumed of { generation : int64 }

(** Byte-exact LJP2 request for a fresh host calendar snapshot. *)
val get_calendar_request : bytes

(** Decode one bounded LJP2 calendar response or event containing an exact
    instant, local day and minute, zone snapshot, calendar generation, and
    lifecycle generation. *)
val decode_calendar : bytes -> (calendar, string) result

(** Decode one coalesced Apple-platform background epoch transition. *)
val decode_network_lifecycle : bytes -> (network_lifecycle, string) result

(** Encode one generation-fenced request for 1 to 64 distinct journal days. *)
val format_journal_days_request : generation:int64 -> int list -> (bytes, string) result

(** Decode a bounded host-formatted heading batch. *)
val decode_formatted_journal_days : bytes -> (formatted_journal_days, string) result

val authenticated_user_request : bytes
val decode_authenticated_user : bytes -> (string option, string) result
val id_token_request : Logseq_db_worker.Sync_auth.challenge -> bytes
val decode_id_token_response : challenge_id:string -> bytes -> (string, string) result
val sign_out_request : bytes
val decode_sign_out_response : bytes -> (unit, string) result

(** Recognize the bounded host event requesting cooperative graph cleanup. *)
val is_prepare_to_terminate_event : bytes -> bool

(** Notify the host that graph ownership and network activity are closed. *)
val termination_ready_request : bytes

val decode_termination_ready_response : bytes -> (unit, string) result
