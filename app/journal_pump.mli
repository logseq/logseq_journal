(** Cross-thread work queue between worker fibers and the lui app thread.

    ocaml-signal is single-threaded: [Lui_app.send]/[dispatch_event]/[flush]
    must only run on the thread that owns the application. Worker fibers
    (Eio, running on the worker domain) enqueue thunks here; the native
    bridge invokes [drain] on the app thread via the C entry
    [journal_ocaml_pump]. *)

type t

val create : unit -> t

(** Enqueue a thunk from any thread. Signals the registered wakeup callback
    (if any) so the host can schedule a pump on the app thread. *)
val enqueue : t -> (unit -> unit) -> unit

(** Register the callback invoked (on the producing thread) whenever the
    queue transitions to non-empty. The native bridge sets this to the C
    wakeup trampoline that schedules [journal_ocaml_pump] on the UI thread. *)
val set_wakeup : t -> (unit -> unit) -> unit

(** Runs all queued thunks in FIFO order. App thread only. *)
val drain : t -> unit
