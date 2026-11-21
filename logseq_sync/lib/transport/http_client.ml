module Dsl = Sync_dsl.Core
module Http = Logseq_sync_native_transport.Http
module Native = Logseq_sync_native_transport.Http_eio

let ( let* ) = Result.bind

type scope =
  { check_current : unit -> (unit, Dsl.error) result
  ; admit_network : unit -> (unit, Dsl.error) result
  }

type backend =
  { perform : Http.request -> (Native.response, Native.error) result
  ; download :
      request:Http.request
      -> destination:string
      -> maximum_bytes:int
      -> (Native.response, Native.error) result
  }

let native_backend ~sw ~clock ~network ~authenticator ~deadlines =
  let clock = Logseq_sync_native_transport.Transport_time.monotonic clock in
  { perform =
      (fun request ->
        Native.perform_with_deadlines
          ~setup_seconds:deadlines.Execute.Core.setup_seconds
          ~tls_handshake_seconds:deadlines.tls_handshake_seconds
          ~http_response_seconds:deadlines.http_response_seconds
          ~sw
          ~clock
          ~network
          ~authenticator
          request)
  ; download =
      (fun ~request ~destination ~maximum_bytes ->
        Native.download_with_deadlines
          ~setup_seconds:deadlines.setup_seconds
          ~tls_handshake_seconds:deadlines.tls_handshake_seconds
          ~download_seconds:deadlines.download_seconds
          ~http_response_seconds:deadlines.http_response_seconds
          ~sw
          ~clock
          ~network
          ~authenticator
          ~request
          ~destination
          ~maximum_bytes
          ~on_progress:(fun _ -> ()))
  }
;;

let domain_error = function
  | Native.Network message -> Dsl.Network_failure message
  | Native.Protocol message -> Dsl.Protocol_failure message
  | Native.Authentication message -> Dsl.Authentication_failure message
  | Native.Storage message -> Dsl.Storage_failure message
  | Native.Crypto message -> Dsl.Crypto_failure message
  | Native.Invalid_input message -> Dsl.Invalid_input message
;;

type t =
  { backend : backend
  ; token : epoch:int64 -> refresh:bool -> (string, Dsl.error) result
  }

let create ~backend ~token = { backend; token }

let request t ~scope ~epoch ~authenticated make_request perform =
  let attempt refresh =
    let* () = scope.check_current () in
    let* token =
      if authenticated then Result.map Option.some (t.token ~epoch ~refresh) else Ok None
    in
    let* () = scope.check_current () in
    let request = make_request token in
    let* () = scope.admit_network () in
    let* response = perform request |> Result.map_error domain_error in
    let* () = scope.check_current () in
    Ok response
  in
  try
    let* response = attempt false in
    let* response =
      if authenticated && response.Native.status = 401 then attempt true else Ok response
    in
    match response.Native.status with
    | 401 | 403 -> Error (Dsl.Authentication_failure "HTTP authorization failed")
    | status when status >= 200 && status < 300 -> Ok response
    | 404 -> Ok response
    | 429 -> Error (Dsl.Protocol_failure "HTTP rate limit exceeded (429)")
    | status when status >= 500 && status < 600 ->
      Error (Dsl.Protocol_failure (Printf.sprintf "HTTP server failure (%d)" status))
    | status ->
      Error (Dsl.Protocol_failure (Printf.sprintf "HTTP request rejected (%d)" status))
  with
  | Eio.Cancel.Cancelled _ as cancelled -> raise cancelled
  | Eio.Time.Timeout -> Error (Dsl.Network_failure "HTTP request deadline expired")
  | Invalid_argument _ -> Error (Dsl.Invalid_input "Invalid HTTP request")
  | _ -> Error (Dsl.Protocol_failure "Unexpected HTTP client failure")
;;

let perform t ~scope ~epoch ~authenticated make_request =
  request t ~scope ~epoch ~authenticated make_request t.backend.perform
;;

let download t ~scope ~epoch ~authenticated ~destination ~maximum_bytes make_request =
  request t ~scope ~epoch ~authenticated make_request (fun request ->
    t.backend.download ~request ~destination ~maximum_bytes)
;;

let asset_request
      ~identity
      ~asset
      ~(version : Logseq_db_types.Asset_descriptor.version)
      ~operation
      ~maximum_response_bytes
      token
  =
  let base_url = Uri.of_string identity.Dsl.origin in
  (match Http.validate_base_url base_url with
   | Ok () -> ()
   | Error message -> invalid_arg message);
  let uri =
    Uri.with_path
      base_url
      (Printf.sprintf
         "/assets/%s/%s.%s"
         (Uri.pct_encode identity.graph)
         (Logseq_db_types.Graph_types.Uuid.to_string asset)
         (Uri.pct_encode version.file_type))
  in
  let headers = Http.authorization (Option.get token) in
  let headers =
    match operation with
    | Http.Get -> headers
    | Put _ ->
      [ "x-amz-meta-checksum", version.checksum
      ; "x-amz-meta-type", version.file_type
      ; "content-type", "application/octet-stream"
      ]
      @ headers
  in
  Http.
    { operation
    ; uri
    ; headers
    ; maximum_response_bytes
    ; expected_content_type = Asset_binary
    }
;;

let get_asset t ~scope ~epoch ~identity ~asset ~version ~maximum_wire_bytes =
  if maximum_wire_bytes <= 0
  then Error (Dsl.Invalid_input "Asset HTTP bound")
  else
    let* response =
      perform
        t
        ~scope
        ~epoch
        ~authenticated:true
        (asset_request
           ~identity
           ~asset
           ~version
           ~operation:Http.Get
           ~maximum_response_bytes:maximum_wire_bytes)
    in
    if response.status = 404 then Ok None else Ok (Some response.body)
;;

let put_asset t ~scope ~epoch ~identity ~asset ~version ~wire =
  let* response =
    perform
      t
      ~scope
      ~epoch
      ~authenticated:true
      (asset_request
         ~identity
         ~asset
         ~version
         ~operation:(Http.Put wire)
         ~maximum_response_bytes:65536)
  in
  if response.status = 404
  then Error (Dsl.Protocol_failure "Asset upload endpoint unavailable")
  else Ok ()
;;
