module T = Logseq_db_worker_test_support.Test_support
module Protocol = Logseq_db_worker.Sync_protocol

let expect_ok label = function
  | Ok value -> value
  | Error message -> T.fail "%s: %s" label message
;;

let expect_error label = function
  | Error _ -> ()
  | Ok _ -> T.fail "%s unexpectedly succeeded" label
;;

let fixture () = T.read_json (T.fixture "sync/upstream-fab2774-protocol.json")
let wire name = fixture () |> Yojson.Safe.Util.member name |> Yojson.Safe.to_string

let deployed_duplicate_fixture () =
  T.read_json (T.fixture "sync/deployed-duplicate-tx-id-stale.json")
;;

let decode_server_messages_case () =
  (match expect_ok "hello" (Protocol.decode_server_message (wire "hello")) with
   | Protocol.Hello { t = 41; checksum = Some checksum } ->
     T.require (String.length checksum = 16) "hello checksum changed"
   | _ -> T.fail "hello decoded to the wrong message");
  (match expect_ok "pull/ok" (Protocol.decode_server_message (wire "pullOk")) with
   | Protocol.Pull_ok { t = 43; checksum = Some checksum; txs = [ first; second ] } ->
     T.require (String.length checksum = 16) "pull checksum changed";
     T.require (first.t = 42 && second.t = 43) "transaction cursor changed";
     T.require (first.outliner_op = Some "save-block") "outliner-op changed";
     T.require (second.outliner_op = None) "missing outliner-op was invented"
   | _ -> T.fail "pull/ok decoded to the wrong message");
  (match expect_ok "changed" (Protocol.decode_server_message (wire "changed")) with
   | Protocol.Changed { t = 43 } -> ()
   | _ -> T.fail "changed decoded to the wrong message");
  (match expect_ok "tx/batch/ok" (Protocol.decode_server_message (wire "txBatchOk")) with
   | Protocol.Tx_batch_ok { t = 44; _ } -> ()
   | _ -> T.fail "tx/batch/ok decoded to the wrong message");
  match expect_ok "error" (Protocol.decode_server_message (wire "error")) with
  | Protocol.Server_error { message = "invalid since" } -> ()
  | _ -> T.fail "error decoded to the wrong message"
;;

let optional_server_checksum_case () =
  (match
     expect_ok
       "checksum-free hello"
       (Protocol.decode_server_message (wire "helloWithoutChecksum"))
   with
   | Protocol.Hello { t = 5; _ } -> ()
   | _ -> T.fail "checksum-free hello decoded to the wrong message");
  (match
     expect_ok
       "checksum-free pull/ok"
       (Protocol.decode_http_pull_response (wire "pullOkWithoutChecksum"))
   with
   | Protocol.Pull_ok { t = 5; txs = []; _ } -> ()
   | _ -> T.fail "checksum-free pull/ok decoded to the wrong message");
  (match
     expect_ok
       "checksum-free tx/batch/ok"
       (Protocol.decode_server_message (wire "txBatchOkWithoutChecksum"))
   with
   | Protocol.Tx_batch_ok { t = 6; _ } -> ()
   | _ -> T.fail "checksum-free tx/batch/ok decoded to the wrong message");
  expect_error
    "invalid optional checksum"
    (Protocol.decode_http_pull_response
       {|{"type":"pull/ok","t":5,"checksum":"bad","txs":[]}|});
  expect_error
    "non-string optional checksum"
    (Protocol.decode_http_pull_response
       {|{"type":"pull/ok","t":5,"checksum":null,"txs":[]}|})
;;

let decode_rejections_case () =
  (match
     expect_ok "stale reject" (Protocol.decode_server_message (wire "staleReject"))
   with
   | Protocol.Tx_reject
       { reason = Stale; t = Some 44; success_tx_ids = []; failed_tx_id = None; _ } -> ()
   | _ -> T.fail "stale reject lost its cursor");
  (match
     expect_ok "partial reject" (Protocol.decode_server_message (wire "partialReject"))
   with
   | Protocol.Tx_reject
       { reason = Db_transact_failed
       ; t = Some 45
       ; success_tx_ids = [ "11111111-1111-4111-8111-111111111111" ]
       ; failed_tx_id = Some "22222222-2222-4222-8222-222222222222"
       ; _
       } -> ()
   | _ -> T.fail "partial reject lost accepted or failed transaction ids");
  let permanent =
    fixture ()
    |> Yojson.Safe.Util.member "permanentRejects"
    |> Yojson.Safe.Util.to_list
    |> List.map (fun value ->
      expect_ok
        "permanent reject"
        (Protocol.decode_server_message (Yojson.Safe.to_string value)))
  in
  let reasons =
    List.map
      (function
        | Protocol.Tx_reject { reason; _ } -> reason
        | _ -> T.fail "permanent reject decoded to the wrong message")
      permanent
  in
  T.require
    (reasons
     = [ Protocol.Empty_tx_data
       ; Invalid_tx
       ; Invalid_t_before
       ; Snapshot_upload_in_progress
       ])
    "permanent rejection forms changed"
;;

let deployed_duplicate_tx_id_case () =
  let fixture = deployed_duplicate_fixture () in
  let member name = fixture |> Yojson.Safe.Util.member name |> Yojson.Safe.to_string in
  (match
     expect_ok
       "deployed first response"
       (Protocol.decode_server_message (member "first-response"))
   with
   | Protocol.Tx_batch_ok { t = 115; checksum = Some "a57d8ae9dc79e209" } -> ()
   | _ -> T.fail "deployed first submission response changed");
  (match
     expect_ok
       "deployed repeated response"
       (Protocol.decode_server_message (member "repeat-response"))
   with
   | Protocol.Tx_reject
       { reason = Stale; t = Some 115; success_tx_ids = []; failed_tx_id = None; _ } -> ()
   | _ -> T.fail "deployed duplicate submission did not preserve generic stale evidence");
  match
    expect_ok
      "deployed final pull"
      (Protocol.decode_http_pull_response (member "final-pull"))
  with
  | Protocol.Pull_ok
      { t = 115
      ; checksum = Some "a57d8ae9dc79e209"
      ; txs = [ { t = 115; outliner_op = None; _ } ]
      } -> ()
  | _ -> T.fail "deployed duplicate submission advanced or duplicated server state"
;;

let strict_validation_case () =
  expect_error
    "negative server t"
    (Protocol.decode_server_message {|{"type":"changed","t":-1}|});
  expect_error
    "invalid checksum"
    (Protocol.decode_server_message {|{"type":"hello","t":1,"checksum":"bad"}|});
  expect_error
    "malformed partial reject"
    (Protocol.decode_server_message
       {|{"type":"tx/reject","reason":"db transact failed","t":2,"success-tx-ids":["not-a-uuid"],"failed-tx-id":"22222222-2222-4222-8222-222222222222"}|});
  expect_error
    "invalid pull outliner-op"
    (Protocol.decode_server_message
       {|{"type":"pull/ok","t":1,"txs":[{"t":1,"tx":"[]","outliner-op":7}]}|});
  expect_error
    "unknown server message"
    (Protocol.decode_server_message {|{"type":"future-message"}|});
  expect_error "Chat SSE event" (Protocol.decode_server_message (wire "chatSseEvent"))
;;

let presence_message_case () =
  ignore
    (expect_ok
       "online users presence"
       (Protocol.decode_server_message
          {|{"type":"online-users","online-users":[{"user-id":"user-1"}]}|}));
  expect_error
    "malformed online users presence"
    (Protocol.decode_server_message {|{"type":"online-users","online-users":"user-1"}|})
;;

let transport_parity_case () =
  let ws = expect_ok "WebSocket pull" (Protocol.decode_server_message (wire "pullOk")) in
  let http = expect_ok "HTTP pull" (Protocol.decode_http_pull_response (wire "pullOk")) in
  T.require (ws = http) "HTTP and WebSocket pull semantics diverged";
  expect_error
    "HTTP non-pull response"
    (Protocol.decode_http_pull_response (wire "hello"))
;;

let cursor_and_checksum_case () =
  let pull =
    expect_ok "pull fixture" (Protocol.decode_http_pull_response (wire "pullOk"))
  in
  ignore
    (expect_ok "continuous pull" (Protocol.validate_pull_continuity ~applied_t:41 pull));
  expect_error "cursor gap" (Protocol.validate_pull_continuity ~applied_t:40 pull);
  expect_error "cursor replay" (Protocol.validate_pull_continuity ~applied_t:42 pull);
  ignore
    (expect_ok
       "matching checksum"
       (Protocol.validate_checksum ~local:"abc" ~remote:"abc"));
  expect_error
    "checksum mismatch"
    (Protocol.validate_checksum ~local:"local-checksum" ~remote:"remote-checksum")
;;

let client_encoding_case () =
  let json wire = Yojson.Safe.from_string wire in
  T.require
    (json (Protocol.encode_hello ~client:"journal-device")
     = `Assoc [ "type", `String "hello"; "client", `String "journal-device" ])
    "hello encoding changed";
  T.require
    (json (Protocol.encode_pull ~since:41)
     = `Assoc [ "type", `String "pull"; "since", `Int 41 ])
    "pull encoding changed";
  let entry =
    Protocol.
      { tx = "[]"
      ; tx_id = "33333333-3333-4333-8333-333333333333"
      ; outliner_op = Some "save-block"
      }
  in
  let batch =
    json (expect_ok "tx/batch encoding" (Protocol.encode_tx_batch ~t_before:41 [ entry ]))
  in
  let open Yojson.Safe.Util in
  T.require (batch |> member "type" |> to_string = "tx/batch") "tx/batch type changed";
  T.require (batch |> member "t-before" |> to_int = 41) "tx/batch cursor changed";
  T.require (batch |> member "txs" |> to_list |> List.length = 1) "tx/batch entry lost";
  let tx_ids =
    expect_ok
      "tx/batch stable IDs"
      (Protocol.decode_tx_batch_ids (Yojson.Safe.to_string batch))
  in
  T.require
    (tx_ids
     = [ Logseq_db_worker.Graph_types.Uuid.of_string
           "33333333-3333-4333-8333-333333333333"
         |> Result.get_ok
       ])
    "tx/batch stable IDs were not recoverable by the transport owner";
  expect_error
    "duplicate tx/batch IDs"
    (Protocol.decode_tx_batch_ids
       {|{"type":"tx/batch","t-before":41,"txs":[{"tx":"[]","tx-id":"33333333-3333-4333-8333-333333333333"},{"tx":"[]","tx-id":"33333333-3333-4333-8333-333333333333"}]}|});
  expect_error
    "non-batch outgoing message"
    (Protocol.decode_tx_batch_ids (Protocol.encode_pull ~since:41));
  expect_error "negative t-before" (Protocol.encode_tx_batch ~t_before:(-1) [ entry ])
;;

let cases =
  [ T.case "decode upstream server messages" decode_server_messages_case
  ; T.case
      "accept omitted server checksums but validate them when present"
      optional_server_checksum_case
  ; T.case "decode every tx/reject form" decode_rejections_case
  ; T.case
      "preserve deployed duplicate tx-id stale evidence"
      deployed_duplicate_tx_id_case
  ; T.case "reject malformed and Chat-only messages" strict_validation_case
  ; T.case "accept deployed online-users presence messages" presence_message_case
  ; T.case "keep HTTP pull identical to WebSocket pull" transport_parity_case
  ; T.case "reject cursor gaps and checksum mismatches" cursor_and_checksum_case
  ; T.case "encode upstream client messages" client_encoding_case
  ]
;;

let () = T.run "sync protocol" cases
