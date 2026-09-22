module Core = Logseq_db_worker_pure_reducer.Core
module Runner = Logseq_db_worker_effect_runner.Effect_runner
module Sync = Logseq_sync_pure_reducer.Core
module T = Logseq_db_worker_test_support.Test_support

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
        let sync_runner =
          Runner.sync_runner
            ~stage_asset:(fun ~scope:_ ~operation:_ ~file_type:_ ~source_file:_ ->
              Error "unexpected staging")
            ~put_upload:(fun ~context:_ _ ~current:_ -> failwith "unexpected upload")
            ~prune_staging:(fun ~scope:_ ~keep:_ -> Ok 0)
            ~release_staging:(fun ~scope:_ ~file:_ -> Ok ())
            ~submit_asset:(fun ~context:_ ~current:_ ~post:_ _ ->
              failwith "unexpected asset IO")
            ~delete_assets:(fun _ -> Ok ())
            ~close_assets:(fun _ -> ())
            ~retain_staged_file:(fun ~scope:_ ~file:_ -> None)
            ~retain_asset_file:(fun ~scope:_ ~handle:_ -> None)
            ~release_asset_file:(fun ~scope:_ ~handle:_ -> ())
            ~submit:(fun runner_effect -> submitted := runner_effect :: !submitted)
            ~shutdown:(fun () -> ())
            ()
        in
        let dependencies =
          Runner.dependencies
            ~runtime
            ~config:fixture.config
            ~overlay:fixture.overlay
            ~sync_runner
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
        let limits =
          Sync.limits
            ~maximum_response_bytes:1024
            ~maximum_artifact_bytes:1024
            ~submission_batch_size:1
          |> Result.get_ok
        in
        let sync =
          Sync.config ~managed_sync_origin:(Uri.of_string "https://api.logseq.io") ~limits
          |> Result.get_ok
          |> Sync.initial
          |> Result.get_ok
        in
        let transition = Sync.step sync (Restore_local_account { user_id = "user-1" }) in
        List.iter
          (function
            | Sync.Run runner_effect -> Runner.submit runner (Core.Run_sync runner_effect)
            | Sync.Publish output ->
              Runner.submit runner (Core.Publish (Core.Sync_output output))
            | Sync.Delegate _ -> ())
          transition.effects;
        Alcotest.check Alcotest.int "sync runner receives run" 1 (List.length !submitted);
        Alcotest.check Alcotest.int "host receives publish" 1 (List.length !published);
        Alcotest.check Alcotest.int "runner never calls reducer" 0 (List.length !posted);
        Runner.shutdown runner)))
;;

let test_upload_checkpoint_io () =
  let module U = Logseq_db_worker_pure_reducer.Asset_upload in
  let module I = Logseq_db_types.Asset_upload_intent in
  let module Cache = Logseq_sync_effect_runner.Asset_cache in
  let module Store = Logseq_db_storage.Asset_upload_store in
  let uuid n =
    Logseq_db_types.Graph_types.Uuid.of_string
      (Printf.sprintf "00000000-0000-4000-8000-%012d" n)
    |> Result.get_ok
  in
  let scope : Sync.graph_scope =
    { account = account "user-1"; graph_id = uuid 1; graph_generation = 1 }
  in
  let intent =
    I.prepare
      ~replace_reference:None
      ~operation_id:(uuid 2)
      ~origin:(Uri.to_string scope.account.managed_sync_origin)
      ~account:"user-1"
      ~graph:(uuid 1)
      ~asset:(uuid 3)
      ~version:
        (Logseq_db_types.Asset_descriptor.version
           ~checksum:(String.make 64 'a')
           ~file_type:"png"
         |> Result.get_ok)
      ~title:"Imported image"
      ~size:4L
      ~staged_file:"fixture.bin"
      ~target:(uuid 4)
      ~local_mutation:(uuid 5)
      ~metadata_mutation:(uuid 6)
    |> Result.get_ok
  in
  let state, instructions = U.step (U.create ~scope ~available:true) (Start intent) in
  let instruction = List.hd instructions in
  T.with_managed (fun fixture ->
    Eio_main.run (fun _ ->
      Eio.Switch.run (fun sw ->
        let create_cache () =
          Cache.create
            ~root:fixture.config.application_support_directory
            ~scope
            ~budget_bytes:16L
            ~maximum_file_bytes:16
          |> Result.get_ok
        in
        let cache = ref (create_cache ()) in
        let source_file =
          Filename.concat fixture.config.application_support_directory "picker.bin"
        in
        Out_channel.with_open_bin source_file (fun output -> output_string output "file");
        let orphan =
          Cache.stage
            !cache
            ~operation:(uuid 88)
            ~file_type:"bin"
            ~source_file
            ~pending_budget_bytes:16L
          |> Result.get_ok
        in
        let orphan_path = Option.get (Cache.staged_path !cache ~file:orphan.file) in
        let published = ref [] in
        let posted = ref [] in
        let current = ref true in
        let runtime =
          Runner.runtime
            ~fork:(fun ~sw:_ f -> f ())
            ~sleep:(fun _ -> failwith "unexpected wait")
          |> Result.get_ok
        in
        let stage_calls = ref 0 in
        let sync_runner =
          Runner.sync_runner
            ~stage_asset:(fun ~scope:_ ~operation ~file_type ~source_file ->
              incr stage_calls;
              Cache.stage
                !cache
                ~operation
                ~file_type
                ~source_file
                ~pending_budget_bytes:16L
              |> Result.map (fun staged ->
                staged.Cache.file, staged.checksum, staged.size)
              |> Result.map_error (fun _ -> "stage failed"))
            ~put_upload:(fun ~context:_ _ ~current:_ -> failwith "unexpected PUT")
            ~prune_staging:(fun ~scope:_ ~keep ->
              Cache.prune_staged !cache ~keep
              |> Result.map_error (fun _ -> "prune failed"))
            ~release_staging:(fun ~scope:release_scope ~file ->
              Alcotest.(check bool)
                "release uses the original scope"
                true
                (release_scope = scope);
              Cache.release_staged !cache ~file
              |> Result.map_error (fun _ -> "cache unavailable"))
            ~submit_asset:(fun ~context:_ ~current:_ ~post:_ _ ->
              failwith "unexpected GET")
            ~delete_assets:(fun _ -> Ok ())
            ~close_assets:(fun _ -> ())
            ~retain_staged_file:(fun ~scope:_ ~file ->
              Option.bind (Cache.retain_staged !cache ~file) (fun lease ->
                Option.map (fun path -> lease, path) (Cache.path !cache lease)))
            ~retain_asset_file:(fun ~scope:_ ~handle:_ -> None)
            ~release_asset_file:(fun ~scope:_ ~handle -> Cache.release !cache handle)
            ~submit:(fun _ -> ())
            ~shutdown:(fun () -> ())
            ()
        in
        let dependencies =
          Runner.dependencies
            ~runtime
            ~config:fixture.config
            ~overlay:fixture.overlay
            ~sync_runner
            ~publish:(fun output -> published := output :: !published)
          |> Result.get_ok
        in
        let runner =
          Runner.create
            ~sw
            dependencies
            ~post:(fun event -> posted := event :: !posted)
            ~recovery_current:(fun _ -> false)
            ~upload_current:(fun ticket -> !current && U.ticket_current state ticket)
            ~asset_current:(fun _ -> false)
          |> Result.get_ok
        in
        Runner.submit
          runner
          (Core.Run_upload ({ scope; encrypted = false; key = None }, instruction));
        Alcotest.(check bool)
          "durable acknowledgement"
          true
          (match !posted with
           | [ Core.Upload_completed (_, U.Persisted) ] -> true
           | _ -> false);
        let db =
          Sqlite3.db_open
            (Filename.concat
               fixture.config.application_support_directory
               "asset-upload-intents.sqlite")
        in
        let stored =
          Logseq_db_storage.Asset_upload_store.read db ~operation:intent.operation_id
          |> Result.get_ok
        in
        ignore (Sqlite3.db_close db);
        Alcotest.(check bool)
          "survives independent database reopen"
          true
          (stored = Some intent);
        current := false;
        posted := [];
        Runner.submit
          runner
          (Core.Run_upload ({ scope; encrypted = false; key = None }, instruction));
        Alcotest.(check int) "stale ticket performs no completion" 0 (List.length !posted);
        let source : Logseq_db_types.Asset_import.t =
          { operation = uuid 10
          ; asset = uuid 11
          ; target = uuid 4
          ; local_mutation = uuid 12
          ; replace_reference = None
          ; metadata_mutation = uuid 13
          ; source_file
          ; title = "Imported image"
          ; file_type = "png"
          }
        in
        let context : Sync.asset_context = { scope; encrypted = false; key = None } in
        Alcotest.(check bool)
          "stale import does not stage"
          true
          (Result.is_error
             (Runner.prepare_import runner ~context source ~current:(fun () -> false)));
        Alcotest.(check int) "stale selection has no IO" 0 !stage_calls;
        Alcotest.(check bool)
          "stale import leaves orphan untouched"
          true
          (Sys.file_exists orphan_path);
        let prepared =
          Runner.prepare_import runner ~context source ~current:(fun () -> true)
          |> Result.get_ok
        in
        let db =
          Sqlite3.db_open
            (Filename.concat
               fixture.config.application_support_directory
               "asset-upload-intents.sqlite")
        in
        Alcotest.(check bool)
          "import reconciles orphan before staging"
          false
          (Sys.file_exists orphan_path);
        let durable =
          Logseq_db_storage.Asset_upload_store.read db ~operation:source.operation
          |> Result.get_ok
        in
        ignore (Sqlite3.db_close db);
        Alcotest.(check bool)
          "import is durable before success"
          true
          (durable = Some prepared && prepared.phase = I.Prepared);
        let lease, preview =
          match Runner.retain_imported_file runner ~scope ~operation:source.operation with
          | Some preview -> preview
          | None -> Alcotest.fail "durable import preview unavailable"
        in
        Alcotest.(check bool) "preview uses staged bytes" true (Sys.file_exists preview);
        Alcotest.(check bool)
          "another graph cannot acquire import"
          true
          (Runner.retain_imported_file
             runner
             ~scope:{ scope with graph_id = uuid 90 }
             ~operation:source.operation
           = None);
        Alcotest.(check bool)
          "another account cannot acquire import"
          true
          (Runner.retain_imported_file
             runner
             ~scope:{ scope with account = { scope.account with user_id = "other" } }
             ~operation:source.operation
           = None);
        Runner.release_asset_file runner ~scope ~handle:lease;
        let duplicate =
          Runner.prepare_import
            runner
            ~context
            { source with source_file = "picker-no-longer-available" }
            ~current:(fun () -> true)
          |> Result.get_ok
        in
        Alcotest.(check bool)
          "same identity restores its intent"
          true
          (duplicate = prepared);
        Alcotest.(check int)
          "duplicate import never recopies picker source"
          1
          !stage_calls;
        Alcotest.(check bool)
          "changed identity payload is rejected"
          true
          (Result.is_error
             (Runner.prepare_import
                runner
                ~context
                { source with asset = uuid 99 }
                ~current:(fun () -> true)));
        let source_path =
          Option.get (Cache.staged_path !cache ~file:prepared.staged_file)
        in
        Sys.remove source_file;
        let checkpoint_path =
          Filename.concat
            fixture.config.application_support_directory
            "asset-upload-intents.sqlite"
        in
        let db = Sqlite3.db_open checkpoint_path in
        let complete =
          List.fold_left
            (fun previous phase ->
               let next = I.advance previous phase |> Result.get_ok in
               Store.save db ~expected:(Some previous.I.revision) next |> Result.get_ok;
               next)
            prepared
            [ I.Local_committed; Uploading; Remote_stored; Metadata_pending; Complete ]
        in
        ignore (Sqlite3.db_close db);
        let restore_terminal () =
          let db = Sqlite3.db_open checkpoint_path in
          let restored =
            Store.list
              db
              ~origin:complete.origin
              ~account:complete.account
              ~graph:complete.graph
              ~after:None
              ~limit:16
            |> Result.get_ok
          in
          ignore (Sqlite3.db_close db);
          let terminal =
            List.find (fun i -> i.I.operation_id = complete.operation_id) restored
          in
          Alcotest.(check bool)
            "terminal checkpoint survives database reopen"
            true
            (terminal = complete);
          let _, instructions =
            U.step (U.create ~scope ~available:false) (Restore terminal)
          in
          match instructions with
          | [ (U.Release_staging _ as instruction) ] -> instruction
          | _ -> Alcotest.fail "terminal recovery attempted non-cleanup work"
        in
        Cache.close !cache;
        Runner.submit runner (Core.Run_upload (context, restore_terminal ()));
        Alcotest.(check bool)
          "unavailable cache retains pending source"
          true
          (Sys.file_exists source_path);
        Alcotest.(check bool)
          "failed cleanup is observable"
          true
          (List.exists
             (function
               | Core.Diagnostic "cache unavailable" -> true
               | _ -> false)
             !published);
        Runner.shutdown runner;
        cache := create_cache ();
        let restarted =
          Runner.create
            ~sw
            dependencies
            ~post:(fun event -> posted := event :: !posted)
            ~recovery_current:(fun _ -> false)
            ~upload_current:(fun _ -> false)
            ~asset_current:(fun _ -> false)
          |> Result.get_ok
        in
        let restored_import =
          Runner.prepare_import restarted ~context source ~current:(fun () -> true)
          |> Result.get_ok
        in
        Alcotest.(check bool)
          "reconciliation retains durable terminal staging"
          true
          (restored_import = complete && Sys.file_exists source_path);
        let cleanup = restore_terminal () in
        Runner.submit restarted (Core.Run_upload (context, cleanup));
        Alcotest.(check bool)
          "restart completes durable terminal cleanup"
          false
          (Sys.file_exists source_path);
        published := [];
        Runner.submit restarted (Core.Run_upload (context, restore_terminal ()));
        Alcotest.(check int) "repeated cleanup is idempotent" 0 (List.length !published);
        Runner.shutdown restarted;
        Cache.close !cache)))
;;

let () =
  Alcotest.run
    "logseq db worker effect runner"
    [ ( "ID token cache"
      , [ Alcotest.test_case
            "caps reuse at twenty-four hours"
            `Quick
            test_id_token_cache_caps_reuse_at_twenty_four_hours
        ; Alcotest.test_case
            "caps reuse one hour before expiration"
            `Quick
            test_id_token_cache_caps_reuse_one_hour_before_expiration
        ; Alcotest.test_case
            "does not retain immediately non-reusable token"
            `Quick
            test_id_token_cache_does_not_retain_immediately_non_reusable_token
        ; Alcotest.test_case
            "rejects invalid responses without retaining them"
            `Quick
            test_id_token_cache_rejects_invalid_responses_without_retaining_them
        ; Alcotest.test_case
            "coalesces concurrent misses"
            `Quick
            test_id_token_cache_coalesces_concurrent_misses
        ; Alcotest.test_case
            "propagates Flutter failure without caching"
            `Quick
            test_id_token_cache_propagates_flutter_failure_without_caching
        ; Alcotest.test_case
            "invalidation is credential-specific"
            `Quick
            test_id_token_cache_invalidation_is_credential_specific
        ; Alcotest.test_case
            "sign-out clears entry and cancels waiters"
            `Quick
            test_id_token_cache_sign_out_clears_entry_and_cancels_waiters
        ; Alcotest.test_case
            "account replacement makes delayed response inert"
            `Quick
            test_id_token_cache_account_replacement_makes_delayed_response_inert
        ; Alcotest.test_case
            "shutdown clears entry and cancels waiters"
            `Quick
            test_id_token_cache_shutdown_clears_entry_and_cancels_waiters
        ] )
    ; ( "contract"
      , [ Alcotest.test_case
            "durable upload checkpoint IO"
            `Quick
            test_upload_checkpoint_io
        ; Alcotest.test_case
            "sync and publish delegation"
            `Quick
            test_sync_and_publish_instructions_are_not_reduced_recursively
        ] )
    ]
;;
