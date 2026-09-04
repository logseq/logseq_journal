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

let protect operation f =
  try Ok (f ()) with
  | Transit.Decode_error message
  | Yojson.Json_error message
  | Failure message
  | Invalid_argument message -> Error (operation ^ ": " ^ message)
  | error -> Error (operation ^ ": " ^ Printexc.to_string error)
;;

let bounded_string field = function
  | `String value
    when String.length value > 0
         && String.length value <= 65_536
         && String.is_valid_utf_8 value
         && not (String.contains value '\000') -> Ok value
  | `String _
  | `Assoc _
  | `List _
  | `Tuple _
  | `Variant _
  | `Null
  | `Bool _
  | `Int _
  | `Intlit _
  | `Float _ -> Error ("E2EE response " ^ field ^ " must be a bounded non-empty string")
;;

let graph_key_response source =
  try
    match Yojson.Safe.from_string source with
    | `Assoc [ ("encrypted-aes-key", value) ] -> bounded_string "encrypted-aes-key" value
    | `Assoc _ | `List _ | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ ->
      Error "E2EE graph-key response must contain exactly one encrypted-aes-key string"
  with
  | Yojson.Json_error _ -> Error "E2EE response must be valid JSON"
;;

let user_keys_response source =
  try
    match Yojson.Safe.from_string source with
    | `Assoc
        [ ("public-key", public_key); ("encrypted-private-key", encrypted_private_key) ]
    | `Assoc
        [ ("encrypted-private-key", encrypted_private_key); ("public-key", public_key) ]
      ->
      bind (bounded_string "public-key" public_key) (fun _ ->
        bounded_string "encrypted-private-key" encrypted_private_key)
    | `Assoc _ | `List _ | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ ->
      Error
        "E2EE user-key response must contain exactly public-key and \
         encrypted-private-key strings"
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
    bind (crypto.decrypt_aes_gcm ~key:graph_key ~iv ~ciphertext) (fun plaintext ->
      protect "decode decrypted value" (fun () -> Codec.of_string plaintext))
  | Ok plaintext -> Ok plaintext
;;
