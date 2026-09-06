type error =
  | Invalid_dns_host
  | No_network_address
  | Setup_failed of string

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

let resolve ~clock host port =
  let family ipv6 =
    let query = dns_start host ipv6 in
    Fun.protect
      ~finally:(fun () -> dns_close query)
      (fun () ->
         try
           Eio.Time.with_timeout_exn clock 2. (fun () ->
             let rec receive () =
               Eio_unix.await_readable (dns_fd query);
               if dns_process query then dns_results query else receive ()
             in
             receive ())
         with
         | Eio.Cancel.Cancelled _ as cancelled -> raise cancelled
         | _ -> [])
  in
  let ipv6, ipv4 = Eio.Fiber.pair (fun () -> family true) (fun () -> family false) in
  List.sort_uniq String.compare (ipv6 @ ipv4)
  |> List.map (fun address -> `Tcp (Eio.Net.Ipaddr.of_raw address, port))
;;

let connect ~sw ~authenticator ~network ~clock ~host ~port =
  match host_name host with
  | Error _ as error -> error
  | Ok peer_name ->
    (match
       Tls.Config.client ~authenticator ~peer_name ~alpn_protocols:[ "http/1.1" ] ()
     with
     | Error (`Msg _) -> Error (Setup_failed "invalid TLS configuration")
     | Ok config ->
       (try
          let addresses = resolve ~clock host port in
          let rec attempt = function
            | [] -> Error (Setup_failed "all resolved addresses failed")
            | address :: rest ->
              let socket = ref None in
              (try
                 let flow =
                   Eio.Time.with_timeout_exn clock 1. (fun () ->
                     let connected = Eio.Net.connect ~sw network address in
                     socket := Some connected;
                     Tls_eio.client_of_flow config ~host:peer_name connected)
                 in
                 Ok flow
               with
               | exn ->
                 Option.iter Eio.Resource.close !socket;
                 (match exn with
                  | Eio.Cancel.Cancelled _ as cancelled -> raise cancelled
                  | _ -> attempt rest))
          in
          if addresses = [] then Error No_network_address else attempt addresses
        with
        | Eio.Cancel.Cancelled _ as cancelled -> raise cancelled
        | _ -> Error (Setup_failed "TLS connection setup failed")))
;;
