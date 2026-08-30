module T = Logseq_db_worker_test_support.Test_support
module F = Logseq_db_worker_test_support.Adapter_fixture
module P = Logseq_db_worker.Protocol
module ID = Bonsai_flutter_spec.Id
module Service = Logseq_db_worker_bonsai.Logseq_db_worker_bonsai_service
module Runner = Logseq_sync_effect_runner.Effect_runner

let crypto =
  Runner.crypto
    ~decrypt_private_key:(fun ~password:_ ~iterations:_ ~salt:_ ~iv:_ ~ciphertext:_ ->
      Error "crypto unavailable")
    ~decrypt_graph_key:(fun ~private_key:_ ~ciphertext:_ -> Error "crypto unavailable")
    ~encrypt_aes_gcm:(fun ~key:_ ~plaintext:_ -> Error "crypto unavailable")
    ~decrypt_aes_gcm:(fun ~key:_ ~iv:_ ~ciphertext:_ -> Error "crypto unavailable")
  |> Result.get_ok
;;

let secrets =
  Runner.secrets
    ~has_private_key:(fun ~managed_sync_origin:_ ~user_id:_ -> false)
    ~unlock_private_key:
      (fun
        ~managed_sync_origin:_ ~user_id:_ ~password:_ ~private_key_package:_ ->
      Error "secrets unavailable")
    ~unlock_graph_key:(fun ~managed_sync_origin:_ ~user_id:_ ~encrypted_graph_key:_ ->
      Error "secrets unavailable")
    ~load_wrapped_graph_key:(fun ~managed_sync_origin:_ ~user_id:_ ~graph_id:_ ->
      Error (Runner.Wrapped_graph_key_unavailable "secrets unavailable"))
    ~verify_and_save_wrapped_graph_key:
      (fun
        ~managed_sync_origin:_ ~user_id:_ ~graph_id:_ ~encrypted_graph_key:_ ->
      Error "secrets unavailable")
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

let epoch = ref 2_000L

let next_epoch () =
  let value = !epoch in
  epoch := Int64.succ value;
  ID.Runtime.Epoch.of_int64 value
;;

let start config =
  Worker_runtime.start
    ~runtime_epoch:(next_epoch ())
    (Service.create ~dependencies)
    config
;;

let stop client =
  Worker_runtime.stop client;
  Worker_runtime.For_testing.await_state Worker_runtime.Idle
;;

let accepted = function
  | Worker.Accepted request_id -> request_id
  | Full -> T.fail "request unexpectedly hit backpressure"
  | Not_ready -> T.fail "request was not ready"
  | Stopping -> T.fail "request was stopping"
;;

let rec await_response client request_id =
  match
    Worker.For_testing.drain_events client ~max_events:64
    |> List.find_map (function
      | Worker.Response
          { request_id = actual
          ; outcome = Completed (Service.Graph_response response)
          ; _
          }
        when ID.Worker.Request_id.equal request_id actual -> Some response
      | Response _ | Push _ | Terminal _ -> None)
  with
  | Some response -> response
  | None ->
    Worker.For_testing.await_output client;
    await_response client request_id
;;

let with_client config f =
  let client =
    match start config with
    | Ok client -> client
    | Error message -> T.fail "Worker service failed to start: %s" message
  in
  Fun.protect
    ~finally:(fun () ->
      if (Worker_runtime.For_testing.diagnostics ()).state = Attached then stop client)
    (fun () -> f client)
;;

let serial_service_executes_engine () =
  F.with_snapshot (fun fixture ->
    with_client fixture.config (fun client ->
      let request = F.graph_info_request () in
      let request_id = Worker.send client (Service.Graph_request request) |> accepted in
      (match await_response client request_id with
       | P.Succeeded { request_id = actual; success = Graph_info_result _; _ } ->
         T.require
           (Logseq_db_types.Graph_types.Uuid.equal actual request.request_id)
           "Worker changed the protocol request ID"
       | _ -> T.fail "Worker did not delegate graph info to Engine");
      let diagnostics = Worker_runtime.For_testing.diagnostics () in
      T.require
        (diagnostics.configured_concurrency_limit = Some 1)
        "Logseq Worker service is not Serial"))
;;

let open_failure_stays_in_protocol () =
  F.with_snapshot (fun fixture ->
    with_client (F.missing_config fixture.support) (fun client ->
      let request = F.graph_info_request () in
      let request_id = Worker.send client (Service.Graph_request request) |> accepted in
      match await_response client request_id with
      | P.Failed { request_id = actual; phase = Open; basis = None; _ } ->
        T.require
          (Logseq_db_types.Graph_types.Uuid.equal actual request.request_id)
          "Open failure lost the protocol request ID"
      | _ -> T.fail "Expected graph-open error was not Protocol.Failed Open"))
;;

let graph_lifecycle_is_generation_fenced () =
  let module Lifecycle = Logseq_db_worker.Graph_lifecycle in
  let graph_id =
    Logseq_db_types.Graph_types.Uuid.of_string "10000000-0000-4000-8000-000000000001"
    |> Result.get_ok
  in
  let lifecycle = Lifecycle.create () in
  let require_phase expected message =
    T.require ((Lifecycle.state lifecycle).phase = expected) "%s" message
  in
  require_phase Logseq_db_worker.Graph_closed "graph did not start closed";
  Lifecycle.begin_open lifecycle ~generation:1 ~graph_id:(Some graph_id);
  require_phase Graph_opening "graph did not enter opening";
  Lifecycle.opened lifecycle ~generation:1;
  require_phase Graph_open "graph did not enter open";
  Lifecycle.failed lifecycle ~generation:0 ~message:"stale failure";
  require_phase Graph_open "stale generation changed graph state";
  Lifecycle.begin_close lifecycle ~generation:1;
  require_phase Graph_closing "graph did not enter closing";
  Lifecycle.closed lifecycle ~generation:1;
  require_phase Graph_closed "graph did not close";
  Lifecycle.begin_open lifecycle ~generation:2 ~graph_id:(Some graph_id);
  require_phase Graph_opening "graph switch did not reopen";
  Lifecycle.failed lifecycle ~generation:2 ~message:"open failed";
  let failed = Lifecycle.state lifecycle in
  require_phase Graph_failed "graph failure was not published";
  T.require (failed.error = Some "open failed") "graph failure detail was discarded"
;;

let await_graph_state client =
  let request_id = Worker.send client Service.Get_graph_state |> accepted in
  let rec loop () =
    match
      Worker.For_testing.drain_events client ~max_events:64
      |> List.find_map (function
        | Worker.Response
            { request_id = actual; outcome = Completed (Service.Graph_state state); _ }
          when ID.Worker.Request_id.equal request_id actual -> Some state
        | Response _ | Push _ | Terminal _ -> None)
    with
    | Some state -> state
    | None ->
      Worker.For_testing.await_output client;
      loop ()
  in
  loop ()
;;

let service_publishes_initial_graph_state () =
  F.with_snapshot (fun fixture ->
    with_client fixture.config (fun client ->
      let state = await_graph_state client in
      T.require
        (state.Logseq_db_worker.phase = Graph_open)
        "successfully opened worker graph was not published"));
  F.with_snapshot (fun fixture ->
    with_client (F.missing_config fixture.support) (fun client ->
      let state = await_graph_state client in
      T.require
        (state.Logseq_db_worker.phase = Graph_failed)
        "worker graph open failure was not published"))
;;

let sole_public_sync_composition () =
  let read_file path =
    let channel = open_in_bin path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr channel)
      (fun () -> really_input_string channel (in_channel_length channel))
  in
  let source =
    read_file
      (Filename.concat
         T.root
         "logseq_db_worker/bonsai/logseq_db_worker_bonsai_service.ml")
  in
  let contains needle =
    let needle_length = String.length needle in
    let rec loop offset =
      offset + needle_length <= String.length source
      && (String.equal (String.sub source offset needle_length) needle || loop (offset + 1)
         )
    in
    loop 0
  in
  T.require
    (contains "Logseq_sync_pure_reducer.Core")
    "Service does not use the pure sync core";
  T.require
    (contains "Logseq_sync_effect_runner.Effect_runner")
    "Service does not use the public effect runner";
  T.require (contains "Core.initial") "Service does not create the pure sync core";
  T.require (contains "module Managed_coordinator") "Service has no managed coordinator";
  T.require
    (contains "Managed_coordinator.handle")
    "Managed events bypass the coordinator";
  T.require (contains "Core.step") "Worker does not drive the sync reducer";
  T.require
    (contains "Effect_runner.submit")
    "Worker does not submit runner-owned effects";
  T.require (not (contains "Core.graph_backend")) "Sync still receives an Engine backend";
  T.require (not (contains "Core.mutate")) "Sync still owns the managed mutation path"
;;

let () =
  T.run
    "bonsai service"
    [ T.case "Serial service delegates to Engine" serial_service_executes_engine
    ; T.case "Open failure remains protocol state" open_failure_stays_in_protocol
    ; T.case "Graph lifecycle is generation fenced" graph_lifecycle_is_generation_fenced
    ; T.case "Service publishes initial graph state" service_publishes_initial_graph_state
    ; T.case
        "Public sync API is the sole composition boundary"
        sole_public_sync_composition
    ];
  Worker_runtime.For_testing.final_shutdown ()
;;
