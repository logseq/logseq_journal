type cursor_payload =
  { api_version : int
  ; fingerprint : string
  ; basis : int64
  ; last_sort_key : string
  ; expires_at_ms : int64
  }

type error =
  | Invalid_limit
  | Invalid_cursor
  | Cursor_tampered
  | Cursor_expired
  | Cursor_conflict

val validate_limit : int -> (unit, error) result
val fingerprint : Yojson.Safe.t -> string

val encode_cursor
  :  key:bytes
  -> cursor_payload
  -> (Graph_types.Cursor.t, error) result

val decode_cursor
  :  key:bytes
  -> now_ms:int64
  -> Graph_types.Cursor.t
  -> (cursor_payload, error) result
