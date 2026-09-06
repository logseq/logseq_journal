type connect_error =
  | Unauthorized
  | Forbidden
  | Connection_failed of string

type liveness =
  | Disabled
  | Ping_pong of
      { interval_seconds : float
      ; timeout_seconds : float
      }

type outgoing =
  { opcode : int
  ; payload : string
  ; application : bool
  }

type t =
  { mutable terminal : string option option
  ; mutable activated : bool
  ; mutable closing : bool
  ; mutable peer_closed : bool
  ; mutable close_sent : bool
  ; mutable close_queued : bool
  ; mutable pending_bytes : int
  ; mutable pending_count : int
  ; mutable read_progress : int
  ; mutable input_count : int
  ; mutable input_bytes : int
  ; mutable pong : (string * unit Eio.Promise.u) option
  ; output : outgoing Queue.t
  ; control : outgoing Queue.t
  ; input : string Queue.t
  ; mutable wake_writer : unit -> unit
  ; mutable descriptor : Httpun_ws.Wsd.t option
  ; input_changed : Eio.Condition.t
  ; stopped : unit Eio.Promise.u
  ; close_requested : unit Eio.Promise.u
  ; activation : unit Eio.Promise.u
  }

exception Stop_owner
exception Protocol_error of string

let maximum_queue_bytes = 8 * 1024 * 1024
let maximum_queue_count = 128
let close_timeout = 1.
let protocol_error message = raise (Protocol_error message)

let stop t reason =
  if t.terminal = None
  then (
    t.terminal <- Some reason;
    ignore (Eio.Promise.try_resolve t.stopped () : bool))
;;

let abort t = stop t (Some "WebSocket aborted")

let activate t ~on_open =
  match t.terminal with
  | Some reason ->
    Error
      (Connection_failed
         (Option.value reason ~default:"WebSocket closed before activation"))
  | None when t.closing -> Error (Connection_failed "WebSocket closed before activation")
  | None when t.activated -> Error (Connection_failed "WebSocket already activated")
  | None ->
    t.activated <- true;
    (try
       on_open ();
       ignore (Eio.Promise.try_resolve t.activation () : bool);
       Ok ()
     with
     | exception_ ->
       abort t;
       ignore (Eio.Promise.try_resolve t.activation () : bool);
       raise exception_)
;;

let enqueue_control t opcode payload =
  if t.terminal = None
  then
    if Queue.length t.control >= 16
    then stop t (Some "WebSocket control queue exceeds its bound")
    else (
      Queue.add { opcode; payload; application = false } t.control;
      t.wake_writer ())
;;

let request_close t payload =
  if t.terminal = None
  then (
    if not t.closing
    then (
      t.closing <- true;
      ignore (Eio.Promise.try_resolve t.close_requested () : bool));
    if (not t.close_sent) && not t.close_queued
    then (
      t.close_queued <- true;
      enqueue_control t 8 payload))
;;

let close t = request_close t "\x03\xe8"

let send t payload =
  let length = String.length payload in
  if t.terminal <> None || t.closing
  then Error "WebSocket is closed"
  else if length > Limits.maximum_request_bytes
  then Error "WebSocket outgoing frame exceeds its bound"
  else if not (String.is_valid_utf_8 payload)
  then Error "WebSocket outgoing text is not UTF-8"
  else if
    t.pending_count = maximum_queue_count
    || length + 14 > maximum_queue_bytes - t.pending_bytes
  then Error "WebSocket output queue is full"
  else (
    t.pending_count <- t.pending_count + 1;
    t.pending_bytes <- t.pending_bytes + length + 14;
    Queue.add { opcode = 1; payload; application = true } t.output;
    t.wake_writer ();
    Ok ())
;;

let enqueue_message t message =
  if (not t.closing) && t.terminal = None
  then (
    if
      t.input_count = maximum_queue_count
      || String.length message > maximum_queue_bytes - t.input_bytes
    then protocol_error "WebSocket input queue exceeds its bound";
    t.input_count <- t.input_count + 1;
    t.input_bytes <- t.input_bytes + String.length message;
    Queue.add message t.input;
    Eio.Condition.broadcast t.input_changed)
;;

let input_handlers t maximum =
  let fragments = Buffer.create 4096 in
  let frame ~opcode ~is_fin ~len payload =
    t.read_progress <- t.read_progress + 1;
    if t.terminal = None
    then (
      if len < 0 || len > maximum then protocol_error "WebSocket frame exceeds its bound";
      let buffer = Buffer.create (min len 4096) in
      let finish () =
        t.read_progress <- t.read_progress + 1;
        if t.terminal = None
        then (
          let value = Buffer.contents buffer in
          match opcode with
          | `Ping -> if not t.closing then enqueue_control t 10 value
          | `Pong ->
            (match t.pong with
             | Some (expected, resolve) when value = expected ->
               ignore (Eio.Promise.try_resolve resolve () : bool)
             | Some _ | None -> ())
          | `Connection_close ->
            t.peer_closed <- true;
            request_close t value;
            if t.close_sent then stop t None
          | `Text | `Binary | `Continuation ->
            (match opcode with
             | `Text | `Binary -> Buffer.clear fragments
             | _ -> ());
            if String.length value > maximum - Buffer.length fragments
            then protocol_error "WebSocket message exceeds its bound";
            Buffer.add_string fragments value;
            if is_fin
            then (
              enqueue_message t (Buffer.contents fragments);
              Buffer.clear fragments)
          | `Other _ -> protocol_error "unsupported WebSocket opcode")
      in
      (* Payload callbacks run to completion without yielding or forking. The
         library advances its frame queue only after this payload is consumed. *)
      let rec read () =
        Httpun_ws.Payload.schedule_read
          payload
          ~on_eof:finish
          ~on_read:(fun chunk ~off ~len ->
            if t.terminal = None
            then (
              if len > maximum - Buffer.length buffer
              then protocol_error "WebSocket frame exceeds its bound";
              Buffer.add_string buffer (Bigstringaf.substring chunk ~off ~len);
              read ()))
      in
      read ())
  in
  let eof ?error () =
    stop
      t
      (match error with
       | Some _ -> Some "WebSocket protocol failed"
       | None when t.peer_closed && t.close_sent -> None
       | None -> Some "WebSocket peer EOF")
  in
  { Httpun_ws.Websocket_connection.frame; eof }
;;

let read_loop t flow protocol =
  let module Client = Httpun_ws.Client_connection in
  let capacity = 16384 in
  let buffer = Bigstringaf.create capacity in
  let rec loop retained parse =
    if t.terminal = None
    then (
      let before = t.read_progress in
      match Client.next_read_operation protocol with
      | `Close -> stop t (Some "WebSocket reader closed")
      | `Yield ->
        let resumed, resume = Eio.Promise.create () in
        Client.yield_reader protocol (fun () ->
          ignore (Eio.Promise.try_resolve resume () : bool));
        Eio.Promise.await resumed;
        loop retained true
      | `Read ->
        if parse || t.read_progress <> before
        then (
          let consumed = Client.read protocol buffer ~off:0 ~len:retained in
          if consumed < 0 || consumed > retained
          then protocol_error "invalid WebSocket parser progress";
          let remaining = retained - consumed in
          if remaining > 0 && consumed > 0
          then Bigstringaf.blit buffer ~src_off:consumed buffer ~dst_off:0 ~len:remaining;
          loop remaining (consumed > 0 || t.read_progress <> before))
        else (
          if retained = capacity
          then protocol_error "WebSocket retained input exceeds its bound";
          match
            Eio.Flow.single_read
              flow
              (Cstruct.of_bigarray buffer ~off:retained ~len:(capacity - retained))
          with
          | count -> loop (retained + count) true
          | exception End_of_file ->
            ignore (Client.read_eof protocol buffer ~off:0 ~len:retained : int);
            stop
              t
              (if t.peer_closed && t.close_sent then None else Some "WebSocket peer EOF")))
  in
  loop 0 false
;;

let serialize descriptor frame =
  let application_data =
    let len = String.length frame.payload in
    Faraday.{ buffer = Bigstringaf.of_string ~off:0 ~len frame.payload; off = 0; len }
  in
  match frame.opcode with
  | 1 ->
    Httpun_ws.Wsd.send_bytes
      descriptor
      ~kind:`Text
      (Bytes.of_string frame.payload)
      ~off:0
      ~len:(String.length frame.payload)
  | 9 -> Httpun_ws.Wsd.send_ping ~application_data descriptor
  | 10 -> Httpun_ws.Wsd.send_pong ~application_data descriptor
  | 8 -> Httpun_ws.Wsd.close ~code:`Normal_closure descriptor
  | _ -> assert false
;;

let write_loop t flow protocol =
  let module Client = Httpun_ws.Client_connection in
  let in_flight = ref None in
  let drained () =
    Option.iter
      (fun frame ->
         if frame.application
         then (
           t.pending_bytes <- t.pending_bytes - String.length frame.payload - 14;
           t.pending_count <- t.pending_count - 1);
         if frame.opcode = 8
         then (
           t.close_sent <- true;
           if t.peer_closed then stop t None))
      !in_flight;
    in_flight := None
  in
  let next_frame () =
    if
      (not (Queue.is_empty t.control))
      && ((Queue.peek t.control).opcode <> 8 || t.peer_closed || Queue.is_empty t.output)
    then Some (Queue.take t.control)
    else if not (Queue.is_empty t.output)
    then Some (Queue.take t.output)
    else None
  in
  let rec loop () =
    if t.terminal = None
    then (
      match Client.next_write_operation protocol with
      | `Write iovecs ->
        let buffers =
          List.map
            (fun { Faraday.buffer; off; len } -> Cstruct.of_bigarray buffer ~off ~len)
            iovecs
        in
        let count = Eio.Flow.single_write flow buffers in
        if count <= 0 then protocol_error "WebSocket writer made no progress";
        Client.report_write_result protocol (`Ok count);
        loop ()
      | `Yield ->
        drained ();
        (match t.descriptor with
         | Some descriptor ->
           (match next_frame () with
            | Some frame ->
              in_flight := Some frame;
              serialize descriptor frame;
              loop ()
            | None -> wait ())
         | None -> wait ())
      | `Close _ ->
        drained ();
        if not t.closing then stop t (Some "WebSocket writer closed"))
  and wait () =
    let resumed, resume = Eio.Promise.create () in
    let wake () = ignore (Eio.Promise.try_resolve resume () : bool) in
    t.wake_writer <- wake;
    Client.yield_writer protocol wake;
    Eio.Promise.await resumed;
    loop ()
  in
  loop ()
;;

let deliver_loop t activation on_message =
  Eio.Promise.await activation;
  while t.terminal = None do
    if Queue.is_empty t.input
    then Eio.Condition.await_no_mutex t.input_changed
    else (
      let message = Queue.take t.input in
      (* Retain its budget while the callback is in flight. *)
      on_message message;
      t.input_count <- t.input_count - 1;
      t.input_bytes <- t.input_bytes - String.length message)
  done
;;

let heartbeat t clock = function
  | Disabled -> ()
  | Ping_pong { interval_seconds; timeout_seconds } ->
    let sequence = ref 0L in
    while (not t.closing) && t.terminal = None do
      Eio.Time.sleep clock interval_seconds;
      if (not t.closing) && t.terminal = None
      then (
        sequence := Int64.succ !sequence;
        let value = Bytes.create 8 in
        Bytes.set_int64_be value 0 !sequence;
        let value = Bytes.to_string value in
        let pong, resolve = Eio.Promise.create () in
        t.pong <- Some (value, resolve);
        enqueue_control t 9 value;
        (try
           Eio.Time.with_timeout_exn clock timeout_seconds (fun () ->
             Eio.Promise.await pong)
         with
         | Eio.Time.Timeout ->
           if not t.closing then stop t (Some "WebSocket Pong deadline expired"));
        t.pong <- None)
    done
;;

let failure_message = function
  | Protocol_error message -> message
  | End_of_file -> "WebSocket peer EOF"
  | Eio.Time.Timeout -> "WebSocket establishment timed out"
  | Tls_eio.Tls_alert _ | Tls_eio.Tls_failure _ -> "WebSocket TLS termination"
  | _ -> "WebSocket transport failed"
;;

let connect
      ~sw
      ~authenticator
      ~network
      ~clock
      ~liveness
      ~uri
      ~token
      ~maximum_frame_bytes
      ~on_message
      ~on_close
  =
  Tls_client_eio.initialize_rng ();
  let valid_uri =
    match Uri.scheme uri, Uri.host uri, Uri.userinfo uri, Uri.fragment uri with
    | Some "wss", Some host, None, None -> host <> ""
    | _ -> false
  in
  if (not valid_uri) || maximum_frame_bytes <= 0
  then Error (Connection_failed "invalid WebSocket connection parameters")
  else (
    let ready, resolve_ready = Eio.Promise.create () in
    let stopped, resolve_stopped = Eio.Promise.create () in
    let close_requested, resolve_close = Eio.Promise.create () in
    let activation, resolve_activation = Eio.Promise.create () in
    let finished, resolve_finished = Eio.Promise.create () in
    let t =
      { terminal = None
      ; activated = false
      ; closing = false
      ; peer_closed = false
      ; close_sent = false
      ; close_queued = false
      ; pending_bytes = 0
      ; pending_count = 0
      ; read_progress = 0
      ; input_count = 0
      ; input_bytes = 0
      ; pong = None
      ; output = Queue.create ()
      ; control = Queue.create ()
      ; input = Queue.create ()
      ; wake_writer = (fun () -> ())
      ; descriptor = None
      ; input_changed = Eio.Condition.create ()
      ; stopped = resolve_stopped
      ; close_requested = resolve_close
      ; activation = resolve_activation
      }
    in
    Eio.Fiber.fork ~sw (fun () ->
      (try
         Eio.Switch.run (fun owner ->
           let guarded f () =
             try f () with
             | Eio.Cancel.Cancelled _ as cancelled -> raise cancelled
             | exception_ -> stop t (Some (failure_message exception_))
           in
           let setup () =
             let host = Option.get (Uri.host uri) in
             match
               Tls_client_eio.connect
                 ~sw:owner
                 ~authenticator
                 ~network
                 ~clock
                 ~host
                 ~port:(Option.value (Uri.port uri) ~default:443)
             with
             | Error _ -> Error (Connection_failed "WebSocket TLS setup failed")
             | Ok flow ->
               let opened, resolve_opened = Eio.Promise.create () in
               let websocket_handler descriptor =
                 t.descriptor <- Some descriptor;
                 t.wake_writer ();
                 ignore (Eio.Promise.try_resolve resolve_opened (Ok ()) : bool);
                 input_handlers t maximum_frame_bytes
               in
               let error_handler error =
                 let failure =
                   match error with
                   | `Handshake_failure (response, _) ->
                     (match Httpun.Status.to_code response.Httpun.Response.status with
                      | 401 -> Unauthorized
                      | 403 -> Forbidden
                      | _ -> Connection_failed "WebSocket Upgrade rejected")
                   | `Malformed_response _ | `Invalid_response_body_length _ | `Exn _ ->
                     Connection_failed "WebSocket protocol failed"
                 in
                 ignore (Eio.Promise.try_resolve resolve_opened (Error failure) : bool);
                 (* Preserve typed authentication failure before the stop signal
                    races the establishment waiter. The caller still awaits retirement. *)
                 ignore (Eio.Promise.try_resolve resolve_ready (Error failure) : bool);
                 stop t (Some "WebSocket protocol failed")
               in
               let port = Option.value (Uri.port uri) ~default:443 in
               let host_header =
                 if port = 443 then host else Printf.sprintf "%s:%d" host port
               in
               let headers =
                 Httpun.Headers.of_list
                   [ "host", host_header; "authorization", "Bearer " ^ token ]
               in
               let target = Uri.path_and_query uri in
               let protocol =
                 Httpun_ws.Client_connection.connect
                   ~nonce:(Mirage_crypto_rng.generate 16)
                   ~headers
                   ~sha1:(fun value ->
                     Digestif.SHA1.digest_string value |> Digestif.SHA1.to_raw_string)
                   ~error_handler
                   ~websocket_handler
                   (if target = "" then "/" else target)
               in
               Eio.Fiber.fork ~sw:owner (guarded (fun () -> write_loop t flow protocol));
               Eio.Fiber.fork ~sw:owner (guarded (fun () -> read_loop t flow protocol));
               Eio.Promise.await opened
           in
           Eio.Fiber.fork
             ~sw:owner
             (guarded (fun () -> deliver_loop t activation on_message));
           Eio.Fiber.fork
             ~sw:owner
             (guarded (fun () ->
                Eio.Promise.await activation;
                Fun.protect
                  ~finally:(fun () -> t.pong <- None)
                  (fun () ->
                     Eio.Fiber.first
                       (fun () -> heartbeat t clock liveness)
                       (fun () -> Eio.Promise.await close_requested))));
           Eio.Fiber.fork
             ~sw:owner
             (guarded (fun () ->
                Eio.Promise.await close_requested;
                Eio.Time.sleep clock close_timeout;
                stop t (Some "WebSocket close deadline expired")));
           (* Setup and both pumps share this owner from before DNS through final
              retirement, including a failure before a handle can be returned. *)
           let setup_result =
             Eio.Fiber.first
               (fun () -> Eio.Time.with_timeout_exn clock 30. setup)
               (fun () ->
                  Eio.Promise.await stopped;
                  raise Stop_owner)
           in
           (match setup_result with
            | Error failure ->
              ignore (Eio.Promise.try_resolve resolve_ready (Error failure) : bool);
              stop t (Some "WebSocket establishment rejected")
            | Ok () -> ignore (Eio.Promise.try_resolve resolve_ready (Ok t) : bool));
           Eio.Promise.await stopped;
           raise Stop_owner)
       with
       | Stop_owner -> ()
       | Eio.Cancel.Cancelled _ -> stop t (Some "WebSocket cancelled")
       | exception_ -> stop t (Some (failure_message exception_)));
      Queue.clear t.input;
      Queue.clear t.output;
      Queue.clear t.control;
      t.pending_bytes <- 0;
      t.pending_count <- 0;
      t.input_count <- 0;
      t.input_bytes <- 0;
      let reason = Option.value t.terminal ~default:(Some "WebSocket owner stopped") in
      ignore
        (Eio.Promise.try_resolve
           resolve_ready
           (Error
              (Connection_failed
                 (Option.value reason ~default:"WebSocket closed before activation")))
         : bool);
      ignore (Eio.Promise.try_resolve resolve_finished () : bool);
      Eio.traceln "sync WebSocket owner retired activated=%b" t.activated;
      if t.activated
      then (
        try
          Eio.Promise.await activation;
          on_close reason
        with
        | _ -> ()));
    try
      match Eio.Promise.await ready with
      | Ok _ as result when t.terminal = None && not t.closing -> result
      | Ok _ ->
        Eio.Promise.await finished;
        Error (Connection_failed "WebSocket closed before activation")
      | Error _ as error ->
        Eio.Promise.await finished;
        error
    with
    | Eio.Cancel.Cancelled _ as cancelled ->
      abort t;
      Eio.Cancel.protect (fun () -> Eio.Promise.await finished);
      raise cancelled)
;;
