type t =
  { instant_unix_ms : int64
  ; local_day : int
  ; local_minute_of_day : int
  }

let create ~instant_unix_ms ~local_day ~local_minute_of_day =
  if not (Journal_validation.is_journal_day local_day)
  then Error "creation local day is invalid"
  else if local_minute_of_day < 0 || local_minute_of_day >= 1_440
  then Error "creation local minute must be between 0 and 1439"
  else Ok { instant_unix_ms; local_day; local_minute_of_day }
;;

let of_instant_unix_ms_with ~localtime ~instant_unix_ms =
  let seconds = Int64.to_float instant_unix_ms /. 1_000. in
  try
    let converted = localtime seconds in
    let local_day =
      ((converted.Unix.tm_year + 1900) * 10_000)
      + ((converted.tm_mon + 1) * 100)
      + converted.tm_mday
    in
    create
      ~instant_unix_ms
      ~local_day
      ~local_minute_of_day:((converted.tm_hour * 60) + converted.tm_min)
  with
  | exn -> Error ("local time conversion failed: " ^ Printexc.to_string exn)
;;

let of_instant_unix_ms ~instant_unix_ms =
  of_instant_unix_ms_with ~localtime:Unix.localtime ~instant_unix_ms
;;

let of_calendar calendar =
  create
    ~instant_unix_ms:(Journal_calendar.instant_unix_ms calendar)
    ~local_day:(Journal_calendar.local_day calendar)
    ~local_minute_of_day:(Journal_calendar.local_minute_of_day calendar)
;;

let equal = ( = )
let instant_unix_ms value = value.instant_unix_ms
let local_day value = value.local_day
let local_minute_of_day value = value.local_minute_of_day

let format_hh_mm value =
  Printf.sprintf
    "%02d:%02d"
    (value.local_minute_of_day / 60)
    (value.local_minute_of_day mod 60)
;;
