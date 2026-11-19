type t

val monotonic : _ Eio.Time.Mono.t -> t
val realtime : _ Eio.Time.clock -> t
val now : t -> float
val sleep : t -> float -> unit
val with_timeout : t -> float -> (unit -> 'a) -> 'a
