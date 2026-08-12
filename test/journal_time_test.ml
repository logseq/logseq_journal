let fail format = Printf.ksprintf failwith format

let require condition format =
  Printf.ksprintf (fun message -> if not condition then failwith message) format
;;

let require_ok = function
  | Ok value -> value
  | Error error -> fail "unexpected creation-time rejection: %s" error
;;

let require_error = function
  | Error _ -> ()
  | Ok _ -> fail "invalid creation-time snapshot was accepted"
;;

let create
      ~instant_unix_ms
      ~local_day
      ~local_minute_of_day
      ~time_zone_id
      ~utc_offset_seconds
  =
  Journal_time.create
    ~instant_unix_ms
    ~local_day
    ~local_minute_of_day
    ~time_zone_id
    ~utc_offset_seconds
;;

let test_midnight_assignment_and_formatting () =
  let before =
    create
      ~instant_unix_ms:1_786_204_740_000L
      ~local_day:20260808
      ~local_minute_of_day:1439
      ~time_zone_id:"Asia/Shanghai"
      ~utc_offset_seconds:28_800
    |> require_ok
  in
  let after =
    create
      ~instant_unix_ms:1_786_204_800_000L
      ~local_day:20260809
      ~local_minute_of_day:0
      ~time_zone_id:"Asia/Shanghai"
      ~utc_offset_seconds:28_800
    |> require_ok
  in
  require (Journal_time.local_day before = 20260808) "pre-midnight day changed";
  require (Journal_time.local_day after = 20260809) "post-midnight day changed";
  require (String.equal (Journal_time.format_hh_mm before) "23:59") "wrong 23:59 format";
  require (String.equal (Journal_time.format_hh_mm after) "00:00") "wrong 00:00 format"
;;

let test_dst_gap_and_fold_preserve_the_admitted_snapshot () =
  let before_gap =
    create
      ~instant_unix_ms:1_772_953_140_000L
      ~local_day:20260308
      ~local_minute_of_day:119
      ~time_zone_id:"America/New_York"
      ~utc_offset_seconds:(-18_000)
    |> require_ok
  in
  let after_gap =
    create
      ~instant_unix_ms:1_772_953_200_000L
      ~local_day:20260308
      ~local_minute_of_day:180
      ~time_zone_id:"America/New_York"
      ~utc_offset_seconds:(-14_400)
    |> require_ok
  in
  require
    (String.equal (Journal_time.format_hh_mm before_gap) "01:59")
    "gap start changed";
  require (String.equal (Journal_time.format_hh_mm after_gap) "03:00") "gap end changed";
  let first_fold =
    create
      ~instant_unix_ms:1_793_511_000_000L
      ~local_day:20261101
      ~local_minute_of_day:90
      ~time_zone_id:"America/New_York"
      ~utc_offset_seconds:(-14_400)
    |> require_ok
  in
  let second_fold =
    create
      ~instant_unix_ms:1_793_514_600_000L
      ~local_day:20261101
      ~local_minute_of_day:90
      ~time_zone_id:"America/New_York"
      ~utc_offset_seconds:(-18_000)
    |> require_ok
  in
  require
    (String.equal (Journal_time.format_hh_mm first_fold) "01:30")
    "first fold changed";
  require
    (String.equal (Journal_time.format_hh_mm second_fold) "01:30")
    "second fold changed";
  require
    (Journal_time.utc_offset_seconds first_fold = -14_400
     && Journal_time.utc_offset_seconds second_fold = -18_000)
    "fold offsets were not preserved"
;;

let test_device_time_zone_changes_do_not_rewrite_creation_time () =
  let admitted =
    create
      ~instant_unix_ms:1_786_204_800_000L
      ~local_day:20260809
      ~local_minute_of_day:0
      ~time_zone_id:"Asia/Shanghai"
      ~utc_offset_seconds:28_800
    |> require_ok
  in
  let current_device_zone = "America/Los_Angeles" in
  ignore current_device_zone;
  require
    (String.equal (Journal_time.time_zone_id admitted) "Asia/Shanghai")
    "zone changed";
  require (String.equal (Journal_time.format_hh_mm admitted) "00:00") "wall time changed";
  require
    (Int64.equal (Journal_time.instant_unix_ms admitted) 1_786_204_800_000L)
    "instant changed"
;;

let test_invalid_snapshots_are_rejected () =
  let valid = 1_786_204_800_000L, 20260809, 0, "Asia/Shanghai", 28_800 in
  let instant, day, minute, zone, offset = valid in
  [ create
      ~instant_unix_ms:instant
      ~local_day:20260229
      ~local_minute_of_day:minute
      ~time_zone_id:zone
      ~utc_offset_seconds:offset
  ; create
      ~instant_unix_ms:instant
      ~local_day:day
      ~local_minute_of_day:(-1)
      ~time_zone_id:zone
      ~utc_offset_seconds:offset
  ; create
      ~instant_unix_ms:instant
      ~local_day:day
      ~local_minute_of_day:1440
      ~time_zone_id:zone
      ~utc_offset_seconds:offset
  ; create
      ~instant_unix_ms:instant
      ~local_day:day
      ~local_minute_of_day:1
      ~time_zone_id:zone
      ~utc_offset_seconds:offset
  ; create
      ~instant_unix_ms:instant
      ~local_day:day
      ~local_minute_of_day:minute
      ~time_zone_id:""
      ~utc_offset_seconds:offset
  ; create
      ~instant_unix_ms:instant
      ~local_day:day
      ~local_minute_of_day:minute
      ~time_zone_id:"Asia/\000Shanghai"
      ~utc_offset_seconds:offset
  ; create
      ~instant_unix_ms:instant
      ~local_day:day
      ~local_minute_of_day:minute
      ~time_zone_id:zone
      ~utc_offset_seconds:64_801
  ]
  |> List.iter require_error
;;

let () =
  test_midnight_assignment_and_formatting ();
  test_dst_gap_and_fold_preserve_the_admitted_snapshot ();
  test_device_time_zone_changes_do_not_rewrite_creation_time ();
  test_invalid_snapshots_are_rejected ()
;;
