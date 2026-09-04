module T = Logseq_db_worker_test_support.Test_support
module P = Logseq_db_worker.Protocol
module ID = Bonsai_flutter_spec.Id
module Service = Logseq_db_worker_bonsai.Logseq_db_worker_bonsai_service
module Runner = Logseq_sync_effect_runner.Effect_runner

let crypto =
  Runner.crypto
    ~encrypt_aes_gcm:(fun ~key:_ ~plaintext:_ -> Error "unavailable")
    ~decrypt_aes_gcm:(fun ~key:_ ~iv:_ ~ciphertext:_ -> Error "unavailable")
  |> Result.get_ok
;;

let secrets =
  Runner.secrets
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
    ~overlay:(T.overlay_dependencies ())
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

let v2_graph_info_request () =
  let json =
    `Assoc
      [ "apiVersion", `Int 2
      ; "requestId", `String "00000000-0000-4000-8000-000000000001"
      ; "command", `Assoc [ "type", `String "graphInfo" ]
      ]
  in
  match P.request_of_yojson json with
  | Ok request -> request
  | Error error ->
    T.fail
      "unable to build v2 graph-info request: %s"
      (Logseq_db_worker.Error.message error)
;;

let test_managed_worker_starts_closed_and_replies_with_v2_envelope () =
  T.with_managed (fun fixture ->
    with_client fixture.config (fun client ->
      let request = v2_graph_info_request () in
      let id = Worker.send client (Service.Graph_request request) |> accepted in
      match await_response client id with
      | Service.Graph_response response ->
        (match P.response_to_yojson response with
         | `Assoc
             [ ("apiVersion", `Int 2)
             ; ("requestId", `String "00000000-0000-4000-8000-000000000001")
             ; ("outcome", `Assoc (("type", `String "failed") :: _))
             ] -> ()
         | json ->
           T.fail
             "pre-selection v2 request did not return a v2 failure envelope: %s"
             (Yojson.Safe.to_string json))
      | _ -> T.fail "managed worker returned the wrong response kind"))
;;

let test_managed_client_command_is_accepted () =
  T.with_managed (fun fixture ->
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
        "managed worker starts closed with a v2 envelope"
        test_managed_worker_starts_closed_and_replies_with_v2_envelope
    ; T.case "managed client command is accepted" test_managed_client_command_is_accepted
    ]
;;
