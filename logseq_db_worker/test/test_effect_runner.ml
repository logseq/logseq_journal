module Core = Logseq_db_worker_pure_reducer.Core
module Runner = Logseq_db_worker_effect_runner.Effect_runner
module Sync = Logseq_sync_pure_reducer.Core
module F = Logseq_db_worker_test_support.Adapter_fixture

let open_instruction config =
  let core_config = Core.config ~worker:config ~sync:None |> Result.get_ok in
  let transition = Core.step (Core.initial core_config |> Result.get_ok) Core.Start in
  List.find
    (function
      | Core.Run_worker (Core.Request (_, Core.Open_engine _)) -> true
      | _ -> false)
    transition.effects
;;

let test_worker_effect_posts_one_completion () =
  F.with_snapshot (fun fixture ->
    Eio_main.run (fun _environment ->
      Eio.Switch.run (fun sw ->
        let tasks = ref [] in
        let posted = ref [] in
        let published = ref [] in
        let runtime =
          Runner.runtime ~fork:(fun ~sw:_ task -> tasks := task :: !tasks)
          |> Result.get_ok
        in
        let sync_runner =
          Runner.sync_runner ~submit:(fun _ -> ()) ~shutdown:(fun () -> ()) ()
        in
        let dependencies =
          Runner.dependencies
            ~runtime
            ~config:fixture.config
            ~engine:F.dependencies
            ~sync_runner
            ~publish:(fun output -> published := output :: !published)
          |> Result.get_ok
        in
        let runner =
          Runner.create ~sw dependencies ~post:(fun event -> posted := event :: !posted)
          |> Result.get_ok
        in
        Runner.submit runner (open_instruction fixture.config);
        List.iter (fun task -> task ()) (List.rev !tasks);
        Alcotest.check Alcotest.int "one completion" 1 (List.length !posted);
        Alcotest.check Alcotest.int "no host output" 0 (List.length !published);
        Runner.shutdown runner)))
;;

let test_sync_and_publish_instructions_are_not_reduced_recursively () =
  Eio_main.run (fun _environment ->
    Eio.Switch.run (fun sw ->
      let submitted = ref [] in
      let published = ref [] in
      let runtime = Runner.runtime ~fork:(fun ~sw:_ task -> task ()) |> Result.get_ok in
      let sync_runner =
        Runner.sync_runner
          ~submit:(fun runner_effect -> submitted := runner_effect :: !submitted)
          ~shutdown:(fun () -> ())
          ()
      in
      let dependencies =
        Runner.dependencies
          ~runtime
          ~config:
            (F.config
               "/tmp/logseq-db-worker-runner-test"
               (Logseq_db_types.Graph_types.Uuid.of_string
                  "10000000-0000-4000-8000-000000000001"
                |> Result.get_ok))
          ~engine:F.dependencies
          ~sync_runner
          ~publish:(fun output -> published := output :: !published)
        |> Result.get_ok
      in
      let posted = ref [] in
      let runner =
        Runner.create ~sw dependencies ~post:(fun event -> posted := event :: !posted)
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
      Runner.shutdown runner))
;;

let () =
  Alcotest.run
    "logseq db worker effect runner"
    [ ( "contract"
      , [ Alcotest.test_case
            "worker completion posting"
            `Quick
            test_worker_effect_posts_one_completion
        ; Alcotest.test_case
            "sync and publish delegation"
            `Quick
            test_sync_and_publish_instructions_are_not_reduced_recursively
        ] )
    ]
;;
