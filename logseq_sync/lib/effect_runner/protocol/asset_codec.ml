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

let decode ~maximum_plaintext_bytes ~crypto ~key ~expected_checksum wire =
  if not (limit maximum_plaintext_bytes)
  then Error "Invalid plaintext size limit"
  else (
    let maximum_wire =
      match key with
      | None -> maximum_plaintext_bytes
      | Some _ -> (4 * ((maximum_plaintext_bytes + 16 + 2) / 3)) + 128
    in
    if String.length wire > maximum_wire
    then Error "Asset exceeds wire size limit"
    else
      let* plaintext =
        match key with
        | None -> Ok wire
        | Some _ when not (transit_candidate wire) ->
          (try Printf.eprintf "journal asset decode path=raw-fallback\n%!" with
           | _ -> ());
          Ok wire
        | Some key ->
          let* () =
            if envelope_shape wire then Ok () else Error "Invalid asset AES-GCM envelope"
          in
          let* value =
            try Ok (Codec.of_string wire) with
            | Transit.Decode_error message
            | Yojson.Json_error message
            | Failure message
            | Invalid_argument message -> Error ("Invalid asset Transit: " ^ message)
          in
          (match value with
           | Transit.Array [ Binary iv; Binary ciphertext ]
             when String.length iv = 12
                  && String.length ciphertext >= 16
                  && String.length ciphertext - 16 <= maximum_plaintext_bytes ->
             crypto.decrypt ~key ~iv ~ciphertext
           | _ -> Error "Invalid asset AES-GCM envelope")
      in
      if String.length plaintext > maximum_plaintext_bytes
      then Error "Asset exceeds plaintext size limit"
      else if checksum plaintext <> expected_checksum
      then Error "Asset checksum mismatch"
      else Ok plaintext)
;;
