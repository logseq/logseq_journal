module Transit = Transit_core.Json
module Codec = Transit_native.Transit.Json

type crypto =
  { decrypt_private_key :
      password:string
      -> iterations:int
      -> salt:string
      -> iv:string
      -> ciphertext:string
      -> (string, string) result
  ; decrypt_graph_key : private_key:string -> ciphertext:string -> (string, string) result
  ; encrypt_aes_gcm : key:string -> plaintext:string -> (string * string, string) result
  ; decrypt_aes_gcm :
      key:string -> iv:string -> ciphertext:string -> (string, string) result
  }

type private_key_package =
  { salt : string
  ; iv : string
  ; ciphertext : string
  }

let unavailable_crypto =
  { decrypt_private_key =
      (fun ~password:_ ~iterations:_ ~salt:_ ~iv:_ ~ciphertext:_ ->
        Error "crypto unavailable")
  ; decrypt_graph_key = (fun ~private_key:_ ~ciphertext:_ -> Error "crypto unavailable")
  ; encrypt_aes_gcm = (fun ~key:_ ~plaintext:_ -> Error "crypto unavailable")
  ; decrypt_aes_gcm = (fun ~key:_ ~iv:_ ~ciphertext:_ -> Error "crypto unavailable")
  }
;;

let protected_attributes = [ "block/title"; "block/name" ]

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

let unlock_graph_key
      ~crypto
      ~password
      ~private_key_package:private_source
      ~encrypted_graph_key
  =
  bind (private_key_package private_source) (fun package ->
    bind (binary encrypted_graph_key) (fun encrypted_graph_key ->
      bind
        (crypto.decrypt_private_key
           ~password
           ~iterations:600_000
           ~salt:package.salt
           ~iv:package.iv
           ~ciphertext:package.ciphertext)
        (fun private_key ->
           crypto.decrypt_graph_key ~private_key ~ciphertext:encrypted_graph_key)))
;;

let transform_attribute_value ~transform ~attribute value =
  if List.mem attribute protected_attributes
  then (
    match value with
    | Transit.String _ -> transform value
    | _ -> Error "protected sync attributes must contain strings")
  else Ok value
;;

let encrypt_value ~crypto ~graph_key value =
  let plaintext = Codec.to_string value in
  bind (crypto.encrypt_aes_gcm ~key:graph_key ~plaintext) (fun (iv, ciphertext) ->
    Ok (Codec.to_string (Transit.Array [ Transit.Binary iv; Transit.Binary ciphertext ])))
;;

let decrypt_value ~crypto ~graph_key source =
  match protect "decode protected value" (fun () -> Codec.of_string source) with
  | Error _ -> Ok (Transit.String source)
  | Ok (Transit.Array [ Transit.Binary iv; Transit.Binary ciphertext ]) ->
    bind (crypto.decrypt_aes_gcm ~key:graph_key ~iv ~ciphertext) (fun plaintext ->
      protect "decode decrypted value" (fun () -> Codec.of_string plaintext))
  | Ok plaintext -> Ok plaintext
;;
