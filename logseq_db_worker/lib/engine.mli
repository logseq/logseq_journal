type t

type clocks =
  { epoch_ms : unit -> int64
  ; monotonic_ns : unit -> int64
  }

type dependencies =
  { clocks : clocks
  ; cursor_authentication_key : bytes
  }

exception Fatal_storage_error of string

val open_ : dependencies:dependencies -> Config.t -> (t, Error.t) result
val execute : t -> Protocol.request -> Protocol.response
val close : t -> (unit, string) result
val basis : t -> int64 option
