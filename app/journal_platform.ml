type reason =
  | Requested
  | Resumed
  | Significant_time_changed
  | Time_zone_changed
  | Locale_changed

type calendar =
  { snapshot : Journal_calendar.t
  ; reason : reason
  }

type formatted_journal_days =
  { generation : int64
  ; headings : (int * string) list
  }

let get_calendar_request = Bytes.of_string "LJP1\001\000\001\000"

let reason_of_wire = function
  | 0 -> Ok Requested
  | 1 -> Ok Resumed
  | 2 -> Ok Significant_time_changed
  | 3 -> Ok Time_zone_changed
  | 4 -> Ok Locale_changed
  | _ -> Error "application calendar reason is unsupported"
;;

let decode_calendar bytes =
  let length = Bytes.length bytes in
  let header_size = 56 in
  if length < header_size
  then Error "application calendar packet is truncated"
  else if not (Bytes.sub_string bytes 0 4 = "LJP1")
  then Error "application calendar magic is invalid"
  else if Bytes.get_uint16_le bytes 4 <> 1
  then Error "application calendar version is unsupported"
  else if
    let tag = Bytes.get_uint16_le bytes 6 in
    tag <> 2 && tag <> 3
  then Error "application calendar packet tag is unsupported"
  else if
    Bytes.get_uint16_le bytes 14 <> 0
    || Bytes.get_uint16_le bytes 30 <> 0
    || Bytes.get_int32_le bytes 36 <> 0l
  then Error "application calendar reserved field is nonzero"
  else (
    let locale_length = Bytes.get_uint16_le bytes 10 in
    let time_zone_length = Bytes.get_uint16_le bytes 12 in
    if locale_length < 1 || locale_length > 128
    then Error "application calendar locale length is invalid"
    else if time_zone_length < 1 || time_zone_length > 256
    then Error "application calendar time-zone length is invalid"
    else if length <> header_size + locale_length + time_zone_length
    then Error "application calendar packet has trailing or missing bytes"
    else (
      let locale = Bytes.sub_string bytes header_size locale_length in
      let time_zone_id =
        Bytes.sub_string bytes (header_size + locale_length) time_zone_length
      in
      let local_day = Int32.to_int (Bytes.get_int32_le bytes 24) in
      let local_minute_of_day = Bytes.get_uint16_le bytes 28 in
      let utc_offset_seconds = Int32.to_int (Bytes.get_int32_le bytes 32) in
      let generation = Bytes.get_int64_le bytes 40 in
      let lifecycle_generation = Bytes.get_int64_le bytes 48 in
      if
        not
          (Journal_validation.is_valid_utf_8 locale
           && Journal_validation.is_valid_utf_8 time_zone_id)
      then Error "application calendar strings are not valid UTF-8"
      else if Int64.compare generation 0L < 0
      then Error "application calendar generation is invalid"
      else if Int64.compare lifecycle_generation 0L < 0
      then Error "application lifecycle generation is invalid"
      else (
        match
          Journal_time.create
            ~instant_unix_ms:(Bytes.get_int64_le bytes 16)
            ~local_day
            ~local_minute_of_day
            ~time_zone_id
            ~utc_offset_seconds
        with
        | Error message -> Error ("application calendar snapshot is invalid: " ^ message)
        | Ok _ ->
          Result.map
            (fun reason ->
               { snapshot =
                   { Journal_calendar.instant_unix_ms = Bytes.get_int64_le bytes 16
                   ; local_day
                   ; local_minute_of_day
                   ; locale
                   ; time_zone_id
                   ; utc_offset_seconds
                   ; generation
                   ; lifecycle_generation
                   }
               ; reason
               })
            (reason_of_wire (Bytes.get_uint16_le bytes 8)))))
;;

let format_journal_days_request ~generation days =
  let count = List.length days in
  if Int64.compare generation 0L < 0
  then Error "formatted journal day generation is invalid"
  else if count < 1 || count > 64
  then Error "formatted journal day count must be between 1 and 64"
  else if List.exists (fun day -> not (Journal_validation.is_journal_day day)) days
  then Error "formatted journal day request contains an invalid day"
  else if List.sort_uniq Int.compare days |> List.length <> count
  then Error "formatted journal day request contains duplicate days"
  else (
    let bytes = Bytes.make (20 + (count * 4)) '\000' in
    Bytes.blit_string "LJP1" 0 bytes 0 4;
    Bytes.set_uint16_le bytes 4 1;
    Bytes.set_uint16_le bytes 6 4;
    Bytes.set_int64_le bytes 8 generation;
    Bytes.set_uint16_le bytes 16 count;
    List.iteri
      (fun index day -> Bytes.set_int32_le bytes (20 + (index * 4)) (Int32.of_int day))
      days;
    Ok bytes)
;;

let decode_formatted_journal_days bytes =
  let length = Bytes.length bytes in
  if length < 20
  then Error "formatted journal day packet is truncated"
  else if not (Bytes.sub_string bytes 0 4 = "LJP1")
  then Error "formatted journal day magic is invalid"
  else if Bytes.get_uint16_le bytes 4 <> 1
  then Error "formatted journal day version is unsupported"
  else if Bytes.get_uint16_le bytes 6 <> 5
  then Error "formatted journal day packet tag is unsupported"
  else if Bytes.get_uint16_le bytes 18 <> 0
  then Error "formatted journal day reserved field is nonzero"
  else (
    let generation = Bytes.get_int64_le bytes 8 in
    let count = Bytes.get_uint16_le bytes 16 in
    if Int64.compare generation 0L < 0
    then Error "formatted journal day generation is invalid"
    else if count < 1 || count > 64
    then Error "formatted journal day count is invalid"
    else (
      let rec decode index offset headings seen =
        if index = count
        then
          if offset = length
          then Ok { generation; headings = List.rev headings }
          else Error "formatted journal day packet has trailing bytes"
        else if offset + 8 > length
        then Error "formatted journal day entry is truncated"
        else (
          let day = Int32.to_int (Bytes.get_int32_le bytes offset) in
          let heading_length = Bytes.get_uint16_le bytes (offset + 4) in
          if Bytes.get_uint16_le bytes (offset + 6) <> 0
          then Error "formatted journal day entry reserved field is nonzero"
          else if not (Journal_validation.is_journal_day day)
          then Error "formatted journal day entry has an invalid day"
          else if List.mem day seen
          then Error "formatted journal day response contains duplicate days"
          else if heading_length < 1 || heading_length > 512
          then Error "formatted journal day heading length is invalid"
          else if offset + 8 + heading_length > length
          then Error "formatted journal day heading is truncated"
          else (
            let heading = Bytes.sub_string bytes (offset + 8) heading_length in
            if not (Journal_validation.is_valid_utf_8 heading)
            then Error "formatted journal day heading is not valid UTF-8"
            else
              decode
                (index + 1)
                (offset + 8 + heading_length)
                ((day, heading) :: headings)
                (day :: seen)))
      in
      decode 0 20 [] []))
;;
