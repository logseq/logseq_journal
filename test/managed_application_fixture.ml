module Runner = Logseq_sync_effect_runner.Effect_runner
module Service = Logseq_db_worker_bonsai.Logseq_db_worker_bonsai_service

let secrets =
  Runner.secrets
    ~has_private_key:(fun ~managed_sync_origin:_ ~user_id:_ -> true)
    ~unlock_private_key:
      (fun
        ~managed_sync_origin:_ ~user_id:_ ~password:_ ~private_key_package:_ -> Ok ())
    ~unlock_graph_key:(fun ~managed_sync_origin:_ ~user_id:_ ~encrypted_graph_key:_ ->
      Ok "managed-fixture-graph-key")
    ~load_wrapped_graph_key:(fun ~managed_sync_origin:_ ~user_id:_ ~graph_id:_ ->
      Ok "managed-fixture-wrapped-key")
    ~verify_and_save_wrapped_graph_key:
      (fun
        ~managed_sync_origin:_ ~user_id:_ ~graph_id:_ ~encrypted_graph_key:_ -> Ok ())
    ~delete_wrapped_graph_key:(fun ~managed_sync_origin:_ ~user_id:_ ~graph_id:_ -> Ok ())
    ~delete_account_secrets:(fun ~managed_sync_origin:_ ~user_id:_ -> Ok ())
  |> Result.get_ok
;;

let crypto =
  Runner.crypto
    ~decrypt_private_key:(fun ~password:_ ~iterations:_ ~salt:_ ~iv:_ ~ciphertext ->
      Ok ciphertext)
    ~decrypt_graph_key:(fun ~private_key:_ ~ciphertext -> Ok ciphertext)
    ~encrypt_aes_gcm:(fun ~key:_ ~plaintext -> Ok ("managed-fixture-iv", plaintext))
    ~decrypt_aes_gcm:(fun ~key:_ ~iv:_ ~ciphertext ->
      Ok (Transit_native.Transit.Json.to_string (Transit_core.Json.String ciphertext)))
  |> Result.get_ok
;;

let dependencies =
  Service.dependencies
    ~engine:Logseq_db_worker_test_support.Adapter_fixture.dependencies
    ~tls_authenticator:(Runner.system_tls_authenticator () |> Result.get_ok)
    ~secrets
    ~crypto
;;

let service = Service.create ~dependencies
let app = Application.For_testing.app_with_service service
