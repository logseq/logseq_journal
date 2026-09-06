module Core = Logseq_sync_pure_reducer.Core
module Runner = Logseq_sync_effect_runner.Effect_runner

let with_support = Runner_contract.with_support
let secrets = Runner_contract.secrets
let crypto = Runner_contract.crypto

(* The peer uses Python's independent TLS/framing implementation. Tests enter
   production transports only through the public Runner API. *)
let peer =
  {python|
import base64, hashlib, json, os, select, socket, ssl, subprocess, sys, time, threading
root = sys.argv[1]
with open(root+'/cases.json') as f: cases = json.load(f)
key, cert = root + '/key.pem', root + '/cert.pem'
subprocess.run(['openssl','req','-x509','-newkey','ec','-pkeyopt','ec_paramgen_curve:P-256',
                '-nodes','-keyout',key,'-out',cert,'-days','1','-subj','/CN=localhost'],
               check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(cert,key)
listener = socket.socket(socket.AF_INET6)
listener.bind(('::1',0)); listener.listen(8); listener.settimeout(5)
listener4 = socket.socket()
listener4.bind(('127.0.0.1', listener.getsockname()[1])); listener4.listen(8)
with open(root+'/ready','w') as f: f.write(str(listener.getsockname()[1]))
report=[]; stalled=[]
def observe_stalled_tls(raw, item):
  try:
    while raw.recv(16384): pass
    item['closed']=True
  except (ConnectionResetError, BrokenPipeError): item['closed']=True
  except socket.timeout: pass
  finally: raw.close()
try:
  for case in cases:
    ready,_,_=select.select([listener,listener4],[],[],5)
    if not ready: raise RuntimeError('no client connection')
    raw,_ = ready[0].accept()
    raw.settimeout(2)
    if case.get('stall_tls'):
      item={'closed':False}; report.append(item)
      worker=threading.Thread(target=observe_stalled_tls,args=(raw,item),daemon=True)
      worker.start(); stalled.append(worker); continue
    conn=ctx.wrap_socket(raw,server_side=True)
    request=b''
    while b'\r\n\r\n' not in request:
      part=conn.recv(16384)
      if not part: raise RuntimeError('no request')
      request+=part
    wire=bytes.fromhex(case.get('wire',''))
    if case.get('ws'):
      headers=dict(line.split(b':',1) for line in request.split(b'\r\n')[1:] if b':' in line)
      nonce=next(v.strip() for k,v in headers.items() if k.lower()==b'sec-websocket-key')
      accept=base64.b64encode(hashlib.sha1(nonce+b'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest())
      wire=(b'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'
            b'Sec-WebSocket-Accept: '+accept+b'\r\n'+case.get('extra','').encode()+b'\r\n'+wire)
    step=case.get('segment',len(wire) or 1)
    for offset in range(0,len(wire),step):
      try: conn.sendall(wire[offset:offset+step])
      except (ssl.SSLError, OSError): break
      if step<32: time.sleep(.0005)
    with open(root+'/sent','w') as f: f.write('sent')
    if case.get('eof'):
      conn.close(); report.append({'request':request.hex(),'closed':True,'frames':[]}); continue
    closed=False; frames=[]; pending=b''
    deadline=time.monotonic()+1.5
    conn.settimeout(.1)
    while time.monotonic()<deadline:
      try:
        data=conn.recv(16384)
        if not data: closed=True; break
        pending+=data
        if not case.get('ws'): continue
        while len(pending)>=2:
          length=pending[1]&127; offset=2
          if length==126:
            if len(pending)<4: break
            length=int.from_bytes(pending[2:4],'big'); offset=4
          elif length==127:
            if len(pending)<10: break
            length=int.from_bytes(pending[2:10],'big'); offset=10
          masked=bool(pending[1]&128)
          if len(pending)<offset+4*masked+length: break
          mask=pending[offset:offset+4] if masked else b''
          payload=pending[offset+4*masked:offset+4*masked+length]
          if masked: payload=bytes(c^mask[i%4] for i,c in enumerate(payload))
          opcode=pending[0]&15
          frames.append({'opcode':opcode,'mask':mask.hex(),'payload':payload.hex()})
          with open(root+'/frame-count','w') as f: f.write(str(len(frames)))
          pending=pending[offset+4*masked+length:]
          if opcode==8 and case.get('reply_close',True):
            time.sleep(case.get('close_delay',0))
            conn.sendall(bytes([0x88,len(payload)])+payload)
          if opcode==9 and case.get('reply_ping',False):
            conn.sendall(bytes([0x8a,len(payload)])+payload)
      except socket.timeout: continue
      except (ssl.SSLError,OSError): closed=True; break
    conn.close()
    report.append({'request':request.hex(),'closed':closed,'frames':frames})
finally:
  listener.close(); listener4.close()
  for worker in stalled: worker.join(3)
  with open(root+'/report','w') as f: json.dump(report,f)
|python}
;;

let hex value =
  String.to_seq value
  |> Seq.map (fun c -> Printf.sprintf "%02x" (Char.code c))
  |> List.of_seq
  |> String.concat ""
;;

let case ?(ws = false) ?(extra = "") ?(segment = 16384) ?(eof = false) wire =
  `Assoc
    [ "wire", `String (hex wire)
    ; "ws", `Bool ws
    ; "extra", `String extra
    ; "segment", `Int segment
    ; "eof", `Bool eof
    ]
;;

let wait clock predicate =
  Eio.Time.with_timeout_exn clock 5. (fun () ->
    while not (predicate ()) do
      Eio.Time.sleep clock 0.005
    done)
;;

let read_file path =
  let input = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr input)
    (fun () -> really_input_string input (in_channel_length input))
;;

let with_peer cases f =
  with_support (fun support ->
    Eio_main.run (fun environment ->
      Eio.Switch.run (fun sw ->
        let clock = Eio.Stdenv.clock environment in
        Yojson.Basic.to_file (Filename.concat support "cases.json") (`List cases);
        let process =
          Eio.Process.spawn
            ~sw
            (Eio.Stdenv.process_mgr environment)
            [ "python3"; "-c"; peer; support ]
        in
        wait clock (fun () -> Sys.file_exists (Filename.concat support "ready"));
        let port = int_of_string (read_file (Filename.concat support "ready")) in
        let origin = Uri.of_string (Printf.sprintf "https://localhost:%d" port) in
        f ~environment ~sw ~support ~origin;
        Eio.Time.with_timeout_exn clock 5. (fun () -> Eio.Process.await_exn process);
        Yojson.Basic.from_file (Filename.concat support "report"))))
;;

let graph = { Core_contract.graph with name = "Transport fixture" }

let bootstrap origin =
  let initial =
    Core.config ~managed_sync_origin:origin ~limits:(Core_contract.limits ())
    |> Result.get_ok
    |> Core.initial
    |> Result.get_ok
  in
  let auth =
    Core.step initial (Core.Account_authenticated { user_id = Some "fixture" })
  in
  let catalog =
    List.find_map
      (function
        | Core.Run (Core.Request (ticket, Core.Fetch_catalog _)) ->
          Some
            (Core.step
               auth.next
               (Core.Runner_completed (Core.Completion (ticket, Ok [ graph ]))))
        | _ -> None)
      auth.effects
    |> Option.get
  in
  let selected = Core.step catalog.next (Core.Graph_selected graph.graph_id) in
  let scope =
    List.find_map
      (function
        | Core.Delegate (Core.Inspect_mirror request) -> Some request.scope
        | _ -> None)
      selected.effects
    |> Option.get
  in
  Core.step selected.next (Core.Mirror_inspected (Core.Mirror_absent scope)), scope
;;

let operation ~download origin =
  let transition, scope = bootstrap origin in
  if not download
  then
    List.find_map
      (function
        | Core.Run (Core.Request (_, Core.Fetch_snapshot_baseline _) as op) -> Some op
        | _ -> None)
      transition.effects
    |> Option.get
  else (
    let metadata =
      List.find_map
        (function
          | Core.Run (Core.Request (ticket, Core.Fetch_snapshot_baseline _)) ->
            Some
              (Core.step
                 transition.next
                 (Core.Runner_completed
                    (Core.Completion (ticket, Ok {|{"type":"pull/ok","t":42}|}))))
          | _ -> None)
        transition.effects
      |> Option.get
    in
    let artifact_uri = Uri.with_path origin "/artifact" |> Uri.to_string in
    let response =
      Yojson.Basic.to_string (`Assoc [ "ok", `Bool true; "url", `String artifact_uri ])
    in
    let downloading =
      List.find_map
        (function
          | Core.Run (Core.Request (ticket, Core.Fetch_snapshot_metadata _)) ->
            Some
              (Core.step
                 metadata.next
                 (Core.Runner_completed (Core.Completion (ticket, Ok response))))
          | _ -> None)
        metadata.effects
      |> Option.get
    in
    List.find_map
      (function
        | Core.Run (Core.Request (ticket, Core.Download_snapshot request)) ->
          Some (Core.Request (ticket, Core.Download_snapshot { request with scope }))
        | _ -> None)
      downloading.effects
    |> Option.get)
;;

let runner
      ?(websocket_liveness = Runner.Disabled)
      ?network
      ~environment
      ~sw
      ~support
      ~posted
      ~invalidations
      ()
  =
  let transport =
    Runner.transport
      ~websocket_liveness
      ~tls_authenticator:(Runner.tls_authenticator (fun ?ip:_ ~host:_ _ -> Ok None))
      ~network:(Option.value network ~default:(Eio.Stdenv.net environment))
      ~clock:(Eio.Stdenv.clock environment)
    |> Result.get_ok
  in
  let dependencies =
    Runner.dependencies
      ~runtime:
        (Runner.runtime
           ~fork:Eio.Fiber.fork
           ~sleep:(Eio.Time.sleep (Eio.Stdenv.clock environment))
         |> Result.get_ok)
      ~transport
      ~local_store:
        (Runner.local_store ~application_support_directory:support |> Result.get_ok)
      ~artifact_store:
        (Runner.artifact_store ~staging_directory:(Filename.concat support "staging")
         |> Result.get_ok)
      ~secrets:(secrets ())
      ~crypto:(crypto ())
      ~id_token_provider:
        (Runner.id_token_provider
           ~acquire:(fun _ -> Ok "fixture-token")
           ~invalidate:(fun _ ~token:_ -> incr invalidations))
    |> Result.get_ok
  in
  Runner.create ~sw dependencies ~post:(fun event -> posted := !posted @ [ event ])
  |> Result.get_ok
;;

let completed events =
  List.find_map
    (function
      | Core.Runner_completed (Core.Completion (_, result)) ->
        Some (Result.map (fun _ -> ()) result)
      | _ -> None)
    events
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

let http_test
      ~download
      ~success
      ?(payload = "x")
      ?retained_download
      ?(segment = 16384)
      ?(eof = false)
      wire
      ()
  =
  let report =
    with_peer
      [ case ~segment ~eof wire ]
      (fun ~environment ~sw ~support ~origin ->
         let posted = ref []
         and invalidations = ref 0 in
         let t = runner ~environment ~sw ~support ~posted ~invalidations () in
         Runner.submit t (operation ~download origin);
         wait (Eio.Stdenv.clock environment) (fun () ->
           Option.is_some (completed !posted));
         let result = Option.get (completed !posted) in
         (match result with
          | Error (Core.Effect_failed message | Core.Crypto_failed (_, message)) ->
            prerr_endline message
          | Ok () -> ());
         Alcotest.(check bool) "response outcome" success (Result.is_ok result);
         if download
         then (
           let staging = Filename.concat support "staging" in
           let names = Sys.readdir staging |> Array.to_list in
           if success
           then (
             Alcotest.(check int) "one artifact published" 1 (List.length names);
             Alcotest.(check string)
               "exact artifact payload"
               payload
               (read_file (Filename.concat staging (List.hd names))))
           else (
             match retained_download with
             | None -> Alcotest.(check (list string)) "no partial artifact" [] names
             | Some body ->
               Alcotest.(check int)
                 "only completed download remains"
                 1
                 (List.length names);
               let name = List.hd names in
               Alcotest.(check bool)
                 "no decompressed artifact or staging file published"
                 true
                 (Filename.check_suffix name ".download");
               Alcotest.(check string)
                 "completed download is intact"
                 body
                 (read_file (Filename.concat staging name))));
         Runner.shutdown t)
  in
  check_retired report
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

let ws_test ?(extra = "") ?(segment = 16384) ~messages ~terminal wire () =
  let report =
    with_peer
      [ case ~ws:true ~extra ~segment wire ]
      (fun ~environment ~sw ~support ~origin ->
         let posted = ref []
         and invalidations = ref 0 in
         let t = runner ~environment ~sw ~support ~posted ~invalidations () in
         let _, graph = bootstrap origin in
         let scope = Core.{ graph; connection_generation = 1 } in
         Runner.submit
           t
           (Core.Start_websocket
              { scope; uri = Uri.with_scheme (Uri.with_path origin "/ws") (Some "wss") });
         let clock = Eio.Stdenv.clock environment in
         let message_count () =
           List.length
             (List.filter
                (function
                  | Core.Websocket_message _ -> true
                  | _ -> false)
                !posted)
         in
         let closed () =
           List.exists
             (function
               | Core.Websocket_closed _ -> true
               | _ -> false)
             !posted
         in
         wait clock (fun () ->
           if terminal then closed () else message_count () >= messages);
         Alcotest.(check int)
           "ordered application message count"
           messages
           (message_count ());
         let rec ordered opened = function
           | [] -> ()
           | Core.Websocket_opened _ :: rest -> ordered true rest
           | Core.Websocket_message _ :: rest ->
             Alcotest.(check bool) "open precedes data" true opened;
             ordered opened rest
           | _ :: rest -> ordered opened rest
         in
         ordered false !posted;
         if not terminal
         then (
           Runner.submit t (Core.Close_websocket scope);
           wait clock closed);
         Alcotest.(check int)
           "one terminal notification"
           1
           (List.length
              (List.filter
                 (function
                   | Core.Websocket_closed _ -> true
                   | _ -> false)
                 !posted));
         Runner.shutdown t)
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
         frames))
;;

(* T12-T18 are accepted dependency limitations. These cases exercise supported
   framing and wrapper cleanup, not a replacement protocol conformance suite. *)
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
  ; "forbidden", false, false, response ~status:403 "x"
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
;;

let test_cancelled_attempt ~download () =
  let report =
    with_peer
      [ case (response ~headers:"Content-Length: 100\r\n" "x") ]
      (fun ~environment ~sw ~support ~origin ->
         let posted = ref []
         and invalidations = ref 0 in
         let t = runner ~environment ~sw ~support ~posted ~invalidations () in
         let op = operation ~download origin in
         let raw =
           match op with
           | Core.Request (ticket, _) ->
             Filename.concat
               (Filename.concat support "staging")
               ("snapshot-"
                ^ Core.effect_id_to_string (Core.effect_ticket_id ticket)
                ^ ".download")
           | _ -> assert false
         in
         if download
         then (
           Unix.mkdir (Filename.dirname raw) 0o700;
           let output = open_out_bin raw in
           output_string output "committed";
           close_out output);
         Runner.submit t op;
         let clock = Eio.Stdenv.clock environment in
         wait clock (fun () -> Sys.file_exists (Filename.concat support "sent"));
         Runner.submit t (Core.Cancel_effects (Core.runner_effect_scope op));
         Eio.Time.sleep clock 0.05;
         let event_count = List.length !posted in
         Eio.Time.sleep clock 0.05;
         Alcotest.(check int)
           "no callbacks after cancellation"
           event_count
           (List.length !posted);
         Alcotest.(check bool)
           "cancelled operation never completes"
           true
           (completed !posted = None);
         if download
         then (
           Alcotest.(check bool)
             "committed destination preserved"
             true
             (Sys.file_exists raw);
           Alcotest.(check string) "committed bytes preserved" "committed" (read_file raw);
           Alcotest.(check int)
             "no attempt temporary remains"
             1
             (Array.length (Sys.readdir (Filename.dirname raw))));
         Runner.shutdown t)
  in
  check_retired report
;;

let test_http_retry ~download () =
  let report =
    with_peer
      [ case (response ~status:401 "x"); case (response "x") ]
      (fun ~environment ~sw ~support ~origin ->
         let posted = ref []
         and invalidations = ref 0 in
         let t = runner ~environment ~sw ~support ~posted ~invalidations () in
         Runner.submit t (operation ~download origin);
         wait (Eio.Stdenv.clock environment) (fun () ->
           Option.is_some (completed !posted));
         Alcotest.(check bool)
           "retry succeeds"
           true
           (Result.is_ok (Option.get (completed !posted)));
         Alcotest.(check int) "one token invalidation" 1 !invalidations;
         if download
         then
           Alcotest.(check int)
             "one validated artifact"
             1
             (Array.length (Sys.readdir (Filename.concat support "staging")));
         Runner.shutdown t)
  in
  check_retired report
;;

let test_redirect ~download ~cross_origin () =
  let redirect =
    response
      ~status:302
      ~headers:
        ((if cross_origin
          then "Location: https://example.invalid/artifact\r\n"
          else "Location: /follow\r\n")
         ^ "Content-Length: 1\r\n")
      "x"
  in
  let cases =
    if cross_origin then [ case redirect ] else [ case redirect; case (response "x") ]
  in
  let report =
    with_peer cases (fun ~environment ~sw ~support ~origin ->
      let posted = ref []
      and invalidations = ref 0 in
      let t = runner ~environment ~sw ~support ~posted ~invalidations () in
      Runner.submit t (operation ~download origin);
      wait (Eio.Stdenv.clock environment) (fun () -> Option.is_some (completed !posted));
      Alcotest.(check bool)
        "redirect origin policy"
        (not cross_origin)
        (Result.is_ok (Option.get (completed !posted)));
      if cross_origin && download
      then
        Alcotest.(check int)
          "no redirect artifact"
          0
          (Array.length (Sys.readdir (Filename.concat support "staging")));
      Runner.shutdown t)
  in
  check_retired report
;;

let test_ws_cancellation ~during_close () =
  let report =
    with_peer
      [ case ~ws:true "" ]
      (fun ~environment ~sw ~support ~origin ->
         let posted = ref []
         and invalidations = ref 0 in
         let t = runner ~environment ~sw ~support ~posted ~invalidations () in
         let _, graph = bootstrap origin in
         let scope = Core.{ graph; connection_generation = 1 } in
         Runner.submit
           t
           (Core.Start_websocket { scope; uri = Uri.with_scheme origin (Some "wss") });
         let clock = Eio.Stdenv.clock environment in
         wait clock (fun () ->
           List.exists
             (function
               | Core.Websocket_opened _ -> true
               | _ -> false)
             !posted);
         if during_close then Runner.submit t (Core.Close_websocket scope);
         let start = Eio.Time.now clock in
         Runner.submit t (Core.Cancel_effects (Core.effect_scope_of_graph graph));
         Runner.shutdown t;
         Alcotest.(check bool)
           "abort dispatch does not await grace"
           true
           (Eio.Time.now clock -. start < 0.05))
  in
  check_retired report
;;

let scenarios =
  scenarios
  @ List.concat_map
      (fun download ->
         let label = if download then "download " else "HTTP " in
         [ Alcotest.test_case
             (label ^ "cancel retires attempt and preserves committed output")
             `Quick
             (test_cancelled_attempt ~download)
         ; Alcotest.test_case
             (label ^ "401 refresh and retry")
             `Quick
             (test_http_retry ~download)
         ; Alcotest.test_case
             (label ^ "same-origin redirect")
             `Quick
             (test_redirect ~download ~cross_origin:false)
         ; Alcotest.test_case
             (label ^ "cross-origin redirect rejected")
             `Quick
             (test_redirect ~download ~cross_origin:true)
         ])
      [ false; true ]
  @ [ Alcotest.test_case
        "WebSocket cancellation aborts owner"
        `Quick
        (test_ws_cancellation ~during_close:false)
    ; Alcotest.test_case
        "WebSocket abort interrupts graceful close"
        `Quick
        (test_ws_cancellation ~during_close:true)
    ]
  @ List.map
      (fun size ->
         let message = {|{"type":"changed","t":42}|} in
         let wire = String.make (size - String.length message) ' ' ^ message in
         Alcotest.test_case
           (Printf.sprintf "WebSocket minimal length boundary %d" size)
           `Quick
           (ws_test ~messages:1 ~terminal:false (frame 1 wire)))
      [ 125; 126; 65535; 65536 ]
  @ [ Alcotest.test_case
        "WebSocket UTF8 codepoint split across fragments"
        `Quick
        (ws_test
           ~messages:1
           ~terminal:false
           (frame ~fin:false 1 "{\"type\":\"error\",\"message\":\"\xe4"
            ^ frame 9 "probe"
            ^ frame 0 "\xb8\xad\"}"))
    ]
;;

let test_artifact_credentials ~status () =
  let report =
    with_peer
      [ case (response ~status "x") ]
      (fun ~environment ~sw ~support ~origin ->
         let posted = ref []
         and invalidations = ref 0 in
         let t = runner ~environment ~sw ~support ~posted ~invalidations () in
         let op =
           match operation ~download:true (Uri.with_port origin (Some 1)) with
           | Core.Request (ticket, Core.Download_snapshot request) ->
             Core.Request
               ( ticket
               , Core.Download_snapshot
                   { request with
                     uri = Uri.with_path origin "/signed-artifact?signature=fixture"
                   } )
           | _ -> assert false
         in
         Runner.submit t op;
         wait (Eio.Stdenv.clock environment) (fun () ->
           Option.is_some (completed !posted));
         Alcotest.(check bool)
           "signed artifact status preserved"
           (status = 200)
           (Result.is_ok (Option.get (completed !posted)));
         Alcotest.(check int) "signed URL never invalidates bearer token" 0 !invalidations;
         Runner.shutdown t)
  in
  check_retired report;
  let wire =
    Yojson.Basic.Util.(report |> to_list |> List.hd |> member "request" |> to_string)
  in
  let decoded =
    String.init
      (String.length wire / 2)
      (fun i -> Char.chr (int_of_string ("0x" ^ String.sub wire (i * 2) 2)))
  in
  Alcotest.(check bool)
    "cross-origin request omits authorization"
    false
    (String.split_on_char '\n' decoded
     |> List.exists (fun line ->
       String.starts_with ~prefix:"authorization:" (String.lowercase_ascii line)))
;;

let scenarios =
  scenarios
  @ [ Alcotest.test_case
        "signed artifact omits account bearer"
        `Quick
        (test_artifact_credentials ~status:200)
    ; Alcotest.test_case
        "signed artifact 401 never refreshes account bearer"
        `Quick
        (test_artifact_credentials ~status:401)
    ]
;;

let test_liveness ~reply () =
  let config =
    match case ~ws:true "" with
    | `Assoc fields -> `Assoc (("reply_ping", `Bool reply) :: fields)
    | _ -> assert false
  in
  let report =
    with_peer [ config ] (fun ~environment ~sw ~support ~origin ->
      let posted = ref []
      and invalidations = ref 0 in
      let t =
        runner
          ~websocket_liveness:
            (Runner.Ping_pong { interval_seconds = 0.02; timeout_seconds = 0.03 })
          ~environment
          ~sw
          ~support
          ~posted
          ~invalidations
          ()
      in
      let _, graph = bootstrap origin in
      let scope = Core.{ graph; connection_generation = 1 } in
      Runner.submit
        t
        (Core.Start_websocket { scope; uri = Uri.with_scheme origin (Some "wss") });
      let clock = Eio.Stdenv.clock environment in
      wait clock (fun () ->
        List.exists
          (function
            | Core.Websocket_opened _ -> true
            | _ -> false)
          !posted);
      Eio.Time.sleep clock 0.15;
      let closed () =
        List.exists
          (function
            | Core.Websocket_closed _ -> true
            | _ -> false)
          !posted
      in
      Alcotest.(check bool) "correlated Pong determines liveness" (not reply) (closed ());
      if reply
      then (
        Runner.submit t (Core.Close_websocket scope);
        wait clock closed);
      Runner.shutdown t)
  in
  check_retired report;
  let frames =
    Yojson.Basic.Util.(report |> to_list |> List.hd |> member "frames" |> to_list)
  in
  Alcotest.(check bool)
    "peer observes protocol Ping"
    true
    (List.exists
       (fun frame -> Yojson.Basic.Util.(frame |> member "opcode" |> to_int) = 9)
       frames)
;;

let test_control_output () =
  let config =
    match case ~ws:true (frame 9 "server-probe") with
    | `Assoc fields -> `Assoc (("reply_ping", `Bool true) :: fields)
    | _ -> assert false
  in
  let report =
    with_peer [ config ] (fun ~environment ~sw ~support ~origin ->
      let posted = ref []
      and invalidations = ref 0 in
      let t =
        runner
          ~websocket_liveness:
            (Runner.Ping_pong { interval_seconds = 0.03; timeout_seconds = 0.1 })
          ~environment
          ~sw
          ~support
          ~posted
          ~invalidations
          ()
      in
      let _, graph = bootstrap origin in
      let scope = Core.{ graph; connection_generation = 1 } in
      Runner.submit
        t
        (Core.Start_websocket { scope; uri = Uri.with_scheme origin (Some "wss") });
      let clock = Eio.Stdenv.clock environment in
      wait clock (fun () ->
        List.exists
          (function
            | Core.Websocket_opened _ -> true
            | _ -> false)
          !posted);
      Runner.submit
        t
        (Core.Send_websocket
           { scope
           ; message =
               Logseq_sync_pure_reducer.Sync_protocol.Client.Hello
                 { client = "mask-fixture" }
           });
      Eio.Time.sleep clock 0.15;
      Runner.submit t (Core.Close_websocket scope);
      wait clock (fun () ->
        List.exists
          (function
            | Core.Websocket_closed _ -> true
            | _ -> false)
          !posted);
      Runner.shutdown t)
  in
  let frames =
    Yojson.Basic.Util.(report |> to_list |> List.hd |> member "frames" |> to_list)
  in
  List.iter
    (fun opcode ->
       Alcotest.(check bool)
         (Printf.sprintf "opcode %d serialized" opcode)
         true
         (List.exists
            (fun frame -> Yojson.Basic.Util.(frame |> member "opcode" |> to_int) = opcode)
            frames))
    [ 1; 8; 9; 10 ];
  List.iter
    (fun frame ->
       Alcotest.(check int)
         "client frame has a mask"
         8
         (String.length Yojson.Basic.Util.(frame |> member "mask" |> to_string)))
    frames;
  check_retired report
;;

let test_invalid_liveness () =
  Eio_main.run (fun env ->
    List.iter
      (fun seconds ->
         let result =
           Runner.transport
             ~tls_authenticator:
               (Runner.tls_authenticator (fun ?ip:_ ~host:_ _ -> Ok None))
             ~network:(Eio.Stdenv.net env)
             ~clock:(Eio.Stdenv.clock env)
             ~websocket_liveness:
               (Runner.Ping_pong { interval_seconds = seconds; timeout_seconds = seconds })
         in
         Alcotest.(check bool)
           "invalid liveness is rejected"
           true
           (Result.is_error result))
      [ 0.; -1.; infinity; nan ])
;;

let scenarios =
  scenarios
  @ [ Alcotest.test_case
        "WebSocket silent peer liveness deadline"
        `Quick
        (test_liveness ~reply:false)
    ; Alcotest.test_case
        "WebSocket matching Pong keeps connection alive"
        `Quick
        (test_liveness ~reply:true)
    ; Alcotest.test_case
        "WebSocket data and control frames reach peer"
        `Quick
        test_control_output
    ; Alcotest.test_case
        "WebSocket liveness configuration validation"
        `Quick
        test_invalid_liveness
    ]
;;

let test_output_admission () =
  let report =
    with_peer
      [ case ~ws:true "" ]
      (fun ~environment ~sw ~support ~origin ->
         let posted = ref []
         and invalidations = ref 0 in
         let t = runner ~environment ~sw ~support ~posted ~invalidations () in
         let _, graph = bootstrap origin in
         let scope = Core.{ graph; connection_generation = 1 } in
         Runner.submit
           t
           (Core.Start_websocket { scope; uri = Uri.with_scheme origin (Some "wss") });
         let clock = Eio.Stdenv.clock environment in
         wait clock (fun () ->
           List.exists
             (function
               | Core.Websocket_opened _ -> true
               | _ -> false)
             !posted);
         for index = 0 to 1999 do
           Runner.submit
             t
             (Core.Send_websocket
                { scope
                ; message =
                    Logseq_sync_pure_reducer.Sync_protocol.Client.Hello
                      { client = string_of_int index }
                })
         done;
         let count_path = Filename.concat support "frame-count" in
         wait clock (fun () ->
           Sys.file_exists count_path
           && Option.value (int_of_string_opt (read_file count_path)) ~default:0 >= 128);
         Runner.submit
           t
           (Core.Send_websocket
              { scope
              ; message =
                  Logseq_sync_pure_reducer.Sync_protocol.Client.Hello
                    { client = "after-drain" }
              });
         Runner.submit t (Core.Close_websocket scope);
         wait clock (fun () ->
           List.exists
             (function
               | Core.Websocket_closed _ -> true
               | _ -> false)
             !posted);
         Runner.shutdown t)
  in
  let frames =
    Yojson.Basic.Util.(report |> to_list |> List.hd |> member "frames" |> to_list)
  in
  let data =
    List.filter
      (fun frame -> Yojson.Basic.Util.(frame |> member "opcode" |> to_int) = 1)
      frames
  in
  Alcotest.(check int)
    "queue rejects overflow and releases completed budget"
    129
    (List.length data);
  List.iteri
    (fun index frame ->
       let client = if index = 128 then "after-drain" else string_of_int index in
       let expected =
         Logseq_sync_pure_reducer.Sync_protocol.encode_client_message (Hello { client })
         |> Result.get_ok
         |> hex
       in
       Alcotest.(check string)
         "accepted data retains order"
         expected
         Yojson.Basic.Util.(frame |> member "payload" |> to_string))
    data;
  check_retired report
;;

let scenarios =
  scenarios
  @ [ Alcotest.test_case
        "WebSocket aggregate send admission and budget release"
        `Quick
        test_output_admission
    ]
;;

let test_setup_cancel ~websocket ~dns () =
  let run ~environment ~sw ~support ~origin =
    let posted = ref []
    and invalidations = ref 0 in
    let t = runner ~environment ~sw ~support ~posted ~invalidations () in
    let op =
      if websocket
      then (
        let _, graph = bootstrap origin in
        Core.Start_websocket
          { scope = { graph; connection_generation = 1 }
          ; uri = Uri.with_scheme origin (Some "wss")
          })
      else operation ~download:false origin
    in
    Runner.submit t op;
    Eio.Time.sleep (Eio.Stdenv.clock environment) 0.03;
    Runner.submit t (Core.Cancel_effects (Core.runner_effect_scope op));
    Runner.shutdown t
  in
  let started = Unix.gettimeofday () in
  if dns
  then (
    let descriptors () = Array.length (Sys.readdir "/dev/fd") in
    let before = descriptors () in
    with_support (fun support ->
      Eio_main.run (fun environment ->
        Eio.Switch.run (fun sw ->
          let host =
            Printf.sprintf
              "logseq-transport-%d-%d.local"
              (Unix.getpid ())
              (Random.bits ())
          in
          let origin = Uri.of_string ("https://" ^ host) in
          run ~environment ~sw ~support ~origin)));
    Alcotest.(check bool)
      "DNS setup cancellation joins within bound"
      true
      (Unix.gettimeofday () -. started < 0.5);
    Alcotest.(check bool)
      "DNS cancellation releases owned descriptors"
      true
      (descriptors () <= before))
  else (
    let stalled = `Assoc [ "stall_tls", `Bool true ] in
    ignore (with_peer [ stalled ] run);
    Alcotest.(check bool)
      "TLS setup cancellation joins within bound"
      true
      (Unix.gettimeofday () -. started < 1.))
;;

let test_alternate_address ~websocket () =
  let config = if websocket then case ~ws:true "" else case (response "x") in
  let report =
    with_peer
      [ `Assoc [ "stall_tls", `Bool true ]; config ]
      (fun ~environment ~sw ~support ~origin ->
         let posted = ref []
         and invalidations = ref 0 in
         let t = runner ~environment ~sw ~support ~posted ~invalidations () in
         if websocket
         then (
           let _, graph = bootstrap origin in
           let scope = Core.{ graph; connection_generation = 1 } in
           Runner.submit
             t
             (Core.Start_websocket { scope; uri = Uri.with_scheme origin (Some "wss") });
           wait (Eio.Stdenv.clock environment) (fun () ->
             List.exists
               (function
                 | Core.Websocket_opened _ | Core.Websocket_closed _ -> true
                 | _ -> false)
               !posted);
           Alcotest.(check bool)
             "later address opens authenticated WebSocket"
             true
             (List.exists
                (function
                  | Core.Websocket_opened _ -> true
                  | _ -> false)
                !posted);
           Runner.submit t (Core.Close_websocket scope);
           wait (Eio.Stdenv.clock environment) (fun () ->
             List.exists
               (function
                 | Core.Websocket_closed _ -> true
                 | _ -> false)
               !posted))
         else (
           Runner.submit t (operation ~download:false origin);
           wait (Eio.Stdenv.clock environment) (fun () ->
             Option.is_some (completed !posted));
           Alcotest.(check bool)
             "later address completes HTTP"
             true
             (Result.is_ok (Option.get (completed !posted))));
         Runner.shutdown t)
  in
  check_retired report
;;

let scenarios =
  scenarios
  @ List.concat_map
      (fun websocket ->
         let prefix = if websocket then "WebSocket " else "HTTP " in
         [ Alcotest.test_case
             (prefix ^ "DNS cancellation reclaims setup")
             `Quick
             (test_setup_cancel ~websocket ~dns:true)
         ; Alcotest.test_case
             (prefix ^ "TLS cancellation reclaims setup")
             `Quick
             (test_setup_cancel ~websocket ~dns:false)
         ; Alcotest.test_case
             (prefix ^ "tries alternate address after TLS failure")
             `Quick
             (test_alternate_address ~websocket)
         ])
      [ false; true ]
;;

let test_upgrade_authentication ~status () =
  let cases =
    [ case (response ~status "x") ] @ if status = 401 then [ case ~ws:true "" ] else []
  in
  let report =
    with_peer cases (fun ~environment ~sw ~support ~origin ->
      let posted = ref []
      and invalidations = ref 0 in
      let t = runner ~environment ~sw ~support ~posted ~invalidations () in
      let _, graph = bootstrap origin in
      let scope = Core.{ graph; connection_generation = 1 } in
      Runner.submit
        t
        (Core.Start_websocket { scope; uri = Uri.with_scheme origin (Some "wss") });
      let clock = Eio.Stdenv.clock environment in
      let closed () =
        List.exists
          (function
            | Core.Websocket_closed _ -> true
            | _ -> false)
          !posted
      in
      let opened () =
        List.exists
          (function
            | Core.Websocket_opened _ -> true
            | _ -> false)
          !posted
      in
      wait clock (fun () -> opened () || closed ());
      Alcotest.(check bool)
        "only unauthorized Upgrade retries and opens"
        (status = 401)
        (opened ());
      Alcotest.(check int)
        "Upgrade token invalidations"
        (if status = 401 then 1 else 0)
        !invalidations;
      if opened ()
      then (
        Runner.submit t (Core.Close_websocket scope);
        wait clock closed);
      Runner.shutdown t)
  in
  check_retired report
;;

let scenarios =
  scenarios
  @ List.map
      (fun status ->
         Alcotest.test_case
           (Printf.sprintf "WebSocket Upgrade %d preserves authentication outcome" status)
           `Quick
           (test_upgrade_authentication ~status))
      [ 401; 403 ]
;;

let delayed_network network before_connect =
  let module Network = struct
    type t = Eio_unix.Net.t * (unit -> unit)

    type tag =
      [ `Generic
      | `Unix
      ]

    let listen (net, _) ~reuse_addr ~reuse_port ~backlog ~sw address =
      Eio.Net.listen net ~reuse_addr ~reuse_port ~backlog ~sw address
    ;;

    let connect (net, before) ~sw address =
      before ();
      Eio.Net.connect net ~sw address
    ;;

    let datagram_socket (net, _) ~reuse_addr ~reuse_port ~sw address =
      Eio.Net.datagram_socket net ~reuse_addr ~reuse_port ~sw address
    ;;

    let getaddrinfo (net, _) ~service host = Eio.Net.getaddrinfo net ~service host
    let getnameinfo (net, _) address = Eio.Net.getnameinfo net address
  end
  in
  Eio.Resource.T ((network, before_connect), Eio.Net.Pi.network (module Network))
;;

let test_stalled_tcp ~cancel () =
  let report =
    with_peer
      (if cancel then [] else [ case (response "x") ])
      (fun ~environment ~sw ~support ~origin ->
         let clock = Eio.Stdenv.clock environment in
         let attempts = ref 0
         and released = ref false in
         let network =
           delayed_network (Eio.Stdenv.net environment) (fun () ->
             incr attempts;
             if !attempts = 1
             then
               Fun.protect
                 ~finally:(fun () -> released := true)
                 (fun () -> Eio.Time.sleep clock 30.))
         in
         let posted = ref []
         and invalidations = ref 0 in
         let t = runner ~network ~environment ~sw ~support ~posted ~invalidations () in
         let op = operation ~download:false origin in
         Runner.submit t op;
         wait clock (fun () -> !attempts > 0);
         let started = Eio.Time.now clock in
         if cancel
         then (
           Runner.submit t (Core.Cancel_effects (Core.runner_effect_scope op));
           wait clock (fun () -> !released);
           Alcotest.(check bool)
             "TCP cancellation is prompt"
             true
             (Eio.Time.now clock -. started < 0.5))
         else (
           wait clock (fun () -> Option.is_some (completed !posted));
           Alcotest.(check bool)
             "blackholed first candidate does not starve the next"
             true
             (Result.is_ok (Option.get (completed !posted)));
           Alcotest.(check bool)
             "next candidate starts within bound"
             true
             (Eio.Time.now clock -. started < 2.);
           Alcotest.(check int) "two address candidates" 2 !attempts);
         Alcotest.(check bool) "first candidate work retired" true !released;
         Runner.shutdown t)
  in
  check_retired report
;;

let test_artifact_publication_failure () =
  let report =
    with_peer
      [ case (response "x") ]
      (fun ~environment ~sw ~support ~origin ->
         let posted = ref []
         and invalidations = ref 0 in
         let t = runner ~environment ~sw ~support ~posted ~invalidations () in
         let op = operation ~download:true origin in
         let id =
           match op with
           | Core.Request (ticket, _) ->
             Core.effect_id_to_string (Core.effect_ticket_id ticket)
           | _ -> assert false
         in
         let staging = Filename.concat support "staging" in
         Unix.mkdir staging 0o700;
         let destination = Filename.concat staging ("snapshot-" ^ id ^ ".download") in
         Unix.mkdir destination 0o700;
         Runner.submit t op;
         wait (Eio.Stdenv.clock environment) (fun () ->
           Option.is_some (completed !posted));
         Alcotest.(check bool)
           "failed atomic publication never succeeds"
           true
           (Result.is_error (Option.get (completed !posted)));
         Alcotest.(check bool)
           "existing destination preserved"
           true
           (Sys.is_directory destination);
         Alcotest.(check int)
           "temporary removed after publication failure"
           1
           (Array.length (Sys.readdir staging));
         Runner.shutdown t)
  in
  check_retired report
;;

let scenarios =
  scenarios
  @ [ Alcotest.test_case
        "HTTP stalled TCP cancellation"
        `Quick
        (test_stalled_tcp ~cancel:true)
    ; Alcotest.test_case
        "HTTP stalled TCP advances to next address"
        `Quick
        (test_stalled_tcp ~cancel:false)
    ; Alcotest.test_case
        "download publication failure preserves destination"
        `Quick
        test_artifact_publication_failure
    ]
;;

(* Generated independently with Python gzip.compress(..., mtime=0). *)
let gzip_downloads =
  [ ( "one gzip layer"
    , true
    , "x"
    , "\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\xff\xab\x00\x00\x83\x16\xdc\x8c\x01\x00\x00\x00"
    )
  ; ( "two gzip layers"
    , true
    , "x"
    , "\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\xff\x93\xef\xe6\x60\x00\x01\xa6\xff\xab\x19\x18\x9a\xc5\xee\xf4\x30\x02\x39\x00\xd5\xaa\x22\xe2\x15\x00\x00\x00"
    )
  ; ( "three gzip layers rejected"
    , false
    , ""
    , "\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\xff\x93\xef\xe6\x60\x00\x01\xa6\xff\x93\xdf\x3f\x4b\x60\x60\x5c\xf6\x7f\xb5\xa4\xc4\xac\xa3\xef\xbe\x18\x30\x59\x32\x5c\x5d\xa5\xf4\x48\x14\x28\x09\x00\x34\x8c\x86\xf0\x25\x00\x00\x00"
    )
  ; "truncated gzip rejected", false, "", "\x1f\x8b"
  ; "empty plain artifact", true, "", ""
  ; "one-byte signature prefix", true, "\x1f", "\x1f"
  ; "reversed signature is plain", true, "\x8b\x1f", "\x8b\x1f"
  ]
;;

let test_close_with_pending_pong ~reply () =
  let config =
    match case ~ws:true "" with
    | `Assoc fields ->
      `Assoc (("reply_close", `Bool reply) :: ("close_delay", `Float 0.4) :: fields)
    | _ -> assert false
  in
  let report =
    with_peer [ config ] (fun ~environment ~sw ~support ~origin ->
      let posted = ref []
      and invalidations = ref 0 in
      let t =
        runner
          ~websocket_liveness:
            (Runner.Ping_pong { interval_seconds = 0.02; timeout_seconds = 0.2 })
          ~environment
          ~sw
          ~support
          ~posted
          ~invalidations
          ()
      in
      let _, graph = bootstrap origin in
      let scope = Core.{ graph; connection_generation = 1 } in
      let clock = Eio.Stdenv.clock environment in
      Runner.submit
        t
        (Core.Start_websocket { scope; uri = Uri.with_scheme origin (Some "wss") });
      (* The peer records a Ping only after receiving the complete frame, and
         deliberately never answers it. Close starts with a Pong outstanding. *)
      wait clock (fun () -> Sys.file_exists (Filename.concat support "frame-count"));
      let started = Eio.Time.now clock in
      Runner.submit t (Core.Close_websocket scope);
      let closures () =
        List.filter_map
          (function
            | Core.Websocket_closed (_, reason) -> Some reason
            | _ -> None)
          !posted
      in
      wait clock (fun () -> closures () <> []);
      let elapsed = Eio.Time.now clock -. started in
      Alcotest.(check (list (option string)))
        "Close handshake or Close deadline owns termination"
        [ (if reply then None else Some "WebSocket close deadline expired") ]
        (closures ());
      Alcotest.(check bool)
        "pending Pong never shortens close grace"
        true
        (elapsed >= if reply then 0.35 else 0.9);
      Runner.shutdown t;
      Alcotest.(check int) "close callback occurs once" 1 (List.length (closures ())))
  in
  check_retired report;
  let frames =
    Yojson.Basic.Util.(report |> to_list |> List.hd |> member "frames" |> to_list)
  in
  Alcotest.(check (list int))
    "one Ping followed by Close, no later heartbeat"
    [ 9; 8 ]
    (List.map
       (fun frame -> Yojson.Basic.Util.(frame |> member "opcode" |> to_int))
       frames)
;;

let scenarios =
  scenarios
  @ List.map
      (fun (name, success, payload, body) ->
         let headers = Printf.sprintf "Content-Length: %d\r\n" (String.length body) in
         Alcotest.test_case
           ("download " ^ name)
           `Quick
           (http_test
              ~download:true
              ~success
              ~payload
              ?retained_download:(if success then None else Some body)
              (response ~headers body)))
      gzip_downloads
  @ [ Alcotest.test_case
        "WebSocket pending Pong permits delayed Close reply"
        `Quick
        (test_close_with_pending_pong ~reply:true)
    ; Alcotest.test_case
        "WebSocket pending Pong preserves silent-peer close grace"
        `Quick
        (test_close_with_pending_pong ~reply:false)
    ]
;;
