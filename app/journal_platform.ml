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

type network_lifecycle =
  | Backgrounded of { generation : int64 }
  | Foreground_resumed of { generation : int64 }

let envelope_header_size = 32
let maximum_envelope_payload_bytes = 256 * 1024

let encode_versioned_envelope ~runtime_generation ~graph_generation tag payload =
  let payload_length = Bytes.length payload in
  if
    payload_length > maximum_envelope_payload_bytes
    || Int64.compare runtime_generation 0L < 0
    || Int64.compare graph_generation 0L < 0
  then Error "application platform payload exceeds 256 KiB"
  else (
    let bytes = Bytes.make (envelope_header_size + payload_length) '\000' in
    Bytes.blit_string "LJP2" 0 bytes 0 4;
    Bytes.set_uint16_le bytes 4 2;
    Bytes.set_uint16_le bytes 6 tag;
    Bytes.set_int64_le bytes 8 runtime_generation;
    Bytes.set_int64_le bytes 16 graph_generation;
    Bytes.set_int32_le bytes 24 (Int32.of_int payload_length);
    Bytes.blit payload 0 bytes envelope_header_size payload_length;
    Ok bytes)
;;

let encode_envelope tag payload =
  encode_versioned_envelope ~runtime_generation:0L ~graph_generation:0L tag payload
;;

let decode_versioned_envelope bytes =
  let length = Bytes.length bytes in
  if length < envelope_header_size
  then Error "application platform envelope is truncated"
  else if length > envelope_header_size + maximum_envelope_payload_bytes
  then Error "application platform envelope exceeds its bound"
  else if not (Bytes.sub_string bytes 0 4 = "LJP2")
  then Error "application platform envelope magic is invalid"
  else if Bytes.get_uint16_le bytes 4 <> 2
  then Error "application platform envelope version is unsupported"
  else if Bytes.get_int32_le bytes 28 <> 0l
  then Error "application platform envelope reserved field is invalid"
  else (
    let tag = Bytes.get_uint16_le bytes 6 in
    let runtime_generation = Bytes.get_int64_le bytes 8 in
    let graph_generation = Bytes.get_int64_le bytes 16 in
    let payload_length = Bytes.get_int32_le bytes 24 in
    if
      Int64.compare runtime_generation 0L < 0
      || Int64.compare graph_generation 0L < 0
      || Int32.compare payload_length 0l < 0
      || Int32.to_int payload_length <> length - envelope_header_size
    then Error "application platform envelope payload length is invalid"
    else
      Ok
        ( tag
        , runtime_generation
        , graph_generation
        , Bytes.sub bytes envelope_header_size (Int32.to_int payload_length) ))
;;

let decode_envelope accepted_tags bytes =
  Result.bind (decode_versioned_envelope bytes) (fun (tag, runtime, graph, payload) ->
    if not (List.mem tag accepted_tags)
    then Error "application platform envelope tag is unsupported"
    else if runtime <> 0L || graph <> 0L
    then Error "application platform calendar generation field is invalid"
    else Ok payload)
;;

let get_calendar_request = encode_envelope 1 Bytes.empty |> Result.get_ok

let reason_of_wire = function
  | 0 -> Ok Requested
  | 1 -> Ok Resumed
  | 2 -> Ok Significant_time_changed
  | 3 -> Ok Time_zone_changed
  | 4 -> Ok Locale_changed
  | _ -> Error "application calendar reason is unsupported"
;;

let decode_calendar_payload bytes =
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

let decode_calendar bytes =
  Result.bind (decode_envelope [ 2; 3 ] bytes) decode_calendar_payload
;;

let decode_network_lifecycle bytes =
  Result.bind (decode_envelope [ 15 ] bytes) (fun payload ->
    if Bytes.length payload <> 16
    then Error "application network lifecycle packet has an invalid length"
    else if Bytes.sub_string payload 0 4 <> "LJP1"
    then Error "application network lifecycle magic is invalid"
    else if Bytes.get_uint16_le payload 4 <> 1
    then Error "application network lifecycle version is unsupported"
    else (
      let generation = Bytes.get_int64_le payload 8 in
      if Int64.compare generation 0L < 0
      then Error "application network lifecycle generation is invalid"
      else (
        match Bytes.get_uint16_le payload 6 with
        | 1 -> Ok (Backgrounded { generation })
        | 2 -> Ok (Foreground_resumed { generation })
        | _ -> Error "application network lifecycle transition is unsupported")))
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
    Result.bind (encode_envelope 4 bytes) (fun bytes -> Ok bytes))
;;

let decode_formatted_journal_days_payload bytes =
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

let decode_formatted_journal_days bytes =
  Result.bind (decode_envelope [ 5 ] bytes) decode_formatted_journal_days_payload
;;

let authenticated_user_request = encode_envelope 6 Bytes.empty |> Result.get_ok

let decode_json_object label bytes f =
  try
    match Yojson.Safe.from_string (Bytes.to_string bytes) with
    | `Assoc fields -> f fields
    | _ -> Error (label ^ " must be a JSON object")
  with
  | Yojson.Json_error _ -> Error (label ^ " is not valid JSON")
;;

let bounded_string maximum = function
  | `String value
    when String.length value > 0
         && String.length value <= maximum
         && Journal_validation.is_valid_utf_8 value
         && not (String.contains value '\000') -> Ok value
  | _ -> Error "platform auth text is invalid"
;;

let decode_authenticated_user bytes =
  Result.bind (decode_envelope [ 7 ] bytes) (fun payload ->
    decode_json_object "authenticated-user response" payload (function
      | [ ("userId", `Null) ] -> Ok None
      | [ ("userId", value) ] -> Result.map Option.some (bounded_string 512 value)
      | _ -> Error "authenticated-user response fields are invalid"))
;;

let purpose = function
  | Logseq_db_worker.Sync_auth.Catalog_discovery -> "catalogDiscovery"
  | Snapshot_bootstrap -> "snapshotBootstrap"
  | E2ee_key_access -> "e2eeKeyAccess"
  | Http_pull -> "httpPull"
  | Transaction_submission -> "transactionSubmission"
  | Websocket_connect -> "websocketConnect"
;;

let id_token_request (challenge : Logseq_db_worker.Sync_auth.challenge) =
  Yojson.Safe.to_string
    (`Assoc
        [ "challengeId", `String challenge.challenge_id
        ; "purpose", `String (purpose challenge.purpose)
        ])
  |> Bytes.of_string
  |> encode_envelope 8
  |> Result.get_ok
;;

let decode_id_token_response ~challenge_id bytes =
  Result.bind (decode_envelope [ 9 ] bytes) (fun payload ->
    decode_json_object "ID-token response" payload (function
      | [ ("challengeId", `String actual); ("token", token) ]
      | [ ("token", token); ("challengeId", `String actual) ]
        when String.equal actual challenge_id ->
        bounded_string maximum_envelope_payload_bytes token
      | _ -> Error "ID-token response is unsolicited or malformed"))
;;

let sign_out_request = encode_envelope 10 Bytes.empty |> Result.get_ok

let decode_sign_out_response bytes =
  Result.bind (decode_envelope [ 11 ] bytes) (fun payload ->
    decode_json_object "sign-out response" payload (function
      | [ ("signedOut", `Bool true) ] -> Ok ()
      | _ -> Error "sign-out response fields are invalid"))
;;

let is_prepare_to_terminate_event bytes =
  match decode_envelope [ 12 ] bytes with
  | Ok payload -> Bytes.length payload = 0
  | Error _ -> false
;;

let termination_ready_request = encode_envelope 13 Bytes.empty |> Result.get_ok

let decode_termination_ready_response bytes =
  Result.bind (decode_envelope [ 14 ] bytes) (fun payload ->
    decode_json_object "termination-ready response" payload (function
      | [ ("ready", `Bool true) ] -> Ok ()
      | _ -> Error "termination-ready response fields are invalid"))
;;
