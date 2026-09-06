let fail format = Printf.ksprintf failwith format

let require condition format =
  Printf.ksprintf (fun message -> if not condition then failwith message) format
;;

let require_ok = function
  | Ok value -> value
  | Error error ->
    fail "unexpected local-time failure: %s" (Journal_calendar.error_message error)
;;

let utc_with_offset offset seconds = Unix.gmtime (seconds +. Float.of_int offset)

let sampler ~seconds ~localtime =
  Journal_calendar.Sampler.create ~clock:(fun () -> seconds) ~localtime ()
;;

let test_sample_uses_one_clock_read_and_one_conversion_for_the_sampled_instant () =
  let clock_reads = ref 0 in
  let sampled_conversions = ref 0 in
  let seconds = 1_788_508_800. in
  let clock () =
    incr clock_reads;
    seconds
  in
  let localtime instant =
    if Float.equal instant seconds then incr sampled_conversions;
    utc_with_offset 28_800 instant
  in
  let calendar =
    Journal_calendar.Sampler.create ~clock ~localtime ()
    |> Journal_calendar.Sampler.sample
    |> require_ok
  in
  require (!clock_reads = 1) "calendar sampled the clock %d times" !clock_reads;
  require
    (!sampled_conversions = 1)
    "calendar converted the sampled instant %d times"
    !sampled_conversions;
  require
    (Int64.equal (Journal_calendar.instant_unix_ms calendar) 1_788_508_800_000L)
    "calendar instant changed";
  require (Journal_calendar.local_day calendar = 20260904) "local day changed";
  require (Journal_calendar.local_minute_of_day calendar = 960) "local minute changed"
;;

let test_midnight_negative_instant_and_leap_day () =
  let sample seconds offset =
    sampler ~seconds ~localtime:(utc_with_offset offset)
    |> Journal_calendar.Sampler.sample
    |> require_ok
  in
  let before_midnight = sample 1_786_204_740. 28_800 in
  let after_midnight = sample 1_786_204_800. 28_800 in
  let negative = sample (-1.) 0 in
  let leap_day = sample 1_709_164_800. 0 in
  require
    (Journal_calendar.local_day before_midnight = 20260808
     && Journal_calendar.local_minute_of_day before_midnight = 1439)
    "pre-midnight sample changed";
  require
    (Journal_calendar.local_day after_midnight = 20260809
     && Journal_calendar.local_minute_of_day after_midnight = 0)
    "post-midnight sample changed";
  require
    (Int64.equal (Journal_calendar.instant_unix_ms negative) (-1_000L)
     && Journal_calendar.local_day negative = 19691231
     && Journal_calendar.local_minute_of_day negative = 1439)
    "negative Unix instant changed";
  require (Journal_calendar.local_day leap_day = 20240229) "leap day changed"
;;

let new_york_2026 seconds =
  let gap = 1_772_953_200. in
  let fold = 1_793_514_600. in
  let offset = if seconds < gap || seconds >= fold then -18_000 else -14_400 in
  utc_with_offset offset seconds
;;

let test_dst_gap_and_fold_use_local_converter () =
  let project milliseconds =
    Journal_time.of_instant_unix_ms_with
      ~localtime:new_york_2026
      ~instant_unix_ms:milliseconds
    |> Result.get_ok
  in
  let before_gap = project 1_772_953_140_000L in
  let after_gap = project 1_772_953_200_000L in
  let first_fold = project 1_793_511_000_000L in
  let second_fold = project 1_793_514_600_000L in
  require
    (String.equal (Journal_time.format_hh_mm before_gap) "01:59")
    "gap start changed";
  require (String.equal (Journal_time.format_hh_mm after_gap) "03:00") "gap end changed";
  require
    (String.equal (Journal_time.format_hh_mm first_fold) "01:30"
     && String.equal (Journal_time.format_hh_mm second_fold) "01:30")
    "fold projection changed";
  require
    (Int64.equal (Journal_time.instant_unix_ms first_fold) 1_793_511_000_000L
     && Int64.equal (Journal_time.instant_unix_ms second_fold) 1_793_514_600_000L)
    "fold instants collapsed"
;;

let test_generation_and_semantic_refresh_classification () =
  let seconds = ref 1_788_508_800. in
  let localtime = ref (utc_with_offset 28_800) in
  let sampler =
    Journal_calendar.Sampler.create
      ~clock:(fun () -> !seconds)
      ~localtime:(fun value -> !localtime value)
      ()
  in
  let first = Journal_calendar.Sampler.sample sampler |> require_ok in
  seconds := !seconds +. 60.;
  let minute = Journal_calendar.Sampler.sample sampler |> require_ok in
  require
    (Journal_calendar.classify_change ~previous:first minute
     = Journal_calendar.Current_time_changed)
    "minute-only refresh changed semantic projection";
  localtime := utc_with_offset 32_400;
  let zone = Journal_calendar.Sampler.sample sampler |> require_ok in
  require
    (Journal_calendar.classify_change ~previous:minute zone
     = Journal_calendar.Local_projection_changed)
    "zone refresh was not detected";
  seconds := 1_788_537_600.;
  let day = Journal_calendar.Sampler.sample sampler |> require_ok in
  require
    (Journal_calendar.classify_change ~previous:zone day
     = Journal_calendar.Local_day_changed)
    "day refresh was not detected";
  require
    (Journal_calendar.is_newer ~than:first minute
     && not (Journal_calendar.is_newer ~than:day first))
    "calendar generation did not fence stale work"
;;

let test_projection_fingerprint_is_stable_across_utc_midnight () =
  let seconds = ref 1_788_566_340. in
  let sampler =
    Journal_calendar.Sampler.create
      ~clock:(fun () -> !seconds)
      ~localtime:(utc_with_offset (-28_800))
      ()
  in
  let before_midnight = Journal_calendar.Sampler.sample sampler |> require_ok in
  seconds := 1_788_566_460.;
  let after_midnight = Journal_calendar.Sampler.sample sampler |> require_ok in
  require
    (Journal_calendar.local_day before_midnight = 20260904
     && Journal_calendar.local_day after_midnight = 20260904)
    "test fixtures did not remain on the same local day";
  require
    (Journal_calendar.classify_change ~previous:before_midnight after_midnight
     = Journal_calendar.Current_time_changed)
    "UTC midnight changed an otherwise stable local projection"
;;

let test_sampling_failures_are_typed () =
  let raised =
    Journal_calendar.Sampler.create
      ~clock:(fun () -> raise (Failure "clock unavailable"))
      ~localtime:Unix.localtime
      ()
    |> Journal_calendar.Sampler.sample
  in
  (match raised with
   | Error (Journal_calendar.Clock_failed _) -> ()
   | Error _ | Ok _ -> fail "clock failure was not typed");
  let invalid =
    sampler ~seconds:Float.nan ~localtime:Unix.localtime
    |> Journal_calendar.Sampler.sample
  in
  match invalid with
  | Error (Journal_calendar.Invalid_instant _) -> ()
  | Error _ | Ok _ -> fail "invalid sampled instant was not typed"
;;

let test_deterministic_journal_day_headings () =
  [ 20260906, "2026.09.06, SUN"
  ; 20261231, "2026.12.31, THU"
  ; 20270101, "2027.01.01, FRI"
  ; 20260904, "2026.09.04, FRI"
  ; 20240229, "2024.02.29, THU"
  ; 19700101, "1970.01.01, THU"
  ; 19691231, "1969.12.31, WED"
  ]
  |> List.iter (fun (day, expected) ->
    match Journal_calendar.present_journal_day day with
    | Ok actual ->
      require
        (String.equal (actual.date_text ^ ", " ^ actual.weekday_text) expected)
        "heading %s changed"
        expected
    | Error error -> fail "valid heading failed: %s" error);
  require
    (Result.is_error (Journal_calendar.present_journal_day 20260229))
    "invalid Gregorian heading was accepted"
;;

let () =
  test_sample_uses_one_clock_read_and_one_conversion_for_the_sampled_instant ();
  test_midnight_negative_instant_and_leap_day ();
  test_dst_gap_and_fold_use_local_converter ();
  test_generation_and_semantic_refresh_classification ();
  test_projection_fingerprint_is_stable_across_utc_midnight ();
  test_sampling_failures_are_typed ();
  test_deterministic_journal_day_headings ()
;;
