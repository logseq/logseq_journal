module Transit = Transit_core.Json
module Codec = Transit_native.Transit.Json

type crypto =
  { decrypt_aes_gcm :
      key:string -> iv:string -> ciphertext:string -> (string, string) result
  }

type private_key_package =
  { salt : string
  ; iv : string
  ; ciphertext : string
  }

let bind result f =
  match result with
  | Ok value -> f value
  | Error _ as error -> error
;;

let protect parse_operation f =
  let operation_name = match parse_operation with
    | "decode protected value" | "decode decrypted value" -> "decryptValue"
    | _ -> "platformCrypto" in
  let parse_failure () =
    Error (Logseq_db_types.Failure_diagnostic.(
      create ~operation:operation_name ~reason:"parseFailed"
        ~source:(parse_operation ^ " failed") () |> message)) in
  try Ok (f ()) with
  | Transit.Decode_error _ | Yojson.Json_error _ | Failure _ | Invalid_argument _ ->
    parse_failure ()
  | error -> Error (Logseq_db_types.Failure_diagnostic.(
      of_source ~operation:operation_name ~reason:"parseFailed"
        (Printexc.to_string error) |> message))
;;

let bounded_string field value =
  if
    String.length value > 0
    && String.length value <= 65_536
    && String.is_valid_utf_8 value
    && not (String.contains value '\000')
  then Ok value
  else Error ("E2EE response " ^ field ^ " must be a bounded non-empty string")
;;

type graph_key_response_dto =
  { encrypted_aes_key : string [@key "encrypted-aes-key"]
  ; encrypted_aes_key_base64 : string option
        [@key "encrypted-aes-key-base64"] [@default None]
  }
[@@deriving of_yojson { strict = false }]

type user_keys_response_dto =
  { public_key : string [@key "public-key"]
  ; encrypted_private_key : string [@key "encrypted-private-key"]
  }
[@@deriving of_yojson { strict = false }]

let graph_key_response source =
  try
    bind
      (Logseq_db_types.Json_codec.decode
         graph_key_response_dto_of_yojson
         (Yojson.Safe.from_string source)
       |> Result.map_error (fun _ -> "E2EE graph key response shape is invalid"))
      (fun dto ->
         (* The optional compatibility field is validated by PPX but not consumed. *)
         let _ = dto.encrypted_aes_key_base64 in
         bounded_string "encrypted-aes-key" dto.encrypted_aes_key)
  with
  | Yojson.Json_error _ -> Error "E2EE response must be valid JSON"
;;

let user_keys_response source =
  try
    bind
      (Logseq_db_types.Json_codec.decode
         user_keys_response_dto_of_yojson
         (Yojson.Safe.from_string source)
       |> Result.map_error (fun _ -> "E2EE user keys response shape is invalid"))
      (fun dto ->
         bind (bounded_string "public-key" dto.public_key) (fun _ ->
           bounded_string "encrypted-private-key" dto.encrypted_private_key))
  with
  | Yojson.Json_error _ -> Error "E2EE response must be valid JSON"
;;

let private_key_package source =
  bind
    (protect "decode encrypted private key" (fun () -> Codec.of_string source))
    (function
      | Transit.Array
          [ Transit.String "20251210"
          ; Transit.Binary salt
          ; Transit.Binary iv
          ; Transit.Binary ciphertext
          ] -> Ok { salt; iv; ciphertext }
      | _ -> Error "encrypted private key must use the 20251210 Transit envelope")
;;

let binary source =
  bind
    (protect "decode encrypted graph key" (fun () -> Codec.of_string source))
    (function
      | Transit.Binary value -> Ok value
      | _ -> Error "encrypted graph key is not Transit binary")
;;

let decrypt_value ~crypto ~graph_key source =
  match protect "decode protected value" (fun () -> Codec.of_string source) with
  | Error _ -> Ok (Transit.String source)
  | Ok (Transit.Array [ Transit.Binary iv; Transit.Binary ciphertext ]) ->
    (match crypto.decrypt_aes_gcm ~key:graph_key ~iv ~ciphertext with
     | Error source ->
       Error (Logseq_db_types.Failure_diagnostic.(
         of_source ~operation:"decryptValue" ~reason:"cryptoInvalid" source |> encode))
     | Ok plaintext ->
       (match protect "decode decrypted value" (fun () -> Codec.of_string plaintext) with
        | Ok value -> Ok value
        | Error _ ->
          Error (Logseq_db_types.Failure_diagnostic.(
            create ~operation:"decryptValue" ~reason:"parseFailed"
              ~source:"decrypted Transit is invalid" () |> encode))))
  | Ok plaintext -> Ok plaintext
;;
