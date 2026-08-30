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
