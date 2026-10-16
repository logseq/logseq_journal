let fail format = Printf.ksprintf failwith format

let require condition format =
  Printf.ksprintf (fun message -> if not condition then failwith message) format
;;

let require_ok = function
  | Ok value -> value
  | Error message -> fail "unexpected platform error: %s" message
;;

let envelope ?(runtime_generation = 0L) ?(graph_generation = 0L) tag payload =
  let bytes = Bytes.make (32 + Bytes.length payload) '\000' in
  Bytes.blit_string "LJP2" 0 bytes 0 4;
  Bytes.set_uint16_le bytes 4 2;
  Bytes.set_uint16_le bytes 6 tag;
  Bytes.set_int64_le bytes 8 runtime_generation;
  Bytes.set_int64_le bytes 16 graph_generation;
  Bytes.set_int32_le bytes 24 (Int32.of_int (Bytes.length payload));
  Bytes.blit payload 0 bytes 32 (Bytes.length payload);
  bytes
;;

let lifecycle_packet ~kind ~generation =
  let payload = Bytes.make 16 '\000' in
  Bytes.blit_string "LJP1" 0 payload 0 4;
  Bytes.set_uint16_le payload 4 1;
  Bytes.set_uint16_le payload 6 kind;
  Bytes.set_int64_le payload 8 generation;
  envelope 15 payload
;;

let test_auth_capability_envelopes_are_bounded_and_protocol_free () =
  require
    (Bytes.get_uint16_le Journal_platform.authenticated_user_request 6 = 6)
    "authenticated-user request tag differs";
  let authenticated =
    envelope 7 (Bytes.of_string {|{"userId":"cognito-user-1"}|})
    |> Journal_platform.decode_authenticated_user
    |> require_ok
  in
  require (authenticated = Some "cognito-user-1") "authenticated-user response changed";
  require
    (Journal_platform.decode_authenticated_user
       (envelope 7 (Bytes.of_string {|{"userId":null}|})) = Ok None)
    "explicit absent authenticated user was rejected";
  let token =
    envelope
      9
      (Bytes.of_string {|{"challengeId":"challenge-1","token":"fresh-id-token"}|})
    |> Journal_platform.decode_id_token_response ~challenge_id:"challenge-1"
    |> require_ok
  in
  require (String.equal token "fresh-id-token") "fresh ID token response changed"
;;

let test_sign_out_capability_is_bounded_and_acknowledged () =
  require
    (Bytes.length Journal_platform.sign_out_request = 32
     && Bytes.get_uint16_le Journal_platform.sign_out_request 6 = 10)
    "sign-out request envelope changed";
  envelope 11 (Bytes.of_string {|{"signedOut":true}|})
  |> Journal_platform.decode_sign_out_response
  |> require_ok;
  require
    (Result.is_error
       (Journal_platform.decode_sign_out_response
          (envelope 11 (Bytes.of_string {|{"signedOut":false}|}))))
    "failed sign-out acknowledgement was accepted"
;;

let test_local_account_binding_is_bounded_and_origin_scoped () =
  require
    (Bytes.length Journal_platform.local_account_binding_request = 32
     && Bytes.get_uint16_le Journal_platform.local_account_binding_request 6 = 20)
    "local-account-binding request envelope changed";
  let binding =
    envelope
      21
      (Bytes.of_string
         {|{"userId":"cognito-user-1","managedSyncOrigin":"https://api.logseq.io"}|})
    |> Journal_platform.decode_local_account_binding
    |> require_ok
  in
  (match binding with
   | Some binding ->
     require (String.equal binding.user_id "cognito-user-1") "binding user changed";
     require
       (String.equal binding.managed_sync_origin "https://api.logseq.io")
       "binding origin changed"
   | None -> fail "valid local account binding decoded as absent");
  require
    (Journal_platform.decode_local_account_binding
       (envelope 21 (Bytes.of_string {|{"userId":null,"managedSyncOrigin":null}|}))
     = Ok None)
    "absent local account binding was rejected";
  require
    (Result.is_error
       (Journal_platform.decode_local_account_binding
          (envelope
             21
             (Bytes.of_string
                {|{"userId":"cognito-user-1","managedSyncOrigin":"http://api.logseq.io"}|}))))
    "insecure managed-sync origin was accepted"
;;

let test_timeline_presentation_handshake_is_bounded () =
  let request = Journal_platform.timeline_presented_request in
  require (Bytes.get_uint16_le request 6 = 22) "Timeline request tag changed";
  require (Bytes.length request = 32) "Timeline request payload is not empty";
  envelope 23 (Bytes.of_string {|{"presented":true}|})
  |> Journal_platform.decode_timeline_presented
  |> require_ok;
  require
    (Result.is_error
       (Journal_platform.decode_timeline_presented
          (envelope 23 (Bytes.of_string {|{"presented":false}|}))))
    "negative Timeline presentation acknowledgement was accepted"
;;

let test_termination_handshake_is_bounded_and_acknowledged () =
  require
    (Journal_platform.is_prepare_to_terminate_event (envelope 12 Bytes.empty))
    "prepare-to-terminate event was rejected";
  require
    (not
       (Journal_platform.is_prepare_to_terminate_event
          (envelope 12 (Bytes.of_string "unexpected"))))
    "prepare-to-terminate event accepted a payload";
  require
    (Bytes.length Journal_platform.termination_ready_request = 32
     && Bytes.get_uint16_le Journal_platform.termination_ready_request 6 = 13)
    "termination-ready request envelope changed";
  envelope 14 (Bytes.of_string {|{"ready":true}|})
  |> Journal_platform.decode_termination_ready_response
  |> require_ok
;;

let test_network_lifecycle_epochs_are_bounded_and_typed () =
  (match
     lifecycle_packet ~kind:1 ~generation:7L
     |> Journal_platform.decode_network_lifecycle
     |> require_ok
   with
   | Journal_platform.Backgrounded { generation = 7L } -> ()
   | Backgrounded _ | Foreground_resumed _ -> fail "background lifecycle changed");
  (match
     lifecycle_packet ~kind:2 ~generation:7L
     |> Journal_platform.decode_network_lifecycle
     |> require_ok
   with
   | Journal_platform.Foreground_resumed { generation = 7L } -> ()
   | Backgrounded _ | Foreground_resumed _ -> fail "foreground lifecycle changed");
  [ lifecycle_packet ~kind:0 ~generation:7L
  ; lifecycle_packet ~kind:3 ~generation:7L
  ; lifecycle_packet ~kind:1 ~generation:(-1L)
  ; envelope 15 Bytes.empty
  ]
  |> List.iter (fun packet ->
    require
      (Result.is_error (Journal_platform.decode_network_lifecycle packet))
      "invalid network lifecycle packet was accepted")
;;

let test_clipboard_is_bounded_and_acknowledged () =
  List.iter
    (fun text ->
       let request = Journal_platform.copy_text_request ~text |> require_ok in
       require (Bytes.get_uint16_le request 6 = 28) "clipboard request tag differs";
       let payload =
         Bytes.sub_string request 32 (Bytes.length request - 32)
         |> Yojson.Safe.from_string
         |> Yojson.Safe.Util.member "text"
         |> Yojson.Safe.Util.to_string
       in
       require (payload = text) "clipboard text was altered")
    [ ""; "Root\n  - 中文😀" ];
  require
    (Result.is_error
       (Journal_platform.copy_text_request ~text:(String.make (256 * 1024) '\n')))
    "oversized clipboard envelope was accepted";
  envelope 29 (Bytes.of_string {|{"copied":true}|})
  |> Journal_platform.decode_copy_text_response
  |> require_ok;
  require
    (Result.is_error
       (Journal_platform.decode_copy_text_response
          (envelope 29 (Bytes.of_string {|{"copied":false}|}))))
    "failed clipboard write was accepted"
;;

let test_generated_native_decoders_reject_untyped_payloads () =
  require
    (Result.is_error
       (Journal_environment.decode_json
          (`Assoc
             [ "brightness", `String "light"; "platform", `String "ios"
             ; "accessibleNavigation", `Bool false; "highContrast", `Bool false
             ; "unsupported", `Bool true ])))
    "environment accepted an unknown generated-record field";
  require
    (Result.is_error (Journal_asset_import.decode_event {|{"action":"unavailable"}|}))
    "picker accepted unavailable without its required reason";
  require
    (Result.is_error
       (Journal_asset_import.decode_event {|{"action":"picked-batch","items":[],"request":{"id":"7"}}|}))
    "picker accepted a malformed request identity"
;;

let test_generated_environment_roundtrip () =
  List.iter
    (fun (brightness : Journal_environment.brightness) ->
       let snapshot : Journal_environment.snapshot =
         { brightness; platform = "ios"; accessible_navigation = true; high_contrast = false }
       in
       require
         (Journal_environment.decode_json (Journal_environment.encode_json snapshot) = Ok snapshot)
         "environment did not roundtrip")
    [ Light; Dark ]
;;

let test_generated_picker_preserves_uuid_validation () =
  let payload =
    {|{"action":"picked","selection":{"operation":"invalid","asset":"11111111-1111-4111-8111-111111111111","localMutation":"22222222-2222-4222-8222-222222222222","metadataMutation":"33333333-3333-4333-8333-333333333333","path":"/tmp/pick.png","title":"pick","type":"png"}}|}
  in
  require (Result.is_error (Journal_asset_import.decode_event payload))
    "generated picker decoder bypassed UUID validation";
  require
    (Result.is_error (Journal_asset_import.decode_event {|{"action":"picked-batch","items":[{}]}|}))
    "generated picker decoder accepted an invalid batch member"
;;

(* Account JSON is owned by the platform byte decoder. The startup reducer only
   sees its result and cannot reproduce omitted fields without injecting that result. *)
let test_account_fields_are_required () =
  let accepted tag decode sources =
    List.filter_map
      (fun source ->
         if Result.is_error (decode (envelope tag (Bytes.of_string source))) then None
         else Some (Printf.sprintf "tag %d %s" tag source)) sources
  in
  let malformed =
    accepted 7 Journal_platform.decode_authenticated_user [ "{}" ]
    @ accepted 21 Journal_platform.decode_local_account_binding
        [ "{}"; {|{"userId":null}|}; {|{"managedSyncOrigin":null}|}
        ; {|{"userId":"cognito-user-1"}|}
        ; {|{"managedSyncOrigin":"https://api.logseq.io"}|} ]
  in
  require (malformed = []) "missing account fields accepted: %s"
    (String.concat "; " malformed)
;;

let tests =
  [ "required account fields", test_account_fields_are_required
  ; "generated native decoders", test_generated_native_decoders_reject_untyped_payloads
  ; "generated environment roundtrip", test_generated_environment_roundtrip
  ; "generated picker UUIDs", test_generated_picker_preserves_uuid_validation
  ; "clipboard text", test_clipboard_is_bounded_and_acknowledged
  ; ( "bounded auth capability"
    , test_auth_capability_envelopes_are_bounded_and_protocol_free )
  ; "sign-out capability", test_sign_out_capability_is_bounded_and_acknowledged
  ; "local account binding", test_local_account_binding_is_bounded_and_origin_scoped
  ; "Timeline presentation handshake", test_timeline_presentation_handshake_is_bounded
  ; "termination handshake", test_termination_handshake_is_bounded_and_acknowledged
  ; "network lifecycle epochs", test_network_lifecycle_epochs_are_bounded_and_typed
  ]
;;

let () =
  List.iter
    (fun (name, test) ->
       Printf.printf "running %s\n%!" name;
       test ())
    tests
;;
