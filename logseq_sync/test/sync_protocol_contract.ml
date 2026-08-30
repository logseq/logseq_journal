module Protocol = Logseq_sync_pure_reducer.Sync_protocol
module Client = Protocol.Client
module Server = Protocol.Server

let fail format = Printf.ksprintf (fun message -> Alcotest.fail message) format
let uuid value = Logseq_db_types.Graph_types.Uuid.of_string value |> Result.get_ok
let tx_id = uuid "11111111-1111-4111-8111-111111111111"
let failed_tx_id = uuid "22222222-2222-4222-8222-222222222222"
let missing_block_id = uuid "33333333-3333-4333-8333-333333333333"

let require_ok label = function
  | Ok value -> value
  | Error error -> fail "%s: %s" label (Protocol.error_to_string error)
;;

let require_error label = function
  | Error error -> error
  | Ok _ -> fail "%s unexpectedly succeeded" label
;;

let contains source needle =
  let source_length = String.length source in
  let needle_length = String.length needle in
  let rec loop offset =
    offset + needle_length <= source_length
    && (String.equal (String.sub source offset needle_length) needle || loop (offset + 1))
  in
  needle_length = 0 || loop 0
;;

let client_round_trip message =
  Protocol.encode_client_message message
  |> require_ok "encode client message"
  |> Protocol.decode_client_message
  |> require_ok "decode client message"
;;

let server_round_trip message =
  Protocol.encode_server_message message
  |> require_ok "encode server message"
  |> Protocol.decode_server_message
  |> require_ok "decode server message"
;;

let test_all_client_messages_round_trip () =
  let messages =
    [ Client.Hello { client = "logseq-journal" }
    ; Client.Presence { editing_block_uuid = None }
    ; Client.Presence { editing_block_uuid = Some "block-1" }
    ; Client.Pull { since = None }
    ; Client.Pull { since = Some 7 }
    ; Client.Tx_batch { client_revision = None; t_before = 7; txs = [] }
    ; Client.Tx_batch
        { client_revision = Some "revision-1"
        ; t_before = 7
        ; txs =
            [ { tx = "transit"; tx_id = Some tx_id; outliner_op = Some "save-block" }
            ; { tx = "second"; tx_id = None; outliner_op = None }
            ]
        }
    ; Client.Ping
    ]
  in
  List.iter
    (fun message ->
       Alcotest.check
         Alcotest.bool
         "client message survives a symmetric codec round trip"
         true
         (client_round_trip message = message))
    messages;
  Alcotest.(check string)
    "pull uses canonical since"
    {|{"type":"pull","since":7}|}
    (Protocol.encode_client_message (Client.Pull { since = Some 7 })
     |> require_ok "encode canonical pull")
;;

let rejection
      ?t
      ?checksum
      ?(success_tx_ids = [])
      ?failed_tx_id
      ?(missing_block_uuids = [])
      ?error_detail
      ?data
      reason
  =
  Protocol.
    { reason
    ; t
    ; checksum
    ; success_tx_ids
    ; failed_tx_id
    ; missing_block_uuids
    ; error_detail
    ; data
    }
;;

let test_all_server_messages_round_trip () =
  let messages =
    [ Server.Hello { t = 7; checksum = Some "0123456789abcdef" }
    ; Server.Online_users
        { online_users =
            [ { user_id = "user-1"
              ; email = Some "user@example.com"
              ; username = Some "alice"
              ; name = Some "Alice"
              }
            ; { user_id = "user-2"; email = None; username = None; name = None }
            ]
        }
    ; Server.Presence { user_id = "user-1"; editing_block_uuid = None }
    ; Server.Presence { user_id = "user-1"; editing_block_uuid = Some "block-1" }
    ; Server.Pull_ok
        { t = 8
        ; checksum = None
        ; txs = [ { t = 8; tx = "transit"; outliner_op = None } ]
        }
    ; Server.Tx_batch_ok { t = 8; checksum = Some "fedcba9876543210" }
    ; Server.Changed { t = 9 }
    ; Server.Pong
    ; Server.Error { message = "server error" }
    ]
  in
  List.iter
    (fun message ->
       Alcotest.check
         Alcotest.bool
         "server message survives a symmetric codec round trip"
         true
         (server_round_trip message = message))
    messages
;;

let test_all_rejection_shapes_round_trip () =
  let messages =
    [ Server.Tx_reject (rejection ~t:9 Protocol.Stale)
    ; Server.Tx_reject (rejection Protocol.Empty_tx_data)
    ; Server.Tx_reject (rejection Protocol.Invalid_tx)
    ; Server.Tx_reject (rejection Protocol.Invalid_t_before)
    ; Server.Tx_reject (rejection ~t:9 Protocol.Snapshot_upload_in_progress)
    ; Server.Tx_reject
        (rejection
           ~t:10
           ~checksum:"0123456789abcdef"
           ~success_tx_ids:[ tx_id ]
           ~failed_tx_id
           ~missing_block_uuids:[ missing_block_id ]
           ~error_detail:"bounded detail"
           ~data:"bounded data"
           Protocol.Db_transact_failed)
    ]
  in
  List.iter
    (fun message ->
       Alcotest.check
         Alcotest.bool
         "rejection survives a symmetric codec round trip"
         true
         (server_round_trip message = message))
    messages
;;

let test_unknown_fields_are_strict_and_safe () =
  let secret = "never-render-this-secret" in
  let top =
    Protocol.decode_client_message
      (Printf.sprintf {|{"type":"ping","z-future":"%s","a-future":true}|} secret)
    |> require_error "unknown client field"
  in
  Alcotest.check Alcotest.bool "direction is client" true (top.direction = Protocol.Client);
  Alcotest.(check (option string))
    "message type is retained"
    (Some "ping")
    top.message_type;
  Alcotest.(check (list string)) "top-level path is root" [] top.path;
  Alcotest.check
    Alcotest.bool
    "unexpected field is named"
    true
    (top.kind = Protocol.Unexpected_fields [ "a-future"; "z-future" ]);
  let rendered = Protocol.error_to_string top in
  Alcotest.check
    Alcotest.bool
    "rendered error names field"
    true
    (contains rendered "a-future" && contains rendered "z-future");
  Alcotest.check
    Alcotest.bool
    "rendered error omits field value"
    false
    (contains rendered secret);
  let nested =
    Protocol.decode_client_message
      {|{"type":"tx/batch","t-before":0,"txs":[{"tx":"secret tx","extra":1}]}|}
    |> require_error "unknown transaction field"
  in
  Alcotest.(check (list string)) "nested path is precise" [ "txs"; "0" ] nested.path;
  Alcotest.check
    Alcotest.bool
    "nested unexpected field is named"
    true
    (nested.kind = Protocol.Unexpected_fields [ "extra" ]);
  Alcotest.check
    Alcotest.bool
    "nested error omits transaction"
    false
    (contains (Protocol.error_to_string nested) "secret tx");
  let pulled_transaction =
    Protocol.decode_server_message
      {|{"type":"pull/ok","t":1,"txs":[{"t":1,"tx":"secret tx","extra":1}]}|}
    |> require_error "unknown pulled transaction field"
  in
  Alcotest.(check (list string))
    "pulled transaction path is precise"
    [ "txs"; "0" ]
    pulled_transaction.path;
  Alcotest.check
    Alcotest.bool
    "pulled transaction field is named"
    true
    (pulled_transaction.kind = Protocol.Unexpected_fields [ "extra" ]);
  Alcotest.check
    Alcotest.bool
    "pulled transaction error omits transaction"
    false
    (contains (Protocol.error_to_string pulled_transaction) "secret tx");
  let presence =
    Protocol.decode_server_message
      {|{"type":"online-users","online-users":[{"user-id":"u1","future":true}]}|}
    |> require_error "unknown online user field"
  in
  Alcotest.check Alcotest.bool "direction is server" true (presence.direction = Server);
  Alcotest.(check (list string))
    "online-user path is precise"
    [ "online-users"; "0" ]
    presence.path
;;

let test_decode_errors_are_structured () =
  let invalid_json = Protocol.decode_server_message "{" |> require_error "invalid JSON" in
  Alcotest.check
    Alcotest.bool
    "invalid JSON is classified"
    true
    (invalid_json.kind = Protocol.Invalid_json);
  let non_object =
    Protocol.decode_server_message "[]" |> require_error "non-object server message"
  in
  Alcotest.check
    Alcotest.bool
    "non-object is classified"
    true
    (non_object.kind = Protocol.Expected_object);
  let missing =
    Protocol.decode_server_message {|{"type":"changed"}|}
    |> require_error "missing changed cursor"
  in
  Alcotest.check
    Alcotest.bool
    "missing field is classified"
    true
    (missing.kind = Protocol.Missing_field "t" && missing.path = []);
  let unsupported =
    Protocol.decode_server_message {|{"type":"future-message"}|}
    |> require_error "unsupported server message"
  in
  Alcotest.check
    Alcotest.bool
    "unsupported discriminator is classified"
    true
    (unsupported.kind = Protocol.Unsupported_message_type "future-message");
  let missing_nullable =
    Protocol.decode_server_message {|{"type":"presence","user-id":"u1"}|}
    |> require_error "missing required nullable presence field"
  in
  Alcotest.check
    Alcotest.bool
    "required nullable field must be present"
    true
    (missing_nullable.kind = Protocol.Missing_field "editing-block-uuid");
  let present_null =
    Protocol.decode_server_message
      {|{"type":"presence","user-id":"u1","editing-block-uuid":null}|}
    |> require_ok "nullable presence field"
  in
  Alcotest.check
    Alcotest.bool
    "required nullable field decodes null"
    true
    (present_null = Server.Presence { user_id = "u1"; editing_block_uuid = None })
;;

let test_protocol_validation_is_fail_closed () =
  let invalid_client_messages =
    [ {|{"type":"pull","since":-1}|}
    ; {|{"type":"pull","t":0}|}
    ; {|{"type":"tx/batch","t-before":0,"txs":[{"tx":"wire","tx-id":"not-a-uuid"}]}|}
    ]
  in
  List.iter
    (fun wire ->
       Alcotest.check
         Alcotest.bool
         "invalid client message is rejected"
         true
         (Result.is_error (Protocol.decode_client_message wire)))
    invalid_client_messages;
  let invalid_server_messages =
    [ {|{"type":"hello","t":0,"checksum":"short"}|}
    ; {|{"type":"pull/ok","t":-1,"txs":[]}|}
    ; {|{"type":"tx/reject","reason":"stale"}|}
    ; {|{"type":"tx/reject","reason":"invalid tx","success-tx-ids":["11111111-1111-4111-8111-111111111111"]}|}
    ; {|{"type":"tx/reject","reason":"future reason"}|}
    ]
  in
  List.iter
    (fun wire ->
       Alcotest.check
         Alcotest.bool
         "invalid server message is rejected"
         true
         (Result.is_error (Protocol.decode_server_message wire)))
    invalid_server_messages;
  Alcotest.check
    Alcotest.bool
    "negative typed cursor cannot be encoded"
    true
    (Result.is_error (Protocol.encode_client_message (Client.Pull { since = Some (-1) })));
  let oversized = String.make (Logseq_db_types.Limits.maximum_response_bytes + 1) 'x' in
  let error =
    Protocol.decode_server_message oversized |> require_error "oversized server message"
  in
  Alcotest.check
    Alcotest.bool
    "oversized frame is classified before JSON parsing"
    true
    (error.kind
     = Protocol.Limit_exceeded { maximum = Logseq_db_types.Limits.maximum_response_bytes }
    )
;;

let scenarios =
  [ Alcotest.test_case
      "all client messages round trip"
      `Quick
      test_all_client_messages_round_trip
  ; Alcotest.test_case
      "all server messages round trip"
      `Quick
      test_all_server_messages_round_trip
  ; Alcotest.test_case
      "all rejection shapes round trip"
      `Quick
      test_all_rejection_shapes_round_trip
  ; Alcotest.test_case
      "unknown fields are strict and safe"
      `Quick
      test_unknown_fields_are_strict_and_safe
  ; Alcotest.test_case
      "decode errors are structured"
      `Quick
      test_decode_errors_are_structured
  ; Alcotest.test_case
      "protocol validation is fail closed"
      `Quick
      test_protocol_validation_is_fail_closed
  ]
;;
