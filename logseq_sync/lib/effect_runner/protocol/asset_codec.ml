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
