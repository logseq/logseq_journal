module Core = Logseq_sync_pure_reducer.Core
module Runner = Logseq_sync_effect_runner.Effect_runner

let fail format = Printf.ksprintf (fun message -> Alcotest.fail message) format

let remove_tree path =
  let rec loop path =
    match Unix.lstat path with
    | { st_kind = Unix.S_DIR; _ } ->
      Sys.readdir path |> Array.iter (fun name -> loop (Filename.concat path name));
      Unix.rmdir path
    | _ -> Unix.unlink path
    | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
  in
  loop path
;;

let with_support f =
  let path = Filename.temp_file "logseq-sync-runner-" "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  Fun.protect ~finally:(fun () -> remove_tree path) (fun () -> f path)
;;

let secrets () =
  Runner.secrets
    ~has_private_key:(fun ~managed_sync_origin:_ ~user_id:_ -> false)
    ~unlock_private_key:
      (fun
        ~managed_sync_origin:_ ~user_id:_ ~password:_ ~private_key_package:_ ->
      Error "private key unavailable")
    ~unlock_graph_key:(fun ~managed_sync_origin:_ ~user_id:_ ~encrypted_graph_key:_ ->
      Error "graph key unavailable")
    ~load_wrapped_graph_key:(fun ~managed_sync_origin:_ ~user_id:_ ~graph_id:_ ->
      Error (Runner.Wrapped_graph_key_unavailable "wrapped graph key unavailable"))
    ~verify_and_save_wrapped_graph_key:
      (fun
        ~managed_sync_origin:_ ~user_id:_ ~graph_id:_ ~encrypted_graph_key:_ ->
      Error "wrapped graph key store unavailable")
    ~delete_wrapped_graph_key:(fun ~managed_sync_origin:_ ~user_id:_ ~graph_id:_ -> Ok ())
    ~delete_account_secrets:(fun ~managed_sync_origin:_ ~user_id:_ -> Ok ())
  |> Result.get_ok
;;

let crypto () =
  Runner.crypto
    ~decrypt_private_key:(fun ~password:_ ~iterations:_ ~salt:_ ~iv:_ ~ciphertext:_ ->
      Error "private key decryption unavailable")
    ~decrypt_graph_key:(fun ~private_key:_ ~ciphertext:_ ->
      Error "graph key decryption unavailable")
    ~encrypt_aes_gcm:(fun ~key:_ ~plaintext:_ -> Error "encryption unavailable")
    ~decrypt_aes_gcm:(fun ~key:_ ~iv:_ ~ciphertext:_ -> Error "decryption unavailable")
  |> Result.get_ok
;;

let core () =
  let limits =
    Core.limits
      ~maximum_response_bytes:Logseq_db_types.Limits.maximum_response_bytes
      ~maximum_artifact_bytes:(1024 * 1024 * 1024)
      ~submission_batch_size:32
    |> Result.get_ok
  in
  Core.config ~managed_sync_origin:(Uri.of_string "https://api.logseq.io") ~limits
  |> Result.get_ok
  |> Core.initial
  |> Result.get_ok
;;

let load_catalog_effect () =
  Core.step (core ()) (Restore_local_account { user_id = "user-1" })
  |> fun transition ->
  List.find_map
    (function
      | Core.Run (Core.Request (_, Core.Load_catalog _) as instruction) ->
        Some instruction
      | Run _ | Delegate _ | Publish _ -> None)
    transition.effects
  |> Option.get
;;

let dependencies ?secrets_dependency ?crypto_dependency ~environment ~support ~fork () =
  let runtime =
    Runner.runtime ~fork ~sleep:(fun _ -> ()) ~monotonic_ns:(fun () -> 0L)
    |> Result.get_ok
  in
  let transport =
    Runner.transport
      ~tls_authenticator:(Runner.system_tls_authenticator () |> Result.get_ok)
      ~network:(Eio.Stdenv.net environment)
      ~clock:(Eio.Stdenv.clock environment)
    |> Result.get_ok
  in
  let local_store =
    Runner.local_store ~application_support_directory:support |> Result.get_ok
  in
  let artifact_store =
    Runner.artifact_store ~staging_directory:(Filename.concat support "staging")
    |> Result.get_ok
  in
  Runner.dependencies
    ~runtime
    ~transport
    ~local_store
    ~artifact_store
    ~secrets:(Option.value secrets_dependency ~default:(secrets ()))
    ~crypto:(Option.value crypto_dependency ~default:(crypto ()))
  |> Result.get_ok
;;

let graph_id () =
  Logseq_db_types.Graph_types.Uuid.of_string "11111111-1111-4111-8111-111111111111"
  |> Result.get_ok
;;

let encrypted_graph () : Core.graph =
  { graph_id = graph_id ()
  ; name = "Encrypted Journal"
  ; schema = { major = 1; minor = 0; exact = true }
  ; encrypted = true
  }
;;

let test_catalog_load_uses_account_and_origin_scoped_path () =
  with_support (fun support ->
    let worker_root = Filename.concat support "logseq-db-worker" in
    let catalog_root = Filename.concat worker_root "sync-catalogs" in
    Unix.mkdir worker_root 0o700;
    Unix.mkdir catalog_root 0o700;
    let cache =
      Core.catalog_cache
        ~user_id:"user-1"
        ~graphs:[ encrypted_graph () ]
        ~selected_graph:None
    in
    let path =
      Filename.concat
        catalog_root
        "748ac0b0c274b30bc6fc1da756958deab4ebdef06a2d6373a377e2b4d8cec6df.json"
    in
    let channel = open_out_bin path in
    Fun.protect
      ~finally:(fun () -> close_out_noerr channel)
      (fun () -> output_string channel (Core.encode_catalog_cache cache));
    Eio_main.run (fun environment ->
      Eio.Switch.run (fun sw ->
        let tasks = ref [] in
        let posted = ref [] in
        let dependencies =
          dependencies
            ~environment
            ~support
            ~fork:(fun ~sw:_ task -> tasks := task :: !tasks)
            ()
        in
        let runner =
          Runner.create ~sw dependencies ~post:(fun event -> posted := event :: !posted)
          |> Result.get_ok
        in
        let restoring =
          Core.step (core ()) (Restore_local_account { user_id = "user-1" })
        in
        Runner.submit runner (load_catalog_effect ());
        List.iter (fun task -> task ()) (List.rev !tasks);
        let restored =
          match !posted with
          | [ event ] -> Core.step restoring.next event
          | _ -> fail "catalog load did not post exactly one completion"
        in
        Alcotest.(check int)
          "scoped catalog is restored"
          1
          (List.length (Core.state restored.next).snapshot.catalog))))
;;

let token_request effects =
  List.find_map
    (function
      | Core.Publish (Core.Token_requested request) -> Some request
      | Run _ | Delegate _ | Publish _ -> None)
    effects
  |> function
  | Some request -> request
  | None -> fail "transition did not publish a token request"
;;

let cached_key_effect () =
  let authenticated =
    Core.step (core ()) (Account_authenticated { user_id = Some "user-1" })
  in
  let catalog_token = token_request authenticated.effects in
  let authorized =
    Core.step authenticated.next (Token_provided (catalog_token, "catalog-token"))
  in
  let graph = encrypted_graph () in
  let catalog =
    List.find_map
      (function
        | Core.Run (Core.Request (ticket, Core.Fetch_catalog _)) ->
          Some
            (Core.step
               authorized.next
               (Runner_completed (Completion (ticket, Ok [ graph ]))))
        | Run _ | Delegate _ | Publish _ -> None)
      authorized.effects
    |> function
    | Some transition -> transition
    | None -> fail "transition did not fetch the graph catalog"
  in
  let selected = Core.step catalog.next (Graph_selected graph.graph_id) in
  let scope =
    List.find_map
      (function
        | Core.Delegate (Core.Inspect_mirror request) -> Some request.scope
        | Run _ | Delegate _ | Publish _ -> None)
      selected.effects
    |> function
    | Some scope -> scope
    | None -> fail "encrypted graph selection did not inspect its mirror"
  in
  let missing = Core.step selected.next (Mirror_inspected (Mirror_absent scope)) in
  let instruction =
    List.find_map
      (function
        | Core.Run (Core.Request (_, Core.Load_and_unlock_graph_key _) as instruction) ->
          Some instruction
        | Run _ | Delegate _ | Publish _ -> None)
      missing.effects
    |> function
    | Some instruction -> instruction
    | None -> fail "encrypted graph bootstrap did not request its cached graph key"
  in
  missing, instruction
;;

let test_dependency_constructors_validate_owned_resources () =
  with_support (fun support ->
    let missing = Filename.concat support "missing" in
    Alcotest.check
      Alcotest.bool
      "missing application support directory is rejected"
      true
      (Result.is_error (Runner.local_store ~application_support_directory:missing)))
;;

let test_submit_is_async_and_posts_a_typed_completion () =
  with_support (fun support ->
    Eio_main.run (fun environment ->
      Eio.Switch.run (fun sw ->
        let tasks = ref [] in
        let posted = ref [] in
        let dependencies =
          dependencies
            ~environment
            ~support
            ~fork:(fun ~sw:_ task -> tasks := task :: !tasks)
            ()
        in
        let runner =
          Runner.create ~sw dependencies ~post:(fun event -> posted := event :: !posted)
        in
        let runner = Result.get_ok runner in
        Runner.submit runner (load_catalog_effect ());
        Alcotest.(check int) "submit does not synchronously post" 0 (List.length !posted);
        List.iter (fun task -> task ()) (List.rev !tasks);
        Alcotest.(check int) "one completion is posted" 1 (List.length !posted);
        match !posted with
        | [ Core.Runner_completed _ ] -> ()
        | _ -> Alcotest.fail "load catalog did not post its typed completion")))
;;

let test_cancellation_suppresses_late_completion () =
  with_support (fun support ->
    Eio_main.run (fun environment ->
      Eio.Switch.run (fun sw ->
        let tasks = ref [] in
        let posted = ref [] in
        let dependencies =
          dependencies
            ~environment
            ~support
            ~fork:(fun ~sw:_ task -> tasks := task :: !tasks)
            ()
        in
        let runner =
          Runner.create ~sw dependencies ~post:(fun event -> posted := event :: !posted)
          |> Result.get_ok
        in
        let instruction = load_catalog_effect () in
        Runner.submit runner instruction;
        Runner.submit runner (Core.Cancel_effects (Core.runner_effect_scope instruction));
        List.iter (fun task -> task ()) (List.rev !tasks);
        Alcotest.(check int)
          "cancelled work posts no late completion"
          0
          (List.length !posted);
        Runner.shutdown runner;
        Runner.shutdown runner;
        Runner.submit runner instruction;
        Alcotest.(check int) "shutdown rejects new work" 0 (List.length !posted))))
;;

let test_cached_wrapped_key_is_unlocked_before_protected_value_decryption () =
  with_support (fun support ->
    Eio_main.run (fun environment ->
      Eio.Switch.run (fun sw ->
        let wrapped_key = "cached-wrapped-graph-key" in
        let raw_key = String.make 32 'k' in
        let unlock_inputs = ref [] in
        let tasks = ref [] in
        let posted = ref [] in
        let secrets_dependency =
          Runner.secrets
            ~has_private_key:(fun ~managed_sync_origin:_ ~user_id:_ -> true)
            ~unlock_private_key:
              (fun
                ~managed_sync_origin:_ ~user_id:_ ~password:_ ~private_key_package:_ ->
              Error "private key unlock was not expected")
            ~unlock_graph_key:
              (fun
                ~managed_sync_origin:_ ~user_id:_ ~encrypted_graph_key ->
              unlock_inputs := encrypted_graph_key :: !unlock_inputs;
              if String.equal encrypted_graph_key wrapped_key
              then Ok raw_key
              else Error "unexpected wrapped graph key")
            ~load_wrapped_graph_key:(fun ~managed_sync_origin:_ ~user_id:_ ~graph_id:_ ->
              Ok wrapped_key)
            ~verify_and_save_wrapped_graph_key:
              (fun
                ~managed_sync_origin:_ ~user_id:_ ~graph_id:_ ~encrypted_graph_key:_ ->
              Error "wrapped graph key save was not expected")
            ~delete_wrapped_graph_key:
              (fun
                ~managed_sync_origin:_ ~user_id:_ ~graph_id:_ -> Ok ())
            ~delete_account_secrets:(fun ~managed_sync_origin:_ ~user_id:_ -> Ok ())
          |> Result.get_ok
        in
        let crypto_dependency =
          Runner.crypto
            ~decrypt_private_key:
              (fun
                ~password:_ ~iterations:_ ~salt:_ ~iv:_ ~ciphertext:_ ->
              Error "private key decryption was not expected")
            ~decrypt_graph_key:(fun ~private_key:_ ~ciphertext:_ ->
              Error "graph key decryption was not expected")
            ~encrypt_aes_gcm:(fun ~key:_ ~plaintext:_ ->
              Error "encryption was not expected")
            ~decrypt_aes_gcm:(fun ~key ~iv:_ ~ciphertext:_ ->
              if String.equal key raw_key
              then
                Ok
                  (Transit_native.Transit.Json.to_string
                     (Transit_core.Json.String "plaintext"))
              else Error "protected value received a wrapped graph key")
          |> Result.get_ok
        in
        let dependencies =
          dependencies
            ~secrets_dependency
            ~crypto_dependency
            ~environment
            ~support
            ~fork:(fun ~sw:_ task -> tasks := task :: !tasks)
            ()
        in
        let runner =
          Runner.create ~sw dependencies ~post:(fun event -> posted := event :: !posted)
          |> Result.get_ok
        in
        let _, instruction = cached_key_effect () in
        let handle =
          match instruction with
          | Core.Request (ticket, Core.Load_and_unlock_graph_key scope) ->
            Core.graph_key_handle
              ~id:("graph-key-" ^ Core.effect_id_to_string (Core.effect_ticket_id ticket))
              ~scope
          | Request _
          | Start_websocket _
          | Send_websocket _
          | Close_websocket _
          | Schedule_timer _
          | Cancel_effects _ -> fail "cached key effect had an unexpected request type"
        in
        Runner.submit runner instruction;
        List.iter (fun task -> task ()) (List.rev !tasks);
        Alcotest.(check (list string))
          "cached wrapped key is explicitly unlocked"
          [ wrapped_key ]
          (List.rev !unlock_inputs);
        Alcotest.(check int) "cached key request completes once" 1 (List.length !posted);
        let ciphertext =
          Transit_native.Transit.Json.to_string
            (Transit_core.Json.Array
               [ Transit_core.Json.Binary "123456789012"
               ; Transit_core.Json.Binary "ciphertext-and-tag"
               ])
        in
        Alcotest.(check (result string string))
          "returned handle decrypts with the raw graph key"
          (Ok "plaintext")
          (Runner.decrypt_protected_value runner handle ciphertext))))
;;

let test_cached_wrapped_key_unlock_failure_is_fail_closed () =
  with_support (fun support ->
    Eio_main.run (fun environment ->
      Eio.Switch.run (fun sw ->
        let tasks = ref [] in
        let posted = ref [] in
        let secrets_dependency =
          Runner.secrets
            ~has_private_key:(fun ~managed_sync_origin:_ ~user_id:_ -> true)
            ~unlock_private_key:
              (fun
                ~managed_sync_origin:_ ~user_id:_ ~password:_ ~private_key_package:_ ->
              Error "private key unlock was not expected")
            ~unlock_graph_key:
              (fun
                ~managed_sync_origin:_ ~user_id:_ ~encrypted_graph_key:_ ->
              Error "cached graph key could not be unlocked")
            ~load_wrapped_graph_key:(fun ~managed_sync_origin:_ ~user_id:_ ~graph_id:_ ->
              Ok "invalid-wrapped-key")
            ~verify_and_save_wrapped_graph_key:
              (fun
                ~managed_sync_origin:_ ~user_id:_ ~graph_id:_ ~encrypted_graph_key:_ ->
              Error "wrapped graph key save was not expected")
            ~delete_wrapped_graph_key:
              (fun
                ~managed_sync_origin:_ ~user_id:_ ~graph_id:_ -> Ok ())
            ~delete_account_secrets:(fun ~managed_sync_origin:_ ~user_id:_ -> Ok ())
          |> Result.get_ok
        in
        let dependencies =
          dependencies
            ~secrets_dependency
            ~environment
            ~support
            ~fork:(fun ~sw:_ task -> tasks := task :: !tasks)
            ()
        in
        let runner =
          Runner.create ~sw dependencies ~post:(fun event -> posted := event :: !posted)
          |> Result.get_ok
        in
        let before, instruction = cached_key_effect () in
        let handle =
          match instruction with
          | Core.Request (ticket, Core.Load_and_unlock_graph_key scope) ->
            Core.graph_key_handle
              ~id:("graph-key-" ^ Core.effect_id_to_string (Core.effect_ticket_id ticket))
              ~scope
          | Request _
          | Start_websocket _
          | Send_websocket _
          | Close_websocket _
          | Schedule_timer _
          | Cancel_effects _ -> fail "cached key effect had an unexpected request type"
        in
        Runner.submit runner instruction;
        List.iter (fun task -> task ()) (List.rev !tasks);
        let failed =
          match !posted with
          | [ event ] -> Core.step before.next event
          | _ -> fail "cached key failure did not post exactly one completion"
        in
        Alcotest.check
          Alcotest.bool
          "unlock failure waits for explicit E2EE recovery"
          true
          ((Core.state failed.next).snapshot.startup.failure
           = Some Core.During_local_restore
           && not
                (List.exists
                   (function
                     | Core.Publish (Core.Token_requested _) -> true
                     | Run _ | Delegate _ | Publish _ -> false)
                   failed.effects));
        let recovery = Core.step failed.next Core.Online_recovery_requested in
        Alcotest.check
          Alcotest.bool
          "explicit recovery requests E2EE authorization"
          true
          (Core.token_request_purpose (token_request recovery.effects)
           = Core.E2ee_key_access);
        Alcotest.(check (result string string))
          "failed cached key is not stored as a usable handle"
          (Error "graph key handle is unavailable or out of scope")
          (Runner.decrypt_protected_value runner handle "plaintext"))))
;;

let scenarios =
  [ Alcotest.test_case
      "dependency constructors validate resources"
      `Quick
      test_dependency_constructors_validate_owned_resources
  ; Alcotest.test_case
      "catalog load uses account and origin scoped path"
      `Quick
      test_catalog_load_uses_account_and_origin_scoped_path
  ; Alcotest.test_case
      "submit posts asynchronously"
      `Quick
      test_submit_is_async_and_posts_a_typed_completion
  ; Alcotest.test_case
      "cancellation suppresses late completion"
      `Quick
      test_cancellation_suppresses_late_completion
  ; Alcotest.test_case
      "cached wrapped key is unlocked before AES"
      `Quick
      test_cached_wrapped_key_is_unlocked_before_protected_value_decryption
  ; Alcotest.test_case
      "cached wrapped key unlock failure is fail-closed"
      `Quick
      test_cached_wrapped_key_unlock_failure_is_fail_closed
  ]
;;
