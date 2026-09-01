module T = Logseq_db_worker_test_support.Test_support
module F = Logseq_db_worker_test_support.Adapter_fixture
module P = Logseq_db_worker.Protocol
module ID = Bonsai_flutter_spec.Id
module Service = Logseq_db_worker_bonsai.Logseq_db_worker_bonsai_service
module Runner = Logseq_sync_effect_runner.Effect_runner

let crypto =
  Runner.crypto
    ~decrypt_private_key:(fun ~password:_ ~iterations:_ ~salt:_ ~iv:_ ~ciphertext:_ ->
      Error "unavailable")
    ~decrypt_graph_key:(fun ~private_key:_ ~ciphertext:_ -> Error "unavailable")
    ~encrypt_aes_gcm:(fun ~key:_ ~plaintext:_ -> Error "unavailable")
    ~decrypt_aes_gcm:(fun ~key:_ ~iv:_ ~ciphertext:_ -> Error "unavailable")
  |> Result.get_ok
;;

let secrets =
  Runner.secrets
    ~has_private_key:(fun ~managed_sync_origin:_ ~user_id:_ -> false)
    ~unlock_private_key:
      (fun
        ~managed_sync_origin:_ ~user_id:_ ~password:_ ~private_key_package:_ ->
      Error "unavailable")
    ~unlock_graph_key:(fun ~managed_sync_origin:_ ~user_id:_ ~encrypted_graph_key:_ ->
      Error "unavailable")
    ~load_wrapped_graph_key:(fun ~managed_sync_origin:_ ~user_id:_ ~graph_id:_ ->
      Error (Runner.Wrapped_graph_key_unavailable "unavailable"))
    ~verify_and_save_wrapped_graph_key:
      (fun
        ~managed_sync_origin:_ ~user_id:_ ~graph_id:_ ~encrypted_graph_key:_ ->
      Error "unavailable")
    ~delete_wrapped_graph_key:(fun ~managed_sync_origin:_ ~user_id:_ ~graph_id:_ -> Ok ())
    ~delete_account_secrets:(fun ~managed_sync_origin:_ ~user_id:_ -> Ok ())
  |> Result.get_ok
;;

let dependencies =
  Service.dependencies
    ~engine:F.dependencies
    ~tls_authenticator:(Runner.system_tls_authenticator () |> Result.get_ok)
    ~secrets
    ~crypto
;;

let accepted = function
  | Worker.Accepted request_id -> request_id
  | Full | Not_ready | Stopping -> T.fail "worker request was not accepted"
;;

let await_response client request_id =
  let rec loop () =
    match
      Worker.For_testing.drain_events client ~max_events:64
      |> List.find_map (function
        | Worker.Response { request_id = actual; outcome = Completed response; _ }
          when ID.Worker.Request_id.equal request_id actual -> Some response
        | Response _ | Push _ | Terminal _ -> None)
    with
    | Some response -> response
    | None ->
      Worker.For_testing.await_output client;
      loop ()
  in
  loop ()
;;

let with_client config run =
  let service = Service.create ~dependencies in
  let client =
    Worker_runtime.start ~runtime_epoch:(ID.Runtime.Epoch.of_int64 2_000L) service config
    |> Result.fold ~ok:Fun.id ~error:(fun message -> T.fail "%s" message)
  in
  Fun.protect ~finally:(fun () -> Worker_runtime.stop client) (fun () -> run client)
;;

let test_managed_worker_starts_closed_and_replies_in_protocol () =
  F.with_managed (fun fixture ->
    with_client fixture.config (fun client ->
      let request = F.graph_info_request () in
      let id = Worker.send client (Service.Graph_request request) |> accepted in
      match await_response client id with
      | Service.Graph_response (P.Failed { phase = Open; _ }) -> ()
      | _ -> T.fail "managed worker did not reject a pre-selection graph request"))
;;

let test_managed_client_command_is_accepted () =
  F.with_managed (fun fixture ->
    with_client fixture.config (fun client ->
      let id =
        Worker.send
          client
          (Service.Client_command (Restore_local_account { user_id = "fixture-user" }))
        |> accepted
      in
      match await_response client id with
      | Service.Client_command_completed -> ()
      | _ -> T.fail "managed client command returned the wrong response"))
;;

let () =
  T.run
    "bonsai worker service"
    [ T.case
        "managed worker starts closed"
        test_managed_worker_starts_closed_and_replies_in_protocol
    ; T.case "managed client command is accepted" test_managed_client_command_is_accepted
    ]
;;
