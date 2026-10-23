module Transit = Transit_core.Json
module Codec = Transit_native.Transit.Json

type crypto =
  { encrypt : key:string -> plaintext:string -> (string * string, string) result
  ; decrypt : key:string -> iv:string -> ciphertext:string -> (string, string) result
  }

let checksum bytes = Digestif.SHA256.(to_hex (digest_string bytes))
let ( let* ) = Result.bind
let limit maximum = maximum >= 0 && maximum <= 100 * 1024 * 1024

let encode ~maximum_plaintext_bytes ~crypto ~key bytes =
  if
    (not (limit maximum_plaintext_bytes)) || String.length bytes > maximum_plaintext_bytes
  then Error "Asset exceeds plaintext size limit"
  else (
    match key with
    | None -> Ok bytes
    | Some key ->
      let* iv, ciphertext = crypto.encrypt ~key ~plaintext:bytes in
      if String.length iv <> 12 || String.length ciphertext <> String.length bytes + 16
      then Error "Invalid AES-GCM output"
      else Ok (Codec.to_string (Transit.Array [ Binary iv; Binary ciphertext ])))
;;

let envelope_shape wire =
  let length = String.length wire in
  let rec whitespace index =
    if index < length
    then (
      match wire.[index] with
      | ' ' | '\n' | '\r' | '\t' -> whitespace (index + 1)
      | _ -> index)
    else index
  in
  let delimiter index expected =
    let index = whitespace index in
    if index < length && wire.[index] = expected then Some (index + 1) else None
  in
  let string_end index =
    let rec scan index =
      if index >= length
      then None
      else (
        match wire.[index] with
        | '"' -> Some (index + 1)
        | '\\' -> scan (index + 2)
        | _ -> scan (index + 1))
    in
    Option.bind (delimiter index '"') scan
  in
  let ( let* ) = Option.bind in
  Option.is_some
    (let* index = delimiter 0 '[' in
     let* index = string_end index in
     let* index = delimiter index ',' in
     let* index = string_end index in
     let* index = delimiter index ']' in
     if whitespace index = length then Some () else None)
;;

(* Reserve JSON/Transit roots, including incomplete envelopes, for the existing
   bounded decoder. A parse/authentication failure is never a raw-file signal. *)
let transit_candidate wire =
  let length = String.length wire in
  let whitespace = function
    | ' ' | '\n' | '\r' | '\t' -> true
    | _ -> false
  in
  let rec start index =
    if index < length && whitespace wire.[index]
    then start (index + 1)
    else if
      index + 3 <= length
      && wire.[index] = '\239'
      && wire.[index + 1] = '\187'
      && wire.[index + 2] = '\191'
    then start (index + 3)
    else index
  in
  let index = start 0 in
  let literal text =
    let count = String.length text in
    let rec prefix offset =
      if index + offset = length
      then true
      else if offset = count
      then (
        match wire.[index + offset] with
        | ']' | '}' | ',' -> true
        | c -> whitespace c)
      else wire.[index + offset] = text.[offset] && prefix (offset + 1)
    in
    prefix 0
  in
  index < length
  &&
  match wire.[index] with
  | '[' | '{' | '"' | '0' .. '9' -> true
  | '-' ->
    index + 1 = length
    ||
      (match wire.[index + 1] with
      | '0' .. '9' -> true
      | _ -> false)
  | 't' -> literal "true"
  | 'f' -> literal "false"
  | 'n' -> literal "null"
  | _ -> false
;;

type decode_error =
  | Invalid_limit
  | Wire_too_large
  | Plaintext_too_large
  | Malformed_envelope
  | Malformed_transit of string
  | Decryption_failed of string
  | Checksum_mismatch

let decode_error_message = function
  | Invalid_limit -> "Invalid plaintext size limit"
  | Wire_too_large -> "Asset exceeds wire size limit"
  | Plaintext_too_large -> "Asset exceeds plaintext size limit"
  | Malformed_envelope -> "Invalid asset AES-GCM envelope"
  | Malformed_transit message -> "Invalid asset Transit: " ^ message
  | Decryption_failed message -> message
  | Checksum_mismatch -> "Asset checksum mismatch"
;;

(* These roles stay inside the decoder: a failed candidate has no raw constructor
   path, and ciphertext cannot be fed directly to verification. *)
type raw = Raw of string
type envelope = Envelope of { iv : string; ciphertext : string }
type plaintext = Plaintext of string
type classified = Clear of raw | Protected of envelope

type verified =
  { bytes : string
  ; version : Logseq_db_types.Asset_descriptor.version
  }

let verified_bytes value = value.bytes
let verified_version value = value.version

let classify ~maximum_plaintext_bytes ~key wire =
  match key with
  | None -> Ok (Clear (Raw wire))
  | Some _ when not (transit_candidate wire) ->
    (try Printf.eprintf "journal asset decode path=raw-fallback\n%!" with
     | _ -> ());
    Ok (Clear (Raw wire))
  | Some _ ->
    let* () = if envelope_shape wire then Ok () else Error Malformed_envelope in
    let* value =
      try Ok (Codec.of_string wire) with
      | Transit.Decode_error message
      | Yojson.Json_error message
      | Failure message
      | Invalid_argument message -> Error (Malformed_transit message)
    in
    (match value with
     | Transit.Array [ Binary iv; Binary ciphertext ]
       when String.length iv = 12
            && String.length ciphertext >= 16
            && String.length ciphertext - 16 <= maximum_plaintext_bytes ->
       Ok (Protected (Envelope { iv; ciphertext }))
     | _ -> Error Malformed_envelope)
;;

let decode ~maximum_plaintext_bytes ~crypto ~key ~expected wire =
  if not (limit maximum_plaintext_bytes)
  then Error Invalid_limit
  else (
    let maximum_wire =
      match key with
      | None -> maximum_plaintext_bytes
      | Some _ -> (4 * ((maximum_plaintext_bytes + 16 + 2) / 3)) + 128
    in
    if String.length wire > maximum_wire
    then Error Wire_too_large
    else
      let* classified = classify ~maximum_plaintext_bytes ~key wire in
      let* Plaintext plaintext =
        match classified, key with
        | Clear (Raw bytes), _ -> Ok (Plaintext bytes)
        | Protected (Envelope { iv; ciphertext }), Some key ->
          crypto.decrypt ~key ~iv ~ciphertext
          |> Result.map (fun bytes -> Plaintext bytes)
          |> Result.map_error (fun message -> Decryption_failed message)
        | Protected _, None -> Error Malformed_envelope
      in
      if String.length plaintext > maximum_plaintext_bytes
      then Error Plaintext_too_large
      else if checksum plaintext <> expected.Logseq_db_types.Asset_descriptor.checksum
      then Error Checksum_mismatch
      else Ok { bytes = plaintext; version = expected })
;;
