let fail format = Printf.ksprintf failwith format

let require condition format =
  Printf.ksprintf (fun message -> if not condition then failwith message) format
;;

let require_ok = function
  | Ok value -> value
  | Error message -> fail "unexpected platform error: %s" message
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
  bytes
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
  bytes
;;

let test_calendar_packet_decodes_complete_bounded_facts () =
  require
    (Journal_platform.get_calendar_request = Bytes.of_string "LJP1\001\000\001\000")
    "calendar request bytes changed";
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
  require (Bytes.length request = 28) "format request length is %d" (Bytes.length request);
  require (Bytes.sub_string request 0 4 = "LJP1") "format request magic differs";
  require (Bytes.get_uint16_le request 6 = 4) "format request tag differs";
  require (Bytes.get_int64_le request 8 = 7L) "format request generation differs";
  require (Bytes.get_uint16_le request 16 = 2) "format request count differs";
  require
    (Bytes.get_int32_le request 20 = Int32.of_int 20260807)
    "first format request day differs";
  require
    (Bytes.get_int32_le request 24 = Int32.of_int 20260808)
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
  Bytes.set_int64_le bytes 8 6L;
  let stale = Journal_platform.decode_formatted_journal_days bytes |> require_ok in
  require (stale.generation = 6L) "stale generation was not preserved"
;;

let tests =
  [ "complete bounded calendar facts", test_calendar_packet_decodes_complete_bounded_facts
  ; ( "invalid calendar facts"
    , test_calendar_packet_rejects_missing_inconsistent_or_unbounded_facts )
  ; "DST fold", test_dst_fold_snapshots_preserve_distinct_instants_and_offsets
  ; "bounded format request", test_format_request_is_bounded_and_exact
  ; ( "formatted response generation"
    , test_formatted_response_decodes_and_preserves_generation )
  ]
;;

let () =
  List.iter
    (fun (name, test) ->
       Printf.printf "running %s\n%!" name;
       test ())
    tests
;;
