let fail format = Printf.ksprintf failwith format

let require condition format =
  Printf.ksprintf (fun message -> if not condition then failwith message) format
;;

let token =
  Logseq_db_worker.Graph_types.Uuid.of_string
    "10000000-0000-4000-8000-000000000001"
  |> Result.get_ok
;;

let sample : Journal_startup.t =
  Logseq_db_worker.Config.create
    ~application_support_directory:"/tmp/support"
    ~target:(Snapshot { token })
    ~compatibility_profile:Logseq_65_33_or_newer
    ~response_budget_bytes:Logseq_db_worker.Protocol.maximum_response_bytes
    ~default_page_size:Logseq_db_worker.Protocol.default_page_size
  |> Result.get_ok
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

let require_decode_error bytes =
  match Journal_startup.decode bytes with
  | Error _ -> ()
  | Ok _ -> fail "expected startup decode error"
;;

let test_exact_codec_and_round_trip () =
  let encoded = encode_exn sample in
  require
    (Bytes.sub_string encoded 0 4 = "LDB1")
    "startup magic changed";
  require
    (Int32.to_int (Bytes.get_int32_le encoded 4) = Bytes.length encoded - 8)
    "startup JSON length changed";
  let json = Bytes.sub_string encoded 8 (Bytes.length encoded - 8) in
  require (not (String.contains json '\000')) "startup JSON contains NUL";
  let decoded = decode_exn encoded in
  require
    (String.equal
       decoded.application_support_directory
       sample.application_support_directory)
    "application-support directory changed";
  match decoded.target with
  | Snapshot { token = decoded } ->
    require
      (Logseq_db_worker.Graph_types.Uuid.equal token decoded)
      "snapshot token changed"
  | Import_snapshot _ | Native_local_graph _ -> fail "snapshot target changed"
;;

let test_bounded_rejection () =
  let encoded = encode_exn sample in
  require_decode_error Bytes.empty;
  require_decode_error (Bytes.make ((1024 * 1024) + 1) '\000');
  require_decode_error (Bytes.sub encoded 0 7);
  let bad_magic = Bytes.copy encoded in
  Bytes.set bad_magic 0 'X';
  require_decode_error bad_magic;
  require_decode_error (Bytes.cat encoded (Bytes.of_string "x"));
  let bad_json = Bytes.copy encoded in
  Bytes.set bad_json 8 '\xff';
  require_decode_error bad_json
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
  Bytes.blit_string time_zone 0 bytes (56 + String.length locale) (String.length time_zone);
  match Journal_platform.decode_calendar bytes with
  | Error error -> fail "platform calendar decode failed: %s" error
  | Ok decoded ->
    require (decoded.snapshot.local_day = 20260807) "calendar day changed";
    require (Int64.equal decoded.snapshot.generation 8L) "calendar generation changed"
;;

let () =
  test_exact_codec_and_round_trip ();
  test_bounded_rejection ();
  test_application_platform_calendar_codec ()
;;
