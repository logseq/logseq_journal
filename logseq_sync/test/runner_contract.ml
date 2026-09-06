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
    ~id_token_provider:
      (Runner.id_token_provider
         ~acquire:(fun _ -> Ok "test-id-token")
         ~invalidate:(fun _ ~token:_ -> ()))
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
        Runner.submit runner (Core.Cancel_effects (Core.runner_effect_scope save));
        List.iter (fun task -> task ()) (List.rev !tasks);
        Alcotest.(check bool)
          "cancelled save has no durable side effects"
          false
          (Sys.file_exists (Filename.concat support "logseq-db-worker"));
        Alcotest.(check int) "cancelled save posts no completion" 0 (List.length !posted))))
;;

let cached_key_effect () =
  let authenticated =
    Core.step (core ()) (Account_authenticated { user_id = Some "user-1" })
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
        Alcotest.(check (result string string))
          "failed cached key is not stored as a usable handle"
          (Error "graph key handle is unavailable or out of scope")
          (Runner.decrypt_protected_value runner handle "plaintext"))))
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
      | Core.Run (Core.Request (ticket, Core.Delete_account_secrets account)) ->
        Some (Core.Request (ticket, Core.Delete_account_secrets account))
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
        | Core.Run (Core.Request (ticket, Core.Unlock_private_key request)) ->
          Some (Core.Request (ticket, Core.Unlock_private_key request))
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

let authentication_policy_provider tokens invalidated =
  Runner.id_token_provider
    ~acquire:(fun _ ->
      match Queue.take_opt tokens with
      | Some token -> Ok token
      | None -> Error "no token")
    ~invalidate:(fun _ ~token -> invalidated := token :: !invalidated)
;;

let authentication_policy_account : Core.account_scope =
  { managed_sync_origin = Uri.of_string "https://api.logseq.io"
  ; user_id = "user-1"
  ; account_generation = 1
  ; presentation_generation = 1
  ; lifecycle_generation = 1L
  }
;;

let test_authenticated_operation_retries_one_unauthorized_response () =
  let tokens = Queue.create () in
  Queue.add "token-1" tokens;
  Queue.add "token-2" tokens;
  let invalidated = ref [] in
  let attempts = ref [] in
  let result =
    Runner.authenticated_operation
      (authentication_policy_provider tokens invalidated)
      ~account:authentication_policy_account
      ~perform:(fun token ->
        attempts := token :: !attempts;
        if String.equal token "token-1" then Error Runner.Unauthorized else Ok "done")
  in
  Alcotest.(check (result string string)) "retry succeeds" (Ok "done") result;
  Alcotest.(check (list string))
    "one refreshed attempt"
    [ "token-1"; "token-2" ]
    (List.rev !attempts);
  Alcotest.(check (list string)) "used token invalidated" [ "token-1" ] !invalidated
;;

let test_authenticated_operation_surfaces_second_unauthorized_response () =
  let tokens = Queue.create () in
  Queue.add "token-1" tokens;
  Queue.add "token-2" tokens;
  let invalidated = ref [] in
  let attempts = ref 0 in
  let result =
    Runner.authenticated_operation
      (authentication_policy_provider tokens invalidated)
      ~account:authentication_policy_account
      ~perform:(fun _ ->
        incr attempts;
        Error Runner.Unauthorized)
  in
  Alcotest.(check (result string string))
    "second unauthorized is terminal"
    (Error "Authentication failed.")
    result;
  Alcotest.check Alcotest.int "at most two attempts" 2 !attempts;
  Alcotest.(check (list string)) "only first token invalidated" [ "token-1" ] !invalidated
;;

let test_authenticated_operation_does_not_retry_forbidden_response () =
  let tokens = Queue.create () in
  Queue.add "token-1" tokens;
  let invalidated = ref [] in
  let attempts = ref 0 in
  let result =
    Runner.authenticated_operation
      (authentication_policy_provider tokens invalidated)
      ~account:authentication_policy_account
      ~perform:(fun _ ->
        incr attempts;
        Error Runner.Forbidden)
  in
  Alcotest.(check (result string string))
    "forbidden is terminal"
    (Error "Authorization failed.")
    result;
  Alcotest.check Alcotest.int "one attempt" 1 !attempts;
  Alcotest.(check (list string)) "token remains reusable" [] !invalidated
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
      "authenticated operation retries one unauthorized response"
      `Quick
      test_authenticated_operation_retries_one_unauthorized_response
  ; Alcotest.test_case
      "authenticated operation surfaces a second unauthorized response"
      `Quick
      test_authenticated_operation_surfaces_second_unauthorized_response
  ; Alcotest.test_case
      "authenticated operation does not retry forbidden response"
      `Quick
      test_authenticated_operation_does_not_retry_forbidden_response
  ; Alcotest.test_case
      "runner source has no placeholder capabilities"
      `Quick
      test_runner_source_has_no_placeholder_capabilities
  ]
;;
