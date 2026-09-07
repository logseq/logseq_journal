(** Pure, process-local monotonic UUID v8 allocation. *)
type t

type error =
  | Timestamp_out_of_range
  | Invalid_random_length of int
  | Payload_exhausted

val empty : t

(** [next state ~timestamp_ms ~random_bytes] uses a 48-bit Unix millisecond
    timestamp and exactly 16 supplied random bytes. Later timestamps select a
    fresh 74-bit payload; equal or earlier timestamps increment the previous
    payload, skipping version and variant bits. Errors leave [state] unchanged.
    No clock, entropy source, or mutable state is owned by this module. *)
val next
  :  t
  -> timestamp_ms:int64
  -> random_bytes:bytes
  -> (t * Graph_types.Uuid.t, error) result
