module T = Logseq_db_worker_test_support.Test_support
module F = Logseq_db_worker_test_support.Adapter_fixture
module P = Logseq_db_worker.Protocol
module ID = Bonsai_flutter_spec.Id
module Service = Logseq_db_worker_bonsai.Logseq_db_worker_bonsai_service

let send_graph client request = Worker.send client (Service.Graph_request request)
let send_manager client command = Worker.send client (Service.Manager_command command)
let epoch = ref 2_000L

let next_epoch () =
  let value = !epoch in
  epoch := Int64.succ value;
  ID.Runtime.Epoch.of_int64 value
;;

let start config =
  Worker_runtime.start
    ~runtime_epoch:(next_epoch ())
    (Service.create ~dependencies:F.dependencies)
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

let response_count events =
  List.fold_left
    (fun count -> function
       | Worker.Response _ -> count + 1
       | Push _ | Terminal _ -> count)
    0
    events
;;

let rec drain_until_responses client expected events =
  let events = events @ Worker.For_testing.drain_events client ~max_events:64 in
  if response_count events >= expected
  then events
  else (
    Worker.For_testing.await_output client;
    drain_until_responses client expected events)
;;

let completed_response events request_id =
  List.find_map
    (function
      | Worker.Response
          { request_id = actual
          ; outcome = Completed (Service.Graph_response response)
          ; _
          }
        when ID.Worker.Request_id.equal request_id actual -> Some response
      | Response _ | Push _ | Terminal _ -> None)
    events
  |> function
  | Some response -> response
  | None -> T.fail "missing completed Worker response"
;;

let completed_manager_snapshot events request_id =
  List.find_map
    (function
      | Worker.Response
          { request_id = actual
          ; outcome = Completed (Service.Manager_snapshot snapshot)
          ; _
          }
        when ID.Worker.Request_id.equal request_id actual -> Some snapshot
      | Response _ | Push _ | Terminal _ -> None)
    events
  |> function
  | Some snapshot -> snapshot
  | None -> T.fail "missing completed manager response"
;;

let has_auth_push events =
  List.exists
    (function
      | Worker.Push { payload = Service.Need_id_token _; _ } -> true
      | Push _ | Response _ | Terminal _ -> false)
    events
;;

let await ?(timeout = 10.) description predicate =
  let deadline = Unix.gettimeofday () +. timeout in
  let rec loop () =
    if predicate ()
    then ()
    else if Unix.gettimeofday () >= deadline
    then T.fail "timed out waiting for %s" description
    else (
      Unix.sleepf 0.0005;
      loop ())
  in
  loop ()
;;

let test_serial_service_executes_engine () =
  F.with_snapshot (fun fixture ->
    let client =
      match start fixture.config with
      | Ok client -> client
      | Error error -> T.fail "Worker service failed to start: %s" error
    in
    Fun.protect
      ~finally:(fun () ->
        if (Worker_runtime.For_testing.diagnostics ()).state = Attached then stop client)
      (fun () ->
         let request = F.graph_info_request () in
         let request_id = send_graph client request |> accepted in
         let response =
           completed_response (drain_until_responses client 1 []) request_id
         in
         (match response with
          | P.Succeeded { request_id = actual; success = Graph_info_result _; _ } ->
            T.require
              (Logseq_db_worker.Graph_types.Uuid.equal actual request.request_id)
              "Worker changed the protocol request ID"
          | _ -> T.fail "Worker did not delegate graph info to Engine");
         let diagnostics = Worker_runtime.For_testing.diagnostics () in
         T.require
           (diagnostics.configured_concurrency_limit = Some 1)
           "Logseq Worker service is not Serial";
         stop client))
;;

let test_open_failed_is_protocol_state () =
  F.with_snapshot (fun fixture ->
    let client =
      match start (F.missing_config fixture.support) with
      | Ok client -> client
      | Error error -> T.fail "expected open failure escaped Worker init: %s" error
    in
    Fun.protect
      ~finally:(fun () ->
        if (Worker_runtime.For_testing.diagnostics ()).state = Attached then stop client)
      (fun () ->
         let first = F.graph_info_request () in
         let second =
           F.graph_info_request ~request_id:"10000000-0000-4000-8000-000000000002" ()
         in
         let first_id = send_graph client first |> accepted in
         let second_id = send_graph client second |> accepted in
         let events = drain_until_responses client 2 [] in
         List.iter
           (fun (transport_id, (request : P.request)) ->
              match completed_response events transport_id with
              | P.Failed { request_id; phase = Open; basis = None; _ } ->
                T.require
                  (Logseq_db_worker.Graph_types.Uuid.equal
                     request_id
                     request.P.request_id)
                  "Open_failed response lost request ID"
              | _ -> T.fail "expected graph-open error was not a Protocol.Failed Open")
           [ first_id, first; second_id, second ];
         stop client))
;;

let test_invalid_data_directories_fail_startup () =
  F.with_snapshot (fun fixture ->
    let missing = Filename.concat fixture.support "missing" in
    let regular_file = Filename.concat fixture.support "not-a-directory" in
    let inaccessible = Filename.concat fixture.support "inaccessible" in
    let channel = open_out_bin regular_file in
    close_out channel;
    Unix.mkdir inaccessible 0o700;
    Unix.chmod inaccessible 0o000;
    Fun.protect
      ~finally:(fun () -> Unix.chmod inaccessible 0o700)
      (fun () ->
         List.iter
           (fun path ->
              let config = { fixture.config with application_support_directory = path } in
              match start config with
              | Error _ -> Worker_runtime.For_testing.await_state Worker_runtime.Idle
              | Ok client ->
                Worker_runtime.stop client;
                T.fail "invalid data directory started a Worker session")
           [ "relative/support"; missing; regular_file; inaccessible ]))
;;

let mutation_response events request_id =
  match completed_response events request_id with
  | P.Succeeded { success = Mutation_result result; _ } -> result
  | _ -> T.fail "mutation did not return a mutation result"
;;

let graph_basis client =
  let request_id = send_graph client (F.graph_info_request ()) |> accepted in
  match completed_response (drain_until_responses client 1 []) request_id with
  | P.Succeeded { basis; _ } -> basis
  | _ -> T.fail "graph info did not return a basis"
;;

let drain_mutation_events client request_id =
  let deadline = Unix.gettimeofday () +. 10. in
  let rec loop events =
    let events = events @ Worker.For_testing.drain_events client ~max_events:64 in
    let has_response =
      List.exists
        (function
          | Worker.Response { request_id = actual; _ } ->
            ID.Worker.Request_id.equal request_id actual
          | Push _ | Terminal _ -> false)
        events
    in
    let has_push =
      List.exists
        (function
          | Worker.Push _ -> true
          | Response _ | Terminal _ -> false)
        events
    in
    if has_response && has_push
    then events
    else if Unix.gettimeofday () >= deadline
    then T.fail "timed out waiting for mutation response and invalidation"
    else (
      Unix.sleepf 0.0001;
      loop events)
  in
  loop []
;;

let await_first_output client =
  let deadline = Unix.gettimeofday () +. 10. in
  let rec loop () =
    if Worker.For_testing.pending_output_count client > 0
    then ()
    else if Unix.gettimeofday () >= deadline
    then T.fail "timed out waiting for the first mutation output"
    else (
      Domain.cpu_relax ();
      loop ())
  in
  loop ()
;;

let test_mutation_push_is_bounded_and_after_response () =
  F.with_snapshot (fun fixture ->
    let client =
      match start fixture.config with
      | Ok client -> client
      | Error error -> T.fail "%s" error
    in
    Fun.protect
      ~finally:(fun () ->
        if (Worker_runtime.For_testing.diagnostics ()).state = Attached then stop client)
      (fun () ->
         let info_id = send_graph client (F.graph_info_request ()) |> accepted in
         let info_events = drain_until_responses client 1 [] in
         let basis =
           match completed_response info_events info_id with
           | P.Succeeded { basis; _ } -> basis
           | _ -> T.fail "graph info failed before mutation"
         in
         let basis = ref basis in
         for index = 1 to 32 do
           let request =
             F.create_page_request
               ~basis:!basis
               ~request_id:(Printf.sprintf "20000000-0000-4000-8000-%012d" index)
               ~mutation_id:(Printf.sprintf "30000000-0000-4000-8000-%012d" index)
               ~page_uuid:(Printf.sprintf "40000000-0000-4000-8000-%012d" index)
               ~title:(Printf.sprintf "Worker page %d" index)
           in
           let request_id = send_graph client request |> accepted in
           await_first_output client;
           let events = drain_mutation_events client request_id in
           let result = mutation_response events request_id in
           let indexed = List.mapi (fun event_index event -> event_index, event) events in
           let response_index =
             List.find_map
               (function
                 | event_index, Worker.Response { request_id = actual; _ }
                   when ID.Worker.Request_id.equal request_id actual -> Some event_index
                 | _ -> None)
               indexed
             |> Option.get
           in
           let push_index, push =
             List.find_map
               (function
                 | event_index, Worker.Push { payload = Service.Graph_push payload; _ } ->
                   Some (event_index, payload)
                 | _ -> None)
               indexed
             |> function
             | Some value -> value
             | None -> T.fail "successful mutation emitted no invalidation"
           in
           T.require
             (response_index < push_index)
             "invalidation was visible before its response on iteration %d"
             index;
           let encoded = P.push_to_yojson push |> Yojson.Safe.to_string in
           T.require
             (String.length encoded <= P.maximum_push_bytes)
             "invalidation exceeded the protocol push budget";
           (match push with
            | P.Graph_invalidated invalidation ->
              T.require
                (Int64.equal invalidation.basis result.basis_after)
                "push basis differs from commit";
              T.require
                (invalidation.changed_uuids = result.changed_uuids)
                "push changed UUIDs differ from mutation response");
           basis := result.basis_after
         done;
         stop client))
;;

let test_latest_wins_push_collapse () =
  F.with_snapshot (fun fixture ->
    let client =
      match start fixture.config with
      | Ok client -> client
      | Error error -> T.fail "%s" error
    in
    Fun.protect
      ~finally:(fun () ->
        if (Worker_runtime.For_testing.diagnostics ()).state = Attached then stop client)
      (fun () ->
         let basis = graph_basis client in
         let first =
           F.create_page_request
             ~basis
             ~request_id:"21000000-0000-4000-8000-000000000001"
             ~mutation_id:"31000000-0000-4000-8000-000000000001"
             ~page_uuid:"41000000-0000-4000-8000-000000000001"
             ~title:"First collapsed push"
         in
         let second =
           F.create_page_request
             ~basis:(Int64.succ basis)
             ~request_id:"21000000-0000-4000-8000-000000000002"
             ~mutation_id:"31000000-0000-4000-8000-000000000002"
             ~page_uuid:"41000000-0000-4000-8000-000000000002"
             ~title:"Second collapsed push"
         in
         let first_id = send_graph client first |> accepted in
         let second_id = send_graph client second |> accepted in
         await "both mutation handlers before the foreground pump" (fun () ->
           let diagnostics = Worker_runtime.For_testing.diagnostics () in
           diagnostics.queued_requests = 0
           && diagnostics.active_handlers = 0
           && Worker.For_testing.pending_output_count client >= 3);
         let events = Worker.For_testing.drain_events client ~max_events:64 in
         ignore (mutation_response events first_id : P.mutation_success);
         let second_result = mutation_response events second_id in
         let pushes =
           List.filter_map
             (function
               | Worker.Push { payload = Service.Graph_push payload; _ } -> Some payload
               | Push _ | Response _ | Terminal _ -> None)
             events
         in
         (match pushes with
          | [ P.Graph_invalidated invalidation ] ->
            T.require
              (Int64.equal invalidation.basis second_result.basis_after)
              "latest-wins queue did not retain the newest push"
          | _ ->
            T.fail "one push topic did not collapse to exactly one latest invalidation");
         stop client))
;;

let test_pulled_transaction_emits_invalidation_after_response () =
  F.with_synced (fun fixture ->
    let payload = F.sync_pull_wire fixture ~title:"Worker Synced Page" in
    let client =
      match start fixture.sync_config with
      | Ok client -> client
      | Error error -> T.fail "%s" error
    in
    Fun.protect
      ~finally:(fun () ->
        if (Worker_runtime.For_testing.diagnostics ()).state = Attached then stop client)
      (fun () ->
         let request =
           F.sync_receive_request
             ~request_id:"21500000-0000-4000-8000-000000000001"
             ~transport:P.Websocket
             ~payload
         in
         let request_id = send_graph client request |> accepted in
         let events = drain_mutation_events client request_id in
         let mutation =
           match completed_response events request_id with
           | P.Succeeded
               { success =
                   Sync_result { activity = Pull_applied; mutation = Some value; _ }
               ; _
               } -> value
           | _ -> T.fail "pulled transaction did not return applied sync metadata"
         in
         let indexed = List.mapi (fun index event -> index, event) events in
         let response_index =
           List.find_map
             (function
               | index, Worker.Response { request_id = actual; _ }
                 when ID.Worker.Request_id.equal request_id actual -> Some index
               | _ -> None)
             indexed
           |> Option.get
         in
         let push_index, invalidation =
           List.find_map
             (function
               | ( index
                 , Worker.Push
                     { payload = Service.Graph_push (P.Graph_invalidated value); _ } ) ->
                 Some (index, value)
               | _ -> None)
             indexed
           |> function
           | Some value -> value
           | None -> T.fail "pulled transaction emitted no Graph_invalidated push"
         in
         T.require (response_index < push_index) "sync invalidation preceded its response";
         T.require
           (Int64.equal invalidation.basis mutation.basis_after)
           "sync invalidation basis differs from the atomic commit";
         T.require
           (invalidation.changed_uuids = mutation.changed_uuids)
           "sync invalidation changed UUIDs differ from replay metadata";
         stop client))
;;

let test_client_backpressure_and_pump_boundary () =
  F.with_snapshot (fun fixture ->
    let service = Service.create ~dependencies:F.dependencies in
    let pending_client, _startup =
      Worker.Private.prepare
        ~runtime_epoch:(next_epoch ())
        ~worker_generation:(ID.Worker.Generation.of_int64 1L)
        service
        fixture.config
    in
    T.require
      (send_graph pending_client (F.graph_info_request ()) = Worker.Not_ready)
      "a prepared but unstarted client did not return Not_ready";
    Worker.Private.request_stop pending_client;
    T.require
      (send_graph pending_client (F.graph_info_request ()) = Worker.Stopping)
      "a stopped client did not return Stopping";
    let client =
      match start fixture.config with
      | Ok client -> client
      | Error error -> T.fail "%s" error
    in
    Fun.protect
      ~finally:(fun () ->
        if (Worker_runtime.For_testing.diagnostics ()).state = Attached then stop client)
      (fun () ->
         let observed = ref 0 in
         Worker.on_event client (fun _event ->
           incr observed;
           Bonsai.Effect.return ());
         ignore
           (send_graph client (F.graph_info_request ()) |> accepted
            : ID.Worker.request_id);
         Worker.For_testing.await_output client;
         T.require (!observed = 0) "Worker output crossed the foreground pump boundary";
         let scheduled = ref 0 in
         Worker.Private.drain_to_effects client ~max_events:64 ~schedule:(fun _effect ->
           incr scheduled);
         T.require (!observed = 1) "accepted foreground pump did not expose the response";
         T.require (!scheduled = 1) "foreground pump scheduled the wrong event count";
         let rec fill remaining =
           if remaining = 0
           then false
           else (
             match send_graph client (F.graph_info_request ()) with
             | Full -> true
             | Accepted _ -> fill (remaining - 1)
             | Not_ready | Stopping -> T.fail "ready client changed state while filling")
         in
         T.require (fill 10_000) "bounded Worker queues never returned Full";
         stop client))
;;

let insert_tree_request basis =
  let uuid index = F.uuid (Printf.sprintf "72000000-0000-4000-8000-%012d" index) in
  let children =
    List.init 767 (fun index ->
      P.{ uuid = uuid (index + 1); title = "Cancellation child"; children = [] })
  in
  P.
    { api_version
    ; request_id = F.uuid "22000000-0000-4000-8000-000000000001"
    ; command =
        Mutate
          (Structural
             (Insert_blocks
                { roots = [ { uuid = uuid 0; title = "Cancellation root"; children } ]
                ; position =
                    Relative (Last_child (F.uuid "11111111-1111-4111-8111-111111111111"))
                ; context =
                    { mutation_id = F.uuid "32000000-0000-4000-8000-000000000001"
                    ; expected_basis = basis
                    }
                }))
    }
;;

let wait_for_nonempty_file path =
  let deadline = Unix.gettimeofday () +. 10. in
  let rec loop () =
    let nonempty =
      try (Unix.stat path).Unix.st_size > 0 with
      | Unix.Unix_error _ -> false
    in
    if nonempty
    then ()
    else if Unix.gettimeofday () >= deadline
    then T.fail "timed out waiting for the durable SQLite WAL commit"
    else (
      Unix.sleepf 0.0001;
      loop ())
  in
  loop ()
;;

let test_cancelled_commit_reconciles_by_basis () =
  F.with_snapshot (fun fixture ->
    let client =
      match start fixture.config with
      | Ok client -> client
      | Error error -> T.fail "%s" error
    in
    Fun.protect
      ~finally:(fun () ->
        if (Worker_runtime.For_testing.diagnostics ()).state = Attached then stop client)
      (fun () ->
         let basis = graph_basis client in
         let request = insert_tree_request basis in
         let request_id = send_graph client request |> accepted in
         wait_for_nonempty_file
           (Filename.concat fixture.resolved.graph_dir "db.sqlite-wal");
         Worker.cancel client ~request_id;
         let events = drain_until_responses client 1 [] in
         let outcome =
           List.find_map
             (function
               | Worker.Response { request_id = actual; outcome; _ }
                 when ID.Worker.Request_id.equal actual request_id -> Some outcome
               | Response _ | Push _ | Terminal _ -> None)
             events
         in
         (match outcome with
          | Some Worker.Cancelled -> ()
          | _ -> T.fail "post-commit cancellation did not win transport arbitration");
         let read =
           P.
             { api_version
             ; request_id = F.uuid "22000000-0000-4000-8000-000000000002"
             ; command =
                 Read
                   (Get_block { block = F.uuid "72000000-0000-4000-8000-000000000000" })
             }
         in
         let read_id = send_graph client read |> accepted in
         (match completed_response (drain_until_responses client 1 []) read_id with
          | P.Succeeded { basis = reconciled_basis; success = Block_result _; _ } ->
            T.require
              (reconciled_basis > basis)
              "basis-aware read did not observe the durable commit"
          | _ -> T.fail "basis-aware reconciliation did not find the committed block");
         stop client))
;;

let read_file path =
  let channel = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr channel)
    (fun () -> really_input_string channel (in_channel_length channel))
;;

let test_bonsai_closure_excludes_cmdliner () =
  let dune = read_file (Filename.concat T.root "logseq_db_worker/bonsai/dune") in
  let core = read_file (Filename.concat T.root "logseq_db_worker/lib/dune") in
  let contains haystack needle =
    let length = String.length needle in
    let rec loop index =
      index + length <= String.length haystack
      && (String.equal (String.sub haystack index length) needle || loop (index + 1))
    in
    loop 0
  in
  T.require (not (contains dune "cmdliner")) "Bonsai adapter directly reaches Cmdliner";
  T.require (not (contains core "cmdliner")) "core library reaches Cmdliner"
;;

let test_transport_shutdown_has_one_state_machine_owner () =
  let source =
    read_file
      (Filename.concat
         T.root
         "logseq_db_worker/bonsai/logseq_db_worker_bonsai_service.ml")
  in
  let forbidden = "| Manager.Websocket_closed _ -> close_websocket runtime" in
  let contains haystack needle =
    let length = String.length needle in
    let rec loop index =
      index + length <= String.length haystack
      && (String.equal (String.sub haystack index length) needle || loop (index + 1))
    in
    loop 0
  in
  T.require
    (not (contains source forbidden))
    "the service closes WebSocket before the manager selects a transport action"
;;

let drain_until_terminal client events =
  let deadline = Unix.gettimeofday () +. 10. in
  let rec loop events =
    let events = events @ Worker.For_testing.drain_events client ~max_events:64 in
    if
      List.exists
        (function
          | Worker.Terminal _ -> true
          | Response _ | Push _ -> false)
        events
    then events
    else if Unix.gettimeofday () >= deadline
    then T.fail "timed out waiting for terminal Worker output"
    else (
      Unix.sleepf 0.0005;
      loop events)
  in
  loop events
;;

let fatal_child () =
  F.with_snapshot ~fail_mutation_writes:true (fun fixture ->
    let client =
      match start fixture.config with
      | Ok client -> client
      | Error error -> T.fail "%s" error
    in
    let basis = graph_basis client in
    let request =
      F.create_page_request
        ~basis
        ~request_id:"23000000-0000-4000-8000-000000000001"
        ~mutation_id:"33000000-0000-4000-8000-000000000001"
        ~page_uuid:"43000000-0000-4000-8000-000000000001"
        ~title:"Fatal Worker write"
    in
    ignore (send_graph client request |> accepted : ID.Worker.request_id);
    let events = drain_until_terminal client [] in
    T.require
      (List.exists
         (function
           | Worker.Terminal _ -> true
           | Response _ | Push _ -> false)
         events)
      "fatal persistence did not terminalize the Worker";
    T.require
      (send_graph client (F.graph_info_request ()) = Worker.Stopping)
      "terminal Worker accepted another request");
  Worker_runtime.For_testing.final_shutdown ()
;;

let close_failure_child () =
  F.with_snapshot (fun fixture ->
    let client =
      match start fixture.config with
      | Ok client -> client
      | Error error -> T.fail "%s" error
    in
    let lock = Filename.concat fixture.resolved.graph_dir "db-worker.lock" in
    let channel = open_out_bin lock in
    output_string channel "{}\n";
    close_out channel;
    Worker_runtime.stop client;
    let events = drain_until_terminal client [] in
    T.require
      (List.exists
         (function
           | Worker.Terminal _ -> true
           | Response _ | Push _ -> false)
         events)
      "shutdown close failure emitted no terminal diagnostic");
  Worker_runtime.For_testing.final_shutdown ()
;;

let run_child mode =
  let pid =
    Unix.create_process
      Sys.executable_name
      [| Sys.executable_name; mode |]
      Unix.stdin
      Unix.stdout
      Unix.stderr
  in
  let rec wait () =
    match Unix.waitpid [] pid with
    | result -> result
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> wait ()
  in
  match snd (wait ()) with
  | Unix.WEXITED 0 -> ()
  | WEXITED code -> T.fail "%s child exited %d" mode code
  | WSIGNALED signal | WSTOPPED signal ->
    T.fail "%s child stopped on signal %d" mode signal
;;

let test_encrypted_warm_start_reaches_timeline_without_network_lane () =
  F.with_synced (fun fixture ->
    let base_url = "https://api.logseq.io" in
    let user_id = "user-1" in
    let graph =
      Logseq_db_worker.Sync_catalog.
        { graph_id = fixture.graph_id
        ; name = "Encrypted local graph"
        ; schema = { major = 65; minor = 33; exact = true }
        ; encrypted = true
        }
    in
    let cache =
      Logseq_db_worker.Sync_catalog.create_cache
        ~user_id
        ~base_url
        ~graphs:[ graph ]
        ~selected_graph:(Some fixture.graph_id)
    in
    (match
       Logseq_db_worker.Sync_catalog_store.save
         ~application_support_directory:fixture.sync_support
         cache
     with
     | Ok () -> ()
     | Error message -> T.fail "unable to save encrypted catalog fixture: %s" message);
    let wrapped = {|["~#'","~bZ3JhcGgta2V5"]|} in
    let local_loads = ref 0 in
    let local_secrets =
      Service.
        { load_and_verify_wrapped_graph_key =
            (fun ~managed_sync_origin ~user_id:actual_user ~graph_id ->
              incr local_loads;
              T.require
                (Uri.to_string managed_sync_origin = base_url)
                "wrapped-key lookup changed the managed sync origin";
              T.require
                (String.equal actual_user user_id)
                "wrapped-key lookup changed the user scope";
              T.require
                (Logseq_db_worker.Graph_types.Uuid.equal graph_id fixture.graph_id)
                "wrapped-key lookup changed the graph scope";
              Ok wrapped)
        ; verify_and_save_wrapped_graph_key =
            (fun ~managed_sync_origin:_ ~user_id:_ ~graph_id:_ ~encrypted_graph_key:_ ->
              T.fail "offline cache hit attempted a wrapped-key save")
        ; delete_wrapped_graph_key =
            (fun ~managed_sync_origin:_ ~user_id:_ ~graph_id:_ -> Ok ())
        ; delete_account_secrets =
            (fun ~managed_sync_origin:_ ~user_id:_ -> Ok ())
        }
    in
    let dependencies =
      { F.dependencies with
        unlock_graph_key =
          (fun ~managed_sync_origin ~user_id:actual_user ~encrypted_graph_key ->
            T.require
              (Uri.to_string managed_sync_origin = base_url)
              "Engine unwrap changed the managed sync origin";
            T.require
              (String.equal actual_user user_id && String.equal encrypted_graph_key wrapped)
              "Engine unwrap changed the verified wrapped-key scope";
            Logseq_db_worker.Sync_graph_key.of_string (String.make 32 'g'))
      }
    in
    let config =
      match
        Logseq_db_worker.Config.create
          ~application_support_directory:fixture.sync_support
          ~target:(Managed_sync { base_url })
          ~compatibility_profile:Logseq_65_33_or_newer
          ~response_budget_bytes:Logseq_db_worker.Protocol.maximum_response_bytes
          ~default_page_size:Logseq_db_worker.Protocol.default_page_size
      with
      | Ok config -> config
      | Error message -> T.fail "invalid managed encrypted fixture: %s" message
    in
    let client =
      match
        Worker_runtime.start
          ~runtime_epoch:(next_epoch ())
          (Service.create_with_local_secrets ~local_secrets ~dependencies)
          config
      with
      | Ok client -> client
      | Error message -> T.fail "encrypted service failed to start: %s" message
    in
    Fun.protect
      ~finally:(fun () ->
        if (Worker_runtime.For_testing.diagnostics ()).state = Attached
        then Worker.Private.request_stop client)
      (fun () ->
         let restore_id =
           send_manager
             client
             (Restore_local_account { user_id; managed_sync_origin = base_url })
           |> accepted
         in
         let pre_timeline_events = drain_until_responses client 1 [] in
         let snapshot = completed_manager_snapshot pre_timeline_events restore_id in
         T.require (!local_loads = 1) "encrypted warm start skipped local key verification";
         T.require
           (snapshot.applied_server_t = Some 40)
           "encrypted warm start did not open the retained mirror";
         T.require
           (not (has_auth_push pre_timeline_events))
           "encrypted warm start entered the network lane before Timeline";
         let feed_id =
           send_manager
             client
             (Local_feed_ready
                { account_generation = snapshot.account_generation
                ; graph_generation = snapshot.graph_generation
                ; presentation_generation = snapshot.presentation_generation
                })
           |> accepted
         in
         ignore (drain_until_responses client 1 [] |> fun events ->
           completed_manager_snapshot events feed_id);
         let timeline_id =
           send_manager
             client
             (Timeline_presented
                { account_generation = snapshot.account_generation
                ; graph_generation = snapshot.graph_generation
                ; presentation_generation = snapshot.presentation_generation
                })
           |> accepted
         in
         let post_timeline_events = drain_until_responses client 1 [] in
         ignore (completed_manager_snapshot post_timeline_events timeline_id);
         T.require
           (has_auth_push post_timeline_events)
           "Timeline presentation did not release network reconciliation";
         Unix.sleepf 0.05;
         let fence_id =
           send_manager client (Backgrounded { lifecycle_generation = 1L }) |> accepted
         in
         ignore (drain_until_responses client 1 [] |> fun events ->
           completed_manager_snapshot events fence_id);
         Worker.Private.request_stop client;
         await
           ~timeout:2.
           "encrypted worker shutdown"
           (fun () -> (Worker_runtime.For_testing.diagnostics ()).state = Idle)))
;;

let () =
  if Array.length Sys.argv > 1 && String.equal Sys.argv.(1) "--fatal-child"
  then fatal_child ()
  else if Array.length Sys.argv > 1 && String.equal Sys.argv.(1) "--close-failure-child"
  then close_failure_child ()
  else if Array.length Sys.argv > 1 && String.equal Sys.argv.(1) "--encrypted-warm-start"
  then test_encrypted_warm_start_reaches_timeline_without_network_lane ()
  else (
    T.run
      "bonsai service"
      [ T.case "Serial service delegates to Engine" test_serial_service_executes_engine
      ; T.case
          "expected graph open error returns Protocol.Failed"
          test_open_failed_is_protocol_state
      ; T.case
          "invalid data directory becomes Session_startup_failed"
          test_invalid_data_directories_fail_startup
      ; T.case
          "mutation response precedes bounded push"
          test_mutation_push_is_bounded_and_after_response
      ; T.case "latest-wins invalidations collapse" test_latest_wins_push_collapse
      ; T.case
          "pulled transaction response precedes Graph_invalidated"
          test_pulled_transaction_emits_invalidation_after_response
      ; T.case
          "Full Not_ready Stopping and pump boundary are preserved"
          test_client_backpressure_and_pump_boundary
      ; T.case
          "cancelled durable commit reconciles by basis"
          test_cancelled_commit_reconciles_by_basis
      ; T.case "Bonsai closure excludes Cmdliner" test_bonsai_closure_excludes_cmdliner
      ; T.case
          "manager exclusively owns transport shutdown"
          test_transport_shutdown_has_one_state_machine_owner
      ; T.case
          "encrypted warm start reaches Timeline before network lane"
          test_encrypted_warm_start_reaches_timeline_without_network_lane
      ];
    Worker_runtime.For_testing.final_shutdown ();
    run_child "--fatal-child";
    run_child "--close-failure-child")
;;
