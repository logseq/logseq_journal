external call_raw : string -> string = "logseq_journal_crypto_call"

let diagnostic_operation = Eio.Fiber.create_key ()

let with_diagnostic_operation id run =
  if Sys.getenv_opt "JOURNAL_UNLOCK_DIAGNOSTICS" = Some "1"
  then Eio.Fiber.with_binding diagnostic_operation id run
  else run ()
;;

let hex value =
  let digits = "0123456789abcdef" in
  String.init
    (String.length value * 2)
    (fun index ->
       let byte = Char.code value.[index / 2] in
       digits.[if index mod 2 = 0 then byte lsr 4 else byte land 15])
;;

let unhex value =
  let digit = function
    | '0' .. '9' as c -> Char.code c - Char.code '0'
    | 'a' .. 'f' as c -> Char.code c - Char.code 'a' + 10
    | 'A' .. 'F' as c -> Char.code c - Char.code 'A' + 10
    | _ -> invalid_arg "invalid hex digit"
  in
  if String.length value mod 2 <> 0
  then Error "platform crypto returned invalid data"
  else (
    try
      Ok
        (String.init
           (String.length value / 2)
           (fun index ->
              Char.chr ((digit value.[index * 2] lsl 4) lor digit value.[(index * 2) + 1])))
    with
    | Invalid_argument _ -> Error "platform crypto returned invalid data")
;;

type request =
  { operation : string
  ; diagnostic_operation : string option [@key "diagnosticOperation"] [@default None]
  ; origin : string [@default ""]
  ; user_id : string [@key "userId"] [@default ""]
  ; graph_id : string option [@key "graphId"] [@default None]
  ; password : string option [@default None]
  ; iterations : int option [@default None]
  ; salt : string option [@default None]
  ; iv : string option [@default None]
  ; ciphertext : string option [@default None]
  ; encrypted_graph_key : string option [@key "encryptedGraphKey"] [@default None]
  }
[@@deriving yojson]

type response =
  { ok : bool
  ; error : string option [@default None]
  ; reason : string option [@default None]
  ; cleanup_pending : bool option [@key "cleanupPending"] [@default None]
  ; value : string option [@default None]
  ; wrapped_keys_deleted : bool option [@key "wrappedKeysDeleted"] [@default None]
  ; private_key_deleted : bool option [@key "privateKeyDeleted"] [@default None]
  ; encrypted_graph_key : string option [@key "encryptedGraphKey"] [@default None]
  ; ciphertext : string option [@default None]
  }
[@@deriving yojson]

let crypto_error_codes =
  [ "cryptoInvalidRequest"; "cryptoAuthenticationFailed"; "cryptoInvalidPrivateKey"
  ; "cryptoRSADecryptionFailed"; "cryptoInvalidGraphKeyLength"; "cryptoKeyStoreLocked"
  ; "cryptoKeyStorePermissionDenied"; "cryptoKeyStoreUnavailable"; "cryptoKeyStoreDecodeFailed"
  ; "cryptoKeyStoreFailed"; "cryptoKeyStoreInvalidType"; "cryptoOperationFailed"; "wrappedGraphKeyUnavailable"
  ; "cryptoInvalidAESInput"; "cryptoEnginePrivateKeyUnavailable"; "cryptoAllocationFailed"
  ; "cryptoNativeUnavailable"; "cryptoNativeResponseUnavailable"
  ; "platform crypto unavailable" ]
;;

let diagnostic_message ~reason:reason_name source =
  Logseq_db_types.Failure_diagnostic.(
    of_source ~operation:"platformCrypto" ~reason:reason_name source |> message)
;;

let response_context fields =
  let reason = match fields.reason with
    | Some ("wrapped-key-absent" | "wrapped-key-cache-invalid" as reason) -> Some reason
    | Some value when List.exists (fun code ->
        value = "wrapped-key-verification-failed:" ^ code) crypto_error_codes -> Some value
    | _ -> None in
  let context = Option.fold ~none:"" ~some:(fun value -> " Context: " ^ value ^ ".") reason in
  context ^ if fields.cleanup_pending = Some true then " Wrapped-key cleanup remains pending." else ""
;;

type invocation_failure = { recovery_code : string option; diagnostic : string }

let failure ?recovery_code diagnostic = Error { recovery_code; diagnostic }

let invoke_response request =
  try
    let request = { request with diagnostic_operation =
      (if Sys.getenv_opt "JOURNAL_UNLOCK_DIAGNOSTICS" = Some "1"
       then Eio.Fiber.get diagnostic_operation else None) } in
    let source = call_raw (request_to_yojson request |> Yojson.Safe.to_string) in
    let decoded = try Ok (Yojson.Safe.from_string source) with
      | Yojson.Json_error _ -> failure (diagnostic_message ~reason:"parseFailed"
          "platform crypto response JSON is invalid") in
    Result.bind decoded (fun json ->
      match Logseq_db_types.Json_codec.decode response_of_yojson json with
      | Ok { ok = true; _ } as result -> result
      (* This exact error selects the existing local-key recovery branch. *)
      | Ok ({ ok = false; error = Some "localPrivateKeyUnavailable"; _ } as fields) ->
        failure ~recovery_code:"localPrivateKeyUnavailable"
          ("local private key is unavailable" ^ response_context fields)
      | Ok ({ ok = false; error = Some error; _ } as fields) ->
        let source = if List.mem error crypto_error_codes then error
          else "platform crypto provider failed" in
        let reason = if List.mem error ["platform crypto unavailable"; "cryptoNativeUnavailable";
          "cryptoNativeResponseUnavailable"] then "unavailable" else "cryptoInvalid" in
        failure (diagnostic_message ~reason source ^ response_context fields)
      | Ok _ -> failure (diagnostic_message ~reason:"cryptoInvalid"
          "platform crypto response error is missing")
      | Error _ -> failure (diagnostic_message ~reason:"parseFailed"
          "platform crypto response shape is invalid"))
  with
  | error -> failure (diagnostic_message ~reason:"unavailable" (Printexc.to_string error))
;;

let invoke request =
  invoke_response request |> Result.map_error (fun failure ->
    Option.value failure.recovery_code ~default:failure.diagnostic)
;;

let bind result f =
  match result with
  | Ok value -> f value
  | Error _ as error -> error
;;

let binary_field response =
  match response.value with
  | Some value -> unhex value
  | None -> Error "platform crypto response is incomplete"
;;

let identity_request operation ~managed_sync_origin ~user_id =
  { operation
  ; diagnostic_operation = None
  ; origin = Uri.to_string managed_sync_origin
  ; user_id
  ; graph_id = None
  ; password = None
  ; iterations = None
  ; salt = None
  ; iv = None
  ; ciphertext = None
  ; encrypted_graph_key = None
  }
;;

let graph_identity_request operation ~managed_sync_origin ~user_id ~graph_id =
  { (identity_request operation ~managed_sync_origin ~user_id) with
    graph_id = Some (Graph_types.Uuid.to_string graph_id)
  }
;;

let unlock_private_key ~managed_sync_origin ~user_id ~password ~private_key_package =
  bind (E2ee.private_key_package private_key_package) (fun package ->
    bind
      (invoke
         { (identity_request "unlockPrivateKey" ~managed_sync_origin ~user_id) with
           password = Some password
         ; iterations = Some 600_000
         ; salt = Some (hex package.salt)
         ; iv = Some (hex package.iv)
         ; ciphertext = Some (hex package.ciphertext)
         })
      (fun _ -> Ok ()))
;;

type crypto =
  { encrypt_aes_gcm : key:string -> plaintext:string -> (string * string, string) result
  ; decrypt_aes_gcm :
      key:string -> iv:string -> ciphertext:string -> (string, string) result
  }

external call_binary
  :  bool
  -> string
  -> string
  -> string
  -> (string, string) result
  = "logseq_journal_crypto_binary_call"

let crypto =
  { encrypt_aes_gcm =
      (fun ~key ~plaintext ->
        Result.map
          (fun bytes ->
             String.sub bytes 0 12, String.sub bytes 12 (String.length bytes - 12))
          (call_binary true key "" plaintext))
  ; decrypt_aes_gcm = (fun ~key ~iv ~ciphertext -> call_binary false key iv ciphertext)
  }
;;

let unlock_graph_key ~managed_sync_origin ~user_id ~encrypted_graph_key =
  bind (E2ee.binary encrypted_graph_key) (fun encrypted_graph_key ->
    bind
      (invoke
         { (identity_request "unwrapGraphKeyForEngine" ~managed_sync_origin ~user_id) with
           ciphertext = Some (hex encrypted_graph_key)
         })
      (fun fields ->
         bind (binary_field fields) (fun key ->
           if String.length key = 32 then Ok key else Error "invalid graph key")))
;;

let string_field response =
  match response.value with
  | Some value -> Ok value
  | None -> Error "platform crypto response is incomplete"
;;

type wrapped_key_load_failure =
  | Wrapped_graph_key_unavailable of string
  | Local_private_key_unavailable of string

let load_wrapped_graph_key ~managed_sync_origin ~user_id ~graph_id =
  match
    invoke_response
      (graph_identity_request
         "loadAndVerifyWrappedGraphKey"
         ~managed_sync_origin
         ~user_id
         ~graph_id)
  with
  | Ok fields ->
    Result.map_error
      (fun diagnostic -> Wrapped_graph_key_unavailable diagnostic)
      (string_field fields)
  | Error { recovery_code = Some "localPrivateKeyUnavailable"; diagnostic } ->
    Error (Local_private_key_unavailable diagnostic)
  | Error failure -> Error (Wrapped_graph_key_unavailable failure.diagnostic)
;;

let verify_and_save_wrapped_graph_key
      ~managed_sync_origin
      ~user_id
      ~graph_id
      ~encrypted_graph_key
  =
  bind
    (invoke
       { (graph_identity_request
            "verifyAndSaveWrappedGraphKey"
            ~managed_sync_origin
            ~user_id
            ~graph_id)
         with
         encrypted_graph_key = Some encrypted_graph_key
       })
    (fun _ -> Ok ())
;;

let delete_account_secrets ~managed_sync_origin ~user_id =
  let result = bind
    (invoke (identity_request "deleteAccountSecrets" ~managed_sync_origin ~user_id))
    (fun _ -> Ok ()) in
  (match result with
   | Ok () -> ()
   | Error diagnostic ->
     (* [invoke] has already reduced native data to a bounded safe message.
        Secondary account cleanup retains its original completion strategy. *)
     (try Printf.eprintf
       "journal: phase=cleanup operation=deleteAccountSecrets code=cleanupPending detail=%s\n%!"
       diagnostic with _ -> ()));
  result
;;
