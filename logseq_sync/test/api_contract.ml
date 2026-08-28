module Api = Logseq_sync.Api

let fail format = Printf.ksprintf (fun message -> Alcotest.fail message) format
let unavailable message = Error message

let unavailable_crypto =
  Api.crypto
    ~decrypt_private_key:(fun ~password:_ ~iterations:_ ~salt:_ ~iv:_ ~ciphertext:_ ->
      unavailable "private-key decryption is unavailable")
    ~decrypt_graph_key:(fun ~private_key:_ ~ciphertext:_ ->
      unavailable "graph-key decryption is unavailable")
    ~encrypt_aes_gcm:(fun ~key:_ ~plaintext:_ ->
      unavailable "AES-GCM encryption is unavailable")
    ~decrypt_aes_gcm:(fun ~key:_ ~iv:_ ~ciphertext:_ ->
      unavailable "AES-GCM decryption is unavailable")
  |> Result.get_ok
;;

let unavailable_secrets =
  Api.secrets
    ~has_private_key:(fun ~managed_sync_origin:_ ~user_id:_ -> false)
    ~unlock_private_key:
      (fun
        ~managed_sync_origin:_ ~user_id:_ ~password:_ ~private_key_package:_ ->
      unavailable "private-key operations are unavailable")
    ~unlock_graph_key:(fun ~managed_sync_origin:_ ~user_id:_ ~encrypted_graph_key:_ ->
      unavailable "graph-key operations are unavailable")
    ~load_and_verify_wrapped_graph_key:
      (fun
        ~managed_sync_origin:_ ~user_id:_ ~graph_id:_ ->
      Error (Api.Wrapped_graph_key_unavailable "wrapped graph key is unavailable"))
    ~verify_and_save_wrapped_graph_key:
      (fun
        ~managed_sync_origin:_ ~user_id:_ ~graph_id:_ ~encrypted_graph_key:_ ->
      unavailable "wrapped graph-key storage is unavailable")
    ~delete_wrapped_graph_key:(fun ~managed_sync_origin:_ ~user_id:_ ~graph_id:_ -> Ok ())
    ~delete_account_secrets:(fun ~managed_sync_origin:_ ~user_id:_ -> Ok ())
  |> Result.get_ok
;;

let rec remove_tree path =
  match Unix.lstat path with
  | { st_kind = Unix.S_DIR; _ } ->
    Sys.readdir path |> Array.iter (fun name -> remove_tree (Filename.concat path name));
    Unix.rmdir path
  | _ -> Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
;;

let with_support f =
  let path = Filename.temp_file "logseq-sync-client-" "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  Fun.protect ~finally:(fun () -> remove_tree path) (fun () -> f path)
;;

let dependencies ~environment ~support on_effect =
  let runtime =
    Api.runtime
      ~fork:(fun ~sw task -> Eio.Fiber.fork ~sw task)
      ~sleep:(fun seconds ->
        Eio.Time.Mono.sleep (Eio.Stdenv.mono_clock environment) seconds)
      ~monotonic_ns:Mtime_clock.elapsed_ns
    |> Result.get_ok
  in
  let transport =
    Api.transport
      ~network:(Eio.Stdenv.net environment)
      ~clock:(Eio.Stdenv.clock environment)
    |> Result.get_ok
  in
  let artifact_store =
    Api.artifact_store ~staging_directory:(Filename.concat support "sync-staging")
    |> Result.get_ok
  in
  Api.dependencies
    ~runtime
    ~transport
    ~artifact_store
    ~secrets:unavailable_secrets
    ~crypto:unavailable_crypto
    ~on_effect
  |> Result.get_ok
;;

let config () =
  let limits =
    Api.limits
      ~maximum_response_bytes:Logseq_db_types.Limits.maximum_response_bytes
      ~maximum_artifact_bytes:(1024 * 1024 * 1024)
      ~submission_batch_size:32
    |> Result.get_ok
  in
  Api.config ~managed_sync_origin:(Uri.of_string "https://api.logseq.io") ~limits
  |> Result.get_ok
;;

let create ~sw ~environment ~support on_effect =
  match Api.create ~sw (config ()) (dependencies ~environment ~support on_effect) with
  | Ok client -> client
  | Error (Api.Invalid_create message) -> fail "Api.create failed: %s" message
;;

let token_requests events =
  List.filter_map
    (function
      | Api.Token_requested request -> Some request
      | State_changed _
      | Bootstrap_progressed _
      | Graph_invalidated _
      | Attach_graph _
      | Detach_graph _
      | Apply_authoritative_batch _
      | Commit_outbox_transition _
      | Run_local_operation _
      | Resume _ -> None)
    !events
  |> List.rev
;;

let handle events client event =
  events := List.rev_append (Api.handle client event) !events
;;

let run_local_effects events client local_store effects =
  List.iter
    (function
      | Api.Run_local_operation operation ->
        events
        := List.rev_append (Api.run_local_operation client local_store operation) !events
      | output -> events := output :: !events)
    effects
;;

let test_dependency_constructors_validate_owned_resources () =
  with_support (fun support ->
    match
      Api.local_store ~application_support_directory:(Filename.concat support "missing")
    with
    | Error (Api.Invalid_dependency message) ->
      Alcotest.check
        Alcotest.bool
        "typed validation message"
        true
        (String.length message > 0)
    | Ok _ -> Alcotest.fail "local_store accepted a missing support directory")
;;

let test_offline_restore_never_enters_the_network_lane () =
  with_support (fun support ->
    Eio_main.run (fun environment ->
      Eio.Switch.run (fun sw ->
        let events = ref [] in
        let client =
          create ~sw ~environment ~support (fun event -> events := event :: !events)
        in
        let local_store =
          Api.local_store ~application_support_directory:support |> Result.get_ok
        in
        let effects = Api.handle client (Restore_local_account { user_id = "user-1" }) in
        Alcotest.check
          Alcotest.bool
          "offline restore delegates local storage"
          true
          (List.exists
             (function
               | Api.Run_local_operation _ -> true
               | _ -> false)
             effects);
        run_local_effects events client local_store effects;
        let state = Api.state client in
        Alcotest.check
          Alcotest.bool
          "offline restore reports synchronization only"
          true
          (state.snapshot.sync_phase = Api.Offline);
        Alcotest.(check (list string))
          "empty offline catalog"
          []
          (List.map
             (fun graph -> graph.Logseq_db_types.Managed_graph.name)
             state.snapshot.catalog);
        Alcotest.check
          Alcotest.bool
          "offline restore requested no token"
          true
          (token_requests events = []);
        handle events client Shutdown)))
;;

let test_token_requests_are_opaque_and_stale_responses_are_fenced () =
  with_support (fun support ->
    Eio_main.run (fun environment ->
      Eio.Switch.run (fun sw ->
        let events = ref [] in
        let client =
          create ~sw ~environment ~support (fun event -> events := event :: !events)
        in
        handle events client (Account_authenticated { user_id = Some "user-1" });
        Alcotest.check
          Alcotest.bool
          "catalog authorization is connecting"
          true
          ((Api.state client).snapshot.sync_phase = Api.Connecting);
        let first =
          match token_requests events with
          | [ request ] -> request
          | requests ->
            fail "expected one first token request, got %d" (List.length requests)
        in
        handle events client (Account_authenticated { user_id = Some "user-2" });
        let second =
          match token_requests events with
          | [ first_again; request ]
            when String.equal
                   (Api.token_request_id first_again)
                   (Api.token_request_id first) -> request
          | requests ->
            fail "expected a replacement token request, got %d" (List.length requests)
        in
        handle events client (Token_provided (first, "stale-token"));
        Alcotest.check
          Alcotest.string
          "replacement request remains current"
          (Api.token_request_id second)
          (Api.token_request_id (List.hd (List.rev (token_requests events))));
        handle events client (Token_rejected second);
        Alcotest.check
          Alcotest.bool
          "current rejection fails the unpopulated client"
          true
          ((Api.state client).snapshot.sync_phase = Api.Failed);
        handle events client Shutdown)))
;;

let test_shutdown_is_idempotent_and_rejects_new_work () =
  with_support (fun support ->
    Eio_main.run (fun environment ->
      Eio.Switch.run (fun sw ->
        let events = ref [] in
        let client =
          create ~sw ~environment ~support (fun event -> events := event :: !events)
        in
        handle events client Shutdown;
        let before = Api.state client, List.length !events in
        handle events client Shutdown;
        handle events client (Account_authenticated { user_id = Some "ignored-user" });
        let after = Api.state client, List.length !events in
        Alcotest.check Alcotest.bool "closed state is stable" true (before = after))))
;;

let scenarios =
  [ Alcotest.test_case
      "dependency constructors validate owned resources"
      `Quick
      test_dependency_constructors_validate_owned_resources
  ; Alcotest.test_case
      "offline restore never enters the network lane"
      `Quick
      test_offline_restore_never_enters_the_network_lane
  ; Alcotest.test_case
      "opaque token requests fence stale responses"
      `Quick
      test_token_requests_are_opaque_and_stale_responses_are_fenced
  ; Alcotest.test_case
      "shutdown is idempotent and rejects new work"
      `Quick
      test_shutdown_is_idempotent_and_rejects_new_work
  ]
;;
