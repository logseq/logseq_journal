type cursor_payload =
  { api_version : int
  ; fingerprint : string
  ; basis : int64
  ; last_sort_key : string
  ; expires_at_ms : int64
  }

type error =
  | Invalid_limit
  | Invalid_cursor
  | Cursor_tampered
  | Cursor_expired
  | Cursor_conflict

let validate_limit limit =
  if limit > 0 && limit <= Protocol.maximum_page_size then Ok () else Error Invalid_limit
;;

let canonical_json json = Yojson.Safe.to_string (Yojson.Safe.sort json)
let fingerprint json = Digestif.SHA256.(to_hex (digest_string (canonical_json json)))

let base64url_alphabet =
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
;;

let base64url_encode value =
  let length = String.length value in
  let output = Buffer.create ((length + 2) / 3 * 4) in
  let rec encode offset =
    if offset < length
    then (
      let first = Char.code value.[offset] in
      let has_second = offset + 1 < length in
      let has_third = offset + 2 < length in
      let second = if has_second then Char.code value.[offset + 1] else 0 in
      let third = if has_third then Char.code value.[offset + 2] else 0 in
      Buffer.add_char output base64url_alphabet.[first lsr 2];
      Buffer.add_char
        output
        base64url_alphabet.[((first land 0x03) lsl 4) lor (second lsr 4)];
      if has_second
      then
        Buffer.add_char
          output
          base64url_alphabet.[((second land 0x0f) lsl 2) lor (third lsr 6)];
      if has_third then Buffer.add_char output base64url_alphabet.[third land 0x3f];
      encode (offset + 3))
  in
  encode 0;
  Buffer.contents output
;;

let base64url_value character =
  match String.index_opt base64url_alphabet character with
  | Some value -> value
  | None -> -1
;;

let base64url_decode value =
  let length = String.length value in
  if length = 0 || length mod 4 = 1
  then None
  else (
    let output = Buffer.create (length * 3 / 4) in
    let rec decode offset =
      if offset = length
      then Some (Buffer.contents output)
      else (
        let remaining = length - offset in
        let count = min 4 remaining in
        let digit index =
          if index < count then base64url_value value.[offset + index] else 0
        in
        let first = digit 0 in
        let second = digit 1 in
        let third = digit 2 in
        let fourth = digit 3 in
        if
          count < 2
          || List.exists (fun digit -> digit < 0) [ first; second; third; fourth ]
        then None
        else (
          Buffer.add_char output (Char.chr ((first lsl 2) lor (second lsr 4)));
          if count >= 3
          then
            Buffer.add_char
              output
              (Char.chr (((second land 0x0f) lsl 4) lor (third lsr 2)));
          if count = 4
          then Buffer.add_char output (Char.chr (((third land 0x03) lsl 6) lor fourth));
          decode (offset + count)))
    in
    decode 0)
;;

let payload_to_yojson payload =
  `Assoc
    [ "apiVersion", `Int payload.api_version
    ; "basis", `Intlit (Int64.to_string payload.basis)
    ; "expiresAtMs", `Intlit (Int64.to_string payload.expires_at_ms)
    ; "fingerprint", `String payload.fingerprint
    ; "lastSortKey", `String payload.last_sort_key
    ]
;;

let payload_of_yojson = function
  | `Assoc fields when List.length fields = 5 ->
    (match
       ( List.assoc_opt "apiVersion" fields
       , List.assoc_opt "basis" fields
       , List.assoc_opt "expiresAtMs" fields
       , List.assoc_opt "fingerprint" fields
       , List.assoc_opt "lastSortKey" fields )
     with
     | ( Some (`Int api_version)
       , Some ((`Int _ | `Intlit _) as basis_json)
       , Some ((`Int _ | `Intlit _) as expires_json)
       , Some (`String fingerprint)
       , Some (`String last_sort_key) ) ->
       (try
          let int64 = function
            | `Int value -> Int64.of_int value
            | `Intlit value -> Int64.of_string value
            | _ -> assert false
          in
          Ok
            { api_version
            ; basis = int64 basis_json
            ; expires_at_ms = int64 expires_json
            ; fingerprint
            ; last_sort_key
            }
        with
        | Failure _ -> Error Invalid_cursor)
     | _ -> Error Invalid_cursor)
  | _ -> Error Invalid_cursor
;;

let signature ~key payload =
  Digestif.SHA256.(to_raw_string (hmac_string ~key:(Bytes.to_string key) payload))
;;

let encode_cursor ~key payload =
  if Bytes.length key < 32 || payload.api_version <> Protocol.api_version
  then Error Invalid_cursor
  else (
    let payload_json = canonical_json (payload_to_yojson payload) in
    Graph_types.Cursor.of_string
      (base64url_encode (payload_json ^ signature ~key payload_json))
    |> Result.map_error (fun _ -> Invalid_cursor))
;;

let constant_time_equal left right =
  if String.length left <> String.length right
  then false
  else (
    let difference = ref 0 in
    for index = 0 to String.length left - 1 do
      difference := !difference lor (Char.code left.[index] lxor Char.code right.[index])
    done;
    !difference = 0)
;;

let decode_cursor ~key ~now_ms cursor =
  if Bytes.length key < 32
  then Error Invalid_cursor
  else (
    let encoded = Graph_types.Cursor.to_string cursor in
    match base64url_decode encoded with
    | Some envelope when String.length envelope > 32 ->
      let payload_length = String.length envelope - 32 in
      let payload_json = String.sub envelope 0 payload_length in
      let supplied_signature = String.sub envelope payload_length 32 in
      if not (constant_time_equal supplied_signature (signature ~key payload_json))
      then Error Cursor_tampered
      else (
        try
          let json = Yojson.Safe.from_string payload_json in
          if not (String.equal payload_json (canonical_json json))
          then Error Invalid_cursor
          else
            Result.bind (payload_of_yojson json) (fun payload ->
              if payload.api_version <> Protocol.api_version
              then Error Invalid_cursor
              else if Int64.compare now_ms payload.expires_at_ms > 0
              then Error Cursor_expired
              else Ok payload)
        with
        | Yojson.Json_error _ -> Error Invalid_cursor)
    | Some _ | None -> Error Invalid_cursor)
;;
