let is_hex = function
  | '0' .. '9' | 'a' .. 'f' | 'A' .. 'F' -> true
  | _ -> false
;;

let is_uuid value =
  String.length value = 36
  && List.for_all (fun index -> value.[index] = '-') [ 8; 13; 18; 23 ]
  && String.to_seq value
     |> Seq.mapi (fun index character -> index, character)
     |> Seq.for_all (fun (index, character) ->
       List.mem index [ 8; 13; 18; 23 ] || is_hex character)
;;

let is_valid_utf_8 value =
  let rec loop offset =
    if offset = String.length value
    then true
    else (
      let decoded = String.get_utf_8_uchar value offset in
      Uchar.utf_decode_is_valid decoded && loop (offset + Uchar.utf_decode_length decoded))
  in
  loop 0
;;

let utf_8_scalar_count value =
  let rec loop offset count =
    if offset = String.length value
    then Some count
    else (
      let decoded = String.get_utf_8_uchar value offset in
      if Uchar.utf_decode_is_valid decoded
      then loop (offset + Uchar.utf_decode_length decoded) (count + 1)
      else None)
  in
  loop 0 0
;;

let contains_nul value = String.contains value '\000'

let validate_source value =
  if String.equal (String.trim value) ""
  then Error "source must not be blank"
  else if String.length value > 65_536
  then Error "source exceeds 65,536 UTF-8 bytes"
  else if not (is_valid_utf_8 value)
  then Error "source is not valid UTF-8"
  else if contains_nul value
  then Error "source contains NUL"
  else Ok ()
;;

let is_leap_year year = year mod 4 = 0 && (year mod 100 <> 0 || year mod 400 = 0)

let is_journal_day day =
  let year = day / 10_000 in
  let month = day / 100 mod 100 in
  let day_of_month = day mod 100 in
  let days_in_month =
    match month with
    | 1 | 3 | 5 | 7 | 8 | 10 | 12 -> 31
    | 4 | 6 | 9 | 11 -> 30
    | 2 -> if is_leap_year year then 29 else 28
    | _ -> 0
  in
  year >= 1 && day_of_month >= 1 && day_of_month <= days_in_month
;;
