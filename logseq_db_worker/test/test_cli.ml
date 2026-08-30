module T = Logseq_db_worker_test_support.Test_support
module F = Logseq_db_worker_test_support.Adapter_fixture
module P = Logseq_db_worker.Protocol
module ID = Bonsai_flutter_spec.Id
module Worker_service = Logseq_db_worker_bonsai.Logseq_db_worker_bonsai_service
module Runner = Logseq_sync_effect_runner.Effect_runner

let worker_dependencies =
  let crypto =
    Runner.crypto
      ~decrypt_private_key:(fun ~password:_ ~iterations:_ ~salt:_ ~iv:_ ~ciphertext:_ ->
        Error "unavailable")
      ~decrypt_graph_key:(fun ~private_key:_ ~ciphertext:_ -> Error "unavailable")
      ~encrypt_aes_gcm:(fun ~key:_ ~plaintext:_ -> Error "unavailable")
      ~decrypt_aes_gcm:(fun ~key:_ ~iv:_ ~ciphertext:_ -> Error "unavailable")
    |> Result.get_ok
  in
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
      ~delete_wrapped_graph_key:(fun ~managed_sync_origin:_ ~user_id:_ ~graph_id:_ ->
        Ok ())
      ~delete_account_secrets:(fun ~managed_sync_origin:_ ~user_id:_ -> Ok ())
    |> Result.get_ok
  in
  Worker_service.dependencies
    ~engine:F.dependencies
    ~tls_authenticator:(Runner.system_tls_authenticator () |> Result.get_ok)
    ~secrets
    ~crypto
;;

let send_graph client request = Worker.send client (Worker_service.Graph_request request)

let require_response_equal expected actual =
  let expected = P.response_to_yojson expected |> Yojson.Safe.sort in
  let actual = P.response_to_yojson actual |> Yojson.Safe.sort in
  T.require
    (Yojson.Safe.equal expected actual)
    "CLI response differs from direct Engine response:\nexpected=%s\nactual=%s"
    (Yojson.Safe.pretty_to_string expected)
    (Yojson.Safe.pretty_to_string actual)
;;

let worker_once ~epoch config request =
  let client =
    match
      Worker_runtime.start
        ~runtime_epoch:(ID.Runtime.Epoch.of_int64 epoch)
        (Worker_service.create ~dependencies:worker_dependencies)
        config
    with
    | Ok client -> client
    | Error message -> T.fail "Worker trace failed to start: %s" message
  in
  Fun.protect
    ~finally:(fun () ->
      if (Worker_runtime.For_testing.diagnostics ()).state = Attached
      then Worker_runtime.stop client)
    (fun () ->
       let transport_request_id =
         match send_graph client request with
         | Accepted request_id -> request_id
         | Full | Not_ready | Stopping -> T.fail "Worker trace request was not accepted"
       in
       let rec await_response () =
         let response =
           Worker.For_testing.drain_events client ~max_events:64
           |> List.find_map (function
             | Worker.Response
                 { request_id
                 ; outcome = Completed (Worker_service.Graph_response response)
                 ; _
                 }
               when ID.Worker.Request_id.equal transport_request_id request_id ->
               Some response
             | Response _ | Push _ | Terminal _ -> None)
         in
         match response with
         | Some response -> response
         | None ->
           Worker.For_testing.await_output client;
           await_response ()
       in
       let response = await_response () in
       Worker_runtime.stop client;
       Worker_runtime.For_testing.await_state Worker_runtime.Idle;
       response)
;;

let test_direct_and_cli_trace_match () =
  F.with_snapshot (fun fixture ->
    let request = F.graph_info_request () in
    let direct =
      match Logseq_db_worker.Engine.open_ ~dependencies:F.dependencies fixture.config with
      | Error error ->
        T.fail "direct Engine open failed: %s" (Logseq_db_worker.Error.message error)
      | Ok engine ->
        Fun.protect
          ~finally:(fun () -> ignore (Logseq_db_worker.Engine.close engine))
          (fun () -> Logseq_db_worker.Engine.execute engine request)
    in
    let cli =
      match
        Cli_command.execute_once ~dependencies:F.dependencies fixture.config request
      with
      | Ok response -> response
      | Error _ -> T.fail "CLI session failed"
    in
    require_response_equal direct cli;
    let worker = worker_once ~epoch:1_901L fixture.config request in
    require_response_equal direct worker)
;;

let direct_once config request =
  match Logseq_db_worker.Engine.open_ ~dependencies:F.dependencies config with
  | Error error ->
    T.fail "direct trace open failed: %s" (Logseq_db_worker.Error.message error)
  | Ok engine ->
    Fun.protect
      ~finally:(fun () -> ignore (Logseq_db_worker.Engine.close engine))
      (fun () -> Logseq_db_worker.Engine.execute engine request)
;;

let test_mutation_and_final_state_match_all_transports () =
  F.with_snapshot (fun fixture ->
    let clone () =
      match
        Cli_command.create_snapshot
          ~application_support_directory:fixture.support
          ~source_graph_dir:fixture.source_graph_dir
      with
      | Ok token -> F.config fixture.support token
      | Error message -> T.fail "unable to clone transport parity snapshot: %s" message
    in
    let cli_config = clone () in
    let worker_config = clone () in
    let basis =
      match direct_once fixture.config (F.graph_info_request ()) with
      | P.Succeeded { basis; _ } -> basis
      | _ -> T.fail "unable to read transport parity basis"
    in
    let mutation =
      F.create_page_request
        ~basis
        ~request_id:"64000000-0000-4000-8000-000000000001"
        ~mutation_id:"65000000-0000-4000-8000-000000000001"
        ~page_uuid:"66000000-0000-4000-8000-000000000001"
        ~title:"Three transport page"
    in
    let direct_mutation = direct_once fixture.config mutation in
    let cli_mutation =
      match Cli_command.execute_once ~dependencies:F.dependencies cli_config mutation with
      | Ok response -> response
      | Error _ -> T.fail "CLI mutation trace terminated"
    in
    let worker_mutation = worker_once ~epoch:1_902L worker_config mutation in
    require_response_equal direct_mutation cli_mutation;
    require_response_equal direct_mutation worker_mutation;
    let read =
      P.
        { api_version
        ; request_id = F.uuid "64000000-0000-4000-8000-000000000002"
        ; command =
            Read
              (Get_page
                 { page = Page_by_uuid (F.uuid "66000000-0000-4000-8000-000000000001") })
        }
    in
    let direct_final = direct_once fixture.config read in
    let cli_final =
      match Cli_command.execute_once ~dependencies:F.dependencies cli_config read with
      | Ok response -> response
      | Error _ -> T.fail "CLI final-state read terminated"
    in
    let worker_final = worker_once ~epoch:1_903L worker_config read in
    require_response_equal direct_final cli_final;
    require_response_equal direct_final worker_final)
;;

let test_open_failure_and_exact_ndjson () =
  F.with_snapshot (fun fixture ->
    let config = F.missing_config fixture.support in
    let first = F.graph_info_request () in
    let second =
      F.graph_info_request ~request_id:"10000000-0000-4000-8000-000000000002" ()
    in
    let lines =
      List.map
        (fun request -> P.request_to_yojson request |> Yojson.Safe.to_string)
        [ first; second ]
    in
    match Cli_command.run_ndjson_lines ~dependencies:F.dependencies config lines with
    | Error _ -> T.fail "expected graph-open failure terminated NDJSON"
    | Ok outputs ->
      T.require (List.length outputs = 2) "NDJSON did not emit one response per request";
      List.iter2
        (fun (request : P.request) line ->
           let actual = Yojson.Safe.from_string line in
           match actual with
           | `Assoc fields ->
             T.require
               (List.assoc_opt "requestId" fields
                = Some
                    (`String
                        (Logseq_db_types.Graph_types.Uuid.to_string request.P.request_id))
               )
               "open failure lost the incoming request ID";
             T.require
               (List.assoc_opt "phase" fields = Some (`String "open"))
               "open failure did not use Protocol.Open"
           | _ -> T.fail "NDJSON response is not an object")
        [ first; second ]
        outputs)
;;

let test_ndjson_rejects_local_decode_errors () =
  F.with_snapshot (fun fixture ->
    match
      Cli_command.run_ndjson_lines
        ~dependencies:F.dependencies
        fixture.config
        [ "{not-json}" ]
    with
    | Error (Cli_command.Local_decode_error _) -> ()
    | Error (Fatal_lifecycle_error _) ->
      T.fail "local decode error was classified as fatal"
    | Ok _ -> T.fail "malformed NDJSON was accepted")
;;

let test_ndjson_rejects_oversized_lines () =
  F.with_snapshot (fun fixture ->
    match
      Cli_command.run_ndjson_lines
        ~dependencies:F.dependencies
        fixture.config
        [ String.make (P.maximum_request_bytes + 1) 'x' ]
    with
    | Error (Cli_command.Local_decode_error _) -> ()
    | Error (Fatal_lifecycle_error _) -> T.fail "oversized line was classified as fatal"
    | Ok _ -> T.fail "oversized NDJSON line was accepted")
;;

let test_snapshot_create_uses_core () =
  F.with_snapshot (fun fixture ->
    match
      Cli_command.create_snapshot
        ~application_support_directory:fixture.support
        ~source_graph_dir:fixture.source_graph_dir
    with
    | Error message -> T.fail "CLI snapshot create failed: %s" message
    | Ok token ->
      (match
         Logseq_db_worker.Engine.open_
           ~dependencies:F.dependencies
           (F.config fixture.support token)
       with
       | Error error ->
         T.fail
           "CLI snapshot token did not open through Engine: %s"
           (Logseq_db_worker.Error.message error)
       | Ok engine ->
         (match Logseq_db_worker.Engine.close engine with
          | Ok () -> ()
          | Error message -> T.fail "CLI-created snapshot did not close: %s" message)))
;;

let test_snapshot_import_uses_confined_core () =
  F.with_snapshot (fun fixture ->
    let inbox =
      Filename.concat (Filename.concat fixture.support "logseq-db-worker") "inbox"
    in
    let source = F.create_oracle_graph inbox "incoming" in
    match
      Cli_command.import_snapshot
        ~application_support_directory:fixture.support
        ~inbox_entry:"incoming"
    with
    | Error message -> T.fail "CLI snapshot import failed: %s" message
    | Ok token ->
      T.require (not (Sys.file_exists source)) "CLI import did not consume inbox entry";
      (match
         Logseq_db_worker.Engine.open_
           ~dependencies:F.dependencies
           (F.config fixture.support token)
       with
       | Error error ->
         T.fail
           "CLI import did not publish an Engine-readable token: %s"
           (Logseq_db_worker.Error.message error)
       | Ok engine ->
         (match Logseq_db_worker.Engine.close engine with
          | Ok () -> ()
          | Error message -> T.fail "CLI-imported snapshot did not close: %s" message));
      (match
         Cli_command.import_snapshot
           ~application_support_directory:fixture.support
           ~inbox_entry:"../escape"
       with
       | Error _ -> ()
       | Ok _ -> T.fail "CLI import accepted an escaping inbox path"))
;;

let test_fatal_persistence_is_session_fatal () =
  F.with_snapshot ~fail_mutation_writes:true (fun fixture ->
    let info =
      match
        Cli_command.execute_once
          ~dependencies:F.dependencies
          fixture.config
          (F.graph_info_request ())
      with
      | Ok (P.Succeeded { basis; _ }) -> basis
      | Ok _ -> T.fail "fixture graph info failed"
      | Error _ -> T.fail "fixture graph info terminated"
    in
    let mutation =
      F.create_page_request
        ~basis:info
        ~request_id:"50000000-0000-4000-8000-000000000001"
        ~mutation_id:"50000000-0000-4000-8000-000000000002"
        ~page_uuid:"50000000-0000-4000-8000-000000000003"
        ~title:"Fatal write"
    in
    match
      Cli_command.execute_once ~dependencies:F.dependencies fixture.config mutation
    with
    | Error (Cli_command.Fatal_lifecycle_error _) -> ()
    | Error (Local_decode_error _) -> T.fail "persistence failure was classified as local"
    | Ok _ -> T.fail "persistence failure left the CLI session reusable")
;;

let test_close_failure_is_session_fatal () =
  F.with_snapshot (fun fixture ->
    let replace_owned_sentinel () =
      let path = Filename.concat fixture.resolved.graph_dir "db-worker.lock" in
      let channel = open_out_bin path in
      output_string channel "{}\n";
      close_out channel
    in
    match
      Cli_command.For_testing.execute_once
        ~dependencies:F.dependencies
        ~after_execute:replace_owned_sentinel
        fixture.config
        (F.graph_info_request ())
    with
    | Error (Cli_command.Fatal_lifecycle_error _) -> ()
    | Error (Local_decode_error _) -> T.fail "close failure was classified as local"
    | Ok _ -> T.fail "close failure did not override the successful response")
;;

let test_desktop_graph_is_derived_from_home () =
  F.with_temp_directory "logseq-db-worker-home-" (fun home ->
    let root = Filename.concat home "logseq" in
    Unix.mkdir root 0o700;
    let graph_dir = F.create_oracle_graph root "notes" |> Unix.realpath in
    (match
       Cli_command.resolve_desktop_target ~home_directory:home ~graph_name:"notes"
     with
     | Ok (Logseq_db_worker.Config.Native_local_graph target) ->
       T.require
         (String.equal target.graph_dir graph_dir)
         "Desktop graph path was not ~/logseq/notes"
     | Ok _ -> T.fail "Desktop graph resolved to a non-native target"
     | Error message -> T.fail "Desktop graph resolution failed: %s" message);
    match
      Cli_command.resolve_desktop_target ~home_directory:home ~graph_name:"../escape"
    with
    | Error _ -> ()
    | Ok _ -> T.fail "Desktop graph-name escaped ~/logseq")
;;

let test_exit_contract () =
  let open_error =
    match
      Logseq_db_worker.Error.create
        ~code:Graph_not_found
        ~message:"Graph not found."
        ~details:[]
    with
    | Ok error -> error
    | Error message -> T.fail "%s" message
  in
  let request = F.graph_info_request () in
  let open_response =
    P.failed ~request_id:request.request_id ~phase:Open ~basis:None open_error
  in
  let execute_response =
    P.failed ~request_id:request.request_id ~phase:Execute ~basis:None open_error
  in
  T.require (Cli_output.exit_code Success = 0) "success exit changed";
  T.require (Cli_output.exit_code Local_error = 2) "local error exit changed";
  T.require (Cli_output.exit_code Execute_error = 3) "execute exit changed";
  T.require (Cli_output.exit_code Open_error = 4) "open exit changed";
  T.require (Cli_output.exit_code Fatal_error = 5) "fatal exit changed";
  T.require
    (Cli_output.classify_response open_response = Open_error)
    "open failure classification changed";
  T.require
    (Cli_output.classify_response execute_response = Execute_error)
    "execute failure classification changed"
;;

let test_documented_argument_order_preserves_open_failure () =
  F.with_temp_directory "logseq-db-worker-cli-home-" (fun home ->
    Unix.mkdir (Filename.concat home "logseq") 0o700;
    F.with_temp_directory "logseq-db-worker-cli-support-" (fun support ->
      let previous_home = Sys.getenv_opt "HOME" in
      Unix.putenv "HOME" home;
      Fun.protect
        ~finally:(fun () -> Option.iter (Unix.putenv "HOME") previous_home)
        (fun () ->
           let argv =
             [| "logseq-db-worker"
              ; "--application-support-directory"
              ; support
              ; "--graph-name"
              ; "missing"
              ; "graph"
              ; "info"
              ; "--format"
              ; "json"
             |]
           in
           match Cmdliner.Cmd.eval_value' ~argv Cli_command.command with
           | `Ok code ->
             T.require (code = 4) "missing graph was not classified as an Open failure"
           | `Exit code -> T.fail "documented CLI syntax exited during parsing: %d" code)))
;;

let () =
  T.run
    "CLI"
    [ T.case "CLI and direct Engine traces match" test_direct_and_cli_trace_match
    ; T.case
        "mutation and final state match all transports"
        test_mutation_and_final_state_match_all_transports
    ; T.case
        "open failures retain exact NDJSON protocol"
        test_open_failure_and_exact_ndjson
    ; T.case
        "invalid request is a local decode error"
        test_ndjson_rejects_local_decode_errors
    ; T.case
        "oversized NDJSON is rejected before Engine"
        test_ndjson_rejects_oversized_lines
    ; T.case "snapshot create uses shared Snapshot core" test_snapshot_create_uses_core
    ; T.case
        "snapshot import uses confined Snapshot core"
        test_snapshot_import_uses_confined_core
    ; T.case
        "Desktop graph resolves only under ~/logseq"
        test_desktop_graph_is_derived_from_home
    ; T.case "exit codes are disjoint" test_exit_contract
    ; T.case
        "documented option order preserves Open failures"
        test_documented_argument_order_preserves_open_failure
    ; T.case
        "fatal persistence terminates the CLI session"
        test_fatal_persistence_is_session_fatal
    ; T.case
        "close failure terminates the CLI session"
        test_close_failure_is_session_fatal
    ];
  Worker_runtime.For_testing.final_shutdown ()
;;
