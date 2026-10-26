type error =
  | Invalid_dns_host
  | No_network_address
  | Setup_failed of string
  | Authentication_failed

type transient_failure = Connection_refused | Connection_timeout | Network_unreachable | Connection_reset

let transient_failure = function
  | Unix.Unix_error (Unix.ECONNREFUSED, _, _)
  | Eio.Io (Eio.Net.E (Eio.Net.Connection_failure (Eio.Net.Refused _)), _) -> Some Connection_refused
  | Eio.Time.Timeout | Unix.Unix_error (Unix.ETIMEDOUT, _, _)
  | Eio.Io (Eio.Net.E (Eio.Net.Connection_failure Eio.Net.Timeout), _) -> Some Connection_timeout
  | Unix.Unix_error ((Unix.ENETUNREACH | Unix.EHOSTUNREACH), _, _) -> Some Network_unreachable
  | Unix.Unix_error ((Unix.ECONNRESET | Unix.EPIPE), _, _)
  | Eio.Io (Eio.Net.E (Eio.Net.Connection_reset _), _) | End_of_file -> Some Connection_reset
  | _ -> None
;;

type dns_query

external dns_start : string -> bool -> dns_query = "logseq_transport_dns_start"
external dns_fd : dns_query -> Unix.file_descr = "logseq_transport_dns_fd"
external dns_process : dns_query -> bool = "logseq_transport_dns_process"
external dns_results : dns_query -> string list = "logseq_transport_dns_results"
external dns_close : dns_query -> unit = "logseq_transport_dns_close"

let rng_initialized = Atomic.make false

let initialize_rng () =
  if Atomic.compare_and_set rng_initialized false true
  then Mirage_crypto_rng_unix.use_default ()
;;

let host_name host =
  match Domain_name.of_string host with
  | Error _ -> Error Invalid_dns_host
  | Ok domain ->
    (match Domain_name.host domain with
     | Error _ -> Error Invalid_dns_host
     | Ok host -> Ok host)
;;

let resolve ~clock ~deadline host port =
  let family ipv6 =
    let query = dns_start host ipv6 in
    Fun.protect
      ~finally:(fun () -> dns_close query)
      (fun () ->
         try
           let addresses = Eio.Time.with_timeout_exn
             clock
             (max 0. (deadline -. Eio.Time.now clock))
             (fun () ->
                let rec receive () =
                  Eio_unix.await_readable (dns_fd query);
                  if dns_process query then dns_results query else receive ()
                in
                receive ()) in
           addresses, None
         with
         | Eio.Cancel.Cancelled _ as cancelled -> raise cancelled
         | Eio.Time.Timeout -> [], Some ("DNS resolution timed out", Some Connection_timeout)
         | Unix.Unix_error ((Unix.EACCES | Unix.EPERM), _, _) ->
           [], Some ("DNS resolver permission denied", None)
         | Unix.Unix_error _ -> [], Some ("DNS resolver I/O failed", None)
         | _ -> [], Some ("DNS resolver operation failed", None))
  in
  let (ipv6, ipv6_error), (ipv4, ipv4_error) = Eio.Fiber.pair (fun () -> family true) (fun () -> family false) in
  let addresses = List.sort_uniq String.compare (ipv6 @ ipv4)
    |> List.map (fun address -> `Tcp (Eio.Net.Ipaddr.of_raw address, port)) in
  let transient = match ipv4_error, ipv6_error with
    | Some (_, Some a), Some (_, Some _) -> Some a
    | _ -> None in
  addresses, Option.map fst (match ipv4_error with Some _ -> ipv4_error | None -> ipv6_error), transient
;;

(* Eio may allocate a socket before connect raises. Keep each candidate in its
   own child owner, and report failure only after that owner has released it.
   A successful candidate remains owned until the operation switch retires. *)
let connect_address ~sw ~network ~clock ~deadline ~tcp_seconds config peer_name address =
  let result, resolve = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    try
      Eio.Switch.run (fun address_owner ->
        let connected =
          Eio.Time.with_timeout_exn
            clock
            (max 0. (min tcp_seconds (deadline -. Eio.Time.now clock)))
            (fun () -> Eio.Net.connect ~sw:address_owner network address)
        in
        let flow =
          Eio.Time.with_timeout_exn clock 10. (fun () ->
            Tls_eio.client_of_flow config ~host:peer_name connected)
        in
        ignore (Eio.Promise.try_resolve resolve (Ok flow) : bool);
        Eio.Fiber.await_cancel ())
    with
    | exn -> ignore (Eio.Promise.try_resolve resolve (Error exn) : bool));
  Eio.Promise.await result
;;

(* Never format exception payloads: transport context can contain addresses,
   URLs and TLS peer metadata. This finite class is retained only for the final
   failed address; trying subsequent addresses and their deadlines is unchanged. *)
let setup_class = function
  | Unix.Unix_error (Unix.ECONNREFUSED, _, _)
  | Eio.Io (Eio.Net.E (Eio.Net.Connection_failure (Eio.Net.Refused _)), _) ->
    "connection refused"
  | Eio.Time.Timeout
  | Unix.Unix_error (Unix.ETIMEDOUT, _, _)
  | Eio.Io (Eio.Net.E (Eio.Net.Connection_failure Eio.Net.Timeout), _) -> "dial timed out"
  | Unix.Unix_error ((Unix.ENETUNREACH | Unix.EHOSTUNREACH), _, _) -> "network unreachable"
  | Unix.Unix_error ((Unix.EACCES | Unix.EPERM), _, _) -> "permission denied"
  | Unix.Unix_error ((Unix.ECONNRESET | Unix.EPIPE), _, _)
  | Eio.Io (Eio.Net.E (Eio.Net.Connection_reset _), _) -> "connection reset"
  | Tls_eio.Tls_alert _ -> "TLS peer alert"
  | Tls_eio.Tls_failure _ -> "TLS handshake failed"
  | Failure _ -> "operation raised Failure"
  | Invalid_argument _ -> "operation raised Invalid_argument"
  | _ -> "external setup failure"
;;

let safe_setup_detail source =
  let prefixes = ["all resolved addresses failed: "; "TLS connection setup failed: "] in
  let classes = ["connection refused"; "dial timed out"; "network unreachable";
    "permission denied"; "connection reset"; "TLS peer alert"; "TLS handshake failed";
    "operation raised Failure"; "operation raised Invalid_argument"; "external setup failure"] in
  if List.exists (fun prefix -> List.exists (fun value -> source = prefix ^ value) classes)
    prefixes then Some source else None
;;

let connect_diagnosed_with_attention ~on_transient_failure ~on_diagnostic ~sw ~authenticator ~network ~clock ~host ~port =
  match host_name host with
  | Error _ as error -> error
  | Ok peer_name ->
    (match
       Tls.Config.client ~authenticator ~peer_name ~alpn_protocols:[ "http/1.1" ] ()
     with
     | Error (`Msg _) -> Error (Setup_failed "invalid TLS configuration")
     | Ok config ->
       let deadline = Eio.Time.now clock +. 30. in
       (try
          let addresses, dns_failure, dns_transient = resolve ~clock ~deadline host port in
          let report transient = Option.iter (fun cause ->
            try on_transient_failure cause with _ -> ()) transient in
          let rec attempt last_failure transient attention_required = function
            | [] ->
              if not attention_required then report transient;
              Error (Setup_failed ("all resolved addresses failed: " ^ last_failure))
            | address :: rest ->
              let remaining = deadline -. Eio.Time.now clock in
              if remaining <= 0.
              then (if not attention_required then report (Some Connection_timeout);
                Error (Setup_failed "DNS/TCP dial timed out"))
              else (
                match
                  connect_address
                    ~sw
                    ~network
                    ~clock
                    ~deadline
                    ~tcp_seconds:(remaining /. float_of_int (1 + List.length rest))
                    config
                    peer_name
                    address
                with
                | Ok flow -> Ok flow
                | Error (Eio.Cancel.Cancelled _ as cancelled) -> raise cancelled
                | Error (Tls_eio.Tls_failure (`Error (`AuthenticationFailure _))) ->
                  Error Authentication_failed
                | Error error ->
                  let transient = transient_failure error in
                  attempt (setup_class error) transient (attention_required || transient = None) rest)
          in
          if addresses = [] then (
            Option.iter (fun cause -> try on_diagnostic cause with _ -> ()) dns_failure;
            report dns_transient;
            Error No_network_address)
          else attempt "external setup failure" None false addresses
        with
        | Eio.Cancel.Cancelled _ as cancelled -> raise cancelled
        | error ->
          Option.iter (fun cause -> try on_transient_failure cause with _ -> ()) (transient_failure error);
          Error (Setup_failed ("TLS connection setup failed: " ^ setup_class error))))
;;

let connect_diagnosed ~on_diagnostic ~sw ~authenticator ~network ~clock ~host ~port =
  connect_diagnosed_with_attention ~on_transient_failure:(fun _ -> ()) ~on_diagnostic
    ~sw ~authenticator ~network ~clock ~host ~port
;;

let connect ~sw ~authenticator ~network ~clock ~host ~port =
  connect_diagnosed ~on_diagnostic:(fun _ -> ()) ~sw ~authenticator ~network ~clock ~host ~port
;;
