module ID = Journal_worker_ids

type mono_clock = Eio.Time.Mono.ty Eio.Resource.t
type net = [ `Generic ] Eio.Net.ty Eio.Resource.t
type data_dir = Eio.Fs.dir_ty Eio.Path.t
type environment = Journal_worker_eio_backend.environment

type 'response outcome =
  | Completed of 'response
  | Failed of string
  | Cancelled
  | Shutdown

type ('response, 'push) event =
  | Response of
      { runtime_epoch : ID.Runtime.epoch
      ; worker_generation : ID.Worker.generation
      ; request_id : ID.Worker.request_id
      ; outcome : 'response outcome
      }
  | Push of
      { runtime_epoch : ID.Runtime.epoch
      ; worker_generation : ID.Worker.generation
      ; push_sequence : ID.Worker.push_sequence
      ; topic : ID.Worker.push_topic
      ; payload : 'push
      }
  | Terminal of
      { runtime_epoch : ID.Runtime.epoch
      ; worker_generation : ID.Worker.generation
      ; error : string
      }

type send_result =
  | Accepted of ID.Worker.request_id
  | Full
  | Not_ready
  | Stopping

type client_status =
  | Starting_status
  | Ready_status
  | Stopping_status
  | Stopped_status
  | Terminal_status

let status_code = function
  | Starting_status -> 0
  | Ready_status -> 1
  | Stopping_status -> 2
  | Stopped_status -> 3
  | Terminal_status -> 4
;;

let status_of_code = function
  | 0 -> Starting_status
  | 1 -> Ready_status
  | 2 -> Stopping_status
  | 3 -> Stopped_status
  | 4 -> Terminal_status
  | _ -> failwith "Worker client status invariant failed"
;;

module Session_context = struct
  type 'push t =
    { switch : Eio.Switch.t
    ; environment : environment
    ; clock : mono_clock
    ; net : net
    ; data_dir : data_dir option
    ; emit : topic:ID.Worker.push_topic -> 'push -> unit
    ; fork_daemon : name:string -> (unit -> unit) -> unit
    }

  let switch t = t.switch
  let environment t = t.environment
  let clock t = t.clock
  let net t = t.net
  let data_dir t = t.data_dir
  let emit t = t.emit
  let fork_daemon t = t.fork_daemon
end

module Request_context = struct
  type 'push t =
    { request_id : ID.Worker.request_id
    ; switch : Eio.Switch.t
    ; environment : environment
    ; clock : mono_clock
    ; net : net
    ; data_dir : data_dir option
    ; emit : topic:ID.Worker.push_topic -> 'push -> unit
    }

  let request_id t = t.request_id
  let switch t = t.switch
  let environment t = t.environment
  let clock t = t.clock
  let net t = t.net
  let data_dir t = t.data_dir
  let emit t = t.emit
end

module Service = struct
  type concurrency =
    | Serial
    | Concurrent of { max_in_flight : int }

  type ('config, 'request, 'response, 'push, 'state) direct_callbacks =
    { push_topic_count : int
    ; concurrency : concurrency
    ; data_directory : ('config -> (string, string) result) option
    ; init : 'push Session_context.t -> 'config -> ('state, string) result
    ; handle : 'push Request_context.t -> 'state -> 'request -> ('response, string) result
    ; shutdown : 'state -> unit
    }

  type ('config, 'request, 'response, 'push) t =
    | Direct :
        ('config, 'request, 'response, 'push, 'state) direct_callbacks
        -> ('config, 'request, 'response, 'push) t

  let validate_push_topic_count push_topic_count =
    if push_topic_count <= 0
    then invalid_arg "Worker.Service.create: push_topic_count must be positive"
  ;;

  let validate_concurrency = function
    | Serial -> ()
    | Concurrent { max_in_flight } when max_in_flight > 0 -> ()
    | Concurrent _ -> invalid_arg "Worker concurrency must be positive"
  ;;

  let create ~push_topic_count ~concurrency ?data_directory ~init ~handle ~shutdown () =
    validate_push_topic_count push_topic_count;
    validate_concurrency concurrency;
    Direct { push_topic_count; concurrency; data_directory; init; handle; shutdown }
  ;;
end

type 'request request_envelope =
  { request_id : ID.Worker.request_id
  ; payload : 'request
  ; enqueued_at_ns : int64
  }

type control_message = Cancel of ID.Worker.request_id

exception Request_cancelled
exception Request_shutdown

type ('request, 'response, 'push) client =
  { runtime_epoch : ID.Runtime.epoch
  ; worker_generation : ID.Worker.generation
  ; requests : 'request request_envelope Journal_bounded_mailbox.Fifo.t
  ; wake : Eio.Condition.t
  ; responses : ('response, 'push) event Journal_bounded_mailbox.Reserved.t
  ; pushes : ('response, 'push) event Journal_bounded_mailbox.Coalesced.t
  ; injected : ('response, 'push) event Journal_bounded_mailbox.Fifo.t
  ; status : int Atomic.t
  ; stop_requested : bool Atomic.t
  ; cancellation_mutex : Mutex.t
  ; cancellations : (ID.Worker.request_id, unit) Hashtbl.t
  ; controls : control_message Queue.t
  ; cancellation_started_ns : (ID.Worker.request_id, int64) Hashtbl.t
  ; request_switches : (ID.Worker.request_id, Eio.Switch.t) Hashtbl.t
  ; terminal_requests : (ID.Worker.request_id, unit) Hashtbl.t
  ; output_mutex : Mutex.t
  ; output_condition : Condition.t
  ; pending_output_count : int Atomic.t
  ; stopped_mutex : Mutex.t
  ; stopped_condition : Condition.t
  ; mutable stopped : bool
  ; mutable next_request_id : ID.Worker.request_id
  ; pending_requests : (ID.Worker.request_id, unit) Hashtbl.t
  ; mutable subscribers : (('response, 'push) event -> unit) list
  ; mutable last_push_sequence : ID.Worker.push_sequence
  ; mutable terminal_event : ('response, 'push) event option
  ; configured_concurrency_limit : int
  ; active_request_fibers : int Atomic.t
  ; waiting_request_fibers : int Atomic.t
  ; active_handlers : int Atomic.t
  ; peak_active_handlers : int Atomic.t
  ; active_background_fibers : int Atomic.t
  ; peak_active_background_fibers : int Atomic.t
  ; request_queue_wait_count : int Atomic.t
  ; max_request_queue_wait_ns : int64 Atomic.t
  ; handler_wall_count : int Atomic.t
  ; max_handler_wall_ns : int64 Atomic.t
  ; cancellation_unwind_count : int Atomic.t
  ; max_cancellation_unwind_ns : int64 Atomic.t
  ; stop_started_ns : int64 Atomic.t
  ; session_cancellation_duration_ns : int64 Atomic.t
  ; shutdown_duration_ns : int64 Atomic.t
  }

type packed_startup =
  | Packed_startup :
      { service : ('config, 'request, 'response, 'push) Service.t
      ; config : 'config
      ; client : ('request, 'response, 'push) client
      }
      -> packed_startup

type packed_client =
  | Packed_client : ('request, 'response, 'push) client -> packed_client

let request_capacity = 32
let response_capacity = 32
let injected_capacity = 1024
let no_duration = -1L
let now_ns () = Mtime_clock.elapsed_ns ()

let elapsed_ns started =
  let elapsed = Int64.sub (now_ns ()) started in
  if Int64.compare elapsed 0L < 0 then 0L else elapsed
;;

let concurrency_limit = function
  | Service.Serial -> 1
  | Concurrent { max_in_flight } -> max_in_flight
;;

let update_peak peak value =
  let rec loop observed =
    if value <= observed
    then ()
    else if not (Atomic.compare_and_set peak observed value)
    then loop (Atomic.get peak)
  in
  loop (Atomic.get peak)
;;

let update_max_int64 maximum value =
  let rec loop observed =
    if Int64.compare value observed <= 0
    then ()
    else if not (Atomic.compare_and_set maximum observed value)
    then loop (Atomic.get maximum)
  in
  loop (Atomic.get maximum)
;;

let record_duration count maximum started =
  let duration = elapsed_ns started in
  Atomic.incr count;
  update_max_int64 maximum duration
;;

let duration_option value = if Int64.equal value no_duration then None else Some value

let prepare ~runtime_epoch ~worker_generation service config =
  let push_topic_count, configured_concurrency_limit =
    match service with
    | Service.Direct { push_topic_count; concurrency; _ } ->
      push_topic_count, concurrency_limit concurrency
  in
  let client =
    { runtime_epoch
    ; worker_generation
    ; requests = Journal_bounded_mailbox.Fifo.create ~capacity:request_capacity
    ; wake = Eio.Condition.create ()
    ; responses = Journal_bounded_mailbox.Reserved.create ~capacity:response_capacity
    ; pushes = Journal_bounded_mailbox.Coalesced.create ~capacity:push_topic_count
    ; injected = Journal_bounded_mailbox.Fifo.create ~capacity:injected_capacity
    ; status = Atomic.make (status_code Starting_status)
    ; stop_requested = Atomic.make false
    ; cancellation_mutex = Mutex.create ()
    ; cancellations = Hashtbl.create request_capacity
    ; controls = Queue.create ()
    ; cancellation_started_ns = Hashtbl.create request_capacity
    ; request_switches = Hashtbl.create request_capacity
    ; terminal_requests = Hashtbl.create request_capacity
    ; output_mutex = Mutex.create ()
    ; output_condition = Condition.create ()
    ; pending_output_count = Atomic.make 0
    ; stopped_mutex = Mutex.create ()
    ; stopped_condition = Condition.create ()
    ; stopped = false
    ; next_request_id = ID.Worker.Request_id.one
    ; pending_requests = Hashtbl.create request_capacity
    ; subscribers = []
    ; last_push_sequence = ID.Worker.Push_sequence.zero
    ; terminal_event = None
    ; configured_concurrency_limit
    ; active_request_fibers = Atomic.make 0
    ; waiting_request_fibers = Atomic.make 0
    ; active_handlers = Atomic.make 0
    ; peak_active_handlers = Atomic.make 0
    ; active_background_fibers = Atomic.make 0
    ; peak_active_background_fibers = Atomic.make 0
    ; request_queue_wait_count = Atomic.make 0
    ; max_request_queue_wait_ns = Atomic.make 0L
    ; handler_wall_count = Atomic.make 0
    ; max_handler_wall_ns = Atomic.make 0L
    ; cancellation_unwind_count = Atomic.make 0
    ; max_cancellation_unwind_ns = Atomic.make 0L
    ; stop_started_ns = Atomic.make no_duration
    ; session_cancellation_duration_ns = Atomic.make no_duration
    ; shutdown_duration_ns = Atomic.make no_duration
    }
  in
  client, Packed_startup { service; config; client }
;;

let runtime_epoch client = client.runtime_epoch
let worker_generation client = client.worker_generation

let with_output_lock client f =
  Mutex.lock client.output_mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock client.output_mutex) f
;;

let increment_pending_output_locked client =
  ignore (Atomic.fetch_and_add client.pending_output_count 1 : int);
  Condition.broadcast client.output_condition
;;

let decrement_pending_output_locked client count =
  if count > 0
  then ignore (Atomic.fetch_and_add client.pending_output_count (-count) : int)
;;

let next_request_id client =
  let request_id = client.next_request_id in
  if ID.Worker.Request_id.equal request_id ID.Worker.Request_id.max_value
  then failwith "Worker request ID counter exhausted"
  else client.next_request_id <- ID.Worker.Request_id.succ request_id;
  request_id
;;

let send client payload =
  match status_of_code (Atomic.get client.status) with
  | Starting_status -> Not_ready
  | Stopping_status | Stopped_status | Terminal_status -> Stopping
  | Ready_status ->
    if not (Journal_bounded_mailbox.Reserved.reserve client.responses)
    then Full
    else (
      let request_id = next_request_id client in
      let request = { request_id; payload; enqueued_at_ns = now_ns () } in
      match Journal_bounded_mailbox.Fifo.try_push client.requests request with
      | `Ok ->
        Hashtbl.add client.pending_requests request_id ();
        Eio.Condition.broadcast client.wake;
        Accepted request_id
      | `Full ->
        Journal_bounded_mailbox.Reserved.cancel client.responses;
        Full
      | `Closed ->
        Journal_bounded_mailbox.Reserved.cancel client.responses;
        Stopping)
;;

let with_cancellations client f =
  Mutex.lock client.cancellation_mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock client.cancellation_mutex) f
;;

let cancel client ~request_id =
  if Hashtbl.mem client.pending_requests request_id
  then (
    let published =
      with_cancellations client (fun () ->
        if
          Hashtbl.mem client.cancellations request_id
          || Hashtbl.mem client.terminal_requests request_id
        then false
        else (
          Hashtbl.add client.cancellations request_id ();
          Hashtbl.replace client.cancellation_started_ns request_id (now_ns ());
          Queue.add (Cancel request_id) client.controls;
          true))
    in
    if published then Eio.Condition.broadcast client.wake)
;;

let is_cancelled client request_id =
  Atomic.get client.stop_requested
  || with_cancellations client (fun () -> Hashtbl.mem client.cancellations request_id)
;;

let clear_cancelled client request_id =
  with_cancellations client (fun () -> Hashtbl.remove client.cancellations request_id)
;;

let take_cancel_control client =
  with_cancellations client (fun () ->
    if Queue.is_empty client.controls then None else Some (Queue.take client.controls))
;;

let attach_request_switch client request_id switch =
  with_cancellations client (fun () ->
    if Hashtbl.mem client.terminal_requests request_id
    then `Finished
    else if Atomic.get client.stop_requested
    then `Shutdown
    else if Hashtbl.mem client.cancellations request_id
    then `Cancelled
    else (
      Hashtbl.replace client.request_switches request_id switch;
      `Attached))
;;

let fail_request_switch client request_id =
  let switch =
    with_cancellations client (fun () ->
      Hashtbl.find_opt client.request_switches request_id)
  in
  Option.iter (fun switch -> Eio.Switch.fail switch Request_cancelled) switch
;;

let fail_all_request_switches client =
  let switches =
    with_cancellations client (fun () ->
      Hashtbl.fold
        (fun _request_id switch switches -> switch :: switches)
        client.request_switches
        [])
  in
  List.iter (fun switch -> Eio.Switch.fail switch Request_shutdown) switches
;;

let remove_cancel_control_locked client request_id =
  let retained = Queue.create () in
  while not (Queue.is_empty client.controls) do
    match Queue.take client.controls with
    | Cancel queued when ID.Worker.Request_id.equal queued request_id -> ()
    | control -> Queue.add control retained
  done;
  Queue.transfer retained client.controls
;;

let claim_direct_outcome client request_id outcome =
  with_cancellations client (fun () ->
    if Hashtbl.mem client.terminal_requests request_id
    then None
    else (
      Hashtbl.add client.terminal_requests request_id ();
      Hashtbl.remove client.request_switches request_id;
      let outcome, cancellation_started =
        if Atomic.get client.stop_requested
        then Shutdown, duration_option (Atomic.get client.stop_started_ns)
        else if Hashtbl.mem client.cancellations request_id
        then Cancelled, Hashtbl.find_opt client.cancellation_started_ns request_id
        else outcome, None
      in
      Hashtbl.remove client.cancellations request_id;
      Hashtbl.remove client.cancellation_started_ns request_id;
      remove_cancel_control_locked client request_id;
      Option.iter
        (record_duration
           client.cancellation_unwind_count
           client.max_cancellation_unwind_ns)
        cancellation_started;
      Some outcome))
;;

let forget_direct_terminal client request_id =
  with_cancellations client (fun () -> Hashtbl.remove client.terminal_requests request_id)
;;

let on_event client handler = client.subscribers <- client.subscribers @ [ handler ]

let publish_response client request_id outcome =
  with_output_lock client (fun () ->
    Journal_bounded_mailbox.Reserved.publish
      client.responses
      (Response
         { runtime_epoch = client.runtime_epoch
         ; worker_generation = client.worker_generation
         ; request_id
         ; outcome
         });
    increment_pending_output_locked client)
;;

let set_terminal_event client error =
  with_output_lock client (fun () ->
    if Option.is_none client.terminal_event
    then (
      client.terminal_event
      <- Some
           (Terminal
              { runtime_epoch = client.runtime_epoch
              ; worker_generation = client.worker_generation
              ; error
              });
      increment_pending_output_locked client))
;;

let mark_stopped client status =
  Atomic.set client.status (status_code status);
  Mutex.lock client.stopped_mutex;
  client.stopped <- true;
  Condition.broadcast client.stopped_condition;
  Mutex.unlock client.stopped_mutex;
  with_output_lock client (fun () -> Condition.broadcast client.output_condition)
;;

let request_stop client =
  let started = now_ns () in
  ignore (Atomic.compare_and_set client.stop_started_ns no_duration started : bool);
  let status = status_of_code (Atomic.get client.status) in
  (match status with
   | Starting_status | Ready_status ->
     Atomic.set client.status (status_code Stopping_status)
   | Stopping_status | Stopped_status | Terminal_status -> ());
  Atomic.set client.stop_requested true;
  Journal_bounded_mailbox.Fifo.close client.requests;
  Eio.Condition.broadcast client.wake
;;

let await_stopped client =
  Mutex.lock client.stopped_mutex;
  while not client.stopped do
    Condition.wait client.stopped_condition client.stopped_mutex
  done;
  Mutex.unlock client.stopped_mutex
;;

let request_stop_packed (Packed_client client) = request_stop client
let await_stopped_packed (Packed_client client) = await_stopped client
let pack_client client = Packed_client client

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

let metrics (Packed_client client) =
  { configured_concurrency_limit = client.configured_concurrency_limit
  ; queued_requests = Journal_bounded_mailbox.Fifo.length client.requests
  ; active_request_fibers = Atomic.get client.active_request_fibers
  ; waiting_request_fibers = Atomic.get client.waiting_request_fibers
  ; active_handlers = Atomic.get client.active_handlers
  ; peak_active_handlers = Atomic.get client.peak_active_handlers
  ; active_background_fibers = Atomic.get client.active_background_fibers
  ; peak_active_background_fibers = Atomic.get client.peak_active_background_fibers
  ; request_queue_wait_count = Atomic.get client.request_queue_wait_count
  ; max_request_queue_wait_ns = Atomic.get client.max_request_queue_wait_ns
  ; handler_wall_count = Atomic.get client.handler_wall_count
  ; max_handler_wall_ns = Atomic.get client.max_handler_wall_ns
  ; cancellation_unwind_count = Atomic.get client.cancellation_unwind_count
  ; max_cancellation_unwind_ns = Atomic.get client.max_cancellation_unwind_ns
  ; session_cancellation_duration_ns =
      duration_option (Atomic.get client.session_cancellation_duration_ns)
  ; shutdown_duration_ns = duration_option (Atomic.get client.shutdown_duration_ns)
  }
;;

let fail_unrecoverable (Packed_client client) error =
  request_stop client;
  set_terminal_event client error;
  mark_stopped client Terminal_status
;;

let exception_message exception_ =
  match exception_ with
  | Failure message | Invalid_argument message -> message
  | _ -> Printexc.to_string exception_
;;

type run_result =
  | Session_stopped
  | Session_startup_failed of string
  | Session_callback_failed of string

let run_direct_session
      (type config request response push state)
      (callbacks : (config, request, response, push, state) Service.direct_callbacks)
      (client : (request, response, push) client)
      (config : config)
      ~(environment : Journal_worker_eio_backend.environment)
      ~session_switch
      ~on_startup
      ~on_idle_wait
      ~on_yield
  =
  let next_push_sequence = ref ID.Worker.Push_sequence.one in
  let emit_push ~topic payload =
    let topic_index = ID.Worker.Push_topic.to_int topic in
    if topic_index < 0 || topic_index >= callbacks.push_topic_count
    then failwith "Worker push topic invariant failed";
    let push_sequence = !next_push_sequence in
    if ID.Worker.Push_sequence.equal push_sequence ID.Worker.Push_sequence.max_value
    then failwith "Worker push sequence exhausted"
    else next_push_sequence := ID.Worker.Push_sequence.succ push_sequence;
    let event =
      Push
        { runtime_epoch = client.runtime_epoch
        ; worker_generation = client.worker_generation
        ; push_sequence
        ; topic
        ; payload
        }
    in
    with_output_lock client (fun () ->
      match
        Journal_bounded_mailbox.Coalesced.push client.pushes ~topic:topic_index event
      with
      | `Added -> increment_pending_output_locked client
      | `Replaced -> Condition.broadcast client.output_condition
      | `Full -> failwith "Worker push mailbox invariant failed")
  in
  let mono_clock = Journal_worker_eio_backend.mono_clock environment in
  let network = Journal_worker_eio_backend.net environment in
  let stdenv = Journal_worker_eio_backend.stdenv environment in
  let directory_capability =
    match callbacks.data_directory with
    | None -> Ok None
    | Some resolve ->
      (match resolve config with
       | Error _ as error -> error
       | Ok path when Filename.is_relative path ->
         Error "Worker data directory must be an absolute path"
       | Ok path ->
         (try
            let directory =
              Eio.Path.open_dir
                ~sw:session_switch
                Eio.Path.(Journal_worker_eio_backend.fs environment / path)
            in
            Ok (Some (directory :> data_dir))
          with
          | exception_ -> Error (exception_message exception_)))
  in
  match directory_capability with
  | Error error ->
    on_startup (Error error);
    mark_stopped client Stopped_status;
    Session_startup_failed error
  | Ok directory_capability ->
    let fatal_error = ref None in
    let daemon_switches = ref [] in
    let daemons_stopping = ref false in
    let daemon_finished () =
      Atomic.decr client.active_background_fibers;
      Eio.Condition.broadcast client.wake
    in
    let report_daemon_failure name exception_ =
      let error =
        Printf.sprintf "Worker daemon %S failed: %s" name (exception_message exception_)
      in
      if Option.is_none !fatal_error then fatal_error := Some error;
      Eio.Condition.broadcast client.wake
    in
    let start_daemon ~name run =
      if !daemons_stopping
      then invalid_arg "Worker.Session_context.fork_daemon: session is stopping";
      Atomic.incr client.active_background_fibers;
      update_peak
        client.peak_active_background_fibers
        (Atomic.get client.active_background_fibers);
      try
        Eio.Fiber.fork ~sw:session_switch (fun () ->
          Fun.protect ~finally:daemon_finished (fun () ->
            try
              Eio.Switch.run (fun daemon_switch ->
                daemon_switches := daemon_switch :: !daemon_switches;
                if !daemons_stopping then Eio.Switch.fail daemon_switch Request_shutdown;
                Fun.protect
                  ~finally:(fun () ->
                    daemon_switches
                    := List.filter
                         (fun registered -> registered != daemon_switch)
                         !daemon_switches)
                  run)
            with
            | Request_shutdown | Eio.Cancel.Cancelled Request_shutdown -> ()
            | exception_ -> report_daemon_failure name exception_))
      with
      | exception_ ->
        daemon_finished ();
        raise exception_
    in
    let rec await_background_fibers () =
      if Atomic.get client.active_background_fibers = 0
      then ()
      else (
        on_idle_wait ();
        Eio.Condition.loop_no_mutex client.wake (fun () ->
          if Atomic.get client.active_background_fibers = 0 then Some () else None);
        await_background_fibers ())
    in
    let stop_daemons () =
      daemons_stopping := true;
      List.iter
        (fun daemon_switch -> Eio.Switch.fail daemon_switch Request_shutdown)
        !daemon_switches;
      await_background_fibers ()
    in
    let session_context =
      Session_context.
        { switch = session_switch
        ; environment = stdenv
        ; clock = mono_clock
        ; net = network
        ; data_dir = directory_capability
        ; emit = emit_push
        ; fork_daemon = start_daemon
        }
    in
    let init_result, resolve_init = Eio.Promise.create () in
    let init_switch = ref None in
    Eio.Fiber.fork ~sw:session_switch (fun () ->
      let result =
        try
          Eio.Switch.run (fun switch ->
            init_switch := Some switch;
            callbacks.init session_context config)
        with
        | Request_shutdown | Eio.Cancel.Cancelled Request_shutdown ->
          Error "Worker session stopped during initialization"
        | exception_ -> Error (exception_message exception_)
      in
      ignore (Eio.Promise.try_resolve resolve_init result : bool);
      Eio.Condition.broadcast client.wake);
    let rec cancel_initialization () =
      match !init_switch with
      | Some switch -> Eio.Switch.fail switch Request_shutdown
      | None ->
        Eio.Fiber.yield ();
        cancel_initialization ()
    in
    let rec await_initialization () =
      if Option.is_some !fatal_error
      then (
        cancel_initialization ();
        Error (Option.get !fatal_error))
      else if Atomic.get client.stop_requested
      then (
        cancel_initialization ();
        Error "Worker session stopped during initialization")
      else (
        match Eio.Promise.peek init_result with
        | Some result -> result
        | None ->
          on_idle_wait ();
          Eio.Condition.loop_no_mutex client.wake (fun () ->
            if
              Atomic.get client.stop_requested
              || Option.is_some !fatal_error
              || Eio.Promise.is_resolved init_result
            then Some ()
            else None);
          await_initialization ())
    in
    (match await_initialization () with
     | Error error ->
       stop_daemons ();
       on_startup (Error error);
       mark_stopped client Stopped_status;
       Session_startup_failed error
     | Ok state ->
       Atomic.set client.status (status_code Ready_status);
       on_startup (Ok ());
       let handler_slots =
         match callbacks.concurrency with
         | Service.Serial -> Eio.Semaphore.make 1
         | Concurrent { max_in_flight } -> Eio.Semaphore.make max_in_flight
       in
       let publish_direct request_id outcome =
         match claim_direct_outcome client request_id outcome with
         | None -> ()
         | Some outcome -> publish_response client request_id outcome
       in
       let request_finished () =
         Atomic.decr client.active_request_fibers;
         Eio.Condition.broadcast client.wake
       in
       let run_handler request request_switch =
         match attach_request_switch client request.request_id request_switch with
         | `Finished -> `No_outcome
         | `Cancelled -> `Outcome Cancelled
         | `Shutdown -> `Outcome Shutdown
         | `Attached ->
           let acquired = ref false in
           let handler_started = ref None in
           let response =
             try
               Atomic.incr client.waiting_request_fibers;
               (try Eio.Semaphore.acquire handler_slots with
                | exception_ ->
                  Atomic.decr client.waiting_request_fibers;
                  raise exception_);
               Atomic.decr client.waiting_request_fibers;
               acquired := true;
               handler_started := Some (now_ns ());
               let active_handlers = Atomic.fetch_and_add client.active_handlers 1 + 1 in
               update_peak client.peak_active_handlers active_handlers;
               Eio.Fiber.check ();
               let context =
                 Request_context.
                   { request_id = request.request_id
                   ; switch = request_switch
                   ; environment = stdenv
                   ; clock = mono_clock
                   ; net = network
                   ; data_dir = directory_capability
                   ; emit = emit_push
                   }
               in
               let result = callbacks.handle context state request.payload in
               match result with
               | Ok response -> `Outcome (Completed response)
               | Error error -> `Outcome (Failed error)
             with
             | Request_cancelled | Eio.Cancel.Cancelled Request_cancelled ->
               `Outcome Cancelled
             | Request_shutdown | Eio.Cancel.Cancelled Request_shutdown ->
               `Outcome Shutdown
             | exception_ -> `Fatal (exception_message exception_)
           in
           if !acquired
           then (
             Atomic.decr client.active_handlers;
             Option.iter
               (record_duration client.handler_wall_count client.max_handler_wall_ns)
               !handler_started;
             Eio.Semaphore.release handler_slots);
           response
       in
       let dispatch request =
         record_duration
           client.request_queue_wait_count
           client.max_request_queue_wait_ns
           request.enqueued_at_ns;
         if is_cancelled client request.request_id
         then
           publish_direct
             request.request_id
             (if Atomic.get client.stop_requested then Shutdown else Cancelled)
         else (
           Atomic.incr client.active_request_fibers;
           Eio.Fiber.fork ~sw:session_switch (fun () ->
             Fun.protect ~finally:request_finished (fun () ->
               let completion =
                 try Eio.Switch.run (run_handler request) with
                 | Request_cancelled -> `Outcome Cancelled
                 | Request_shutdown -> `Outcome Shutdown
               in
               match completion with
               | `No_outcome -> ()
               | `Outcome outcome -> publish_direct request.request_id outcome
               | `Fatal error ->
                 publish_direct request.request_id (Failed error);
                 if Option.is_none !fatal_error then fatal_error := Some error;
                 Eio.Condition.broadcast client.wake)))
       in
       let drain_shutdown_requests () =
         Journal_bounded_mailbox.Fifo.drain client.requests ~max_items:max_int
         |> List.iter (fun request ->
           record_duration
             client.request_queue_wait_count
             client.max_request_queue_wait_ns
             request.enqueued_at_ns;
           publish_direct request.request_id Shutdown)
       in
       let shutdown_state () =
         let started = now_ns () in
         let result =
           try
             callbacks.shutdown state;
             Ok ()
           with
           | exception_ -> Error (exception_message exception_)
         in
         Atomic.set client.shutdown_duration_ns (elapsed_ns started);
         result
       in
       let rec await_active_requests () =
         if Atomic.get client.active_request_fibers = 0
         then ()
         else (
           on_idle_wait ();
           Eio.Condition.loop_no_mutex client.wake (fun () ->
             if Atomic.get client.active_request_fibers = 0 then Some () else None);
           await_active_requests ())
       in
       let stop_session terminal_error =
         request_stop client;
         fail_all_request_switches client;
         drain_shutdown_requests ();
         await_active_requests ();
         stop_daemons ();
         let shutdown_error = shutdown_state () in
         Option.iter
           (fun started ->
              Atomic.set client.session_cancellation_duration_ns (elapsed_ns started))
           (duration_option (Atomic.get client.stop_started_ns));
         let terminal_error =
           match terminal_error, shutdown_error with
           | None, Ok () -> None
           | Some error, Ok () -> Some error
           | None, Error error -> Some error
           | Some error, Error shutdown_error -> Some (error ^ "\n" ^ shutdown_error)
         in
         match terminal_error with
         | None ->
           mark_stopped client Stopped_status;
           Session_stopped
         | Some error ->
           set_terminal_event client error;
           mark_stopped client Terminal_status;
           Session_callback_failed error
       in
       let rec coordinate consecutive_requests =
         match !fatal_error with
         | Some error -> stop_session (Some error)
         | None when Atomic.get client.stop_requested -> stop_session None
         | None ->
           (match take_cancel_control client with
            | Some (Cancel request_id) ->
              fail_request_switch client request_id;
              coordinate consecutive_requests
            | None when consecutive_requests >= 8 ->
              on_yield ();
              Eio.Fiber.yield ();
              coordinate 0
            | None ->
              (match Journal_bounded_mailbox.Fifo.pop client.requests with
               | Some request ->
                 dispatch request;
                 coordinate (consecutive_requests + 1)
               | None ->
                 on_idle_wait ();
                 let next =
                   Eio.Condition.loop_no_mutex client.wake (fun () ->
                     match !fatal_error with
                     | Some _ -> Some `Fatal
                     | None ->
                       if Atomic.get client.stop_requested
                       then Some (`Action `Stop)
                       else (
                         match take_cancel_control client with
                         | Some control -> Some (`Action (`Control control))
                         | None ->
                           (match Journal_bounded_mailbox.Fifo.pop client.requests with
                            | Some request -> Some (`Action (`Request request))
                            | None -> None)))
                 in
                 (match next with
                  | `Fatal -> coordinate 0
                  | `Action `Stop -> coordinate 0
                  | `Action (`Control (Cancel request_id)) ->
                    fail_request_switch client request_id;
                    coordinate 0
                  | `Action (`Request request) ->
                    dispatch request;
                    coordinate 1)))
       in
       coordinate 0)
;;

let run_session
      (Packed_startup { service; config; client })
      ~(environment : Journal_worker_eio_backend.environment)
      ~session_switch
      ~on_startup
      ~on_idle_wait
      ~on_yield
  =
  match service with
  | Service.Direct callbacks ->
    run_direct_session
      callbacks
      client
      config
      ~environment
      ~session_switch
      ~on_startup
      ~on_idle_wait
      ~on_yield
;;

let take_terminal_locked client =
  let terminal = client.terminal_event in
  client.terminal_event <- None;
  terminal
;;

let raw_events client ~max_events =
  if max_events < 0 then invalid_arg "Worker drain max_events must be nonnegative";
  with_output_lock client (fun () ->
    let responses =
      Journal_bounded_mailbox.Reserved.drain client.responses ~max_items:max_events
    in
    let remaining = max_events - List.length responses in
    let terminal =
      if remaining = 0
      then []
      else (
        match take_terminal_locked client with
        | None -> []
        | Some terminal -> [ terminal ])
    in
    let remaining = remaining - List.length terminal in
    let injected =
      Journal_bounded_mailbox.Fifo.drain client.injected ~max_items:remaining
    in
    let remaining = remaining - List.length injected in
    let pushes =
      Journal_bounded_mailbox.Coalesced.drain client.pushes ~max_items:remaining
      |> List.map snd
      |> List.sort (fun left right ->
        match left, right with
        | Push left, Push right ->
          ID.Worker.Push_sequence.compare left.push_sequence right.push_sequence
        | _ -> 0)
    in
    let events = responses @ terminal @ injected @ pushes in
    decrement_pending_output_locked client (List.length events);
    events)
;;

let accepted_event client = function
  | Response response as event ->
    if
      ID.Runtime.Epoch.equal response.runtime_epoch client.runtime_epoch
      && ID.Worker.Generation.equal response.worker_generation client.worker_generation
      && Hashtbl.mem client.pending_requests response.request_id
    then (
      Hashtbl.remove client.pending_requests response.request_id;
      clear_cancelled client response.request_id;
      forget_direct_terminal client response.request_id;
      Some event)
    else None
  | Push push as event ->
    if
      ID.Runtime.Epoch.equal push.runtime_epoch client.runtime_epoch
      && ID.Worker.Generation.equal push.worker_generation client.worker_generation
      && ID.Worker.Push_sequence.compare push.push_sequence client.last_push_sequence > 0
    then (
      client.last_push_sequence <- push.push_sequence;
      Some event)
    else None
  | Terminal terminal as event ->
    if
      ID.Runtime.Epoch.equal terminal.runtime_epoch client.runtime_epoch
      && ID.Worker.Generation.equal terminal.worker_generation client.worker_generation
    then Some event
    else None
;;

let drain_events client ~max_events =
  raw_events client ~max_events |> List.filter_map (accepted_event client)
;;

let deliver client ~max_events =
  let events = drain_events client ~max_events in
  List.iter
    (fun event -> List.iter (fun subscriber -> subscriber event) client.subscribers)
    events
;;

let await_output client =
  Mutex.lock client.output_mutex;
  while
    Atomic.get client.pending_output_count = 0
    &&
    match status_of_code (Atomic.get client.status) with
    | Starting_status | Ready_status | Stopping_status -> true
    | Stopped_status | Terminal_status -> false
  do
    Condition.wait client.output_condition client.output_mutex
  done;
  Mutex.unlock client.output_mutex
;;

let pending_output_count client = Atomic.get client.pending_output_count

let is_stopping client =
  match status_of_code (Atomic.get client.status) with
  | Starting_status | Ready_status -> false
  | Stopping_status | Stopped_status | Terminal_status -> true
;;

let inject_push client ~runtime_epoch ~worker_generation ~push_sequence ~topic payload =
  let event = Push { runtime_epoch; worker_generation; push_sequence; topic; payload } in
  with_output_lock client (fun () ->
    match Journal_bounded_mailbox.Fifo.try_push client.injected event with
    | `Ok -> increment_pending_output_locked client
    | `Full | `Closed -> failwith "Worker test injection mailbox is unavailable")
;;

module Private = struct
  type nonrec packed_startup = packed_startup
  type nonrec packed_client = packed_client

  type nonrec metrics = metrics =
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

  type nonrec run_result = run_result =
    | Session_stopped
    | Session_startup_failed of string
    | Session_callback_failed of string

  let prepare = prepare
  let run_session = run_session
  let pack_client = pack_client
  let metrics = metrics
  let request_stop = request_stop
  let request_stop_packed = request_stop_packed
  let await_stopped = await_stopped
  let await_stopped_packed = await_stopped_packed
  let fail_unrecoverable = fail_unrecoverable
  let deliver = deliver
end

module For_testing = struct
  let drain_events = drain_events
  let await_output = await_output
  let pending_output_count = pending_output_count
  let is_stopping = is_stopping
  let inject_push = inject_push
end
