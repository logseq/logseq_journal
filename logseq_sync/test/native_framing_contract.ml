module Native = Logseq_sync_native_transport
module Ws = Native.Websocket_eio
module Http = Native.Http
module Peer = Tls_peer

let with_peer = Peer.with_peer
let wait = Peer.wait
let read_file = Peer.read_file
let case = Peer.case

let authenticator ~support =
  let certificate =
    X509.Certificate.decode_pem (read_file (Filename.concat support "cert.pem"))
    |> Result.get_ok
  in
  X509.Authenticator.chain_of_trust
    ~time:(fun () -> Ptime.of_float_s (Unix.gettimeofday ()))
    [ certificate ]
;;

let response ?(status = 200) ?(headers = "Content-Length: 1\r\n") body =
  Printf.sprintf
    "HTTP/1.1 %d Test\r\n\
     Content-Type: application/transit+json\r\n\
     X-Snapshot-Row-Count: 1\r\n\
     %s\r\n\
     %s"
    status
    headers
    body
;;

let check_retired report =
  let rows = Yojson.Basic.Util.to_list report in
  List.iter
    (fun row ->
       Alcotest.(check bool)
         "peer observed local resource retirement"
         true
         Yojson.Basic.Util.(row |> member "closed" |> to_bool))
    rows
;;

let captured_request_headers row =
  let encoded = Yojson.Basic.Util.(row |> member "request" |> to_string) in
  let request =
    String.init
      (String.length encoded / 2)
      (fun n -> Char.chr (int_of_string ("0x" ^ String.sub encoded (2 * n) 2)))
  in
  let rec headers = function
    | [] | "" :: _ -> []
    | line :: rest -> line :: headers rest
  in
  String.split_on_char '\n' request
  |> List.tl
  |> List.map (fun line -> String.lowercase_ascii (String.trim line))
  |> headers
;;

let check_default_connection report =
  Yojson.Basic.Util.to_list report
  |> List.iter (fun row ->
    Alcotest.(check bool)
      "ordinary request omits Connection"
      false
      (List.exists
         (String.starts_with ~prefix:"connection:")
         (captured_request_headers row)))
;;

let http_test ~download ~success ?(segment = 16384) ?(eof = false) wire () =
  let report =
    with_peer
      [ case ~segment ~eof wire ]
      (fun ~environment ~sw ~support ~origin ->
         let request : Http.request =
           { operation = Get
           ; uri = origin
           ; headers = []
           ; maximum_response_bytes = 1024
           ; expected_content_type = Snapshot_artifact
           }
         in
         let authenticator = authenticator ~support in
         let network = Eio.Stdenv.net environment in
         let clock =
           Native.Transport_time.monotonic (Eio.Stdenv.mono_clock environment)
         in
         let result =
           if download
           then
             Native.Http_eio.download
               ~sw
               ~authenticator
               ~network
               ~clock
               ~request
               ~destination:(Filename.concat support "artifact")
               ~maximum_bytes:1024
               ~on_progress:(fun _ -> ())
           else Native.Http_eio.perform ~sw ~authenticator ~network ~clock request
         in
         Alcotest.(check bool) "response outcome" success (Result.is_ok result);
         if success
         then (
           let response = Result.get_ok result in
           Alcotest.(check int) "response status" 200 response.status;
           Alcotest.(check string)
             "exact payload"
             "x"
             (if download
              then read_file (Filename.concat support "artifact")
              else response.body)))
  in
  check_retired report;
  check_default_connection report
;;

let frame ?(fin = true) opcode payload =
  let size = String.length payload in
  let prefix =
    if size < 126
    then String.make 1 (Char.chr size)
    else if size <= 65535
    then
      String.init 3 (function
        | 0 -> Char.chr 126
        | 1 -> Char.chr (size lsr 8)
        | _ -> Char.chr (size land 255))
    else
      String.init 9 (function
        | 0 -> Char.chr 127
        | i ->
          Char.chr
            (Int64.to_int
               (Int64.logand
                  255L
                  (Int64.shift_right_logical (Int64.of_int size) ((8 - i) * 8)))))
  in
  String.make 1 (Char.chr (opcode lor if fin then 128 else 0)) ^ prefix ^ payload
;;

let ws_test
      ?(extra = "")
      ?(segment = 16384)
      ?(maximum_frame_bytes = 1024)
      ?expected_messages
      ?expected_pong
      ?expected_failure
      ~messages
      ~terminal
      wire
      ()
  =
  let report =
    with_peer
      [ case ~ws:true ~extra ~segment wire ]
      (fun ~environment ~sw ~support ~origin ->
         let received = ref []
         and closed = ref []
         and opened = ref false in
         let uri = Uri.with_scheme origin (Some "wss") in
         let result =
           Ws.connect
             ~setup_seconds:5.
             ~tls_handshake_seconds:5.
             ~http_response_seconds:5.
             ~sw
             ~authenticator:(authenticator ~support)
             ~network:(Eio.Stdenv.net environment)
             ~clock:(Native.Transport_time.monotonic (Eio.Stdenv.mono_clock environment))
             ~liveness:Ws.Disabled
             ~uri
             ~token:"synthetic"
             ~maximum_frame_bytes
             ~on_message:(fun message ->
               Alcotest.(check bool) "open precedes data" true !opened;
               received := !received @ [ message ])
             ~on_close:(fun reason -> closed := reason :: !closed)
         in
         match result with
         | Error _ when terminal ->
           Alcotest.(check int) "no application data" 0 (List.length !received)
         | Error _ -> Alcotest.fail "WebSocket connection failed"
         | Ok socket ->
           (match Ws.activate socket ~on_open:(fun () -> opened := true) with
            | Error _ when terminal -> ()
            | Error _ -> Alcotest.fail "WebSocket activation failed"
            | Ok () ->
              wait (Eio.Stdenv.clock environment) (fun () ->
                if terminal then !closed <> [] else List.length !received >= messages);
              Alcotest.(check int)
                "ordered application message count"
                messages
                (List.length !received);
              Option.iter
                (fun expected ->
                   Alcotest.(check (list string))
                     "exact application messages"
                     expected
                     !received)
                expected_messages;
              if not terminal then Ws.close socket);
           Ws.await_retired socket;
           Option.iter (fun expected ->
             match !closed with
             | [Native.Transport_domain.Protocol_failure actual] ->
               Alcotest.(check string) "terminal budget diagnostic" expected actual
             | _ -> Alcotest.fail "expected a protocol failure") expected_failure;
           Alcotest.(check int) "one terminal notification" 1 (List.length !closed))
  in
  check_retired report;
  if not terminal
  then (
    let frames =
      Yojson.Basic.Util.(report |> to_list |> List.hd |> member "frames" |> to_list)
    in
    Alcotest.(check bool)
      "peer received masked Close"
      true
      (List.exists
         (fun frame ->
            Yojson.Basic.Util.(frame |> member "opcode" |> to_int) = 8
            && String.length Yojson.Basic.Util.(frame |> member "mask" |> to_string) = 8)
         frames);
    Option.iter
      (fun payload ->
         Alcotest.(check bool)
           "peer received masked Pong with exact ping payload"
           true
           (List.exists
              (fun frame ->
                 Yojson.Basic.Util.(frame |> member "opcode" |> to_int) = 10
                 && String.length Yojson.Basic.Util.(frame |> member "mask" |> to_string)
                    = 8
                 && Yojson.Basic.Util.(frame |> member "payload" |> to_string)
                    = Peer.hex payload)
              frames))
      expected_pong)
;;

let http_cases =
  [ "complete length", true, false, response "x"
  ; "truncated length", false, true, response ~headers:"Content-Length: 2\r\n" "x"
  ; "close delimited", true, true, response ~headers:"" "x"
  ; ( "plain chunked"
    , true
    , false
    , response ~headers:"Transfer-Encoding: chunked\r\n" "1\r\nx\r\n0\r\n\r\n" )
  ; ( "truncated chunk"
    , false
    , true
    , response ~headers:"Transfer-Encoding: chunked\r\n" "2\r\nx" )
  ; ( "malformed chunk after payload preserves failure"
    , false
    , false
    , response ~headers:"Transfer-Encoding: chunked\r\n" "1\r\nx\r\nZ\r\n" )
  ; ( "bad content type"
    , false
    , false
    , "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 1\r\n\r\nx" )
  ]
;;

let ws_cases =
  let message = {|{"type":"changed","t":42}|} in
  [ ( "coalesced fragmented message"
    , 1
    , false
    , frame ~fin:false 1 (String.sub message 0 3)
      ^ frame 0 (String.sub message 3 (String.length message - 3)) )
  ; "ordered multiple messages", 2, false, frame 1 message ^ frame 1 message
  ; ( "interleaved ping"
    , 1
    , false
    , frame ~fin:false 1 (String.sub message 0 3)
      ^ frame 9 "probe"
      ^ frame 0 (String.sub message 3 (String.length message - 3)) )
  ; "peer close", 0, true, frame 8 "\x03\xe8"
  ]
;;

let scenarios =
  List.concat_map
    (fun download ->
       List.map
         (fun (name, success, eof, wire) ->
            Alcotest.test_case
              ((if download then "download " else "HTTP ") ^ name)
              `Quick
              (http_test ~download ~success ~eof wire))
         http_cases)
    [ false; true ]
  @ List.map
      (fun (name, messages, terminal, wire) ->
         Alcotest.test_case
           ("WebSocket " ^ name)
           `Quick
           (ws_test ~messages ~terminal wire))
      ws_cases
  @ (let maximum = 4 * 1024 * 1024 in
     let prefix = {|{"type":"pull/ok","t":1,"txs":[{"t":1,"tx":"|} in
     let suffix = {|"}]}|} in
     let payload = prefix ^ String.make (maximum - String.length prefix - String.length suffix) 'x' ^ suffix in
     let fragmented tail =
       let split = maximum / 2 in
       frame ~fin:false 1 (String.sub payload 0 split)
       ^ frame 0 (String.sub payload split (maximum - split) ^ tail)
     in
     [ Alcotest.test_case
         "WebSocket drains exact-limit frames and fragments"
         `Quick
         (ws_test ~maximum_frame_bytes:maximum ~messages:3 ~terminal:false
            (frame 1 payload ^ fragmented "" ^ frame 1 payload))
     ; Alcotest.test_case
         "WebSocket rejects over-limit fragmented message"
         `Quick
         (ws_test ~maximum_frame_bytes:maximum
            ~expected_failure:"WebSocket message payload is at least 4194305 bytes (limit: 4194304 bytes)"
            ~messages:0 ~terminal:true (fragmented " "))
     ; Alcotest.test_case
         "WebSocket rejects over-limit single frame"
         `Quick
         (ws_test ~maximum_frame_bytes:maximum
            ~expected_failure:"WebSocket frame payload is 4194305 bytes (limit: 4194304 bytes)"
            ~messages:0 ~terminal:true (frame 1 (payload ^ " ")))
     ; Alcotest.test_case
         "WebSocket rejects unsigned length without waiting for payload"
         `Quick
         (ws_test ~maximum_frame_bytes:maximum ~segment:1
            ~expected_failure:"WebSocket frame payload is 18446744073709551615 bytes (limit: 4194304 bytes)"
            ~messages:0 ~terminal:true ("\x81\x7f" ^ String.make 8 '\xff'))
     ])
  @ [ Alcotest.test_case
        "HTTP segmented supported chunked response"
        `Quick
        (http_test
           ~download:false
           ~success:true
           ~segment:1
           (response ~headers:"Transfer-Encoding: chunked\r\n" "1\r\nx\r\n0\r\n\r\n"))
    ; Alcotest.test_case
        "WebSocket segmented Upgrade and frame"
        `Quick
        (ws_test
           ~messages:1
           ~terminal:false
           ~segment:1
           (frame 1 {|{"type":"changed","t":42}|}))
    ; Alcotest.test_case
        "WebSocket bounds retained incomplete Upgrade input"
        `Quick
        (ws_test
           ~messages:0
           ~terminal:true
           ~extra:("X-Incomplete: " ^ String.make 20000 'x')
           "")
    ]
  @ List.map
      (fun size ->
         let message = {|{"type":"changed","t":42}|} in
         let payload = String.make (size - String.length message) ' ' ^ message in
         Alcotest.test_case
           (Printf.sprintf "WebSocket minimal length boundary %d" size)
           `Quick
           (ws_test
              ~maximum_frame_bytes:65536
              ~expected_messages:[ payload ]
              ~messages:1
              ~terminal:false
              (frame 1 payload)))
      [ 125; 126; 65535; 65536 ]
  @ [ Alcotest.test_case
        "WebSocket UTF8 codepoint split across fragments"
        `Quick
        (ws_test
           ~expected_messages:[ "{\"type\":\"error\",\"message\":\"\xe4\xb8\xad\"}" ]
           ~expected_pong:"probe"
           ~messages:1
           ~terminal:false
           (frame ~fin:false 1 "{\"type\":\"error\",\"message\":\"\xe4"
            ^ frame 9 "probe"
            ^ frame 0 "\xb8\xad\"}"))
    ]
;;

let () = Alcotest.run "native framing regressions" [ "transport", scenarios ]
