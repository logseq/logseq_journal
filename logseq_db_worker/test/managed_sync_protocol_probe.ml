module Protocol = Logseq_sync_pure_reducer.Sync_protocol

type t =
  { descriptor : Httpun_ws.Wsd.t
  ; protocol : Httpun_ws.Client_connection.t
  ; messages : Protocol.Server.message Eio.Stream.t
  ; mutable closed : bool
  }

let bind result next =
  match result with
  | Ok value -> next value
  | Error _ as error -> error
;;

let host_name host =
  match Domain_name.of_string host with
  | Error _ -> Error "WSS host is not a valid DNS name"
  | Ok domain ->
    (match Domain_name.host domain with
     | Error _ -> Error "WSS host is not a valid DNS name"
     | Ok host -> Ok host)
;;

let open_flow ~sw ~authenticator ~network uri =
  match Uri.scheme uri, Uri.host uri, Uri.userinfo uri, Uri.fragment uri with
  | Some "wss", Some host, None, None ->
    bind (host_name host) (fun peer_name ->
      match
        Tls.Config.client ~authenticator ~peer_name ~alpn_protocols:[ "http/1.1" ] ()
      with
      | Error (`Msg message) -> Error message
      | Ok config ->
        (match
           Eio.Net.getaddrinfo_stream
             ~service:(string_of_int (Option.value (Uri.port uri) ~default:443))
             network
             host
         with
         | [] -> Error "WSS host has no network address"
         | address :: _ ->
           (try
              let socket = Eio.Net.connect ~sw network address in
              Ok (Tls_eio.client_of_flow config ~host:peer_name socket)
            with
            | Eio.Cancel.Cancelled _ as canceled -> raise canceled
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
  let buffer = Buffer.create (min maximum 4_096) in
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

let connect ~sw ~network ~clock ~base_url ~graph_id ~token =
  bind
    (Ca_certs_nss.authenticator () |> Result.map_error (fun (`Msg message) -> message))
    (fun authenticator ->
       let uri =
         Uri.of_string base_url
         |> fun uri ->
         Uri.with_scheme uri (Some "wss")
         |> fun uri ->
         Uri.with_path uri ("/sync/" ^ Logseq_db_types.Graph_types.Uuid.to_string graph_id)
       in
       bind (open_flow ~sw ~authenticator ~network uri) (fun flow ->
         let opened, resolve_opened = Eio.Promise.create () in
         let messages = Eio.Stream.create 256 in
         let fragments = Buffer.create 4_096 in
         let websocket_handler descriptor =
           ignore (Eio.Promise.try_resolve resolve_opened descriptor : bool);
           let frame ~opcode ~is_fin ~len:_ payload =
             Eio.Fiber.fork ~sw (fun () ->
               match read_payload ~maximum:(4 * 1_024 * 1_024) payload with
               | Error _ -> Httpun_ws.Wsd.close ~code:`Message_too_big descriptor
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
                  | `Connection_close -> Httpun_ws.Wsd.close descriptor
                  | `Text | `Binary ->
                    Buffer.clear fragments;
                    Buffer.add_string fragments value;
                    if is_fin
                    then (
                      match
                        Protocol.decode_server_message (Buffer.contents fragments)
                      with
                      | Ok message -> Eio.Stream.add messages message
                      | Error _ -> Httpun_ws.Wsd.close ~code:`Protocol_error descriptor)
                  | `Continuation ->
                    Buffer.add_string fragments value;
                    if is_fin
                    then (
                      match
                        Protocol.decode_server_message (Buffer.contents fragments)
                      with
                      | Ok message -> Eio.Stream.add messages message
                      | Error _ -> Httpun_ws.Wsd.close ~code:`Protocol_error descriptor)
                  | `Other _ -> Httpun_ws.Wsd.close ~code:`Protocol_error descriptor))
           in
           let eof ?error:_ () = () in
           { Httpun_ws.Websocket_connection.frame; eof }
         in
         let error_handler _ = () in
         let host = Option.get (Uri.host uri) in
         let host_header =
           match Uri.port uri with
           | None | Some 443 -> host
           | Some port -> Printf.sprintf "%s:%d" host port
         in
         let headers =
           Httpun.Headers.of_list
             [ "host", host_header; "authorization", "Bearer " ^ token ]
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
           Ok { descriptor; protocol; messages; closed = false }
         with
         | Eio.Time.Timeout ->
           Httpun_ws.Client_connection.shutdown protocol;
           Error "WebSocket handshake timed out"))
;;

let send connection message =
  if connection.closed
  then Error "WebSocket is closed"
  else (
    match Protocol.encode_client_message message with
    | Error error -> Error (Protocol.error_to_string error)
    | Ok payload ->
      (try
         let bytes = Bytes.of_string payload in
         Httpun_ws.Wsd.send_bytes
           connection.descriptor
           ~kind:`Text
           bytes
           ~off:0
           ~len:(Bytes.length bytes);
         Ok ()
       with
       | exception_ -> Error (Printexc.to_string exception_)))
;;

let await ~clock ~timeout_seconds select connection =
  try
    Eio.Time.with_timeout_exn clock timeout_seconds (fun () ->
      let rec loop () =
        match select (Eio.Stream.take connection.messages) with
        | Some value -> value
        | None -> loop ()
      in
      Ok (loop ()))
  with
  | Eio.Time.Timeout -> Error "timed out waiting for deployed sync protocol response"
;;

let close connection =
  if not connection.closed
  then (
    connection.closed <- true;
    Httpun_ws.Wsd.close connection.descriptor;
    Httpun_ws.Client_connection.shutdown connection.protocol)
;;
