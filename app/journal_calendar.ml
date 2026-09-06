type error =
  | Clock_failed of string
  | Invalid_instant of string
  | Local_time_failed of string

type change =
  | Current_time_changed
  | Local_day_changed
  | Local_projection_changed

type civil_projection =
  { day : int
  ; minute_of_day : int
  ; is_dst : bool
  }

type local_projection =
  { utc_day_delta : int
  ; minute_of_day : int
  ; is_dst : bool
  }

type projection_fingerprint = local_projection list

type t =
  { instant_unix_ms : int64
  ; local_day : int
  ; local_minute_of_day : int
  ; generation : int64
  ; projection_fingerprint : projection_fingerprint
  }

let error_message = function
  | Clock_failed message -> "Local calendar clock failed: " ^ message
  | Invalid_instant message ->
    "Local calendar clock returned an invalid instant: " ^ message
  | Local_time_failed message -> "Local calendar conversion failed: " ^ message
;;

let day_of_tm (tm : Unix.tm) =
  ((tm.tm_year + 1900) * 10_000) + ((tm.tm_mon + 1) * 100) + tm.tm_mday
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

let projection_of_tm tm =
  let day = day_of_tm tm in
  let minute_of_day = (tm.Unix.tm_hour * 60) + tm.tm_min in
  if
    (not (Journal_validation.is_journal_day day))
    || minute_of_day < 0
    || minute_of_day >= 1_440
  then Error (Local_time_failed "the converted civil time is outside its bounds")
  else Ok { day; minute_of_day; is_dst = tm.tm_isdst }
;;

let fingerprint_projection instant projection =
  let utc_day = int_of_float (Float.floor (instant /. 86_400.)) in
  { utc_day_delta = days_from_civil projection.day - utc_day
  ; minute_of_day = projection.minute_of_day
  ; is_dst = projection.is_dst
  }
;;

module Sampler = struct
  type calendar = t

  type t =
    { clock : unit -> float
    ; localtime : float -> Unix.tm
    ; mutable next_generation : int64
    }

  let create ?(clock = Unix.gettimeofday) ?(localtime = Unix.localtime) () =
    { clock; localtime; next_generation = 0L }
  ;;

  let localtime t = t.localtime

  let sample t =
    let sampled =
      try Ok (t.clock ()) with
      | exn -> Error (Clock_failed (Printexc.to_string exn))
    in
    match sampled with
    | Error _ as error -> error
    | Ok seconds ->
      if
        classify_float seconds = FP_nan
        || classify_float seconds = FP_infinite
        || seconds *. 1_000. > Int64.to_float Int64.max_int
        || seconds *. 1_000. < Int64.to_float Int64.min_int
      then Error (Invalid_instant "the sampled Unix time is not a finite int64 value")
      else if Int64.equal t.next_generation Int64.max_int
      then Error (Invalid_instant "the local calendar generation is exhausted")
      else (
        let converted =
          try Ok (t.localtime seconds) with
          | exn -> Error (Local_time_failed (Printexc.to_string exn))
        in
        match converted with
        | Error _ as error -> error
        | Ok current ->
          (match projection_of_tm current with
           | Error _ as error -> error
           | Ok current_projection ->
             let utc_day_start = Float.floor (seconds /. 86_400.) *. 86_400. in
             let representative_instants =
               [ -7.; -6.; -5.; -4.; -3.; -2.; -1.; 0.; 1. ]
               |> List.map (fun days -> utc_day_start +. (days *. 86_400.))
             in
             let rec fingerprint reversed = function
               | [] -> Ok (List.rev reversed)
               | instant :: rest ->
                 let projected =
                   if Float.equal instant seconds
                   then Ok current_projection
                   else (
                     try projection_of_tm (t.localtime instant) with
                     | exn -> Error (Local_time_failed (Printexc.to_string exn)))
                 in
                 (match projected with
                  | Error _ as error -> error
                  | Ok projection ->
                    fingerprint
                      (fingerprint_projection instant projection :: reversed)
                      rest)
             in
             (match fingerprint [] representative_instants with
              | Error _ as error -> error
              | Ok projection_fingerprint ->
                let calendar =
                  { instant_unix_ms = Int64.of_float (Float.floor (seconds *. 1_000.))
                  ; local_day = current_projection.day
                  ; local_minute_of_day = current_projection.minute_of_day
                  ; generation = t.next_generation
                  ; projection_fingerprint
                  }
                in
                t.next_generation <- Int64.succ t.next_generation;
                Ok calendar)))
  ;;
end

let instant_unix_ms t = t.instant_unix_ms
let local_day t = t.local_day
let local_minute_of_day t = t.local_minute_of_day
let generation t = t.generation
let projection_fingerprint t = t.projection_fingerprint

let equal_projection_fingerprint left right =
  List.length left = List.length right
  && List.for_all2
       (fun left right ->
          left.utc_day_delta = right.utc_day_delta
          && left.minute_of_day = right.minute_of_day
          && Bool.equal left.is_dst right.is_dst)
       left
       right
;;

let classify_change ~previous current =
  if previous.local_day <> current.local_day
  then Local_day_changed
  else if
    not
      (equal_projection_fingerprint
         previous.projection_fingerprint
         current.projection_fingerprint)
  then Local_projection_changed
  else Current_time_changed
;;

let is_newer ~than candidate = Int64.compare candidate.generation than.generation > 0

type date_presentation =
  { date_text : string
  ; weekday_text : string
  ; accessibility_label : string
  }

let present_journal_day day =
  if not (Journal_validation.is_journal_day day)
  then Error "journal day is not a valid Gregorian date"
  else (
    let weekdays = [| "MON"; "TUE"; "WED"; "THU"; "FRI"; "SAT"; "SUN" |] in
    let full_weekdays =
      [| "Monday"; "Tuesday"; "Wednesday"; "Thursday"; "Friday"; "Saturday"; "Sunday" |]
    in
    let index = (((days_from_civil day + 3) mod 7) + 7) mod 7 in
    let date_text =
      Printf.sprintf "%04d.%02d.%02d" (day / 10_000) (day / 100 mod 100) (day mod 100)
    in
    Ok
      { date_text
      ; weekday_text = weekdays.(index)
      ; accessibility_label = date_text ^ ", " ^ full_weekdays.(index)
      })
;;
