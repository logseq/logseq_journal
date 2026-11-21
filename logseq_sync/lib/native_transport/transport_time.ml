type t =
  { now : unit -> float
  ; sleep : float -> unit
  ; timeout : 'a. float -> (unit -> 'a) -> 'a
  }

let monotonic clock =
  { now = (fun () -> Int64.to_float (Mtime.to_uint64_ns (Eio.Time.Mono.now clock)) /. 1e9)
  ; sleep = Eio.Time.Mono.sleep clock
  ; timeout =
      (fun seconds callback ->
        Eio.Time.Timeout.run_exn (Eio.Time.Timeout.seconds clock seconds) callback)
  }
;;

let realtime clock =
  { now = (fun () -> Eio.Time.now clock)
  ; sleep = Eio.Time.sleep clock
  ; timeout = (fun seconds callback -> Eio.Time.with_timeout_exn clock seconds callback)
  }
;;

let now clock = clock.now ()
let sleep clock seconds = clock.sleep seconds
let with_timeout clock seconds callback = clock.timeout seconds callback
