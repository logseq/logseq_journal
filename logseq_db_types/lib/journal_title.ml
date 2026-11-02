(* Mirrors the pinned Logseq cljs-time fork (logseq/cljs-time
   5704fbf48d3478eedcf24d458c8964b3c2fd59a9): parse.cljs read-pattern for
   tokenization and unparse.cljs lookup/unparse for emission. Journal days
   are UTC midnights, so time fields are zero and `Z` emits "Z". *)
let default_format = "MMM do, yyyy"

let months =
  [| "January"
   ; "February"
   ; "March"
   ; "April"
   ; "May"
   ; "June"
   ; "July"
   ; "August"
   ; "September"
   ; "October"
   ; "November"
   ; "December"
  |]
;;

let days =
  [| "Sunday"; "Monday"; "Tuesday"; "Wednesday"; "Thursday"; "Friday"; "Saturday" |]
;;

type token =
  | Pattern_token of string
  | Pattern_quoted of string

let tokenize pattern =
  let length = String.length pattern in
  let is_alpha c = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') in
  let rec loop index tokens =
    if index >= length
    then List.rev tokens
    else (
      match pattern.[index] with
      | '\'' ->
        if index + 1 < length && pattern.[index + 1] = '\''
        then loop (index + 2) (Pattern_quoted "'" :: tokens)
        else (
          let rec scan stop =
            if stop >= length || pattern.[stop] = '\'' then stop else scan (stop + 1)
          in
          let stop = scan (index + 1) in
          loop
            (min (stop + 1) length)
            (Pattern_quoted (String.sub pattern (index + 1) (stop - index - 1))
             :: tokens))
      | c when is_alpha c ->
        let rec scan stop =
          if stop < length && pattern.[stop] = c then scan (stop + 1) else stop
        in
        let stop = scan index in
        loop stop (Pattern_token (String.sub pattern index (stop - index)) :: tokens)
      | _ ->
        let rec scan stop =
          if stop < length && not (is_alpha pattern.[stop] || pattern.[stop] = '\'')
          then scan (stop + 1)
          else stop
        in
        let stop = scan index in
        loop stop (Pattern_quoted (String.sub pattern index (stop - index)) :: tokens))
  in
  loop 0 []
;;

type field =
  | Millis
  | Seconds
  | Minutes
  | Hours
  | HOURS
  | Day
  | Month
  | Year
  | Weekyear
  | Weekyear_week
  | Day_of_week

type spec =
  | Number of field * int * int
  | Month_name of bool
  | Day_name of bool
  | Meridiem of bool
  | Timezone
  | Ordinal_suffix
  | Literal of string

let spec_of_token = function
  | "S" -> Some (Number (Millis, 1, 2))
  | "SSS" -> Some (Number (Millis, 3, 3))
  | "s" -> Some (Number (Seconds, 1, 2))
  | "ss" -> Some (Number (Seconds, 2, 2))
  | "m" -> Some (Number (Minutes, 1, 2))
  | "mm" -> Some (Number (Minutes, 2, 2))
  | "h" -> Some (Number (Hours, 1, 2))
  | "hh" -> Some (Number (Hours, 2, 2))
  | "H" -> Some (Number (HOURS, 1, 2))
  | "HH" -> Some (Number (HOURS, 2, 2))
  | "d" -> Some (Number (Day, 1, 2))
  | "dd" -> Some (Number (Day, 2, 2))
  | "D" -> Some (Number (Day, 1, 3))
  | "DD" -> Some (Number (Day, 2, 3))
  | "DDD" -> Some (Number (Day, 3, 3))
  | "M" -> Some (Number (Month, 1, 2))
  | "MM" -> Some (Number (Month, 2, 2))
  | "MMM" -> Some (Month_name true)
  | "MMMM" -> Some (Month_name false)
  | "y" -> Some (Number (Year, 1, 4))
  | "yy" -> Some (Number (Year, 2, 2))
  | "yyyy" -> Some (Number (Year, 4, 4))
  | "Y" -> Some (Number (Year, 1, 4))
  | "YY" -> Some (Number (Year, 2, 2))
  | "YYYY" -> Some (Number (Year, 4, 4))
  | "x" -> Some (Number (Weekyear, 1, 4))
  | "xx" -> Some (Number (Weekyear, 2, 2))
  | "xxxx" -> Some (Number (Weekyear, 4, 4))
  | "w" -> Some (Number (Weekyear_week, 1, 2))
  | "ww" -> Some (Number (Weekyear_week, 2, 2))
  | "e" -> Some (Number (Day_of_week, 1, 1))
  | "E" -> Some (Day_name true)
  | "EEE" -> Some (Day_name true)
  | "EEEE" -> Some (Day_name false)
  | "a" -> Some (Meridiem false)
  | "A" -> Some (Meridiem true)
  | "Z" -> Some Timezone
  | "ZZ" -> Some Timezone
  | "o" -> Some Ordinal_suffix
  | _ -> None
;;

let days_from_civil ~year ~month ~day =
  let year = if month <= 2 then year - 1 else year in
  let era = if year >= 0 then year / 400 else (year - 399) / 400 in
  let yoe = year - (era * 400) in
  let doy = (((153 * if month > 2 then month - 3 else month + 9) + 2) / 5) + day - 1 in
  let doe = (yoe * 365) + (yoe / 4) - (yoe / 100) + doy in
  (era * 146097) + doe - 719468
;;

let civil_from_days days =
  let z = days + 719468 in
  let era = if z >= 0 then z / 146097 else (z - 146096) / 146097 in
  let doe = z - (era * 146097) in
  let yoe = (doe - (doe / 1460) + (doe / 36524) - (doe / 146096)) / 365 in
  let year = yoe + (era * 400) in
  let doy = doe - ((365 * yoe) + (yoe / 4) - (yoe / 100)) in
  let mp = ((5 * doy) + 2) / 153 in
  let day = doy - (((153 * mp) + 2) / 5) + 1 in
  let month = if mp < 10 then mp + 3 else mp - 9 in
  (if month <= 2 then year + 1 else year), month, day
;;

type context =
  { day : int
  ; month : int
  ; year : int
  ; day_of_week : int
  ; weekyear : int
  ; weekyear_week : int
  }

let context ~year ~month ~day =
  let epoch_days = days_from_civil ~year ~month ~day in
  let day_of_week = ((((epoch_days + 3) mod 7) + 7) mod 7) + 1 in
  let thursday = epoch_days + (4 - day_of_week) in
  let weekyear, _, _ = civil_from_days thursday in
  { day
  ; month
  ; year
  ; day_of_week
  ; weekyear
  ; weekyear_week =
      ((thursday - days_from_civil ~year:weekyear ~month:1 ~day:1) / 7) + 1
  }
;;

let field_value context = function
  | Millis | Seconds | Minutes | HOURS -> 0
  | Hours -> 12
  | Day -> context.day
  | Month -> context.month
  | Year -> context.year
  | Weekyear -> context.weekyear
  | Weekyear_week -> context.weekyear_week
  | Day_of_week -> context.day_of_week
;;

let ordinal_getter context = function
  | Millis | Seconds | Minutes | Hours | HOURS -> Some 0
  | Day -> Some context.day
  | Month -> Some (context.month - 1)
  | Year -> Some context.year
  | Weekyear | Weekyear_week | Day_of_week -> None
;;

(* zero-pad to min, then keep the rightmost max digits; upstream's substring
   clamps so a padded value shorter than max is kept whole *)
let padded ~min ~max value =
  let text = string_of_int value in
  let length = String.length text in
  let text = if length < min then String.make (min - length) '0' ^ text else text in
  let length = String.length text in
  if length <= max then text else String.sub text (length - max) max
;;

let ordinal_suffix n =
  match n with
  | 1 | 21 | 31 -> "st"
  | 2 | 22 -> "nd"
  | 3 | 23 -> "rd"
  | _ -> "th"
;;

let emit context spec previous =
  match spec, previous with
  | Number (field, min, max), _ -> Some (padded ~min ~max (field_value context field))
  | Month_name true, _ -> Some (String.sub months.(context.month - 1) 0 3)
  | Month_name false, _ -> Some months.(context.month - 1)
  | Day_name true, _ -> Some (String.sub days.(context.day_of_week mod 7) 0 3)
  | Day_name false, _ -> Some days.(context.day_of_week mod 7)
  | Meridiem capitalize, _ -> Some (if capitalize then "AM" else "am")
  | Timezone, _ -> Some "Z"
  | Ordinal_suffix, Some (Number (field, _, _)) ->
    (match ordinal_getter context field with
     | Some n -> Some (ordinal_suffix n)
     | None -> None)
  | Ordinal_suffix, _ -> None
  | Literal text, _ -> Some text
;;

let format ~pattern ~year ~month ~day =
  let context = context ~year ~month ~day in
  let rec resolve tokens reversed =
    match tokens with
    | [] -> Some (List.rev reversed)
    | Pattern_token token :: rest ->
      (match spec_of_token token with
       | Some spec -> resolve rest (spec :: reversed)
       | None -> None)
    | Pattern_quoted text :: rest -> resolve rest (Literal text :: reversed)
  in
  match resolve (tokenize pattern) [] with
  | None -> None
  | Some specs ->
    let rec render specs previous parts =
      match specs with
      | [] -> Some (String.concat "" (List.rev parts))
      | spec :: rest ->
        (match emit context spec previous with
         | Some text -> render rest (Some spec) (text :: parts)
         | None -> None)
    in
    render specs None []
;;
