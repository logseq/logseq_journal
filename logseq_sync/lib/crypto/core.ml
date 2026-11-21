module Dsl = Sync_dsl.Core
module Native = Logseq_sync_native_crypto.Platform_crypto

type backend =
  { crypto : Native.crypto
  ; unlock :
      identity:Dsl.identity -> wrapped_graph_key:string -> (string, Dsl.error) result
  }

let apple_backend =
  { crypto = Native.crypto
  ; unlock =
      (fun ~identity ~wrapped_graph_key ->
        Native.unlock_graph_key
          ~managed_sync_origin:(Uri.of_string identity.Dsl.origin)
          ~user_id:identity.account
          ~encrypted_graph_key:wrapped_graph_key
        |> Result.map_error (fun message -> Dsl.Crypto_failure message))
  }
;;

type t =
  { identity : Dsl.identity
  ; limits : Dsl.limits
  ; encrypted : bool
  ; backend : backend
  ; mutable key : bytes option
  ; mutable retired : bool
  ; lock : Eio.Mutex.t
  }

let create ~identity ~limits ~encrypted ~backend =
  { identity
  ; limits
  ; encrypted
  ; backend
  ; key = None
  ; retired = false
  ; lock = Eio.Mutex.create ()
  }
;;

let status t =
  if t.retired || (t.encrypted && Option.is_none t.key)
  then Dsl.Key_locked
  else if t.encrypted
  then Dsl.Key_available
  else Dsl.Unencrypted
;;

let retire t =
  t.retired <- true;
  Option.iter (fun key -> Bytes.fill key 0 (Bytes.length key) '\000') t.key;
  t.key <- None
;;

let ( let* ) = Result.bind

let asset_key t ~check_current ~identity =
  let current () =
    let* () = check_current () in
    if t.retired
    then Error Dsl.Stale_context
    else if identity <> t.identity
    then Error (Dsl.Identity_mismatch "Crypto owner")
    else Ok ()
  in
  let* () = current () in
  Eio.Mutex.use_rw ~protect:false t.lock (fun () ->
    let* () = current () in
    match t.encrypted, t.key with
    | false, _ -> Ok None
    | true, None -> Error Dsl.Locked
    | true, Some key -> Ok (Some (Bytes.to_string key)))
;;

let run (type a) t ~check_current ~identity (operation : a Dsl.crypto)
  : (a, Dsl.error) result
  =
  let current () =
    let* () = check_current () in
    if t.retired
    then Error Dsl.Stale_context
    else if identity <> t.identity
    then Error (Dsl.Identity_mismatch "Crypto owner")
    else Ok ()
  in
  let* () = current () in
  Eio.Mutex.use_rw ~protect:false t.lock (fun () : (a, Dsl.error) result ->
    let* () = current () in
    let* () =
      match operation with
      | Dsl.Unlock _ -> Ok ()
      | Dsl.Encrypt_values _ | Dsl.Decrypt_value _ | Dsl.Protect _ | Dsl.Unprotect _ ->
        if t.encrypted && Option.is_none t.key then Error Dsl.Locked else Ok ()
    in
    let bounded_lengths values =
      if List.length values > t.limits.maximum_items
      then Error (Dsl.Capacity_exceeded "Crypto items")
      else
        List.fold_left
          (fun total value ->
             let* total = total in
             if value > t.limits.maximum_bytes - total
             then Error (Dsl.Capacity_exceeded "Crypto bytes")
             else Ok (total + value))
          (Ok 0)
          values
        |> Result.map (fun _ -> ())
    in
    let bounded values = bounded_lengths (List.map String.length values) in
    let native callback =
      let* () = current () in
      let result = callback () in
      let* () = current () in
      Result.map_error (fun message -> Dsl.Crypto_failure message) result
    in
    let graph_key () =
      match t.key with
      | Some key -> Ok (Bytes.to_string key)
      | None -> Error Dsl.Locked
    in
    let decrypt source =
      let* () = bounded [ source ] in
      let* value =
        if t.encrypted
        then
          let* key = graph_key () in
          native (fun () ->
            Logseq_sync_native_crypto.E2ee.decrypt_value
              ~crypto:{ decrypt_aes_gcm = t.backend.crypto.decrypt_aes_gcm }
              ~graph_key:key
              source)
        else (
          try Ok (Transit_native.Transit.Json.of_string source) with
          | Transit_core.Json.Decode_error _
          | Yojson.Json_error _
          | Failure _
          | Invalid_argument _ -> Ok (Transit_core.Json.String source))
      in
      match value with
      | Transit_core.Json.String plaintext ->
        let* () = bounded [ plaintext ] in
        Ok plaintext
      | _ -> Error (Dsl.Crypto_failure "Protected value must be a string")
    in
    let encrypt plaintext =
      let* key = graph_key () in
      let* iv, ciphertext =
        native (fun () -> t.backend.crypto.encrypt_aes_gcm ~key ~plaintext)
      in
      if
        String.length iv <> 12 || String.length ciphertext <> String.length plaintext + 16
      then Error (Dsl.Crypto_failure "Invalid AES-GCM output")
      else Ok (iv, ciphertext)
    in
    let rec traverse callback acc = function
      | [] -> Ok (List.rev acc)
      | value :: rest ->
        let* value = callback value in
        traverse callback (value :: acc) rest
    in
    let perform : type value. value Dsl.crypto -> (value, Dsl.error) result = function
      | Dsl.Unlock input ->
        if not t.encrypted
        then Ok Dsl.Unencrypted
        else (
          let result =
            t.backend.unlock ~identity ~wrapped_graph_key:(Dsl.wrapped_graph_key input)
          in
          let* key =
            match result with
            | Ok key -> Ok key
            | Error error ->
              let* () = current () in
              Error error
          in
          let bytes = Bytes.of_string key in
          let installed = ref false in
          Fun.protect
            ~finally:(fun () ->
              if not !installed then Bytes.fill bytes 0 (Bytes.length bytes) '\000')
            (fun () ->
               let* () = current () in
               if Bytes.length bytes <> 32
               then Error (Dsl.Crypto_failure "Invalid graph key length")
               else (
                 Option.iter
                   (fun previous -> Bytes.fill previous 0 (Bytes.length previous) '\000')
                   t.key;
                 t.key <- Some bytes;
                 installed := true;
                 Ok Dsl.Key_available)))
      | Dsl.Encrypt_values values ->
        if not t.encrypted
        then Error (Dsl.Crypto_failure "Encryption requires a graph key")
        else (
          let values = Rrbvec.to_list values in
          let* () = bounded values in
          let* values = traverse encrypt [] values in
          let* () =
            bounded_lengths
              (List.map
                 (fun (iv, ciphertext) -> String.length iv + String.length ciphertext)
                 values)
          in
          Ok (Rrbvec.of_list values))
      | Dsl.Decrypt_value source -> decrypt source
      | Dsl.Protect request ->
        let items = Logseq_overlay_db.Database.protection_plaintexts request in
        let* () = bounded (List.map snd items) in
        if not t.encrypted
        then
          traverse
            (fun (id, source) ->
               let* plaintext = decrypt source in
               Ok (id, plaintext))
            []
            items
        else
          let* encrypted =
            traverse
              (fun (id, plaintext) ->
                 let* iv, ciphertext = encrypt plaintext in
                 let wire =
                   Transit_native.Transit.Json.to_string
                     (Transit_core.Json.Array [ Binary iv; Binary ciphertext ])
                 in
                 Ok (id, wire))
              []
              items
          in
          let* () = bounded (List.map snd encrypted) in
          Ok encrypted
      | Dsl.Unprotect request ->
        let items = Logseq_overlay_db.Database.unprotection_ciphertexts request in
        let* () = bounded (List.map snd items) in
        let* plaintexts =
          traverse
            (fun (id, source) ->
               let* plaintext = decrypt source in
               Ok (id, plaintext))
            []
            items
        in
        let* () = bounded (List.map snd plaintexts) in
        Ok plaintexts
    in
    perform operation)
;;

let dispatch t ~scope ~identity operation =
  run t ~check_current:(fun () -> Execute.Core.check_current scope) ~identity operation
;;
