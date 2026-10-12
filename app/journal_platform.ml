module Graph_service = Logseq_db_worker_lui.Logseq_db_worker_lui_service

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

module Json = struct
  type account = { userId : string option [@default None]; managedSyncOrigin : string option [@default None] }
  [@@deriving yojson]
  type user = { userId : string option [@default None] } [@@deriving yojson]
  type challenge = { challengeId : string } [@@deriving yojson]
  type token = { challengeId : string; token : string } [@@deriving yojson]
  type sign_out = { signedOut : bool } [@@deriving yojson]
  type ready = { ready : bool } [@@deriving yojson]
  type presented = { presented : bool } [@@deriving yojson]
  type notice =
    { token : int64; message : string; actionLabel : string option [@default None]; durationMs : int }
  [@@deriving yojson]
  type notice_result = { token : int64; result : string } [@@deriving yojson]
  type cancel = { token : int64 } [@@deriving yojson]
  type text = { text : string } [@@deriving yojson]
  type copied = { copied : bool } [@@deriving yojson]
end

let decode_json label decoder bytes =
  try Logseq_db_types.Json_codec.decode decoder (Yojson.Safe.from_string (Bytes.to_string bytes))
  with Yojson.Json_error _ -> Error (label ^ " is not valid JSON")
;;

let bounded_string maximum value =
  if String.length value > 0 && String.length value <= maximum
     && Journal_validation.is_valid_utf_8 value && not (String.contains value '\000')
  then Ok value else Error "platform auth text is invalid"
;;

let secure_origin value =
  let uri = Uri.of_string value in
  match Uri.scheme uri, Uri.host uri with
  | Some "https", Some _ when String.length value <= 2048 -> Ok value
  | _ -> Error "managed-sync origin must be one bounded HTTPS origin"
;;

let decode_local_account_binding bytes =
  let ( let* ) = Result.bind in
  let* payload = decode_envelope [21] bytes in
  let* wire = decode_json "local-account-binding response" Json.account_of_yojson payload in
  match wire.userId, wire.managedSyncOrigin with
  | None, None -> Ok None
  | Some user_id, Some managed_sync_origin ->
    let* user_id = bounded_string 512 user_id in
    let* managed_sync_origin = secure_origin managed_sync_origin in
    Ok (Some { user_id; managed_sync_origin })
  | _ -> Error "local-account-binding response fields are invalid"
;;

let decode_timeline_presented bytes =
  let ( let* ) = Result.bind in
  let* payload = decode_envelope [23] bytes in
  let* wire = decode_json "Timeline-presented response" Json.presented_of_yojson payload in
  if wire.presented then Ok () else Error "Timeline-presented response is malformed"
;;

let decode_authenticated_user bytes =
  let ( let* ) = Result.bind in
  let* payload = decode_envelope [7] bytes in
  let* wire = decode_json "authenticated-user response" Json.user_of_yojson payload in
  match wire.userId with
  | None -> Ok None
  | Some user -> Result.map Option.some (bounded_string 512 user)
;;

let json_request tag encoder value =
  encoder value |> Yojson.Safe.to_string |> Bytes.of_string |> encode_envelope tag
;;

let id_token_request (challenge : Graph_service.token_request) =
  json_request 8 Json.challenge_to_yojson
    { challengeId = Graph_service.token_request_id challenge } |> Result.get_ok
;;

let decode_id_token_response ~challenge_id bytes =
  let ( let* ) = Result.bind in
  let* payload = decode_envelope [9] bytes in
  let* wire = decode_json "ID-token response" Json.token_of_yojson payload in
  if String.equal wire.challengeId challenge_id
  then bounded_string maximum_envelope_payload_bytes wire.token
  else Error "ID-token response is unsolicited"
;;

let sign_out_request = encode_envelope 10 Bytes.empty |> Result.get_ok

let decode_sign_out_response bytes =
  let ( let* ) = Result.bind in
  let* payload = decode_envelope [11] bytes in
  let* wire = decode_json "sign-out response" Json.sign_out_of_yojson payload in
  if wire.signedOut then Ok () else Error "sign-out response fields are invalid"
;;

let is_prepare_to_terminate_event bytes =
  match decode_envelope [12] bytes with
  | Ok payload -> Bytes.length payload = 0
  | Error _ -> false
;;

let termination_ready_request = encode_envelope 13 Bytes.empty |> Result.get_ok

let decode_termination_ready_response bytes =
  let ( let* ) = Result.bind in
  let* payload = decode_envelope [14] bytes in
  let* wire = decode_json "termination-ready response" Json.ready_of_yojson payload in
  if wire.ready then Ok () else Error "termination-ready response fields are invalid"
;;

type notice_result = Notice_action | Notice_dismiss | Notice_swipe | Notice_timeout

let decode_environment_event bytes =
  Result.bind (decode_envelope [24] bytes) (fun payload ->
    match Yojson.Basic.from_string (Bytes.to_string payload) |> Journal_environment.decode_json with
    | Ok snapshot -> Ok snapshot
    | Error error -> Error ("environment event: " ^ error)
    | exception Yojson.Json_error _ -> Error "environment event is not valid JSON")
;;

let is_environment_event bytes = Result.is_ok (decode_envelope [24] bytes)

let show_notice_request ~token ~message ~action_label ~duration_ms =
  json_request 25 Json.notice_to_yojson
    { token; message; actionLabel = action_label; durationMs = duration_ms }
  |> Result.get_ok
;;

let decode_notice_response ~token bytes =
  let ( let* ) = Result.bind in
  let* payload = decode_envelope [26] bytes in
  let* wire = decode_json "notice response" Json.notice_result_of_yojson payload in
  if wire.token <> token then Error "notice response token is unsolicited"
  else match wire.result with
    | "action" -> Ok Notice_action
    | "dismiss" -> Ok Notice_dismiss
    | "swipe" -> Ok Notice_swipe
    | "timeout" -> Ok Notice_timeout
    | _ -> Error "notice response result is unsupported"
;;

let notice_cancel_request ~token =
  json_request 27 Json.cancel_to_yojson { token } |> Result.get_ok
;;

let copy_text_request ~text =
  if not (Journal_validation.is_valid_utf_8 text)
  then Error "Clipboard text is invalid."
  else json_request 28 Json.text_to_yojson { text }
;;

let decode_copy_text_response bytes =
  let ( let* ) = Result.bind in
  let* payload = decode_envelope [29] bytes in
  let* wire = decode_json "clipboard response" Json.copied_of_yojson payload in
  if wire.copied then Ok () else Error "Clipboard write was not acknowledged."
;;
