module Error : sig
  type t

  val to_string : t -> string
end

(** Access policy for the app-private SQLite store. Recovery-only is an
    application mutation gate; it does not claim a read-only SQLite handle. *)
type access_mode =
  | Read_write
  | Recovery_only

type diagnostic_mode = Operational_only

(** One immutable bootstrap snapshot. Live calendar data is supplied through
    the host request/event bridge after startup. *)
type calendar_snapshot =
  { instant_unix_ms : int64
  ; local_day : int
  ; local_minute_of_day : int
  ; locale : string
  ; time_zone_id : string
  ; utc_offset_seconds : int
  ; generation : int64
  ; lifecycle_generation : int64
  }

type t =
  { application_support_root : string
  ; expected_schema_version : int
  ; initial_calendar : calendar_snapshot
  ; access_mode : access_mode
  ; diagnostic_mode : diagnostic_mode
  }

val database_relative_path : string

(** Encode and decode the byte-exact LJR1 mechanical host payload nested
    inside the framework-owned BFR1 runtime envelope. Database, schema, and
    access policy are not transported by this codec. *)
val encode : t -> (bytes, Error.t) result

val decode : bytes -> (t, Error.t) result
