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

let calendar_packet
      ?(tag = 3)
      ?(reason = 0)
      ?(instant_unix_ms = 1_786_055_400_000L)
      ?(local_day = 20260807)
      ?(local_minute_of_day = 30)
      ?(utc_offset_seconds = 7_200)
      ?(generation = 7L)
      ?(lifecycle_generation = 3L)
      ?(locale = "en_US")
      ?(time_zone_id = "Europe/Paris")
      ()
  =
  let header_size = 56 in
  let bytes =
    Bytes.make (header_size + String.length locale + String.length time_zone_id) '\000'
  in
  Bytes.blit_string "LJP1" 0 bytes 0 4;
  Bytes.set_uint16_le bytes 4 1;
  Bytes.set_uint16_le bytes 6 tag;
  Bytes.set_uint16_le bytes 8 reason;
  Bytes.set_uint16_le bytes 10 (String.length locale);
  Bytes.set_uint16_le bytes 12 (String.length time_zone_id);
  Bytes.set_int64_le bytes 16 instant_unix_ms;
  Bytes.set_int32_le bytes 24 (Int32.of_int local_day);
  Bytes.set_uint16_le bytes 28 local_minute_of_day;
  Bytes.set_int32_le bytes 32 (Int32.of_int utc_offset_seconds);
  Bytes.set_int64_le bytes 40 generation;
  Bytes.set_int64_le bytes 48 lifecycle_generation;
  Bytes.blit_string locale 0 bytes header_size (String.length locale);
  Bytes.blit_string
    time_zone_id
    0
    bytes
    (header_size + String.length locale)
    (String.length time_zone_id);
  envelope tag bytes
;;

let formatted_response ~generation headings =
  let size =
    20
    + List.fold_left
        (fun total (_, heading) -> total + 8 + String.length heading)
        0
        headings
  in
  let bytes = Bytes.make size '\000' in
  Bytes.blit_string "LJP1" 0 bytes 0 4;
  Bytes.set_uint16_le bytes 4 1;
  Bytes.set_uint16_le bytes 6 5;
  Bytes.set_int64_le bytes 8 generation;
  Bytes.set_uint16_le bytes 16 (List.length headings);
  ignore
    (List.fold_left
       (fun offset (day, heading) ->
          Bytes.set_int32_le bytes offset (Int32.of_int day);
          Bytes.set_uint16_le bytes (offset + 4) (String.length heading);
          Bytes.blit_string heading 0 bytes (offset + 8) (String.length heading);
          offset + 8 + String.length heading)
       20
       headings);
  envelope 5 bytes
;;

let lifecycle_packet ~kind ~generation =
  let payload = Bytes.make 16 '\000' in
  Bytes.blit_string "LJP1" 0 payload 0 4;
  Bytes.set_uint16_le payload 4 1;
  Bytes.set_uint16_le payload 6 kind;
  Bytes.set_int64_le payload 8 generation;
  envelope 15 payload
;;

let test_calendar_packet_decodes_complete_bounded_facts () =
  require
    (Bytes.length Journal_platform.get_calendar_request = 32
     && Bytes.sub_string Journal_platform.get_calendar_request 0 4 = "LJP2"
     && Bytes.get_uint16_le Journal_platform.get_calendar_request 6 = 1)
    "calendar request envelope changed";
  let decoded =
    calendar_packet ~reason:3 () |> Journal_platform.decode_calendar |> require_ok
  in
  require (decoded.reason = Journal_platform.Time_zone_changed) "calendar reason changed";
  require
    (decoded.snapshot.instant_unix_ms = 1_786_055_400_000L)
    "calendar instant changed";
  require (decoded.snapshot.local_day = 20260807) "calendar local day changed";
  require (decoded.snapshot.utc_offset_seconds = 7_200) "calendar offset changed";
  require (decoded.snapshot.generation = 7L) "calendar generation changed";
  require (String.equal decoded.snapshot.locale "en_US") "calendar locale changed";
  require
    (String.equal decoded.snapshot.time_zone_id "Europe/Paris")
    "calendar time-zone changed"
;;

let test_calendar_packet_rejects_missing_inconsistent_or_unbounded_facts () =
  [ calendar_packet ~locale:"" ()
  ; calendar_packet ~time_zone_id:"" ()
  ; calendar_packet ~local_day:20260229 ()
  ; calendar_packet ~local_minute_of_day:31 ()
  ; calendar_packet ~local_minute_of_day:1_440 ()
  ; calendar_packet ~utc_offset_seconds:64_801 ()
  ; calendar_packet ~generation:(-1L) ()
  ; calendar_packet ~lifecycle_generation:(-1L) ()
  ]
  |> List.iter (fun bytes ->
    require
      (Result.is_error (Journal_platform.decode_calendar bytes))
      "invalid calendar packet was accepted");
  require
    (Result.is_error (Journal_platform.decode_calendar (Bytes.of_string "bad")))
    "truncated calendar packet was accepted";
  require
    (Result.is_error
       (Journal_platform.decode_calendar
          (Bytes.cat (calendar_packet ()) (Bytes.of_string "x"))))
    "calendar packet with trailing bytes was accepted"
;;

let test_dst_fold_snapshots_preserve_distinct_instants_and_offsets () =
  let early =
    calendar_packet
      ~instant_unix_ms:1_762_061_400_000L
      ~local_day:20251102
      ~local_minute_of_day:90
      ~utc_offset_seconds:(-14_400)
      ~time_zone_id:"America/New_York"
      ()
    |> Journal_platform.decode_calendar
    |> require_ok
  in
  let late =
    calendar_packet
      ~instant_unix_ms:1_762_065_000_000L
      ~local_day:20251102
      ~local_minute_of_day:90
      ~utc_offset_seconds:(-18_000)
      ~time_zone_id:"America/New_York"
      ~generation:8L
      ()
    |> Journal_platform.decode_calendar
    |> require_ok
  in
  require
    (early.snapshot.instant_unix_ms <> late.snapshot.instant_unix_ms)
    "DST fold instants collapsed";
  require
    (early.snapshot.utc_offset_seconds <> late.snapshot.utc_offset_seconds)
    "DST fold offsets collapsed"
;;

let test_format_request_is_bounded_and_exact () =
  let request =
    Journal_platform.format_journal_days_request ~generation:7L [ 20260807; 20260808 ]
    |> require_ok
  in
  require (Bytes.length request = 60) "format request length is %d" (Bytes.length request);
  require (Bytes.sub_string request 0 4 = "LJP2") "format request magic differs";
  require (Bytes.get_uint16_le request 6 = 4) "format envelope tag differs";
  require (Bytes.get_int64_le request 40 = 7L) "format request generation differs";
  require (Bytes.get_uint16_le request 48 = 2) "format request count differs";
  require
    (Bytes.get_int32_le request 52 = Int32.of_int 20260807)
    "first format request day differs";
  require
    (Bytes.get_int32_le request 56 = Int32.of_int 20260808)
    "second format request day differs";
  let too_many = List.init 65 (fun index -> 20260101 + index) in
  require
    (Result.is_error
       (Journal_platform.format_journal_days_request ~generation:7L too_many))
    "format request accepted more than 64 days";
  require
    (Result.is_error
       (Journal_platform.format_journal_days_request
          ~generation:7L
          [ 20260807; 20260807 ]))
    "format request accepted duplicate days"
;;

let test_formatted_response_decodes_and_preserves_generation () =
  let bytes =
    formatted_response
      ~generation:7L
      [ 20260807, "Friday, August 7"
      ; 20260808, "\229\145\168\229\133\173\239\188\1408\230\156\1368\230\151\165"
      ]
  in
  let response = Journal_platform.decode_formatted_journal_days bytes |> require_ok in
  require (response.generation = 7L) "formatted response generation differs";
  require
    (List.assoc 20260807 response.headings = "Friday, August 7")
    "English heading differs";
  Bytes.set_int64_le bytes 40 6L;
  let stale = Journal_platform.decode_formatted_journal_days bytes |> require_ok in
  require (stale.generation = 6L) "stale generation was not preserved"
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

let tests =
  [ "complete bounded calendar facts", test_calendar_packet_decodes_complete_bounded_facts
  ; ( "invalid calendar facts"
    , test_calendar_packet_rejects_missing_inconsistent_or_unbounded_facts )
  ; "DST fold", test_dst_fold_snapshots_preserve_distinct_instants_and_offsets
  ; "bounded format request", test_format_request_is_bounded_and_exact
  ; ( "formatted response generation"
    , test_formatted_response_decodes_and_preserves_generation )
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
