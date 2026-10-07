(** Typed domain-0 client and Worker Domain service contract. *)

type mono_clock = Eio.Time.Mono.ty Eio.Resource.t
type net = [ `Generic ] Eio.Net.ty Eio.Resource.t
type data_dir = Eio.Fs.dir_ty Eio.Path.t
type environment = Journal_worker_eio_backend.environment

(** A client-bound capability for one reply. New tickets retire older replies
    on the same topic. Tickets cannot be forged or transferred to another client. *)
type control_ticket

type control_admission =
  | Reply of control_ticket
  | Latest of
      { topic : int
      ; key : string
      ; invalidates : int option
      }

type control_send_result =
  | Control_accepted
  | Control_duplicate
  | Control_stale
  | Control_not_ready
  | Control_stopping
  | Control_unsupported

module Session_context : sig
  type 'push t

  val switch : 'push t -> Eio.Switch.t
  val environment : 'push t -> environment
  val clock : 'push t -> mono_clock
  val net : 'push t -> net
  val data_dir : 'push t -> data_dir option
  val emit : 'push t -> topic:Journal_worker_ids.Worker.push_topic -> 'push -> unit
  val fork_daemon : 'push t -> name:string -> (unit -> unit) -> unit

  (** Register one current reply capability in a configured fixed topic.
      Supersedes its previous ticket and pending reply: the service must cancel
      the previous obligation before issuing a replacement. Returns [None]
      during stop or while an invalidating latest update is pending. *)
  val issue_control : 'push t -> topic:int -> control_ticket option
end

module Request_context : sig
  type 'push t

  val request_id : 'push t -> Journal_worker_ids.Worker.request_id
  val switch : 'push t -> Eio.Switch.t
  val environment : 'push t -> environment
  val clock : 'push t -> mono_clock
  val net : 'push t -> net
  val data_dir : 'push t -> data_dir option
  val emit : 'push t -> topic:Journal_worker_ids.Worker.push_topic -> 'push -> unit
end

type 'response outcome =
  | Completed of 'response
  | Failed of string
  | Cancelled
  | Shutdown

type ('response, 'push) event =
  | Response of
      { runtime_epoch : Journal_worker_ids.Runtime.epoch
      ; worker_generation : Journal_worker_ids.Worker.generation
      ; request_id : Journal_worker_ids.Worker.request_id
      ; outcome : 'response outcome
      }
  | Push of
      { runtime_epoch : Journal_worker_ids.Runtime.epoch
      ; worker_generation : Journal_worker_ids.Worker.generation
      ; push_sequence : Journal_worker_ids.Worker.push_sequence
      ; topic : Journal_worker_ids.Worker.push_topic
      ; payload : 'push
      }
  | Terminal of
      { runtime_epoch : Journal_worker_ids.Runtime.epoch
      ; worker_generation : Journal_worker_ids.Worker.generation
      ; error : string
      }

type send_result =
  | Accepted of Journal_worker_ids.Worker.request_id
  | Full
  | Not_ready
  | Stopping

type ('request, 'response, 'push) client

module Service : sig
  type concurrency =
    | Serial
    | Concurrent of { max_in_flight : int }

  type ('config, 'request, 'response, 'push) t

  val create
    :  push_topic_count:int
    -> concurrency:concurrency
    -> ?merge_push:(topic:Journal_worker_ids.Worker.push_topic -> 'push -> 'push -> 'push)
    -> ?data_directory:('config -> (string, string) result)
    -> ?control_topic_count:int
    -> ?classify_control:('request -> control_admission option)
    -> ?handle_control:('state -> 'request -> unit)
    -> init:('push Session_context.t -> 'config -> ('state, string) result)
    -> handle:
         ('push Request_context.t -> 'state -> 'request -> ('response, string) result)
    -> shutdown:('state -> unit)
    -> unit
    -> ('config, 'request, 'response, 'push) t
end

(** Non-blocking domain-0 data enqueue. For a classified [Latest] update, its
    short control state is mirrored before data admission, including on [Full].
    Its data handler waits for that control version (or a newer coalesced version)
    after taking its ordinary handler permit and before invoking the data handler.
    Other data work keeps existing
    FIFO/backpressure and response semantics. *)
val send : ('request, 'response, 'push) client -> 'request -> send_result

(** Non-blocking domain-0 control submission. Fixed topics (at most 64) retain
    one pending payload each. A topic has one role; a latest topic keeps a fixed
    invalidation target throughout the session. Replies accept only the current client ticket and
    first answer; latest updates coalesce identical complete state keys and
    revoke unclaimed replies immediately when the key changes. Every invalidating
    topic must finish its current version before a new reply ticket can be issued.
    Execution claims are atomic under the short control lock; already claimed
    callbacks may finish and always run outside that lock.
    Accepted means stored, not executed. No data response is produced.
    The service handler runs on the Worker coordinator without the data handler
    semaphore. It must be short and perform no network/DB waits. Control work
    yields and gives data admission a turn after a bounded batch. *)
val send_control : ('request, 'response, 'push) client -> 'request -> control_send_result

(** Requests cooperative cancellation without entering the bounded request
    lane. *)
val cancel
  :  ('request, 'response, 'push) client
  -> request_id:Journal_worker_ids.Worker.request_id
  -> unit

(** Registers a domain-0 event handler. The handler is invoked only by a
    later accepted drain on the application thread. *)
val on_event
  :  ('request, 'response, 'push) client
  -> (('response, 'push) event -> unit)
  -> unit

val runtime_epoch
  :  ('request, 'response, 'push) client
  -> Journal_worker_ids.Runtime.epoch

val worker_generation
  :  ('request, 'response, 'push) client
  -> Journal_worker_ids.Worker.generation

module Private : sig
  type packed_startup
  type packed_client

  type metrics =
    { configured_concurrency_limit : int
    ; queued_requests : int
    ; active_request_fibers : int
    ; waiting_request_fibers : int
    ; active_handlers : int
    ; peak_active_handlers : int
    ; active_background_fibers : int
    ; peak_active_background_fibers : int
    ; request_queue_wait_count : int
    ; max_request_queue_wait_ns : int64
    ; handler_wall_count : int
    ; max_handler_wall_ns : int64
    ; cancellation_unwind_count : int
    ; max_cancellation_unwind_ns : int64
    ; session_cancellation_duration_ns : int64 option
    ; shutdown_duration_ns : int64 option
    }

  type run_result =
    | Session_stopped
    | Session_startup_failed of string
    | Session_callback_failed of string

  val prepare
    :  runtime_epoch:Journal_worker_ids.Runtime.epoch
    -> worker_generation:Journal_worker_ids.Worker.generation
    -> ('config, 'request, 'response, 'push) Service.t
    -> 'config
    -> ('request, 'response, 'push) client * packed_startup

  (** Optional scheduler observation after extracting control work and before
      its execution claim. Runs without the control mutex; production omits it. *)
  val run_session
    :  ?on_control_taken:(unit -> unit)
    -> packed_startup
    -> environment:Journal_worker_eio_backend.environment
    -> session_switch:Eio.Switch.t
    -> on_startup:((unit, string) result -> unit)
    -> on_idle_wait:(unit -> unit)
    -> on_yield:(unit -> unit)
    -> run_result

  val pack_client : ('request, 'response, 'push) client -> packed_client
  val metrics : packed_client -> metrics
  val request_stop : ('request, 'response, 'push) client -> unit
  val request_stop_packed : packed_client -> unit
  val await_stopped : ('request, 'response, 'push) client -> unit
  val await_stopped_packed : packed_client -> unit
  val fail_unrecoverable : packed_client -> string -> unit

  (** Drains pending events and invokes every registered subscriber for each,
      in drain order. Must be called on the application thread (the lui pump
      entry point), never from worker fibers. *)
  val deliver : ('request, 'response, 'push) client -> max_events:int -> unit

  (** Registers the callback invoked on the producing domain whenever new
      output (responses, pushes, terminal events) lands in the client's
      mailboxes. Install a thread-safe thunk that hops to the application
      thread and calls {!deliver}; do not wait on OCaml
      [Mutex]/[Condition] from an application-domain systhread here — a
      waiter that holds a shared mutex while blocked re-acquiring its own
      domain lock deadlocks against producer domains. *)
  val set_output_wakeup : ('request, 'response, 'push) client -> (unit -> unit) -> unit
end

module For_testing : sig
  val drain_events
    :  ('request, 'response, 'push) client
    -> max_events:int
    -> ('response, 'push) event list

  val await_output : ('request, 'response, 'push) client -> unit
  val pending_output_count : ('request, 'response, 'push) client -> int
  val is_stopping : ('request, 'response, 'push) client -> bool
  val pending_control_count : ('request, 'response, 'push) client -> int

  val inject_push
    :  ('request, 'response, 'push) client
    -> runtime_epoch:Journal_worker_ids.Runtime.epoch
    -> worker_generation:Journal_worker_ids.Worker.generation
    -> push_sequence:Journal_worker_ids.Worker.push_sequence
    -> topic:Journal_worker_ids.Worker.push_topic
    -> 'push
    -> unit
end
