type t =
  { descriptor : Httpun_ws.Wsd.t
  ; protocol : Httpun_ws.Client_connection.t
  ; mutable closed : bool
  }

let bind result f =
  match result with
  | Ok value -> f value
  | Error _ as error -> error
;;

let initialize_rng =
  let initialized = Atomic.make false in
  fun () ->
    if Atomic.compare_and_set initialized false true
    then Mirage_crypto_rng_unix.use_default ()
;;

let host_name host =
  bind (Domain_name.of_string host) (fun domain ->
    match Domain_name.host domain with
    | Ok host -> Ok host
    | Error _ -> Error (`Msg "WSS host is not a valid DNS name"))
;;

let tls_config authenticator host =
  bind (host_name host) (fun peer_name ->
    Tls.Config.client ~authenticator ~peer_name ~alpn_protocols:[ "http/1.1" ] ())
;;

let open_flow ~sw ~authenticator ~network uri =
  match Uri.scheme uri, Uri.host uri, Uri.userinfo uri, Uri.fragment uri with
  | Some "wss", Some host, None, None ->
    (match tls_config authenticator host with
     | Error (`Msg message) -> Error message
     | Ok config ->
       let port = Option.value (Uri.port uri) ~default:443 in
       (match Eio.Net.getaddrinfo_stream ~service:(string_of_int port) network host with
        | [] -> Error "WSS host has no network address"
        | address :: _ ->
          (try
             let socket = Eio.Net.connect ~sw network address in
             let peer_name = host_name host |> Result.get_ok in
             Ok (Tls_eio.client_of_flow config ~host:peer_name socket)
           with
           | Eio.Cancel.Cancelled _ as cancelled -> raise cancelled
           | exception_ -> Error (Printexc.to_string exception_))))
  | Some _, Some _, _, _ | Some _, None, _, _ | None, _, _, _ ->
    Error "WebSocket URL must be WSS without credentials or fragments"
;;

let start_connection ~sw flow connection =
  let rec read_loop buffer =
    match Httpun_ws.Client_connection.next_read_operation connection with
    | `Read ->
      (try
         let count = Eio.Flow.single_read flow (Cstruct.of_bigarray buffer) in
         let rec consume offset remaining =
           if remaining > 0
           then (
             let consumed =
               Httpun_ws.Client_connection.read
                 connection
                 buffer
                 ~off:offset
                 ~len:remaining
             in
             if consumed <= 0
             then failwith "WebSocket parser did not consume network input";
             consume (offset + consumed) (remaining - consumed))
         in
         consume 0 count;
         read_loop buffer
       with
       | End_of_file ->
         ignore
           (Httpun_ws.Client_connection.read_eof connection buffer ~off:0 ~len:0 : int))
    | `Yield ->
      let resumed, resume = Eio.Promise.create () in
      Httpun_ws.Client_connection.yield_reader connection (fun () ->
        Eio.Promise.resolve resume ());
      Eio.Promise.await resumed;
      read_loop buffer
    | `Close -> ()
  in
  let rec write_loop () =
    match Httpun_ws.Client_connection.next_write_operation connection with
    | `Write iovecs ->
      let cstructs, length =
        List.fold_left
          (fun (values, length) { Faraday.buffer; off; len } ->
             Cstruct.of_bigarray buffer ~off ~len :: values, length + len)
          ([], 0)
          iovecs
      in
      (try
         Eio.Flow.write flow (List.rev cstructs);
         Httpun_ws.Client_connection.report_write_result connection (`Ok length)
       with
       | End_of_file -> Httpun_ws.Client_connection.report_write_result connection `Closed);
      write_loop ()
    | `Yield ->
      let resumed, resume = Eio.Promise.create () in
      Httpun_ws.Client_connection.yield_writer connection (fun () ->
        Eio.Promise.resolve resume ());
      Eio.Promise.await resumed;
      write_loop ()
    | `Close _ ->
      (try Eio.Flow.shutdown flow `Send with
       | _ -> ())
  in
  Eio.Fiber.fork ~sw (fun () ->
    try read_loop (Bigstringaf.create 16_384) with
    | exception_ -> Httpun_ws.Client_connection.report_exn connection exception_);
  Eio.Fiber.fork ~sw (fun () ->
    try write_loop () with
    | exception_ -> Httpun_ws.Client_connection.report_exn connection exception_)
;;

let read_payload ~maximum payload =
  let buffer = Buffer.create (min maximum 4096) in
  let completed, complete = Eio.Promise.create () in
  let rec read () =
    Httpun_ws.Payload.schedule_read
      payload
      ~on_eof:(fun () ->
        ignore (Eio.Promise.try_resolve complete (Ok (Buffer.contents buffer)) : bool))
      ~on_read:(fun chunk ~off ~len ->
        if Buffer.length buffer + len > maximum
        then (
          Httpun_ws.Payload.close payload;
          ignore
            (Eio.Promise.try_resolve complete (Error "WebSocket frame exceeds its bound")
             : bool))
        else (
          Buffer.add_string buffer (Bigstringaf.substring chunk ~off ~len);
          read ()))
  in
  read ();
  Eio.Promise.await completed
;;

let connect
      ~sw
      ~authenticator
      ~network
      ~clock
      ~uri
      ~token
      ~maximum_frame_bytes
      ~on_message
      ~on_close
  =
  initialize_rng ();
  if maximum_frame_bytes <= 0
  then Error "WebSocket frame bound must be positive"
  else
    bind (open_flow ~sw ~authenticator ~network uri) (fun flow ->
      let opened, resolve_opened = Eio.Promise.create () in
      let fragments = Buffer.create 4096 in
      let close_once =
        let closed = ref false in
        fun error ->
          if not !closed
          then (
            closed := true;
            on_close error)
      in
      let websocket_handler descriptor =
        ignore (Eio.Promise.try_resolve resolve_opened descriptor : bool);
        let frame ~opcode ~is_fin ~len:_ payload =
          Eio.Fiber.fork ~sw (fun () ->
            match read_payload ~maximum:maximum_frame_bytes payload with
            | Error message ->
              Httpun_ws.Wsd.close ~code:`Message_too_big descriptor;
              close_once (Some message)
            | Ok value ->
              (match opcode with
               | `Ping ->
                 let bytes =
                   Bigstringaf.of_string ~off:0 ~len:(String.length value) value
                 in
                 Httpun_ws.Wsd.send_pong
                   ~application_data:
                     Faraday.{ buffer = bytes; off = 0; len = String.length value }
                   descriptor
               | `Pong -> ()
               | `Connection_close ->
                 Httpun_ws.Wsd.close descriptor;
                 close_once None
               | `Text | `Binary ->
                 Buffer.clear fragments;
                 Buffer.add_string fragments value;
                 if is_fin
                 then (
                   on_message (Buffer.contents fragments);
                   Buffer.clear fragments)
               | `Continuation ->
                 if Buffer.length fragments + String.length value > maximum_frame_bytes
                 then (
                   Httpun_ws.Wsd.close ~code:`Message_too_big descriptor;
                   close_once (Some "WebSocket message exceeds its bound"))
                 else (
                   Buffer.add_string fragments value;
                   if is_fin
                   then (
                     on_message (Buffer.contents fragments);
                     Buffer.clear fragments))
               | `Other _ ->
                 Httpun_ws.Wsd.close ~code:`Protocol_error descriptor;
                 close_once (Some "unsupported WebSocket opcode")))
        in
        let eof ?error () =
          close_once
            (Option.map (fun (`Exn exception_) -> Printexc.to_string exception_) error)
        in
        { Httpun_ws.Websocket_connection.frame; eof }
      in
      let error_handler _ = close_once (Some "WebSocket handshake failed") in
      let host = Option.get (Uri.host uri) in
      let host_header =
        match Uri.port uri with
        | None | Some 443 -> host
        | Some port -> Printf.sprintf "%s:%d" host port
      in
      let headers =
        Httpun.Headers.of_list [ "host", host_header; "authorization", "Bearer " ^ token ]
      in
      let nonce = Mirage_crypto_rng.generate 16 in
      let sha1 source =
        Digestif.SHA1.digest_string source |> Digestif.SHA1.to_raw_string
      in
      let protocol =
        Httpun_ws.Client_connection.connect
          ~nonce
          ~headers
          ~sha1
          ~error_handler
          ~websocket_handler
          (let target = Uri.path_and_query uri in
           if String.length target = 0 then "/" else target)
      in
      start_connection ~sw flow protocol;
      try
        let descriptor =
          Eio.Time.with_timeout_exn clock 30. (fun () -> Eio.Promise.await opened)
        in
        Ok { descriptor; protocol; closed = false }
      with
      | Eio.Cancel.Cancelled _ as cancelled -> raise cancelled
      | Eio.Time.Timeout ->
        Httpun_ws.Client_connection.shutdown protocol;
        Error "WebSocket handshake timed out"
      | exception_ ->
        Httpun_ws.Client_connection.shutdown protocol;
        Error (Printexc.to_string exception_))
;;

let send t payload =
  if t.closed || Httpun_ws.Wsd.is_closed t.descriptor
  then Error "WebSocket is closed"
  else if String.length payload > Limits.maximum_request_bytes
  then Error "WebSocket outgoing frame exceeds its bound"
  else (
    try
      let bytes = Bytes.of_string payload in
      Httpun_ws.Wsd.send_bytes
        t.descriptor
        ~kind:`Text
        bytes
        ~off:0
        ~len:(Bytes.length bytes);
      Ok ()
    with
    | exception_ -> Error (Printexc.to_string exception_))
;;

let close t =
  if not t.closed
  then (
    t.closed <- true;
    Httpun_ws.Wsd.close t.descriptor;
    Httpun_ws.Client_connection.shutdown t.protocol)
;;
