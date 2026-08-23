module T = Logseq_db_worker_test_support.Test_support
module H = Logseq_db_worker.Sync_http
module W = Logseq_db_worker.Sync_websocket
module Uuid = Logseq_db_worker.Graph_types.Uuid

let graph_id = Uuid.of_string "10000000-0000-4000-8000-000000000001" |> Result.get_ok
let base_url = Uri.of_string "https://api.logseq.io"
let token = "secret-token-value"

let contains text needle =
  let rec loop offset =
    if offset + String.length needle > String.length text
    then false
    else if String.sub text offset (String.length needle) = needle
    then true
    else loop (offset + 1)
  in
  String.length needle = 0 || loop 0
;;

let header name request =
  request.H.headers
  |> List.find_map (fun (actual, value) ->
    if String.equal (String.lowercase_ascii actual) name then Some value else None)
;;

let require_request request ~meth ~path ~query =
  T.require (request.H.meth = meth) "HTTP method changed";
  T.require (String.equal (Uri.path request.uri) path) "HTTP path changed";
  T.require (Uri.query request.uri = query) "HTTP query changed";
  T.require
    (header "authorization" request = Some ("Bearer " ^ token))
    "fresh ID token was not attached"
;;

let test_worker_constructs_every_endpoint () =
  require_request (H.catalog ~base_url ~token) ~meth:Get ~path:"/graphs" ~query:[];
  require_request
    (H.pull ~base_url ~graph_id ~since:(Some 41) ~token)
    ~meth:Get
    ~path:"/sync/10000000-0000-4000-8000-000000000001/pull"
    ~query:[ "since", [ "41" ] ];
  let tx =
    H.transaction_batch ~base_url ~graph_id ~token ~body:"{\"type\":\"tx/batch\"}"
  in
  require_request
    tx
    ~meth:Post
    ~path:"/sync/10000000-0000-4000-8000-000000000001/tx/batch"
    ~query:[];
  T.require (Option.is_some tx.body) "transaction body was dropped";
  require_request
    (H.snapshot_metadata ~base_url ~graph_id ~token)
    ~meth:Get
    ~path:"/sync/10000000-0000-4000-8000-000000000001/snapshot/download"
    ~query:[];
  require_request
    (H.e2ee_graph_key ~base_url ~graph_id ~token)
    ~meth:Get
    ~path:"/e2ee/graphs/10000000-0000-4000-8000-000000000001/aes-key"
    ~query:[];
  require_request
    (H.e2ee_user_keys ~base_url ~token)
    ~meth:Get
    ~path:"/e2ee/user-keys"
    ~query:[];
  let websocket = H.websocket_uri ~base_url ~graph_id |> Result.get_ok in
  T.require
    (String.equal (Uri.scheme websocket |> Option.get) "wss")
    "WebSocket is not WSS";
  T.require
    (String.equal (Uri.path websocket) "/sync/10000000-0000-4000-8000-000000000001")
    "WebSocket path changed";
  T.require
    (not (contains (H.redacted tx) token))
    "redacted HTTP diagnostics exposed token bytes";
  let signed_artifact =
    H.artifact
      ~uri:(Uri.of_string "https://objects.example/snapshot?X-Amz-Signature=url-secret")
      ~token
  in
  T.require
    (not (contains (H.redacted signed_artifact) "url-secret"))
    "redacted HTTP diagnostics exposed signed artifact query material"
;;

let test_endpoint_policy_is_fail_closed () =
  List.iter
    (fun value ->
       T.require
         (Result.is_error (H.validate_base_url (Uri.of_string value)))
         "unsafe base URL was accepted: %s"
         value)
    [ "http://api.logseq.io"
    ; "https://user@api.logseq.io"
    ; "https://api.logseq.io/#fragment"
    ; "https://api.logseq.io/product-path"
    ];
  T.require
    (Result.is_ok (H.validate_base_url base_url))
    "production HTTPS origin was rejected"
;;

let test_response_content_type_policy () =
  let structured = H.catalog ~base_url ~token in
  T.require
    (H.validate_response_content_type
       structured
       [ "content-type", "application/json; charset=utf-8" ]
     = Ok ())
    "structured JSON content type was rejected";
  T.require
    (H.validate_response_content_type
       structured
       [ "Content-Type", "application/transit+json" ]
     = Ok ())
    "structured Transit content type was rejected";
  T.require
    (Result.is_error
       (H.validate_response_content_type structured [ "content-type", "text/html" ]))
    "structured endpoint accepted HTML";
  T.require
    (Result.is_error (H.validate_response_content_type structured []))
    "structured endpoint accepted a missing content type";
  let artifact =
    H.artifact ~uri:(Uri.of_string "https://objects.example/snapshot") ~token
  in
  T.require
    (H.validate_response_content_type
       artifact
       [ "content-type", "application/octet-stream" ]
     = Ok ())
    "snapshot binary content type was rejected";
  T.require
    (H.validate_response_content_type artifact [] = Ok ())
    "snapshot without optional CDN content type was rejected";
  T.require
    (Result.is_error
       (H.validate_response_content_type artifact [ "content-type", "text/plain" ]))
    "snapshot endpoint accepted plain text"
;;

let test_websocket_handshake_generation_and_pull_hints () =
  let socket =
    W.create
      ~account_generation:2
      ~graph_generation:5
      ~connection_generation:7
      ~applied_server_t:41
  in
  let outgoing =
    W.opened socket ~account_generation:2 ~graph_generation:5 ~connection_generation:7
  in
  T.require
    (outgoing
     = [ Logseq_db_worker.Sync_protocol.encode_hello ~client:"logseq-journal"
       ; Logseq_db_worker.Sync_protocol.encode_pull ~since:41
       ])
    "WebSocket did not send hello then durable-cursor pull";
  T.require
    (W.receive
       socket
       ~account_generation:2
       ~graph_generation:4
       ~connection_generation:7
       {|{"type":"pull/ok","t":41,"txs":[]}|}
     = Ok Ignore_late)
    "late graph frame was delivered";
  T.require
    (W.receive
       socket
       ~account_generation:2
       ~graph_generation:5
       ~connection_generation:7
       {|{"type":"changed","t":44}|}
     = Ok (Pull_hint 44))
    "changed frame was not reduced to a pull hint";
  let reconnected = W.reconnect socket in
  T.require
    (W.connection_generation reconnected = 8)
    "reconnect did not fence the old connection";
  T.require
    (W.applied_server_t reconnected = 41)
    "reconnect did not retain durable cursor"
;;

let () =
  test_worker_constructs_every_endpoint ();
  test_endpoint_policy_is_fail_closed ();
  test_response_content_type_policy ();
  test_websocket_handshake_generation_and_pull_hints ()
;;
