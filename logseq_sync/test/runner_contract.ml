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
    ~delete_account_secrets:(fun ~managed_sync_origin:_ ~user_id:_ -> Ok ())
  |> Result.get_ok
;;

let crypto () =
  Runner.crypto
    ~encrypt_aes_gcm:(fun ~key:_ ~plaintext:_ -> Error "encryption unavailable")
    ~decrypt_aes_gcm:(fun ~key:_ ~iv:_ ~ciphertext:_ -> Error "decryption unavailable")
  |> Result.get_ok
;;

let core ?(origin = Uri.of_string "https://api.logseq.io") () =
  let limits =
    Core.limits
      ~maximum_response_bytes:Logseq_db_types.Limits.maximum_response_bytes
      ~maximum_artifact_bytes:(1024 * 1024 * 1024)
      ~submission_batch_size:32
    |> Result.get_ok
  in
  Core.config ~managed_sync_origin:origin ~limits
  |> Result.get_ok
  |> Core.initial
  |> Result.get_ok
;;

let load_catalog_transition () =
  Core.step (core ()) (Restore_local_account { user_id = "user-1" })
;;

let cancellation_effect () =
  let restoring = load_catalog_transition () in
  let cancelled = Core.step restoring.next Core.Shutdown in
  List.find_map
    (function
      | Core.Run (Core.Cancel_effects _ as runnable) -> Some runnable
      | _ -> None)
    cancelled.effects
  |> Option.get
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

let dependencies
      ?secrets_dependency
      ?crypto_dependency
      ?id_token_dependency
      ~environment
      ~support
      ~fork
      ()
  =
  let runtime = Runner.runtime ~fork ~sleep:(fun _ -> ()) |> Result.get_ok in
  let transport =
    Runner.transport
      ~websocket_liveness:Runner.Disabled
      ~tls_authenticator:(Runner.system_tls_authenticator () |> Result.get_ok)
      ~network:(Eio.Stdenv.net environment)
      ~clock:(Eio.Stdenv.clock environment)
    |> Result.get_ok
  in
  let local_store =
    Runner.local_store ~application_support_directory:support () |> Result.get_ok
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
    ~id_token_provider:
      (Option.value
         id_token_dependency
         ~default:
           (Runner.id_token_provider
              ~acquire:(fun _ -> Ok "test-id-token")
              ~invalidate:(fun _ ~token:_ -> ())))
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

(* The runner owns whether a queued callback starts. A pure Core completion
   cannot reproduce a cancelled callback writing to the filesystem. *)
let test_cancelled_queued_catalog_save_does_not_write () =
  with_support (fun support ->
    Eio_main.run (fun environment ->
      Eio.Switch.run (fun sw ->
        let tasks = ref [] in
        let posted = ref [] in
        let deps =
          dependencies
            ~environment
            ~support
            ~fork:(fun ~sw:_ task -> tasks := task :: !tasks)
            ()
        in
        let runner =
          Runner.create ~sw deps ~post:(fun event -> posted := event :: !posted)
          |> Result.get_ok
        in
        let authenticated =
          Core.step (core ()) (Account_authenticated { user_id = Some "user-1" })
        in
        let catalog =
          List.find_map
            (function
              | Core.Run (Core.Request (ticket, Core.Fetch_catalog _)) ->
                Some
                  (Core.step
                     authenticated.next
                     (Runner_completed (Completion (ticket, Ok [ encrypted_graph () ]))))
              | _ -> None)
            authenticated.effects
          |> Option.get
        in
        let selected = Core.step catalog.next (Graph_selected (graph_id ())) in
        let save =
          List.find_map
            (function
              | Core.Run (Core.Request (_, Core.Save_catalog _) as instruction) ->
                Some instruction
              | _ -> None)
            selected.effects
          |> Option.get
        in
        Runner.submit runner save;
        Runner.submit runner (cancellation_effect ());
        List.iter (fun task -> task ()) (List.rev !tasks);
        Alcotest.(check bool)
          "cancelled save has no durable side effects"
          false
          (Sys.file_exists (Filename.concat support "logseq-db-worker"));
        Alcotest.(check int) "cancelled save posts no completion" 0 (List.length !posted))))
;;

let cached_key_effect ?origin () =
  let authenticated =
    Core.step (core ?origin ()) (Account_authenticated { user_id = Some "user-1" })
  in
  let graph = encrypted_graph () in
  let catalog =
    List.find_map
      (function
        | Core.Run (Core.Request (ticket, Core.Fetch_catalog _)) ->
          Some
            (Core.step
               authenticated.next
               (Runner_completed (Completion (ticket, Ok [ graph ]))))
        | Run _ | Delegate _ | Publish _ -> None)
      authenticated.effects
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
      (Result.is_error (Runner.local_store ~application_support_directory:missing ())))
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
        Runner.submit runner (cancellation_effect ());
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

let protected_run runner ~tasks ~posted core operation scope action =
  tasks := [];
  posted := [];
  let transition =
    Core.step
      core
      (Core.Protected_requested
         { protected_operation = operation
         ; protected_scope = scope
         ; protected_action = action
         })
  in
  List.iter
    (function
      | Core.Run runnable -> Runner.submit runner runnable
      | _ -> ())
    transition.effects;
  let queued = List.rev !tasks in
  tasks := [];
  List.iter (fun task -> task ()) queued;
  let finished =
    List.fold_left (fun core event -> (Core.step core event).next) transition.next !posted
  in
  let outputs =
    List.concat_map
      (fun event ->
         let completed = Core.step transition.next event in
         List.filter_map
           (function
             | Core.Publish (Core.Protected_finished output) ->
               Some output.protected_result
             | _ -> None)
           completed.effects)
      !posted
  in
  ignore finished;
  match outputs with
  | [ result ] -> result
  | _ -> fail "protected request did not resolve through Core output"
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
            ~delete_account_secrets:(fun ~managed_sync_origin:_ ~user_id:_ -> Ok ())
          |> Result.get_ok
        in
        let crypto_dependency =
          Runner.crypto
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
        let before, instruction = cached_key_effect () in
        let handle =
          match instruction with
          | Core.Request (ticket, Core.Load_and_unlock_graph_key scope) ->
            Core.graph_key_handle
              ~id:("graph-key-" ^ Core.effect_id_to_string (Core.effect_ticket_id ticket))
              ~scope
          | Asset_io _
          | Protected_io _
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
        let unlocked =
          match !posted with
          | [ event ] -> (Core.step before.next event).next
          | _ -> fail "missing key completion"
        in
        Alcotest.(check bool)
          "returned handle decrypts with the raw graph key"
          true
          (protected_run
             runner
             ~tasks
             ~posted
             unlocked
             "decrypt-cached"
             (Core.graph_key_handle_scope handle)
             (Core.Decrypt_value (handle, ciphertext))
           = Ok (Core.Decrypted_value "plaintext")))))
;;

let test_cached_wrapped_key_unlock_failure_is_fail_closed () =
  with_support (fun support ->
    Eio_main.run (fun environment ->
      Eio.Switch.run (fun sw ->
        let tasks = ref [] in
        let posted = ref [] in
        let secrets_dependency =
          Runner.secrets
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
          | Asset_io _
          | Protected_io _
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
           && failed.effects
              = [ Core.Publish (Core.State_changed (Core.state failed.next)) ]);
        let recovery = Core.step failed.next Core.Online_recovery_requested in
        Alcotest.check
          Alcotest.bool
          "explicit recovery requests E2EE authorization"
          true
          (List.exists
             (function
               | Core.Run (Core.Request (_, Core.Fetch_e2ee_graph_key _)) -> true
               | Run _ | Delegate _ | Publish _ -> false)
             recovery.effects);
        Alcotest.(check bool)
          "failed cached key is not stored as a usable handle"
          true
          (match
             protected_run
               runner
               ~tasks
               ~posted
               failed.next
               "decrypt-failed"
               (Core.graph_key_handle_scope handle)
               (Core.Decrypt_value (handle, "plaintext"))
           with
           | Error (Core.Effect_failed _) -> true
           | _ -> false))))
;;

let account_deletion_effect () =
  let authenticated =
    Core.step (core ()) (Account_authenticated { user_id = Some "account-user" })
  in
  let signed_out =
    Core.step authenticated.next (Account_authenticated { user_id = None })
  in
  List.find_map
    (function
      | Core.Run (Core.Request (_, Core.Delete_account_secrets _) as runnable) ->
        Some runnable
      | Run _ | Delegate _ | Publish _ -> None)
    signed_out.effects
  |> Option.get
;;

let test_account_deletion_callback_receives_exact_identity_once () =
  with_support (fun support ->
    Eio_main.run (fun environment ->
      Eio.Switch.run (fun sw ->
        let tasks = ref [] in
        let posted = ref [] in
        let accounts = ref [] in
        let secrets_dependency =
          Runner.secrets
            ~unlock_private_key:
              (fun
                ~managed_sync_origin:_ ~user_id:_ ~password:_ ~private_key_package:_ ->
              Error "unexpected private-key unlock")
            ~unlock_graph_key:
              (fun
                ~managed_sync_origin:_ ~user_id:_ ~encrypted_graph_key:_ ->
              Error "unexpected graph-key unlock")
            ~load_wrapped_graph_key:(fun ~managed_sync_origin:_ ~user_id:_ ~graph_id:_ ->
              Error (Runner.Wrapped_graph_key_unavailable "unexpected wrapped-key load"))
            ~verify_and_save_wrapped_graph_key:
              (fun
                ~managed_sync_origin:_ ~user_id:_ ~graph_id:_ ~encrypted_graph_key:_ ->
              Error "unexpected wrapped-key save")
            ~delete_account_secrets:(fun ~managed_sync_origin ~user_id ->
              accounts := (Uri.to_string managed_sync_origin, user_id) :: !accounts;
              Ok ())
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
        Runner.submit runner (account_deletion_effect ());
        List.iter (fun task -> task ()) (List.rev !tasks);
        Alcotest.(check (list (pair string string)))
          "account callback receives the captured identity once"
          [ "https://api.logseq.io", "account-user" ]
          (List.rev !accounts);
        Alcotest.(check int) "account deletion completes" 1 (List.length !posted))))
;;

let test_account_deletion_callback_failures_are_typed () =
  with_support (fun support ->
    Eio_main.run (fun environment ->
      Eio.Switch.run (fun sw ->
        let tasks = ref [] in
        let posted = ref [] in
        let secrets_dependency =
          Runner.secrets
            ~unlock_private_key:
              (fun
                ~managed_sync_origin:_ ~user_id:_ ~password:_ ~private_key_package:_ ->
              Error "unexpected private-key unlock")
            ~unlock_graph_key:
              (fun
                ~managed_sync_origin:_ ~user_id:_ ~encrypted_graph_key:_ ->
              Error "unexpected graph-key unlock")
            ~load_wrapped_graph_key:(fun ~managed_sync_origin:_ ~user_id:_ ~graph_id:_ ->
              Error (Runner.Wrapped_graph_key_unavailable "unexpected wrapped-key load"))
            ~verify_and_save_wrapped_graph_key:
              (fun
                ~managed_sync_origin:_ ~user_id:_ ~graph_id:_ ~encrypted_graph_key:_ ->
              Error "unexpected wrapped-key save")
            ~delete_account_secrets:(fun ~managed_sync_origin:_ ~user_id:_ ->
              Error "account-delete")
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
        Runner.submit runner (account_deletion_effect ());
        List.iter (fun task -> task ()) (List.rev !tasks);
        let failures =
          List.rev !posted
          |> List.map (function
            | Core.Runner_completed
                (Core.Completion (_, Error (Core.Effect_failed message))) -> message
            | _ -> fail "deletion callback did not map its error to Effect_failed")
        in
        Alcotest.(check (list string))
          "callback errors remain typed"
          [ "account-delete" ]
          failures)))
;;

let private_key_unlock_and_sign_out () =
  let authenticated =
    Core.step (core ()) (Account_authenticated { user_id = Some "serialized-user" })
  in
  let catalog =
    List.find_map
      (function
        | Core.Run (Core.Request (ticket, Core.Fetch_catalog _)) ->
          Some
            (Core.step
               authenticated.next
               (Runner_completed (Completion (ticket, Ok [ encrypted_graph () ]))))
        | Run _ | Delegate _ | Publish _ -> None)
      authenticated.effects
    |> Option.get
  in
  let selected = Core.step catalog.next (Graph_selected (graph_id ())) in
  let scope = Core.admitted_graph_scope selected.next |> Option.get in
  let missing = Core.step selected.next (Mirror_inspected (Mirror_absent scope)) in
  let failed =
    List.find_map
      (function
        | Core.Run (Core.Request (ticket, Core.Load_and_unlock_graph_key _)) ->
          Some
            (Core.step
               missing.next
               (Runner_completed
                  (Completion (ticket, Error (Core.Effect_failed "missing key")))))
        | Run _ | Delegate _ | Publish _ -> None)
      missing.effects
    |> Option.get
  in
  let recovery = Core.step failed.next Online_recovery_requested in
  let user_key_fetch =
    List.find_map
      (function
        | Core.Run (Core.Request (ticket, Core.Fetch_e2ee_graph_key _)) ->
          Some
            (Core.step
               recovery.next
               (Runner_completed (Completion (ticket, Ok "encrypted-graph-key"))))
        | Run _ | Delegate _ | Publish _ -> None)
      recovery.effects
    |> Option.get
  in
  let password_prompt =
    List.find_map
      (function
        | Core.Run (Core.Request (ticket, Core.Fetch_e2ee_user_keys _)) ->
          Some
            (Core.step
               user_key_fetch.next
               (Runner_completed (Completion (ticket, Ok "private-key-package"))))
        | Run _ | Delegate _ | Publish _ -> None)
      user_key_fetch.effects
    |> Option.get
  in
  let unlocking = Core.step password_prompt.next (E2ee_password_submitted "password") in
  let unlock =
    List.find_map
      (function
        | Core.Run (Core.Request (_, Core.Unlock_private_key _) as runnable) ->
          Some runnable
        | Run _ | Delegate _ | Publish _ -> None)
      unlocking.effects
    |> Option.get
  in
  let signed_out = Core.step unlocking.next (Account_authenticated { user_id = None }) in
  unlock, signed_out.effects
;;

let test_secret_cleanup_is_serialized_after_an_older_write () =
  with_support (fun support ->
    Eio_main.run (fun environment ->
      Eio.Switch.run (fun sw ->
        let write_started, resolve_write_started = Eio.Promise.create () in
        let release_write, resolve_release_write = Eio.Promise.create () in
        let deletion_finished, resolve_deletion_finished = Eio.Promise.create () in
        let order = ref [] in
        let secrets_dependency =
          Runner.secrets
            ~unlock_private_key:
              (fun
                ~managed_sync_origin:_ ~user_id:_ ~password:_ ~private_key_package:_ ->
              Eio.Cancel.protect (fun () ->
                order := "write-started" :: !order;
                Eio.Promise.resolve resolve_write_started ();
                Eio.Promise.await release_write;
                order := "write-finished" :: !order;
                Ok ()))
            ~unlock_graph_key:
              (fun
                ~managed_sync_origin:_ ~user_id:_ ~encrypted_graph_key:_ ->
              Error "unexpected graph-key unlock")
            ~load_wrapped_graph_key:(fun ~managed_sync_origin:_ ~user_id:_ ~graph_id:_ ->
              Error (Runner.Wrapped_graph_key_unavailable "unexpected wrapped-key load"))
            ~verify_and_save_wrapped_graph_key:
              (fun
                ~managed_sync_origin:_ ~user_id:_ ~graph_id:_ ~encrypted_graph_key:_ ->
              Error "unexpected wrapped-key save")
            ~delete_account_secrets:(fun ~managed_sync_origin:_ ~user_id:_ ->
              order := "delete-account" :: !order;
              Eio.Promise.resolve resolve_deletion_finished ();
              Ok ())
          |> Result.get_ok
        in
        let dependencies =
          dependencies
            ~secrets_dependency
            ~environment
            ~support
            ~fork:(fun ~sw task -> Eio.Fiber.fork ~sw task)
            ()
        in
        let runner =
          Runner.create ~sw dependencies ~post:(fun _ -> ()) |> Result.get_ok
        in
        let unlock, sign_out_effects = private_key_unlock_and_sign_out () in
        Runner.submit runner unlock;
        Eio.Promise.await write_started;
        List.iter
          (function
            | Core.Run runner_effect -> Runner.submit runner runner_effect
            | Delegate _ | Publish _ -> ())
          sign_out_effects;
        Eio.Fiber.yield ();
        Alcotest.(check bool)
          "delete waits while the older write is open"
          false
          (List.mem "delete-account" !order);
        Eio.Promise.resolve resolve_release_write ();
        Eio.Promise.await deletion_finished;
        Alcotest.(check (list string))
          "older write finishes before deletion"
          [ "write-started"; "write-finished"; "delete-account" ]
          (List.rev !order))))
;;

let source_contents relative alternatives =
  let candidates = relative :: alternatives in
  match List.find_opt Sys.file_exists candidates with
  | None -> fail "unable to locate source file %s" relative
  | Some filename ->
    let channel = open_in_bin filename in
    Fun.protect
      ~finally:(fun () -> close_in_noerr channel)
      (fun () -> really_input_string channel (in_channel_length channel))
;;

let contains text needle =
  let rec loop offset =
    if offset + String.length needle > String.length text
    then false
    else if String.sub text offset (String.length needle) = needle
    then true
    else loop (offset + 1)
  in
  String.length needle = 0 || loop 0
;;

let test_runner_source_has_no_placeholder_capabilities () =
  let source =
    source_contents
      "logseq_sync/lib/effect_runner/effect_runner.ml"
      [ "../lib/effect_runner/effect_runner.ml" ]
  in
  List.iter
    (fun forbidden ->
       if contains source forbidden
       then fail "runner retains placeholder capability %s" forbidden)
    [ "monotonic_ns"
    ; "has_private_key"
    ; "decrypt_private_key"
    ; "decrypt_graph_key"
    ; "ignore secrets.delete_account_secrets"
    ]
;;

let scenarios =
  [ Alcotest.test_case
      "cancelled queued catalog save never writes"
      `Quick
      test_cancelled_queued_catalog_save_does_not_write
  ; Alcotest.test_case
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
  ; Alcotest.test_case
      "account deletion callback receives exact identity once"
      `Quick
      test_account_deletion_callback_receives_exact_identity_once
  ; Alcotest.test_case
      "account deletion callback failures are typed"
      `Quick
      test_account_deletion_callback_failures_are_typed
  ; Alcotest.test_case
      "secret cleanup is serialized after older writes"
      `Quick
      test_secret_cleanup_is_serialized_after_an_older_write
  ; Alcotest.test_case
      "runner source has no placeholder capabilities"
      `Quick
      test_runner_source_has_no_placeholder_capabilities
  ]
;;

(* These assertions execute staging/lease filesystem ownership, which pure Core
   cannot reproduce; policy acceptance itself is covered by Core_contract. *)
let test_asset_local_lifecycle_uses_completion_outputs () =
  with_support (fun support ->
    Eio_main.run (fun environment ->
      Eio.Switch.run (fun sw ->
        let tasks = ref []
        and posted = ref [] in
        let deps =
          dependencies
            ~environment
            ~support
            ~fork:(fun ~sw:_ task -> tasks := task :: !tasks)
            ()
        in
        let runner =
          Runner.create ~sw deps ~post:(fun event -> posted := event :: !posted)
          |> Result.get_ok
        in
        let selected, scope = Core_contract.selected_graph Core_contract.graph in
        let core = ref selected.next in
        let rec pump outputs =
          match !tasks, !posted with
          | [], [] -> List.rev outputs
          | task :: rest, _ ->
            tasks := rest;
            task ();
            pump outputs
          | [], event :: rest ->
            posted := rest;
            let transition = Core.step !core event in
            core := transition.next;
            let outputs =
              List.fold_left
                (fun outputs -> function
                   | Core.Run runnable ->
                     Runner.submit runner runnable;
                     outputs
                   | Core.Publish (Core.Asset_finished output) -> output :: outputs
                   | _ -> outputs)
                outputs
                transition.effects
            in
            pump outputs
        in
        let request operation action =
          let transition =
            Core.step !core (Core.Asset_requested { scope; operation; action })
          in
          core := transition.next;
          List.iter
            (function
              | Core.Run runnable -> Runner.submit runner runnable
              | _ -> ())
            transition.effects;
          match pump [] with
          | [ output ] -> output.Core.result
          | _ -> fail "local asset action did not resolve through Core"
        in
        let source_file = Filename.concat support "import-source.bin" in
        Out_channel.with_open_bin source_file (fun out -> output_string out "local asset");
        let file, checksum =
          match
            request
              "stage"
              (Core.Stage_asset_file
                 { operation = graph_id (); file_type = "bin"; source_file })
          with
          | Ok (Core.Asset_staged { file; checksum; size }) ->
            Alcotest.(check int64) "staging returns metadata" 11L size;
            file, checksum
          | _ -> fail "staging did not complete"
        in
        let lease, path =
          match request "retain" (Core.Retain_staged_file file) with
          | Ok (Core.Asset_retained (Some (lease, path))) -> lease, path
          | _ -> fail "staging lease did not complete"
        in
        Alcotest.(check bool)
          "controlled lease resolves existing path"
          true
          (Sys.file_exists path);
        Alcotest.(check bool)
          "release lease completes"
          true
          (request "release-lease" (Core.Release_asset_file lease) = Ok Core.Asset_unit);
        Alcotest.(check bool)
          "release staging completes"
          true
          (request "release-stage" (Core.Release_staged_file file) = Ok Core.Asset_unit);
        Alcotest.(check bool) "released staging is removed" false (Sys.file_exists path);
        let version =
          Logseq_db_types.Asset_descriptor.version ~checksum ~file_type:"bin"
          |> Result.get_ok
        in
        Alcotest.(check bool)
          "cache miss passes through Core output"
          true
          (request "cache" (Core.Check_asset_cache (graph_id (), version))
           = Ok (Core.Asset_cached None));
        Alcotest.(check bool)
          "prune passes through Core output"
          true
          (match request "prune" (Core.Prune_asset_staging []) with
           | Ok (Core.Asset_pruned _) -> true
           | _ -> false);
        Alcotest.(check bool)
          "retry timer passes through Core output"
          true
          (request "timer" (Core.Asset_retry_after 0.25) = Ok Core.Asset_retry_elapsed);
        Alcotest.(check bool)
          "scope close completes"
          true
          (request "close" Core.Close_asset_scope = Ok Core.Asset_unit);
        Alcotest.(check bool)
          "graph deletion completes"
          true
          (request "delete-graph" Core.Delete_graph_assets = Ok Core.Asset_unit);
        Alcotest.(check bool)
          "account deletion completes"
          true
          (request "delete-account" Core.Delete_account_assets = Ok Core.Asset_unit);
        Runner.shutdown runner)))
;;

let scenarios =
  scenarios
  @ [ Alcotest.test_case
        "asset local IO resolves through Core outputs"
        `Quick
        test_asset_local_lifecycle_uses_completion_outputs
    ]
;;

(* Core cannot prevent a runner from executing the same submitted capability twice.
   Re-execution of Retain would mint an unaccepted lease and strand staging cleanup. *)
let test_asset_submit_replay_does_not_mint_a_second_lease () =
  with_support (fun support ->
    Eio_main.run (fun environment ->
      Eio.Switch.run (fun sw ->
        let tasks = ref []
        and posted = ref [] in
        let deps =
          dependencies
            ~environment
            ~support
            ~fork:(fun ~sw:_ task -> tasks := task :: !tasks)
            ()
        in
        let runner =
          Runner.create ~sw deps ~post:(fun event -> posted := event :: !posted)
          |> Result.get_ok
        in
        let selected, scope = Core_contract.selected_graph Core_contract.graph in
        let run_tasks () =
          while !tasks <> [] do
            let batch = List.rev !tasks in
            tasks := [];
            List.iter (fun task -> task ()) batch
          done
        in
        let complete transition =
          posted := [];
          List.iter
            (function
              | Core.Run runnable -> Runner.submit runner runnable
              | _ -> ())
            transition.Core.effects;
          run_tasks ();
          match List.rev !posted with
          | [ event ] -> Core.step transition.next event
          | _ -> fail "resource command did not post one completion"
        in
        let source_file = Filename.concat support "replay-source.bin" in
        Out_channel.with_open_bin source_file (fun out -> output_string out "replay");
        let stage =
          complete
            (Core.step
               selected.next
               (Core.Asset_requested
                  { scope
                  ; operation = "replay-stage"
                  ; action =
                      Core.Stage_asset_file
                        { operation = graph_id (); file_type = "bin"; source_file }
                  }))
        in
        let file =
          List.find_map
            (function
              | Core.Publish
                  (Core.Asset_finished { result = Ok (Core.Asset_staged { file; _ }); _ })
                -> Some file
              | _ -> None)
            stage.effects
          |> Option.get
        in
        let retaining =
          Core.step
            stage.next
            (Core.Asset_requested
               { scope
               ; operation = "replay-retain"
               ; action = Core.Retain_staged_file file
               })
        in
        let runnable =
          List.find_map
            (function
              | Core.Run (Core.Asset_io _ as runnable) -> Some runnable
              | _ -> None)
            retaining.effects
          |> Option.get
        in
        let retained = complete retaining in
        let lease, path =
          List.find_map
            (function
              | Core.Publish
                  (Core.Asset_finished
                     { result = Ok (Core.Asset_retained (Some retained)); _ }) ->
                Some retained
              | _ -> None)
            retained.effects
          |> Option.get
        in
        posted := [];
        Runner.submit runner runnable;
        run_tasks ();
        Alcotest.(check int)
          "accepted effect replay creates no new completion or lease"
          0
          (List.length !posted);
        let released =
          complete
            (Core.step
               retained.next
               (Core.Asset_requested
                  { scope
                  ; operation = "replay-release-lease"
                  ; action = Core.Release_asset_file lease
                  }))
        in
        ignore
          (complete
             (Core.step
                released.next
                (Core.Asset_requested
                   { scope
                   ; operation = "replay-release-stage"
                   ; action = Core.Release_staged_file file
                   })));
        Alcotest.(check bool)
          "original lease release permits final staging cleanup"
          false
          (Sys.file_exists path);
        Runner.shutdown runner)))
;;

let scenarios =
  scenarios
  @ [ Alcotest.test_case
        "asset submit replay cannot mint a second lease"
        `Quick
        test_asset_submit_replay_does_not_mint_a_second_lease
    ]
;;

let test_asset_cleanup_survives_shutdown_before_queued_fork () =
  with_support (fun support ->
    Eio_main.run (fun environment ->
      Eio.Switch.run (fun sw ->
        let tasks = ref []
        and posted = ref [] in
        let deps =
          dependencies
            ~environment
            ~support
            ~fork:(fun ~sw:_ task -> tasks := task :: !tasks)
            ()
        in
        let runner =
          Runner.create ~sw deps ~post:(fun event -> posted := event :: !posted)
          |> Result.get_ok
        in
        let selected, scope = Core_contract.selected_graph Core_contract.graph in
        let core = ref selected.next in
        let drain () =
          while !tasks <> [] do
            let batch = List.rev !tasks in
            tasks := [];
            List.iter (fun task -> task ()) batch
          done
        in
        let request operation action =
          posted := [];
          let transition =
            Core.step !core (Core.Asset_requested { scope; operation; action })
          in
          core := transition.next;
          List.iter
            (function
              | Core.Run runnable -> Runner.submit runner runnable
              | _ -> ())
            transition.effects;
          drain ();
          match List.rev !posted with
          | [ event ] ->
            let completed = Core.step !core event in
            core := completed.next;
            List.find_map
              (function
                | Core.Publish (Core.Asset_finished output) -> Some output.result
                | _ -> None)
              completed.effects
            |> Option.get
          | _ -> fail "cleanup fixture command did not complete"
        in
        let source_file = Filename.concat support "shutdown-source.bin" in
        Out_channel.with_open_bin source_file (fun out -> output_string out "shutdown");
        let file =
          match
            request
              "shutdown-stage"
              (Core.Stage_asset_file
                 { operation = graph_id (); file_type = "bin"; source_file })
          with
          | Ok (Core.Asset_staged { file; _ }) -> file
          | _ -> fail "shutdown fixture staging failed"
        in
        let lease, path =
          match request "shutdown-retain" (Core.Retain_staged_file file) with
          | Ok (Core.Asset_retained (Some retained)) -> retained
          | _ -> fail "shutdown fixture retention failed"
        in
        ignore (request "shutdown-release-lease" (Core.Release_asset_file lease));
        posted := [];
        let cleanup =
          Core.step
            !core
            (Core.Asset_requested
               { scope
               ; operation = "shutdown-release-stage"
               ; action = Core.Release_staged_file file
               })
        in
        List.iter
          (function
            | Core.Run runnable -> Runner.submit runner runnable
            | _ -> ())
          cleanup.effects;
        Runner.shutdown runner;
        drain ();
        Alcotest.(check bool)
          "submitted staging cleanup survives shutdown before queued tasks"
          false
          (Sys.file_exists path);
        let completed =
          match List.rev !posted with
          | [ event ] -> Core.step cleanup.next event
          | _ -> fail "submitted cleanup did not post exactly one completion"
        in
        Alcotest.(check bool)
          "cleanup completion reaches its reducer output"
          true
          (List.exists
             (function
               | Core.Publish (Core.Asset_finished output) ->
                 output.request.operation = "shutdown-release-stage"
                 && output.result = Ok Core.Asset_unit
               | _ -> false)
             completed.effects))))
;;

let scenarios =
  scenarios
  @ [ Alcotest.test_case
        "asset queued cleanup survives runner shutdown"
        `Quick
        test_asset_cleanup_survives_shutdown_before_queued_fork
    ]
;;

(* Migrated asset cache public runner scenarios. *)
let with_local_asset_cache ?(budget = 8L) ?(pending_budget = 8L) test =
  with_support (fun support ->
    Eio_main.run (fun environment ->
      Eio.Switch.run (fun sw ->
        let tasks = Queue.create ()
        and posted = Queue.create () in
        let deps =
          let transport =
            Runner.transport
              ~websocket_liveness:Runner.Disabled
              ~tls_authenticator:(Runner.system_tls_authenticator () |> Result.get_ok)
              ~network:(Eio.Stdenv.net environment)
              ~clock:(Eio.Stdenv.clock environment)
            |> Result.get_ok
          in
          Runner.dependencies
            ~runtime:
              (Runner.runtime
                 ~fork:(fun ~sw:_ task -> Queue.add task tasks)
                 ~sleep:(fun _ -> ())
               |> Result.get_ok)
            ~transport
            ~local_store:
              (Runner.local_store
                 ~asset_cache_budget_bytes:budget
                 ~asset_maximum_file_bytes:8
                 ~asset_pending_budget_bytes:pending_budget
                 ~application_support_directory:support
                 ()
               |> Result.get_ok)
            ~artifact_store:
              (Runner.artifact_store
                 ~staging_directory:(Filename.concat support "staging")
               |> Result.get_ok)
            ~secrets:(secrets ())
            ~crypto:(crypto ())
            ~id_token_provider:
              (Runner.id_token_provider
                 ~acquire:(fun _ -> Ok "token")
                 ~invalidate:(fun _ ~token:_ -> ()))
          |> Result.get_ok
        in
        let runner =
          Runner.create ~sw deps ~post:(fun event -> Queue.add event posted)
          |> Result.get_ok
        in
        Fun.protect
          ~finally:(fun () -> Runner.shutdown runner)
          (fun () ->
             let selected, scope = Core_contract.selected_graph Core_contract.graph in
             let state = ref selected.next
             and sequence = ref 0 in
             let rec consume outputs effects =
               List.fold_left
                 (fun outputs -> function
                    | Core.Run runner_effect ->
                      Runner.submit runner runner_effect;
                      outputs
                    | Core.Publish (Core.Asset_finished output) -> output :: outputs
                    | _ -> outputs)
                 outputs
                 effects
             and pump outputs =
               match Queue.take_opt tasks with
               | Some task ->
                 task ();
                 pump outputs
               | None ->
                 (match Queue.take_opt posted with
                  | None -> List.rev outputs
                  | Some event ->
                    let transition = Core.step !state event in
                    state := transition.next;
                    pump (consume outputs transition.effects))
             in
             let request action =
               incr sequence;
               let transition =
                 Core.step
                   !state
                   (Core.Asset_requested
                      { scope; operation = "cache-" ^ string_of_int !sequence; action })
               in
               state := transition.next;
               match pump (consume [] transition.effects) with
               | [ output ] -> output.Core.result
               | _ -> fail "cache operation did not resolve through reducer output"
             in
             test support request))))
;;

let staged_value = function
  | Ok (Core.Asset_staged { file; checksum; size }) -> file, checksum, size
  | _ -> fail "expected staged resource metadata"
;;

let retained_value = function
  | Ok (Core.Asset_retained (Some resource)) -> resource
  | _ -> fail "expected retained resource output"
;;

let cache_unit result =
  Alcotest.(check bool) "cleanup completed" true (result = Ok Core.Asset_unit)
;;

let cache_bool = Alcotest.check Alcotest.bool

let cache_stage
      request
      ?(operation = Core_contract.graph_id)
      ?(file_type = "bin")
      source_file
  =
  request (Core.Stage_asset_file { operation; file_type; source_file }) |> staged_value
;;

let test_cache_durable_staging () =
  with_local_asset_cache (fun support request ->
    let source = Filename.concat support "picker.bin" in
    Out_channel.with_open_bin source (fun output -> output_string output "source");
    let file, checksum, size = cache_stage request source in
    Alcotest.(check string)
      "staging checksum"
      (Logseq_sync_effect_runner.Asset_codec.checksum "source")
      checksum;
    Alcotest.(check int64) "staging size" 6L size;
    Sys.remove source;
    let lease, path = request (Core.Retain_staged_file file) |> retained_value in
    Alcotest.(check string)
      "picker is no longer needed"
      "source"
      (In_channel.with_open_bin path In_channel.input_all);
    cache_unit (request (Core.Release_asset_file lease));
    let interrupted = path ^ ".part" in
    Out_channel.with_open_bin interrupted (fun output -> output_string output "partial");
    cache_unit (request Core.Close_asset_scope);
    let lease, restored = request (Core.Retain_staged_file file) |> retained_value in
    cache_bool "restart preserves pending source" true (String.equal restored path);
    cache_bool "interrupted staging discarded" false (Sys.file_exists interrupted);
    cache_bool
      "path traversal rejected"
      true
      (request (Core.Retain_staged_file "../picker.bin") = Ok (Core.Asset_retained None));
    cache_unit (request (Core.Release_asset_file lease));
    cache_unit (request (Core.Release_staged_file file));
    cache_unit (request (Core.Release_staged_file file));
    cache_bool
      "completion releases pending source"
      true
      (request (Core.Retain_staged_file file) = Ok (Core.Asset_retained None)))
;;

let test_cache_staging_limits () =
  with_local_asset_cache ~pending_budget:4L (fun support request ->
    let source = Filename.concat support "picker.bin" in
    let write bytes =
      Out_channel.with_open_bin source (fun output -> output_string output bytes)
    in
    write "large-file";
    cache_bool
      "oversize staging rejected"
      true
      (Result.is_error
         (request
            (Core.Stage_asset_file
               { operation = Core_contract.graph_id
               ; file_type = "bin"
               ; source_file = source
               })));
    write "file";
    let file, _, _ = cache_stage request source in
    cache_bool
      "duplicate cannot overwrite immutable staging"
      true
      (Result.is_error
         (request
            (Core.Stage_asset_file
               { operation = Core_contract.graph_id
               ; file_type = "bin"
               ; source_file = source
               })));
    cache_bool
      "pending namespace has a separate budget"
      true
      (request
         (Core.Stage_asset_file
            { operation = Core_contract.other_graph_id
            ; file_type = "bin"
            ; source_file = source
            })
       = Error Core.Asset_storage_full);
    let lease, path = request (Core.Retain_staged_file file) |> retained_value in
    cache_bool "failed staging leaves original intact" true (Sys.file_exists path);
    cache_unit (request (Core.Release_asset_file lease));
    cache_unit (request Core.Delete_graph_assets);
    cache_bool "graph deletion removes staging" false (Sys.file_exists path))
;;

let test_cache_orphan_staging () =
  with_local_asset_cache ~pending_budget:16L (fun support request ->
    let source = Filename.concat support "picker.bin" in
    Out_channel.with_open_bin source (fun output -> output_string output "file");
    let retained, _, _ = cache_stage request source in
    let orphan, _, _ =
      cache_stage request ~operation:Core_contract.other_graph_id source
    in
    let first_lease, retained_path =
      request (Core.Retain_staged_file retained) |> retained_value
    in
    let second_lease, orphan_path =
      request (Core.Retain_staged_file orphan) |> retained_value
    in
    cache_unit (request (Core.Release_asset_file first_lease));
    cache_unit (request (Core.Release_asset_file second_lease));
    let directory = Filename.dirname orphan_path in
    let stranger = Filename.concat directory "unrecognized.txt" in
    Out_channel.with_open_bin stranger (fun output -> output_string output "preserve");
    let link = Filename.concat directory "00000000-0000-4000-8000-000000000003.bin" in
    Unix.symlink source link;
    Alcotest.(check bool)
      "only orphan removed"
      true
      (request (Core.Prune_asset_staging [ retained ]) = Ok (Core.Asset_pruned 1));
    cache_bool "durable staging retained" true (Sys.file_exists retained_path);
    cache_bool "orphan gone" false (Sys.file_exists orphan_path);
    cache_bool "unknown file retained" true (Sys.file_exists stranger);
    cache_bool
      "symlink not followed or removed"
      true
      ((Unix.lstat link).st_kind = Unix.S_LNK && Sys.file_exists source);
    cache_bool
      "repeat cleanup"
      true
      (request (Core.Prune_asset_staging [ retained ]) = Ok (Core.Asset_pruned 0));
    for index = 1 to 4096 do
      Out_channel.with_open_bin
        (Filename.concat directory ("unknown-" ^ string_of_int index))
        (fun _ -> ())
    done;
    cache_bool
      "oversized directory fails closed"
      true
      (request (Core.Prune_asset_staging []) = Error Core.Asset_storage_full);
    cache_bool
      "capacity failure preserves staged data"
      true
      (Sys.file_exists retained_path))
;;

let test_cache_staged_preview () =
  with_local_asset_cache (fun support request ->
    let source = Filename.concat support "picker.bin" in
    Out_channel.with_open_bin source (fun output -> output_string output "file");
    let file, _, _ = cache_stage request ~file_type:"pdf" source in
    let lease, path = request (Core.Retain_staged_file file) |> retained_value in
    cache_bool
      "native preview retains document extension"
      true
      (Filename.check_suffix path ".pdf");
    List.iter
      (fun file_type ->
         cache_bool
           "unsafe file types are rejected"
           true
           (Result.is_error
              (request
                 (Core.Stage_asset_file
                    { operation = Core_contract.graph_id
                    ; file_type
                    ; source_file = source
                    }))))
      [ ""; "../pdf"; "x.pdf"; String.make 33 'a' ];
    let second, _ = request (Core.Retain_asset_file lease) |> retained_value in
    cache_bool
      "orphan cleanup preserves active previews"
      true
      (request (Core.Prune_asset_staging []) = Ok (Core.Asset_pruned 0));
    cache_unit (request (Core.Release_staged_file file));
    cache_bool "completion keeps preview bytes" true (Sys.file_exists path);
    cache_bool
      "completed staging refuses new preview"
      true
      (request (Core.Retain_staged_file file) = Ok (Core.Asset_retained None));
    cache_unit (request (Core.Release_asset_file lease));
    cache_bool "one remaining lease keeps file" true (Sys.file_exists path);
    cache_unit (request (Core.Release_asset_file second));
    cache_bool "last lease finishes cleanup" false (Sys.file_exists path);
    cache_unit (request (Core.Release_asset_file second));
    cache_unit (request (Core.Release_staged_file file));
    let file, _, _ = cache_stage request ~file_type:"pdf" source in
    let lease, path = request (Core.Retain_staged_file file) |> retained_value in
    cache_unit (request (Core.Release_staged_file file));
    cache_unit (request Core.Close_asset_scope);
    cache_bool
      "close invalidates preview lease"
      true
      (request (Core.Retain_asset_file lease) = Ok (Core.Asset_retained None));
    cache_bool "close finishes deferred cleanup" false (Sys.file_exists path);
    let file, _, _ = cache_stage request ~file_type:"pdf" source in
    let _, path = request (Core.Retain_staged_file file) |> retained_value in
    cache_unit (request Core.Close_asset_scope);
    cache_bool "close preserves nonterminal staging" true (Sys.file_exists path))
;;

let scenarios =
  scenarios
  @ List.map
      (fun (name, test) -> Alcotest.test_case name `Quick test)
      [ "cache durable staging via submit", test_cache_durable_staging
      ; "cache staging limits via submit", test_cache_staging_limits
      ; "cache orphan staging via submit", test_cache_orphan_staging
      ; "cache staged preview lifetime via submit", test_cache_staged_preview
      ]
;;

(* The runner owns distinct physical staging instances; Core only fences the
   cancelled completion and asks to release that exact resource reference. *)
let test_late_stage_cleanup_cannot_delete_a_replacement () =
  with_support (fun support ->
    Eio_main.run (fun environment ->
      Eio.Switch.run (fun sw ->
        let tasks = ref []
        and posted = ref [] in
        let deps =
          dependencies
            ~environment
            ~support
            ~fork:(fun ~sw:_ task -> tasks := task :: !tasks)
            ()
        in
        let runner =
          Runner.create ~sw deps ~post:(fun event -> posted := event :: !posted)
          |> Result.get_ok
        in
        let selected, scope = Core_contract.selected_graph Core_contract.graph in
        let core = ref selected.next in
        let drain () =
          while !tasks <> [] do
            let batch = List.rev !tasks in
            tasks := [];
            List.iter (fun task -> task ()) batch
          done
        in
        let submit operation action =
          posted := [];
          let transition =
            Core.step !core (Core.Asset_requested { scope; operation; action })
          in
          core := transition.next;
          List.iter
            (function
              | Core.Run runnable -> Runner.submit runner runnable
              | _ -> ())
            transition.effects;
          drain ();
          List.rev !posted
        in
        let request operation action =
          match submit operation action with
          | [ event ] ->
            let completed = Core.step !core event in
            core := completed.next;
            List.find_map
              (function
                | Core.Publish (Core.Asset_finished output) -> Some output.result
                | _ -> None)
              completed.effects
            |> Option.get
          | _ -> fail "stage instance fixture did not complete"
        in
        let source_file = Filename.concat support "instance-source.bin" in
        let write bytes =
          Out_channel.with_open_bin source_file (fun out -> output_string out bytes)
        in
        let stage =
          Core.Stage_asset_file
            { operation = graph_id (); file_type = "bin"; source_file }
        in
        write "old";
        let old_event, old_file =
          match submit "old-instance" stage with
          | [ (Core.Runner_completed
                 (Core.Asset_completion (_, Ok (Core.Asset_staged { file; _ }))) as event)
            ] -> event, file
          | _ -> fail "old stage did not produce a resource completion"
        in
        Alcotest.(check bool)
          "prune removes old unaccepted staging instance"
          true
          (request "prune-old-instance" (Core.Prune_asset_staging [])
           = Ok (Core.Asset_pruned 1));
        write "new";
        let new_file =
          match request "new-instance" stage with
          | Ok (Core.Asset_staged { file; _ }) -> file
          | _ -> fail "replacement staging failed"
        in
        Alcotest.(check bool)
          "same import operation gets a distinct physical resource"
          false
          (String.equal old_file new_file);
        ignore
          (request "cancel-old-instance" (Core.Cancel_asset_operation "old-instance"));
        let late = Core.step !core old_event in
        core := late.next;
        Alcotest.(check bool)
          "cancelled completion releases the original exact reference"
          true
          (List.exists
             (function
               | Core.Run (Core.Asset_io (_, io)) ->
                 io.action = Core.Release_staged_file old_file
               | _ -> false)
             late.effects);
        posted := [];
        List.iter
          (function
            | Core.Run runnable -> Runner.submit runner runnable
            | _ -> ())
          late.effects;
        drain ();
        List.iter (fun event -> core := (Core.step !core event).next) (List.rev !posted);
        let lease, path =
          match request "retain-replacement" (Core.Retain_staged_file new_file) with
          | Ok (Core.Asset_retained (Some retained)) -> retained
          | _ -> fail "old cleanup deleted or completed replacement"
        in
        Alcotest.(check string)
          "replacement bytes survive old cleanup"
          "new"
          (In_channel.with_open_bin path In_channel.input_all);
        ignore (request "release-replacement-lease" (Core.Release_asset_file lease));
        ignore (request "release-replacement-stage" (Core.Release_staged_file new_file));
        Runner.shutdown runner)))
;;

let test_cache_prune_keeps_exact_staging_instance_and_legacy_files () =
  with_local_asset_cache ~pending_budget:16L (fun support request ->
    let source = Filename.concat support "exact-source.bin" in
    Out_channel.with_open_bin source (fun out -> output_string out "file");
    let older, _, _ = cache_stage request source in
    let newest, _, _ = cache_stage request source in
    cache_bool
      "same operation can stage a fresh instance without replacing old bytes"
      false
      (String.equal older newest);
    cache_bool
      "prune preserves exact durable instance only"
      true
      (request (Core.Prune_asset_staging [ newest ]) = Ok (Core.Asset_pruned 1));
    cache_bool
      "older instance removed"
      true
      (request (Core.Retain_staged_file older) = Ok (Core.Asset_retained None));
    let lease, path = request (Core.Retain_staged_file newest) |> retained_value in
    cache_bool "new durable instance survives prune" true (Sys.file_exists path);
    let legacy =
      Logseq_db_types.Graph_types.Uuid.to_string Core_contract.other_graph_id ^ ".bin"
    in
    let legacy_path = Filename.concat (Filename.dirname path) legacy in
    Out_channel.with_open_bin legacy_path (fun out -> output_string out "legacy");
    let legacy_lease, restored =
      request (Core.Retain_staged_file legacy) |> retained_value
    in
    Alcotest.(check string)
      "legacy UUID.type resource remains recoverable"
      "legacy"
      (In_channel.with_open_bin restored In_channel.input_all);
    cache_unit (request (Core.Release_asset_file legacy_lease));
    cache_unit (request (Core.Release_staged_file legacy));
    cache_unit (request (Core.Release_asset_file lease));
    cache_unit (request (Core.Release_staged_file newest)))
;;

let scenarios =
  scenarios
  @ [ Alcotest.test_case
        "late staging cleanup cannot delete replacement"
        `Quick
        test_late_stage_cleanup_cannot_delete_a_replacement
    ; Alcotest.test_case
        "staging prune keeps exact instance and legacy recovery"
        `Quick
        test_cache_prune_keeps_exact_staging_instance_and_legacy_files
    ]
;;

(* Deletion must cancel registered work before any cache instance exists; Core's
   cancelled pending state alone cannot stop a queued callback from doing I/O. *)
let test_graph_asset_deletion_cancels_queued_fetch_before_cache_open () =
  with_support (fun support ->
    Eio_main.run (fun environment ->
      Eio.Switch.run (fun sw ->
        let tasks = ref []
        and posted = ref []
        and acquisitions = ref 0 in
        let deps =
          dependencies
            ~environment
            ~support
            ~fork:(fun ~sw:_ task -> tasks := task :: !tasks)
            ~id_token_dependency:
              (Runner.id_token_provider
                 ~acquire:(fun _ ->
                   incr acquisitions;
                   Error "network must not be entered")
                 ~invalidate:(fun _ ~token:_ -> ()))
            ()
        in
        let runner =
          Runner.create ~sw deps ~post:(fun event -> posted := event :: !posted)
          |> Result.get_ok
        in
        let selected, scope = Core_contract.selected_graph Core_contract.graph in
        let version =
          Logseq_db_types.Asset_descriptor.version
            ~checksum:(String.make 64 'a')
            ~file_type:"bin"
          |> Result.get_ok
        in
        let fetching =
          Core.step
            selected.next
            (Core.Asset_requested
               { scope
               ; operation = "queued-fetch-before-cache"
               ; action =
                   Core.Fetch_asset
                     { asset = graph_id (); version; maximum_plaintext_bytes = 8 }
               })
        in
        let expected_ticket =
          List.find_map
            (function
              | Core.Run (Core.Asset_io (ticket, _) as runnable) ->
                Runner.submit runner runnable;
                Some ticket
              | _ -> None)
            fetching.effects
          |> Option.get
        in
        Alcotest.(check int)
          "fetch has not entered authentication before queued work starts"
          0
          !acquisitions;
        let deleting =
          Core.step
            fetching.next
            (Core.Asset_requested
               { scope
               ; operation = "delete-before-cache"
               ; action = Core.Delete_graph_assets
               })
        in
        List.iter
          (function
            | Core.Run runnable -> Runner.submit runner runnable
            | _ -> ())
          deleting.effects;
        while !tasks <> [] do
          let batch = List.rev !tasks in
          tasks := [];
          List.iter (fun task -> task ()) batch
        done;
        Alcotest.(check int)
          "deleted graph's queued fetch never enters authentication or network"
          0
          !acquisitions;
        Alcotest.(check bool)
          "queued callback reports its own cancelled completion"
          true
          (List.exists
             (function
               | Core.Runner_completed
                   (Core.Asset_completion (ticket, Error Core.Asset_cancelled)) ->
                 ticket = expected_ticket
               | _ -> false)
             !posted);
        List.iter (fun event -> ignore (Core.step deleting.next event)) (List.rev !posted);
        Runner.shutdown runner)))
;;

let scenarios =
  scenarios
  @ [ Alcotest.test_case
        "asset graph deletion cancels queued fetch before cache opens"
        `Quick
        test_graph_asset_deletion_cancels_queued_fetch_before_cache_open
    ]
;;
