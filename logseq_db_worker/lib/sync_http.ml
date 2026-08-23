type meth =
  | Get
  | Post

type expected_content_type =
  | Structured_response
  | Snapshot_artifact

type request =
  { meth : meth
  ; uri : Uri.t
  ; headers : (string * string) list
  ; body : string option
  ; maximum_response_bytes : int
  ; expected_content_type : expected_content_type
  }

let validate_base_url uri =
  match Uri.scheme uri, Uri.host uri, Uri.userinfo uri, Uri.fragment uri with
  | Some "https", Some host, None, None
    when String.length host > 0
         && (Uri.path uri = "" || Uri.path uri = "/")
         && Uri.query uri = [] -> Ok ()
  | Some _, Some _, _, _ | Some _, None, _, _ | None, _, _, _ ->
    Error "sync base URL must be one HTTPS origin without credentials or fragments"
;;

let require_base_url base_url =
  match validate_base_url base_url with
  | Ok () -> ()
  | Error message -> invalid_arg message
;;

let authorization token =
  if String.length token = 0 || String.length token > 1024 * 1024
  then invalid_arg "ID token must be bounded and non-empty";
  [ "authorization", "Bearer " ^ token; "accept", "application/transit+json" ]
;;

let create
      ?body
      ?(maximum_response_bytes = Protocol.maximum_response_bytes)
      ~meth
      ~base_url
      ~path
      ~query
      ~token
      ()
  =
  require_base_url base_url;
  let uri = Uri.with_path base_url path |> fun uri -> Uri.with_query' uri query in
  let headers =
    match body with
    | None -> authorization token
    | Some _ -> ("content-type", "application/json") :: authorization token
  in
  { meth
  ; uri
  ; headers
  ; body
  ; maximum_response_bytes
  ; expected_content_type = Structured_response
  }
;;

let graph_path graph_id suffix =
  Printf.sprintf "/sync/%s/%s" (Graph_types.Uuid.to_string graph_id) suffix
;;

let catalog ~base_url ~token =
  create ~meth:Get ~base_url ~path:"/graphs" ~query:[] ~token ()
;;

let pull ~base_url ~graph_id ~since ~token =
  let query =
    Option.fold ~none:[] ~some:(fun since -> [ "since", string_of_int since ]) since
  in
  let maximum_response_bytes =
    match since with
    | None -> 64 * 1024 * 1024
    | Some _ -> Protocol.maximum_response_bytes
  in
  create
    ~meth:Get
    ~base_url
    ~path:(graph_path graph_id "pull")
    ~query
    ~token
    ~maximum_response_bytes
    ()
;;

let transaction_batch ~base_url ~graph_id ~token ~body =
  create
    ~meth:Post
    ~base_url
    ~path:(graph_path graph_id "tx/batch")
    ~query:[]
    ~token
    ~body
    ()
;;

let snapshot_metadata ~base_url ~graph_id ~token =
  create
    ~meth:Get
    ~base_url
    ~path:(graph_path graph_id "snapshot/download")
    ~query:[]
    ~token
    ()
;;

let e2ee_graph_key ~base_url ~graph_id ~token =
  create
    ~meth:Get
    ~base_url
    ~path:(Printf.sprintf "/e2ee/graphs/%s/aes-key" (Graph_types.Uuid.to_string graph_id))
    ~query:[]
    ~token
    ()
;;

let e2ee_user_keys ~base_url ~token =
  create ~meth:Get ~base_url ~path:"/e2ee/user-keys" ~query:[] ~token ()
;;

let valid_artifact uri =
  match Uri.scheme uri, Uri.host uri, Uri.userinfo uri, Uri.fragment uri with
  | Some "https", Some host, None, None when String.length host > 0 -> true
  | Some _, Some _, _, _ | Some _, None, _, _ | None, _, _, _ -> false
;;

let artifact ~uri ~token =
  if not (valid_artifact uri) then invalid_arg "snapshot artifact URL is unsafe";
  { meth = Get
  ; uri
  ; headers = authorization token
  ; body = None
  ; maximum_response_bytes = max_int
  ; expected_content_type = Snapshot_artifact
  }
;;

let response_header name headers =
  List.find_map
    (fun (actual, value) ->
       if String.equal (String.lowercase_ascii actual) name then Some value else None)
    headers
;;

let media_type value =
  value |> String.split_on_char ';' |> List.hd |> String.trim |> String.lowercase_ascii
;;

let structured_media_type value =
  String.equal value "application/json"
  || String.equal value "application/transit+json"
  || String.ends_with ~suffix:"+json" value
;;

let artifact_media_type value =
  List.mem
    value
    [ "application/octet-stream"
    ; "application/gzip"
    ; "application/x-gzip"
    ; "application/transit+json"
    ; "binary/octet-stream"
    ]
;;

let validate_response_content_type request headers =
  match
    ( request.expected_content_type
    , Option.map media_type (response_header "content-type" headers) )
  with
  | Snapshot_artifact, None -> Ok ()
  | Structured_response, None -> Error "sync HTTP response is missing Content-Type"
  | expected_content_type, Some value ->
    let accepted =
      match expected_content_type with
      | Structured_response -> structured_media_type value
      | Snapshot_artifact -> artifact_media_type value
    in
    if accepted
    then Ok ()
    else Error (Printf.sprintf "sync HTTP response has unsupported Content-Type %s" value)
;;

let websocket_uri ~base_url ~graph_id =
  match validate_base_url base_url with
  | Error _ as error -> error
  | Ok () ->
    let uri =
      Uri.with_scheme base_url (Some "wss")
      |> fun uri ->
      Uri.with_path uri (Printf.sprintf "/sync/%s" (Graph_types.Uuid.to_string graph_id))
    in
    Ok uri
;;

let redacted request =
  let meth =
    match request.meth with
    | Get -> "GET"
    | Post -> "POST"
  in
  let uri = Uri.with_query' request.uri [] in
  Printf.sprintf
    "%s %s body-bytes=%d max-response-bytes=%d"
    meth
    (Uri.to_string uri)
    (Option.fold ~none:0 ~some:String.length request.body)
    request.maximum_response_bytes
;;
