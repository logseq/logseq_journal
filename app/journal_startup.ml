module Error = struct
  type t = Invalid of string

  let to_string (Invalid message) = message
end

type access_mode =
  | Read_write
  | Recovery_only

type diagnostic_mode = Operational_only

type calendar_snapshot =
  { instant_unix_ms : int64
  ; local_day : int
  ; local_minute_of_day : int
  ; locale : string
  ; time_zone_id : string
  ; utc_offset_seconds : int
  ; generation : int64
  ; lifecycle_generation : int64
  }

type t =
  { application_support_root : string
  ; expected_schema_version : int
  ; initial_calendar : calendar_snapshot
  ; access_mode : access_mode
  ; diagnostic_mode : diagnostic_mode
  }

let database_relative_path = "logseq_journal/store.sqlite3"
let magic = "LJR1"
let envelope_version = 1
let schema_version = 1
let header_size = 64
let maximum_payload_bytes = 1024 * 1024
let maximum_root_bytes = 4096
let maximum_locale_bytes = 128
let error format = Printf.ksprintf (fun message -> Error (Error.Invalid message)) format
let has_nul value = String.contains value '\x00'

let validate_utf8_field ~name ~maximum_bytes value =
  if String.length value = 0
  then error "%s must not be empty" name
  else if String.length value > maximum_bytes
  then error "%s exceeds %d UTF-8 bytes" name maximum_bytes
  else if not (String.is_valid_utf_8 value)
  then error "%s must be valid UTF-8" name
  else if has_nul value
  then error "%s must not contain NUL" name
  else Ok ()
;;

let validate_root root =
  let components = String.split_on_char '/' root in
  if Filename.is_relative root
  then error "Application Support root must be absolute"
  else if String.length root > maximum_root_bytes
  then error "Application Support root exceeds %d UTF-8 bytes" maximum_root_bytes
  else if not (String.is_valid_utf_8 root)
  then error "Application Support root must be valid UTF-8"
  else if has_nul root
  then error "Application Support root must not contain NUL"
  else if String.contains root '\\'
  then error "Application Support root must use platform separators"
  else if String.equal root "/"
  then error "Application Support root must not be the filesystem root"
  else (
    match components with
    | "" :: rest
      when rest <> []
           && List.for_all
                (fun component ->
                   component <> "" && component <> "." && component <> "..")
                rest -> Ok ()
    | _ -> error "Application Support root must be a canonical absolute path")
;;

let validate_calendar snapshot =
  match
    validate_utf8_field
      ~name:"initial calendar locale"
      ~maximum_bytes:maximum_locale_bytes
      snapshot.locale
  with
  | Error _ as result -> result
  | Ok () ->
    if Int64.compare snapshot.generation 0L < 0
    then error "initial calendar generation must be nonnegative"
    else if Int64.compare snapshot.lifecycle_generation 0L < 0
    then error "initial lifecycle generation must be nonnegative"
    else (
      match
        Journal_time.create
          ~instant_unix_ms:snapshot.instant_unix_ms
          ~local_day:snapshot.local_day
          ~local_minute_of_day:snapshot.local_minute_of_day
          ~time_zone_id:snapshot.time_zone_id
          ~utc_offset_seconds:snapshot.utc_offset_seconds
      with
      | Ok _ -> Ok ()
      | Error message -> error "initial calendar snapshot is invalid: %s" message)
;;

let validate value =
  match validate_root value.application_support_root with
  | Error _ as result -> result
  | Ok () ->
    if value.expected_schema_version <> schema_version
    then error "unsupported expected schema version: %d" value.expected_schema_version
    else validate_calendar value.initial_calendar
;;

let set_u32 bytes offset value = Bytes.set_int32_le bytes offset (Int32.of_int value)

let encode value =
  match validate value with
  | Error _ as result -> result
  | Ok () ->
    let root = value.application_support_root in
    let locale = value.initial_calendar.locale in
    let time_zone = value.initial_calendar.time_zone_id in
    let size =
      header_size + String.length root + String.length locale + String.length time_zone
    in
    if size > maximum_payload_bytes
    then error "startup payload exceeds 1 MiB"
    else (
      let bytes = Bytes.make size '\x00' in
      Bytes.blit_string magic 0 bytes 0 4;
      set_u32 bytes 4 envelope_version;
      set_u32 bytes 8 (String.length root);
      set_u32 bytes 12 (String.length locale);
      set_u32 bytes 16 (String.length time_zone);
      Bytes.set_int64_le bytes 24 value.initial_calendar.instant_unix_ms;
      set_u32 bytes 32 value.initial_calendar.local_day;
      Bytes.set_uint16_le bytes 36 value.initial_calendar.local_minute_of_day;
      Bytes.set_int32_le bytes 40 (Int32.of_int value.initial_calendar.utc_offset_seconds);
      Bytes.set_int64_le bytes 48 value.initial_calendar.generation;
      Bytes.set_int64_le bytes 56 value.initial_calendar.lifecycle_generation;
      let offset = ref header_size in
      List.iter
        (fun field ->
           Bytes.blit_string field 0 bytes !offset (String.length field);
           offset := !offset + String.length field)
        [ root; locale; time_zone ];
      Ok bytes)
;;

let get_length bytes offset name =
  let value = Bytes.get_int32_le bytes offset in
  if Int32.compare value 0l < 0
  then error "%s length is out of range" name
  else Ok (Int32.to_int value)
;;

let decode bytes =
  let length = Bytes.length bytes in
  if length = 0
  then error "startup payload is empty"
  else if length > maximum_payload_bytes
  then error "startup payload exceeds 1 MiB"
  else if length < header_size
  then error "startup payload is truncated"
  else if not (String.equal (Bytes.sub_string bytes 0 4) magic)
  then error "invalid startup magic"
  else if Bytes.get_int32_le bytes 4 <> Int32.of_int envelope_version
  then error "unsupported startup envelope version"
  else if
    Bytes.get_int32_le bytes 20 <> 0l
    || Bytes.get_uint16_le bytes 38 <> 0
    || Bytes.get_int32_le bytes 44 <> 0l
  then error "startup reserved bytes must be zero"
  else (
    match
      ( get_length bytes 8 "Application Support root"
      , get_length bytes 12 "locale"
      , get_length bytes 16 "time-zone ID" )
    with
    | (Error _ as result), _, _ | _, (Error _ as result), _ | _, _, (Error _ as result) ->
      result
    | Ok root_length, Ok locale_length, Ok time_zone_length ->
      let expected_length =
        header_size + root_length + locale_length + time_zone_length
      in
      if expected_length > length
      then error "startup payload is truncated"
      else if expected_length < length
      then error "startup payload has trailing bytes"
      else (
        let take offset field_length =
          Bytes.sub_string bytes offset field_length, offset + field_length
        in
        let root, offset = take header_size root_length in
        let locale, offset = take offset locale_length in
        let time_zone_id, _ = take offset time_zone_length in
        let value =
          { application_support_root = root
          ; expected_schema_version = schema_version
          ; initial_calendar =
              { instant_unix_ms = Bytes.get_int64_le bytes 24
              ; local_day = Int32.to_int (Bytes.get_int32_le bytes 32)
              ; local_minute_of_day = Bytes.get_uint16_le bytes 36
              ; locale
              ; time_zone_id
              ; utc_offset_seconds = Int32.to_int (Bytes.get_int32_le bytes 40)
              ; generation = Bytes.get_int64_le bytes 48
              ; lifecycle_generation = Bytes.get_int64_le bytes 56
              }
          ; access_mode = Read_write
          ; diagnostic_mode = Operational_only
          }
        in
        match validate value with
        | Ok () -> Ok value
        | Error _ as result -> result))
;;
