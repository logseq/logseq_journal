type state =
  | Queued
  | Submitted
  | Accepted of int
  | Blocked of string

type entry =
  { mutation_id : Graph_types.Uuid.t
  ; mutation_payload : string
  ; mutation_fingerprint : string
  ; encoded_tx : string
  ; outliner_op : string
  ; state : state
  }

val encode : entry list -> (string list, string) result
val decode : string list -> (entry list, string) result
val append_entry : entry list -> entry -> (entry list, string) result
