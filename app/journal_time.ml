type t =
  { instant_unix_ms : int64
  ; local_day : int
  ; local_minute_of_day : int
  ; time_zone_id : string
  ; utc_offset_seconds : int
  }

let floor_div dividend divisor =
  let quotient = Int64.div dividend divisor in
  let remainder = Int64.rem dividend divisor in
  if Int64.compare remainder 0L < 0 then Int64.pred quotient else quotient
;;

let days_from_civil day =
  let year = day / 10_000 in
  let month = day / 100 mod 100 in
  let day_of_month = day mod 100 in
  let adjusted_year = if month <= 2 then year - 1 else year in
  let era = adjusted_year / 400 in
  let year_of_era = adjusted_year - (era * 400) in
  let adjusted_month = month + if month > 2 then -3 else 9 in
  let day_of_year = (((153 * adjusted_month) + 2) / 5) + day_of_month - 1 in
  let day_of_era =
    (year_of_era * 365) + (year_of_era / 4) - (year_of_era / 100) + day_of_year
  in
  (era * 146_097) + day_of_era - 719_468
;;

let create
      ~instant_unix_ms
      ~local_day
      ~local_minute_of_day
      ~time_zone_id
      ~utc_offset_seconds
  =
  if not (Journal_validation.is_journal_day local_day)
  then Error "creation local day is invalid"
  else if local_minute_of_day < 0 || local_minute_of_day >= 1_440
  then Error "creation local minute must be between 0 and 1439"
  else if
    String.equal (String.trim time_zone_id) ""
    || String.length time_zone_id > 255
    || (not (Journal_validation.is_valid_utf_8 time_zone_id))
    || Journal_validation.contains_nul time_zone_id
  then Error "creation time-zone ID is invalid"
  else if utc_offset_seconds < -64_800 || utc_offset_seconds > 64_800
  then Error "creation UTC offset is outside the supported range"
  else (
    let instant_seconds = floor_div instant_unix_ms 1_000L in
    let local_seconds = Int64.add instant_seconds (Int64.of_int utc_offset_seconds) in
    let actual_day = floor_div local_seconds 86_400L in
    let actual_minute =
      let minutes = floor_div local_seconds 60L in
      Int64.rem (Int64.add (Int64.rem minutes 1_440L) 1_440L) 1_440L |> Int64.to_int
    in
    if not (Int64.equal actual_day (Int64.of_int (days_from_civil local_day)))
    then Error "creation local day does not match instant and offset"
    else if actual_minute <> local_minute_of_day
    then Error "creation local minute does not match instant and offset"
    else
      Ok
        { instant_unix_ms
        ; local_day
        ; local_minute_of_day
        ; time_zone_id
        ; utc_offset_seconds
        })
;;

let of_instant_unix_ms ~instant_unix_ms ~time_zone_id ~utc_offset_seconds =
  let seconds = Int64.to_float instant_unix_ms /. 1_000. in
  let local_time = Unix.gmtime (seconds +. Float.of_int utc_offset_seconds) in
  let local_day =
    ((local_time.Unix.tm_year + 1900) * 10_000)
    + ((local_time.tm_mon + 1) * 100)
    + local_time.tm_mday
  in
  create
    ~instant_unix_ms
    ~local_day
    ~local_minute_of_day:((local_time.tm_hour * 60) + local_time.tm_min)
    ~time_zone_id
    ~utc_offset_seconds
;;

let equal = ( = )
let instant_unix_ms value = value.instant_unix_ms
let local_day value = value.local_day
let local_minute_of_day value = value.local_minute_of_day
let time_zone_id value = value.time_zone_id
let utc_offset_seconds value = value.utc_offset_seconds

let format_hh_mm value =
  Printf.sprintf
    "%02d:%02d"
    (value.local_minute_of_day / 60)
    (value.local_minute_of_day mod 60)
;;
