module Core = Logseq_db_worker_pure_reducer.Core
module Runner = Logseq_db_worker_effect_runner.Effect_runner
module Sync = Logseq_sync_domain.Core
module T = Logseq_db_worker_test_support.Test_support

let services ?(post = fun _ -> ()) () : Runner.services =
  { post
  ; owner = (fun ~scope:_ -> Error "No graph owner installed")
  ; asset = (fun _ -> Error Sync.Asset_cancelled)
  ; await_io = (fun ~scope:_ -> Ok ())
  ; shutdown = (fun () -> ())
  ; retire_account = (fun ~account:_ -> Ok ())
  }
;;

let account ?(generation = 1) user_id : Sync.account_scope =
  { managed_sync_origin = Uri.of_string "https://api.logseq.io"
  ; user_id
  ; account_generation = generation
  ; presentation_generation = 1
  ; lifecycle_generation = 1L
  }
;;

let far_future_token = "header.eyJleHAiOjIwMDAwMDAwMDB9.signature"
let two_hour_token = "header.eyJleHAiOjE3MDAwMDcyMDB9.signature"
let one_hour_token = "header.eyJleHAiOjE3MDAwMDM2MDB9.signature"
let expired_token = "header.eyJleHAiOjE2OTk5OTk5OTl9.signature"

let expect_ok = function
  | Ok value -> value
  | Error message -> Alcotest.failf "expected token, got error: %s" message
;;

let expect_error = function
  | Error message -> message
  | Ok _ -> Alcotest.fail "expected token acquisition to fail"
;;

let auto_cache ~wall_clock_s ~monotonic_ns responses =
  let cache = ref None in
  let request_count = ref 0 in
  let request request =
    incr request_count;
    match !cache, Queue.take responses with
    | Some cache, Ok token -> Runner.provide_id_token cache request token
    | Some cache, Error message -> Runner.reject_id_token cache request message
    | None, _ -> Alcotest.fail "token cache was not initialized"
  in
  let created = Runner.id_token_cache ~wall_clock_s ~monotonic_ns ~request in
  cache := Some created;
  created, request_count
;;

let test_id_token_cache_caps_reuse_at_twenty_four_hours () =
  Eio_main.run (fun _ ->
    let now_ns = ref 0L in
    let responses = Queue.create () in
    Queue.add (Ok far_future_token) responses;
    Queue.add (Ok far_future_token) responses;
    let cache, request_count =
      auto_cache
        ~wall_clock_s:(fun () -> 1_700_000_000.)
        ~monotonic_ns:(fun () -> !now_ns)
        responses
    in
    Alcotest.check
      Alcotest.string
      "first token"
      far_future_token
      (Runner.acquire_id_token cache ~account:(account "user-1") |> expect_ok);
    Runner.reconcile_authenticated_user cache ~user_id:(Some "user-1");
    now_ns := 86_399_999_999_999L;
    ignore (Runner.acquire_id_token cache ~account:(account "user-1") |> expect_ok);
    Alcotest.check Alcotest.int "cache hit" 1 !request_count;
    now_ns := 86_400_000_000_000L;
    ignore (Runner.acquire_id_token cache ~account:(account "user-1") |> expect_ok);
    Alcotest.check Alcotest.int "exact deadline is expired" 2 !request_count)
;;

let test_id_token_cache_caps_reuse_one_hour_before_expiration () =
  Eio_main.run (fun _ ->
    let now_ns = ref 0L in
    let responses = Queue.create () in
    Queue.add (Ok two_hour_token) responses;
    Queue.add (Ok two_hour_token) responses;
    let cache, request_count =
      auto_cache
        ~wall_clock_s:(fun () -> 1_700_000_000.)
        ~monotonic_ns:(fun () -> !now_ns)
        responses
    in
    ignore (Runner.acquire_id_token cache ~account:(account "user-1") |> expect_ok);
    now_ns := 3_599_999_999_999L;
    ignore (Runner.acquire_id_token cache ~account:(account "user-1") |> expect_ok);
    Alcotest.check Alcotest.int "before expiration margin" 1 !request_count;
    now_ns := 3_600_000_000_000L;
    ignore (Runner.acquire_id_token cache ~account:(account "user-1") |> expect_ok);
    Alcotest.check Alcotest.int "expiration margin deadline" 2 !request_count)
;;

let test_id_token_cache_does_not_retain_immediately_non_reusable_token () =
  Eio_main.run (fun _ ->
    let responses = Queue.create () in
    Queue.add (Ok one_hour_token) responses;
    Queue.add (Ok one_hour_token) responses;
    let cache, request_count =
      auto_cache
        ~wall_clock_s:(fun () -> 1_700_000_000.)
        ~monotonic_ns:(fun () -> 0L)
        responses
    in
    ignore (Runner.acquire_id_token cache ~account:(account "user-1") |> expect_ok);
    ignore (Runner.acquire_id_token cache ~account:(account "user-1") |> expect_ok);
    Alcotest.check Alcotest.int "near-expiry token is one-shot" 2 !request_count)
;;

let test_id_token_cache_rejects_invalid_responses_without_retaining_them () =
  Eio_main.run (fun _ ->
    let oversized = String.make ((1024 * 1024) + 1) 's' in
    let invalid =
      [ ""
      ; "secret-token"
      ; "header.e30.signature"
      ; "header.not-base64!.signature"
      ; "header.e30"
      ; oversized
      ; expired_token
      ]
    in
    let responses = Queue.create () in
    List.iter (fun token -> Queue.add (Ok token) responses) invalid;
    Queue.add (Ok far_future_token) responses;
    let cache, request_count =
      auto_cache
        ~wall_clock_s:(fun () -> 1_700_000_000.)
        ~monotonic_ns:(fun () -> 0L)
        responses
    in
    List.iter
      (fun _ ->
         let message =
           Runner.acquire_id_token cache ~account:(account "user-1") |> expect_error
         in
         Alcotest.(check bool) "bounded error" true (String.length message <= 160);
         Alcotest.(check bool)
           "error does not expose token"
           false
           (String.equal message "secret-token"))
      invalid;
    ignore (Runner.acquire_id_token cache ~account:(account "user-1") |> expect_ok);
    ignore (Runner.acquire_id_token cache ~account:(account "user-1") |> expect_ok);
    Alcotest.check
      Alcotest.int
      "every invalid response remained a miss"
      (List.length invalid + 1)
      !request_count)
;;

let test_id_token_cache_coalesces_concurrent_misses () =
  Eio_main.run (fun _ ->
    Eio.Switch.run (fun sw ->
      let requests = Queue.create () in
      let cache =
        Runner.id_token_cache
          ~wall_clock_s:(fun () -> 1_700_000_000.)
          ~monotonic_ns:(fun () -> 0L)
          ~request:(fun request -> Queue.add request requests)
      in
      let outcomes = ref [] in
      let acquire () =
        let outcome = Runner.acquire_id_token cache ~account:(account "user-1") in
        outcomes := outcome :: !outcomes
      in
      Eio.Fiber.fork ~sw acquire;
      Eio.Fiber.fork ~sw acquire;
      Eio.Fiber.yield ();
      Alcotest.check Alcotest.int "one Flutter request" 1 (Queue.length requests);
      Runner.provide_id_token cache (Queue.take requests) far_future_token;
      Eio.Fiber.yield ();
      Alcotest.check Alcotest.int "all waiters resumed" 2 (List.length !outcomes);
      List.iter
        (fun outcome ->
           Alcotest.check
             Alcotest.string
             "shared token"
             far_future_token
             (expect_ok outcome))
        !outcomes))
;;

let test_id_token_cache_propagates_flutter_failure_without_caching () =
  Eio_main.run (fun _ ->
    let responses = Queue.create () in
    Queue.add (Error "session unavailable") responses;
    Queue.add (Ok far_future_token) responses;
    let cache, request_count =
      auto_cache
        ~wall_clock_s:(fun () -> 1_700_000_000.)
        ~monotonic_ns:(fun () -> 0L)
        responses
    in
    let message =
      Runner.acquire_id_token cache ~account:(account "user-1") |> expect_error
    in
    Alcotest.check
      Alcotest.string
      "bounded generic failure"
      "ID token is unavailable."
      message;
    ignore (Runner.acquire_id_token cache ~account:(account "user-1") |> expect_ok);
    Alcotest.check Alcotest.int "failure was not cached" 2 !request_count)
;;

let test_id_token_cache_invalidation_is_credential_specific () =
  Eio_main.run (fun _ ->
    let responses = Queue.create () in
    Queue.add (Ok far_future_token) responses;
    Queue.add (Ok two_hour_token) responses;
    let cache, request_count =
      auto_cache
        ~wall_clock_s:(fun () -> 1_700_000_000.)
        ~monotonic_ns:(fun () -> 0L)
        responses
    in
    let first = Runner.acquire_id_token cache ~account:(account "user-1") |> expect_ok in
    Runner.invalidate_id_token cache ~account:(account "user-1") ~token:first;
    let second = Runner.acquire_id_token cache ~account:(account "user-1") |> expect_ok in
    Runner.invalidate_id_token cache ~account:(account "user-1") ~token:first;
    Alcotest.check
      Alcotest.string
      "stale invalidation keeps replacement"
      second
      (Runner.acquire_id_token cache ~account:(account "user-1") |> expect_ok);
    Alcotest.check Alcotest.int "one refresh only" 2 !request_count)
;;

let test_id_token_cache_sign_out_clears_entry_and_cancels_waiters () =
  Eio_main.run (fun _ ->
    Eio.Switch.run (fun sw ->
      let requests = Queue.create () in
      let cache =
        Runner.id_token_cache
          ~wall_clock_s:(fun () -> 1_700_000_000.)
          ~monotonic_ns:(fun () -> 0L)
          ~request:(fun request -> Queue.add request requests)
      in
      let outcome = ref None in
      Eio.Fiber.fork ~sw (fun () ->
        outcome := Some (Runner.acquire_id_token cache ~account:(account "user-1")));
      Eio.Fiber.yield ();
      let stale = Queue.take requests in
      Runner.reconcile_authenticated_user cache ~user_id:None;
      Eio.Fiber.yield ();
      ignore (Option.get !outcome |> expect_error);
      Runner.provide_id_token cache stale far_future_token;
      Runner.reconcile_authenticated_user cache ~user_id:(Some "user-1");
      let next = ref None in
      Eio.Fiber.fork ~sw (fun () ->
        next
        := Some (Runner.acquire_id_token cache ~account:(account ~generation:2 "user-1")));
      Eio.Fiber.yield ();
      Alcotest.check
        Alcotest.int
        "sign-in starts a fresh request"
        1
        (Queue.length requests);
      Runner.provide_id_token cache (Queue.take requests) far_future_token;
      Eio.Fiber.yield ();
      ignore (Option.get !next |> expect_ok)))
;;

let test_id_token_cache_account_replacement_makes_delayed_response_inert () =
  Eio_main.run (fun _ ->
    Eio.Switch.run (fun sw ->
      let requests = Queue.create () in
      let cache =
        Runner.id_token_cache
          ~wall_clock_s:(fun () -> 1_700_000_000.)
          ~monotonic_ns:(fun () -> 0L)
          ~request:(fun request -> Queue.add request requests)
      in
      let old_outcome = ref None in
      Eio.Fiber.fork ~sw (fun () ->
        old_outcome := Some (Runner.acquire_id_token cache ~account:(account "user-1")));
      Eio.Fiber.yield ();
      let stale = Queue.take requests in
      Runner.reconcile_authenticated_user cache ~user_id:(Some "user-2");
      Eio.Fiber.yield ();
      ignore (Option.get !old_outcome |> expect_error);
      Runner.provide_id_token cache stale far_future_token;
      let fresh_outcome = ref None in
      Eio.Fiber.fork ~sw (fun () ->
        fresh_outcome
        := Some (Runner.acquire_id_token cache ~account:(account ~generation:2 "user-2")));
      Eio.Fiber.yield ();
      Alcotest.check
        Alcotest.int
        "replacement requests its own token"
        1
        (Queue.length requests);
      Runner.provide_id_token cache (Queue.take requests) far_future_token;
      Eio.Fiber.yield ();
      ignore (Option.get !fresh_outcome |> expect_ok)))
;;

let test_id_token_cache_shutdown_clears_entry_and_cancels_waiters () =
  Eio_main.run (fun _ ->
    Eio.Switch.run (fun sw ->
      let requests = Queue.create () in
      let cache =
        Runner.id_token_cache
          ~wall_clock_s:(fun () -> 1_700_000_000.)
          ~monotonic_ns:(fun () -> 0L)
          ~request:(fun request -> Queue.add request requests)
      in
      let outcome = ref None in
      Eio.Fiber.fork ~sw (fun () ->
        outcome := Some (Runner.acquire_id_token cache ~account:(account "user-1")));
      Eio.Fiber.yield ();
      let stale = Queue.take requests in
      Runner.shutdown_id_token_cache cache;
      Eio.Fiber.yield ();
      ignore (Option.get !outcome |> expect_error);
      Runner.provide_id_token cache stale far_future_token;
      Alcotest.check
        Alcotest.string
        "future acquisition stays stopped"
        "ID token cache is stopped."
        (Runner.acquire_id_token cache ~account:(account "user-1") |> expect_error);
      Alcotest.check
        Alcotest.int
        "shutdown emits no new request"
        0
        (Queue.length requests)))
;;

let test_sync_and_publish_instructions_are_not_reduced_recursively () =
  T.with_managed (fun fixture ->
    Eio_main.run (fun _environment ->
      Eio.Switch.run (fun sw ->
        let submitted = ref [] in
        let published = ref [] in
        let runtime =
          Runner.runtime
            ~sleep:(fun _ -> failwith "unexpected wait")
            ~fork:(fun ~sw:_ task -> task ())
          |> Result.get_ok
        in
        let services : Runner.services =
          {post=(fun intent -> submitted := intent :: !submitted);
           owner=(fun ~scope:_ -> Error "No graph owner installed");
           asset=(fun _ -> Alcotest.fail "Unexpected asset request");
           await_io=(fun ~scope:_ -> Alcotest.fail "Unexpected I/O join");
           retire_account=(fun ~account:_ -> Alcotest.fail "Unexpected account retirement in fixture");
           shutdown=(fun () -> ())}
        in
        let dependencies =
          Runner.dependencies
            ~runtime
            ~config:fixture.config
            ~overlay:fixture.overlay
            ~services
            ~publish:(fun output -> published := output :: !published)
          |> Result.get_ok
        in
        let posted = ref [] in
        let runner =
          Runner.create
            ~sw
            dependencies
            ~recovery_current:(fun _ -> false)
            ~upload_current:(fun _ -> false)
            ~asset_current:(fun _ -> false)
            ~post:(fun event -> posted := event :: !posted)
          |> Result.get_ok
        in
        let intent = Core.Sync_intent (Sync.Restore_local_account {user_id="user-1"}) in
        Runner.submit runner (Core.Publish (Core.Lifecycle_intent intent));
        Runner.submit runner (Core.Publish (Core.Diagnostic "fixture publication"));
        Alcotest.check Alcotest.int "lifecycle receives post" 1 (List.length !submitted);
        Alcotest.(check bool) "original intent retained" true (!submitted=[intent]);
        Alcotest.check Alcotest.int "host receives publish" 1 (List.length !published);
        Alcotest.check Alcotest.int "runner never calls reducer" 0 (List.length !posted);
        Runner.shutdown runner)))
;;

let test_direct_owner_io_failure_has_no_event_bridge () =
  T.with_managed (fun fixture -> Eio_main.run (fun _ -> Eio.Switch.run (fun sw ->
    let posted = ref [] in
    let calls = ref 0 in
    let services : Runner.services =
      {post=(fun _ -> Alcotest.fail "Unexpected lifecycle intent");
       owner=(fun ~scope:_ -> Error "No graph owner installed");
       asset=(fun _ -> Error Sync.Asset_cancelled);
       await_io=(fun ~scope:_ -> incr calls; Error "Original owner cleanup failed");
       retire_account=(fun ~account:_ -> Ok ()); shutdown=(fun () -> ())} in
    let dependencies = Runner.dependencies
      ~runtime:(Runner.runtime ~fork:(fun ~sw task -> Eio.Fiber.fork ~sw task)
        ~sleep:(fun _ -> ()) |> Result.get_ok)
      ~config:fixture.config ~overlay:fixture.overlay ~services
      ~publish:(fun _ -> ()) |> Result.get_ok in
    let runner = Runner.create ~sw dependencies ~post:(fun event -> posted := event :: !posted)
      ~recovery_current:(fun _ -> false) ~upload_current:(fun _ -> false)
      ~asset_current:(fun _ -> false) |> Result.get_ok in
    let account : Sync.account_scope =
      {managed_sync_origin=Uri.of_string "https://api.logseq.io";user_id="user-1";account_generation=0;
       presentation_generation=0;lifecycle_generation=0L} in
    Alcotest.(check (result unit string)) "physical error preserved"
      (Error "Original owner cleanup failed")
      (Runner.await_sync_io runner ~scope:(Sync.effect_scope_of_account account));
    Alcotest.(check int) "direct callback called once" 1 !calls;
    Alcotest.(check int) "no reducer fence event" 0 (List.length !posted);
    Runner.shutdown runner;
    Alcotest.(check bool) "stopped worker cannot borrow upload store" true
      (Result.is_error (Runner.sync_upload_store runner)))))
;;

let asset_sync_config () =
  let limits=Sync.limits ~maximum_response_bytes:1024 ~maximum_artifact_bytes:1024 ~submission_batch_size:1 |> Result.get_ok in
  Sync.config ~managed_sync_origin:(Uri.of_string "https://api.logseq.io") ~limits |> Result.get_ok
;;
(* Scheduling failures belong to the effect runner, not the pure reducer. *)
let lifecycle_projection config (scope : Sync.graph_scope) =
  let state = Core.initial (Core.config ~worker:config ~sync:(asset_sync_config ())) |> Result.get_ok in
  let initial = (Core.view state).sync in
  let graph : Sync.graph = {graph_id=scope.graph_id;name="Direct owner fixture";
    schema={major=65;minor=33;exact=true};encrypted=false} in
  let sync : Sync.state = {initial with snapshot={initial.snapshot with
    selected_graph=Some graph.graph_id;catalog=[graph];resident_graphs=[graph.graph_id];
    startup={initial.snapshot.startup with authenticated=true;local_access=Sync.Local_available;
      account_generation=scope.account.account_generation;graph_generation=scope.graph_generation;
      presentation_generation=scope.account.presentation_generation}}} in
  let coordination : Sync.coordination_state = {account=Some scope.account;
    selected=Some {startup={account_generation=scope.account.account_generation;
      presentation_generation=scope.account.presentation_generation};graph_id=scope.graph_id;
      graph_generation=scope.graph_generation};
    residents=[scope,sync];desired_residents=[scope.graph_id];deletion=None} in
  sync, coordination
;;

let test_worker_schedule_failure_completes
    ?(failure=Unix.Unix_error (Unix.EACCES, "fork", "PRIVATE_SYNTHETIC_PAYLOAD"))
    ?(expected_source="io-permission") ?(expected_reason="resourceFailed") () =
  let module Sync = Logseq_sync_domain.Core in
  T.with_managed (fun fixture -> Eio_main.run (fun _ -> Eio.Switch.run (fun sw ->
    let posted = ref [] in
    let dependencies = Runner.dependencies
      ~runtime:(Runner.runtime ~fork:(fun ~sw:_ _ ->
        raise failure)
        ~sleep:(fun _ -> ()) |> Result.get_ok)
      ~config:fixture.config ~overlay:fixture.overlay
      ~services:(services ())
      ~publish:(fun _ -> ()) |> Result.get_ok in
    let runner = Runner.create ~sw dependencies
      ~recovery_current:(fun _ -> false) ~upload_current:(fun _ -> false)
      ~asset_current:(fun _ -> false) ~post:(fun event -> posted := event :: !posted)
      |> Result.get_ok in
    let state = Core.initial (Core.config ~worker:fixture.config ~sync:(asset_sync_config ())) |> Result.get_ok in
    let graph : Sync.graph = {graph_id=(Logseq_db_types.Graph_types.Uuid.of_string "94000000-0000-4000-8000-000000000709" |> Result.get_ok);name="fixture";
      schema={major=65;minor=33;exact=true};encrypted=false} in
    let scope : Sync.graph_scope = {account=account "user-1";graph_id=graph.graph_id;graph_generation=1} in
    let initial = (Core.view state).sync in
    let sync : Sync.state = {initial with snapshot={initial.snapshot with
      selected_graph=Some graph.graph_id;catalog=[graph];resident_graphs=[graph.graph_id];
      startup={initial.snapshot.startup with authenticated=true;local_access=Sync.Local_available;
        account_generation=1;graph_generation=1;presentation_generation=1}}} in
    let coordination : Sync.coordination_state = {account=Some scope.account;
      selected=Some {startup={account_generation=1;presentation_generation=1};graph_id=graph.graph_id;graph_generation=1};
      residents=[scope,sync];desired_residents=[graph.graph_id];deletion=None} in
    let opened = Core.database_opened ~database_id:"schedule-fixture" ~graph_id:graph.graph_id in
    let snapshot = Core.step state (Core.Lifecycle_snapshot (sync, coordination, [scope, opened])) in
    let module Read = Worker_pure_read in
    let module F = Read.For_worker in
    let binding = F.binding ~serial:1L ~incarnation:(Read.worker_incarnation
      ~runtime_epoch:(Journal_worker_ids.Runtime.Epoch.of_int64 1L)
      ~worker_generation:(Journal_worker_ids.Worker.Generation.of_int64 1L))
      ~origin:(Uri.to_string scope.account.managed_sync_origin) ~user:scope.account.user_id in
    let owner : Sync.timeline_scope = {startup={account_generation=scope.account.account_generation;
      presentation_generation=scope.account.presentation_generation};graph_id=scope.graph_id;
      graph_generation=scope.graph_generation} in
    let limits : Worker_pure_data.capability_limits = {response_budget_bytes=fixture.config.response_budget_bytes;
      outbox_max_records=4096;outbox_max_bytes=8388608;change_max_items=4096;change_max_bytes=1048576;
      dispatcher_capacity=256;wire_batch_max_bytes=262144} in
    let session = F.session ~binding ~graph:scope.graph_id ~account:scope.account.account_generation
      ~lifecycle:scope.account.lifecycle_generation ~generation:scope.graph_generation ~scope:owner ~asset_scope:scope ~limits in
    let budget = Read.read_budget session ~maximum_items:1 ~maximum_bytes:limits.response_budget_bytes |> Result.get_ok in
    let requested = Core.step snapshot.next (Core.Graph_request_for_scope
      {scope;id=Core.request_id_of_int64 1L;read=F.pack_query budget Read.Admission}) in
    let work = List.find (function Core.Run_worker _ -> true | _ -> false) requested.effects in
    Runner.submit runner work;
    match !posted with
    | [Core.Runner_completed (Core.Execute_request_completed (_, Error error))] ->
      let module E = Logseq_db_worker_contract.Error in
      let module D = Logseq_db_types.Failure_diagnostic in
      let detail = List.find_map (fun (item:E.detail) -> match item.value with
        | E.Detail_string source when item.name=D.detail_name -> D.decode source
        | _ -> None) (E.details error) |> Option.get in
      Alcotest.(check string) "operation retained" "workerOperation" (D.operation detail);
      Alcotest.(check string) "source cause retained" expected_source (D.source_class detail);
      Alcotest.(check string) "specific reason retained" expected_reason (D.reason detail);
      let encoded=Yojson.Safe.to_string(E.to_yojson error) in
      let marker="PRIVATE_SYNTHETIC_PAYLOAD" in
      let rec contains offset = offset + String.length marker <= String.length encoded
        && (String.sub encoded offset (String.length marker)=marker || contains (offset+1)) in
      Alcotest.(check bool) "private exception argument excluded" false (contains 0)
    | _ -> Alcotest.fail "Scheduling failure must post exactly one typed completion")))
;;

let picker_import support ordinal : Logseq_db_types.Asset_import.t =
  let uuid n =
    Logseq_db_types.Graph_types.Uuid.of_string
      (Printf.sprintf "33000000-0000-4000-8000-%012d" n)
    |> Result.get_ok
  in
  let source_file =
    Filename.concat support ("picker-" ^ string_of_int ordinal ^ ".bin")
  in
  Out_channel.with_open_bin source_file (fun output -> output_string output "file");
  { operation = uuid ordinal
  ; asset = uuid (ordinal + 1)
  ; target = uuid (ordinal + 2)
  ; local_mutation = uuid (ordinal + 3)
  ; metadata_mutation = uuid (ordinal + 4)
  ; replace_reference = None
  ; source_file
  ; title = "Cancellation fixture"
  ; file_type = "bin"
  }
;;

(* Local staging publication and lease ownership live in the runner, not the
   transfer reducer. Exercise real cache pressure and filesystem failures. *)
type owner_fixture =
  { runner : Runner.t
  ; context : Sync.asset_context
  ; support : string
  ; database : Logseq_overlay_db.Database.t
  ; crypto : Logseq_sync_crypto.Core.t
  ; identity : Sync_dsl.Core.identity
  ; actions : Sync.asset_action list ref
  ; fixture_result : Sync.asset_action -> Sync.asset_result
  ; fixture_asset : Sync.asset_action -> Sync.asset_value
  ; set_upload_current : (Logseq_db_worker_pure_reducer.Asset_upload.ticket -> bool) -> unit
  ; upload_events : Logseq_db_worker_pure_reducer.Asset_upload.completion Queue.t
  ; recover_uploads : unit -> (Logseq_db_types.Asset_upload_intent.t list, string) result
  ; staged_path : string -> string option
  ; gate : (Sync.asset_output -> bool) -> unit Eio.Promise.t
  ; deliver_held : ?keep_gate:bool -> unit -> unit
  }

let with_direct_owner run =
  T.with_managed (fun fixture -> Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
    let module D = Sync_dsl.Core in
    let module Assets = Logseq_sync_assets.Core in
    let module Cache = Logseq_sync_assets.Cache in
    let scope : Sync.graph_scope =
      { account = account "user-1"
      ; graph_id = Logseq_db_types.Graph_types.Uuid.of_string
          "22000000-0000-4000-8000-000000000001" |> Result.get_ok
      ; graph_generation = 1
      } in
    let identity = D.identity ~origin:(Uri.to_string scope.account.managed_sync_origin)
      ~account:scope.account.user_id ~graph:(Logseq_db_types.Graph_types.Uuid.to_string scope.graph_id)
      ~account_generation:1L ~graph_generation:1L |> Result.get_ok in
    let limits = D.limits ~maximum_items:8 ~maximum_bytes:32768 ~maximum_pending:8
      ~maximum_resources:8 ~steps_per_turn:8 ~maximum_tasks:8 ~maximum_messages:8
      ~maximum_message_bytes:32768 ~maximum_demands:8 ~maximum_active_assets:2
      ~foreground_reserve:1 ~foreground_demand_reserve:1 ~foreground_descriptor_reserve_bytes:128
      ~asset_cache_budget_bytes:16L ~asset_maximum_file_bytes:16 ~asset_pending_budget_bytes:32L
      ~snapshot_maximum_artifact_bytes:4096L ~snapshot_staging_budget_bytes:4096L
      ~snapshot_scratch_budget_bytes:4096L |> Result.get_ok in
    let crypto = Logseq_sync_crypto.Core.create ~identity ~limits ~encrypted:false
      ~backend:{crypto=Logseq_sync_native_crypto.Platform_crypto.crypto;
        unlock=(fun ~identity:_ ~wrapped_graph_key:_ -> Error D.Locked)} in
    let support = fixture.config.application_support_directory in
    let assets = Assets.create ~root:support ~identity ~limits ~crypto
      ~key:(Assets.native_key ~identity ~crypto)
      ~network:{get=(fun ~identity:_ ~asset:_ ~version:_ ~maximum_wire_bytes:_ ->
          Alcotest.fail "Unexpected network GET");
        put=(fun ~identity:_ ~asset:_ ~version:_ ~wire:_ -> Alcotest.fail "Unexpected network PUT")}
      |> Result.get_ok in
    ignore (Test_support.seed_mirror ~graph_id:scope.graph_id support);
    let inspection = Logseq_overlay_db.Database.inspect_mirror
      ~application_support_directory:support ~graph_id:scope.graph_id |> Result.get_ok in
    let database = Logseq_overlay_db.Database.open_ ~sw fixture.overlay inspection
      ~graph_name:"Direct import owner" |> Result.get_ok in
    let database_owner = Execute.Core.database_owner database in
    let cache = Assets.cache assets in
    let actions = ref [] in
    let owner_ref = ref None in
    let await_owner () = match !owner_ref with
      | None -> Ok ()
      | Some owner ->
        Result.bind (Logseq_sync_worker_owner.Core.fence owner ~identity)
          (fun () -> Logseq_sync_worker_owner.Core.await_io owner ~identity)
        |> Result.map_error D.error_message in
    let with_cause kind message = Sync.Asset_with_cause (kind,
      Logseq_db_types.Failure_diagnostic.of_source ~operation:"assetPreview"
        ~reason:"ownerFailed" message) in
    let failure error =
      let kind = match error with
        | Cache.Full -> Sync.Asset_storage_full
        | Checksum_mismatch -> Sync.Asset_checksum_mismatch
        | Stale -> Sync.Asset_cancelled
        | Invalid message | Io message -> Sync.Asset_invalid_content message in
      with_cause kind (D.error_message (Assets.cache_error error)) in
    let fixture_result action =
      actions := action :: !actions;
      match action with
      | Sync.Stage_asset_file {operation;file_type;source_file} ->
        Cache.stage cache ~operation ~file_type ~source_file ~pending_budget_bytes:32L
        |> Result.map (fun (staged : Cache.staged) -> Sync.Asset_staged
          {file=staged.file;checksum=staged.checksum;size=staged.size})
        |> Result.map_error failure
      | Sync.Check_asset_cache (asset, version) ->
        Cache.lookup cache ~asset ~version |> Result.map (fun handle -> Sync.Asset_cached handle)
        |> Result.map_error failure
      | Sync.Publish_staged_asset {asset;version;file} ->
        let module Codec = Logseq_sync_native_crypto.Asset_codec in
        (match Cache.staged_path cache ~file with
         | None -> Error (with_cause Sync.Asset_missing_source "Staged original is missing")
         | Some path when not (Sys.file_exists path) ->
           Error (with_cause Sync.Asset_missing_source "Staged original is missing")
         | Some path ->
           let native = Logseq_sync_native_crypto.Platform_crypto.crypto in
           let crypto : Codec.crypto = {encrypt=native.encrypt_aes_gcm;decrypt=native.decrypt_aes_gcm} in
           let bytes = In_channel.with_open_bin path In_channel.input_all in
           Codec.decode ~maximum_plaintext_bytes:16 ~crypto ~key:None ~expected:version bytes
           |> Result.map_error (fun error ->
             let kind = match error with
               | Codec.Checksum_mismatch -> Sync.Asset_checksum_mismatch
               | Wire_too_large | Plaintext_too_large -> Sync.Asset_size_rejected
               | Invalid_limit | Malformed_envelope | Malformed_transit _ | Decryption_failed _ ->
                 Sync.Asset_invalid_content (Codec.decode_error_message error) in
             with_cause kind (Codec.decode_error_message error))
           |> fun result -> Result.bind result (fun verified ->
             Cache.publish cache ~asset ~current:(fun () -> true) ~verified
             |> Result.map_error failure)
           |> fun result -> Result.bind result (fun handle ->
             Cache.release_checked cache handle |> Result.map (fun () -> Sync.Asset_unit)
             |> Result.map_error failure))
      | Sync.Retain_staged_file file ->
        Ok (Sync.Asset_retained (Option.bind (Cache.retain_staged cache ~file)
          (fun handle -> Option.map (fun path -> handle,path) (Cache.path cache handle))))
      | Sync.Retain_asset_file handle ->
        Ok (Sync.Asset_retained (Option.bind (Cache.retain cache handle)
          (fun retained -> Option.map (fun path -> retained,path) (Cache.path cache retained))))
      | Sync.Release_staged_file file ->
        Cache.release_staged cache ~file |> Result.map (fun () -> Sync.Asset_unit) |> Result.map_error failure
      | Sync.Release_asset_file handle ->
        Cache.release_checked cache handle |> Result.map (fun () -> Sync.Asset_unit) |> Result.map_error failure
      | Sync.Close_asset_scope ->
        Cache.close_checked cache |> Result.map (fun () -> Sync.Asset_unit) |> Result.map_error failure
      | Sync.Await_asset_operations ->
        await_owner () |> Result.map (fun () -> Sync.Asset_unit)
        |> Result.map_error (fun message -> Sync.Asset_invalid_content message)
      | _ -> Alcotest.fail "Unexpected direct cache operation" in
    let runner_ref = ref None in
    let result_hook = ref (fun (_ : Sync.asset_output) -> ()) in
    let held = Queue.create () in
    let gate predicate =
      let reached, resolve = Eio.Promise.create () in
      result_hook := (fun output -> if predicate output then (
        let released, release = Eio.Promise.create () in
        Queue.add release held;
        ignore (Eio.Promise.try_resolve resolve () : bool);
        Eio.Promise.await released));
      reached in
    let deliver_held ?(keep_gate=false) () =
      if not keep_gate then result_hook := (fun _ -> ());
      while not (Queue.is_empty held) do
        Eio.Promise.resolve (Queue.take held) ()
      done in
    let direct_services : Runner.services =
      { (services ()) with
        owner=(fun ~scope:actual ->
          if actual<>scope then Error "Wrong owner incarnation"
          else match !owner_ref with
          | Some owner -> Ok (identity, owner)
          | None ->
            let store = Runner.sync_upload_store (Option.get !runner_ref) |> Result.get_ok in
            let namespace = Logseq_db_worker_contract.Worker_pure_mutation.namespace_for_owner
              ~origin:scope.account.managed_sync_origin ~user:scope.account.user_id ~graph:scope.graph_id in
            let owner = Logseq_sync_worker_owner.Core.create
              ~clock:(Eio.Stdenv.mono_clock env) ~namespace ~assets ~store
              ~notify_outbox_changed:(fun ~owner:_ ~identity:_ -> Ok ()) in
            let module Owner = (val Logseq_sync_worker_owner.Core.worker_owner owner : Execute.Core.WORKER_OWNER) in
            Owner.bind_runtime ~identity ~database_owner ~limits ~cleanup_seconds:2.
              ~network:{with_admission=(fun _ -> Alcotest.fail "Unexpected owner network admission")}
            |> Result.map_error D.error_message
            |> Result.map (fun () -> owner_ref := Some owner; identity, owner))
      ; asset=(fun request ->
          if request.Sync.scope<>scope then Error Sync.Asset_cancelled
          else let result=fixture_result request.action in
            !result_hook {Sync.request;result};
            result)
      ; await_io=(fun ~scope:_ -> await_owner ())
      } in
    let dependencies = Runner.dependencies ~config:fixture.config ~overlay:fixture.overlay
      ~runtime:(Runner.runtime ~fork:(fun ~sw task -> Eio.Fiber.fork ~sw task)
        ~sleep:(Eio.Time.sleep (Eio.Stdenv.clock env)) |> Result.get_ok)
      ~services:direct_services ~publish:(fun _ -> ()) |> Result.get_ok in
    let upload_current = ref (fun _ -> false) and upload_events = Queue.create () in
    let recovery_results = Queue.create () in
    let state = Core.initial (Core.config ~worker:fixture.config ~sync:(asset_sync_config ())) |> Result.get_ok in
    let sync, coordination = lifecycle_projection fixture.config scope in
    let opened = Core.database_opened ~database_id:"staging-recovery" ~graph_id:scope.graph_id in
    let transition = Core.step state (Core.Lifecycle_snapshot (sync, coordination, [scope, opened])) in
    let recovery_ticket = List.find_map (function Core.Read_uploads ticket -> Some ticket | _ -> None)
      transition.effects |> Option.get in
    let runner = Runner.create ~sw dependencies ~post:(function
      | Core.Asset_cleanup_barrier token ->
        Runner.submit (Option.get !runner_ref) (Core.Asset_cleanup_barrier_reached token)
      | Core.Upload_completed (_, event) -> Queue.add event upload_events
      | Core.Uploads_loaded (_, result) -> Queue.add result recovery_results
      | _ -> ()) ~recovery_current:(fun ticket -> ticket = recovery_ticket) ~upload_current:(fun ticket -> !upload_current ticket)
      ~asset_current:(fun _ -> false) |> Result.get_ok in
    runner_ref := Some runner;
    Fun.protect ~finally:(fun () ->
      deliver_held ();
      Runner.shutdown runner;
      let closed = Assets.close assets in
      Logseq_sync_crypto.Core.retire crypto;
      Logseq_overlay_db.Database.close database |> Result.get_ok;
      match closed with Ok () -> () | Error error -> Alcotest.fail (D.error_message error))
      (fun () ->
        try
          Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 10. (fun () ->
            run {runner;context={scope;encrypted=false;key=None};support;database;crypto;identity;actions;
              fixture_result;fixture_asset=(fun action -> fixture_result action |> Result.get_ok);
              gate;deliver_held;upload_events;set_upload_current=(fun current -> upload_current := current);
              staged_path=(fun file -> Cache.staged_path cache ~file);
              recover_uploads=(fun () ->
                Runner.submit runner (Core.Read_uploads recovery_ticket);
                let rec await turns =
                  if not (Queue.is_empty recovery_results) then Queue.take recovery_results
                  else if turns = 0 then Alcotest.fail "Recovery completion did not arrive"
                  else (Eio.Fiber.yield (); await (turns - 1)) in
                await 1000)})
        with Eio.Time.Timeout ->
          Alcotest.fail "Direct owner did not settle within 10s; check physical IO and fixture gate ownership"))))
;;

let test_import_input_readonly_recovery_and_proof_ack () =
  with_direct_owner(fun fixture->
    let module P=Logseq_db_types.Asset_import.Pure_intent in
    let module W=Logseq_db_worker_contract.Worker_pure_mutation in
    let scope=fixture.context.scope in
    let store=Filename.concat fixture.support "asset-upload-intents.sqlite" in
    let recover()=Runner.recover_import_inputs fixture.runner ~scope ~after:None ~maximum_items:2
      ~maximum_bytes:32768 ~current:(fun()->true) |> Result.get_ok in
    let empty=recover() in
    Alcotest.(check bool) "absent readonly recovery is complete empty" true(empty.items=[] && empty.next=None);
    Alcotest.(check bool) "readonly recovery cannot create store or schema" false(Sys.file_exists store);
    let source=picker_import fixture.support 970 in
    let namespace=W.namespace_for_owner ~origin:scope.account.managed_sync_origin ~user:scope.account.user_id ~graph:scope.graph_id in
    let input=P.create ~namespace source |> Result.get_ok |> P.encode in
    Alcotest.(check bool) "readonly lookup of absent complete input is None" true
      (Runner.confirm_import_input fixture.runner ~scope ~input ~current:(fun()->true)=Ok None);
    Alcotest.(check bool) "readonly lookup cannot create store" false(Sys.file_exists store);
    ignore(Runner.prepare_import fixture.runner ~context:fixture.context source ~current:(fun()->true) |> Result.get_ok);
    let actions= !(fixture.actions) and modified=(Unix.stat store).st_mtime in
    let page=recover() in
    let row=match page.items with [row]->row|_->Alcotest.fail "missing complete prepared source recovery" in
    Alcotest.(check string) "original complete input bytes preserved" input row.input;
    let proof=Option.get row.prepared in
    Alcotest.(check bool) "prepared input proof initially pending" false row.acknowledged;
    Alcotest.(check bool) "actual readonly reopen retains original evidence" true
      (Runner.confirm_import_input fixture.runner ~scope ~input ~current:(fun()->true)=Ok(Some row));
    Alcotest.(check bool) "readonly recovery leaves store mtime unchanged" true((Unix.stat store).st_mtime=modified);
    Alcotest.(check bool) "readonly recovery does no staging/lease/transport work" true(actions= !(fixture.actions));
    Alcotest.(check bool) "stale caller cannot ACK original source" true
      (Result.is_error(Runner.acknowledge_import_input fixture.runner ~scope ~input ~prepared:proof ~current:(fun()->false)));
    Alcotest.(check bool) "forged evidence cannot ACK original source" true
      (Result.is_error(Runner.acknowledge_import_input fixture.runner ~scope ~input ~prepared:(proof^" ") ~current:(fun()->true)));
    Runner.acknowledge_import_input fixture.runner ~scope ~input ~prepared:proof ~current:(fun()->true) |> Result.get_ok;
    let done_=recover() in
    Alcotest.(check bool) "ACK removes only pending recovery membership" true(done_.items=[] && done_.next=None);
    let saved=Runner.confirm_import_input fixture.runner ~scope ~input ~current:(fun()->true) |> Result.get_ok |> Option.get in
    Alcotest.(check bool) "ACK retains original canonical bytes and proof" true(saved.input=input && saved.prepared=Some proof && saved.acknowledged))
;;

let test_worker_sync_io_fence_correlates_real_child () =
  T.with_managed (fun fixture -> Eio_main.run (fun _ -> Eio.Switch.run (fun sw ->
    let reached,reach=Eio.Promise.create () and physical,settle=Eio.Promise.create () in
    let posted=ref [] and outcome=ref None in
    let account : Sync.account_scope =
      {managed_sync_origin=Uri.of_string "https://api.logseq.io";user_id="user-1";
       account_generation=3;presentation_generation=4;lifecycle_generation=5L} in
    let scope=Sync.effect_scope_of_account account in
    let services : Runner.services =
      {post=(fun _ -> Alcotest.fail "Unexpected lifecycle intent");
       owner=(fun ~scope:_->Error "No graph owner is installed");
       asset=(fun _->Error Sync.Asset_cancelled);
       await_io=(fun ~scope:actual->
         Alcotest.(check bool) "original account scope" true (actual=scope);
         Eio.Promise.resolve reach (); Eio.Promise.await physical);
       retire_account=(fun ~account:_->Ok ()); shutdown=(fun()->())} in
    let dependencies=Runner.dependencies
      ~runtime:(Runner.runtime ~fork:(fun ~sw task->Eio.Fiber.fork ~sw task)
        ~sleep:(fun _->()) |> Result.get_ok)
      ~config:fixture.config ~overlay:fixture.overlay ~services ~publish:(fun _->()) |> Result.get_ok in
    let runner=Runner.create ~sw dependencies ~post:(fun event->posted:=event:: !posted)
      ~recovery_current:(fun _->false) ~upload_current:(fun _->false)
      ~asset_current:(fun _->false) |> Result.get_ok in
    Eio.Fiber.fork ~sw (fun()->outcome:=Some(Runner.await_sync_io runner ~scope));
    Eio.Promise.await reached;
    Alcotest.(check bool) "physical completion is required" true (!outcome=None);
    Alcotest.(check int) "no reducer ticket or fence event" 0 (List.length !posted);
    Eio.Promise.resolve settle (Error "physical cleanup failed");
    while !outcome=None do Eio.Fiber.yield () done;
    Alcotest.(check bool) "exact cleanup failure survives forwarding" true
      (!outcome=Some(Error "physical cleanup failed"));
    Runner.shutdown runner;
    Alcotest.(check bool) "stopped Worker cannot mint an I/O ACK" true
      (Result.is_error(Runner.await_sync_io runner ~scope)))))
;;

let test_scope_close_keeps_live_staged_lease () =
  with_direct_owner(fun fixture->
    let source=picker_import fixture.support 960 in
    let staged=match fixture.fixture_asset(Sync.Stage_asset_file
      {operation=source.operation;file_type=source.file_type;source_file=source.source_file})with
      |Sync.Asset_staged value->value.file|_->Alcotest.fail "scope close fixture staging" in
    let lease,path=match fixture.fixture_asset(Sync.Retain_staged_file staged)with
      |Sync.Asset_retained(Some value)->value|_->Alcotest.fail "scope close fixture lease" in
    ignore(fixture.fixture_asset(Sync.Release_staged_file staged));
    let closed=fixture.fixture_result Sync.Close_asset_scope in
    let prematurely_unlinked=not(Sys.file_exists path) in
    let released=fixture.fixture_result(Sync.Release_asset_file lease) in
    let retried=fixture.fixture_result Sync.Close_asset_scope in
    Alcotest.(check bool) "live native lease prevents successful close ACK" true(Result.is_error closed);
    Alcotest.(check bool) "failed close preserves actual retained staged bytes" false prematurely_unlinked;
    Alcotest.(check bool) "original handle still has actual release authority" true(released=Ok Sync.Asset_unit);
    Alcotest.(check bool) "last checked release settles retired bytes" false(Sys.file_exists path);
    Alcotest.(check bool) "close retries after physical lease release" true(retried=Ok Sync.Asset_unit))
;;

(* Physical cache/lease ownership is outside Core.step; exercise the real Sync
   storage owner through the Worker interpreter, not an injected successful ACK. *)
let test_host_scope_settlement_preserves_live_lease () =
  with_direct_owner(fun fixture->
    let source=picker_import fixture.support 961 in
    let prepared=Runner.prepare_import fixture.runner ~context:fixture.context source ~current:(fun()->true) |> Result.get_ok in
    let lease,path=Runner.retain_imported_file fixture.runner ~scope:fixture.context.scope ~operation:source.operation |> Option.get in
    ignore(fixture.fixture_asset(Sync.Release_staged_file prepared.staged_file));
    let first=Runner.settle_host_scope fixture.runner ~scope:fixture.context.scope in
    Alcotest.(check bool) "actual live lease prevents host settlement" true(Result.is_error first);
    Alcotest.(check bool) "failed settlement preserves retained bytes" true(Sys.file_exists path);
    let released=Runner.release_asset_file_checked fixture.runner ~scope:fixture.context.scope ~handle:lease in
    Alcotest.(check bool) "original release succeeds behind admission fence" true(released=Ok());
    let second=Runner.settle_host_scope fixture.runner ~scope:fixture.context.scope in
    Alcotest.(check bool) "host settlement succeeds only after actual release" true(second=Ok());
    Alcotest.(check bool) "settled retired file is removed" false(Sys.file_exists path))
;;

(* The bounded actor queue is outside Core.step. Fill it inside the registered
   snapshot callback before automatic host follow-up; the consumer must not wait
   for itself to make room. All data and account identities are isolated. *)
(* Migrated existing physical after-listen initial-snapshot race. The public Db
   owner executes the real read/cleanup; only unrelated Sync transport is absent. *)
let test_observation_release_waits_for_initial_snapshot () =
  let module Db=Logseq_db_worker in
  let module Fixture=Test_support in
  let module Read=Worker_pure_read in
  let module F=Read.For_worker in
  let require condition message=Alcotest.(check bool)message true condition in
  T.with_managed(fun fixture->
    ignore(Fixture.seed_mirror fixture.config.application_support_directory);
    Eio_main.run(fun env->Eio.Switch.run(fun sw->
      let scope : Sync.graph_scope = {account=account "fixture-user";
        graph_id=Fixture.graph_uuid;graph_generation=1} in
      let services = services () in
      let dependencies=Runner.dependencies ~config:fixture.config ~overlay:fixture.overlay ~services
        ~runtime:(Runner.runtime ~fork:(fun ~sw task->Eio.Fiber.fork ~sw task)
          ~sleep:(Eio.Time.sleep(Eio.Stdenv.clock env)) |> Result.get_ok) ~publish:(fun _->()) |> Result.get_ok in
      let db=Db.create_lifecycle ~sw ~config:(Core.config ~worker:fixture.config ~sync:(asset_sync_config()))
        ~runner_dependencies:dependencies |> Result.get_ok in
      let inspection=Logseq_overlay_db.Database.inspect_mirror
        ~application_support_directory:fixture.config.application_support_directory ~graph_id:scope.graph_id |> Result.get_ok in
      let database=Logseq_overlay_db.Database.open_ ~sw fixture.overlay inspection
        ~graph_name:"Observation snapshot fixture" |> Result.get_ok in
      Fun.protect ~finally:(fun()->Db.shutdown db;
        Logseq_overlay_db.Database.close database |> Result.get_ok)(fun()->
        let opened=Db.attach_database_owner db ~scope (Execute.Core.database_owner database) |> Result.get_ok in
        let sync,coordination=lifecycle_projection fixture.config scope in
        Db.post db (Core.Lifecycle_snapshot(sync,coordination,[scope,opened]));
        let latest=ref None in
        ignore(Db.register_coordination db ~registration:801L ~notify:(fun value->latest:=Some value) |> Result.get_ok);
        Eio.Time.with_timeout_exn(Eio.Stdenv.clock env)3.(fun()->
          while not(Option.exists(fun(snapshot:Db.coordination_snapshot)->
            List.exists(fun(_,state)->state.Db.phase=Db.Graph_open)snapshot.state.residents)!latest)
          do Eio.Fiber.yield()done);
        let owner=Option.get coordination.selected in
        let binding=F.binding ~serial:801L ~incarnation:(Read.worker_incarnation
          ~runtime_epoch:(Journal_worker_ids.Runtime.Epoch.of_int64 29000L)
          ~worker_generation:Journal_worker_ids.Worker.Generation.one)
          ~origin:(Uri.to_string scope.Sync.account.managed_sync_origin) ~user:scope.account.user_id in
        let limits:Worker_pure_data.capability_limits={response_budget_bytes=fixture.config.response_budget_bytes;
          outbox_max_records=4096;outbox_max_bytes=8388608;change_max_items=256;change_max_bytes=65536;
          dispatcher_capacity=256;wire_batch_max_bytes=262144}in
        let session=F.session ~binding ~graph:scope.graph_id ~account:scope.account.account_generation
          ~lifecycle:scope.account.lifecycle_generation ~generation:scope.graph_generation ~scope:owner ~asset_scope:scope ~limits in
        (* Timeline receipts and positions belong to the physical snapshot owner,
           which cannot be exercised through Core.step alone. *)
        let module Timeline = Read.Timeline in
        let budget = Read.read_budget session ~maximum_items:1 ~maximum_bytes:16384 |> Result.get_ok in
        let run : type a. a Read.query -> a = fun query ->
          match Db.read_for_scope db ~scope (F.pack_query budget query) with
          | Read.Query_answer (_, actual, answer) ->
            (match Read.query_result_equality query actual with
             | Some Read.Refl -> Result.get_ok answer
             | None -> Alcotest.fail "Timeline query result type changed") in
        let roots = Timeline.roots ~page:Fixture.page_uuid in
        let packet = run (Read.Timeline_read { query=roots; after=None }) |> Result.get_ok in
        require (Rrbvec.length packet.items <= 1) "Timeline root packets respect source item limits";
        let empty = run (Read.Timeline_read {
          query=Timeline.roots ~page:Fixture.missing_page_uuid; after=None }) |> Result.get_ok in
        require (Rrbvec.is_empty empty.items && empty.next=Timeline.End)
          "empty Timeline scopes retain an exhaustion receipt";
        let day=Read.journal_day 20260902 |> Result.get_ok in
        let dates=run (Read.Timeline_read {
          query=Timeline.dates ~from_day:day ~through_day:day; after=None }) |> Result.get_ok in
        let receipts=Rrbvec.of_list [Timeline.Receipt packet.receipt;
          Timeline.Receipt empty.receipt; Timeline.Receipt dates.receipt] in
        let checked=(run(Read.Timeline_check receipts)).Timeline.results in
        require (Rrbvec.length checked=3 && Rrbvec.fold_left(fun ok value->ok && value=Ok())true checked)
          "one Timeline check validates every retained and exhausted scope";
        (match packet.next with
         | Timeline.End -> ()
         | More after ->
           let next=run(Read.Timeline_read{query=roots;after=Some after}) |> Result.get_ok in
           require (Rrbvec.fold_left(fun ok item->ok && not(Rrbvec.exists(fun old->
             Read.Graph.Uuid.equal old.Worker_pure_data.value.block.uuid item.Worker_pure_data.value.block.uuid)packet.items))true next.items)
             "Timeline root continuation advances without duplicated members";
           require (match run(Read.Timeline_read{
             query=Timeline.roots ~page:Fixture.missing_page_uuid;after=Some after}) with
             |Error(Timeline.Invalid_request _)->true|_->false)
             "Timeline continuation rejects a different scope");
        let tiny=Read.read_budget session ~maximum_items:1 ~maximum_bytes:1 |> Result.get_ok in
        require (match Db.read_for_scope db ~scope (F.pack_query tiny (Read.Timeline_read{query=roots;after=None})) with
          | Read.Query_answer(_,Read.Timeline_read _,Ok(Error(Timeline.Limit_exceeded _)))->true
          | _->false) "Timeline singleton reports its final receipt and DTO byte bound";
        (* Slot reconstruction is performed by the physical snapshot reader,
           not Core.step, so exercise it through the existing public Db fixture. *)
        let missing=Fixture.mutation_uuid 29001 in
        let lookup=Read.Asset_descriptors [missing; missing] in
        let lookup_read=F.pack_query
          (Read.read_budget session ~maximum_items:2 ~maximum_bytes:16384 |> Result.get_ok) lookup in
        let lookup_id=Fixture.mutation_uuid 29002 in
        let _,lookup_answer=Db.register_observation db ~registration:801L ~id:lookup_id
          ~scope ~read:lookup_read ~current:(fun()->true) ~notify:(fun ~epoch:_->()) |> Result.get_ok in
        require (match lookup_answer with
          | Read.Query_answer(_,Read.Asset_descriptors _,Ok value)->value.items=[None;None]
          | _->false) "physical snapshot keeps every repeated missing asset slot";
        require (Db.release_observation db ~registration:801L ~id:lookup_id ~scope=Ok())
          "exact lookup observation releases";
        let read=F.pack_query(Read.read_budget session ~maximum_items:1 ~maximum_bytes:16384 |> Result.get_ok)Read.Graph_info in
    let entered, enter = Eio.Promise.create ()
    and gate, release_gate = Eio.Promise.create () in
    let result, resolve_result = Eio.Promise.create ()
    and released, resolve_released = Eio.Promise.create () in
    let calls = ref 0
    and notifications = ref 0 in
    let current () =
      incr calls;
      if !calls = 2
      then (
        Eio.Promise.resolve enter ();
        Eio.Promise.await gate);
      true
    in
    let id=Fixture.mutation_uuid 29000 in
    let await promise =
      let deadline = Unix.gettimeofday () +. 3. in
      while Eio.Promise.peek promise = None && Unix.gettimeofday () < deadline do
        Eio.Fiber.yield ()
      done;
      match Eio.Promise.peek promise with
      | Some value -> value
      | None -> failwith "physical observation race timed out"
    in
    Fun.protect
      ~finally:(fun () -> ignore (Eio.Promise.try_resolve release_gate () : bool))
      (fun () ->
         Eio.Fiber.fork ~sw (fun () ->
           let value =
             Db.register_observation
               db
               ~registration:801L
               ~id
               ~scope
               ~read
               ~current
               ~notify:(fun ~epoch:_ -> incr notifications)
           in
           Eio.Promise.resolve resolve_result value);
         await entered;
         Eio.Fiber.fork ~sw (fun () ->
           let value =
             Db.release_observation
               db
               ~registration:801L
               ~id
               ~scope
           in
           Eio.Promise.resolve resolve_released value);
         for _ = 1 to 8 do
           Eio.Fiber.yield ()
         done;
         require
           (Eio.Promise.peek released = None)
           "release ACK preceded initial snapshot settlement";
         Eio.Promise.resolve release_gate ();
         require
           (match await result with
            | Error _ -> true
            | _ -> false)
           "cancelled registration returned a readable observation";
         require (await released = Ok ()) "physical release did not acknowledge cleanup";
         require
           (!notifications = 0)
           "initial registration resurrected a retired callback";
         require
           (match
              Db.register_observation
                db
                ~registration:801L
                ~id
                ~scope
                ~read
                ~current:(fun () -> true)
                ~notify:(fun ~epoch:_ -> incr notifications)
            with
            | Error _ -> true
            | _ -> false)
           "retired registration ID was physically allocated again")
      ))))
;;

let test_host_followup_survives_full_actor_queue () =
  T.with_managed(fun fixture->Eio_main.run(fun env->Eio.Switch.run(fun sw->
    let module Db=Logseq_db_worker in
    let forwarded=ref 0 in
    let dependencies=Runner.dependencies ~config:fixture.config ~overlay:fixture.overlay
      ~services:(services ~post:(function Core.Foreground_intent false -> incr forwarded | _ -> ()) ())
      ~runtime:(Runner.runtime ~fork:(fun ~sw task->Eio.Fiber.fork ~sw task)
        ~sleep:(Eio.Time.sleep(Eio.Stdenv.clock env)) |> Result.get_ok)
      ~publish:(fun _->()) |> Result.get_ok in
    let db=Db.create_lifecycle ~sw ~config:(Core.config ~worker:fixture.config ~sync:(asset_sync_config()))
      ~runner_dependencies:dependencies |> Result.get_ok in
    Fun.protect ~finally:(fun()->Db.shutdown db)(fun()->
      let scope : Sync.graph_scope = {account=account "host-queue-next";
        graph_id=Test_support.graph_uuid;graph_generation=1} in
      let sync,coordination=lifecycle_projection fixture.config scope in
      let filled=ref false and latest=ref None in
      let notify (snapshot:Db.coordination_snapshot)=
        latest:=Some snapshot;
        if not !filled then (
          filled:=true;
          for _=1 to 256 do Db.post db(Core.Set_foreground false) done;
          Eio.Fiber.fork ~sw(fun()->Db.post db(Core.Lifecycle_snapshot(sync,coordination,[])))) in
      ignore(Db.register_coordination db ~registration:79L ~notify |> Result.get_ok);
      let previous_scope={scope with account=account "host-queue-old"} in
      let previous_sync,previous_coordination=lifecycle_projection fixture.config previous_scope in
      Db.post db(Core.Lifecycle_snapshot(previous_sync,previous_coordination,[]));
      Eio.Time.with_timeout_exn(Eio.Stdenv.clock env)2.(fun()->
        while !forwarded<256 || not(Option.exists(fun(snapshot:Db.coordination_snapshot)->
          snapshot.state.sync.account=Some scope.account)!latest) do Eio.Fiber.yield()done);
      Alcotest.(check bool) "consumer drains full queue across lifecycle follow-up" true !filled;
      Alcotest.(check int) "every queued foreground intent reaches lifecycle owner" 256 !forwarded))))
;;

let test_checked_release_storage_retry () =
  with_direct_owner(fun fixture->
    let source=picker_import fixture.support 80 in
    let prepared=Runner.prepare_import fixture.runner ~context:fixture.context source
      ~current:(fun()->true) |> Result.get_ok in
    let lease,path=Runner.retain_imported_file fixture.runner ~scope:fixture.context.scope
      ~operation:source.operation |> Option.get in
    ignore(fixture.fixture_asset(Sync.Release_staged_file prepared.staged_file));
    let directory=Filename.dirname path in
    Unix.chmod directory 0o500;
    Fun.protect ~finally:(fun()->Unix.chmod directory 0o700)(fun()->
      Alcotest.(check bool) "physical staging cleanup failure is not a release ACK" true
        (Result.is_error(Runner.release_asset_file_checked fixture.runner ~scope:fixture.context.scope ~handle:lease));
      Alcotest.(check bool) "failed release retains its bytes" true(Sys.file_exists path));
    Alcotest.(check bool) "same exact handle can settle after storage recovers" true
      (Runner.release_asset_file_checked fixture.runner ~scope:fixture.context.scope ~handle:lease=Ok());
    Alcotest.(check bool) "successful retry actually removes retired staging" false(Sys.file_exists path))
;;

let test_discarded_retain_retries_real_storage_cleanup () =
  with_direct_owner(fun fixture->
    let source=picker_import fixture.support 81 in
    let prepared=Runner.prepare_import fixture.runner ~context:fixture.context source
      ~current:(fun()->true) |> Result.get_ok in
    let lease,path=Runner.retain_imported_file fixture.runner ~scope:fixture.context.scope
      ~operation:source.operation |> Option.get in
    ignore(fixture.fixture_asset(Sync.Release_staged_file prepared.staged_file));
    let directory=Filename.dirname path in
    Unix.chmod directory 0o500;
    Fun.protect ~finally:(fun()->Unix.chmod directory 0o700)(fun()->
      Runner.abandon_asset_file fixture.runner ~scope:fixture.context.scope ~handle:lease;
      Alcotest.(check int) "discard retains failed physical cleanup" 1(Runner.unsettled_orphan_retains fixture.runner);
      Alcotest.(check bool) "pending failed cleanup preserves its bytes" true(Sys.file_exists path);
      Alcotest.(check bool) "failed orphan cleanup gates new retain" true
        (Runner.retain_imported_file fixture.runner ~scope:fixture.context.scope ~operation:source.operation=None));
    let deadline=Unix.gettimeofday()+.2. in
    while Runner.unsettled_orphan_retains fixture.runner>0 && Unix.gettimeofday()<deadline do
      Eio.Fiber.yield()
    done;
    Alcotest.(check int) "actual background ACK settles the obligation" 0(Runner.unsettled_orphan_retains fixture.runner);
    Alcotest.(check bool) "actual retry removes the retired staging bytes" false(Sys.file_exists path))
;;

(* The public pure cleanup owner correctly queues both releases. Its state cannot
   reproduce the interpreter's job finishing before queued physical IO starts. *)
let test_asset_cleanup_snapshot_retains_physical_failure () =
  with_direct_owner(fun fixture->
    let source=picker_import fixture.support 83 in
    let prepared=Runner.prepare_import fixture.runner ~context:fixture.context source ~current:(fun()->true) |> Result.get_ok in
    let lease,path=Runner.retain_imported_file fixture.runner ~scope:fixture.context.scope ~operation:source.operation |> Option.get in
    ignore(fixture.fixture_asset(Sync.Release_staged_file prepared.staged_file));
    let directory=Filename.dirname path in
    Unix.chmod directory 0o500;
    Fun.protect ~finally:(fun()->Unix.chmod directory 0o700)(fun()->
      Runner.submit fixture.runner(Core.Run_asset(fixture.context,Logseq_sync_asset_transfer.Core.Release_handle lease));
      let snapshot=Runner.asset_cleanup_snapshot fixture.runner ~scope:fixture.context.scope in
      Alcotest.(check bool) "a failed physical resource cannot produce settlement ACK" true
        (Result.is_error(Runner.await_asset_cleanup fixture.runner snapshot));
      Alcotest.(check bool) "failure retains actual bytes" true(Sys.file_exists path));
    let deadline=Unix.gettimeofday()+.2. in
    while Runner.unsettled_orphan_retains fixture.runner>0 && Unix.gettimeofday()<deadline do Eio.Fiber.yield() done;
    let snapshot=Runner.asset_cleanup_snapshot fixture.runner ~scope:fixture.context.scope in
    Alcotest.(check bool) "settlement succeeds only after actual recovery" true(Runner.await_asset_cleanup fixture.runner snapshot=Ok());
    Alcotest.(check bool) "recovered settlement removed actual bytes" false(Sys.file_exists path))
;;


let retain_fixture_staged_file fixture file =
  match fixture.fixture_asset (Sync.Retain_staged_file file) with
  | Sync.Asset_retained (Some retained) -> retained
  | _ -> Alcotest.fail "Concrete cache owner did not retain staged file"
;;

let test_checked_release_exact_physical_completion () =
  with_direct_owner(fun fixture->
    let source=picker_import fixture.support 60 in
    let prepared=Runner.prepare_import fixture.runner ~context:fixture.context source
      ~current:(fun()->true) |> Result.get_ok in
    let lease,path=retain_fixture_staged_file fixture prepared.staged_file in
    let wrong_scope={fixture.context.scope with graph_generation=fixture.context.scope.graph_generation+1} in
    Alcotest.(check bool) "cancelled scoped release is not ACK" true
      (Result.is_error(Runner.release_asset_file_checked fixture.runner ~scope:wrong_scope ~handle:lease));
    Alcotest.(check bool) "old scope release leaves staged original intact" true (Sys.file_exists path);
    let reached=fixture.gate (fun output->match output.Sync.request.action with
      | Sync.Release_asset_file handle->handle=lease | _->false) in
    let completed=ref None in
    Eio.Fiber.both
      (fun()->completed:=Some(Runner.release_asset_file_checked fixture.runner ~scope:fixture.context.scope ~handle:lease))
      (fun()->Eio.Promise.await reached;
        Alcotest.(check bool) "release ACK waits for actual owner completion" true (!completed=None);
        fixture.deliver_held());
    Alcotest.(check bool) "exact physical release completes" true (!completed=Some(Ok()));
    Runner.shutdown fixture.runner;
    Alcotest.(check bool) "stopped runner cannot acknowledge release" true
      (Result.is_error(Runner.release_asset_file_checked fixture.runner ~scope:fixture.context.scope ~handle:lease)))
;;

let test_asset_cleanup_snapshot_joins_queued_release () =
  with_direct_owner(fun fixture->
    let source=picker_import fixture.support 87 in
    let prepared=Runner.prepare_import fixture.runner ~context:fixture.context source ~current:(fun()->true) |> Result.get_ok in
    let retain()=retain_fixture_staged_file fixture prepared.staged_file |> fst in
    let first=retain() and second=retain() in
    ignore(fixture.fixture_asset(Sync.Release_staged_file prepared.staged_file));
    let second_reached,resolve_second=Eio.Promise.create() in
    let reached=fixture.gate(fun output->match output.Sync.request.action with
      | Sync.Release_asset_file handle when handle=first->true
      | Sync.Release_asset_file handle when handle=second->Eio.Promise.resolve resolve_second();true
      | _->false) in
    let release handle=Runner.submit fixture.runner(Core.Run_asset(fixture.context,
      Logseq_sync_asset_transfer.Core.Release_handle handle)) in
    release first;
    Eio.Promise.await reached;
    release second;
    let snapshot=Runner.asset_cleanup_snapshot fixture.runner ~scope:fixture.context.scope in
    let completed=ref None in
    Eio.Fiber.both
      (fun()->completed:=Some(Runner.await_asset_cleanup fixture.runner snapshot))
      (fun()->fixture.deliver_held ~keep_gate:true();
        Eio.Promise.await second_reached;
        Alcotest.(check bool) "queued physical release has not returned an ACK" true(!completed=None);
        fixture.deliver_held());
    Alcotest.(check bool) "queued real release is joined before settlement ACK" true(!completed=Some(Ok()));
    Alcotest.(check int) "both original resource releases are settled" 0(Runner.unsettled_orphan_retains fixture.runner))
;;

let test_asset_cleanup_snapshot_joins_physical_release () =
  with_direct_owner(fun fixture->
    let source=picker_import fixture.support 82 in
    let prepared=Runner.prepare_import fixture.runner ~context:fixture.context source ~current:(fun()->true) |> Result.get_ok in
    let lease,path=retain_fixture_staged_file fixture prepared.staged_file in
    ignore(fixture.fixture_asset(Sync.Release_staged_file prepared.staged_file));
    let reached=fixture.gate(fun output->match output.Sync.request.action with
      | Sync.Release_asset_file handle->handle=lease|_->false) in
    Runner.submit fixture.runner(Core.Run_asset(fixture.context,Logseq_sync_asset_transfer.Core.Release_handle lease));
    let snapshot=Runner.asset_cleanup_snapshot fixture.runner ~scope:fixture.context.scope in
    let completed=ref None in
    Eio.Fiber.both
      (fun()->completed:=Some(Runner.await_asset_cleanup fixture.runner snapshot))
      (fun()->Eio.Promise.await reached;
        Alcotest.(check bool) "settlement waits for actual checked release result" true(!completed=None);
        fixture.deliver_held());
    Alcotest.(check bool) "joined physical cleanup ACK" true(!completed=Some(Ok()));
    Alcotest.(check bool) "retired actual staging bytes were removed" false(Sys.file_exists path))
;;

let test_asset_cleanup_stop_does_not_wait_for_lost_io () =
  with_direct_owner(fun fixture->
    let source=picker_import fixture.support 84 in
    let prepared=Runner.prepare_import fixture.runner ~context:fixture.context source ~current:(fun()->true) |> Result.get_ok in
    let lease,_=retain_fixture_staged_file fixture prepared.staged_file in
    ignore(fixture.fixture_asset(Sync.Release_staged_file prepared.staged_file));
    let reached=fixture.gate(fun output->match output.Sync.request.action with
      | Sync.Release_asset_file handle->handle=lease|_->false) in
    Runner.submit fixture.runner(Core.Run_asset(fixture.context,Logseq_sync_asset_transfer.Core.Release_handle lease));
    let snapshot=Runner.asset_cleanup_snapshot fixture.runner ~scope:fixture.context.scope in
    let completed=ref None in
    Eio.Fiber.both
      (fun()->completed:=Some(Runner.await_asset_cleanup fixture.runner snapshot))
      (fun()->Eio.Promise.await reached;Runner.shutdown fixture.runner;
        for _=0 to 9 do Eio.Fiber.yield() done;
        let returned=Option.exists Result.is_error !completed in
        fixture.deliver_held();
        Alcotest.(check bool) "stopped cleanup reports failure without waiting for lost callback" true returned))
;;

let test_recovery_staging_failure_is_not_acknowledged () =
  with_direct_owner (fun fixture ->
    let source = picker_import fixture.support 982 in
    let intent = Runner.prepare_import fixture.runner ~context:fixture.context source
      ~current:(fun () -> true) |> Result.get_ok in
    let path = fixture.staged_path intent.staged_file |> Option.get in
    let directory = Filename.dirname path in
    let saved = directory ^ "-synthetic-failure" in
    Unix.rename directory saved;
    let channel = open_out_bin directory in
    close_out channel;
    Fun.protect ~finally:(fun () -> Sys.remove directory; Unix.rename saved directory)
      (fun () ->
        match fixture.recover_uploads () with
        | Ok _ -> Alcotest.fail "Physical staging error must not acknowledge reconciliation"
        | Error message ->
          let cause = "Path component is not a directory" in
          let rec contains offset =
            offset + String.length cause <= String.length message
            && (String.sub message offset (String.length cause) = cause || contains (offset + 1)) in
          Alcotest.(check bool) "physical failure retains ENOTDIR cause" true (contains 0));
    Alcotest.(check bool) "failed recovery preserves original physical source" true (Sys.file_exists path);
    Alcotest.(check bool) "only actual successful prune settles recovery" true
      (fixture.recover_uploads () = Ok [intent]))
;;

let test_recovery_prunes_original_owner_staging () =
  with_direct_owner (fun fixture ->
    let source = picker_import fixture.support 980 in
    let intent = Runner.prepare_import fixture.runner ~context:fixture.context source
      ~current:(fun () -> true) |> Result.get_ok in
    let durable_path = fixture.staged_path intent.staged_file |> Option.get in
    let orphan_source = picker_import fixture.support 981 in
    let orphan = match fixture.fixture_asset (Sync.Stage_asset_file
      {operation=orphan_source.operation;file_type=orphan_source.file_type;source_file=orphan_source.source_file}) with
      | Sync.Asset_staged value -> value.file
      | _ -> Alcotest.fail "Expected real staged orphan" in
    let orphan_path = fixture.staged_path orphan |> Option.get in
    let before = !(fixture.actions) in
    let recovered = match fixture.recover_uploads () with
      | Ok rows -> rows
      | Error message -> Alcotest.fail message in
    Alcotest.(check bool) "real Read_uploads returns original durable intent" true (recovered = [intent]);
    Alcotest.(check bool) "unpublished durable source survives" true (Sys.file_exists durable_path);
    Alcotest.(check bool) "unproven staging is physically pruned" false (Sys.file_exists orphan_path);
    Alcotest.(check bool) "recovery never reaches registration fallback" true (before = !(fixture.actions));
    Alcotest.(check bool) "recovery is idempotent without PUT or metadata" true
      (fixture.recover_uploads () = Ok [intent]))
;;

let test_upload_checkpoint_io () =
  let module Upload = Logseq_db_worker_pure_reducer.Asset_upload in
  with_direct_owner (fun fixture ->
    let source = picker_import fixture.support 900 in
    let intent = Runner.prepare_import fixture.runner ~context:fixture.context source
      ~current:(fun () -> true) |> Result.get_ok in
    let state, instructions = Upload.step
      (Upload.create ~scope:fixture.context.scope ~available:true) (Upload.Start intent) in
    let current = ref true in
    fixture.set_upload_current (fun ticket -> !current && Upload.ticket_current state ticket);
    let instruction = List.hd instructions in
    Runner.submit fixture.runner (Core.Run_upload (fixture.context, instruction));
    let rec await turns =
      if not (Queue.is_empty fixture.upload_events) then Queue.take fixture.upload_events
      else if turns=0 then Alcotest.fail "Upload checkpoint completion did not arrive"
      else (Eio.Fiber.yield (); await (turns-1)) in
    Alcotest.(check bool) "durable acknowledgement" true (await 1000 = Upload.Persisted);
    let db = Sqlite3.db_open ~mode:`READONLY
      (Filename.concat fixture.support "asset-upload-intents.sqlite") in
    let stored = Fun.protect ~finally:(fun () ->
      Alcotest.(check bool) "independent checkpoint reader closes" true (Sqlite3.db_close db))
      (fun () -> Logseq_db_storage.Asset_upload_store.read db ~operation:intent.operation_id
        |> Result.get_ok) in
    Alcotest.(check bool) "survives independent database reopen" true (stored=Some intent);
    current := false;
    Runner.submit fixture.runner (Core.Run_upload (fixture.context, instruction));
    for _=1 to 8 do Eio.Fiber.yield () done;
    Alcotest.(check bool) "stale upload ticket performs no completion" true
      (Queue.is_empty fixture.upload_events))
;;

let test_plaintext_submission_encoding () =
  let module D = Sync_dsl.Core in
  let module C = Logseq_sync_crypto.Core in
  let module Database = Logseq_overlay_db.Database in
  let module Types = Logseq_overlay_db.Types in
  with_direct_owner (fun fixture ->
    let require = function Ok value -> value | Error _ -> Alcotest.fail "submission setup failed" in
    let uuid value = Logseq_db_types.Graph_types.Uuid.of_string value |> require in
    let page = uuid "70000000-0000-4000-8000-000000000001" in
    let mutation_id = uuid "70000000-0000-4000-8000-000000000002" in
    let title = "~:plain-中文-\"quoted\"" in
    let snapshot = Database.current_snapshot fixture.database |> require in
    let expected = Fun.protect ~finally:(fun () -> Database.release_snapshot snapshot)
      (fun () -> match Database.get_pages snapshot [page] |> require with
        | [Types.Missing_page {revision;_}] ->
          Database.write_precondition ~blocks:[] ~pages:[page,revision] ~scopes:[] |> require
        | _ -> Alcotest.fail "new page exists") in
    Database.commit_local fixture.database ~expected
      (Types.Create_journal_page {mutation_id;page;title;journal_day=20261119}) |> require |> ignore;
    let view = Database.inspect_sync fixture.database |> require in
    let prepared, request = Database.begin_outbox_transition fixture.database
      ~expected:(Types.sync_view_token view) (Types.Submit_group [mutation_id]) |> require in
    let request = Option.get request in
    let run crypto operation = C.run crypto ~identity:fixture.identity
      ~check_current:(fun () -> Ok ()) operation in
    let locked = C.create ~identity:fixture.identity ~limits:(D.limits
      ~maximum_items:8 ~maximum_bytes:32768 ~maximum_pending:8 ~maximum_resources:8
      ~steps_per_turn:8 ~maximum_tasks:8 ~maximum_messages:8 ~maximum_message_bytes:32768
      ~maximum_demands:8 ~maximum_active_assets:2 ~foreground_reserve:1
      ~foreground_demand_reserve:1 ~foreground_descriptor_reserve_bytes:128
      ~asset_cache_budget_bytes:16L ~asset_maximum_file_bytes:16 ~asset_pending_budget_bytes:32L
      ~snapshot_maximum_artifact_bytes:4096L ~snapshot_staging_budget_bytes:4096L
      ~snapshot_scratch_budget_bytes:4096L |> require) ~encrypted:true ~backend:C.apple_backend in
    Fun.protect ~finally:(fun () -> C.retire locked) (fun () ->
      Alcotest.(check bool) "encrypted graph cannot downgrade without key" true
        (run locked (D.Protect request) = Error D.Locked));
    let values = match run fixture.crypto (D.Protect request) with
      | Ok values -> values
      | Error error -> Alcotest.fail (D.error_message error) in
    Alcotest.(check bool) "plain upload decodes the serialized title" true
      (List.mem title (List.map snd values));
    let result = Database.apply_outbox_transition fixture.database prepared
      ~encrypted:(Some (request,values)) |> require in
    let wire = Option.get result.submission_batch |> Types.submission_batch_wires
      |> List.hd |> Types.submission_wire_protected_transaction in
    let operations = match Logseq_db_storage.Logseq_sqlite_codec.decode_transit wire with
      | Ok (Array operations) -> operations
      | Ok _ -> Alcotest.fail "submission wire is not a Transit transaction array"
      | Error message -> Alcotest.fail message in
    let select_operations select = List.filter_map select operations in
    let page_entities = select_operations (function
      | Array [Keyword "db/add"; entity; Keyword "block/uuid"; Uuid value]
        when value = Logseq_db_types.Graph_types.Uuid.to_string page -> Some entity
      | _ -> None) in
    let entity = match page_entities with
      | [entity] -> entity
      | _ -> Alcotest.fail "submission must identify exactly one target page entity" in
    let titles = select_operations (function
      | Array [Keyword "db/add"; target; Keyword "block/title"; value]
        when target = entity -> Some value
      | _ -> None) in
    match titles with
    | [String value] ->
      Alcotest.(check string) "target page title survives Transit decoding" title value
    | _ -> Alcotest.fail "target page must have exactly one Transit String block/title")
;;

let () =
  Alcotest.run "logseq db worker effect runner"
    [ "ID token cache", [
      Alcotest.test_case "caps reuse at twenty four hours" `Quick test_id_token_cache_caps_reuse_at_twenty_four_hours;
      Alcotest.test_case "caps reuse one hour before expiration" `Quick test_id_token_cache_caps_reuse_one_hour_before_expiration;
      Alcotest.test_case "does not retain immediately non reusable token" `Quick test_id_token_cache_does_not_retain_immediately_non_reusable_token;
      Alcotest.test_case "rejects invalid responses without retaining them" `Quick test_id_token_cache_rejects_invalid_responses_without_retaining_them;
      Alcotest.test_case "coalesces concurrent misses" `Quick test_id_token_cache_coalesces_concurrent_misses;
      Alcotest.test_case "propagates flutter failure without caching" `Quick test_id_token_cache_propagates_flutter_failure_without_caching;
      Alcotest.test_case "invalidation is credential specific" `Quick test_id_token_cache_invalidation_is_credential_specific;
      Alcotest.test_case "sign out clears entry and cancels waiters" `Quick test_id_token_cache_sign_out_clears_entry_and_cancels_waiters;
      Alcotest.test_case "account replacement makes delayed response inert" `Quick test_id_token_cache_account_replacement_makes_delayed_response_inert;
      Alcotest.test_case "shutdown clears entry and cancels waiters" `Quick test_id_token_cache_shutdown_clears_entry_and_cancels_waiters
    ];
      "contract", [
      Alcotest.test_case "sync and publish instructions are not reduced recursively" `Quick test_sync_and_publish_instructions_are_not_reduced_recursively;
      Alcotest.test_case "direct owner io failure has no event bridge" `Quick test_direct_owner_io_failure_has_no_event_bridge;
      Alcotest.test_case "worker schedule failure completes" `Quick (fun () -> test_worker_schedule_failure_completes ());
      Alcotest.test_case "import input readonly recovery and proof ack" `Quick test_import_input_readonly_recovery_and_proof_ack;
      Alcotest.test_case "worker sync io fence correlates real child" `Quick test_worker_sync_io_fence_correlates_real_child;
      Alcotest.test_case "scope close keeps live staged lease" `Quick test_scope_close_keeps_live_staged_lease;
      Alcotest.test_case "host scope settlement preserves live lease" `Quick test_host_scope_settlement_preserves_live_lease;
      Alcotest.test_case "observation release waits for initial snapshot" `Quick test_observation_release_waits_for_initial_snapshot;
      Alcotest.test_case "host followup survives full actor queue" `Quick test_host_followup_survives_full_actor_queue;
      Alcotest.test_case "checked release storage retry" `Quick test_checked_release_storage_retry;
      Alcotest.test_case "discarded retain retries real storage cleanup" `Quick test_discarded_retain_retries_real_storage_cleanup;
      Alcotest.test_case "asset cleanup snapshot retains physical failure" `Quick test_asset_cleanup_snapshot_retains_physical_failure
      ; Alcotest.test_case "worker encoded exception preserves reason" `Quick
          (test_worker_schedule_failure_completes
            ~failure:(Invalid_argument (Logseq_db_storage.Logseq_sqlite_codec.diagnostic_error
              (Logseq_db_storage.Logseq_sqlite_codec.Unsupported_tag "PRIVATE_SYNTHETIC_PAYLOAD")))
            ~expected_source:"unknown" ~expected_reason:"codecUnsupportedTag")
      ; Alcotest.test_case "checked release exact physical completion" `Quick test_checked_release_exact_physical_completion
      ; Alcotest.test_case "asset cleanup snapshot joins queued release" `Quick test_asset_cleanup_snapshot_joins_queued_release
      ; Alcotest.test_case "asset cleanup snapshot joins physical release" `Quick test_asset_cleanup_snapshot_joins_physical_release
      ; Alcotest.test_case "asset cleanup stop does not wait for lost io" `Quick test_asset_cleanup_stop_does_not_wait_for_lost_io
      ; Alcotest.test_case "recovery prunes original owner staging" `Quick test_recovery_prunes_original_owner_staging
      ; Alcotest.test_case "failed staging recovery is not acknowledged" `Quick test_recovery_staging_failure_is_not_acknowledged
      ; Alcotest.test_case "durable upload checkpoint IO" `Quick test_upload_checkpoint_io
      ; Alcotest.test_case "plaintext submission encoding" `Quick test_plaintext_submission_encoding
    ] ]
;;
