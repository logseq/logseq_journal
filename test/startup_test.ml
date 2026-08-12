let fail format = Printf.ksprintf failwith format

let require condition format =
  Printf.ksprintf (fun message -> if not condition then failwith message) format
;;

let has_substring string fragment =
  let string_length = String.length string in
  let fragment_length = String.length fragment in
  let rec loop index =
    if index + fragment_length > string_length
    then false
    else if String.sub string index fragment_length = fragment
    then true
    else loop (index + 1)
  in
  fragment_length = 0 || loop 0
;;

let require_equal_string ~expected ~actual =
  if not (String.equal expected actual) then fail "expected %S, got %S" expected actual
;;

let require_equal_int ~expected ~actual =
  if expected <> actual then fail "expected %d, got %d" expected actual
;;

let require_equal_int64 ~expected ~actual =
  if not (Int64.equal expected actual) then fail "expected %Ld, got %Ld" expected actual
;;

let sample_calendar : Journal_startup.calendar_snapshot =
  { instant_unix_ms = 1_786_055_400_000L
  ; local_day = 20260807
  ; local_minute_of_day = 30
  ; locale = "en_US"
  ; time_zone_id = "Europe/Paris"
  ; utc_offset_seconds = 7200
  ; generation = 7L
  ; lifecycle_generation = 0L
  }
;;

let sample : Journal_startup.t =
  { application_support_root = "/tmp/support"
  ; expected_schema_version = 1
  ; initial_calendar = sample_calendar
  ; access_mode = Read_write
  ; diagnostic_mode = Operational_only
  }
;;

let expected_bytes =
  Bytes.of_string
    ("LJR1"
     ^ "\x01\x00\x00\x00"
     ^ "\x0c\x00\x00\x00"
     ^ "\x05\x00\x00\x00"
     ^ "\x0c\x00\x00\x00"
     ^ "\x00\x00\x00\x00"
     ^ "\x40\x9a\x32\xd9\x9f\x01\x00\x00"
     ^ "\xc7\x27\x35\x01"
     ^ "\x1e\x00\x00\x00"
     ^ "\x20\x1c\x00\x00"
     ^ "\x00\x00\x00\x00"
     ^ "\x07\x00\x00\x00\x00\x00\x00\x00"
     ^ "\x00\x00\x00\x00\x00\x00\x00\x00"
     ^ "/tmp/support"
     ^ "en_US"
     ^ "Europe/Paris")
;;

let encode_exn value =
  match Journal_startup.encode value with
  | Ok bytes -> bytes
  | Error error ->
    fail "unexpected encode error: %s" (Journal_startup.Error.to_string error)
;;

let decode_exn bytes =
  match Journal_startup.decode bytes with
  | Ok value -> value
  | Error error ->
    fail "unexpected decode error: %s" (Journal_startup.Error.to_string error)
;;

let require_decode_error ?contains bytes =
  match Journal_startup.decode bytes with
  | Ok _ -> fail "expected startup decode error"
  | Error error ->
    (match contains with
     | None -> ()
     | Some fragment ->
       let message = Journal_startup.Error.to_string error in
       if not (has_substring message fragment)
       then fail "expected error containing %S, got %S" fragment message)
;;

let require_encode_error ?contains value =
  match Journal_startup.encode value with
  | Ok _ -> fail "expected startup encode error"
  | Error error ->
    (match contains with
     | None -> ()
     | Some fragment ->
       let message = Journal_startup.Error.to_string error in
       if not (has_substring message fragment)
       then fail "expected error containing %S, got %S" fragment message)
;;

let copy_and_set bytes offset value =
  let copy = Bytes.copy bytes in
  Bytes.set_uint8 copy offset value;
  copy
;;

let test_exact_codec_and_round_trip () =
  let encoded = encode_exn sample in
  require
    (Bytes.equal expected_bytes encoded)
    "startup bytes differ\nexpected: %S\nactual:   %S"
    (Bytes.to_string expected_bytes)
    (Bytes.to_string encoded);
  let decoded = decode_exn expected_bytes in
  require_equal_string
    ~expected:sample.application_support_root
    ~actual:decoded.application_support_root;
  require_equal_int
    ~expected:sample.expected_schema_version
    ~actual:decoded.expected_schema_version;
  require_equal_int64
    ~expected:sample.initial_calendar.instant_unix_ms
    ~actual:decoded.initial_calendar.instant_unix_ms;
  require_equal_int
    ~expected:sample.initial_calendar.local_day
    ~actual:decoded.initial_calendar.local_day;
  require_equal_string
    ~expected:sample.initial_calendar.locale
    ~actual:decoded.initial_calendar.locale;
  require_equal_string
    ~expected:sample.initial_calendar.time_zone_id
    ~actual:decoded.initial_calendar.time_zone_id;
  require_equal_int
    ~expected:sample.initial_calendar.utc_offset_seconds
    ~actual:decoded.initial_calendar.utc_offset_seconds;
  require_equal_int64
    ~expected:sample.initial_calendar.generation
    ~actual:decoded.initial_calendar.generation;
  require (decoded.access_mode = Read_write) "access mode changed";
  require (decoded.diagnostic_mode = Operational_only) "diagnostic mode changed"
;;

let test_host_wire_does_not_transport_access_policy () =
  let recovery = { sample with access_mode = Recovery_only } in
  let encoded = encode_exn recovery in
  require
    (Bytes.equal encoded expected_bytes)
    "recovery policy leaked into host startup bytes";
  require
    ((decode_exn encoded).access_mode = Read_write)
    "host startup unexpectedly selected recovery-only policy"
;;

let test_payload_and_header_rejection () =
  require_decode_error ~contains:"payload is empty" Bytes.empty;
  require_decode_error ~contains:"payload exceeds" (Bytes.make ((1024 * 1024) + 1) '\x00');
  require_decode_error ~contains:"truncated" (Bytes.sub expected_bytes 0 63);
  require_decode_error ~contains:"magic" (copy_and_set expected_bytes 0 0);
  require_decode_error ~contains:"version" (copy_and_set expected_bytes 4 2);
  require_decode_error ~contains:"reserved" (copy_and_set expected_bytes 20 1);
  require_decode_error ~contains:"reserved" (copy_and_set expected_bytes 38 1);
  require_decode_error ~contains:"reserved" (copy_and_set expected_bytes 44 1);
  require_decode_error
    ~contains:"trailing"
    (Bytes.cat expected_bytes (Bytes.of_string "x"))
;;

let test_path_and_string_rejection () =
  require_encode_error
    ~contains:"absolute"
    { sample with application_support_root = "tmp/support" };
  require_encode_error
    ~contains:"canonical"
    { sample with application_support_root = "/tmp/../tmp/support" };
  require_encode_error
    ~contains:"NUL"
    { sample with application_support_root = "/tmp/sup\x00port" };
  require_encode_error
    ~contains:"locale"
    { sample with initial_calendar = { sample_calendar with locale = "" } };
  require_encode_error
    ~contains:"time-zone"
    { sample with initial_calendar = { sample_calendar with time_zone_id = "" } };
  let locale_offset = 64 + String.length sample.application_support_root in
  require_decode_error ~contains:"UTF-8" (copy_and_set expected_bytes locale_offset 0xff)
;;

let test_calendar_rejection () =
  require_encode_error
    ~contains:"local day"
    { sample with initial_calendar = { sample_calendar with local_day = 20260229 } };
  ignore
    (encode_exn
       { sample with
         initial_calendar =
           { sample_calendar with
             instant_unix_ms = 1_709_163_000_000L
           ; local_day = 20240229
           ; utc_offset_seconds = 3_600
           }
       });
  require_encode_error
    ~contains:"UTC offset"
    { sample with initial_calendar = { sample_calendar with utc_offset_seconds = 86401 } };
  require_encode_error
    ~contains:"generation"
    { sample with initial_calendar = { sample_calendar with generation = -1L } }
;;

let test_application_platform_calendar_codec () =
  require
    (Journal_platform.get_calendar_request = Bytes.of_string "LJP1\001\000\001\000")
    "application calendar request bytes changed";
  let locale = "en_US" in
  let time_zone = "Europe/Paris" in
  let bytes = Bytes.make (56 + String.length locale + String.length time_zone) '\000' in
  Bytes.blit_string "LJP1" 0 bytes 0 4;
  Bytes.set_uint16_le bytes 4 1;
  Bytes.set_uint16_le bytes 6 3;
  Bytes.set_uint16_le bytes 8 2;
  Bytes.set_uint16_le bytes 10 (String.length locale);
  Bytes.set_uint16_le bytes 12 (String.length time_zone);
  Bytes.set_int64_le bytes 16 1_786_055_400_000L;
  Bytes.set_int32_le bytes 24 (Int32.of_int 20260807);
  Bytes.set_uint16_le bytes 28 30;
  Bytes.set_int32_le bytes 32 (Int32.of_int 7200);
  Bytes.set_int64_le bytes 40 8L;
  Bytes.set_int64_le bytes 48 4L;
  Bytes.blit_string locale 0 bytes 56 (String.length locale);
  Bytes.blit_string
    time_zone
    0
    bytes
    (56 + String.length locale)
    (String.length time_zone);
  let decoded =
    match Journal_platform.decode_calendar bytes with
    | Ok value -> value
    | Error error -> fail "platform calendar decode failed: %s" error
  in
  require (decoded.reason = Journal_platform.Significant_time_changed) "reason changed";
  require_equal_int64
    ~expected:1_786_055_400_000L
    ~actual:decoded.snapshot.instant_unix_ms;
  require_equal_int ~expected:20260807 ~actual:decoded.snapshot.local_day;
  require_equal_int64 ~expected:8L ~actual:decoded.snapshot.generation;
  require_equal_string ~expected:locale ~actual:decoded.snapshot.locale;
  require_equal_string ~expected:time_zone ~actual:decoded.snapshot.time_zone_id;
  require
    (Result.is_error (Journal_platform.decode_calendar (Bytes.of_string "bad")))
    "malformed platform calendar was accepted"
;;

let () =
  test_exact_codec_and_round_trip ();
  test_host_wire_does_not_transport_access_policy ();
  test_payload_and_header_rejection ();
  test_path_and_string_rejection ();
  test_calendar_rejection ();
  test_application_platform_calendar_codec ()
;;
