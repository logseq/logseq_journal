type error =
  | Invalid_dns_host
  | No_network_address
  | Setup_failed of string

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

let connect ~sw ~authenticator ~network ~host ~port =
  match host_name host with
  | Error _ as error -> error
  | Ok peer_name ->
    (match
       Tls.Config.client ~authenticator ~peer_name ~alpn_protocols:[ "http/1.1" ] ()
     with
     | Error (`Msg message) -> Error (Setup_failed message)
     | Ok config ->
       (match Eio.Net.getaddrinfo_stream ~service:(string_of_int port) network host with
        | [] -> Error No_network_address
        | address :: _ ->
          (try
             let socket = Eio.Net.connect ~sw network address in
             Ok (Tls_eio.client_of_flow config ~host:peer_name socket)
           with
           | Eio.Cancel.Cancelled _ as cancelled -> raise cancelled
           | exception_ -> Error (Setup_failed (Printexc.to_string exception_)))))
;;
