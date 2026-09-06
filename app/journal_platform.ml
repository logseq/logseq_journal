module Graph_service = Logseq_db_worker_bonsai.Logseq_db_worker_bonsai_service

type network_lifecycle =
  | Backgrounded of { generation : int64 }
  | Foreground_resumed of { generation : int64 }

type local_account_binding =
  { user_id : string
  ; managed_sync_origin : string
  }

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
    then Error "application platform envelope generation fields are invalid"
    else Ok payload)
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

let authenticated_user_request = encode_envelope 6 Bytes.empty |> Result.get_ok
let local_account_binding_request = encode_envelope 20 Bytes.empty |> Result.get_ok
let timeline_presented_request = encode_envelope 22 Bytes.empty |> Result.get_ok

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

let secure_origin = function
  | `String value ->
    let uri = Uri.of_string value in
    (match Uri.scheme uri, Uri.host uri with
     | Some "https", Some _ when String.length value <= 2048 -> Ok value
     | _ -> Error "managed-sync origin must be one bounded HTTPS origin")
  | _ -> Error "managed-sync origin is invalid"
;;

let decode_local_account_binding bytes =
  Result.bind (decode_envelope [ 21 ] bytes) (fun payload ->
    decode_json_object "local-account-binding response" payload (fun fields ->
      if List.length fields <> 2
      then Error "local-account-binding response fields are invalid"
      else (
        match
          List.assoc_opt "userId" fields, List.assoc_opt "managedSyncOrigin" fields
        with
        | Some `Null, Some `Null -> Ok None
        | Some user_id, Some origin ->
          Result.bind (bounded_string 512 user_id) (fun user_id ->
            Result.map
              (fun managed_sync_origin -> Some { user_id; managed_sync_origin })
              (secure_origin origin))
        | _ -> Error "local-account-binding response fields are invalid")))
;;

let decode_timeline_presented bytes =
  Result.bind (decode_envelope [ 23 ] bytes) (fun payload ->
    decode_json_object "Timeline-presented response" payload (fun fields ->
      if List.length fields = 1 && List.assoc_opt "presented" fields = Some (`Bool true)
      then Ok ()
      else Error "Timeline-presented response is malformed"))
;;

let decode_authenticated_user bytes =
  Result.bind (decode_envelope [ 7 ] bytes) (fun payload ->
    decode_json_object "authenticated-user response" payload (function
      | [ ("userId", `Null) ] -> Ok None
      | [ ("userId", value) ] -> Result.map Option.some (bounded_string 512 value)
      | _ -> Error "authenticated-user response fields are invalid"))
;;

let typography_preset_preference_key = "typographyPreset"

let typography_preset_preference_request =
  Yojson.Safe.to_string (`Assoc [ "key", `String typography_preset_preference_key ])
  |> Bytes.of_string
  |> encode_envelope 16
  |> Result.get_ok
;;

let decode_typography_preset_preference bytes =
  Result.bind (decode_envelope [ 17 ] bytes) (fun payload ->
    decode_json_object "typography-preset preference response" payload (function
      | [ ("key", `String key); ("value", `Null) ]
      | [ ("value", `Null); ("key", `String key) ]
        when String.equal key typography_preset_preference_key -> Ok None
      | [ ("key", `String key); ("value", value) ]
      | [ ("value", value); ("key", `String key) ]
        when String.equal key typography_preset_preference_key ->
        Result.map Option.some (bounded_string 64 value)
      | _ -> Error "typography-preset preference response fields are invalid"))
;;

let set_typography_preset_preference_request value =
  if
    not
      (String.equal value "dense"
       || String.equal value "balanced"
       || String.equal value "comfortable")
  then invalid_arg "typography preset preference is invalid";
  Yojson.Safe.to_string
    (`Assoc [ "key", `String typography_preset_preference_key; "value", `String value ])
  |> Bytes.of_string
  |> encode_envelope 18
  |> Result.get_ok
;;

let decode_set_typography_preset_preference bytes =
  Result.bind (decode_envelope [ 19 ] bytes) (fun payload ->
    decode_json_object "set typography-preset preference response" payload (function
      | [ ("key", `String key); ("stored", `Bool true) ]
      | [ ("stored", `Bool true); ("key", `String key) ]
        when String.equal key typography_preset_preference_key -> Ok ()
      | _ -> Error "set typography-preset preference response fields are invalid"))
;;

let id_token_request (challenge : Graph_service.token_request) =
  Yojson.Safe.to_string
    (`Assoc [ "challengeId", `String (Graph_service.token_request_id challenge) ])
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
