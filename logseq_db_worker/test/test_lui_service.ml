module T = Logseq_db_worker_test_support.Test_support
module P = Logseq_db_worker.Protocol
module ID = Logseq_db_worker_lui.Journal_worker_ids
module Service = Logseq_db_worker_lui.Logseq_db_worker_lui_service
module Runner = Logseq_sync_effect_runner.Effect_runner
module Worker = Logseq_db_worker_lui.Journal_worker
module Worker_runtime = Logseq_db_worker_lui.Journal_worker_runtime

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

module Mailbox = Logseq_db_worker_lui.Journal_bounded_mailbox.Coalesced
module Transfer = Logseq_sync_pure_reducer.Asset_transfer

let asset_scope generation : Service.asset_scope =
  { account =
      { managed_sync_origin = Uri.of_string "https://api.logseq.io"
      ; user_id = "fixture-user"
      ; account_generation = 1
      ; presentation_generation = 1
      ; lifecycle_generation = 1L
      }
  ; graph_id =
      Logseq_db_types.Graph_types.Uuid.of_string "00000000-0000-4000-8000-999999999999"
      |> Result.get_ok
  ; graph_generation = generation
  }
;;

let asset_uuid suffix =
  Logseq_db_types.Graph_types.Uuid.of_string
    (Printf.sprintf "00000000-0000-4000-8000-%012d" suffix)
  |> Result.get_ok
;;

let availability scope consumer asset state =
  Service.Asset_notice
    (scope, Asset_availability { consumer; asset; availability = state })
;;

let collect_asset_burst pushes =
  let mailbox = Mailbox.create ~capacity:6 in
  List.iter
    (fun push ->
       ignore
         (Mailbox.push
            ~merge:(Service.coalesce_push ~topic:(ID.Worker.Push_topic.of_int 5))
            mailbox
            ~topic:5
            push))
    pushes;
  Mailbox.drain mailbox ~max_items:6
  |> List.concat_map (fun (_, push) -> Service.asset_notices push)
;;

let test_ready_survives_acceptance () =
  let scope = asset_scope 1 in
  let ready = availability scope "visible" (asset_uuid 1) (Ready "cached") in
  let accepted = Service.Asset_notice (scope, Asset_demand_accepted "visible") in
  T.require
    (collect_asset_burst [ ready; accepted ]
     = [ ( scope
         , Asset_availability
             { consumer = "visible"; asset = asset_uuid 1; availability = Ready "cached" }
         )
       ; scope, Asset_demand_accepted "visible"
       ])
    "Ready must survive demand acceptance in the same asset topic"
;;

let test_assets_consumers_and_scopes_survive () =
  let scope = asset_scope 1 in
  let next_scope = asset_scope 2 in
  let pushes =
    [ availability scope "a" (asset_uuid 1) (Ready "first")
    ; availability scope "a" (asset_uuid 2) (Ready "second")
    ; availability scope "b" (asset_uuid 1) (Ready "shared")
    ; availability next_scope "a" (asset_uuid 1) (Ready "new-graph")
    ; Service.Asset_notice (scope, Asset_capacity_available)
    ]
  in
  T.require
    (List.length (collect_asset_burst pushes) = 5)
    "Distinct assets, consumers, graph scopes and capacity must not overwrite each other"
;;

let test_retry_keeps_latest_fact_in_arrival_order () =
  let scope = asset_scope 1 in
  let asset = asset_uuid 1 in
  let failed =
    Transfer.Failed { failure = Not_found; attempts = 1; retry_scheduled = false }
  in
  let collected =
    collect_asset_burst
      [ availability scope "a" asset failed
      ; Service.Asset_notice (scope, Asset_backpressure "a")
      ; availability scope "a" asset Queued
      ; availability scope "a" asset (Ready "retried")
      ; Service.Asset_notice (scope, Asset_demand_accepted "a")
      ]
  in
  T.require
    (collected
     = [ ( scope
         , Asset_availability { consumer = "a"; asset; availability = Ready "retried" } )
       ; scope, Asset_demand_accepted "a"
       ])
    "Retry should replace only the same fact, keeping Ready and latest admission ordered"
;;

let test_uploads_do_not_erase_downloads () =
  let scope = asset_scope 1 in
  let upload operation status =
    Service.Asset_notice
      ( scope
      , Upload_status
          { operation = asset_uuid operation
          ; asset = asset_uuid 1
          ; target = asset_uuid 3
          ; title = "Fixture upload"
          ; status
          } )
  in
  let result =
    collect_asset_burst
      [ availability scope "a" (asset_uuid 1) (Ready "download")
      ; upload 10 Preparing
      ; upload 11 Sending
      ; upload 10 Uploaded
      ]
  in
  T.require
    (List.length result = 3)
    "Upload operations and download availability must retain independent latest facts"
;;

let test_pending_asset_facts_have_hard_bound () =
  let scope = asset_scope 1 in
  let pushes =
    List.init 4097 (fun index ->
      availability scope (string_of_int index) (asset_uuid 1) Queued)
  in
  let exhausted =
    try
      ignore (collect_asset_burst pushes);
      false
    with
    | Failure message -> message = "Worker pending asset fact limit exceeded"
  in
  T.require
    exhausted
    "Asset burst overflow must fail explicitly instead of dropping facts"
;;

let test_snapshot_topics_still_replace () =
  let mailbox = Mailbox.create ~capacity:1 in
  ignore (Mailbox.push mailbox ~topic:0 1);
  ignore (Mailbox.push mailbox ~topic:0 2);
  T.require
    (Mailbox.drain mailbox ~max_items:1 = [ 0, 2 ])
    "Ordinary snapshot topics should retain their latest value"
;;

(* No pure DB/Core reducer owns Worker admission, tickets or handler permits.
   These public Service/client tests exercise only that scheduling boundary. *)
let control_wait label predicate =
  let deadline = Unix.gettimeofday () +. 2. in
  while (not (predicate ())) && Unix.gettimeofday () < deadline do
    Unix.sleepf 0.001
  done;
  T.require (predicate ()) label
;;

type control_request =
  | Data of int
  | Reply of Worker.control_ticket * int
  | Latest of int
  | Crash of Worker.control_ticket

let control_fixture ?(fail_init = false) () =
  let ticket = Atomic.make None in
  let replies = Atomic.make 0
  and latest = Atomic.make (-1) in
  let control_count = Atomic.make 0 in
  let service =
    Worker.Service.create
      ~push_topic_count:1
      ~control_topic_count:2
      ~concurrency:(Worker.Service.Concurrent { max_in_flight = 2 })
      ~classify_control:(function
        | Reply (ticket, _) | Crash ticket -> Some (Worker.Reply ticket)
        | Latest value ->
          Some
            (Worker.Latest { topic = 1; key = string_of_int value; invalidates = None })
        | Data _ -> None)
      ~init:(fun context () ->
        Atomic.set ticket (Worker.Session_context.issue_control context ~topic:0);
        if fail_init then Error "controlled startup error" else Ok (Eio.Promise.create ()))
      ~handle:(fun _ (gate, _) -> function
         | Data value ->
           Eio.Promise.await gate;
           Ok value
         | Latest value ->
           T.require
             (Atomic.get latest >= value)
             "data waits for its latest control version";
           Ok value
         | Reply _ | Crash _ -> Error "control must use the control API")
      ~handle_control:(fun (_, resolve) -> function
         | Reply (_, _) ->
           Atomic.incr replies;
           Atomic.incr control_count;
           ignore (Eio.Promise.try_resolve resolve () : bool)
         | Latest value ->
           Atomic.set latest value;
           Atomic.incr control_count
         | Crash _ -> failwith "controlled control failure"
         | Data _ -> invalid_arg "data is not a short control")
      ~shutdown:(fun (_, resolve) -> ignore (Eio.Promise.try_resolve resolve () : bool))
      ()
  in
  service, ticket, replies, latest, control_count
;;

let with_control_fixture run =
  let service, ticket, replies, latest, control_count = control_fixture () in
  let client =
    Worker_runtime.start ~runtime_epoch:(ID.Runtime.Epoch.of_int64 2200L) service ()
    |> Result.get_ok
  in
  Fun.protect
    ~finally:(fun () -> Worker_runtime.stop client)
    (fun () -> run client (Option.get (Atomic.get ticket)) replies latest control_count)
;;

let test_control_bypasses_full_data_and_waiting_handlers () =
  with_control_fixture (fun client ticket replies _ _ ->
    let ids = List.init 32 (fun i -> Worker.send client (Data i) |> accepted) in
    control_wait "all data permits are occupied" (fun () ->
      let metrics = Worker.Private.metrics (Worker.Private.pack_client client) in
      metrics.active_handlers = 2 && metrics.waiting_request_fibers = 30);
    T.require
      (Worker.send client (Data 32) = Worker.Full)
      "data backpressure remains Full";
    T.require
      (Worker.send_control client (Reply (ticket, 1)) = Worker.Control_accepted)
      "reply bypasses all data capacity";
    control_wait "reply executes without a data permit" (fun () -> Atomic.get replies = 1);
    for _ = 1 to 10000 do
      T.require
        (Worker.send_control client (Reply (ticket, 2)) = Worker.Control_duplicate)
        "duplicate reply is not queued"
    done;
    T.require
      (Worker.For_testing.pending_control_count client <= 2)
      "control storage is bounded";
    control_wait "all data responds without draining first" (fun () ->
      Worker.For_testing.pending_output_count client = 32);
    T.require
      (Worker.send client (Data 33) = Worker.Full)
      "control did not steal or enlarge data reservations";
    let events = Worker.For_testing.drain_events client ~max_events:64 in
    let completed =
      List.filter_map
        (function
          | Worker.Response { request_id; outcome = Completed value; _ } ->
            Some (request_id, value)
          | _ -> None)
        events
    in
    T.require (List.length completed = 32) "every accepted data request completes once";
    List.iteri
      (fun i id ->
         T.require (List.mem (id, i) completed) "ordinary response identities survive")
      ids;
    T.require (Atomic.get replies = 1) "first answer wins")
;;

let test_control_client_epoch_and_stop () =
  let old_ticket = ref None
  and old_client = ref None in
  with_control_fixture (fun client ticket _ _ _ ->
    old_ticket := Some ticket;
    old_client := Some client);
  T.require
    (Worker.send_control (Option.get !old_client) (Reply (Option.get !old_ticket, 1))
     = Worker.Control_stopping)
    "old stopped session cannot accept control";
  with_control_fixture (fun client ticket replies _ _ ->
    T.require
      (Worker.send_control client (Reply (Option.get !old_ticket, 1))
       = Worker.Control_stale)
      "same runtime epoch does not transfer a capability";
    T.require
      (Worker.send_control client (Reply (ticket, 1)) = Worker.Control_accepted)
      "fresh session accepts its own reply";
    control_wait "fresh reply applied" (fun () -> Atomic.get replies = 1);
    Worker.Private.request_stop client;
    T.require
      (Worker.For_testing.pending_control_count client = 0)
      "stop clears all retained controls";
    T.require
      (Worker.send_control client (Latest 5) = Worker.Control_stopping)
      "stop has priority over control traffic")
;;

let test_control_cancel_and_failure () =
  with_control_fixture (fun client ticket _ _ _ ->
    let cancelled = Worker.send client (Data 1) |> accepted in
    let blocked = Worker.send client (Data 2) |> accepted in
    control_wait "both handlers wait" (fun () ->
      (Worker.Private.metrics (Worker.Private.pack_client client)).active_handlers = 2);
    Worker.cancel client ~request_id:cancelled;
    let outcomes = ref [] in
    control_wait "cancel bypasses handler saturation" (fun () ->
      outcomes := Worker.For_testing.drain_events client ~max_events:64 @ !outcomes;
      List.exists
        (function
          | Worker.Response { request_id; outcome = Cancelled; _ } ->
            request_id = cancelled
          | _ -> false)
        !outcomes);
    T.require
      (Worker.send_control client (Reply (ticket, 1)) = Worker.Control_accepted)
      "control survives a data cancellation";
    control_wait "other data completes" (fun () ->
      outcomes := Worker.For_testing.drain_events client ~max_events:64 @ !outcomes;
      List.exists
        (function
          | Worker.Response { request_id; outcome = Completed 2; _ } ->
            request_id = blocked
          | _ -> false)
        !outcomes));
  with_control_fixture (fun client ticket _ _ _ ->
    ignore (Worker.send client (Data 1) |> accepted);
    T.require
      (Worker.send_control client (Crash ticket) = Worker.Control_accepted)
      "control exception is exercised";
    let terminal = ref false in
    control_wait "control exception reaches terminal" (fun () ->
      List.iter
        (function
          | Worker.Terminal _ -> terminal := true
          | _ -> ())
        (Worker.For_testing.drain_events client ~max_events:64);
      !terminal);
    T.require
      (Worker.For_testing.pending_control_count client = 0)
      "terminal clears control payloads");
  let service, _, _, _, _ = control_fixture ~fail_init:true () in
  let client, _ =
    Worker.Private.prepare
      ~runtime_epoch:(ID.Runtime.Epoch.of_int64 2201L)
      ~worker_generation:(ID.Worker.Generation.of_int64 1L)
      service
      ()
  in
  T.require
    (Worker.send_control client (Latest 1) = Worker.Control_not_ready)
    "starting state admits no control";
  Worker.Private.request_stop client;
  T.require
    (Worker.For_testing.pending_control_count client = 0)
    "startup cancellation has no retained payload";
  T.require
    (Result.is_error
       (Worker_runtime.start ~runtime_epoch:(ID.Runtime.Epoch.of_int64 2202L) service ()))
    "startup failure returns an error"
;;

let test_control_pressure_is_bounded_and_fair () =
  with_control_fixture (fun client ticket _ latest count ->
    ignore (Worker.send_control client (Reply (ticket, 1)));
    let completed = ref 0
    and accepted_data = ref 0 in
    for i = 1 to 5000 do
      ignore (Worker.send_control client (Latest i));
      let request = if i mod 8 = 0 then Latest i else Data i in
      (match Worker.send client request with
       | Accepted _ -> incr accepted_data
       | Full -> ()
       | _ -> T.fail "worker unexpectedly stopped");
      List.iter
        (function
          | Worker.Response { outcome = Completed _; _ } -> incr completed
          | _ -> ())
        (Worker.For_testing.drain_events client ~max_events:64);
      T.require
        (Worker.For_testing.pending_control_count client <= 2)
        "fixed control capacity under producer pressure";
      if i mod 32 = 0 then Unix.sleepf 0.0001
    done;
    T.require (!completed > 0) "data makes progress while control production continues";
    control_wait "final latest control state is applied" (fun () ->
      Atomic.get latest = 5000);
    control_wait "all accepted data drains" (fun () ->
      List.iter
        (function
          | Worker.Response { outcome = Completed _; _ } -> incr completed
          | _ -> ())
        (Worker.For_testing.drain_events client ~max_events:64);
      !completed = !accepted_data);
    T.require (Atomic.get count <= 5001) "no extra or duplicated control execution")
;;

(* A serial data handler keeps FIFO order while a mirrored control version is
   pending. The existing scheduler hook bounds the pause for cancellation tests. *)
let test_control_barrier ~ending () =
  let applied = Atomic.make (-1)
  and handled = Atomic.make []
  and ready = Atomic.make false
  and start = Atomic.make false
  and paused = Atomic.make false
  and resume = Atomic.make false
  and finished = Atomic.make false in
  let service =
    Worker.Service.create
      ~push_topic_count:1
      ~control_topic_count:5
      ~concurrency:Worker.Service.Serial
      ~classify_control:(function
        | Latest value ->
          Some (Worker.Latest { topic = value; key = "state"; invalidates = None })
        | Data _ | Reply _ | Crash _ -> None)
      ~init:(fun _ () -> Ok ())
      ~handle:(fun _ () -> function
         | Latest value | Data value ->
           Atomic.set handled (value :: Atomic.get handled);
           Ok value
         | _ -> Error "unexpected request")
      ~handle_control:(fun () -> function
         | Latest 4 when ending = `Failure -> failwith "barrier control failure"
         | Latest value -> Atomic.set applied value
         | _ -> failwith "unexpected control")
      ~shutdown:(fun () -> ())
      ()
  in
  let client, startup =
    Worker.Private.prepare
      ~runtime_epoch:(ID.Runtime.Epoch.of_int64 2250L)
      ~worker_generation:(ID.Worker.Generation.of_int64 1L)
      service
      ()
  in
  let worker =
    Domain.spawn (fun () ->
      let result =
        Logseq_db_worker_lui.Journal_worker_eio_backend.run (fun environment ->
          Eio.Switch.run (fun session_switch ->
            Worker.Private.run_session
              startup
              ~environment
              ~session_switch
              ~on_startup:(fun result ->
                T.require (Result.is_ok result) "barrier service started";
                Atomic.set ready true;
                control_wait "release barrier startup" (fun () -> Atomic.get start))
              ~on_idle_wait:(fun () -> ())
              ~on_yield:(fun () ->
                if
                  ending <> `Complete
                  && Atomic.get applied = 3
                  && (Worker.Private.metrics (Worker.Private.pack_client client))
                       .active_handlers
                     = 1
                then (
                  Atomic.set paused true;
                  control_wait "release barrier scheduler pause" (fun () ->
                    Atomic.get resume)))))
      in
      Atomic.set finished true;
      result)
  in
  Fun.protect
    ~finally:(fun () ->
      Atomic.set start true;
      Atomic.set resume true;
      Worker.Private.request_stop client;
      ignore (Domain.join worker))
    (fun () ->
       control_wait "barrier host ready" (fun () -> Atomic.get ready);
       for topic = 0 to 3 do
         T.require
           (Worker.send_control client (Latest topic) = Worker.Control_accepted)
           "preceding controls accepted"
       done;
       let first = Worker.send client (Latest 4) |> accepted in
       let second = Worker.send client (Data 5) |> accepted in
       Atomic.set start true;
       if ending <> `Complete
       then (
         control_wait "serial permit waits for control version" (fun () ->
           Atomic.get paused);
         T.require (Atomic.get handled = []) "no data handler bypasses the barrier";
         (match ending with
          | `Cancel -> Worker.cancel client ~request_id:first
          | `Stop -> Worker.Private.request_stop client
          | `Failure | `Complete -> ());
         Atomic.set resume true);
       let events = ref [] in
       control_wait "barrier produces both terminal request outcomes" (fun () ->
         events := Worker.For_testing.drain_events client ~max_events:64 @ !events;
         List.length
           (List.filter
              (function
                | Worker.Response _ -> true
                | _ -> false)
              !events)
         = 2);
       let has id outcome =
         List.exists
           (function
             | Worker.Response { request_id; outcome = actual; _ } ->
               request_id = id && actual = outcome
             | _ -> false)
           !events
       in
       match ending with
       | `Complete ->
         T.require
           (Atomic.get handled = [ 5; 4 ])
           "serial data order survives control wait";
         T.require
           (has first (Worker.Completed 4) && has second (Worker.Completed 5))
           "both data requests complete"
       | `Cancel ->
         T.require
           (has first Worker.Cancelled && has second (Worker.Completed 5))
           "cancel releases the serial permit and later data progresses";
         T.require (Atomic.get handled = [ 5 ]) "cancelled barrier never invokes handler"
       | `Stop | `Failure ->
         T.require
           (has first Worker.Shutdown && has second Worker.Shutdown)
           "shutdown releases both waiting data requests";
         T.require (Atomic.get handled = []) "shutdown never invokes a data handler";
         if ending = `Failure
         then
           control_wait "barrier failure reaches terminal" (fun () ->
             events := Worker.For_testing.drain_events client ~max_events:64 @ !events;
             List.exists
               (function
                 | Worker.Terminal _ -> true
                 | _ -> false)
               !events);
         control_wait "barrier session exits" (fun () -> Atomic.get finished);
         T.require
           ((Worker.Private.metrics (Worker.Private.pack_client client)).active_handlers
            = 0)
           "shutdown releases handler permits";
         T.require
           (Worker.For_testing.pending_control_count client = 0)
           "barrier shutdown clears control state")
;;

(* Worker owns dequeue/claim and invalidation scheduling; no pure reducer owns
   these transitions. Use its declared Private host hook and Service interface. *)
let with_review_host service ~on_control_taken run =
  let client, startup =
    Worker.Private.prepare
      ~runtime_epoch:(ID.Runtime.Epoch.of_int64 2400L)
      ~worker_generation:(ID.Worker.Generation.of_int64 1L)
      service
      ()
  in
  let ready = Atomic.make false
  and start = Atomic.make false in
  let worker =
    Domain.spawn (fun () ->
      Logseq_db_worker_lui.Journal_worker_eio_backend.run (fun environment ->
        Eio.Switch.run (fun session_switch ->
          Worker.Private.run_session
            ~on_control_taken:(fun () -> on_control_taken client)
            startup
            ~environment
            ~session_switch
            ~on_startup:(fun result ->
              T.require (Result.is_ok result) "review host ready";
              Atomic.set ready true;
              control_wait "release review startup" (fun () -> Atomic.get start))
            ~on_idle_wait:(fun () -> ())
            ~on_yield:(fun () -> ()))))
  in
  Fun.protect
    ~finally:(fun () ->
      Atomic.set start true;
      Worker.Private.request_stop client;
      ignore (Domain.join worker))
    (fun () ->
       control_wait "review startup observed" (fun () -> Atomic.get ready);
       run client (fun () -> Atomic.set start true))
;;

let test_extracted_reply_revalidation ~change () =
  let context = Atomic.make None
  and ticket = Atomic.make None in
  let paused = Atomic.make false
  and resume = Atomic.make false
  and replies = Atomic.make 0
  and auths = Atomic.make 0 in
  let service =
    Worker.Service.create
      ~push_topic_count:1
      ~control_topic_count:2
      ~concurrency:Worker.Service.Serial
      ~classify_control:(function
        | Reply (ticket, _) -> Some (Worker.Reply ticket)
        | Latest value ->
          Some
            (Worker.Latest { topic = 1; key = string_of_int value; invalidates = Some 0 })
        | _ -> None)
      ~init:(fun ctx () ->
        Atomic.set context (Some ctx);
        Atomic.set ticket (Worker.Session_context.issue_control ctx ~topic:0);
        Ok ())
      ~handle:(fun _ () -> function
         | Data value -> Ok value
         | _ -> Error "unexpected data")
      ~handle_control:(fun () -> function
         | Reply _ -> Atomic.incr replies
         | Latest _ -> Atomic.incr auths
         | _ -> failwith "unexpected control")
      ~shutdown:(fun () -> ())
      ()
  in
  Fun.protect
    ~finally:(fun () -> Atomic.set resume true)
    (fun () ->
       with_review_host
         service
         ~on_control_taken:(fun _ ->
           if not (Atomic.get paused)
           then (
             Atomic.set paused true;
             control_wait "release extracted reply" (fun () -> Atomic.get resume)))
         (fun client start ->
            T.require
              (Worker.send_control client (Reply (Option.get (Atomic.get ticket), 1))
               = Worker.Control_accepted)
              "first reply accepted";
            start ();
            control_wait "reply extracted before claim" (fun () -> Atomic.get paused);
            (match change with
             | `Auth ->
               T.require
                 (Worker.send_control client (Latest 1) = Worker.Control_accepted)
                 "authentication revokes extracted reply"
             | `Stop -> Worker.Private.request_stop client
             | `Replacement ->
               T.require
                 (Option.is_some
                    (Worker.Session_context.issue_control
                       (Option.get (Atomic.get context))
                       ~topic:0))
                 "new ticket replaces extracted reply");
            Atomic.set resume true;
            if change = `Auth
            then control_wait "auth applied" (fun () -> Atomic.get auths = 1)
            else if change = `Replacement
            then ignore (Worker.send client (Data 1) |> accepted |> await_response client);
            Worker.Private.request_stop client;
            Worker.Private.await_stopped client;
            T.require
              (Atomic.get replies = 0)
              "revoked extracted reply never invokes callback"))
;;

let test_all_invalidators_block_reply ?(second_topic = 2) ~newer () =
  let context = Atomic.make None
  and callbacks = Atomic.make 0
  and premature = Atomic.make false
  and fresh = Atomic.make false in
  let client_ref = Atomic.make None in
  let service =
    Worker.Service.create
      ~push_topic_count:1
      ~control_topic_count:(second_topic + 1)
      ~concurrency:Worker.Service.Serial
      ~classify_control:(function
        | Latest value ->
          Some
            (Worker.Latest
               { topic = (if value = 2 then second_topic else 1)
               ; key = string_of_int value
               ; invalidates = Some 0
               })
        | _ -> None)
      ~init:(fun ctx () ->
        Atomic.set context (Some ctx);
        ignore (Worker.Session_context.issue_control ctx ~topic:0);
        Ok ())
      ~handle:(fun _ () _ ->
        Atomic.set
          fresh
          (Option.is_some
             (Worker.Session_context.issue_control
                (Option.get (Atomic.get context))
                ~topic:0));
        Ok 1)
      ~handle_control:(fun () -> function
         | Latest value ->
           if value = 1 && newer
           then
             T.require
               (Worker.send_control (Option.get (Atomic.get client_ref)) (Latest 11)
                = Worker.Control_accepted)
               "newer version stages during old callback";
           if value = 2 || value = 11
           then
             if
               Option.is_some
                 (Worker.Session_context.issue_control
                    (Option.get (Atomic.get context))
                    ~topic:0)
             then Atomic.set premature true;
           Atomic.incr callbacks
         | _ -> failwith "unexpected control")
      ~shutdown:(fun () -> ())
      ()
  in
  with_review_host
    service
    ~on_control_taken:(fun _ -> ())
    (fun client start ->
       Atomic.set client_ref (Some client);
       T.require
         (Worker.send_control client (Latest 2) = Worker.Control_accepted)
         "second topic stages first";
       T.require
         (Worker.send_control client (Latest 1) = Worker.Control_accepted)
         "first topic stages last";
       start ();
       control_wait "all invalidators applied" (fun () ->
         Atomic.get callbacks = if newer then 3 else 2);
       T.require
         (not (Atomic.get premature))
         "every pending invalidator blocks issuing a reply";
       ignore (Worker.send client (Data 0) |> accepted |> await_response client);
       T.require
         (Atomic.get fresh)
         "all invalidators finish and fresh ticket is available")
;;

(* Pause the actual Worker coordinator through its existing public private-host
   scheduler hook. No production callback is blocked or implementation copied. *)
let test_real_auth_control ~transition () =
  T.with_managed (fun fixture ->
    let service = Service.create ~dependencies in
    let client, startup =
      Worker.Private.prepare
        ~runtime_epoch:(ID.Runtime.Epoch.of_int64 2300L)
        ~worker_generation:(ID.Worker.Generation.of_int64 1L)
        service
        fixture.config
    in
    let ready = Atomic.make false
    and pause = Atomic.make false
    and paused = Atomic.make false in
    let worker =
      Domain.spawn (fun () ->
        Logseq_db_worker_lui.Journal_worker_eio_backend.run (fun environment ->
          Eio.Switch.run (fun session_switch ->
            Worker.Private.run_session
              startup
              ~environment
              ~session_switch
              ~on_startup:(fun result ->
                T.require (Result.is_ok result) "real service started";
                Atomic.set ready true)
              ~on_idle_wait:(fun () ->
                if Atomic.get pause
                then (
                  Atomic.set paused true;
                  control_wait "test scheduler pause released" (fun () ->
                    not (Atomic.get pause));
                  Atomic.set paused false))
              ~on_yield:(fun () -> ()))))
    in
    Fun.protect
      ~finally:(fun () ->
        Atomic.set pause false;
        Worker.Private.request_stop client;
        ignore (Domain.join worker))
      (fun () ->
         control_wait "host sees ready" (fun () -> Atomic.get ready);
         ignore
           (Worker.send
              client
              (Service.Client_command (Restore_local_account { user_id = "auth-A" }))
            |> accepted);
         ignore
           (Worker.send
              client
              (Service.Client_command
                 (Reconcile_authenticated_user { user_id = Some "auth-A" }))
            |> accepted);
         let challenge = ref None
         and errors = ref []
         and authenticated = ref true
         and account_generation = ref 0
         and cancelled = ref [] in
         let drain () =
           List.iter
             (function
               | Worker.Push { payload = Service.Need_id_token request; _ } ->
                 challenge := Some request
               | Worker.Push { payload = Service.Client_state_changed state; _ } ->
                 authenticated := state.snapshot.startup.authenticated;
                 account_generation := state.snapshot.startup.account_generation;
                 Option.iter
                   (fun message -> errors := message :: !errors)
                   state.snapshot.last_error
               | Worker.Response { request_id; outcome = Cancelled; _ } ->
                 cancelled := request_id :: !cancelled
               | _ -> ())
             (Worker.For_testing.drain_events client ~max_events:64)
         in
         control_wait "real current token flight" (fun () ->
           drain ();
           Option.is_some !challenge);
         let request = Option.get !challenge in
         let initial_account_generation = !account_generation in
         Atomic.set pause true;
         ignore (Worker.send client Service.Get_graph_state |> accepted);
         control_wait "coordinator is paused before changes" (fun () -> Atomic.get paused);
         let cancelled_auth = ref None in
         (match transition with
          | `Late_restore ->
            ignore
              (Worker.send
                 client
                 (Service.Client_command (Restore_local_account { user_id = "auth-A" }))
               |> accepted)
          | `Cancelled_auth ->
            let id =
              Worker.send
                client
                (Service.Client_command (Reconcile_authenticated_user { user_id = None }))
              |> accepted
            in
            cancelled_auth := Some id;
            Worker.cancel client ~request_id:id
          | `Same ->
            ignore
              (Worker.send
                 client
                 (Service.Client_command
                    (Reconcile_authenticated_user { user_id = Some "auth-A" }))
               |> accepted);
            T.require
              (Service.answer_token client request (Ok "synthetic-invalid-token")
               = Worker.Control_accepted)
              "same user retains the real challenge"
          | `Aba ->
            ignore
              (Worker.send
                 client
                 (Service.Client_command
                    (Reconcile_authenticated_user { user_id = Some "auth-B" }))
               |> accepted);
            ignore
              (Worker.send
                 client
                 (Service.Client_command
                    (Reconcile_authenticated_user { user_id = Some "auth-A" }))
               |> accepted);
            T.require
              (Service.answer_token client request (Ok "synthetic-invalid-token")
               = Worker.Control_stale)
              "A-B-A revoked the old reply"
          | `Queued_reply ->
            T.require
              (Service.answer_token client request (Ok "synthetic-invalid-token")
               = Worker.Control_accepted)
              "old reply is queued first";
            ignore
              (Worker.send
                 client
                 (Service.Client_command (Reconcile_authenticated_user { user_id = None }))
               |> accepted);
            T.require
              (Service.answer_token client request (Error "late") = Worker.Control_stale)
              "signout revokes even a queued reply"
          | `Full_signout | `Full_auth_after_signout ->
            if transition = `Full_auth_after_signout
            then
              ignore
                (Worker.send
                   client
                   (Service.Client_command
                      (Reconcile_authenticated_user { user_id = None }))
                 |> accepted);
            let full = ref false
            and admissions = ref 0 in
            while (not !full) && !admissions < 32 do
              match Worker.send client Service.Get_graph_state with
              | Worker.Accepted _ -> incr admissions
              | Worker.Full -> full := true
              | _ -> T.fail "fixture stopped while filling ordinary reservations"
            done;
            T.require !full "ordinary response reservations are full";
            let user_id = if transition = `Full_signout then None else Some "auth-A" in
            T.require
              (Worker.send
                 client
                 (Service.Client_command (Reconcile_authenticated_user { user_id }))
               = Worker.Full)
              "latest auth has no ordinary data admission"
          | `Worker_owned ->
            (* No Application continuation is needed: invalidation identifies the
            Worker-owned current capability without Application continuation state. *)
            ignore
              (Worker.send
                 client
                 (Service.Client_command (Reconcile_authenticated_user { user_id = None }))
               |> accepted);
            T.require
              (Service.answer_token client request (Error "late") = Worker.Control_stale)
              "unanswered challenge is revoked by identity change");
         T.require
           (Worker.For_testing.pending_control_count client <= 2)
           "real service has two bounded topics";
         Atomic.set pause false;
         (match transition with
          | `Late_restore ->
            control_wait "SDK auth is reasserted after late local restoration" (fun () ->
              drain ();
              !account_generation > initial_account_generation && !authenticated)
          | `Same ->
            control_wait "same-user answer reaches the real cache" (fun () ->
              drain ();
              List.mem "ID token response is invalid." !errors)
          | `Aba | `Full_auth_after_signout ->
            control_wait
              "A-B-A creates a new flight instead of joining the revoked one"
              (fun () ->
                 drain ();
                 match !challenge with
                 | Some fresh ->
                   Service.token_request_id fresh <> Service.token_request_id request
                 | None -> false)
          | `Queued_reply | `Worker_owned | `Full_signout | `Cancelled_auth ->
            control_wait "real account invalidation reaches Core" (fun () ->
              drain ();
              not !authenticated));
         Option.iter
           (fun id ->
              control_wait "cancelled auth waiter retires" (fun () ->
                drain ();
                List.mem id !cancelled))
           !cancelled_auth;
         if transition <> `Same
         then
           T.require
             (not (List.mem "ID token response is invalid." !errors))
             "revoked token was never applied"))
;;

let () =
  T.run
    "lui worker service"
    [ T.case
        "control bypasses full data and handler waits"
        test_control_bypasses_full_data_and_waiting_handlers
    ; T.case
        "control capabilities bind client and stop"
        test_control_client_epoch_and_stop
    ; T.case "control cancellation startup and exceptions" test_control_cancel_and_failure
    ; T.case
        "bounded control pressure and data fairness"
        test_control_pressure_is_bounded_and_fair
    ; T.case
        "serial control barrier preserves FIFO"
        (test_control_barrier ~ending:`Complete)
    ; T.case
        "control barrier cancellation releases permit"
        (test_control_barrier ~ending:`Cancel)
    ; T.case "control barrier stop releases requests" (test_control_barrier ~ending:`Stop)
    ; T.case
        "control barrier exception shuts down"
        (test_control_barrier ~ending:`Failure)
    ; T.case
        "late local restoration retains observed SDK auth"
        (test_real_auth_control ~transition:`Late_restore)
    ; T.case
        "cancelled auth waiter preserves latest Core intent"
        (test_real_auth_control ~transition:`Cancelled_auth)
    ; T.case
        "Full auth signout still reaches Core"
        (test_real_auth_control ~transition:`Full_signout)
    ; T.case
        "Full latest auth supersedes queued signout"
        (test_real_auth_control ~transition:`Full_auth_after_signout)
    ; T.case
        "auth revokes an extracted reply"
        (test_extracted_reply_revalidation ~change:`Auth)
    ; T.case
        "stop revokes an extracted reply"
        (test_extracted_reply_revalidation ~change:`Stop)
    ; T.case
        "replacement revokes an extracted reply"
        (test_extracted_reply_revalidation ~change:`Replacement)
    ; T.case
        "all invalidators block reply"
        (test_all_invalidators_block_reply ~newer:false)
    ; T.case
        "topic 63 invalidator blocks reply"
        (test_all_invalidators_block_reply ~second_topic:63 ~newer:false)
    ; T.case
        "old invalidator completion retains new block"
        (test_all_invalidators_block_reply ~newer:true)
    ; T.case "real auth A-B-A retires flight" (test_real_auth_control ~transition:`Aba)
    ; T.case "same auth retains flight" (test_real_auth_control ~transition:`Same)
    ; T.case
        "auth retires queued token answer"
        (test_real_auth_control ~transition:`Queued_reply)
    ; T.case
        "auth retires Worker-owned token obligation"
        (test_real_auth_control ~transition:`Worker_owned)
    ; T.case "Ready survives acceptance" test_ready_survives_acceptance
    ; T.case "distinct asset facts survive" test_assets_consumers_and_scopes_survive
    ; T.case
        "retry retains latest ordered facts"
        test_retry_keeps_latest_fact_in_arrival_order
    ; T.case "uploads and downloads are independent" test_uploads_do_not_erase_downloads
    ; T.case "pending asset facts are bounded" test_pending_asset_facts_have_hard_bound
    ; T.case "snapshot topics still replace" test_snapshot_topics_still_replace
    ; T.case
        "managed worker starts closed with a v2 envelope"
        test_managed_worker_starts_closed_and_replies_with_v2_envelope
    ; T.case "managed client command is accepted" test_managed_client_command_is_accepted
    ]
;;
