(* Extend an isolated warm-start fixture through public storage and Core/Effect_runner APIs only.
   Arguments: SUPPORT_ROOT PNG_DIRECTORY [JOURNAL_PAGE_UUID]. *)
module G = Logseq_db_types.Graph_types
module Storage = Logseq_db_storage.Logseq_sqlite_storage
module Session = Logseq_db_storage.Storage_session
module Runner = Logseq_sync_effect_runner.Effect_runner
module Codec = Logseq_sync_effect_runner.Asset_codec
module Asset = Logseq_db_types.Asset_descriptor
module Core = Logseq_sync_pure_reducer.Core

let get = function
  | Ok value -> value
  | Error _ -> failwith "Synthetic Timeline image fixture preparation failed"
;;

let support = Sys.argv.(1)
let graph = "60000000-0000-4000-8000-000000000001"
let graph_id = get (G.Uuid.of_string graph)

let root =
  Datascript.Lookup_ref ("block/uuid", Uuid "80000000-0000-4000-a000-000000000001")
;;

let now = Unix.localtime (Unix.time ())

let title =
  Printf.sprintf "%04d-%02d-%02d" (now.tm_year + 1900) (now.tm_mon + 1) now.tm_mday
;;

let page_uuid =
  if Array.length Sys.argv > 3
  then Sys.argv.(3)
  else
    Printf.sprintf
      "00000001-%04d-%02d%02d-0000-000000000000"
      (now.tm_year + 1900)
      (now.tm_mon + 1)
      now.tm_mday
;;

let page = Datascript.Lookup_ref ("block/uuid", Uuid page_uuid)

let connection =
  get
    (Storage.open_database
       (Filename.concat
          support
          ("logseq-db-worker/synced-graphs/" ^ graph ^ "/db.sqlite")))
;;

let before = get (Storage.restore_database connection)

let session =
  Session.create
    ~tail:(Datascript.Storage.restore_tail_groups (Storage.datascript_storage connection))
    ~callbacks:(Storage.connection_callbacks connection)
;;

(* A disposable HTTPS endpoint keeps the warm fixture's real cache identity while
   routing asset connections to loopback. Production DNS may resolve the origin;
   no production server receives a request and no trust store changes. *)
let rec wait_process pid =
  try snd (Unix.waitpid [] pid) with
  | Unix.Unix_error (Unix.EINTR, _, _) -> wait_process pid
;;

let with_asset_publication publish =
  let directory = Filename.temp_file "journal-image-assets-" "" in
  Sys.remove directory;
  Unix.mkdir directory 0o700;
  let certificate = Filename.concat directory "certificate.pem"
  and private_key = Filename.concat directory "private-key.pem" in
  let server_pid = ref None in
  Fun.protect
    ~finally:(fun () ->
      Option.iter
        (fun pid ->
           (try Unix.kill pid Sys.sigterm with
            | Unix.Unix_error (Unix.ESRCH, _, _) -> ());
           ignore (wait_process pid))
        !server_pid;
      Sys.readdir directory
      |> Array.iter (fun name -> Sys.remove (Filename.concat directory name));
      Unix.rmdir directory)
    (fun () ->
       let log =
         Unix.openfile
           (Filename.concat directory "server.log")
           [ Unix.O_CREAT; Unix.O_WRONLY ]
           0o600
       in
       Fun.protect
         ~finally:(fun () -> Unix.close log)
         (fun () ->
            let args =
              [| "openssl"
               ; "req"
               ; "-x509"
               ; "-newkey"
               ; "rsa:2048"
               ; "-nodes"
               ; "-keyout"
               ; private_key
               ; "-out"
               ; certificate
               ; "-days"
               ; "1"
               ; "-subj"
               ; "/CN=api.logseq.io"
               ; "-addext"
               ; "subjectAltName=DNS:api.logseq.io"
              |]
            in
            let pid = Unix.create_process "openssl" args Unix.stdin log log in
            if wait_process pid <> Unix.WEXITED 0
            then failwith "Fixture TLS certificate failed";
            let server =
              {|import http.server, pathlib, ssl, sys
images = pathlib.Path(sys.argv[1])
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        prefix = '/assets/60000000-0000-4000-8000-000000000001/92000000-0000-4000-8000-'
        if not self.path.startswith(prefix) or self.headers.get('Authorization') != 'Bearer image-fixture':
            self.send_error(404); return
        names = {'000000000001.png':'red.png', '000000000002.png':'blue.png', '000000000003.png':'green.png'}
        name = names.get(self.path[len(prefix):])
        if name is None:
            self.send_error(404); return
        data = (images/name).read_bytes()
        self.send_response(200)
        self.send_header('Content-Type', 'application/octet-stream')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def log_message(self, *_): pass
server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(sys.argv[2], sys.argv[3])
server.socket = context.wrap_socket(server.socket, server_side=True)
print(server.server_port, flush=True)
server.serve_forever()
|}
            in
            let read_port, write_port = Unix.pipe () in
            let pid =
              Unix.create_process
                "python3"
                [| "python3"
                 ; "-B"
                 ; "-c"
                 ; server
                 ; Sys.argv.(2)
                 ; certificate
                 ; private_key
                |]
                Unix.stdin
                write_port
                log
            in
            server_pid := Some pid;
            Unix.close write_port;
            let channel = Unix.in_channel_of_descr read_port in
            let port =
              Fun.protect
                ~finally:(fun () -> close_in channel)
                (fun () -> input_line channel |> int_of_string)
            in
            let cert =
              In_channel.with_open_bin certificate In_channel.input_all
              |> X509.Certificate.decode_pem
              |> get
            in
            Eio_main.run (fun environment ->
              Eio.Switch.run (fun sw ->
                let real_network = Eio.Stdenv.net environment in
                let module Network = struct
                  type t = unit
                  type tag = [ `Generic ]

                  let listen _ ~reuse_addr:_ ~reuse_port:_ ~backlog:_ ~sw:_ _ =
                    failwith "Fixture network cannot listen"
                  ;;

                  let connect () ~sw = function
                    | `Tcp (_, 443) ->
                      (Eio.Net.connect
                         ~sw
                         real_network
                         (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
                        :> tag Eio.Net.stream_socket_ty Eio.Resource.t)
                    | _ -> failwith "Fixture network rejects nonlocal destinations"
                  ;;

                  let datagram_socket _ ~reuse_addr:_ ~reuse_port:_ ~sw:_ _ =
                    failwith "Fixture network cannot use datagrams"
                  ;;

                  let getaddrinfo () ~service host =
                    if host <> "api.logseq.io" || service <> "443"
                    then failwith "Fixture network rejects external DNS";
                    [ `Tcp (Eio.Net.Ipaddr.V4.loopback, port) ]
                  ;;

                  let getnameinfo _ _ = failwith "Fixture network cannot reverse DNS"
                end
                in
                let network = Eio.Resource.T ((), Eio.Net.Pi.network (module Network)) in
                let tasks = Queue.create ()
                and posted = Queue.create () in
                let dependencies =
                  Runner.dependencies
                    ~runtime:
                      (Runner.runtime
                         ~fork:(fun ~sw:_ task -> Queue.add task tasks)
                         ~sleep:(fun _ -> ())
                       |> get)
                    ~transport:
                      (Runner.transport
                         ~tls_authenticator:
                           (Runner.tls_authenticator
                              (X509.Authenticator.chain_of_trust
                                 ~time:(fun () -> Ptime.of_float_s (Unix.time ()))
                                 [ cert ]))
                         ~network
                         ~clock:(Eio.Stdenv.clock environment)
                         ~websocket_liveness:Runner.Disabled
                       |> get)
                    ~local_store:
                      (Runner.local_store
                         ~asset_cache_budget_bytes:268435456L
                         ~asset_maximum_file_bytes:(8 * 1024 * 1024)
                         ~application_support_directory:support
                         ()
                       |> get)
                    ~artifact_store:
                      (Runner.artifact_store
                         ~staging_directory:(Filename.concat directory "snapshot-staging")
                       |> get)
                    ~secrets:
                      (Runner.secrets
                         ~unlock_private_key:
                           (fun
                             ~managed_sync_origin:_
                             ~user_id:_
                             ~password:_
                             ~private_key_package:_ -> Error "unused")
                         ~unlock_graph_key:
                           (fun
                             ~managed_sync_origin:_ ~user_id:_ ~encrypted_graph_key:_ ->
                           Error "unused")
                         ~load_wrapped_graph_key:
                           (fun
                             ~managed_sync_origin:_ ~user_id:_ ~graph_id:_ ->
                           Error (Runner.Wrapped_graph_key_unavailable "unused"))
                         ~verify_and_save_wrapped_graph_key:
                           (fun
                             ~managed_sync_origin:_
                             ~user_id:_
                             ~graph_id:_
                             ~encrypted_graph_key:_ -> Error "unused")
                         ~delete_account_secrets:(fun ~managed_sync_origin:_ ~user_id:_ ->
                           Ok ())
                       |> get)
                    ~crypto:
                      (Runner.crypto
                         ~encrypt_aes_gcm:(fun ~key:_ ~plaintext:_ -> Error "unused")
                         ~decrypt_aes_gcm:(fun ~key:_ ~iv:_ ~ciphertext:_ ->
                           Error "unused")
                       |> get)
                    ~id_token_provider:
                      (Runner.id_token_provider
                         ~acquire:(fun _ -> Ok "image-fixture")
                         ~invalidate:(fun _ ~token:_ -> ()))
                  |> get
                in
                let runner =
                  Runner.create ~sw dependencies ~post:(fun event ->
                    Queue.add event posted)
                  |> get
                in
                Fun.protect
                  ~finally:(fun () -> Runner.shutdown runner)
                  (fun () ->
                     let origin = Uri.of_string "https://api.logseq.io" in
                     let initial =
                       Core.config
                         ~managed_sync_origin:origin
                         ~limits:
                           (Core.limits
                              ~maximum_response_bytes:
                                Logseq_db_types.Limits.maximum_response_bytes
                              ~maximum_artifact_bytes:(8 * 1024 * 1024)
                              ~submission_batch_size:32
                            |> get)
                       |> get
                       |> Core.initial
                       |> get
                     in
                     let authenticated =
                       Core.step
                         initial
                         (Core.Account_authenticated { user_id = Some "user-1" })
                     in
                     let graph : Core.graph =
                       { graph_id
                       ; name = "Image fixture"
                       ; schema = { major = 65; minor = 33; exact = true }
                       ; encrypted = false
                       }
                     in
                     let catalog =
                       List.find_map
                         (function
                           | Core.Run (Core.Request (ticket, Core.Fetch_catalog _)) ->
                             Some
                               (Core.step
                                  authenticated.next
                                  (Core.Runner_completed
                                     (Core.Completion (ticket, Ok [ graph ]))))
                           | _ -> None)
                         authenticated.effects
                       |> Option.get
                     in
                     let state =
                       ref (Core.step catalog.next (Core.Graph_selected graph_id)).next
                     in
                     let scope = Core.admitted_graph_scope !state |> Option.get in
                     let consume outputs effects =
                       List.fold_left
                         (fun outputs -> function
                            | Core.Run runnable ->
                              Runner.submit runner runnable;
                              outputs
                            | Core.Publish (Core.Asset_finished output) ->
                              output :: outputs
                            | _ -> outputs)
                         outputs
                         effects
                     in
                     let rec pump outputs =
                       match Queue.take_opt tasks with
                       | Some task ->
                         task ();
                         pump outputs
                       | None ->
                         (match Queue.take_opt posted with
                          | None -> List.rev outputs
                          | Some event ->
                            let transition = Core.step !state event in
                            state := transition.next;
                            pump (consume outputs transition.effects))
                     in
                     let sequence = ref 0 in
                     let request action =
                       incr sequence;
                       let transition =
                         Core.step
                           !state
                           (Core.Asset_requested
                              { scope
                              ; operation = "image-" ^ string_of_int !sequence
                              ; action
                              })
                       in
                       state := transition.next;
                       match pump (consume [] transition.effects) with
                       | [ output ] -> get output.Core.result
                       | _ -> failwith "Fixture asset request did not complete"
                     in
                     publish (fun ~asset ~version ~bytes ->
                       let handle =
                         match
                           request
                             (Core.Fetch_asset
                                { asset
                                ; version
                                ; maximum_plaintext_bytes = String.length bytes
                                })
                         with
                         | Core.Asset_downloaded handle -> handle
                         | _ -> failwith "Fixture asset download failed"
                       in
                       let lease, path =
                         match request (Core.Retain_asset_file handle) with
                         | Core.Asset_retained (Some resource) -> resource
                         | _ -> failwith "Fixture asset lease failed"
                       in
                       if In_channel.with_open_bin path In_channel.input_all <> bytes
                       then failwith "Fixture asset cache bytes changed";
                       ignore (request (Core.Release_asset_file lease));
                       ignore (request (Core.Release_asset_file handle));
                       ignore (request Core.Close_asset_scope);
                       let restored =
                         match request (Core.Check_asset_cache (asset, version)) with
                         | Core.Asset_cached (Some handle) -> handle
                         | _ -> failwith "Fixture asset cache did not survive reopening"
                       in
                       let lease, restored_path =
                         match request (Core.Retain_asset_file restored) with
                         | Core.Asset_retained (Some resource) -> resource
                         | _ -> failwith "Fixture restored asset lease failed"
                       in
                       if restored_path <> path
                       then failwith "Fixture asset path changed after reopening";
                       ignore (request (Core.Release_asset_file lease));
                       ignore (request (Core.Release_asset_file restored));
                       path))))))
;;

type metadata =
  { color : string
  ; fileName : string
  }
[@@deriving yojson]

type metadata_list = metadata list [@@deriving yojson]

let metadata = ref []

let operations =
  with_asset_publication (fun publish ->
    [ "red"; "blue"; "green" ]
    |> List.mapi (fun index color ->
      let uuid = Printf.sprintf "92000000-0000-4000-8000-%012d" (index + 1) in
      let id = Datascript.Temp_id ("timeline-" ^ color) in
      let channel = open_in_bin (Filename.concat Sys.argv.(2) (color ^ ".png")) in
      let bytes =
        Fun.protect
          ~finally:(fun () -> close_in channel)
          (fun () -> really_input_string channel (in_channel_length channel))
      in
      let checksum = Codec.checksum bytes in
      let asset = get (G.Uuid.of_string uuid) in
      let version = get (Asset.version ~checksum ~file_type:"png") in
      let path = publish ~asset ~version ~bytes in
      metadata := { color; fileName = Filename.basename path } :: !metadata;
      Datascript.
        [ Add (id, "block/uuid", Uuid uuid)
        ; Add (id, "block/title", String (color ^ ".png"))
        ; Add (id, "block/parent", Ref_to root)
        ; Add (id, "block/page", Ref_to page)
        ; Add (id, "block/order", String (Printf.sprintf "a0A%06dU" index))
        ; Add (id, "block/tags", Ref_to (Ident "logseq.class/Asset"))
        ; Add (id, "logseq.property.asset/type", String "png")
        ; Add (id, "logseq.property.asset/checksum", String checksum)
        ; Add
            (id, "logseq.property.asset/size", Int64 (Int64.of_int (String.length bytes)))
        ; Add (id, "logseq.property.asset/width", Int64 640L)
        ; Add (id, "logseq.property.asset/height", Int64 420L)
        ; Add
            ( id
            , "logseq.property.asset/remote-metadata"
            , Map [ Keyword "checksum", String checksum; Keyword "type", String "png" ] )
        ; Add (root, "block/refs", Ref_to id)
        ])
    |> List.concat)
;;

let operations =
  operations
  @ Datascript.
      [ Add (root, "block/title", String "Timeline gallery fixture")
      ; Add (page, "block/name", String title)
      ; Add (page, "block/title", String title)
      ; Add
          ( page
          , "block/journal-day"
          , Int64
              (Int64.of_int
                 (((now.tm_year + 1900) * 10000) + ((now.tm_mon + 1) * 100) + now.tm_mday))
          )
      ]
;;

let staged = get (Session.stage_transact session ~authoritative_before:before operations)
let () = ignore (get (Session.commit_staged session staged))
let () = ignore (get (Session.close session))
let () = Yojson.Safe.to_channel stdout (metadata_list_to_yojson (List.rev !metadata))
let () = print_newline ()
