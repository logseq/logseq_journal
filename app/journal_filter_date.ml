open Journal_timeline_filter.Timeline_filter

let resolve_days criteria ~today =
  let calendar_months () =
    let month_index = (today / 10000) * 12 + today / 100 mod 100 - 1 - 3 in
    if month_index < 12 then invalid_arg "Filter range starts before year 1";
    let year = month_index / 12 and month = month_index mod 12 + 1 in
    let last_day = match month with
      | 2 -> if year mod 4 = 0 && (year mod 100 <> 0 || year mod 400 = 0) then 29 else 28
      | 4 | 6 | 9 | 11 -> 30
      | _ -> 31 in
    Some (year * 10000 + month * 100 + min (today mod 100) last_day, today)
  in
  let days count =
    let civil day =
      let year = day / 10000 and month = day / 100 mod 100 in
      let year = if month <= 2 then year - 1 else year in
      let era = year / 400 in
      let year_of_era = year mod 400 in
      let month = if month <= 2 then month + 9 else month - 3 in
      era * 146097 + year_of_era * 365 + year_of_era / 4 - year_of_era / 100
      + (153 * month + 2) / 5 + day mod 100 - 1 - 719468
    in
    let earliest = civil today - (count - 1) in
    if earliest < civil 10101 then invalid_arg "Filter range starts before year 1";
    let start = Unix.gmtime (float_of_int earliest *. 86400.) in
    Some ((start.tm_year + 1900) * 10000 + (start.tm_mon + 1) * 100 + start.tm_mday, today)
  in
  match time_choice (time criteria) with
  | `Any_time -> None
  | `Preset Past_3_months -> calendar_months ()
  | `Preset Past_14_days -> days 14
  | `Custom (count, Days) -> days count
  | `Custom (count, Weeks) -> days (7 * count)
;;
