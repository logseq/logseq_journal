module Journal_worker = Logseq_db_worker_lui.Journal_worker

let bounded_increment value = if !value < 1_000_000_000 then incr value

let private_directory path =
  let canonical = Unix.realpath path in
  let stat = Unix.lstat path in
  if
    canonical <> path
    || stat.Unix.st_kind <> Unix.S_DIR
    || stat.Unix.st_perm land 0o7777 <> 0o700
    || stat.Unix.st_uid <> Unix.getuid ()
  then invalid_arg "Probe directory must be canonical, owned and mode 0700";
  canonical
;;

let wrap ~directory ~sw ~clock (original : Journal_worker.net) : Journal_worker.net =
  let directory = private_directory directory in
  let status =
    Unix.openfile
      (Filename.concat directory "status.json")
      [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL; Unix.O_CLOEXEC ]
      0o600
  in
  Eio.Switch.on_release sw (fun () -> Unix.close status);
  Unix.fchmod status 0o600;
  let offline = ref false in
  let generation = ref 0 in
  let heartbeat = ref 0 in
  let connect_failures = ref 0 in
  let shutdowns = ref 0 in
  let errors = ref 0 in
  let flows = Hashtbl.create 256 in
  let next_token = ref 0L in
  let fail_network () =
    bounded_increment connect_failures;
    raise
      (Eio.Net.err
         (Connection_failure
            (Refused (Eio_unix.Unix_error (Unix.ENETDOWN, "sync-network-probe", "")))))
  in
  let shutdown flow =
    match Eio.Flow.shutdown flow `All with
    | () -> bounded_increment shutdowns
    | exception Eio.Io _ -> bounded_increment errors
    | exception Unix.Unix_error _ -> bounded_increment errors
  in
  let read_control () =
    let path = Filename.concat directory "offline" in
    match Unix.lstat path with
    | stat ->
      if
        stat.Unix.st_kind <> Unix.S_REG
        || stat.Unix.st_uid <> Unix.getuid ()
        || stat.Unix.st_perm land 0o7777 <> 0o600
        || stat.Unix.st_size <> 0
      then (
        bounded_increment errors;
        true)
      else true
    | exception Unix.Unix_error (Unix.ENOENT, _, _) -> false
    | exception Unix.Unix_error _ ->
      bounded_increment errors;
      true
  in
  let publish () =
    let text =
      Printf.sprintf
        "{\"schema\":1,\"heartbeat\":%d,\"offline\":%d,\"generation\":%d,\"live_flows\":%d,\"connect_failures\":%d,\"shutdowns\":%d,\"errors\":%d}\n"
        !heartbeat
        (if !offline then 1 else 0)
        !generation
        (Hashtbl.length flows)
        !connect_failures
        !shutdowns
        !errors
    in
    ignore (Unix.lseek status 0 Unix.SEEK_SET);
    let bytes = Bytes.of_string text in
    let rec write offset =
      if offset < Bytes.length bytes
      then (
        let count = Unix.write status bytes offset (Bytes.length bytes - offset) in
        if count = 0 then failwith "Probe status write stopped" else write (offset + count))
    in
    write 0;
    Unix.ftruncate status (Bytes.length bytes)
  in
  let reconcile () =
    let requested = read_control () in
    if requested <> !offline
    then (
      offline := requested;
      bounded_increment generation;
      if requested
      then (
        let live = Hashtbl.fold (fun token flow live -> (token, flow) :: live) flows [] in
        List.iter
          (fun (token, flow) ->
             match Hashtbl.find_opt flows token with
             | Some current when current == flow -> shutdown flow
             | _ -> ())
          live))
  in
  reconcile ();
  publish ();
  Eio.Fiber.fork_daemon ~sw (fun () ->
    while true do
      Eio.Time.Mono.sleep clock 0.1;
      reconcile ();
      bounded_increment heartbeat;
      publish ()
    done;
    `Stop_daemon);
  let module Network = struct
    type t = Journal_worker.net
    type tag = [ `Generic ]

    let connect net ~sw address =
      reconcile ();
      if !offline then fail_network ();
      if Hashtbl.length flows >= 256 || !next_token = Int64.max_int
      then (
        bounded_increment errors;
        fail_network ());
      let started = !generation in
      let flow = Eio.Net.connect ~sw net address in
      reconcile ();
      if !offline || started <> !generation
      then (
        shutdown flow;
        fail_network ());
      if Hashtbl.length flows >= 256 || !next_token = Int64.max_int
      then (
        bounded_increment errors;
        shutdown flow;
        fail_network ());
      let token = !next_token in
      next_token := Int64.succ token;
      Hashtbl.add flows token flow;
      let release () =
        match Hashtbl.find_opt flows token with
        | Some current when current == flow -> Hashtbl.remove flows token
        | _ -> ()
      in
      let hook = Eio.Switch.on_release_cancellable sw release in
      let (Eio.Resource.T (resource, handlers)) = flow in
      let original_close = Eio.Resource.get handlers Eio.Resource.Close in
      let close resource =
        release ();
        Eio.Switch.remove_hook hook;
        original_close resource
      in
      Eio.Resource.T
        ( resource
        , Eio.Resource.handler
            (Eio.Resource.H (Eio.Resource.Close, close) :: Eio.Resource.bindings handlers)
        )
    ;;

    let listen net ~reuse_addr ~reuse_port ~backlog ~sw address =
      Eio.Net.listen net ~reuse_addr ~reuse_port ~backlog ~sw address
    ;;

    let datagram_socket net ~reuse_addr ~reuse_port ~sw address =
      Eio.Net.datagram_socket net ~reuse_addr ~reuse_port ~sw address
    ;;

    let getaddrinfo net ~service host = Eio.Net.getaddrinfo net ~service host
    let getnameinfo net address = Eio.Net.getnameinfo net address
  end
  in
  Eio.Resource.T (original, Eio.Net.Pi.network (module Network))
;;
