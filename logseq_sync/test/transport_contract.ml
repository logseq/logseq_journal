module Core = Logseq_sync_pure_reducer.Core
module Runner = Logseq_sync_effect_runner.Effect_runner

let with_support = Runner_contract.with_support
let secrets = Runner_contract.secrets
let crypto = Runner_contract.crypto

(* The peer uses Python's independent TLS/framing implementation. Tests enter
   production transports only through the public Runner API. *)
let peer =
  {python|
import base64, hashlib, json, os, select, socket, ssl, struct, subprocess, sys, time, threading
root = sys.argv[1]
with open(root+'/cases.json') as f: cases = json.load(f)
key, cert = root + '/key.pem', root + '/cert.pem'
subprocess.run(['openssl','req','-x509','-newkey','ec','-pkeyopt','ec_paramgen_curve:P-256',
                '-nodes','-keyout',key,'-out',cert,'-days','1','-subj','/CN=localhost'],
               check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(cert,key)
for attempt in range(16):
  listener = socket.socket(socket.AF_INET6)
  listener.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
  listener4 = socket.socket()
  try:
    listener.bind(('::1',0))
    listener4.bind(('127.0.0.1', listener.getsockname()[1]))
    break
  except OSError:
    listener.close(); listener4.close()
    if attempt == 15: raise
listener.listen(8); listener.settimeout(5); listener4.listen(8)
with open(root+'/ready.tmp','w') as f: f.write(str(listener.getsockname()[1]))
os.replace(root+'/ready.tmp', root+'/ready')
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
    time.sleep(case.get('tls_delay',0))
    try: conn=ctx.wrap_socket(raw,server_side=True)
    except (ssl.SSLError,OSError):
      raw.close(); report.append({'closed':True,'frames':[]}); continue
    request=b''
    while b'\r\n\r\n' not in request:
      part=conn.recv(16384)
      if not part: raise RuntimeError('no request')
      request+=part
    header_end=request.index(b'\r\n\r\n')+4
    request_headers=dict(line.split(b':',1) for line in request[:header_end].split(b'\r\n')[1:] if b':' in line)
    length=next((int(v.strip()) for k,v in request_headers.items() if k.lower()==b'content-length'),0)
    while len(request)<header_end+length:
      part=conn.recv(16384)
      if not part: raise RuntimeError('truncated request body')
      request+=part
    time.sleep(case.get('response_delay',0))
    wire=bytes.fromhex(case.get('wire',''))
    if case.get('ws'):
      headers=dict(line.split(b':',1) for line in request.split(b'\r\n')[1:] if b':' in line)
      nonce=next(v.strip() for k,v in headers.items() if k.lower()==b'sec-websocket-key')
      accept=base64.b64encode(hashlib.sha1(nonce+b'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest())
      frames_wire=wire
      wire=(b'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'
            b'Sec-WebSocket-Accept: '+accept+b'\r\n'+case.get('extra','').encode()+b'\r\n'+wire)
    if case.get('ws') and case.get('frame_delay'):
      header_end=wire.index(b'\r\n\r\n')+4
      conn.sendall(wire[:header_end]); time.sleep(case['frame_delay']); wire=frames_wire
    step=case.get('segment',len(wire) or 1)
    for offset in range(0,len(wire),step):
      try: conn.sendall(wire[offset:offset+step])
      except (ssl.SSLError, OSError): break
      if step<32: time.sleep(.0005)
    with open(root+'/sent','w') as f: f.write('sent')
    if case.get('eof'):
      if case.get('reset'): conn.setsockopt(socket.SOL_SOCKET,socket.SO_LINGER,struct.pack('ii',1,0))
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
          with open(root+'/frame-count.tmp','w') as f: f.write(str(len(frames)))
          os.replace(root+'/frame-count.tmp', root+'/frame-count')
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

let scaled_clock clock scale =
  let module Clock = struct
    type t = unit
    type time = float

    let now () = Eio.Time.now clock *. scale
    let sleep_until () deadline = Eio.Time.sleep_until clock (deadline /. scale)
  end
  in
  Eio.Resource.T ((), Eio.Time.Pi.clock (module Clock))
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

let bootstrap ?(mirror_absent = true) ?(user_id = "fixture") origin =
  let initial =
    Core.config ~managed_sync_origin:origin ~limits:(Core_contract.limits ())
    |> Result.get_ok
    |> Core.initial
    |> Result.get_ok
  in
  let auth = Core.step initial (Core.Account_authenticated { user_id = Some user_id }) in
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
  ( (if mirror_absent
     then Core.step selected.next (Core.Mirror_inspected (Core.Mirror_absent scope))
     else selected)
  , scope )
;;

let operation ?artifact_uri ~download origin =
  let transition, _scope = bootstrap origin in
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
    let artifact_uri =
      Option.value
        artifact_uri
        ~default:(Uri.with_path origin "/artifact" |> Uri.to_string)
    in
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
        | Core.Run (Core.Request (_, Core.Download_snapshot _) as runnable) ->
          Some runnable
        | _ -> None)
      downloading.effects
    |> Option.get)
;;

let websocket_cores = ref []

let websocket_start ?(checkpoint = 0) origin =
  let selected, scope = bootstrap ~mirror_absent:false origin in
  let inspected =
    Core.step
      selected.next
      (Core.Mirror_inspected (Core.Mirror_available { graph; scope }))
  in
  let sync =
    Logseq_overlay_db.Types.sync_view
      ~token:
        (Logseq_overlay_db.Types.sync_token_of_string "sync-token:v1:transport"
         |> Result.get_ok)
      ~checkpoint:
        (Logseq_overlay_db.Types.Server_cursor.of_int64 (Int64.of_int checkpoint)
         |> Result.get_ok)
      ~submissions:[]
  in
  let attached = Core.step inspected.next (Core.Graph_attached { scope; sync }) in
  let runnable, connection =
    List.find_map
      (function
        | Core.Run (Core.Start_websocket request as runnable) ->
          Some (runnable, request.scope)
        | _ -> None)
      attached.effects
    |> Option.get
  in
  websocket_cores := (connection, attached.next) :: !websocket_cores;
  runnable
;;

let websocket_core (scope : Core.connection_scope) = List.assoc scope !websocket_cores

let websocket_close (scope : Core.connection_scope) =
  let opened = Core.step (websocket_core scope) (Core.Websocket_opened scope) in
  Core.step
    opened.next
    (Core.Foreground_changed
       { foreground = false
       ; lifecycle_generation = scope.graph.account.lifecycle_generation
       })
  |> fun transition ->
  List.find_map
    (function
      | Core.Run (Core.Close_websocket _ as runnable) -> Some runnable
      | _ -> None)
    transition.effects
  |> Option.get
;;

let websocket_send (scope : Core.connection_scope) checkpoint =
  let _ = websocket_start ~checkpoint scope.Core.graph.account.managed_sync_origin in
  Core.step (websocket_core scope) (Core.Websocket_opened scope)
  |> fun transition ->
  List.find_map
    (function
      | Core.Run (Core.Send_websocket _ as runnable) -> Some runnable
      | _ -> None)
    transition.effects
  |> Option.get
;;

let cancellation_effect scope =
  let core =
    Core.config
      ~managed_sync_origin:(Uri.of_string "https://localhost")
      ~limits:(Core_contract.limits ())
    |> Result.get_ok
    |> Core.initial
    |> Result.get_ok
  in
  let core =
    (Core.step core (Core.Account_authenticated { user_id = Some "fixture" })).next
  in
  let transition = Core.step core Core.Shutdown in
  ignore scope;
  List.find_map
    (function
      | Core.Run (Core.Cancel_effects _ as runnable) -> Some runnable
      | _ -> None)
    transition.effects
  |> Option.get
;;

(* Keep the fixture's real reducer owner across sequential commands. Each accepted
   completion consumes a ticket; starting from its old snapshot would replay it. *)
let asset_fixture_owners = ref []

let asset_owner t =
  match List.find_opt (fun (runner, _) -> runner == t) !asset_fixture_owners with
  | Some (_, scopes) -> scopes
  | None ->
    let scopes = Hashtbl.create 8 in
    asset_fixture_owners := (t, scopes) :: !asset_fixture_owners;
    scopes
;;

let asset_current_core t core scope =
  if Core.admitted_graph_scope core <> Some scope
  then core
  else Option.value (Hashtbl.find_opt (asset_owner t) scope) ~default:core
;;

let asset_remember_core t scope core = Hashtbl.replace (asset_owner t) scope core

let asset_submit t core scope operation action =
  let core = asset_current_core t core scope in
  let transition = Core.step core (Core.Asset_requested { scope; operation; action }) in
  List.iter
    (function
      | Core.Run runnable -> Runner.submit t runnable
      | _ -> ())
    transition.effects;
  asset_remember_core t scope transition.next;
  transition.next
;;

let asset_collect t core posted =
  let rec collect core outputs = function
    | [] ->
      Option.iter
        (fun scope -> asset_remember_core t scope core)
        (Core.admitted_graph_scope core);
      core, List.rev outputs
    | event :: events ->
      let transition = Core.step core event in
      let outputs =
        List.fold_left
          (fun outputs -> function
             | Core.Publish (Core.Asset_finished result) -> result :: outputs
             | Core.Run runnable ->
               Runner.submit t runnable;
               outputs
             | _ -> outputs)
          outputs
          transition.effects
      in
      collect transition.next outputs events
  in
  collect core [] posted
;;

let asset_run t ~clock ~posted core scope operation action =
  let core = asset_current_core t core scope in
  posted := [];
  let transition = Core.step core (Core.Asset_requested { scope; operation; action }) in
  let immediate =
    List.filter_map
      (function
        | Core.Publish (Core.Asset_finished output) -> Some output
        | _ -> None)
      transition.effects
  in
  List.iter
    (function
      | Core.Run runnable -> Runner.submit t runnable
      | _ -> ())
    transition.effects;
  let outputs =
    if immediate <> []
    then (
      asset_remember_core t scope transition.next;
      immediate)
    else (
      wait clock (fun () -> !posted <> []);
      let completed, outputs = asset_collect t transition.next !posted in
      asset_remember_core t scope completed;
      outputs)
  in
  match outputs with
  | [ output ] -> output.Core.result
  | _ -> Alcotest.fail "asset request did not publish exactly one typed outcome"
;;

let asset_stage t ~clock ~posted core scope source_file =
  match
    asset_run
      t
      ~clock
      ~posted
      core
      scope
      "stage"
      (Core.Stage_asset_file
         { operation = graph.graph_id; file_type = "bin"; source_file })
  with
  | Ok (Core.Asset_staged { file; _ }) -> file
  | _ -> Alcotest.fail "source staging failed"
;;

let runner
      ?(websocket_liveness = Runner.Disabled)
      ?network
      ?clock
      ?secrets_dependency
      ?crypto_dependency
      ?(acquire = fun _ -> Ok "fixture-token")
      ?(on_invalidate = fun _ -> ())
      ?(on_post = fun _ -> ())
      ?asset_cache_budget_bytes
      ?asset_maximum_file_bytes
      ?asset_pending_budget_bytes
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
      ~clock:(Option.value clock ~default:(Eio.Stdenv.clock environment))
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
        (Runner.local_store
           ?asset_cache_budget_bytes
           ?asset_maximum_file_bytes
           ?asset_pending_budget_bytes
           ~application_support_directory:support
           ()
         |> Result.get_ok)
      ~artifact_store:
        (Runner.artifact_store ~staging_directory:(Filename.concat support "staging")
         |> Result.get_ok)
      ~secrets:(Option.value secrets_dependency ~default:(secrets ()))
      ~crypto:(Option.value crypto_dependency ~default:(crypto ()))
      ~id_token_provider:
        (Runner.id_token_provider ~acquire ~invalidate:(fun _ ~token ->
           incr invalidations;
           on_invalidate token))
    |> Result.get_ok
  in
  Runner.create ~sw dependencies ~post:(fun event ->
    on_post event;
    posted := !posted @ [ event ])
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
         Runner.submit t (websocket_start origin);
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
           Runner.submit t (websocket_close scope);
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
         Runner.submit t (cancellation_effect (Core.runner_effect_scope op));
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
         Runner.submit t (websocket_start origin);
         let clock = Eio.Stdenv.clock environment in
         wait clock (fun () ->
           List.exists
             (function
               | Core.Websocket_opened _ -> true
               | _ -> false)
             !posted);
         if during_close then Runner.submit t (websocket_close scope);
         let start = Eio.Time.now clock in
         Runner.submit t (cancellation_effect (Core.effect_scope_of_graph graph));
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
           operation
             ~download:true
             ~artifact_uri:
               (Uri.with_path origin "/signed-artifact?signature=fixture" |> Uri.to_string)
             (Uri.with_port origin (Some 1))
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
      Runner.submit t (websocket_start origin);
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
        Runner.submit t (websocket_close scope);
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
      Runner.submit t (websocket_start origin);
      let clock = Eio.Stdenv.clock environment in
      wait clock (fun () ->
        List.exists
          (function
            | Core.Websocket_opened _ -> true
            | _ -> false)
          !posted);
      Runner.submit t (websocket_send scope 0);
      Eio.Time.sleep clock 0.15;
      Runner.submit t (websocket_close scope);
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
         Runner.submit t (websocket_start origin);
         let clock = Eio.Stdenv.clock environment in
         wait clock (fun () ->
           List.exists
             (function
               | Core.Websocket_opened _ -> true
               | _ -> false)
             !posted);
         for index = 0 to 1999 do
           Runner.submit t (websocket_send scope index)
         done;
         let count_path = Filename.concat support "frame-count" in
         wait clock (fun () ->
           Sys.file_exists count_path
           && Option.value (int_of_string_opt (read_file count_path)) ~default:0 >= 128);
         Runner.submit t (websocket_send scope 2000);
         Runner.submit t (websocket_close scope);
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
       let since = if index = 128 then 2000 else index in
       let expected =
         Logseq_sync_pure_reducer.Sync_protocol.encode_client_message
           (Pull { since = Some (Core_contract.server_cursor_of_int since) })
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
      if websocket then websocket_start origin else operation ~download:false origin
    in
    Runner.submit t op;
    Eio.Time.sleep (Eio.Stdenv.clock environment) 0.03;
    Runner.submit t (cancellation_effect (Core.runner_effect_scope op));
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
         let clock = scaled_clock (Eio.Stdenv.clock environment) 10. in
         let t = runner ~clock ~environment ~sw ~support ~posted ~invalidations () in
         if websocket
         then (
           let _, graph = bootstrap origin in
           let scope = Core.{ graph; connection_generation = 1 } in
           Runner.submit t (websocket_start origin);
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
           Runner.submit t (websocket_close scope);
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
      Runner.submit t (websocket_start origin);
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
        Runner.submit t (websocket_close scope);
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

let delayed_network ?(destination = Fun.id) network before_connect =
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
      Eio.Net.connect net ~sw (destination address)
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
         let transport_clock = scaled_clock clock 10. in
         let attempts = ref 0
         and released = ref false in
         let network =
           delayed_network (Eio.Stdenv.net environment) (fun () ->
             incr attempts;
             if !attempts = 1
             then
               Fun.protect
                 ~finally:(fun () -> released := true)
                 (fun () -> Eio.Time.sleep transport_clock 30.))
         in
         let posted = ref []
         and invalidations = ref 0 in
         let t =
           runner
             ~network
             ~clock:transport_clock
             ~environment
             ~sw
             ~support
             ~posted
             ~invalidations
             ()
         in
         let op = operation ~download:false origin in
         Runner.submit t op;
         wait clock (fun () -> !attempts > 0);
         let started = Eio.Time.now clock in
         if cancel
         then (
           Runner.submit t (cancellation_effect (Core.runner_effect_scope op));
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
      Runner.submit t (websocket_start origin);
      (* The peer records a Ping only after receiving the complete frame, and
         deliberately never answers it. Close starts with a Pong outstanding. *)
      wait clock (fun () -> Sys.file_exists (Filename.concat support "frame-count"));
      let started = Eio.Time.now clock in
      Runner.submit t (websocket_close scope);
      let closures () =
        List.filter_map
          (function
            | Core.Websocket_closed (_, reason) -> Some reason
            | _ -> None)
          !posted
      in
      wait clock (fun () -> closures () <> []);
      let elapsed = Eio.Time.now clock -. started in
      Alcotest.(check bool)
        "intentional Close is classified locally and terminates exactly once"
        true
        (closures () = [ Core.Local_close ]);
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

let asset_download ~mismatch ~refresh () =
  let module Asset = Logseq_db_types.Asset_descriptor in
  let module Codec = Logseq_sync_effect_runner.Asset_codec in
  let bytes = "\000\255file\128" in
  let checksum = Codec.checksum (if mismatch then "different" else bytes) in
  let version = Asset.version ~checksum ~file_type:"png" |> Result.get_ok in
  let wire =
    response
      ~headers:(Printf.sprintf "Content-Length: %d\r\n" (String.length bytes))
      bytes
  in
  let cases =
    (if refresh then [ case (response ~status:401 "x") ] else []) @ [ case wire ]
  in
  let report =
    with_peer cases (fun ~environment ~sw ~support ~origin ->
      let posted = ref []
      and invalidations = ref 0 in
      let t = runner ~environment ~sw ~support ~posted ~invalidations () in
      let selected, scope = bootstrap ~mirror_absent:false origin in
      let clock = Eio.Stdenv.clock environment in
      let result =
        asset_run
          t
          ~clock
          ~posted
          selected.next
          scope
          "download"
          (Core.Fetch_asset
             { asset = scope.graph_id; version; maximum_plaintext_bytes = 32 })
      in
      (match result with
       | Ok (Core.Asset_downloaded file) when not mismatch ->
         let retained =
           asset_run
             t
             ~clock
             ~posted
             selected.next
             scope
             "retain"
             (Core.Retain_asset_file file)
         in
         (match retained with
          | Ok (Core.Asset_retained (Some (lease, path))) ->
            Alcotest.(check string) "verified binary bytes" bytes (read_file path);
            ignore
              (asset_run
                 t
                 ~clock
                 ~posted
                 selected.next
                 scope
                 "release"
                 (Core.Release_asset_file lease));
            Alcotest.(check bool)
              "download handle releases through completion"
              true
              (asset_run
                 t
                 ~clock
                 ~posted
                 selected.next
                 scope
                 "release-download"
                 (Core.Release_asset_file file)
               = Ok Core.Asset_unit)
          | _ -> Alcotest.fail "downloaded resource could not be retained")
       | Error Core.Asset_checksum_mismatch when mismatch ->
         let checked =
           asset_run
             t
             ~clock
             ~posted
             selected.next
             scope
             "check"
             (Core.Check_asset_cache (scope.graph_id, version))
         in
         Alcotest.(check bool)
           "bad object not published"
           true
           (checked = Ok (Core.Asset_cached None))
       | _ -> Alcotest.fail "unexpected asset download outcome");
      Alcotest.(check int)
        "same token refresh owner"
        (if refresh then 1 else 0)
        !invalidations;
      Runner.shutdown t)
  in
  check_retired report;
  let request =
    Yojson.Basic.Util.(report |> to_list |> List.hd |> member "request" |> to_string)
  in
  let expected =
    "GET /assets/"
    ^ Logseq_db_types.Graph_types.Uuid.to_string graph.graph_id
    ^ "/"
    ^ Logseq_db_types.Graph_types.Uuid.to_string graph.graph_id
    ^ ".png HTTP/1.1"
  in
  Alcotest.(check bool)
    "per-asset endpoint"
    true
    (String.starts_with ~prefix:(hex expected) request)
;;

let scenarios =
  scenarios
  @ [ Alcotest.test_case
        "asset GET publishes verified bytes"
        `Quick
        (asset_download ~mismatch:false ~refresh:false)
    ; Alcotest.test_case
        "asset GET rejects checksum mismatch"
        `Quick
        (asset_download ~mismatch:true ~refresh:false)
    ; Alcotest.test_case
        "asset GET refreshes authentication"
        `Quick
        (asset_download ~mismatch:false ~refresh:true)
    ]
;;

let asset_upload ~status ~refresh () =
  let module Asset = Logseq_db_types.Asset_descriptor in
  let bytes = "\000\255upload\128" in
  let checksum = Logseq_sync_effect_runner.Asset_codec.checksum bytes in
  let version = Asset.version ~checksum ~file_type:"png" |> Result.get_ok in
  let cases =
    (if refresh then [ case (response ~status:401 "x") ] else [])
    @ [ case (response ~status "x") ]
  in
  let report =
    with_peer cases (fun ~environment ~sw ~support ~origin ->
      let posted = ref []
      and invalidations = ref 0 in
      let runner = runner ~environment ~sw ~support ~posted ~invalidations () in
      let selected, scope = bootstrap ~mirror_absent:false origin in
      let source_file = Filename.concat support "staged.bin" in
      Out_channel.with_open_bin source_file (fun out -> output_string out bytes);
      let clock = Eio.Stdenv.clock environment in
      let file = asset_stage runner ~clock ~posted selected.next scope source_file in
      let result =
        asset_run
          runner
          ~clock
          ~posted
          selected.next
          scope
          "upload"
          (Core.Put_asset_file
             { asset = scope.graph_id; version; file; maximum_plaintext_bytes = 32 })
      in
      let expected =
        match status with
        | 200 -> Ok Core.Asset_unit
        | 403 -> Error Core.Asset_revoked_access
        | 413 -> Error Core.Asset_size_rejected
        | _ -> Error Core.Asset_network
      in
      Alcotest.(check bool) "explicit upload result" true (result = expected);
      Alcotest.(check int)
        "upload token refresh"
        (if refresh then 1 else 0)
        !invalidations;
      Alcotest.(check bool)
        "upload staging cleanup completes"
        true
        (asset_run
           runner
           ~clock
           ~posted
           selected.next
           scope
           "release-upload-stage"
           (Core.Release_staged_file file)
         = Ok Core.Asset_unit);
      Runner.shutdown runner)
  in
  check_retired report;
  Yojson.Basic.Util.to_list report
  |> List.iter (fun row ->
    let encoded = Yojson.Basic.Util.(row |> member "request" |> to_string) in
    let request =
      String.init
        (String.length encoded / 2)
        (fun n -> Char.chr (int_of_string ("0x" ^ String.sub encoded (2 * n) 2)))
    in
    let endpoint =
      Printf.sprintf
        "PUT /assets/%s/%s.png HTTP/1.1"
        (Logseq_db_types.Graph_types.Uuid.to_string graph.graph_id)
        (Logseq_db_types.Graph_types.Uuid.to_string graph.graph_id)
    in
    Alcotest.(check bool)
      "immutable asset endpoint"
      true
      (String.starts_with ~prefix:endpoint request);
    let headers = String.split_on_char '\n' request |> List.map String.trim in
    List.iter
      (fun header -> Alcotest.(check bool) header true (List.mem header headers))
      [ "x-amz-meta-checksum: " ^ checksum
      ; "x-amz-meta-type: png"
      ; "content-length: " ^ string_of_int (String.length bytes)
      ];
    Alcotest.(check bool)
      "raw uploaded bytes"
      true
      (String.ends_with ~suffix:bytes request))
;;

let asset_upload_source () =
  with_support (fun support ->
    Eio_main.run (fun environment ->
      Eio.Switch.run (fun sw ->
        let posted = ref []
        and invalidations = ref 0 in
        let runner = runner ~environment ~sw ~support ~posted ~invalidations () in
        let selected, scope =
          bootstrap ~mirror_absent:false (Uri.of_string "https://localhost:1")
        in
        let clock = Eio.Stdenv.clock environment in
        let version =
          Logseq_db_types.Asset_descriptor.version
            ~checksum:(Logseq_sync_effect_runner.Asset_codec.checksum "file")
            ~file_type:"bin"
          |> Result.get_ok
        in
        let source_file = Filename.concat support "source.bin" in
        let missing =
          asset_run
            runner
            ~clock
            ~posted
            selected.next
            scope
            "missing"
            (Core.Put_asset_file
               { asset = scope.graph_id
               ; version
               ; file = "unavailable-stage"
               ; maximum_plaintext_bytes = 32
               })
        in
        Alcotest.(check bool)
          "missing staging file"
          true
          (missing = Error Core.Asset_missing_source);
        Out_channel.with_open_bin source_file (fun out -> output_string out "file");
        let file = asset_stage runner ~clock ~posted selected.next scope source_file in
        let put core scope operation maximum_plaintext_bytes version =
          asset_run
            runner
            ~clock
            ~posted
            core
            scope
            operation
            (Core.Put_asset_file
               { asset = scope.Core.graph_id; version; file; maximum_plaintext_bytes })
        in
        Alcotest.(check bool)
          "size bound before network"
          true
          (put selected.next scope "size" 3 version = Error Core.Asset_size_rejected);
        let locked, locked_scope =
          Core_contract.selected_graph Core_contract.encrypted_graph
        in
        let locked_file =
          asset_stage runner ~clock ~posted locked.next locked_scope source_file
        in
        Alcotest.(check bool)
          "locked graph never sends plaintext"
          true
          (asset_run
             runner
             ~clock
             ~posted
             locked.next
             locked_scope
             "locked"
             (Core.Put_asset_file
                { asset = locked_scope.graph_id
                ; version
                ; file = locked_file
                ; maximum_plaintext_bytes = 32
                })
           = Error Core.Asset_locked);
        let requested =
          Core.step
            selected.next
            (Core.Asset_requested
               { scope
               ; operation = "cancelled"
               ; action =
                   Core.Put_asset_file
                     { asset = scope.graph_id
                     ; version
                     ; file
                     ; maximum_plaintext_bytes = 32
                     }
               })
        in
        let cancelled =
          Core.step
            requested.next
            (Core.Asset_requested
               { scope
               ; operation = "cancel"
               ; action = Core.Cancel_asset_operation "cancelled"
               })
        in
        Alcotest.(check bool)
          "cancelled intent never uploads"
          true
          (List.exists
             (function
               | Core.Publish (Core.Asset_finished output) ->
                 output.request.operation = "cancelled"
                 && output.result = Error Core.Asset_cancelled
               | _ -> false)
             cancelled.effects);
        let incorrect =
          Logseq_db_types.Asset_descriptor.version
            ~checksum:(Logseq_sync_effect_runner.Asset_codec.checksum "oops")
            ~file_type:"bin"
          |> Result.get_ok
        in
        Alcotest.(check bool)
          "changed source rejected"
          true
          (match put selected.next scope "changed" 32 incorrect with
           | Error (Core.Asset_invalid_content _) -> true
           | _ -> false);
        Runner.shutdown runner)))
;;

let scenarios =
  scenarios
  @ [ Alcotest.test_case
        "asset PUT bytes and metadata"
        `Quick
        (asset_upload ~status:200 ~refresh:false)
    ; Alcotest.test_case
        "asset PUT token refresh"
        `Quick
        (asset_upload ~status:200 ~refresh:true)
    ; Alcotest.test_case
        "asset PUT revoked access"
        `Quick
        (asset_upload ~status:403 ~refresh:false)
    ; Alcotest.test_case
        "asset PUT size rejection"
        `Quick
        (asset_upload ~status:413 ~refresh:false)
    ; Alcotest.test_case
        "asset PUT transient failure"
        `Quick
        (asset_upload ~status:503 ~refresh:false)
    ; Alcotest.test_case "asset PUT validates staging" `Quick asset_upload_source
    ]
;;

let asset_upload_admission () =
  with_support (fun support ->
    Eio_main.run (fun environment ->
      Eio.Switch.run (fun sw ->
        let active = ref 0
        and maximum = ref 0 in
        let acquire _ =
          incr active;
          maximum := max !maximum !active;
          Eio.Fiber.yield ();
          decr active;
          Error "offline"
        in
        let posted = ref [] in
        let t =
          runner ~acquire ~environment ~sw ~support ~posted ~invalidations:(ref 0) ()
        in
        let selected, scope =
          bootstrap ~mirror_absent:false (Uri.of_string "https://localhost")
        in
        let clock = Eio.Stdenv.clock environment in
        let source_file = Filename.concat support "pending.bin" in
        Out_channel.with_open_bin source_file (fun out -> output_string out "file");
        let file = asset_stage t ~clock ~posted selected.next scope source_file in
        let version =
          Logseq_db_types.Asset_descriptor.version
            ~checksum:(Logseq_sync_effect_runner.Asset_codec.checksum "file")
            ~file_type:"bin"
          |> Result.get_ok
        in
        posted := [];
        let core =
          List.fold_left
            (fun core index ->
               asset_submit
                 t
                 core
                 scope
                 ("upload-" ^ string_of_int index)
                 (Core.Put_asset_file
                    { asset = scope.graph_id; version; file; maximum_plaintext_bytes = 4 }))
            selected.next
            [ 1; 2; 3 ]
        in
        wait clock (fun () -> List.length !posted = 3);
        let _, outputs = asset_collect t core !posted in
        Alcotest.(check int) "one upload holds source and wire buffers" 1 !maximum;
        Alcotest.(check bool)
          "failed transfer releases admission"
          true
          (List.length outputs = 3
           && List.for_all (fun output -> Result.is_error output.Core.result) outputs);
        Runner.shutdown t)))
;;

let scenarios =
  scenarios
  @ [ Alcotest.test_case "asset upload resource admission" `Quick asset_upload_admission ]
;;

let asset_download_budget maximum_plaintext_bytes expected_entered () =
  let module Asset = Logseq_db_types.Asset_descriptor in
  with_support (fun support ->
    Eio_main.run (fun environment ->
      Eio.Switch.run (fun sw ->
        let entered = ref 0 in
        let gate, release = Eio.Promise.create () in
        let acquire _ =
          incr entered;
          Eio.Promise.await gate;
          Error "offline"
        in
        let posted = ref [] in
        let t =
          runner ~acquire ~environment ~sw ~support ~posted ~invalidations:(ref 0) ()
        in
        let version =
          Asset.version ~checksum:(String.make 64 '0') ~file_type:"bin" |> Result.get_ok
        in
        let cores =
          List.init 5 (fun index ->
            let selected, scope =
              bootstrap
                ~mirror_absent:false
                ~user_id:("fixture-" ^ string_of_int index)
                (Uri.of_string "https://localhost")
            in
            asset_submit
              t
              selected.next
              scope
              ("download-" ^ string_of_int index)
              (Core.Fetch_asset
                 { asset = scope.graph_id; version; maximum_plaintext_bytes }))
        in
        for _ = 1 to 10 do
          Eio.Fiber.yield ()
        done;
        let initial = !entered in
        Eio.Promise.resolve release ();
        wait (Eio.Stdenv.clock environment) (fun () -> List.length !posted = 5);
        let outputs =
          List.concat_map (fun core -> snd (asset_collect t core !posted)) cores
        in
        Alcotest.(check int)
          "scopes share bounded download and byte permits"
          expected_entered
          initial;
        Alcotest.(check int) "all failed requests release admission" 5 !entered;
        Alcotest.(check int)
          "all completions pass through reducer outputs"
          5
          (List.length outputs);
        Runner.shutdown t)))
;;

let asset_download_admission = asset_download_budget 4 3

let scenarios =
  scenarios
  @ [ Alcotest.test_case
        "asset download resource admission"
        `Quick
        asset_download_admission
    ]
;;

let shared_asset_byte_budget = asset_download_budget 16777216 2

let scenarios =
  scenarios
  @ [ Alcotest.test_case "shared asset byte budget" `Quick shared_asset_byte_budget ]
;;

let shared_asset_codec_admission () =
  let module Asset = Logseq_db_types.Asset_descriptor in
  let plaintext = "file" in
  let version =
    Asset.version
      ~checksum:(Logseq_sync_effect_runner.Asset_codec.checksum plaintext)
      ~file_type:"bin"
    |> Result.get_ok
  in
  let envelope =
    Transit_native.Transit.Json.to_string
      (Transit_core.Json.Array
         [ Binary (String.make 12 'i'); Binary (String.make 20 'c') ])
  in
  let wire =
    response
      ~headers:(Printf.sprintf "Content-Length: %d\r\n" (String.length envelope))
      envelope
  in
  let report =
    with_peer
      [ case wire ]
      (fun ~environment ~sw ~support ~origin ->
         let gate, release = Eio.Promise.create () in
         let active = ref 0
         and maximum = ref 0
         and encrypted = ref false
         and decrypted = ref false in
         let use flag result =
           flag := true;
           incr active;
           maximum := max !maximum !active;
           Eio.Promise.await gate;
           decr active;
           result
         in
         let crypto_dependency =
           Runner.crypto
             ~encrypt_aes_gcm:(fun ~key:_ ~plaintext:_ ->
               use encrypted (Error "fixture encode failure"))
             ~decrypt_aes_gcm:(fun ~key:_ ~iv:_ ~ciphertext:_ ->
               use decrypted (Ok plaintext))
           |> Result.get_ok
         in
         let secrets_dependency =
           Runner.secrets
             ~unlock_private_key:
               (fun
                 ~managed_sync_origin:_ ~user_id:_ ~password:_ ~private_key_package:_ ->
               Ok ())
             ~unlock_graph_key:
               (fun
                 ~managed_sync_origin:_ ~user_id:_ ~encrypted_graph_key:_ ->
               Ok (String.make 32 'k'))
             ~load_wrapped_graph_key:(fun ~managed_sync_origin:_ ~user_id:_ ~graph_id:_ ->
               Ok "wrapped")
             ~verify_and_save_wrapped_graph_key:
               (fun
                 ~managed_sync_origin:_ ~user_id:_ ~graph_id:_ ~encrypted_graph_key:_ ->
               Ok ())
             ~delete_account_secrets:(fun ~managed_sync_origin:_ ~user_id:_ -> Ok ())
           |> Result.get_ok
         in
         let posted = ref [] in
         let t =
           runner
             ~crypto_dependency
             ~secrets_dependency
             ~environment
             ~sw
             ~support
             ~posted
             ~invalidations:(ref 0)
             ()
         in
         let before, instruction = Runner_contract.cached_key_effect ~origin () in
         Runner.submit t instruction;
         wait (Eio.Stdenv.clock environment) (fun () -> !posted <> []);
         let unlocked = (Core.step before.next (List.hd !posted)).next in
         let context = Core.asset_context unlocked |> Option.get in
         let scope = context.scope in
         let source_file = Filename.concat support "pending.bin" in
         Out_channel.with_open_bin source_file (fun out -> output_string out plaintext);
         let clock = Eio.Stdenv.clock environment in
         let file = asset_stage t ~clock ~posted unlocked scope source_file in
         posted := [];
         let uploading =
           asset_submit
             t
             unlocked
             scope
             "codec-upload"
             (Core.Put_asset_file
                { asset = scope.graph_id; version; file; maximum_plaintext_bytes = 4 })
         in
         wait clock (fun () -> !encrypted);
         let downloading =
           asset_submit
             t
             uploading
             scope
             "codec-download"
             (Core.Fetch_asset
                { asset = scope.graph_id; version; maximum_plaintext_bytes = 4 })
         in
         wait (Eio.Stdenv.clock environment) (fun () ->
           Sys.file_exists (Filename.concat support "report"));
         Eio.Promise.resolve release ();
         wait (Eio.Stdenv.clock environment) (fun () -> List.length !posted = 2);
         let _, outputs = asset_collect t downloading !posted in
         Alcotest.(check int)
           "both codec completions reach reducer"
           2
           (List.length outputs);
         Alcotest.(check int) "GET and PUT share one codec permit" 1 !maximum;
         Alcotest.(check bool)
           "failed encoding releases the permit for decoding"
           true
           !decrypted;
         Runner.shutdown t)
  in
  check_retired report
;;

let scenarios =
  scenarios
  @ [ Alcotest.test_case
        "shared asset codec admission"
        `Quick
        shared_asset_codec_admission
    ]
;;

(* Provider refresh contracts execute through reducer-created HTTP operations. *)
let submitted_authentication_policy
      statuses
      expected_result
      expected_tokens
      expected_invalidated
      ()
  =
  let acquired = ref []
  and invalidated = ref [] in
  let tokens = Queue.create () in
  Queue.add "token-1" tokens;
  Queue.add "token-2" tokens;
  let report =
    with_peer
      (List.map (fun status -> case (response ~status "x")) statuses)
      (fun ~environment ~sw ~support ~origin ->
         let posted = ref [] in
         let acquire _ =
           match Queue.take_opt tokens with
           | Some token ->
             acquired := token :: !acquired;
             Ok token
           | None -> Error "no token"
         in
         let t =
           runner
             ~acquire
             ~on_invalidate:(fun token -> invalidated := token :: !invalidated)
             ~environment
             ~sw
             ~support
             ~posted
             ~invalidations:(ref 0)
             ()
         in
         let requested, _ = bootstrap origin in
         let runnable =
           List.find_map
             (function
               | Core.Run (Core.Request (_, Core.Fetch_snapshot_baseline _) as runnable)
                 -> Some runnable
               | _ -> None)
             requested.effects
           |> Option.get
         in
         Runner.submit t runnable;
         wait (Eio.Stdenv.clock environment) (fun () -> completed !posted <> None);
         Alcotest.(check bool)
           "typed authentication outcome"
           true
           (match completed !posted, expected_result with
            | Some (Ok ()), None -> true
            | Some (Error (Core.Effect_failed message)), Some expected ->
              String.equal message expected
            | _ -> false);
         List.iter (fun event -> ignore (Core.step requested.next event)) !posted;
         Runner.shutdown t)
  in
  Alcotest.(check (list string))
    "bounded acquired token attempts"
    expected_tokens
    (List.rev !acquired);
  Alcotest.(check (list string))
    "only first unauthorized token invalidated"
    expected_invalidated
    (List.rev !invalidated);
  check_retired report
;;

let scenarios =
  scenarios
  @ [ Alcotest.test_case
        "authenticated operation retries one unauthorized response"
        `Quick
        (submitted_authentication_policy
           [ 401; 200 ]
           None
           [ "token-1"; "token-2" ]
           [ "token-1" ])
    ; Alcotest.test_case
        "authenticated operation surfaces second unauthorized response"
        `Quick
        (submitted_authentication_policy
           [ 401; 401 ]
           (Some "Authentication failed.")
           [ "token-1"; "token-2" ]
           [ "token-1" ])
    ; Alcotest.test_case
        "authenticated operation does not retry forbidden response"
        `Quick
        (submitted_authentication_policy
           [ 403 ]
           (Some "Authorization failed.")
           [ "token-1" ]
           [])
    ]
;;

(* Semaphore ownership belongs to runner I/O: cancellation while a reservation is
   incomplete must release the units already acquired, before the first request ends. *)
let cancelled_asset_byte_wait_releases_partial_reservation () =
  with_support (fun support ->
    Eio_main.run (fun environment ->
      Eio.Switch.run (fun sw ->
        let entered = ref 0 in
        let gate, release = Eio.Promise.create () in
        let acquire _ =
          incr entered;
          Eio.Promise.await gate;
          Error "offline"
        in
        let posted = ref [] in
        let t =
          runner ~acquire ~environment ~sw ~support ~posted ~invalidations:(ref 0) ()
        in
        let selected, scope =
          bootstrap ~mirror_absent:false (Uri.of_string "https://localhost")
        in
        let version =
          Logseq_db_types.Asset_descriptor.version
            ~checksum:(String.make 64 'a')
            ~file_type:"bin"
          |> Result.get_ok
        in
        let action maximum_plaintext_bytes =
          Core.Fetch_asset { asset = scope.graph_id; version; maximum_plaintext_bytes }
        in
        let first =
          asset_submit t selected.next scope "holding-48MiB" (action (24 * 1024 * 1024))
        in
        wait (Eio.Stdenv.clock environment) (fun () -> !entered = 1);
        let waiting =
          asset_submit t first scope "waiting-for-48MiB" (action (24 * 1024 * 1024))
        in
        for _ = 1 to 10 do
          Eio.Fiber.yield ()
        done;
        let cancelled =
          asset_submit
            t
            waiting
            scope
            "cancel-waiter"
            (Core.Cancel_asset_operation "waiting-for-48MiB")
        in
        wait (Eio.Stdenv.clock environment) (fun () -> List.length !posted >= 2);
        let admitted =
          asset_submit t cancelled scope "using-returned-16MiB" (action (8 * 1024 * 1024))
        in
        wait (Eio.Stdenv.clock environment) (fun () -> !entered = 2);
        Alcotest.(check int)
          "cancelled partial reservation immediately admits another request"
          2
          !entered;
        Eio.Promise.resolve release ();
        wait (Eio.Stdenv.clock environment) (fun () -> List.length !posted = 4);
        ignore (asset_collect t admitted !posted);
        Runner.shutdown t)))
;;

let scenarios =
  scenarios
  @ [ Alcotest.test_case
        "asset cancellation releases partial byte reservation"
        `Quick
        cancelled_asset_byte_wait_releases_partial_reservation
    ]
;;

(* Two legal 40 MiB reservations must not divide the 64 MiB pool and deadlock. *)
let weighted_asset_reservations_make_progress () =
  let bytes = "file" in
  let version =
    Logseq_db_types.Asset_descriptor.version
      ~checksum:(Logseq_sync_effect_runner.Asset_codec.checksum bytes)
      ~file_type:"bin"
    |> Result.get_ok
  in
  let headers = "Content-Length: 4\r\n" in
  let report =
    with_peer
      [ case (response ~headers bytes); case (response ~headers bytes) ]
      (fun ~environment ~sw ~support ~origin ->
         let entered = ref 0 in
         let gate, release = Eio.Promise.create () in
         let acquire _ =
           incr entered;
           Eio.Promise.await gate;
           Ok "fixture-token"
         in
         let posted = ref [] in
         let t =
           runner ~acquire ~environment ~sw ~support ~posted ~invalidations:(ref 0) ()
         in
         let selected, scope = bootstrap ~mirror_absent:false origin in
         let action =
           Core.Fetch_asset
             { asset = scope.graph_id
             ; version
             ; maximum_plaintext_bytes = 20 * 1024 * 1024
             }
         in
         let first = asset_submit t selected.next scope "weighted-first" action in
         wait (Eio.Stdenv.clock environment) (fun () -> !entered = 1);
         let second = asset_submit t first scope "weighted-second" action in
         for _ = 1 to 10 do
           Eio.Fiber.yield ()
         done;
         Alcotest.(check int)
           "one entire reservation enters while the second waits"
           1
           !entered;
         Eio.Promise.resolve release ();
         wait (Eio.Stdenv.clock environment) (fun () -> List.length !posted = 2);
         let _, outputs = asset_collect t second !posted in
         Alcotest.(check int)
           "both weighted TLS downloads complete"
           2
           (List.length outputs);
         Alcotest.(check bool)
           "weighted reservations release for the next request"
           true
           (List.for_all
              (fun output ->
                 match output.Core.result with
                 | Ok (Core.Asset_downloaded _) -> true
                 | _ -> false)
              outputs);
         Alcotest.(check int) "second request proceeds after the first" 2 !entered;
         Runner.shutdown t)
  in
  check_retired report
;;

let scenarios =
  scenarios
  @ [ Alcotest.test_case
        "weighted asset reservations make TLS progress"
        `Quick
        weighted_asset_reservations_make_progress
    ]
;;

(* Migrated downloaded cache scenarios. *)
module Cache_asset = Logseq_db_types.Asset_descriptor
module Cache_codec = Logseq_sync_effect_runner.Asset_codec

let cache_version bytes =
  Cache_asset.version ~checksum:(Cache_codec.checksum bytes) ~file_type:"png"
  |> Result.get_ok
;;

let cache_response bytes =
  case
    (response
       ~headers:(Printf.sprintf "Content-Length: %d\r\n" (String.length bytes))
       bytes)
;;

let cache_selection ?(user = "fixture") ?(selected_graph : Core.graph = graph) origin =
  let initial =
    Core.config ~managed_sync_origin:origin ~limits:(Core_contract.limits ())
    |> Result.get_ok
    |> Core.initial
    |> Result.get_ok
  in
  let authenticated =
    Core.step initial (Core.Account_authenticated { user_id = Some user })
  in
  let catalog =
    List.find_map
      (function
        | Core.Run (Core.Request (ticket, Core.Fetch_catalog _)) ->
          Some
            (Core.step
               authenticated.next
               (Core.Runner_completed (Core.Completion (ticket, Ok [ selected_graph ]))))
        | _ -> None)
      authenticated.effects
    |> Option.get
  in
  let selected = Core.step catalog.next (Core.Graph_selected selected_graph.graph_id) in
  selected.next, Core.admitted_graph_scope selected.next |> Option.get
;;

let with_downloaded_cache ?(budget = 8L) ?(pending_budget = 8L) cases test =
  let report =
    with_peer cases (fun ~environment ~sw ~support ~origin ->
      let posted = ref []
      and invalidations = ref 0 in
      let create () =
        runner
          ~asset_cache_budget_bytes:budget
          ~asset_maximum_file_bytes:8
          ~asset_pending_budget_bytes:pending_budget
          ~environment
          ~sw
          ~support
          ~posted
          ~invalidations
          ()
      in
      let active = ref (create ()) in
      Fun.protect
        ~finally:(fun () -> Runner.shutdown !active)
        (fun () ->
           let sequence = ref 0 in
           let request core scope action =
             incr sequence;
             asset_run
               !active
               ~clock:(Eio.Stdenv.clock environment)
               ~posted
               core
               scope
               ("cache-" ^ string_of_int !sequence)
               action
           in
           let reopen () =
             Runner.shutdown !active;
             active := create ()
           in
           test support origin request reopen))
  in
  check_retired report
;;

let cache_download request core (scope : Core.graph_scope) bytes =
  match
    request
      core
      scope
      (Core.Fetch_asset
         { asset = scope.graph_id
         ; version = cache_version bytes
         ; maximum_plaintext_bytes = 8
         })
  with
  | Ok (Core.Asset_downloaded handle) -> handle
  | _ -> Alcotest.fail "cache download did not produce a controlled resource"
;;

let cache_lookup request core (scope : Core.graph_scope) bytes =
  match
    request core scope (Core.Check_asset_cache (scope.graph_id, cache_version bytes))
  with
  | Ok (Core.Asset_cached handle) -> handle
  | _ -> Alcotest.fail "cache lookup did not resolve through reducer output"
;;

let cache_retain request core scope handle =
  match request core scope (Core.Retain_asset_file handle) with
  | Ok (Core.Asset_retained (Some resource)) -> resource
  | _ -> Alcotest.fail "cache resource retention failed"
;;

let cache_release request core scope handle =
  Runner_contract.cache_unit (request core scope (Core.Release_asset_file handle))
;;

let test_downloaded_cache_restart () =
  with_downloaded_cache
    [ cache_response "file" ]
    (fun _ origin request reopen ->
       let core, scope = cache_selection origin in
       let handle = cache_download request core scope "file" in
       let lease, path = cache_retain request core scope handle in
       Alcotest.(check string) "published bytes" "file" (read_file path);
       cache_release request core scope lease;
       reopen ();
       Alcotest.(check bool)
         "restart restores verified file"
         true
         (Option.is_some (cache_lookup request core scope "file")))
;;

let test_downloaded_cache_corruption () =
  with_downloaded_cache
    [ cache_response "file" ]
    (fun _ origin request reopen ->
       let core, scope = cache_selection origin in
       let handle = cache_download request core scope "file" in
       let _, path = cache_retain request core scope handle in
       Runner_contract.cache_unit (request core scope Core.Close_asset_scope);
       Out_channel.with_open_bin path (fun output -> output_string output "bad!");
       reopen ();
       Alcotest.(check bool)
         "corrupt file not ready"
         true
         (cache_lookup request core scope "file" = None))
;;

let test_downloaded_cache_eligibility () =
  with_downloaded_cache
    [ cache_response "bad!" ]
    (fun _ origin request _ ->
       let core, scope = cache_selection origin in
       Alcotest.(check bool)
         "checksum verified before publication"
         true
         (request
            core
            scope
            (Core.Fetch_asset
               { asset = scope.graph_id
               ; version = cache_version "file"
               ; maximum_plaintext_bytes = 8
               })
          = Error Core.Asset_checksum_mismatch);
       Alcotest.(check bool)
         "no corrupt record"
         true
         (cache_lookup request core scope "file" = None))
;;

let test_downloaded_cache_leases () =
  with_downloaded_cache
    ~budget:4L
    [ cache_response "file"; cache_response "next"; cache_response "next" ]
    (fun support origin request _ ->
       let core, scope = cache_selection origin in
       let source = Filename.concat support "picker.bin" in
       Out_channel.with_open_bin source (fun output -> output_string output "source");
       let staged, _, _ = Runner_contract.cache_stage (request core scope) source in
       let stage_lease, staged_path =
         request core scope (Core.Retain_staged_file staged)
         |> Runner_contract.retained_value
       in
       cache_release request core scope stage_lease;
       let handle = cache_download request core scope "file" in
       let lease, path = cache_retain request core scope handle in
       cache_release request core scope handle;
       Alcotest.(check bool)
         "live renderer pins file"
         true
         (request
            core
            scope
            (Core.Fetch_asset
               { asset = scope.graph_id
               ; version = cache_version "next"
               ; maximum_plaintext_bytes = 8
               })
          = Error Core.Asset_storage_full);
       Alcotest.(check bool) "renderer path remains" true (Sys.file_exists path);
       cache_release request core scope lease;
       ignore (cache_download request core scope "next");
       Alcotest.(check bool)
         "unpinned LRU evicted"
         true
         (cache_lookup request core scope "file" = None);
       Alcotest.(check bool)
         "LRU does not evict pending import"
         true
         (Sys.file_exists staged_path))
;;

let test_downloaded_cache_filename () =
  with_downloaded_cache
    [ cache_response "file" ]
    (fun _ origin request reopen ->
       let core, scope = cache_selection origin in
       let handle = cache_download request core scope "file" in
       let lease, path = cache_retain request core scope handle in
       Alcotest.(check bool)
         "download carries its type"
         true
         (Filename.check_suffix path ".png");
       cache_release request core scope lease;
       cache_release request core scope handle;
       reopen ();
       let handle = cache_lookup request core scope "file" |> Option.get in
       let lease, path = cache_retain request core scope handle in
       Alcotest.(check bool)
         "restart preserves typed filename"
         true
         (Filename.check_suffix path ".png");
       cache_release request core scope lease;
       cache_release request core scope handle)
;;

let test_downloaded_cache_legacy_cleanup () =
  with_downloaded_cache
    [ cache_response "file" ]
    (fun _ origin request reopen ->
       let core, scope = cache_selection origin in
       let handle = cache_download request core scope "file" in
       let _, path = cache_retain request core scope handle in
       let legacy = Filename.chop_extension path ^ ".bin" in
       Sys.rename path legacy;
       Runner_contract.cache_unit (request core scope Core.Close_asset_scope);
       reopen ();
       let restored = cache_lookup request core scope "file" in
       Alcotest.(check bool) "untyped data file evicted" false (Sys.file_exists legacy);
       Alcotest.(check bool) "manifest without typed data removed" true (restored = None))
;;

let test_downloaded_cache_isolation () =
  with_downloaded_cache
    [ cache_response "file"; cache_response "next" ]
    (fun _ origin request _ ->
       let first, first_scope = cache_selection origin in
       let second, second_scope = cache_selection ~user:"another" origin in
       ignore (cache_download request first first_scope "file");
       Alcotest.(check bool)
         "accounts isolated"
         true
         (cache_lookup request second second_scope "file" = None);
       ignore (cache_download request second second_scope "next");
       Runner_contract.cache_unit (request first first_scope Core.Delete_graph_assets);
       Alcotest.(check bool)
         "deletion leaves other account"
         true
         (Option.is_some (cache_lookup request second second_scope "next")))
;;

let test_downloaded_cache_account_cleanup () =
  with_downloaded_cache
    [ cache_response "file"; cache_response "file"; cache_response "file" ]
    (fun _ origin request _ ->
       let other_report =
         with_peer
           [ cache_response "file" ]
           (fun ~environment:_ ~sw:_ ~support:_ ~origin:other_origin ->
              let first = cache_selection origin in
              let another_graph =
                cache_selection
                  ~selected_graph:{ graph with graph_id = Core_contract.other_graph_id }
                  origin
              in
              let other_user = cache_selection ~user:"other" origin in
              let other_origin = cache_selection other_origin in
              List.iter
                (fun (core, scope) ->
                   let handle = cache_download request core scope "file" in
                   cache_release request core scope handle;
                   Runner_contract.cache_unit (request core scope Core.Close_asset_scope))
                [ first; another_graph; other_user; other_origin ];
              let first_core, first_scope = first in
              Runner_contract.cache_unit
                (request first_core first_scope Core.Delete_account_assets);
              Runner_contract.cache_unit
                (request first_core first_scope Core.Delete_account_assets);
              List.iter
                (fun (core, scope) ->
                   Alcotest.(check bool)
                     "all account graphs removed"
                     true
                     (cache_lookup request core scope "file" = None))
                [ first; another_graph ];
              List.iter
                (fun (core, scope) ->
                   Alcotest.(check bool)
                     "other namespace preserved"
                     true
                     (Option.is_some (cache_lookup request core scope "file")))
                [ other_user; other_origin ])
       in
       check_retired other_report)
;;

let test_downloaded_cache_graph_cleanup () =
  with_downloaded_cache
    [ cache_response "file"; cache_response "file" ]
    (fun _ origin request _ ->
       let first, scope = cache_selection origin in
       let another, another_scope =
         cache_selection
           ~selected_graph:{ graph with graph_id = Core_contract.other_graph_id }
           origin
       in
       List.iter
         (fun (core, scope) -> ignore (cache_download request core scope "file"))
         [ first, scope; another, another_scope ];
       Runner_contract.cache_unit (request first scope Core.Delete_graph_assets);
       Runner_contract.cache_unit (request first scope Core.Delete_graph_assets);
       Alcotest.(check bool)
         "selected graph removed"
         true
         (cache_lookup request first scope "file" = None);
       Alcotest.(check bool)
         "other graph retained"
         true
         (Option.is_some (cache_lookup request another another_scope "file")))
;;

let scenarios =
  scenarios
  @ List.map
      (fun (name, test) -> Alcotest.test_case name `Quick test)
      [ "cache restart via submit", test_downloaded_cache_restart
      ; "cache corruption via submit", test_downloaded_cache_corruption
      ; "cache publication eligibility via submit", test_downloaded_cache_eligibility
      ; "cache leases and budget via submit", test_downloaded_cache_leases
      ; "cache downloaded filename via submit", test_downloaded_cache_filename
      ; "cache legacy bin cleanup via submit", test_downloaded_cache_legacy_cleanup
      ; "cache account isolation via submit", test_downloaded_cache_isolation
      ; "cache account cleanup via submit", test_downloaded_cache_account_cleanup
      ; "cache graph cleanup via submit", test_downloaded_cache_graph_cleanup
      ]
;;

(* These failures execute transport framing/deadlines, not Core policy. There is
   no pure reducer boundary that can parse coalesced TLS bytes or own DNS/socket
   cancellation. All fixtures enter through public Runner.transport/submit. *)
let test_early_frame_backpressure () =
  let message = {|{"type":"changed","t":42}|} in
  let wire = String.concat "" (List.init 129 (fun _ -> frame 1 message)) in
  let report =
    with_peer
      [ case ~ws:true wire ]
      (fun ~environment ~sw ~support ~origin ->
         let posted = ref []
         and invalidations = ref 0 in
         let t = runner ~environment ~sw ~support ~posted ~invalidations () in
         let start = websocket_start origin in
         let scope =
           match start with
           | Core.Start_websocket r -> r.scope
           | _ -> assert false
         in
         Runner.submit t start;
         let count () =
           List.length
             (List.filter
                (function
                  | Core.Websocket_message _ -> true
                  | _ -> false)
                !posted)
         in
         wait (Eio.Stdenv.clock environment) (fun () ->
           count () = 129
           || List.exists
                (function
                  | Core.Websocket_closed _ -> true
                  | _ -> false)
                !posted);
         Alcotest.(check int)
           "all small coalesced messages delivered without rejection"
           129
           (count ());
         Runner.submit t (websocket_close scope);
         wait (Eio.Stdenv.clock environment) (fun () ->
           List.exists
             (function
               | Core.Websocket_closed _ -> true
               | _ -> false)
             !posted);
         Runner.shutdown t)
  in
  check_retired report
;;

let test_segmented_backpressure_control () =
  let message = {|{"type":"changed","t":42}|} in
  ws_test
    ~messages:129
    ~terminal:false
    ~segment:26
    (String.concat "" (List.init 129 (fun _ -> frame 1 message)))
    ()
;;

let delayed_case ?(tls_delay = 0.) ?(response_delay = 0.) wire =
  match case wire with
  | `Assoc fields ->
    `Assoc
      (("tls_delay", `Float tls_delay)
       :: ("response_delay", `Float response_delay)
       :: fields)
  | _ -> assert false
;;

let test_tls_slow_legal_handshake () =
  let report =
    with_peer
      [ delayed_case ~tls_delay:1.1 (response "x") ]
      (fun ~environment ~sw ~support ~origin ->
         let posted = ref []
         and invalidations = ref 0 in
         let t = runner ~environment ~sw ~support ~posted ~invalidations () in
         Runner.submit t (operation ~download:false origin);
         wait (Eio.Stdenv.clock environment) (fun () ->
           Option.is_some (completed !posted));
         Alcotest.(check bool)
           "valid handshake beyond one second succeeds"
           true
           (Result.is_ok (Option.get (completed !posted)));
         Runner.shutdown t)
  in
  check_retired report
;;

let test_phased_response_deadline () =
  let report =
    with_peer
      [ delayed_case ~tls_delay:0.3 ~response_delay:0.9 (response "x") ]
      (fun ~environment ~sw ~support ~origin ->
         let clock = scaled_clock (Eio.Stdenv.clock environment) 20. in
         let network =
           delayed_network (Eio.Stdenv.net environment) (fun () ->
             Eio.Time.sleep clock 10.)
         in
         let posted = ref []
         and invalidations = ref 0 in
         let t =
           runner ~network ~clock ~environment ~sw ~support ~posted ~invalidations ()
         in
         let before = Eio.Time.now clock in
         Runner.submit t (operation ~download:false origin);
         wait (Eio.Stdenv.clock environment) (fun () ->
           Option.is_some (completed !posted));
         Alcotest.(check bool)
           "response retains its budget after independent dial and TLS"
           true
           (Result.is_ok (Option.get (completed !posted)));
         Alcotest.(check bool)
           "total operation legitimately exceeds old outer 30s"
           true
           (Eio.Time.now clock -. before > 30.);
         Runner.shutdown t)
  in
  check_retired report
;;

let test_shared_dial_deadline () =
  Runner_contract.with_support (fun support ->
    Eio_main.run (fun environment ->
      Eio.Switch.run (fun sw ->
        let clock = scaled_clock (Eio.Stdenv.clock environment) 30. in
        let attempts = ref 0 in
        let network =
          delayed_network (Eio.Stdenv.net environment) (fun () ->
            incr attempts;
            Eio.Time.sleep clock 100.)
        in
        let posted = ref []
        and invalidations = ref 0 in
        let t =
          runner ~network ~clock ~environment ~sw ~support ~posted ~invalidations ()
        in
        let before = Eio.Time.now clock in
        Runner.submit t (operation ~download:false (Uri.of_string "https://localhost:1"));
        wait (Eio.Stdenv.clock environment) (fun () -> Option.is_some (completed !posted));
        let elapsed = Eio.Time.now clock -. before in
        Alcotest.(check bool)
          "shared DNS/TCP window reaches 30s"
          true
          (elapsed >= 29. && elapsed < 33.);
        Alcotest.(check bool)
          "address fallback uses the shared remaining window"
          true
          (!attempts >= 2);
        Alcotest.(check bool)
          "dial deadline returns a transport failure"
          true
          (Result.is_error (Option.get (completed !posted)));
        Runner.shutdown t)))
;;

let test_tls_independent_deadline () =
  let report =
    with_peer
      [ `Assoc [ "stall_tls", `Bool true ] ]
      (fun ~environment ~sw ~support ~origin ->
         let clock = scaled_clock (Eio.Stdenv.clock environment) 20. in
         let posted = ref []
         and invalidations = ref 0 in
         let t = runner ~clock ~environment ~sw ~support ~posted ~invalidations () in
         let before = Eio.Time.now clock in
         Runner.submit t (operation ~download:false origin);
         wait (Eio.Stdenv.clock environment) (fun () ->
           Option.is_some (completed !posted));
         let elapsed = Eio.Time.now clock -. before in
         Alcotest.(check bool)
           "TLS has independent 10s window"
           true
           (elapsed >= 9. && elapsed < 13.);
         Alcotest.(check bool)
           "TLS timeout is a transport failure"
           true
           (Result.is_error (Option.get (completed !posted)));
         Runner.shutdown t)
  in
  check_retired report
;;

let test_redirect_response_budget_is_shared () =
  let report =
    with_peer
      [ delayed_case
          ~response_delay:0.9
          (response ~status:302 ~headers:"Content-Length: 1\r\nLocation: /next\r\n" "x")
      ; delayed_case ~response_delay:0.9 (response "x")
      ]
      (fun ~environment ~sw ~support ~origin ->
         let clock = scaled_clock (Eio.Stdenv.clock environment) 20. in
         let posted = ref []
         and invalidations = ref 0 in
         let t = runner ~clock ~environment ~sw ~support ~posted ~invalidations () in
         Runner.submit t (operation ~download:false origin);
         wait (Eio.Stdenv.clock environment) (fun () ->
           Option.is_some (completed !posted));
         Alcotest.(check bool)
           "redirect does not reset response deadline"
           true
           (Result.is_error (Option.get (completed !posted)));
         Runner.shutdown t)
  in
  check_retired report
;;

let scenarios =
  scenarios
  @ [ Alcotest.test_case
        "early frames drain bounded backpressure"
        `Quick
        test_early_frame_backpressure
    ; Alcotest.test_case
        "segmented early frames control"
        `Quick
        test_segmented_backpressure_control
    ; Alcotest.test_case
        "TLS legal slow handshake succeeds"
        `Quick
        test_tls_slow_legal_handshake
    ; Alcotest.test_case
        "dial TLS and response deadlines are independent"
        `Quick
        test_phased_response_deadline
    ; Alcotest.test_case
        "DNS TCP address attempts share dial deadline"
        `Quick
        test_shared_dial_deadline
    ; Alcotest.test_case
        "TLS independent ten second deadline"
        `Quick
        test_tls_independent_deadline
    ; Alcotest.test_case
        "redirect response deadline remains shared"
        `Quick
        test_redirect_response_budget_is_shared
    ]
;;

let test_backpressure_close_unblocks_full_event_sink () =
  let message = {|{"type":"changed","t":42}|} in
  let wire = String.concat "" (List.init 129 (fun _ -> frame 1 message)) in
  let report =
    with_peer
      [ case ~ws:true wire ]
      (fun ~environment ~sw ~support ~origin ->
         let sink = Eio.Stream.create 1 in
         let entered = ref false in
         let posted = ref []
         and invalidations = ref 0 in
         let t =
           runner
             ~environment
             ~sw
             ~support
             ~posted
             ~invalidations
             ~on_post:(fun event ->
               (match event with
                | Core.Websocket_message _ -> entered := true
                | _ -> ());
               Eio.Stream.add sink event)
             ()
         in
         let start = websocket_start origin in
         let scope =
           match start with
           | Core.Start_websocket r -> r.scope
           | _ -> assert false
         in
         Runner.submit t start;
         wait (Eio.Stdenv.clock environment) (fun () ->
           !entered
           || List.exists
                (function
                  | Core.Websocket_closed _ -> true
                  | _ -> false)
                !posted);
         Alcotest.(check bool) "consumer reached bounded sink before close" true !entered;
         let before = Eio.Time.now (Eio.Stdenv.clock environment) in
         Runner.submit t (websocket_close scope);
         Alcotest.(check bool)
           "close submit never joins on the event consumer"
           true
           (Eio.Time.now (Eio.Stdenv.clock environment) -. before < 0.1);
         Eio.Time.with_timeout_exn (Eio.Stdenv.clock environment) 3. (fun () ->
           let rec drain () =
             match Eio.Stream.take sink with
             | Core.Websocket_retired retired when retired = scope -> ()
             | _ -> drain ()
           in
           drain ());
         let callbacks = List.length !posted in
         Eio.Time.sleep (Eio.Stdenv.clock environment) 0.03;
         Alcotest.(check int)
           "retired owner cannot emit late callbacks"
           callbacks
           (List.length !posted);
         Runner.shutdown t)
  in
  check_retired report
;;

let test_message_callback_exception_retires_owner () =
  let report =
    with_peer
      [ case ~ws:true (frame 1 {|{"type":"changed","t":42}|}) ]
      (fun ~environment ~sw ~support ~origin ->
         let calls = ref 0 in
         let posted = ref []
         and invalidations = ref 0 in
         let t =
           runner
             ~environment
             ~sw
             ~support
             ~posted
             ~invalidations
             ~on_post:(function
               | Core.Websocket_message _ ->
                 incr calls;
                 failwith "fixture callback failure"
               | _ -> ())
             ()
         in
         Runner.submit t (websocket_start origin);
         wait (Eio.Stdenv.clock environment) (fun () ->
           List.exists
             (function
               | Core.Websocket_closed _ -> true
               | _ -> false)
             !posted);
         Alcotest.(check int) "failing callback executes once" 1 !calls;
         Runner.shutdown t)
  in
  check_retired report
;;

type socket_peaks =
  { mutable sockets : int
  ; mutable socket_peak : int
  ; mutable dials : int
  ; mutable dial_peak : int
  ; mutable owner_peak : int
  ; mutable attempts : int
  }

let metered_network ?(fail_first = false) network peaks =
  let module Socket = struct
    type t =
      { flow : [ `Generic | `Unix ] Eio.Net.stream_socket_ty Eio.Resource.t
      ; retire : unit -> unit
      }

    type tag =
      [ `Generic
      | `Unix
      ]

    let read_methods = []
    let single_read t = Eio.Flow.single_read t.flow
    let single_write t = Eio.Flow.single_write t.flow
    let copy t ~src = Eio.Flow.copy src t.flow
    let shutdown t = Eio.Flow.shutdown t.flow
    let close t = Fun.protect ~finally:t.retire (fun () -> Eio.Resource.close t.flow)
  end
  in
  let module Network = struct
    type t = Eio_unix.Net.t

    type tag =
      [ `Generic
      | `Unix
      ]

    let listen net ~reuse_addr ~reuse_port ~backlog ~sw address =
      Eio.Net.listen net ~reuse_addr ~reuse_port ~backlog ~sw address
    ;;

    let connect net ~sw address =
      peaks.attempts <- peaks.attempts + 1;
      peaks.dials <- peaks.dials + 1;
      peaks.dial_peak <- max peaks.dial_peak peaks.dials;
      peaks.owner_peak <- max peaks.owner_peak (peaks.dials + peaks.sockets);
      let flow =
        Fun.protect
          ~finally:(fun () -> peaks.dials <- peaks.dials - 1)
          (fun () -> Eio.Net.connect net ~sw address)
      in
      peaks.sockets <- peaks.sockets + 1;
      peaks.socket_peak <- max peaks.socket_peak peaks.sockets;
      peaks.owner_peak <- max peaks.owner_peak (peaks.dials + peaks.sockets);
      let released = ref false in
      let retire () =
        if not !released
        then (
          released := true;
          peaks.sockets <- peaks.sockets - 1)
      in
      Eio.Switch.on_release sw retire;
      if fail_first && peaks.attempts = 1 then raise End_of_file;
      Eio.Resource.T (Socket.{ flow; retire }, Eio.Net.Pi.stream_socket (module Socket))
    ;;

    let datagram_socket net ~reuse_addr ~reuse_port ~sw address =
      Eio.Net.datagram_socket net ~reuse_addr ~reuse_port ~sw address
    ;;

    let getaddrinfo net ~service host = Eio.Net.getaddrinfo net ~service host
    let getnameinfo net address = Eio.Net.getnameinfo net address
  end
  in
  Eio.Resource.T (network, Eio.Net.Pi.network (module Network))
;;

let test_runtime_single_owner_and_scope_switch ?(eof = false) ?(reset = false) () =
  let peer_case wire =
    match case ~ws:true wire with
    | `Assoc fields ->
      `Assoc (("frame_delay", `Float 0.1) :: ("close_delay", `Float 0.1) :: fields)
    | _ -> assert false
  in
  let first_case =
    match peer_case (if eof then "" else frame 8 "\x03\xe8") with
    | `Assoc fields ->
      `Assoc
        (("eof", `Bool eof) :: ("reset", `Bool reset) :: List.remove_assoc "eof" fields)
    | _ -> assert false
  in
  let report =
    with_peer
      [ first_case; peer_case ""; peer_case "" ]
      (fun ~environment ~sw ~support ~origin ->
         let peaks =
           { sockets = 0
           ; socket_peak = 0
           ; dials = 0
           ; dial_peak = 0
           ; owner_peak = 0
           ; attempts = 0
           }
         in
         let network = metered_network (Eio.Stdenv.net environment) peaks in
         let events = Eio.Stream.create 2 in
         let posted = ref []
         and invalidations = ref 0 in
         let t =
           runner
             ~network
             ~environment
             ~sw
             ~support
             ~posted
             ~invalidations
             ~on_post:(Eio.Stream.add events)
             ()
         in
         let start = websocket_start origin in
         let first =
           match start with
           | Core.Start_websocket r -> r.scope
           | _ -> assert false
         in
         let core = ref (websocket_core first) in
         let retry = ref None
         and retirement_seen = ref false
         and opened = ref []
         and running = ref true in
         let apply event =
           let transition = Core.step !core event in
           core := transition.next;
           (match event with
            | Core.Websocket_opened s -> opened := s :: !opened
            | _ -> ());
           List.iter
             (function
               | Core.Run runnable ->
                 (match runnable with
                  | Core.Schedule_timer timer when timer.delay_seconds < 30. ->
                    retry := Some timer
                  | _ -> ());
                 Runner.submit t runnable
               | Core.Delegate (Core.Inspect_mirror r) ->
                 Eio.Fiber.fork ~sw (fun () ->
                   Eio.Stream.add events (Core.Mirror_inspected (Core.Mirror_available r)))
               | Core.Delegate (Core.Attach_graph r) ->
                 let sync =
                   Logseq_overlay_db.Types.sync_view
                     ~token:
                       (Logseq_overlay_db.Types.sync_token_of_string
                          "sync-token:v1:singleton"
                        |> Result.get_ok)
                     ~checkpoint:
                       (Logseq_overlay_db.Types.Server_cursor.of_int64 0L |> Result.get_ok)
                     ~submissions:[]
                 in
                 Eio.Fiber.fork ~sw (fun () ->
                   Eio.Stream.add events (Core.Graph_attached { scope = r.scope; sync }))
               | _ -> ())
             transition.effects;
           match event with
           | Core.Websocket_retired scope when scope = first -> retirement_seen := true
           | _ -> ()
         in
         Eio.Fiber.fork ~sw (fun () ->
           while !running do
             let event = Eio.Stream.take events in
             apply event
           done);
         Runner.submit t start;
         wait (Eio.Stdenv.clock environment) (fun () ->
           Option.is_some !retry || !retirement_seen);
         Alcotest.(check bool)
           "real peer Close schedules reducer retry"
           true
           (Option.is_some !retry);
         let timer = Option.get !retry in
         Eio.Stream.add events (Core.Timer_elapsed timer.id);
         Eio.Stream.add events (Core.Timer_elapsed timer.id);
         wait (Eio.Stdenv.clock environment) (fun () ->
           List.exists
             (fun (s : Core.connection_scope) ->
                s.connection_generation > first.connection_generation)
             !opened);
         Eio.Stream.add
           events
           (Core.Foreground_changed { foreground = true; lifecycle_generation = 1L });
         Eio.Stream.add
           events
           (Core.Foreground_changed { foreground = true; lifecycle_generation = 2L });
         Eio.Stream.add events (Core.Graph_selected first.graph.graph_id);
         wait (Eio.Stdenv.clock environment) (fun () ->
           List.exists
             (fun (s : Core.connection_scope) ->
                s.graph.graph_generation > first.graph.graph_generation)
             !opened);
         Eio.Stream.add events (Core.Websocket_opened first);
         Eio.Stream.add
           events
           (Core.Websocket_closed (first, Core.Recoverable_close None));
         Eio.Stream.add
           events
           (Core.Websocket_message
              ( first
              , Logseq_sync_pure_reducer.Sync_protocol.Server.Changed
                  { t = Core_contract.server_cursor_of_int 42 } ));
         Eio.Time.sleep (Eio.Stdenv.clock environment) 0.03;
         Runner.shutdown t;
         running := false;
         Eio.Stream.add events Core.Shutdown;
         wait (Eio.Stdenv.clock environment) (fun () ->
           peaks.sockets = 0 && peaks.dials = 0);
         Alcotest.(check int) "actual live TCP socket peak" 1 peaks.socket_peak;
         Alcotest.(check int) "connected plus opening socket peak" 1 peaks.owner_peak;
         Alcotest.(check int) "actual simultaneous connect attempt peak" 1 peaks.dial_peak;
         Alcotest.(check int)
           "exactly initial retry and scope replacement dial"
           3
           peaks.attempts)
  in
  check_retired report
;;

let scenarios =
  scenarios
  @ [ Alcotest.test_case
        "close drains full callback sink without join deadlock"
        `Quick
        test_backpressure_close_unblocks_full_event_sink
    ; Alcotest.test_case
        "callback exception retires WebSocket owner"
        `Quick
        test_message_callback_exception_retires_owner
    ; Alcotest.test_case
        "real Runner Core singleton and scope switch"
        `Quick
        test_runtime_single_owner_and_scope_switch
    ]
;;

let test_runtime_duplicate_opening_has_one_socket () =
  let report =
    with_peer
      [ case ~ws:true "" ]
      (fun ~environment ~sw ~support ~origin ->
         let peaks =
           { sockets = 0
           ; socket_peak = 0
           ; dials = 0
           ; dial_peak = 0
           ; owner_peak = 0
           ; attempts = 0
           }
         in
         let network = metered_network (Eio.Stdenv.net environment) peaks in
         let posted = ref []
         and invalidations = ref 0 in
         let t = runner ~network ~environment ~sw ~support ~posted ~invalidations () in
         let start = websocket_start origin in
         let scope =
           match start with
           | Core.Start_websocket r -> r.scope
           | _ -> assert false
         in
         let core = ref (websocket_core scope) in
         Runner.submit t start;
         List.iter
           (fun generation ->
              let tr =
                Core.step
                  !core
                  (Core.Foreground_changed
                     { foreground = true; lifecycle_generation = generation })
              in
              core := tr.next;
              List.iter
                (function
                  | Core.Run r -> Runner.submit t r
                  | _ -> ())
                tr.effects)
           [ 1L; 2L ];
         Eio.Time.sleep (Eio.Stdenv.clock environment) 0.15;
         Alcotest.(check int)
           "repeat foreground during opening creates one actual socket"
           1
           peaks.socket_peak;
         Alcotest.(check int) "one actual dial attempt admitted" 1 peaks.attempts;
         Runner.shutdown t)
  in
  check_retired report
;;

let scenarios =
  scenarios
  @ [ Alcotest.test_case
        "duplicate opening actual socket peak"
        `Quick
        test_runtime_duplicate_opening_has_one_socket
    ]
;;

let test_upgrade_failure_is_typed_terminal status () =
  let cases =
    List.init (if status = 401 then 2 else 1) (fun _ -> case (response ~status "x"))
  in
  let report =
    with_peer cases (fun ~environment ~sw ~support ~origin ->
      let posted = ref []
      and invalidations = ref 0 in
      let t = runner ~environment ~sw ~support ~posted ~invalidations () in
      Runner.submit t (websocket_start origin);
      wait (Eio.Stdenv.clock environment) (fun () ->
        List.exists
          (function
            | Core.Websocket_closed _ -> true
            | _ -> false)
          !posted);
      Alcotest.(check bool)
        "authentication failure cannot enter network retry"
        true
        (List.exists
           (function
             | Core.Websocket_closed (_, Core.Authentication_failure _) -> true
             | _ -> false)
           !posted);
      Runner.shutdown t)
  in
  check_retired report
;;

let scenarios =
  scenarios
  @ [ Alcotest.test_case
        "real Runner Core recovers peer EOF"
        `Quick
        (test_runtime_single_owner_and_scope_switch ~eof:true)
    ; Alcotest.test_case
        "real Runner Core recovers TCP reset"
        `Quick
        (test_runtime_single_owner_and_scope_switch ~eof:true ~reset:true)
    ; Alcotest.test_case
        "Upgrade 401 typed terminal failure"
        `Quick
        (test_upgrade_failure_is_typed_terminal 401)
    ; Alcotest.test_case
        "Upgrade 403 typed terminal failure"
        `Quick
        (test_upgrade_failure_is_typed_terminal 403)
    ]
;;

let test_shutdown_does_not_wait_for_stopped_event_consumer ~during_open () =
  let config =
    match case ~ws:true (if during_open then "" else frame 8 "\x03\xe8") with
    | `Assoc fields -> `Assoc (("frame_delay", `Float 0.1) :: fields)
    | _ -> assert false
  in
  let report =
    with_peer [ config ] (fun ~environment ~sw:_ ~support ~origin ->
      let clock = Eio.Stdenv.clock environment in
      let result =
        Eio.Time.with_timeout clock 2. (fun () ->
          Eio.Switch.run (fun owner ->
            let sink = Eio.Stream.create 1 in
            if during_open then Eio.Stream.add sink Core.Local_feed_acknowledged;
            let entered = ref false in
            let posted = ref []
            and invalidations = ref 0 in
            let t =
              runner
                ~environment
                ~sw:owner
                ~support
                ~posted
                ~invalidations
                ~on_post:(fun event ->
                  (match event with
                   | Core.Websocket_opened _ when during_open -> entered := true
                   | Core.Websocket_closed _ when not during_open -> entered := true
                   | _ -> ());
                  Eio.Stream.add sink event)
                ()
            in
            Runner.submit t (websocket_start origin);
            wait clock (fun () -> !entered);
            Runner.shutdown t);
          Ok ())
      in
      Alcotest.(check bool)
        "shutdown joins without draining the stopped consumer's sink"
        true
        (Result.is_ok result))
  in
  check_retired report
;;

let scenarios =
  scenarios
  @ [ Alcotest.test_case
        "shutdown cancels blocked open callback"
        `Quick
        (test_shutdown_does_not_wait_for_stopped_event_consumer ~during_open:true)
    ; Alcotest.test_case
        "shutdown cancels blocked terminal callback"
        `Quick
        (test_shutdown_does_not_wait_for_stopped_event_consumer ~during_open:false)
    ]
;;

let test_failed_dial_retires_allocated_socket_before_fallback () =
  let report =
    with_peer
      [ `Assoc [ "stall_tls", `Bool true ]; case (response "x") ]
      (fun ~environment ~sw ~support ~origin ->
         let peaks =
           { sockets = 0
           ; socket_peak = 0
           ; dials = 0
           ; dial_peak = 0
           ; owner_peak = 0
           ; attempts = 0
           }
         in
         let network =
           metered_network ~fail_first:true (Eio.Stdenv.net environment) peaks
         in
         let posted = ref []
         and invalidations = ref 0 in
         let t = runner ~network ~environment ~sw ~support ~posted ~invalidations () in
         Runner.submit t (operation ~download:false origin);
         wait (Eio.Stdenv.clock environment) (fun () ->
           Option.is_some (completed !posted));
         Alcotest.(check bool)
           "real fallback response succeeds"
           true
           (Result.is_ok (Option.get (completed !posted)));
         Alcotest.(check int)
           "failed backend allocation retires before next dial"
           1
           peaks.owner_peak;
         Alcotest.(check int) "all actual allocated sockets released" 0 peaks.sockets;
         Runner.shutdown t)
  in
  check_retired report
;;

let scenarios =
  scenarios
  @ [ Alcotest.test_case
        "failed dial retires allocated socket before fallback"
        `Quick
        test_failed_dial_retires_allocated_socket_before_fallback
    ]
;;

(* DNS-SD is executed by the public Runner transport, not Core. RFC7050's
   IPv4-only name supplies a real absent-family reply. Only DNS is external:
   every resulting TCP candidate is redirected to the independent loopback peer. *)
let test_absent_dns_family_preserves_dial_budget () =
  let report =
    with_peer
      [ case (response "x") ]
      (fun ~environment ~sw ~support ~origin ->
         let real_clock = Eio.Stdenv.clock environment in
         let addresses =
           Eio.Time.with_timeout_exn real_clock 5. (fun () ->
             Eio.Net.getaddrinfo_stream
               ~service:"443"
               (Eio.Stdenv.net environment)
               "ipv4only.arpa")
         in
         Alcotest.(check bool)
           "fixture requires IPv4 without IPv6; DNS64 would invalidate this regression"
           true
           (addresses <> []
            && List.for_all
                 (function
                   | `Tcp (ip, _) ->
                     Eio.Net.Ipaddr.fold ~v4:(fun _ -> true) ~v6:(fun _ -> false) ip
                   | `Unix _ -> false)
                 addresses);
         let clock = scaled_clock real_clock 10. in
         let attempts = ref 0 in
         let port = Uri.port origin |> Option.get in
         let network =
           delayed_network
             ~destination:(fun _ -> `Tcp (Eio.Net.Ipaddr.V4.loopback, port))
             (Eio.Stdenv.net environment)
             (fun () -> incr attempts)
         in
         let posted = ref []
         and invalidations = ref 0 in
         let t =
           runner ~clock ~network ~environment ~sw ~support ~posted ~invalidations ()
         in
         Fun.protect
           ~finally:(fun () -> Runner.shutdown t)
           (fun () ->
              Runner.submit
                t
                (operation ~download:false (Uri.with_host origin (Some "ipv4only.arpa")));
              wait (Eio.Stdenv.clock environment) (fun () ->
                Option.is_some (completed !posted));
              Alcotest.(check bool)
                "usable family completes HTTPS before shared deadline expires"
                true
                (Result.is_ok (Option.get (completed !posted)));
              Alcotest.(check int) "one loopback connection" 1 !attempts))
  in
  check_retired report
;;

let test_unanswered_dns_obeys_shared_dial_deadline () =
  with_support (fun support ->
    Eio_main.run (fun environment ->
      Eio.Switch.run (fun sw ->
        let clock = scaled_clock (Eio.Stdenv.clock environment) 30. in
        let attempts = ref 0 in
        let network =
          delayed_network (Eio.Stdenv.net environment) (fun () ->
            incr attempts;
            failwith "unanswered DNS must not dial")
        in
        let posted = ref []
        and invalidations = ref 0 in
        let t =
          runner ~clock ~network ~environment ~sw ~support ~posted ~invalidations ()
        in
        Fun.protect
          ~finally:(fun () -> Runner.shutdown t)
          (fun () ->
             let host =
               Printf.sprintf
                 "logseq-deadline-%d-%d.local"
                 (Unix.getpid ())
                 (Random.bits ())
             in
             let before = Eio.Time.now clock in
             Runner.submit
               t
               (operation ~download:false (Uri.of_string ("https://" ^ host)));
             wait (Eio.Stdenv.clock environment) (fun () ->
               Option.is_some (completed !posted));
             let elapsed = Eio.Time.now clock -. before in
             Alcotest.(check bool)
               "unanswered families share the unchanged thirty-second window"
               true
               (elapsed >= 29. && elapsed < 33.);
             Alcotest.(check bool)
               "no addresses produce an explicit transport failure"
               true
               (Result.is_error (Option.get (completed !posted)));
             Alcotest.(check int) "DNS timeout opens no socket" 0 !attempts))))
;;

let scenarios =
  scenarios
  @ [ Alcotest.test_case
        "absent DNS family preserves shared dial budget"
        `Quick
        test_absent_dns_family_preserves_dial_budget
    ; Alcotest.test_case
        "unanswered DNS obeys shared dial deadline"
        `Quick
        test_unanswered_dns_obeys_shared_dial_deadline
    ]
;;
