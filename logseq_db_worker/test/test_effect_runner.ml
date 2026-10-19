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

module Sync_runner = Logseq_sync_effect_runner.Effect_runner

let asset_io_runner ~env ~sw ~support ~post =
  let module R = Sync_runner in
  let dependencies =
    R.dependencies
      ~runtime:
        (R.runtime ~fork:(fun ~sw:_ task -> task ()) ~sleep:(fun _ -> ()) |> Result.get_ok)
      ~transport:
        (R.transport
           ~tls_authenticator:(R.system_tls_authenticator () |> Result.get_ok)
           ~network:(Eio.Stdenv.net env)
           ~clock:(Eio.Stdenv.clock env)
           ~websocket_liveness:R.Disabled
         |> Result.get_ok)
      ~local_store:
        (R.local_store
           ~asset_cache_budget_bytes:16L
           ~asset_maximum_file_bytes:16
           ~asset_pending_budget_bytes:16L
           ~application_support_directory:support
           ()
         |> Result.get_ok)
      ~artifact_store:
        (R.artifact_store ~staging_directory:(Filename.concat support "snapshot-staging")
         |> Result.get_ok)
      ~secrets:
        (R.secrets
           ~unlock_private_key:
             (fun
               ~managed_sync_origin:_ ~user_id:_ ~password:_ ~private_key_package:_ ->
             Error "unused")
           ~unlock_graph_key:
             (fun
               ~managed_sync_origin:_ ~user_id:_ ~encrypted_graph_key:_ -> Error "unused")
           ~load_wrapped_graph_key:(fun ~managed_sync_origin:_ ~user_id:_ ~graph_id:_ ->
             Error (R.Wrapped_graph_key_unavailable "unused"))
           ~verify_and_save_wrapped_graph_key:
             (fun
               ~managed_sync_origin:_ ~user_id:_ ~graph_id:_ ~encrypted_graph_key:_ ->
             Error "unused")
           ~delete_account_secrets:(fun ~managed_sync_origin:_ ~user_id:_ -> Ok ())
         |> Result.get_ok)
      ~crypto:
        (R.crypto
           ~encrypt_aes_gcm:(fun ~key:_ ~plaintext:_ -> Error "unused")
           ~decrypt_aes_gcm:(fun ~key:_ ~iv:_ ~ciphertext:_ -> Error "unused")
         |> Result.get_ok)
      ~id_token_provider:
        (R.id_token_provider
           ~acquire:(fun _ -> Error "test must not use network")
           ~invalidate:(fun _ ~token:_ -> ()))
    |> Result.get_ok
  in
  R.create ~sw dependencies ~post |> Result.get_ok
;;

let test_unlock_runner_logging () =
  let path = Filename.temp_file "journal-unlock-runner-log-" "" in
  let saved = Unix.dup Unix.stderr in
  let output = Unix.openfile path [Unix.O_WRONLY; Unix.O_TRUNC] 0o600 in
  let previous = Sys.getenv_opt "JOURNAL_UNLOCK_DIAGNOSTICS" in
  Unix.putenv "JOURNAL_UNLOCK_DIAGNOSTICS" "1";
  Unix.dup2 output Unix.stderr;
  let has text value =
    let n = String.length value in
    let rec loop i = i + n <= String.length text
      && (String.sub text i n = value || loop (i + 1)) in loop 0
  in
  Fun.protect ~finally:(fun () ->
    flush stderr; Unix.dup2 saved Unix.stderr; Unix.close saved; Unix.close output;
    Unix.putenv "JOURNAL_UNLOCK_DIAGNOSTICS" (Option.value previous ~default:""); Sys.remove path)
    (fun () ->
      Eio_main.run (fun env -> Eio.Switch.run (fun sw -> T.with_managed (fun fixture ->
        let completions = ref [] in
        let runner = asset_io_runner ~env ~sw
          ~support:fixture.config.application_support_directory
          ~post:(fun event -> completions := event :: !completions) in
        let limits = Sync.limits ~maximum_response_bytes:1024 ~maximum_artifact_bytes:1024
          ~submission_batch_size:1 |> Result.get_ok in
        let config = Sync.config ~managed_sync_origin:(Uri.of_string "https://example.invalid")
          ~limits |> Result.get_ok in
        let state = Sync.initial config |> Result.get_ok in
        let state = (Sync.step state (Sync.Sign_in_requested {account_generation=0; presentation_generation=0})).next in
        let transition = Sync.step state (Sync.Account_authenticated {user_id=Some "LOG_SECRET_USER"}) in
        let request = List.find_map (function
          | Sync.Run (Sync.Request (_, Sync.Fetch_catalog _) as request) -> Some request
          | _ -> None) transition.effects |> Option.get in
        Sync_runner.submit runner request;
        Alcotest.(check bool) "runner still posts typed completion" true (!completions <> []);
        Sync_runner.shutdown runner)));
      flush stderr;
      let logs = In_channel.with_open_bin path In_channel.input_all in
      List.iter (fun value -> Alcotest.(check bool) value true (has logs value))
        [ "source=runner"; "request=fetch-catalog"; "phase=begin"; "phase=end"
        ; "result=effect-failed"; "failure_category=token"; "elapsed_ms="; "op=" ];
      List.iter (fun value -> Alcotest.(check bool) "sensitive runner value excluded" false (has logs value))
        [ "LOG_SECRET_USER"; "test must not use network"; "example.invalid" ])
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

let admitted_asset_state graph_id =
  let limits =
    Sync.limits
      ~maximum_response_bytes:1024
      ~maximum_artifact_bytes:1024
      ~submission_batch_size:1
    |> Result.get_ok
  in
  let initial =
    Sync.config ~managed_sync_origin:(Uri.of_string "https://api.logseq.io") ~limits
    |> Result.get_ok
    |> Sync.initial
    |> Result.get_ok
  in
  let graph : Sync.graph =
    { graph_id
    ; name = "Upload checkpoint fixture"
    ; schema = { major = 1; minor = 0; exact = true }
    ; encrypted = false
    }
  in
  let initial = (Sync.step initial (Sync.Sign_in_requested {account_generation=0; presentation_generation=0})).next in
  let authenticated =
    Sync.step initial (Sync.Account_authenticated { user_id = Some "user-1" })
  in
  let catalog =
    List.find_map
      (function
        | Sync.Run (Sync.Request (ticket, Sync.Fetch_catalog _)) ->
          Some
            (Sync.step
               authenticated.next
               (Sync.Runner_completed (Sync.Completion (ticket, Ok [ graph ]))))
        | _ -> None)
      authenticated.effects
    |> Option.get
  in
  let selected = Sync.step catalog.next (Sync.Graph_selected graph.graph_id) in
  let mirror =
    List.find_map
      (function
        | Sync.Delegate (Sync.Inspect_mirror request) -> Some request
        | _ -> None)
      selected.effects
    |> Option.get
  in
  let admitted =
    Sync.step selected.next (Sync.Mirror_inspected (Sync.Mirror_available mirror))
  in
  let context = Sync.asset_context admitted.next |> Option.get in
  admitted.next, context
;;

type asset_bridge_fixture =
  { runner : Runner.t
  ; context : Sync.asset_context
  ; support : string
  ; gate : (Sync.asset_output -> bool) -> deliver_first:bool -> unit Eio.Promise.t
  ; deliver_held : unit -> unit
  ; held_path : string option ref
  ; actions : Sync.asset_action list ref
  ; fixture_asset : Sync.asset_action -> Sync.asset_value
  }

let with_asset_bridge run =
  T.with_managed (fun fixture ->
    Eio_main.run (fun env ->
      Eio.Switch.run (fun sw ->
        let graph_id =
          Logseq_db_types.Graph_types.Uuid.of_string
            "22000000-0000-4000-8000-000000000001"
          |> Result.get_ok
        in
        let admitted, context = admitted_asset_state graph_id in
        let state = ref admitted in
        let active_runner = ref None in
        let io_runner = ref None in
        let actions = ref [] in
        let output_handler = ref (fun (_ : Sync.asset_output) -> false) in
        let held = Queue.create () in
        let held_path = ref None in
        let fixture_output = ref None in
        let post = function
          | Core.Sync_event event ->
            (match event with
             | Sync.Asset_requested request -> actions := request.action :: !actions
             | _ -> ());
            let transition = Sync.step !state event in
            state := transition.next;
            List.iter
              (function
                | Sync.Run runner_effect ->
                  Sync_runner.submit (Option.get !io_runner) runner_effect
                | Sync.Publish (Sync.Asset_finished output) ->
                  if String.starts_with ~prefix:"fixture:" output.request.operation
                  then fixture_output := Some output.result
                  else if not (!output_handler output)
                  then
                    Runner.submit
                      (Option.get !active_runner)
                      (Core.Deliver_asset_result output)
                | Sync.Publish _ -> ()
                | Sync.Delegate _ -> Alcotest.fail "unexpected bridge graph effect")
              transition.effects
          | _ -> ()
        in
        io_runner
        := Some
             (asset_io_runner
                ~env
                ~sw
                ~support:fixture.config.application_support_directory
                ~post:(fun event -> post (Core.Sync_event event)));
        let sync_runner =
          Runner.sync_runner
            ~submit:(fun runnable -> Sync_runner.submit (Option.get !io_runner) runnable)
            ~shutdown:(fun () -> Sync_runner.shutdown (Option.get !io_runner))
            ()
        in
        let dependencies =
          Runner.dependencies
            ~runtime:
              (Runner.runtime ~fork:(fun ~sw:_ task -> task ()) ~sleep:(fun _ -> ())
               |> Result.get_ok)
            ~config:fixture.config
            ~overlay:fixture.overlay
            ~sync_runner
            ~publish:(fun _ -> ())
          |> Result.get_ok
        in
        let runner =
          Runner.create
            ~sw
            dependencies
            ~post
            ~recovery_current:(fun _ -> false)
            ~upload_current:(fun _ -> false)
            ~asset_current:(fun _ -> false)
          |> Result.get_ok
        in
        active_runner := Some runner;
        let serial = ref 0 in
        let fixture_asset action =
          incr serial;
          fixture_output := None;
          post
            (Core.Sync_event
               (Sync.Asset_requested
                  { scope = context.scope
                  ; operation = "fixture:" ^ string_of_int !serial
                  ; action
                  }));
          Option.get !fixture_output |> Result.get_ok
        in
        let path_of_output (output : Sync.asset_output) =
          match output.result with
          | Ok (Sync.Asset_staged { file; _ }) ->
            (match fixture_asset (Sync.Retain_staged_file file) with
             | Sync.Asset_retained (Some (lease, path)) ->
               ignore (fixture_asset (Sync.Release_asset_file lease));
               Some path
             | _ -> Alcotest.fail "gated staged resource unavailable")
          | Ok (Sync.Asset_retained (Some (_, path))) -> Some path
          | _ -> None
        in
        let gate predicate ~deliver_first =
          let reached, resolve = Eio.Promise.create () in
          let never, _ = Eio.Promise.create () in
          (output_handler
           := fun output ->
                if not (predicate output)
                then false
                else (
                  held_path := path_of_output output;
                  Queue.add (output, deliver_first) held;
                  if deliver_first
                  then Runner.submit runner (Core.Deliver_asset_result output);
                  Eio.Promise.resolve resolve ();
                  if deliver_first then Eio.Promise.await never;
                  true));
          reached
        in
        let deliver_held () =
          (output_handler := fun _ -> false);
          Queue.iter
            (fun (output, delivered) ->
               if not delivered
               then Runner.submit runner (Core.Deliver_asset_result output))
            held;
          Queue.clear held
        in
        Fun.protect
          ~finally:(fun () -> Runner.shutdown runner)
          (fun () ->
             run
               { runner
               ; context
               ; support = fixture.config.application_support_directory
               ; gate
               ; deliver_held
               ; held_path
               ; actions
               ; fixture_asset
               }))))
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

let cancelled_stage_output deliver_first () =
  with_asset_bridge (fun fixture ->
    let source = picker_import fixture.support 10 in
    let reached =
      fixture.gate
        (fun output ->
           match output.Sync.request.action with
           | Sync.Stage_asset_file _ -> true
           | _ -> false)
        ~deliver_first
    in
    Eio.Fiber.first
      (fun () ->
         ignore
           (Runner.prepare_import
              fixture.runner
              ~context:fixture.context
              source
              ~current:(fun () -> true));
         Alcotest.fail "gated import unexpectedly finished")
      (fun () -> Eio.Promise.await reached);
    let path = Option.get !(fixture.held_path) in
    if not deliver_first
    then
      Alcotest.(check bool)
        "queued accepted staging still exists"
        true
        (Sys.file_exists path);
    fixture.deliver_held ();
    Alcotest.(check bool)
      "canceled caller releases accepted staging"
      false
      (Sys.file_exists path);
    Alcotest.(check bool)
      "staging cleanup requested through reducer"
      true
      (List.exists
         (function
           | Sync.Release_staged_file _ -> true
           | _ -> false)
         !(fixture.actions));
    let db =
      Sqlite3.db_open (Filename.concat fixture.support "asset-upload-intents.sqlite")
    in
    let durable =
      Logseq_db_storage.Asset_upload_store.read db ~operation:source.operation
      |> Result.get_ok
    in
    ignore (Sqlite3.db_close db);
    Alcotest.(check bool)
      "cancel before staging acceptance persists no import"
      true
      (durable = None))
;;

let test_cancelled_retained_output () =
  with_asset_bridge (fun fixture ->
    let source = picker_import fixture.support 20 in
    let prepared =
      Runner.prepare_import
        fixture.runner
        ~context:fixture.context
        source
        ~current:(fun () -> true)
      |> Result.get_ok
    in
    let reached =
      fixture.gate
        (fun output ->
           match output.Sync.request.action with
           | Sync.Retain_staged_file _ -> true
           | _ -> false)
        ~deliver_first:false
    in
    Eio.Fiber.first
      (fun () ->
         ignore
           (Runner.retain_imported_file
              fixture.runner
              ~scope:fixture.context.scope
              ~operation:source.operation);
         Alcotest.fail "gated lease acquisition unexpectedly finished")
      (fun () -> Eio.Promise.await reached);
    let path = Option.get !(fixture.held_path) in
    fixture.deliver_held ();
    Alcotest.(check bool)
      "canceled lease acquisition requests release"
      true
      (List.exists
         (function
           | Sync.Release_asset_file _ -> true
           | _ -> false)
         !(fixture.actions));
    ignore (fixture.fixture_asset (Sync.Release_staged_file prepared.staged_file));
    Alcotest.(check bool)
      "released lease no longer pins staged bytes"
      false
      (Sys.file_exists path))
;;

let test_db_shutdown_accepts_late_staging_completion () =
  let module Db = Logseq_db_worker in
  T.with_managed (fun fixture ->
    Eio_main.run (fun env ->
      Eio.Switch.run (fun sw ->
        let support = fixture.config.application_support_directory in
        let source = picker_import support 40 in
        let graph : Sync.graph =
          { graph_id = source.target
          ; name = "Shutdown fixture"
          ; schema = { major = 65; minor = 33; exact = true }
          ; encrypted = false
          }
        in
        let db = ref None in
        let io_runner = ref None in
        let catalog_ready, catalog_resolve = Eio.Promise.create () in
        let scope_ready, scope_resolve = Eio.Promise.create () in
        let stage_ready, stage_resolve = Eio.Promise.create () in
        let path_ready, path_resolve = Eio.Promise.create () in
        let stage_completion = ref None in
        let cleanup_actions = ref [] in
        let post event =
          match event with
          | Sync.Runner_completed (Sync.Asset_completion (_, Ok (Sync.Asset_staged _))) ->
            stage_completion := Some event;
            Eio.Promise.resolve stage_resolve ()
          | Sync.Runner_completed
              (Sync.Asset_completion (_, Ok (Sync.Asset_retained (Some (_, path))))) ->
            Eio.Promise.resolve path_resolve path;
            Db.post (Option.get !db) (Core.Sync_event event)
          | event -> Db.post (Option.get !db) (Core.Sync_event event)
        in
        io_runner := Some (asset_io_runner ~env ~sw ~support ~post);
        let sync_runner =
          Runner.sync_runner
            ~submit:(function
              | Sync.Request (ticket, Sync.Fetch_catalog _) ->
                Db.post
                  (Option.get !db)
                  (Core.Sync_event
                     (Sync.Runner_completed (Sync.Completion (ticket, Ok [ graph ]))));
                Eio.Promise.resolve catalog_resolve ()
              | Sync.Request (_, Sync.Fetch_snapshot_baseline scope) ->
                Eio.Promise.resolve scope_resolve scope
              | Sync.Request (_, Sync.Fetch_snapshot_metadata _)
              | Sync.Request (_, Sync.Download_snapshot _) -> ()
              | Sync.Asset_io (_, request) as runnable ->
                (match request.action with
                 | Sync.Release_staged_file _ ->
                   cleanup_actions := request.action :: !cleanup_actions
                 | _ -> ());
                Sync_runner.submit (Option.get !io_runner) runnable
              | runnable -> Sync_runner.submit (Option.get !io_runner) runnable)
            ~shutdown:(fun () -> Sync_runner.shutdown (Option.get !io_runner))
            ()
        in
        let runner_dependencies =
          Runner.dependencies
            ~runtime:
              (Runner.runtime ~fork:(fun ~sw:_ task -> task ()) ~sleep:(fun _ -> ())
               |> Result.get_ok)
            ~config:fixture.config
            ~overlay:fixture.overlay
            ~sync_runner
            ~publish:(fun _ -> ())
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
        in
        let worker =
          Db.create
            ~sw
            ~config:(Core.config ~worker:fixture.config ~sync)
            ~runner_dependencies
          |> Result.get_ok
        in
        db := Some worker;
        Fun.protect
          ~finally:(fun () -> Db.shutdown worker)
          (fun () ->
             Db.post worker (Core.Sync_event (Sync.Sign_in_requested {account_generation=0; presentation_generation=0}));
             Db.post
               worker
               (Core.Sync_event (Sync.Account_authenticated { user_id = Some "user-1" }));
             Eio.Promise.await catalog_ready;
             Db.post worker (Core.Sync_event (Sync.Graph_selected graph.graph_id));
             let scope = Eio.Promise.await scope_ready in
             Db.post
               worker
               (Core.Sync_event
                  (Sync.Asset_requested
                     { scope
                     ; operation = "db-shutdown:stage"
                     ; action =
                         Sync.Stage_asset_file
                           { operation = source.operation
                           ; file_type = source.file_type
                           ; source_file = source.source_file
                           }
                     }));
             Eio.Promise.await stage_ready;
             let file =
               match Option.get !stage_completion with
               | Sync.Runner_completed
                   (Sync.Asset_completion (_, Ok (Sync.Asset_staged { file; _ }))) -> file
               | _ -> Alcotest.fail "missing real staging completion"
             in
             Db.post
               worker
               (Core.Sync_event
                  (Sync.Asset_requested
                     { scope
                     ; operation = "db-shutdown:path"
                     ; action = Sync.Retain_staged_file file
                     }));
             let path = Eio.Promise.await path_ready in
             Alcotest.(check bool)
               "actual runner staged file before shutdown"
               true
               (Sys.file_exists path);
             Db.shutdown worker;
             Alcotest.(check bool) "actual worker stopped" true (Db.view worker).shutdown;
             Db.post worker (Core.Sync_event (Option.get !stage_completion));
             Alcotest.(check bool)
               "late resource completion reaches cleanup submit"
               true
               (List.exists
                  (function
                    | Sync.Release_staged_file released -> released = file
                    | _ -> false)
                  !cleanup_actions);
             Alcotest.(check bool)
               "late completion leaves no staged orphan"
               false
               (Sys.file_exists path);
             Eio.Fiber.yield ()))))
;;

let test_upload_checkpoint_io () =
  let module U = Logseq_db_worker_pure_reducer.Asset_upload in
  let module I = Logseq_db_types.Asset_upload_intent in
  let module Store = Logseq_db_storage.Asset_upload_store in
  let uuid n =
    Logseq_db_types.Graph_types.Uuid.of_string
      (Printf.sprintf "00000000-0000-4000-8000-%012d" n)
    |> Result.get_ok
  in
  let admitted, context = admitted_asset_state (uuid 1) in
  let sync_state = ref admitted in
  let scope = context.Sync.scope in
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
    Eio_main.run (fun env ->
      Eio.Switch.run (fun sw ->
        let source_file =
          Filename.concat fixture.config.application_support_directory "picker.bin"
        in
        Out_channel.with_open_bin source_file (fun output -> output_string output "file");
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
        let active_runner = ref None in
        let bridge_requests = ref 0 in
        let bridge_outputs = ref 0 in
        let io_runner = ref None in
        let fixture_output = ref None in
        let transfer_ticket = ref None in
        let submit_sync = ref (fun _ -> failwith "sync interpreter not initialized") in
        let post = function
          | Core.Sync_event event ->
            (match event with
             | Sync.Asset_requested _ -> incr bridge_requests
             | _ -> ());
            let transition = Sync.step !sync_state event in
            sync_state := transition.next;
            List.iter
              (function
                | Sync.Run runner_effect -> !submit_sync runner_effect
                | Sync.Publish (Sync.Asset_finished output) ->
                  incr bridge_outputs;
                  if String.starts_with ~prefix:"fixture:" output.request.operation
                  then fixture_output := Some output.result
                  else
                    Runner.submit
                      (Option.get !active_runner)
                      (Core.Deliver_asset_result output)
                | Sync.Publish _ -> ()
                | Sync.Delegate _ -> Alcotest.fail "unexpected graph work in asset bridge")
              transition.effects
          | event -> posted := event :: !posted
        in
        io_runner
        := Some
             (asset_io_runner
                ~env
                ~sw
                ~support:fixture.config.application_support_directory
                ~post:(fun event -> post (Core.Sync_event event)));
        let sync_runner =
          Runner.sync_runner
            ~submit:(fun runner_effect ->
              (match runner_effect with
               | Sync.Asset_io (_, { action = Sync.Stage_asset_file _; _ }) ->
                 incr stage_calls
               | _ -> ());
              Sync_runner.submit (Option.get !io_runner) runner_effect)
            ~shutdown:(fun () -> Sync_runner.shutdown (Option.get !io_runner))
            ()
        in
        (submit_sync
         := fun runner_effect ->
              Runner.submit (Option.get !active_runner) (Core.Run_sync runner_effect));
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
            ~post
            ~recovery_current:(fun _ -> false)
            ~upload_current:(fun ticket -> !current && U.ticket_current state ticket)
            ~asset_current:(fun ticket -> !transfer_ticket = Some ticket)
          |> Result.get_ok
        in
        active_runner := Some runner;
        let fixture_serial = ref 0 in
        let fixture_asset action =
          incr fixture_serial;
          fixture_output := None;
          post
            (Core.Sync_event
               (Sync.Asset_requested
                  { scope
                  ; operation = "fixture:" ^ string_of_int !fixture_serial
                  ; action
                  }));
          Option.get !fixture_output |> Result.get_ok
        in
        let staged_path file =
          match fixture_asset (Sync.Retain_staged_file file) with
          | Sync.Asset_retained (Some (lease, path)) ->
            ignore (fixture_asset (Sync.Release_asset_file lease));
            path
          | _ -> Alcotest.fail "staged resource unavailable"
        in
        let orphan_file =
          match
            fixture_asset
              (Sync.Stage_asset_file
                 { operation = uuid 88; file_type = "bin"; source_file })
          with
          | Sync.Asset_staged { file; _ } -> file
          | _ -> Alcotest.fail "orphan staging failed"
        in
        let orphan_path = staged_path orphan_file in
        stage_calls := 0;
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
        (* Worker import owns publishing the staged original. This exercises its
           public prepare operation and the sealed Core/runner bridge. *)
        let normal_handle =
          match fixture_asset (Sync.Check_asset_cache (prepared.asset, prepared.version)) with
          | Sync.Asset_cached (Some handle) -> handle
          | _ -> Alcotest.fail "imported original must be in normal cache before upload"
        in
        let normal_lease, normal_path =
          match fixture_asset (Sync.Retain_asset_file normal_handle) with
          | Sync.Asset_retained (Some file) -> file
          | _ -> Alcotest.fail "normal imported original must be retainable"
        in
        Alcotest.(check string) "normal cache contains the original" "file"
          (In_channel.with_open_bin normal_path In_channel.input_all);
        ignore (fixture_asset (Sync.Release_asset_file normal_lease));
        ignore (fixture_asset (Sync.Release_asset_file normal_handle));
        let local_descriptor = Logseq_db_types.Asset_descriptor.create
          ~uuid:prepared.asset ~source:(Managed None)
          ~current_checksum:(Some prepared.version.checksum) ~size:None ~dimensions:None
          |> Result.get_ok in
        let module Transfer = Logseq_sync_pure_reducer.Asset_transfer in
        let transfer = Transfer.create
          (Transfer.config ~active:2 ~foreground_reserved:1 ~pending:3 ~retries:0 |> Result.get_ok)
          ~scope ~online:false ~unlocked:false in
        let _, instructions = Transfer.step transfer
          (Replace { consumer = "local-original"; priority = Foreground; assets = [local_descriptor] }) in
        let lookup = List.find_map (function Transfer.Check_cache ticket -> Some ticket | _ -> None) instructions |> Option.get in
        transfer_ticket := Some (Transfer.Lookup lookup);
        posted := [];
        Runner.submit runner (Core.Run_asset (context, Transfer.Check_cache lookup));
        let local_handle = List.find_map (function
          | Core.Asset_completed (actual, Transfer.Cache_checked (_, Ok (Some handle))) when actual = scope -> Some handle
          | _ -> None) !posted |> Option.get in
        ignore (fixture_asset (Sync.Release_asset_file local_handle));
        posted := [];
        let before_wrong_scope = !bridge_requests in
        Runner.submit runner (Core.Run_asset ({ context with scope = { scope with graph_id = uuid 90 } }, Transfer.Check_cache lookup));
        Alcotest.(check int) "mismatched transfer context performs no asset IO" before_wrong_scope !bridge_requests;
        Alcotest.(check bool) "mismatched transfer context has no completion" true (!posted = []);
        transfer_ticket := None;
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
        let source_path = staged_path prepared.staged_file in
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
        let staging_directory = Filename.dirname source_path in
        Unix.chmod staging_directory 0o500;
        Fun.protect
          ~finally:(fun () -> Unix.chmod staging_directory 0o700)
          (fun () ->
             Runner.submit runner (Core.Publish (Core.Sync_output (Sync.State_changed (Sync.state !sync_state))));
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
                    | Core.Diagnostic _ -> true
                    | _ -> false)
                  !published);
             let signed_out = Sync.step !sync_state (Sync.Account_authenticated {user_id=None}) in
             Runner.submit runner (Core.Publish (Core.Sync_output (Sync.State_changed (Sync.state signed_out.next))));
             published := [];
             Runner.submit runner (Core.Run_upload (context, restore_terminal ()));
             Alcotest.(check bool) "old scope cleanup cannot create a current diagnostic" false
               (List.exists (function Core.Diagnostic _ -> true | _ -> false) !published);
             Runner.shutdown runner);
        sync_state := admitted;
        io_runner
        := Some
             (asset_io_runner
                ~env
                ~sw
                ~support:fixture.config.application_support_directory
                ~post:(fun event -> post (Core.Sync_event event)));
        let restarted =
          Runner.create
            ~sw
            dependencies
            ~post
            ~recovery_current:(fun _ -> false)
            ~upload_current:(fun _ -> false)
            ~asset_current:(fun ticket -> !transfer_ticket = Some ticket)
          |> Result.get_ok
        in
        active_runner := Some restarted;
        transfer_ticket := Some (Transfer.Lookup lookup);
        posted := [];
        Runner.submit restarted (Core.Run_asset (context, Transfer.Check_cache lookup));
        let cold_handle = List.find_map (function
          | Core.Asset_completed (actual, Transfer.Cache_checked (_, Ok (Some handle))) when actual = scope -> Some handle
          | _ -> None) !posted |> Option.get in
        ignore (fixture_asset (Sync.Release_asset_file cold_handle));
        transfer_ticket := None;
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
        Alcotest.(check int)
          "every asset request returns through reducer output"
          !bridge_requests
          !bridge_outputs;
        Alcotest.(check bool) "asset bridge exercised" true (!bridge_requests > 0);
        Runner.shutdown restarted)))
;;

let deletion_runtime_fixture ?deletion_case ?(journal_failure = false)
      ?(confirmation_failure = false) ~busy () =
  let module Db = Logseq_db_worker in
  let module G = Logseq_db_types.Graph_types in
  T.with_managed (fun fixture ->
    Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
      let graph_id suffix = G.Uuid.of_string ("94000000-0000-4000-8000-" ^ suffix) |> Result.get_ok in
      let first = graph_id "000000000201" and second = graph_id "000000000202" in
      let graph graph_id : Sync.graph =
        { graph_id; name = "Deletion waiter fixture"; encrypted = false
        ; schema = { major = 65; minor = 33; exact = true } } in
      let root = fixture.config.application_support_directory in
      let worker_root = Filename.concat root "logseq-db-worker" in
      Unix.mkdir worker_root 0o700;
      let mirrors = Filename.concat worker_root "synced-graphs" in
      Unix.mkdir mirrors 0o700;
      let directory = Filename.concat mirrors (G.Uuid.to_string first) in
      Unix.mkdir directory 0o700;
      let first_database_path = Filename.concat directory "db.sqlite" in
      let sqlite = Sqlite3.db_open first_database_path in
      let checkpoint = Logseq_db_types.Sync_checkpoint.create ~graph_id:first
          ~schema:{ major = 65; minor = 33 }
          ~applied_server_t:(Logseq_db_types.Server_cursor.of_int64 0L |> Result.get_ok)
          ~checksum:"0123456789abcdef" |> Result.get_ok in
      Logseq_db_storage.Sync_checkpoint_store.initialize_database sqlite checkpoint |> Result.get_ok;
      ignore (Sqlite3.db_close sqlite);
      (match deletion_case with
       | None | Some `Legacy -> ()
       | Some `Corrupt_sqlite ->
         Out_channel.with_open_bin first_database_path (fun output -> output_string output "not a SQLite database")
       | Some `Corrupt_checkpoint ->
         let db = Sqlite3.db_open first_database_path in
         Sqlite3.Rc.check (Sqlite3.exec db "DROP TABLE sync_meta; CREATE TABLE sync_meta (broken TEXT)");
         ignore (Sqlite3.db_close db)
       | Some `Missing_database -> Unix.unlink first_database_path
       | Some `Linked_database ->
         let external_database = Filename.concat root "unrelated-database.sqlite" in
         Unix.rename first_database_path external_database;
         Unix.symlink external_database first_database_path);
      let second_directory = Filename.concat mirrors (G.Uuid.to_string second) in
      Unix.mkdir second_directory 0o700;
      let sqlite = Sqlite3.db_open (Filename.concat second_directory "db.sqlite") in
      let open Yojson.Safe.Util in
      let storage = T.read_json (T.fixture "storage/logseq-65.33-create-page.json") in
      Sqlite3.Rc.check (Sqlite3.exec sqlite (storage |> member "tableSql" |> to_string));
      let statement = Sqlite3.prepare sqlite "INSERT INTO kvs(addr, content, addresses) VALUES(?, ?, ?)" in
      storage |> member "rows" |> to_list |> List.iter (fun row ->
        Sqlite3.Rc.check (Sqlite3.reset statement);
        Sqlite3.Rc.check (Sqlite3.bind_int statement 1 (row |> member "addr" |> to_int));
        Sqlite3.Rc.check (Sqlite3.bind_text statement 2 (row |> member "content" |> to_string));
        Sqlite3.Rc.check (Sqlite3.bind statement 3 (match member "addresses" row with
          | `Null -> Sqlite3.Data.NULL | `String value -> TEXT value | _ -> assert false));
        Sqlite3.Rc.check (Sqlite3.step statement));
      Sqlite3.Rc.check (Sqlite3.finalize statement);
      let checkpoint = Logseq_db_types.Sync_checkpoint.create ~graph_id:second
          ~schema:{ major = 65; minor = 33 }
          ~applied_server_t:(Logseq_db_types.Server_cursor.of_int64 0L |> Result.get_ok)
          ~checksum:"0123456789abcdef" |> Result.get_ok in
      Logseq_db_storage.Sync_checkpoint_store.initialize_database sqlite checkpoint |> Result.get_ok;
      Logseq_db_storage.Sync_outbox_store.initialize_database sqlite |> Result.get_ok;
      ignore (Sqlite3.db_close sqlite);
      let worker = ref None and refreshed = ref false and held_cleanup = ref None in
      let destructive_requests = ref 0 in
      let published = ref [] and blocked_states = ref None in
      let post event = Db.post (Option.get !worker) (Core.Sync_event event) in
      let sync_runner = Runner.sync_runner ~submit:(function
        | Sync.Request (ticket, Sync.Load_catalog _) ->
          post (Sync.Runner_completed (Sync.Completion (ticket, Ok None)))
        | Sync.Request (ticket, Sync.Save_catalog _) ->
          post (Sync.Runner_completed (Sync.Completion (ticket, Ok ())))
        | Sync.Request (ticket, Sync.Fetch_catalog _) ->
          post (Sync.Runner_completed (Sync.Completion
            (ticket, Ok (if !refreshed then [graph first] else [graph first; graph second]))))
        | Sync.Request (ticket, Sync.Fetch_snapshot_baseline _) ->
          post (Sync.Runner_completed (Sync.Completion
            (ticket, Error (Sync.Effect_failed "Synthetic bootstrap unavailable."))))
        | Sync.Request (ticket, Sync.Fetch_snapshot_metadata _) ->
          post (Sync.Runner_completed (Sync.Completion
            (ticket, Error (Sync.Effect_failed "Synthetic bootstrap unavailable."))))
        | Sync.Asset_io (ticket, { context; action = Sync.Prepare_graph_asset_deletion retirement; _ }) ->
          incr destructive_requests;
          let deletion = Sync.asset_deletion_reference ~scope:context.scope ~retirement in
          if confirmation_failure then (
            (* Preparation has already written the uncommitted receipt. Keep
               it readable so the canonical rename can commit, but prevent
               the receipt rewrite that confirms durability afterwards. *)
            let states = Filename.concat mirrors
                (Filename.concat ".mirror-deletions"
                   (Filename.concat (G.Uuid.to_string first) "states")) in
            Unix.chmod states 0o500;
            blocked_states := Some states;
            post (Sync.Runner_completed (Sync.Asset_completion
              (ticket, Ok (Sync.Asset_deletion_prepared deletion)))))
          else if busy || Option.is_some deletion_case then post (Sync.Runner_completed (Sync.Asset_completion (ticket, Ok (Sync.Asset_deletion_prepared deletion))))
          else held_cleanup := Some (ticket, deletion)
        | Sync.Asset_io (ticket, _) ->
          post (Sync.Runner_completed (Sync.Asset_completion (ticket, Ok Sync.Asset_unit)))
        | _ -> ()) ~shutdown:(fun () -> ()) () in
      let dependencies = Runner.dependencies
          ~runtime:(Runner.runtime ~fork:(fun ~sw task -> Eio.Fiber.fork ~sw task)
              ~sleep:(Eio.Time.sleep (Eio.Stdenv.clock env)) |> Result.get_ok)
          ~config:fixture.config ~overlay:fixture.overlay ~sync_runner
          ~publish:(fun output -> published := output :: !published)
          |> Result.get_ok in
      let limits = Sync.limits ~maximum_response_bytes:1024 ~maximum_artifact_bytes:1024
          ~submission_batch_size:1 |> Result.get_ok in
      let sync = Sync.config ~managed_sync_origin:(Uri.of_string "https://api.logseq.io") ~limits
          |> Result.get_ok in
      let db = Db.create ~sw ~config:(Core.config ~worker:fixture.config ~sync)
          ~runner_dependencies:dependencies |> Result.get_ok in
      worker := Some db;
      let wait predicate =
        match Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 3. (fun () ->
          while not (predicate ()) do Eio.Fiber.yield () done) with
        | () -> ()
        | exception error ->
          let snapshot = (Db.view db).sync.snapshot in
          Alcotest.failf "Wait failed: %s selected=%s bootstrap=%b restore=%b failure=%b error=%s"
            (Printexc.to_string error)
            (Option.fold ~none:"none" ~some:G.Uuid.to_string snapshot.selected_graph)
            snapshot.startup.bootstrapping snapshot.startup.restoring_local
            (Option.is_some snapshot.startup.failure)
            (Option.value snapshot.last_error ~default:"none") in
      Fun.protect ~finally:(fun () ->
        Option.iter (fun states -> Unix.chmod states 0o700) !blocked_states;
        Option.iter (fun (ticket, _) -> post (Sync.Runner_completed
          (Sync.Asset_completion (ticket, Error Sync.Asset_cancelled)))) !held_cleanup;
        Db.shutdown db)
        (fun () ->
          post (Sync.Sign_in_requested {account_generation=0; presentation_generation=0});
          post (Sync.Account_authenticated { user_id = Some "user-1" });
          wait (fun () -> (Db.view db).sync.snapshot.catalog <> []);
          post (Sync.Graph_selected second);
          wait (fun () -> let snapshot = (Db.view db).sync.snapshot in
            snapshot.selected_graph = Some second && (Db.graph_state db).phase = Db.Graph_open
            && not snapshot.startup.bootstrapping && not snapshot.startup.restoring_local);
          let generation = (Db.view db).sync.snapshot.startup.account_generation in
          if confirmation_failure then (
            published := [];
            ignore (Db.delete_local_copy db ~account_generation:generation ~graph_id:first);
            Alcotest.(check bool) "canonical deletion reached the caught confirmation fault" false
              (Sys.file_exists directory);
            Alcotest.(check bool) "current other graph stays open" true
              ((Db.graph_state db).phase = Db.Graph_open);
            let states = Option.get !blocked_states in
            let receipts = Sys.readdir states |> Array.to_list in
            Alcotest.(check bool) "unconfirmed receipt remains replayable" true
              (List.exists (fun name -> Filename.check_suffix name ".json"
                 && not (T.read_json (Filename.concat states name)
                    |> Yojson.Safe.Util.member "committed" |> Yojson.Safe.Util.to_bool)) receipts);
            Alcotest.(check bool) "caught current confirmation failure publishes Diagnostic" true
              (List.exists (function
                | Core.Diagnostic "worker.confirmMirrorRetirement" -> true
                | _ -> false) !published))
          else if Option.is_some deletion_case then (
            let result = Db.delete_local_copy db ~account_generation:generation ~graph_id:first in
            (match result with Ok () -> () | Error message -> Alcotest.failf "unopened local copy must delete: %s" message);
            Alcotest.(check bool) "selected target directory is absent" false (Sys.file_exists directory);
            Alcotest.(check bool) "other graph database survives" true
              (Sys.file_exists (Filename.concat second_directory "db.sqlite"));
            Alcotest.(check bool) "current Worker remains open" true ((Db.graph_state db).phase = Db.Graph_open);
            Alcotest.(check bool) "opening current graph creates no account-owner JSON" false
              (Sys.file_exists (Filename.concat second_directory ".journal-local-owner.json"));
            if deletion_case = Some `Linked_database then
              Alcotest.(check bool) "linked external database survives deletion" true
                (Sys.file_exists (Filename.concat root "unrelated-database.sqlite")))
          else if journal_failure then (
            let blocked = Filename.concat worker_root "local-copy-retirements" in
            Out_channel.with_open_bin blocked (fun output -> output_string output "synthetic mkdir fault");
            Alcotest.(check bool) "journal IO failure returns a deletion error" true
              (Result.is_error (Db.delete_local_copy db ~account_generation:generation ~graph_id:first));
            Alcotest.(check int) "journal failure never retires assets" 0 !destructive_requests;
            Alcotest.(check bool) "journal failure preserves target mirror" true (Sys.file_exists first_database_path);
            Alcotest.(check bool) "current graph Worker stays open" true ((Db.graph_state db).phase = Db.Graph_open);
            post (Sync.Catalog_refresh_requested
              (let f=(Db.view db).sync.snapshot.startup in
               {account_generation=f.account_generation;presentation_generation=f.presentation_generation}));
            wait (fun () -> (Db.view db).sync.snapshot.catalog <> []))
          else if busy then (
            let lock = Sqlite3.db_open (Filename.concat directory ".logseq-overlay-owner.sqlite") in
            Fun.protect ~finally:(fun () -> ignore (Sqlite3.exec lock "ROLLBACK"); ignore (Sqlite3.db_close lock)) (fun () ->
              Sqlite3.Rc.check (Sqlite3.exec lock "BEGIN IMMEDIATE");
              Alcotest.(check bool) "busy mirror reports failure" true
                (Result.is_error (Db.delete_local_copy db ~account_generation:generation ~graph_id:first));
              Alcotest.(check int) "busy mirror never starts destructive asset work" 0 !destructive_requests;
              Alcotest.(check bool) "busy mirror remains usable" true (Sys.file_exists first_database_path)))
          else (
          let result, resolve = Eio.Promise.create () in
          Eio.Fiber.fork ~sw (fun () -> Eio.Promise.resolve resolve
            (Db.delete_local_copy db ~account_generation:generation ~graph_id:first));
          wait (fun () -> Option.is_some !held_cleanup);
          refreshed := true;
          post (Sync.Catalog_refresh_requested
              (let f=(Db.view db).sync.snapshot.startup in
               {account_generation=f.account_generation;presentation_generation=f.presentation_generation}));
          wait (fun () -> (Db.view db).sync.snapshot.selected_graph = None);
          Alcotest.(check bool) "catalog refresh cannot report deletion success" true
            (match Eio.Promise.peek result with Some (Ok ()) -> false | _ -> true);
          Option.iter (fun (ticket, deletion) -> post (Sync.Runner_completed
            (Sync.Asset_completion (ticket, Ok (Sync.Asset_deletion_prepared deletion))))) !held_cleanup;
          held_cleanup := None;
          Alcotest.(check bool) "matching deletion finishes with cancellation failure" true
            (match Eio.Promise.await result with Error _ -> true | Ok () -> false);
          Alcotest.(check bool) "unauthorized deletion preserves its mirror" true
            (Sys.file_exists first_database_path))))))
;;

let test_catalog_refresh_cannot_complete_another_deletion () = deletion_runtime_fixture ~busy:false ()
let test_deletion_checks_ownership_before_assets () = deletion_runtime_fixture ~busy:true ()
let test_deletion_journal_failure_preserves_worker () = deletion_runtime_fixture ~journal_failure:true ~busy:false ()
let test_deletion_confirmation_failure_reports () =
  deletion_runtime_fixture ~confirmation_failure:true ~busy:false ()

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
    ; ( "unlock diagnostics", [Alcotest.test_case "typed finite runner observations" `Quick test_unlock_runner_logging] )
    ; ( "contract"
      , [ Alcotest.test_case
            "cancel queued staging output"
            `Quick
            (cancelled_stage_output false)
        ; Alcotest.test_case
            "cancel resolved staging output"
            `Quick
            (cancelled_stage_output true)
        ; Alcotest.test_case
            "cancel queued retained lease output"
            `Quick
            test_cancelled_retained_output
        ; Alcotest.test_case
            "actual Db shutdown late staging completion"
            `Quick
            test_db_shutdown_accepts_late_staging_completion
        ; Alcotest.test_case
            "durable upload checkpoint IO"
            `Quick
            test_upload_checkpoint_io
        ; Alcotest.test_case
            "sync and publish delegation"
            `Quick
            test_sync_and_publish_instructions_are_not_reduced_recursively
        ; Alcotest.test_case
            "catalog refresh cannot complete another deletion"
            `Quick
            test_catalog_refresh_cannot_complete_another_deletion
        ; Alcotest.test_case "busy mirror preserves attachment sources" `Quick
            test_deletion_checks_ownership_before_assets
        ; Alcotest.test_case "journal IO failure preserves current Worker" `Quick
            test_deletion_journal_failure_preserves_worker
        ; Alcotest.test_case "caught retirement confirmation failure reports Diagnostic" `Quick
            test_deletion_confirmation_failure_reports
        ; Alcotest.test_case "delete never-opened legacy copy" `Quick
            (deletion_runtime_fixture ~deletion_case:`Legacy ~busy:false)
        ; Alcotest.test_case "delete non-SQLite copy" `Quick
            (deletion_runtime_fixture ~deletion_case:`Corrupt_sqlite ~busy:false)
        ; Alcotest.test_case "delete invalid checkpoint copy" `Quick
            (deletion_runtime_fixture ~deletion_case:`Corrupt_checkpoint ~busy:false)
        ; Alcotest.test_case "delete residual directory without database" `Quick
            (deletion_runtime_fixture ~deletion_case:`Missing_database ~busy:false)
        ; Alcotest.test_case "delete contained database link without following it" `Quick
            (deletion_runtime_fixture ~deletion_case:`Linked_database ~busy:false)
        ] )
    ]
;;
