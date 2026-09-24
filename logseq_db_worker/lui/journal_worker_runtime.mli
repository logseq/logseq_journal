(** Process-wide singleton OCaml Worker Domain lifecycle. *)

type state =
  | Not_started
  | Idle
  | Attached
  | Stopping
  | Stopped
  | Terminal

type diagnostics =
  { state : state
  ; spawn_count : int
  ; join_count : int
  ; worker_domain_id : Journal_worker_ids.Worker.domain_id option
  ; active_sessions : int
  ; peak_active_sessions : int
  ; idle_wait_count : int
  ; backend_run_count : int
  ; backend_running : bool
  ; coordinator_start_count : int
  ; active_coordinators : int
  ; peak_active_coordinators : int
  ; coordinator_yield_count : int
  ; configured_concurrency_limit : int option
  ; queued_requests : int
  ; active_request_fibers : int
  ; waiting_request_fibers : int
  ; active_handlers : int
  ; peak_active_handlers : int
  ; active_background_fibers : int
  ; peak_active_background_fibers : int
  ; logical_live_fibers : int
  ; request_queue_wait_count : int
  ; max_request_queue_wait_ns : int64
  ; handler_wall_count : int
  ; max_handler_wall_ns : int64
  ; cancellation_unwind_count : int
  ; max_cancellation_unwind_ns : int64
  ; session_cancellation_duration_ns : int64 option
  ; shutdown_duration_ns : int64 option
  ; backend_identity : string
  ; backend_version : string
  }

val start
  :  runtime_epoch:Journal_worker_ids.Runtime.epoch
  -> ('config, 'request, 'response, 'push) Journal_worker.Service.t
  -> 'config
  -> (('request, 'response, 'push) Journal_worker.client, string) result

(** Cooperatively removes one attached session. This never joins the
    process-wide Worker Domain. *)
val stop : ('request, 'response, 'push) Journal_worker.client -> unit

module For_testing : sig
  val diagnostics : unit -> diagnostics
  val await_state : state -> unit
  val await_idle_wait_count : int -> unit

  (** Stops and joins the process-wide Worker Domain exactly once when a
      Domain was successfully spawned. *)
  val final_shutdown : unit -> unit

  val crash_worker_loop : unit -> unit
  val fail_next_spawn : exn -> unit
end
