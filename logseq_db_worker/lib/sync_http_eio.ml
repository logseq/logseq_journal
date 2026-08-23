type response =
  { status : int
  ; headers : (string * string) list
  ; body : string
  }

let rng_initialized = Atomic.make false

let initialize_rng () =
  if Atomic.compare_and_set rng_initialized false true
  then Mirage_crypto_rng_unix.use_default ()
;;

let bind result f =
  match result with
  | Ok value -> f value
  | Error _ as error -> error
;;

let host_name host =
  bind (Domain_name.of_string host) (fun domain ->
    match Domain_name.host domain with
    | Ok host -> Ok host
    | Error _ -> Error (`Msg "HTTPS host is not a valid DNS name"))
;;

let tls_config host =
  bind (Ca_certs_nss.authenticator ()) (fun authenticator ->
    bind (host_name host) (fun peer_name ->
      Tls.Config.client ~authenticator ~peer_name ()))
;;

let first_address ~network ~host ~port =
  match Eio.Net.getaddrinfo_stream ~service:(string_of_int port) network host with
  | address :: _ -> Ok address
  | [] -> Error "sync host has no network address"
;;

let port uri = Option.value (Uri.port uri) ~default:443

let open_flow ~sw ~environment uri =
  match Uri.host uri with
  | None -> Error "HTTPS request host is missing"
  | Some host ->
    (match tls_config host with
     | Error (`Msg message) -> Error message
     | Ok config ->
       let network = Eio.Stdenv.net environment in
       bind
         (first_address ~network ~host ~port:(port uri))
         (fun address ->
            try
              let socket = Eio.Net.connect ~sw network address in
              let peer_name = host_name host |> Result.get_ok in
              Ok (Tls_eio.client_of_flow config ~host:peer_name socket)
            with
            | Eio.Cancel.Cancelled _ as cancelled -> raise cancelled
            | exception_ -> Error (Printexc.to_string exception_)))
;;

let request_headers uri headers =
  let host = Option.get (Uri.host uri) in
  let host =
    match Uri.port uri with
    | None | Some 443 -> host
    | Some port -> Printf.sprintf "%s:%d" host port
  in
  Httpun.Headers.of_list (("host", host) :: ("connection", "close") :: headers)
;;

let method_ = function
  | Sync_http.Get -> `GET
  | Post -> `POST
;;

let protocol_error_message context = function
  | `Malformed_response _ -> context ^ ": malformed HTTP response"
  | `Invalid_response_body_length _ -> context ^ ": invalid HTTP response body length"
  | `Exn _ -> context ^ ": HTTP transport exception"
;;

let tls_stream_socket flow =
  let module Socket = struct
    type t = Tls_eio.t
    type tag = [ `Generic ]

    let read_methods = []
    let single_read = Eio.Flow.single_read
    let single_write = Eio.Flow.single_write
    let copy destination ~src = Eio.Flow.copy src destination
    let shutdown = Eio.Flow.shutdown
    let close = Eio.Resource.close
  end
  in
  Eio.Resource.T (flow, Eio.Net.Pi.stream_socket (module Socket))
;;

let request_once ~sw ~environment request =
  bind (open_flow ~sw ~environment request.Sync_http.uri) (fun flow ->
    let client = Httpun_eio.Client.create_connection ~sw (tls_stream_socket flow) in
    let result, resolve_result = Eio.Promise.create () in
    let resolve value = ignore (Eio.Promise.try_resolve resolve_result value : bool) in
    let error_handler error =
      resolve (Error (protocol_error_message "sync HTTP protocol failed" error))
    in
    let response_handler response body =
      let buffer = Buffer.create 4096 in
      let rec read () =
        Httpun.Body.Reader.schedule_read
          body
          ~on_eof:(fun () ->
            resolve
              (Ok
                 { status = Httpun.Status.to_code response.Httpun.Response.status
                 ; headers = Httpun.Headers.to_list response.headers
                 ; body = Buffer.contents buffer
                 }))
          ~on_read:(fun chunk ~off ~len ->
            if Buffer.length buffer + len > request.Sync_http.maximum_response_bytes
            then (
              Httpun.Body.Reader.close body;
              resolve (Error "sync HTTP response exceeds its configured bound"))
            else (
              Buffer.add_string buffer (Bigstringaf.substring chunk ~off ~len);
              read ()))
      in
      read ()
    in
    let target =
      let value = Uri.path_and_query request.uri in
      if String.length value = 0 then "/" else value
    in
    let descriptor =
      Httpun.Request.create
        ~headers:(request_headers request.uri request.headers)
        (method_ request.meth)
        target
    in
    let writer =
      Httpun_eio.Client.request
        client
        descriptor
        ~error_handler
        ~response_handler
    in
    Option.iter (Httpun.Body.Writer.write_string writer) request.body;
    Httpun.Body.Writer.close writer;
    Eio.Promise.await result)
;;

let header name headers =
  List.find_map
    (fun (actual, value) ->
       if String.equal (String.lowercase_ascii actual) name then Some value else None)
    headers
;;

let positive_int value =
  match Option.bind value int_of_string_opt with
  | Some value when value > 0 -> Some value
  | None | Some _ -> None
;;

let remove_if_exists path =
  try Sys.remove path with
  | Sys_error _ -> ()
;;

let download_once ~sw ~environment ~request ~destination ~maximum_bytes ~on_progress =
  bind (open_flow ~sw ~environment request.Sync_http.uri) (fun flow ->
    let client = Httpun_eio.Client.create_connection ~sw (tls_stream_socket flow) in
    let result, resolve_result = Eio.Promise.create () in
    let resolve value = ignore (Eio.Promise.try_resolve resolve_result value : bool) in
    let destination_channel = ref None in
    let close_destination () =
      Option.iter close_out_noerr !destination_channel;
      destination_channel := None
    in
    let error_handler error =
      close_destination ();
      remove_if_exists destination;
      resolve
        (Error (protocol_error_message "snapshot artifact HTTP protocol failed" error))
    in
    let response_handler response body =
      let headers = Httpun.Headers.to_list response.Httpun.Response.headers in
      let status = Httpun.Status.to_code response.status in
      let total_bytes = positive_int (header "content-length" headers) in
      if
        match total_bytes with
        | Some total -> total > maximum_bytes
        | None -> false
      then (
        Httpun.Body.Reader.close body;
        resolve (Error "snapshot artifact exceeds its configured bound"))
      else (
        try
          let channel =
            open_out_gen
              [ Open_wronly; Open_creat; Open_excl; Open_binary ]
              0o600
              destination
          in
          destination_channel := Some channel;
          let received = ref 0 in
          let finish value =
            close_destination ();
            resolve value
          in
          on_progress
            Sync_bootstrap.{ received_bytes = 0; total_bytes; datom_count = None };
          let rec read () =
            Httpun.Body.Reader.schedule_read
              body
              ~on_eof:(fun () -> finish (Ok { status; headers; body = "" }))
              ~on_read:(fun chunk ~off ~len ->
                if !received + len > maximum_bytes
                then (
                  Httpun.Body.Reader.close body;
                  finish (Error "snapshot artifact exceeds its configured bound"))
                else (
                  output_string channel (Bigstringaf.substring chunk ~off ~len);
                  received := !received + len;
                  on_progress
                    Sync_bootstrap.
                      { received_bytes = !received; total_bytes; datom_count = None };
                  read ()))
          in
          read ()
        with
        | exception_ ->
          close_destination ();
          remove_if_exists destination;
          resolve (Error (Printexc.to_string exception_)))
    in
    let target =
      let value = Uri.path_and_query request.uri in
      if String.length value = 0 then "/" else value
    in
    let descriptor =
      Httpun.Request.create
        ~headers:(request_headers request.uri request.headers)
        (method_ request.meth)
        target
    in
    let writer =
      Httpun_eio.Client.request
        client
        descriptor
        ~error_handler
        ~response_handler
    in
    Option.iter (Httpun.Body.Writer.write_string writer) request.body;
    Httpun.Body.Writer.close writer;
    Eio.Promise.await result)
;;

let redirect_status = function
  | 301 | 302 | 303 | 307 | 308 -> true
  | _ -> false
;;

let successful_status status = status >= 200 && status < 300

let same_authority first second =
  Uri.scheme first = Uri.scheme second
  && Uri.host first = Uri.host second
  && port first = port second
;;

let location headers =
  headers
  |> List.find_map (fun (name, value) ->
    if String.equal (String.lowercase_ascii name) "location" then Some value else None)
;;

let perform ~sw ~environment request =
  initialize_rng ();
  let clock = Eio.Stdenv.clock environment in
  let rec follow remaining request =
    match request_once ~sw ~environment request with
    | Error _ as error -> error
    | Ok response when redirect_status response.status ->
      if remaining = 0
      then Error "sync HTTP redirect limit exceeded"
      else (
        match location response.headers with
        | None -> Error "sync HTTP redirect is missing Location"
        | Some location ->
          let next = Uri.resolve "" request.uri (Uri.of_string location) in
          if not (same_authority request.uri next)
          then Error "authenticated sync HTTP redirect changed authority"
          else follow (remaining - 1) { request with uri = next })
    | Ok response ->
      if successful_status response.status
      then
        Result.map
          (fun () -> response)
          (Sync_http.validate_response_content_type request response.headers)
      else Ok response
  in
  try Eio.Time.with_timeout_exn clock 30. (fun () -> follow 3 request) with
  | Eio.Cancel.Cancelled _ as cancelled -> raise cancelled
  | Eio.Time.Timeout -> Error "sync HTTP request timed out"
  | exception_ -> Error (Printexc.to_string exception_)
;;

let download ~sw ~environment ~request ~destination ~maximum_bytes ~on_progress =
  initialize_rng ();
  if maximum_bytes <= 0
  then Error "snapshot artifact bound must be positive"
  else (
    let clock = Eio.Stdenv.clock environment in
    let rec follow remaining request =
      remove_if_exists destination;
      match
        download_once ~sw ~environment ~request ~destination ~maximum_bytes ~on_progress
      with
      | Error _ as error ->
        remove_if_exists destination;
        error
      | Ok response when redirect_status response.status ->
        remove_if_exists destination;
        if remaining = 0
        then Error "snapshot artifact redirect limit exceeded"
        else (
          match location response.headers with
          | None -> Error "snapshot artifact redirect is missing Location"
          | Some location ->
            let next = Uri.resolve "" request.uri (Uri.of_string location) in
            if not (same_authority request.uri next)
            then Error "authenticated snapshot redirect changed authority"
            else follow (remaining - 1) { request with uri = next })
      | Ok response ->
        if successful_status response.status
        then (
          match Sync_http.validate_response_content_type request response.headers with
          | Ok () -> Ok response
          | Error _ as error ->
            remove_if_exists destination;
            error)
        else Ok response
    in
    try Eio.Time.with_timeout_exn clock 120. (fun () -> follow 3 request) with
    | Eio.Cancel.Cancelled _ as cancelled -> raise cancelled
    | Eio.Time.Timeout ->
      remove_if_exists destination;
      Error "snapshot artifact download timed out"
    | exception_ ->
      remove_if_exists destination;
      Error (Printexc.to_string exception_))
;;
