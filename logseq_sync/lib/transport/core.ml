module Dsl = Sync_dsl.Core
module Protocol = Logseq_sync_protocol.Sync_protocol
module Native = Logseq_sync_native_transport.Websocket_eio
module Domain = Logseq_sync_native_transport.Transport_domain
module Cursor = Logseq_overlay_db.Types.Server_cursor

let ( let* ) = Result.bind

type scope =
  { check_current : unit -> (unit, Dsl.error) result
  ; admit_network : unit -> (unit, Dsl.error) result
  ; handoff : Dsl.resource_reference Rrbvec.t -> (unit, Dsl.error) result
  }

type socket =
  { activate : unit -> (unit, Dsl.error) result
  ; send : string -> (unit, Dsl.error) result
  ; stop : unit -> unit
  ; await_stopped : unit -> unit
  }

type connect_error =
  | Unauthorized
  | Failed of Dsl.error

type backend =
  { connect :
      token:string
      -> on_message:(string -> unit)
      -> on_close:(Dsl.connection_end -> unit)
      -> (socket, connect_error) result
  }

let native_error = function
  | Native.Unauthorized | Forbidden ->
    Dsl.Authentication_failure "WebSocket authorization failed"
  | Native.Authentication_failed _ ->
    Dsl.Authentication_failure "WebSocket TLS authentication failed"
  | Native.Protocol_failed message -> Dsl.Protocol_failure message
  | Native.Connection_failed { message; _ } -> Dsl.Network_failure message
;;

let native_end = function
  | Domain.Local_close -> Dsl.Locally_closed
  | Authentication_failure _ -> Dsl.Access_revoked "WebSocket authentication failed"
  | Protocol_failure message -> Dsl.Invalid_protocol message
  | Recoverable_close { message = None; _ } -> Dsl.Remote_closed
  | Recoverable_close { message = Some message; _ } -> Dsl.Network_lost message
;;

let native_backend
      ~sw
      ~clock
      ~network
      ~authenticator
      ~identity
      ~limits
      ~deadlines
      ~liveness
  =
  let uri =
    Uri.of_string identity.Dsl.origin
    |> fun origin ->
    Uri.with_scheme origin (Some "wss")
    |> fun origin -> Uri.with_path origin ("/sync/" ^ Uri.pct_encode identity.graph)
  in
  let clock = Logseq_sync_native_transport.Transport_time.monotonic clock in
  let liveness =
    match liveness with
    | Execute.Core.Peer_close_only -> Native.Disabled
    | Ping_pong { interval_seconds; timeout_seconds } ->
      Native.Ping_pong { interval_seconds; timeout_seconds }
  in
  { connect =
      (fun ~token ~on_message ~on_close ->
        let* socket =
          Native.connect
            ~sw
            ~clock
            ~network
            ~authenticator
            ~uri
            ~token
            ~liveness
            ~setup_seconds:deadlines.Execute.Core.setup_seconds
            ~tls_handshake_seconds:deadlines.tls_handshake_seconds
            ~http_response_seconds:deadlines.http_response_seconds
            ~maximum_frame_bytes:limits.Dsl.maximum_websocket_downlink_bytes
            ~on_message
            ~on_close:(fun reason -> on_close (native_end reason))
          |> Result.map_error (function
            | Native.Unauthorized -> Unauthorized
            | error -> Failed (native_error error))
        in
        Ok
          { activate =
              (fun () ->
                Native.activate socket ~on_open:(fun () -> ())
                |> Result.map_error native_error)
          ; send =
              (fun wire ->
                Native.send socket wire
                |> Result.map_error (fun _ -> Dsl.Network_failure "WebSocket send failed"))
          ; stop = (fun () -> Native.abort socket)
          ; await_stopped = (fun () -> Native.await_retired socket)
          })
  }
;;

type family =
  | Head
  | Pull
  | Push

type invocation =
  { cancellation : Eio.Cancel.t
  ; stopped : unit Eio.Promise.t
  }

type entry =
  { handle : Dsl.connection
  ; epoch : int64
  ; changed : Eio.Condition.t
  ; finished : unit Eio.Promise.t
  ; finish : unit Eio.Promise.u
  ; mutable invocations : invocation list
  ; mutable joining : (unit, Dsl.error) result Eio.Promise.t option
  ; mutable socket : socket option
  ; mutable setup : Eio.Cancel.t option
  ; mutable connecting : bool
  ; mutable retiring : bool
  ; mutable joined : bool
  ; mutable terminal : Dsl.error option
  ; mutable ending : Dsl.connection_end option
  ; mutable request : family option
  ; mutable response : Protocol.Server.message option
  ; mutable receiving : bool
  ; mutable notifications : Dsl.remote_message list
  ; mutable notification_bytes : int
  }

type t =
  { identity : Dsl.identity
  ; limits : Dsl.limits
  ; backend : backend
  ; token : epoch:int64 -> refresh:bool -> (string, Dsl.error) result
  ; fetch_snapshot :
      scope:scope -> epoch:int64 -> unit -> (Dsl.snapshot, Dsl.error) result
  ; snapshots : Snapshot.t option
  ; timeout : 'a. float -> (unit -> 'a) -> 'a
  ; connect_seconds : float
  ; response_seconds : float
  ; cleanup_seconds : float
  ; mutable epoch : int64 option
  ; mutable fenced_epoch : int64 option
  ; mutable generation : int64
  ; mutable entries : entry list
  ; mutable retired : Dsl.connection Weak.t list
  }

let same_identity t identity =
  if t.identity = identity then Ok () else Error (Dsl.Identity_mismatch "Transport owner")
;;

let pulse entry = Eio.Condition.broadcast entry.changed

let terminal entry error =
  if entry.terminal = None
  then (
    entry.terminal <- Some error;
    pulse entry)
;;

let error_of_end = function
  | Dsl.Remote_closed -> Dsl.Network_failure "WebSocket peer closed"
  | Network_lost message -> Dsl.Network_failure message
  | Access_revoked message -> Dsl.Authentication_failure message
  | Invalid_protocol message -> Dsl.Protocol_failure message
  | Locally_closed -> Dsl.Network_closed
;;

let check t scope (entry : entry) =
  let* () = scope.check_current () in
  match t.epoch with
  | None -> Error Dsl.Network_closed
  | Some epoch when epoch <> entry.epoch -> Error Dsl.Stale_context
  | Some _ when entry.retiring -> Error Dsl.Network_closed
  | Some _ ->
    (match entry.terminal with
     | None -> Ok ()
     | Some error -> Error error)
;;

let rec await entry ready =
  match ready () with
  | Some result -> result
  | None ->
    Eio.Condition.await_no_mutex entry.changed;
    await entry ready
;;

let message_bytes = function
  | Dsl.Remote_changed _ -> 32
  | Remote_error message -> String.length message
  | Connection_ended _ -> 32
;;

let notify t entry message =
  let bytes = message_bytes message in
  let rec add () =
    if entry.retiring || entry.joined
    then ()
    else (
      match List.rev entry.notifications, message with
      | Dsl.Remote_changed previous :: rest, Dsl.Remote_changed next ->
        let head =
          if Cursor.compare previous.through next.through >= 0 then previous else next
        in
        entry.notifications <- List.rev (Dsl.Remote_changed head :: rest);
        pulse entry
      | _
        when List.length entry.notifications < t.limits.maximum_messages
             && entry.notification_bytes <= t.limits.maximum_bytes - bytes ->
        entry.notifications <- entry.notifications @ [ message ];
        entry.notification_bytes <- entry.notification_bytes + bytes;
        pulse entry
      | _ ->
        Eio.Condition.await_no_mutex entry.changed;
        add ())
  in
  add ()
;;

let on_message t entry wire =
  if (not entry.retiring) && entry.terminal = None
  then
    if String.length wire > t.limits.maximum_websocket_downlink_bytes
    then
      terminal entry (Dsl.Protocol_failure "WebSocket message exceeds configured bound")
    else (
      match Protocol.decode_server_message wire with
      | Error _ -> terminal entry (Dsl.Protocol_failure "Invalid WebSocket message")
      | Ok (Protocol.Server.Hello _ as response) ->
        if entry.request = Some Head && entry.response = None
        then (
          entry.response <- Some response;
          pulse entry)
        else terminal entry (Dsl.Protocol_failure "Unmatched hello response")
      | Ok (Changed { t = through }) ->
        notify
          t
          entry
          (Dsl.Remote_changed
             { through; snapshot_available = true; expected_checksum = None })
      | Ok (Error _) ->
        terminal entry (Dsl.Protocol_failure "Remote server error");
        notify t entry (Dsl.Remote_error "Remote server error")
      | Ok (Pull_ok _ as response) ->
        if entry.request = Some Pull && entry.response = None
        then (
          entry.response <- Some response;
          pulse entry)
        else terminal entry (Dsl.Protocol_failure "Unmatched pull response")
      | Ok ((Tx_batch_ok _ | Tx_reject _) as response) ->
        if entry.request = Some Push && entry.response = None
        then (
          entry.response <- Some response;
          pulse entry)
        else terminal entry (Dsl.Protocol_failure "Unmatched submission response")
      | Ok (Online_users _ | Presence _ | Pong) -> ())
;;

let on_close entry ending =
  if (not entry.retiring) && entry.terminal = None
  then (
    entry.ending <- Some ending;
    terminal entry (error_of_end ending);
    pulse entry)
;;

let remember_retired t entry =
  let reference = Weak.create 1 in
  Weak.set reference 0 (Some entry.handle);
  t.retired <- reference :: List.filter (fun item -> Weak.check item 0) t.retired
;;

let with_invocation entry callback =
  let stopped, resolve = Eio.Promise.create () in
  Eio.Cancel.sub (fun cancellation ->
    let invocation = { cancellation; stopped } in
    entry.invocations <- invocation :: entry.invocations;
    Fun.protect
      ~finally:(fun () ->
        entry.invocations
        <- List.filter (fun current -> current != invocation) entry.invocations;
        Eio.Promise.resolve resolve ())
      callback)
;;

let stop_entry t entry =
  if entry.joined
  then Ok ()
  else
    Eio.Cancel.protect (fun () ->
      match entry.joining with
      | Some promise -> Eio.Promise.await promise
      | None ->
        let promise, resolve = Eio.Promise.create () in
        entry.joining <- Some promise;
        let result =
          entry.retiring <- true;
          entry.notifications <- [];
          entry.notification_bytes <- 0;
          pulse entry;
          Option.iter (fun context -> Eio.Cancel.cancel context Exit) entry.setup;
          let cleanup () =
            let invocations = entry.invocations in
            List.iter
              (fun invocation -> Eio.Cancel.cancel invocation.cancellation Exit)
              invocations;
            Option.iter (fun socket -> socket.stop ()) entry.socket;
            if entry.connecting then Eio.Promise.await entry.finished;
            Option.iter (fun socket -> socket.await_stopped ()) entry.socket;
            List.iter (fun invocation -> Eio.Promise.await invocation.stopped) invocations
          in
          try
            t.timeout t.cleanup_seconds cleanup;
            entry.joined <- true;
            remember_retired t entry;
            t.entries <- List.filter (fun current -> current != entry) t.entries;
            pulse entry;
            Ok ()
          with
          | Eio.Time.Timeout ->
            Error
              (Dsl.Cleanup_failure
                 { primary = entry.terminal
                 ; failures =
                     Rrbvec.singleton
                       (Dsl.Network_failure "WebSocket retirement deadline expired")
                 })
          | _ ->
            Error
              (Dsl.Cleanup_failure
                 { primary = entry.terminal
                 ; failures =
                     Rrbvec.singleton (Dsl.Network_failure "WebSocket retirement failed")
                 })
        in
        Eio.Promise.resolve resolve result;
        result)
;;

let find t handle =
  match List.find_opt (fun entry -> entry.handle == handle) t.entries with
  | Some entry -> Ok entry
  | None -> Error Dsl.Stale_context
;;

let validate_resource t = function
  | Dsl.Connection_reference handle ->
    let* _ = find t handle in
    Ok ()
  | Dsl.Snapshot_reference _ as reference ->
    (match t.snapshots with
     | Some snapshots -> Snapshot.validate_resource snapshots reference
     | None -> Error Dsl.Stale_context)
  | _ -> Error (Dsl.Invalid_input "Not a transport resource")
;;

let fence t ~identity =
  let* () = same_identity t identity in
  (match t.epoch with
   | Some epoch -> t.fenced_epoch <- Some epoch
   | None -> ());
  t.epoch <- None;
  List.iter
    (fun entry ->
       pulse entry;
       Option.iter (fun context -> Eio.Cancel.cancel context Exit) entry.setup)
    t.entries;
  Ok ()
;;

let close_network t ~identity =
  let* () = fence t ~identity in
  let failures =
    List.filter_map
      (fun entry ->
         match stop_entry t entry with
         | Ok () -> None
         | Error error -> Some error)
      t.entries
  in
  match failures with
  | [] ->
    (match t.snapshots with
     | None -> Ok ()
     | Some snapshots -> Snapshot.drain snapshots)
  | failures ->
    Error (Dsl.Cleanup_failure { primary = None; failures = Rrbvec.of_list failures })
;;

let authorize t ~identity ~epoch =
  let* () = same_identity t identity in
  if epoch < 0L
  then Error (Dsl.Invalid_input "Negative authorization epoch")
  else (
    match t.epoch, t.fenced_epoch with
    | Some current, _ when current = epoch -> Ok ()
    | Some _, _ -> Error Dsl.Stale_context
    | None, Some previous when epoch <= previous -> Error Dsl.Stale_context
    | None, _ ->
      if t.entries <> []
      then Error Dsl.Stale_context
      else (
        t.epoch <- Some epoch;
        Ok ()))
;;

let cleanup_result t entry result =
  match stop_entry t entry with
  | Ok () -> result
  | Error (Dsl.Cleanup_failure failure) ->
    Error
      (Dsl.Cleanup_failure
         { failure with
           primary =
             (match result with
              | Error error -> Some error
              | Ok _ -> failure.primary)
         })
  | Error error -> Error error
;;

let send scope entry message =
  let* () = scope.admit_network () in
  let* wire =
    Protocol.encode_client_message message
    |> Result.map_error (fun _ -> Dsl.Protocol_failure "Invalid client message")
  in
  match entry.socket with
  | None -> Error Dsl.Stale_context
  | Some socket -> socket.send wire
;;

exception Unauthorized_challenge

let connect t scope =
  let* () = scope.check_current () in
  let* epoch =
    match t.epoch with
    | None -> Error Dsl.Network_closed
    | Some epoch -> Ok epoch
  in
  if List.length t.entries >= t.limits.maximum_resources
  then Error (Dsl.Capacity_exceeded "Transport connections")
  else if t.generation = Int64.max_int
  then Error (Dsl.Capacity_exceeded "Connection generations")
  else (
    t.generation <- Int64.succ t.generation;
    let* handle =
      Dsl.connection
        ~owner:t.identity
        ~token:("native-websocket-" ^ Int64.to_string t.generation)
        ~generation:t.generation
    in
    let finished, finish = Eio.Promise.create () in
    let entry =
      { handle
      ; epoch
      ; changed = Eio.Condition.create ()
      ; finished
      ; finish
      ; socket = None
      ; setup = None
      ; connecting = true
      ; invocations = []
      ; joining = None
      ; retiring = false
      ; joined = false
      ; terminal = None
      ; ending = None
      ; request = None
      ; response = None
      ; receiving = false
      ; notifications = []
      ; notification_bytes = 0
      }
    in
    t.entries <- entry :: t.entries;
    let attempt refresh =
      let* () = check t scope entry in
      let* token = t.token ~epoch ~refresh in
      let* () = check t scope entry in
      let* () = scope.admit_network () in
      let* socket =
        match
          t.backend.connect
            ~token
            ~on_message:(on_message t entry)
            ~on_close:(on_close entry)
        with
        | Ok socket -> Ok socket
        | Error Unauthorized -> raise Unauthorized_challenge
        | Error (Failed error) -> Error error
      in
      entry.socket <- Some socket;
      let* () = check t scope entry in
      let* () = socket.activate () in
      let* () = check t scope entry in
      Ok handle
    in
    let result =
      try
        Fun.protect
          ~finally:(fun () ->
            entry.setup <- None;
            entry.connecting <- false;
            Eio.Promise.resolve entry.finish ())
          (fun () ->
             t.timeout t.connect_seconds (fun () ->
               Eio.Cancel.sub (fun context ->
                 entry.setup <- Some context;
                 try attempt false with
                 | Unauthorized_challenge ->
                   (try attempt true with
                    | Unauthorized_challenge ->
                      Error
                        (Dsl.Authentication_failure
                           "WebSocket token rejected after refresh")))))
      with
      | Eio.Cancel.Cancelled _ as cancelled ->
        ignore (stop_entry t entry : (unit, Dsl.error) result);
        raise cancelled
      | _ -> Error (Dsl.Network_failure "WebSocket setup failed")
    in
    match result with
    | Error _ -> cleanup_result t entry result
    | Ok handle ->
      let transferred =
        Eio.Cancel.protect (fun () ->
          scope.handoff (Rrbvec.singleton (Dsl.Connection_reference handle)))
      in
      (match transferred with
       | Error error -> cleanup_result t entry (Error error)
       | Ok () -> Ok handle))
;;

let bounded t scope entry ?(seconds = t.response_seconds) ~write work =
  try
    let result =
      with_invocation entry (fun () ->
        t.timeout seconds (fun () ->
          let* () = check t scope entry in
          work ()))
    in
    match result with
    | Ok _ -> result
    | Error (Dsl.Capacity_exceeded _) -> result
    | Error (Dsl.Network_failure _) when write ->
      cleanup_result t entry (Error (Dsl.Outcome_unknown "Submission response lost"))
    | Error _ -> cleanup_result t entry result
  with
  | Eio.Time.Timeout ->
    cleanup_result
      t
      entry
      (Error
         (if write
          then Dsl.Outcome_unknown "Submission response deadline expired"
          else Dsl.Network_failure "WebSocket response deadline expired"))
  | Eio.Cancel.Cancelled _ as cancelled ->
    let retiring = entry.retiring in
    let result = stop_entry t entry in
    if retiring
    then
      let* () = result in
      Error Dsl.Network_closed
    else raise cancelled
  | _ ->
    cleanup_result
      t
      entry
      (Error
         (if write
          then Dsl.Outcome_unknown "Submission interrupted"
          else Dsl.Network_failure "WebSocket request failed"))
;;

let response t scope entry family message decode =
  if entry.request <> None
  then Error (Dsl.Capacity_exceeded "WebSocket response family busy")
  else
    Fun.protect
      ~finally:(fun () ->
        entry.request <- None;
        entry.response <- None;
        pulse entry)
      (fun () ->
         entry.request <- Some family;
         bounded t scope entry ~write:(family = Push) (fun () ->
           let* () = send scope entry message in
           let* response =
             await entry (fun () ->
               match check t scope entry with
               | Error error -> Some (Error error)
               | Ok () -> Option.map (fun message -> Ok message) entry.response)
           in
           decode response))
;;

let head t scope entry =
  response t scope entry Head (Protocol.Client.Hello { client = "journal" }) Wire.head
;;

let receive t scope entry =
  if entry.receiving
  then Error (Dsl.Capacity_exceeded "WebSocket receiver busy")
  else
    Fun.protect
      ~finally:(fun () ->
        entry.receiving <- false;
        pulse entry)
      (fun () ->
         entry.receiving <- true;
         try
           with_invocation entry (fun () ->
             await entry (fun () ->
               match scope.check_current (), t.epoch with
               | Error error, _ -> Some (Error error)
               | Ok (), None -> Some (Error Dsl.Network_closed)
               | Ok (), Some epoch when epoch <> entry.epoch ->
                 Some (Error Dsl.Stale_context)
               | Ok (), Some _ when entry.retiring -> Some (Error Dsl.Network_closed)
               | Ok (), Some _ ->
                 (match entry.notifications with
                  | message :: rest ->
                    entry.notifications <- rest;
                    entry.notification_bytes
                    <- entry.notification_bytes - message_bytes message;
                    pulse entry;
                    Some (Ok Dsl.{ connection = entry.handle; message })
                  | [] ->
                    (match entry.ending, entry.terminal with
                     | Some ending, _ ->
                       entry.ending <- None;
                       Some
                         (Ok
                            Dsl.
                              { connection = entry.handle
                              ; message = Connection_ended ending
                              })
                     | None, Some error -> Some (Error error)
                     | None, None -> None))))
         with
         | Eio.Cancel.Cancelled _ as cancelled ->
           let retiring = entry.retiring in
           let result = stop_entry t entry in
           if retiring
           then
             let* () = result in
             Error Dsl.Network_closed
           else raise cancelled)
;;

let scoped : type a. t -> scope -> entry -> a Dsl.transport -> (a, Dsl.error) result =
  fun t scope entry -> function
  | Dsl.Head -> head t scope entry
  | Dsl.Pull since ->
    response
      t
      scope
      entry
      Pull
      (Protocol.Client.Pull { since = Some since })
      (Wire.pull ~limits:t.limits ~since)
  | Dsl.Push batch ->
    if
      Logseq_overlay_db.Types.submission_batch_total_bytes batch > t.limits.maximum_bytes
      || List.length (Logseq_overlay_db.Types.submission_batch_wires batch)
         > t.limits.maximum_items
    then Error (Dsl.Capacity_exceeded "Submission transport bounds")
    else response t scope entry Push (Wire.submission batch) (Wire.push ~batch)
  | Dsl.Fetch_snapshot ->
    Error (Dsl.Invalid_input "Snapshot download is independent of connections")
  | Dsl.Connect | Receive _ | Retire_connection _ | On_connection _ ->
    Error (Dsl.Invalid_input "Invalid scoped transport")
;;

let run
  : type a.
    t -> scope:scope -> identity:Dsl.identity -> a Dsl.transport -> (a, Dsl.error) result
  =
  fun t ~scope ~identity operation ->
  match same_identity t identity with
  | Error error -> Error error
  | Ok () ->
    (match operation with
     | Dsl.Retire_connection handle ->
       (match find t handle with
        | Ok entry -> stop_entry t entry
        | Error error ->
          if
            List.exists
              (fun weak ->
                 match Weak.get weak 0 with
                 | Some original -> original == handle
                 | None -> false)
              t.retired
          then Ok ()
          else Error error)
     | Dsl.Connect -> connect t scope
     | Dsl.Receive handle ->
       let* entry = find t handle in
       receive t scope entry
     | Dsl.On_connection (handle, request) ->
       let* entry = find t handle in
       scoped t scope entry request
     | Dsl.Fetch_snapshot ->
       let* epoch =
         match t.epoch with
         | None -> Error Dsl.Network_closed
         | Some epoch -> Ok epoch
       in
       let check_current () =
         let* () = scope.check_current () in
         if t.epoch = Some epoch then Ok () else Error Dsl.Stale_context
       in
       let snapshot_scope =
         { scope with
           check_current
         ; admit_network =
             (fun () ->
               let* () = check_current () in
               scope.admit_network ())
         }
       in
       let* () = snapshot_scope.admit_network () in
       let* snapshot = t.fetch_snapshot ~scope:snapshot_scope ~epoch () in
       let* () = check_current () in
       if snapshot.Dsl.resource.owner <> t.identity
       then Error (Dsl.Protocol_failure "Snapshot source identity mismatch")
       else Ok snapshot
     | Dsl.Head | Pull _ | Push _ ->
       let live = List.filter (fun entry -> not entry.retiring) t.entries in
       (match live with
        | [ entry ] -> scoped t scope entry operation
        | [] -> Error Dsl.Network_closed
        | _ -> Error (Dsl.Invalid_input "Transport connection is ambiguous")))
;;

let dispatch t ~scope ~identity operation =
  let scope =
    { check_current = (fun () -> Execute.Core.check_current scope)
    ; admit_network = (fun () -> Execute.Core.admit_network scope)
    ; handoff = Execute.Core.handoff scope
    }
  in
  run t ~scope ~identity operation
;;

let capabilities t (caps : Execute.Core.capabilities) =
  { caps with
    dispatch =
      { caps.dispatch with
        transport =
          (fun ~scope ~identity operation -> dispatch t ~scope ~identity operation)
      }
  ; authorize_network = (fun identity ~epoch -> authorize t ~identity ~epoch)
  ; fence_network = (fun identity -> fence t ~identity)
  ; close_network = (fun identity -> close_network t ~identity)
  ; validate_resource =
      (fun reference ->
        match reference, t.snapshots with
        | Dsl.Connection_reference _, _ | Dsl.Snapshot_reference _, Some _ ->
          validate_resource t reference
        | _ -> caps.validate_resource reference)
  ; release_snapshot =
      (fun identity snapshot ->
        match t.snapshots with
        | Some snapshots -> Snapshot.release snapshots ~identity snapshot
        | None -> caps.release_snapshot identity snapshot)
  }
;;

let create_owner
      ~sw
      ~clock
      ~identity
      ~limits
      ~(deadlines : Execute.Core.network_deadlines)
      ~cleanup_seconds
      ~backend
      ~token
      ~fetch_snapshot
      ~snapshots
  =
  let response_seconds = deadlines.http_response_seconds in
  let download_seconds = deadlines.download_seconds in
  let connect_seconds =
    deadlines.setup_seconds +. deadlines.tls_handshake_seconds +. response_seconds
  in
  if
    not
      (List.for_all
         (fun value -> Float.is_finite value && value > 0.)
         [ deadlines.setup_seconds
         ; deadlines.tls_handshake_seconds
         ; response_seconds
         ; download_seconds
         ; connect_seconds
         ; cleanup_seconds
         ])
  then Error (Dsl.Invalid_input "Transport deadlines")
  else (
    let t =
      { identity
      ; limits
      ; backend
      ; token
      ; fetch_snapshot
      ; snapshots
      ; timeout =
          (fun seconds callback ->
            Eio.Time.Timeout.run_exn (Eio.Time.Timeout.seconds clock seconds) callback)
      ; connect_seconds
      ; response_seconds
      ; cleanup_seconds
      ; epoch = None
      ; fenced_epoch = None
      ; generation = 0L
      ; entries = []
      ; retired = []
      }
    in
    Eio.Switch.on_release sw (fun () ->
      let result =
        let* () = close_network t ~identity in
        match snapshots with
        | None -> Ok ()
        | Some owner -> Snapshot.close owner
      in
      match result with
      | Ok () -> ()
      | Error error -> failwith (Dsl.error_message error));
    Ok t)
;;

let create
      ~sw
      ~clock
      ~identity
      ~limits
      ~deadlines
      ~cleanup_seconds
      ~backend
      ~token
      ~fetch_snapshot
  =
  create_owner
    ~sw
    ~clock
    ~identity
    ~limits
    ~deadlines
    ~cleanup_seconds
    ~backend
    ~token
    ~snapshots:None
    ~fetch_snapshot:(fun ~scope ~epoch:_ () -> fetch_snapshot ~scope ())
;;

let create_native
      ~verify_snapshot
      ~sw
      ~clock
      ~network
      ~authenticator
      ~identity
      ~limits
      ~deadlines
      ~cleanup_seconds
      ~liveness
      ~staging_directory
      ~encrypted
      ~token
  =
  let http =
    Http_client.create
      ~backend:(Http_client.native_backend ~sw ~clock ~network ~authenticator ~deadlines)
      ~token
  in
  let* snapshots =
    Snapshot.create
      ~verify:verify_snapshot
      ~root:staging_directory
      ~identity
      ~limits
      ~encrypted
      ~http
  in
  let backend =
    native_backend
      ~sw
      ~clock
      ~network
      ~authenticator
      ~identity
      ~limits
      ~deadlines
      ~liveness
  in
  create_owner
    ~sw
    ~clock
    ~identity
    ~limits
    ~deadlines
    ~cleanup_seconds
    ~backend
    ~token
    ~snapshots:(Some snapshots)
    ~fetch_snapshot:(fun ~scope ~epoch () ->
      Snapshot.acquire
        snapshots
        ~scope:
          { Http_client.check_current = scope.check_current
          ; admit_network = scope.admit_network
          }
        ~epoch
        ~handoff:scope.handoff
        ())
;;

let snapshot_source t snapshot =
  match t.snapshots with
  | Some snapshots -> Snapshot.source snapshots snapshot
  | None -> Error (Dsl.Invalid_input "No native snapshot producer")
;;

let release_snapshot t ~identity snapshot =
  match t.snapshots with
  | Some snapshots -> Snapshot.release snapshots ~identity snapshot
  | None -> Error (Dsl.Invalid_input "No native snapshot producer")
;;
