open Yojson.Basic

external call_raw : string -> string = "logseq_journal_crypto_call"

let hex value =
  let buffer = Buffer.create (String.length value * 2) in
  String.iter
    (fun character ->
       Buffer.add_string buffer (Printf.sprintf "%02x" (Char.code character)))
    value;
  Buffer.contents buffer
;;

let unhex value =
  if String.length value mod 2 <> 0
  then Error "platform crypto returned invalid data"
  else (
    try
      let result = Bytes.create (String.length value / 2) in
      for index = 0 to Bytes.length result - 1 do
        Bytes.set
          result
          index
          (Char.chr (int_of_string ("0x" ^ String.sub value (index * 2) 2)))
      done;
      Ok (Bytes.unsafe_to_string result)
    with
    | _ -> Error "platform crypto returned invalid data")
;;

let invoke operation fields =
  try
    match
      call_raw (to_string (`Assoc (("operation", `String operation) :: fields)))
      |> from_string
    with
    | `Assoc fields ->
      (match List.assoc_opt "ok" fields with
       | Some (`Bool true) -> Ok fields
       | Some (`Bool false) ->
         (match List.assoc_opt "error" fields with
          | Some (`String error) -> Error error
          | _ -> Error "platform crypto operation failed")
       | _ -> Error "platform crypto operation failed")
    | _ -> Error "platform crypto returned invalid data"
  with
  | _ -> Error "platform crypto is unavailable"
;;

let bind result f =
  match result with
  | Ok value -> f value
  | Error _ as error -> error
;;

let binary_field name fields =
  match List.assoc_opt name fields with
  | Some (`String value) -> unhex value
  | _ -> Error "platform crypto response is incomplete"
;;

let identity_fields ~managed_sync_origin ~user_id =
  [ "origin", `String (Uri.to_string managed_sync_origin); "userId", `String user_id ]
;;

let graph_identity_fields ~managed_sync_origin ~user_id ~graph_id =
  identity_fields ~managed_sync_origin ~user_id
  @ [ "graphId", `String (Graph_types.Uuid.to_string graph_id) ]
;;

let has_private_key ~managed_sync_origin ~user_id =
  match invoke "hasPrivateKey" (identity_fields ~managed_sync_origin ~user_id) with
  | Ok fields ->
    (match List.assoc_opt "value" fields with
     | Some (`Bool value) -> value
     | _ -> false)
  | Error _ -> false
;;

let unlock_private_key ~managed_sync_origin ~user_id ~password ~private_key_package =
  bind (E2ee.private_key_package private_key_package) (fun package ->
    bind
      (invoke
         "unlockPrivateKey"
         (identity_fields ~managed_sync_origin ~user_id
          @ [ "password", `String password
            ; "iterations", `Int 600_000
            ; "salt", `String (hex package.salt)
            ; "iv", `String (hex package.iv)
            ; "ciphertext", `String (hex package.ciphertext)
            ]))
      (fun _ -> Ok ()))
;;

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

let crypto =
  { decrypt_private_key =
      (fun ~password:_ ~iterations:_ ~salt:_ ~iv:_ ~ciphertext:_ ->
        Error "password unlock is owned by the platform account shell")
  ; decrypt_graph_key =
      (fun ~private_key:_ ~ciphertext:_ ->
        Error "private keys never cross the platform crypto boundary")
  ; encrypt_aes_gcm =
      (fun ~key ~plaintext ->
        bind
          (invoke
             "encryptAES"
             [ "key", `String (hex key); "plaintext", `String (hex plaintext) ])
          (fun fields ->
             bind (binary_field "iv" fields) (fun iv ->
               bind (binary_field "ciphertext" fields) (fun ciphertext ->
                 Ok (iv, ciphertext)))))
  ; decrypt_aes_gcm =
      (fun ~key ~iv ~ciphertext ->
        bind
          (invoke
             "decryptAES"
             [ "key", `String (hex key)
             ; "iv", `String (hex iv)
             ; "ciphertext", `String (hex ciphertext)
             ])
          (binary_field "value"))
  }
;;

let unlock_graph_key ~managed_sync_origin ~user_id ~encrypted_graph_key =
  bind (E2ee.binary encrypted_graph_key) (fun encrypted_graph_key ->
    bind
      (invoke
         "unwrapGraphKeyForEngine"
         (identity_fields ~managed_sync_origin ~user_id
          @ [ "ciphertext", `String (hex encrypted_graph_key) ]))
      (fun fields ->
         bind (binary_field "value" fields) (fun key ->
           if String.length key = 32 then Ok key else Error "invalid graph key")))
;;

let string_field name fields =
  match List.assoc_opt name fields with
  | Some (`String value) -> Ok value
  | _ -> Error "platform crypto response is incomplete"
;;

type wrapped_key_load_failure =
  | Wrapped_graph_key_unavailable of string
  | Local_private_key_unavailable of string

let load_wrapped_graph_key ~managed_sync_origin ~user_id ~graph_id =
  match
    invoke
      "loadAndVerifyWrappedGraphKey"
      (graph_identity_fields ~managed_sync_origin ~user_id ~graph_id)
  with
  | Ok fields ->
    Result.map_error
      (fun diagnostic -> Wrapped_graph_key_unavailable diagnostic)
      (string_field "value" fields)
  | Error "localPrivateKeyUnavailable" ->
    Error (Local_private_key_unavailable "local private key is unavailable")
  | Error diagnostic -> Error (Wrapped_graph_key_unavailable diagnostic)
;;

let verify_and_save_wrapped_graph_key
      ~managed_sync_origin
      ~user_id
      ~graph_id
      ~encrypted_graph_key
  =
  bind
    (invoke
       "verifyAndSaveWrappedGraphKey"
       (graph_identity_fields ~managed_sync_origin ~user_id ~graph_id
        @ [ "encryptedGraphKey", `String encrypted_graph_key ]))
    (fun _ -> Ok ())
;;

let delete_wrapped_graph_key ~managed_sync_origin ~user_id ~graph_id =
  bind
    (invoke
       "deleteWrappedGraphKey"
       (graph_identity_fields ~managed_sync_origin ~user_id ~graph_id))
    (fun _ -> Ok ())
;;

let delete_account_secrets ~managed_sync_origin ~user_id =
  bind
    (invoke "deleteAccountSecrets" (identity_fields ~managed_sync_origin ~user_id))
    (fun _ -> Ok ())
;;
