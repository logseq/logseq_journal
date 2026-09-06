type response =
  { status : int
  ; headers : (string * string) list
  ; body : string
  }

exception Transport_error of string
exception Retire_attempt

let fail message = raise (Transport_error message)
let port uri = Option.value (Uri.port uri) ~default:443
let successful_status status = status >= 200 && status < 300
let next_attempt = Atomic.make 0

let header name headers =
  List.find_map
    (fun (key, value) ->
       if String.equal (String.lowercase_ascii key) name then Some value else None)
    headers
;;

let exception_message = function
  | Transport_error message -> message
  | End_of_file -> "premature HTTP EOF"
  | Tls_eio.Tls_alert _ | Tls_eio.Tls_failure _ -> "TLS transport terminated"
  | Sys_error _ | Unix.Unix_error _ -> "transport file or socket operation failed"
  | _ -> "HTTP transport failed"
;;

let tls_stream_socket flow =
  let module Socket = struct
    type t = Tls_eio.t
    type tag = [ `Generic ]

    let read_methods = []
    let single_read = Eio.Flow.single_read
    let single_write = Eio.Flow.single_write
    let copy destination ~src = Eio.Flow.copy src destination

    (* HTTP request output completion must not send TLS close_notify while the
       response is still streaming. The attempt owner closes the complete flow. *)
    let shutdown flow = function
      | `Send -> ()
      | (`Receive | `All) as direction -> Eio.Flow.shutdown flow direction
    ;;

    let close = Eio.Resource.close
  end
  in
  Eio.Resource.T (flow, Eio.Net.Pi.stream_socket (module Socket))
;;

let with_attempt ~sw ~authenticator ~network ~clock request ~consume =
  Eio.Switch.check sw;
  let id = Atomic.fetch_and_add next_attempt 1 in
  let stage = ref "setup"
  and received = ref 0 in
  let outcome = ref None
  and fenced = ref false in
  let completed, complete = Eio.Promise.create () in
  let settle value =
    if not !fenced
    then (
      (* An error may follow body EOF in the same parser call. Preserve the first
         failure until the driver returns to the operation owner. *)
      (match !outcome, value with
       | Some (Error _), _ -> ()
       | _, Error _ -> outcome := Some value
       | None, Ok _ -> outcome := Some value
       | Some (Ok _), Ok _ -> ());
      ignore (Eio.Promise.try_resolve complete () : bool))
  in
  let guard f =
    if
      (not !fenced)
      &&
      match !outcome with
      | Some (Error _) -> false
      | _ -> true
    then (
      try f () with
      | Eio.Cancel.Cancelled _ as cancelled -> raise cancelled
      | exn -> settle (Error (exception_message exn)))
  in
  let log result =
    Eio.traceln
      "sync HTTP attempt=%d stage=%s received=%d outcome=%s"
      id
      !stage
      !received
      result
  in
  try
    (try
       Eio.Switch.run (fun owner ->
         Fun.protect
           ~finally:(fun () -> fenced := true)
           (fun () ->
              let host =
                match Uri.host request.Http.uri with
                | Some host -> host
                | None -> fail "HTTPS host is missing"
              in
              let flow =
                match
                  Tls_client_eio.connect
                    ~sw:owner
                    ~authenticator
                    ~network
                    ~clock
                    ~host
                    ~port:(port request.uri)
                with
                | Ok flow -> flow
                | Error _ -> fail "TLS connection setup failed"
              in
              let client =
                Httpun_eio.Client.create_connection ~sw:owner (tls_stream_socket flow)
              in
              let error_handler error =
                let message =
                  match error with
                  | `Malformed_response _ -> "malformed HTTP response"
                  | `Invalid_response_body_length _ -> "invalid HTTP response body length"
                  | `Exn exn -> exception_message exn
                in
                settle (Error message)
              in
              let response_handler response body =
                guard (fun () ->
                  let status = Httpun.Status.to_code response.Httpun.Response.status in
                  let headers = Httpun.Headers.to_list response.headers in
                  let framing =
                    match Httpun.Response.body_length ~request_method:`GET response with
                    | `Fixed length -> Printf.sprintf "length:%Ld" length
                    | `Chunked -> "chunked"
                    | `Close_delimited -> "close-delimited"
                    | `Error _ -> "invalid-framing"
                  in
                  stage := Printf.sprintf "body:%d:%s" status framing;
                  consume ~status ~headers ~received ~guard ~settle body)
              in
              let host_header =
                if port request.uri = 443
                then host
                else Printf.sprintf "%s:%d" host (port request.uri)
              in
              let headers =
                Httpun.Headers.of_list
                  (("host", host_header) :: ("connection", "close") :: request.headers)
              in
              let target = Uri.path_and_query request.uri in
              let descriptor =
                Httpun.Request.create ~headers `GET (if target = "" then "/" else target)
              in
              stage := "headers";
              let writer =
                Httpun_eio.Client.request
                  client
                  descriptor
                  ~error_handler
                  ~response_handler
              in
              Httpun.Body.Writer.close writer;
              Eio.Promise.await completed;
              Eio.Fiber.check ();
              (* Cancellation of this private switch interrupts blocked I/O and joins
              the adapter. Fence its cleanup callbacks before that cancellation. *)
              fenced := true;
              raise Retire_attempt))
     with
     | Retire_attempt -> ());
    Eio.Fiber.check ();
    log "retired";
    Option.value !outcome ~default:(Error "HTTP driver retired without an outcome")
  with
  | Eio.Cancel.Cancelled _ as cancelled ->
    log "cancelled-retired";
    raise cancelled
  | exn ->
    log "failed-retired";
    Error (exception_message exn)
;;

let read_body ~maximum_bytes ~received ~guard ~settle ~on_chunk ~on_eof body =
  let rec read () =
    Httpun.Body.Reader.schedule_read
      body
      ~on_eof:(fun () -> guard on_eof)
      ~on_read:(fun chunk ~off ~len ->
        guard (fun () ->
          if len > maximum_bytes - !received
          then (
            settle (Error "HTTP body exceeds its configured bound");
            Httpun.Body.Reader.close body)
          else (
            on_chunk (Bigstringaf.substring chunk ~off ~len);
            received := !received + len;
            read ())))
  in
  read ()
;;

let request_once ~sw ~authenticator ~network ~clock request =
  with_attempt
    ~sw
    ~authenticator
    ~network
    ~clock
    request
    ~consume:(fun ~status ~headers ~received ~guard ~settle body ->
      let buffer = Buffer.create 4096 in
      read_body
        ~maximum_bytes:request.Http.maximum_response_bytes
        ~received
        ~guard
        ~settle
        ~on_chunk:(Buffer.add_string buffer)
        ~on_eof:(fun () -> settle (Ok { status; headers; body = Buffer.contents buffer }))
        body)
;;

let redirect_status = function
  | 301 | 302 | 303 | 307 | 308 -> true
  | _ -> false
;;

let redirect request headers =
  match header "location" headers with
  | None -> Error "HTTP redirect is missing Location"
  | Some location ->
    let next = Uri.resolve "" request.Http.uri (Uri.of_string location) in
    if
      Uri.userinfo next <> None
      || Uri.fragment next <> None
      || not (Http.same_origin request.uri next)
    then Error "HTTP redirect changed authority or contains unsafe credentials"
    else Ok { request with uri = next }
;;

let follow_redirects attempt request =
  let rec follow remaining request =
    Result.bind (attempt request) (fun response ->
      if redirect_status response.status
      then
        if remaining = 0
        then Error "HTTP redirect limit exceeded"
        else Result.bind (redirect request response.headers) (follow (remaining - 1))
      else Ok (request, response))
  in
  follow 3 request
;;

let timed clock seconds f =
  try Eio.Time.with_timeout_exn clock seconds f with
  | Eio.Cancel.Cancelled _ as cancelled -> raise cancelled
  | Eio.Time.Timeout -> Error "HTTP transport timed out"
  | exception_ -> Error (exception_message exception_)
;;

let perform ~sw ~authenticator ~network ~clock request =
  Tls_client_eio.initialize_rng ();
  timed clock 30. (fun () ->
    Result.bind
      (follow_redirects (request_once ~sw ~authenticator ~network ~clock) request)
      (fun (request, response) ->
         if successful_status response.status
         then
           Result.map
             (fun () -> response)
             (Http.validate_response_content_type request response.headers)
         else Ok response))
;;

let remove_partial path =
  try Sys.remove path with
  | Sys_error _ -> ()
;;

let download_once
      ~sw
      ~authenticator
      ~network
      ~clock
      ~request
      ~destination
      ~maximum_bytes
      ~on_progress
  =
  let partial = ref None
  and channel = ref None in
  Fun.protect
    ~finally:(fun () ->
      Option.iter close_out_noerr !channel;
      Option.iter remove_partial !partial)
    (fun () ->
       let result =
         with_attempt
           ~sw
           ~authenticator
           ~network
           ~clock
           request
           ~consume:(fun ~status ~headers ~received ~guard ~settle body ->
             if not (successful_status status)
             then settle (Ok { status; headers; body = "" })
             else (
               (match Http.validate_response_content_type request headers with
                | Ok () -> ()
                | Error message -> fail message);
               let total_bytes =
                 Option.bind (header "content-length" headers) int_of_string_opt
                 |> fun count ->
                 match count with
                 | Some n when n >= 0 -> Some n
                 | _ -> None
               in
               if Option.fold ~none:false ~some:(fun n -> n > maximum_bytes) total_bytes
               then fail "snapshot artifact exceeds its configured bound";
               let path, output =
                 Filename.open_temp_file
                   ~temp_dir:(Filename.dirname destination)
                   ~mode:[ Open_binary ]
                   (Filename.basename destination ^ ".")
                   ".partial"
               in
               partial := Some path;
               channel := Some output;
               let progress count =
                 on_progress
                   Bootstrap.{ received_bytes = count; total_bytes; datom_count = None }
               in
               progress 0;
               read_body
                 ~maximum_bytes
                 ~received
                 ~guard
                 ~settle
                 body
                 ~on_chunk:(fun data ->
                   output_string output data;
                   progress (!received + String.length data))
                 ~on_eof:(fun () -> settle (Ok { status; headers; body = "" }))))
       in
       Result.bind result (fun response ->
         match !partial, !channel with
         | Some path, Some output ->
           (try
              (* The attempt has retired; no network callback survives publication. *)
              flush output;
              close_out output;
              channel := None;
              Sys.rename path destination;
              partial := None;
              Ok response
            with
            | exn -> Error (exception_message exn))
         | None, None -> Ok response
         | _ -> Error "incomplete artifact output state"))
;;

let download
      ~sw
      ~authenticator
      ~network
      ~clock
      ~request
      ~destination
      ~maximum_bytes
      ~on_progress
  =
  Tls_client_eio.initialize_rng ();
  if maximum_bytes <= 0
  then Error "snapshot artifact bound must be positive"
  else
    timed clock 120. (fun () ->
      Result.map
        snd
        (follow_redirects
           (fun request ->
              download_once
                ~sw
                ~authenticator
                ~network
                ~clock
                ~request
                ~destination
                ~maximum_bytes
                ~on_progress)
           request))
;;
