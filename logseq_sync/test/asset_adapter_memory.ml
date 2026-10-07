(* Exercise the public runner with its production Apple adapter and synthetic keys. *)
module R = Logseq_sync_effect_runner.Effect_runner
module C = Logseq_sync_pure_reducer.Core
module A = Logseq_db_types.Asset_descriptor
module Codec = Logseq_sync_effect_runner.Asset_codec

let get = Result.get_ok
let uuid = Logseq_db_types.Graph_types.Uuid.of_string
let graph_id = get (uuid "11111111-1111-4111-8111-111111111111")

let key_request () =
  let limits =
    get
      (C.limits
         ~maximum_response_bytes:Logseq_db_types.Limits.maximum_response_bytes
         ~maximum_artifact_bytes:1073741824
         ~submission_batch_size:32)
  in
  let config =
    get
      (C.config ~managed_sync_origin:(Uri.of_string "https://asset-test.invalid") ~limits)
  in
  let authenticated =
    C.step (get (C.initial config)) (C.Account_authenticated { user_id = Some "fixture" })
  in
  let graph : C.graph =
    { graph_id
    ; name = "Fixture"
    ; encrypted = true
    ; schema = { major = 1; minor = 0; exact = true }
    }
  in
  let catalog =
    List.find_map
      (function
        | C.Run (C.Request (ticket, C.Fetch_catalog _)) ->
          Some
            (C.step
               authenticated.next
               (C.Runner_completed (C.Completion (ticket, Ok [ graph ]))))
        | _ -> None)
      authenticated.effects
    |> Option.get
  in
  let selected = C.step catalog.next (C.Graph_selected graph_id) in
  let scope =
    List.find_map
      (function
        | C.Delegate (C.Inspect_mirror request) -> Some request.scope
        | _ -> None)
      selected.effects
    |> Option.get
  in
  let missing = C.step selected.next (C.Mirror_inspected (C.Mirror_absent scope)) in
  let instruction =
    List.find_map
      (function
        | C.Run (C.Request (_, C.Load_and_unlock_graph_key _) as runnable) ->
          Some runnable
        | _ -> None)
      missing.effects
    |> Option.get
  in
  missing.next, instruction
;;

let () =
  let support = Sys.argv.(1) in
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      let key = String.init 32 Char.chr in
      let secrets =
        get
          (R.secrets
             ~unlock_private_key:
               (fun
                 ~managed_sync_origin:_ ~user_id:_ ~password:_ ~private_key_package:_ ->
               Error "unused")
             ~unlock_graph_key:
               (fun
                 ~managed_sync_origin:_ ~user_id:_ ~encrypted_graph_key:_ -> Ok key)
             ~load_wrapped_graph_key:(fun ~managed_sync_origin:_ ~user_id:_ ~graph_id:_ ->
               Ok "synthetic")
             ~verify_and_save_wrapped_graph_key:
               (fun
                 ~managed_sync_origin:_ ~user_id:_ ~graph_id:_ ~encrypted_graph_key:_ ->
               Error "unused")
             ~delete_account_secrets:(fun ~managed_sync_origin:_ ~user_id:_ -> Ok ()))
      in
      let auth_calls = ref 0 in
      let dependencies =
        get
          (R.dependencies
             ~runtime:(get (R.runtime ~fork:(fun ~sw:_ f -> f ()) ~sleep:(fun _ -> ())))
             ~transport:
               (get
                  (R.transport
                     ~tls_authenticator:(get (R.system_tls_authenticator ()))
                     ~network:(Eio.Stdenv.net env)
                     ~clock:(Eio.Stdenv.clock env)
                     ~websocket_liveness:R.Disabled))
             ~local_store:(get (R.local_store ~application_support_directory:support ()))
             ~artifact_store:
               (get
                  (R.artifact_store
                     ~staging_directory:(Filename.concat support "staging")))
             ~secrets
             ~crypto:(get (R.apple_crypto ()))
             ~id_token_provider:
               (R.id_token_provider
                  ~acquire:(fun _ ->
                    incr auth_calls;
                    Error "fixture stops before network")
                  ~invalidate:(fun _ ~token:_ -> ())))
      in
      let posted = ref [] in
      let runner =
        get (R.create ~sw dependencies ~post:(fun e -> posted := e :: !posted))
      in
      let before_key, instruction = key_request () in
      R.submit runner instruction;
      let unlocked =
        match !posted with
        | [ event ] -> (C.step before_key event).next
        | _ -> failwith "expected one key completion"
      in
      let context = C.asset_context unlocked |> Option.get in
      let handle = context.key |> Option.get in
      let owner = ref unlocked in
      let protected operation action =
        posted := [];
        let requested =
          C.step
            !owner
            (C.Protected_requested
               { protected_operation = operation
               ; protected_scope = context.scope
               ; protected_action = action
               })
        in
        List.iter
          (function
            | C.Run runnable -> R.submit runner runnable
            | _ -> ())
          requested.effects;
        let completed = C.step requested.next (List.hd !posted) in
        owner := completed.next;
        List.find_map
          (function
            | C.Publish (C.Protected_finished output) -> Some output.protected_result
            | _ -> None)
          completed.effects
        |> Option.get
        |> get
      in
      List.iter
        (fun size ->
           let value = String.init size (fun i -> Char.chr (i mod 128)) in
           let plaintext =
             Transit_native.Transit.Json.to_string (Transit_core.Json.String value)
           in
           let iv, ciphertext =
             match
               protected
                 ("encrypt-" ^ string_of_int size)
                 (C.Encrypt_values (handle, [ plaintext ]))
             with
             | C.Encrypted_values [ pair ] -> pair
             | _ -> failwith "missing encrypted value"
           in
           let wire =
             Transit_native.Transit.Json.to_string
               (Transit_core.Json.Array [ Binary iv; Binary ciphertext ])
           in
           if
             protected ("decrypt-" ^ string_of_int size) (C.Decrypt_value (handle, wire))
             <> C.Decrypted_value value
           then failwith "production adapter roundtrip changed bytes")
        [ 0; 1; 256; 4097; 131057 ];
      let size = 8 * 1024 * 1024 in
      let plaintext = String.init size (fun i -> Char.chr (i mod 256)) in
      let source_file = Filename.concat support "source.bin" in
      Out_channel.with_open_bin source_file (fun out -> output_string out plaintext);
      let version =
        get (A.version ~checksum:(Codec.checksum plaintext) ~file_type:"bin")
      in
      Gc.full_major ();
      let staged =
        C.step
          !owner
          (C.Asset_requested
             { scope = context.scope
             ; operation = "stage"
             ; action =
                 C.Stage_asset_file
                   { operation = graph_id; file_type = "bin"; source_file }
             })
      in
      posted := [];
      List.iter
        (function
          | C.Run runnable -> R.submit runner runnable
          | _ -> ())
        staged.effects;
      let staged_done = C.step staged.next (List.hd !posted) in
      let file =
        List.find_map
          (function
            | C.Publish (C.Asset_finished { result = Ok (C.Asset_staged { file; _ }); _ })
              -> Some file
            | _ -> None)
          staged_done.effects
        |> Option.get
      in
      let before = Gc.allocated_bytes () in
      let upload =
        C.step
          staged_done.next
          (C.Asset_requested
             { scope = context.scope
             ; operation = "upload"
             ; action =
                 C.Put_asset_file
                   { asset = graph_id; version; file; maximum_plaintext_bytes = size }
             })
      in
      posted := [];
      List.iter
        (function
          | C.Run runnable -> R.submit runner runnable
          | _ -> ())
        upload.effects;
      let finished = C.step upload.next (List.hd !posted) in
      let outcome =
        List.find_map
          (function
            | C.Publish (C.Asset_finished output) -> Some output.result
            | _ -> None)
          finished.effects
        |> Option.get
      in
      let allocated = Gc.allocated_bytes () -. before in
      if outcome <> Error C.Asset_authentication || !auth_calls <> 1
      then failwith "production adapter did not encode the maximum-size asset";
      Printf.printf "Production upload OCaml allocation bytes: %.0f\n%!" allocated;
      if allocated > 128. *. 1024. *. 1024.
      then failwith "asset adapter allocation exceeds 128 MiB"))
;;
