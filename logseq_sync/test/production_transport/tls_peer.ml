let rec remove path =
  match Unix.lstat path with
  | { st_kind = Unix.S_DIR; _ } ->
    Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | _ -> Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
;;

let with_directory callback =
  let path = Filename.temp_file "native-http-peer-" "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  Fun.protect ~finally:(fun () -> remove path) (fun () -> callback path)
;;

let peer =
  {python|
import base64, gzip, hashlib, json, os, select, socket, ssl, struct, subprocess, sys, time, threading
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
def observe_stalled_tls(raw, item, index):
  try:
    hello=b''
    while True:
      part=raw.recv(16384)
      if not part:
        item['closed']=True; break
      if not item['client_hello']:
        hello+=part
        if len(hello)>5:
          record_length=int.from_bytes(hello[3:5],'big')
          if len(hello)>=5+record_length and hello[0]==22 and hello[5]==1:
            item['client_hello']=True
            path=root+'/client-hello-'+str(index)
            with open(path+'.tmp','w') as f: f.write('ClientHello observed')
            os.replace(path+'.tmp',path)
  except (ConnectionResetError, BrokenPipeError): item['closed']=True
  except socket.timeout: pass
  finally: raw.close()
def serve_case(index,case,raw):
  raw.settimeout(2)
  if case.get('stall_tls'):
    item={'closed':False,'client_hello':False}; report.append(item)
    worker=threading.Thread(target=observe_stalled_tls,args=(raw,item,index),daemon=True)
    worker.start(); stalled.append(worker); return
  time.sleep(case.get('tls_delay',0))
  try: conn=ctx.wrap_socket(raw,server_side=True)
  except (ssl.SSLError,OSError):
    raw.close(); report.append({'closed':True,'frames':[]}); return
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
  wire=bytes.fromhex(case.get('wire','')).replace(b'{{ORIGIN}}', ('https://localhost:'+str(listener.getsockname()[1])).encode())
  if case.get('gzip_layers'):
    headers,body=wire.split(b'\r\n\r\n',1)
    for _ in range(case['gzip_layers']): body=gzip.compress(body)
    wire=headers+b'\r\n\r\n'+body
  if b'{{LENGTH}}' in wire:
    wire=wire.replace(b'{{LENGTH}}',str(len(wire.split(b'\r\n\r\n',1)[1])).encode())
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
  if case.get('body_delay'):
    header_end=wire.index(b'\r\n\r\n')+4
    conn.sendall(wire[:header_end]); time.sleep(case['body_delay']); wire=wire[header_end:]
  step=case.get('segment',len(wire) or 1)
  for offset in range(0,len(wire),step):
    try: conn.sendall(wire[offset:offset+step])
    except (ssl.SSLError, OSError): break
    if step<32: time.sleep(.0005)
  if case.get('corrupt_tls'): os.write(conn.fileno(), b'\x17\x03\x03\x00\x20' + bytes(32))
  with open(root+'/sent','w') as f: f.write('sent')
  if case.get('eof'):
    if case.get('reset'): conn.setsockopt(socket.SOL_SOCKET,socket.SO_LINGER,struct.pack('ii',1,0))
    conn.close(); report.append({'request':request.hex(),'closed':True,'frames':[]}); return
  closed=False; frames=[]; pending=b''
  deadline=time.monotonic()+case.get('lifetime',1.5)
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
        if opcode==1 and case.get('reply_text'):
          reply=case['reply_text']
          if case.get('reply_by_type'):
            message=json.loads(payload)
            if message.get('type')=='pull': assert message['since']==case['expected_pull_since']
            reply=case['reply_by_type'].get(message.get('type'),reply)
          conn.sendall(bytes.fromhex(reply))
        if opcode==8 and case.get('reply_close',True):
          time.sleep(case.get('close_delay',0))
          conn.sendall(bytes([0x88,len(payload)])+payload)
        if opcode==9 and case.get('reply_ping',False):
          conn.sendall(bytes([0x8a,len(payload)])+payload)
    except socket.timeout: continue
    except (ssl.SSLError,OSError): closed=True; break
  conn.close()
  report.append({'request':request.hex(),'closed':closed,'frames':frames})
try:
  for index,case in enumerate(cases):
    ready,_,_=select.select([listener,listener4],[],[],5)
    if not ready: raise RuntimeError('no client connection')
    raw,_ = ready[0].accept()
    if case.get('parallel'):
      worker=threading.Thread(target=serve_case,args=(index,case,raw),daemon=True)
      worker.start(); stalled.append(worker)
    else: serve_case(index,case,raw)
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
  with_directory (fun support ->
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
