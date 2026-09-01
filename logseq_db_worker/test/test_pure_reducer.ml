module Core = Logseq_db_worker_pure_reducer.Core
module Sync = Logseq_sync_pure_reducer.Core
module Config = Logseq_db_worker.Config
module Protocol = Logseq_db_worker.Protocol

let fail format = Printf.ksprintf (fun message -> Alcotest.fail message) format
let uuid value = Logseq_db_types.Graph_types.Uuid.of_string value |> Result.get_ok

let worker_config target =
  Config.create
    ~application_support_directory:"/tmp/logseq-db-worker-reducer-contract"
    ~target
    ~compatibility_profile:Logseq_65_33_or_newer
    ~response_budget_bytes:Protocol.maximum_response_bytes
    ~default_page_size:Protocol.default_page_size
  |> Result.get_ok
;;

let sync_config () =
  let limits =
    Sync.limits
      ~maximum_response_bytes:Protocol.maximum_response_bytes
      ~maximum_artifact_bytes:(1024 * 1024 * 1024)
      ~submission_batch_size:32
    |> Result.get_ok
  in
  Sync.config ~managed_sync_origin:(Uri.of_string "https://api.logseq.io") ~limits
  |> Result.get_ok
;;

let initial ?sync target =
  Core.config ~worker:(worker_config target) ~sync
  |> Result.get_ok
  |> Core.initial
  |> Result.get_ok
;;

let local_target () =
  Config.Native_local_graph { graph_name = "Journal"; graph_dir = "/tmp/Journal" }
;;

let request_id value = Core.request_id_of_int64 value

let graph_info_request ?(id = "10000000-0000-4000-8000-000000000001") () =
  Protocol.{ api_version; request_id = uuid id; command = Read Graph_info }
;;

let error message =
  Logseq_db_worker.Error.create
    ~code:Logseq_db_worker.Error.Storage_busy
    ~message
    ~details:[]
  |> Result.get_ok
;;

let open_effect effects =
  List.find_map
    (function
      | Core.Run_worker (Core.Request (_, Core.Open_engine _) as runner_effect) ->
        Some runner_effect
      | Run_worker _ | Run_sync _ | Publish _ -> None)
    effects
  |> function
  | Some runner_effect -> runner_effect
  | None -> fail "transition did not request an Engine open"
;;

let execute_effect effects =
  List.find_map
    (function
      | Core.Run_worker (Core.Request (_, Core.Execute_request _) as runner_effect) ->
        Some runner_effect
      | Run_worker _ | Run_sync _ | Publish _ -> None)
    effects
  |> function
  | Some runner_effect -> runner_effect
  | None -> fail "transition did not request Graph execution"
;;

let reply_count effects request_id =
  List.fold_left
    (fun count -> function
       | Core.Publish (Core.Reply (actual, _))
         when Core.equal_request_id actual request_id -> count + 1
       | Run_worker _ | Run_sync _ | Publish _ -> count)
    0
    effects
;;

let opened_local () =
  let core = initial (local_target ()) in
  let starting = Core.step core Core.Start in
  let runner_effect = open_effect starting.effects in
  let opened =
    Core.engine_opened ~engine_id:"engine-1" ~graph_id:None ~basis:(Some 42L)
  in
  let transition =
    Core.step starting.next (Core.complete_open runner_effect (Ok opened) |> Option.get)
  in
  transition.next
;;

let test_all_target_initializations_are_canonical () =
  let graph_id = uuid "60000000-0000-4000-8000-000000000001" in
  let checkpoint =
    Logseq_db_types.Sync_checkpoint.create
      ~graph_id
      ~schema:Logseq_db_types.Graph_types.{ major = 1; minor = 0 }
      ~applied_server_t:0
      ~checksum:"0000000000000000"
    |> Result.get_ok
  in
  let targets =
    [ Config.Managed_sync { base_url = "https://api.logseq.io" }, Core.Managed
    ; Config.Snapshot { token = graph_id }, Core.Snapshot
    ; Config.Import_snapshot { inbox_entry = "import" }, Core.Import_snapshot
    ; ( Config.Synced_mirror
          { graph_id
          ; graph_name = "Journal"
          ; graph_dir = "/tmp/Journal"
          ; database_path = "/tmp/Journal/db.sqlite"
          ; checkpoint
          }
      , Core.Synced_mirror )
    ; local_target (), Core.Native_local
    ]
  in
  List.iter
    (fun (target, expected) ->
       let sync =
         match target with
         | Config.Managed_sync _ -> Some (sync_config ())
         | _ -> None
       in
       let state = initial ?sync target in
       let view = Core.view state in
       Alcotest.check Alcotest.bool "target kind" true (view.target = expected);
       Alcotest.check Alcotest.bool "starts closed" true (view.graph.phase = Graph_closed);
       let started = Core.step state Start in
       match target with
       | Managed_sync _ ->
         Alcotest.check
           Alcotest.int
           "managed waits for selection"
           0
           (List.length started.effects)
       | Snapshot _ | Import_snapshot _ | Synced_mirror _ | Native_local_graph _ ->
         ignore (open_effect started.effects);
         Alcotest.check
           (Alcotest.list Alcotest.string)
           "opening effects are ordered"
           [ "run-worker:Open_engine"; "publish:graph-state" ]
           (List.map Core.instruction_diagnostic started.effects))
    targets
;;

let test_open_success_failure_and_duplicate_completion () =
  let state = initial (local_target ()) in
  let starting = Core.step state Start in
  let runner_effect = open_effect starting.effects in
  Alcotest.check
    Alcotest.bool
    "opening phase"
    true
    ((Core.view starting.next).graph.phase = Graph_opening);
  let failed =
    Core.step
      starting.next
      (Core.complete_open runner_effect (Error (error "open failed")) |> Option.get)
  in
  Alcotest.check
    Alcotest.bool
    "failed phase"
    true
    ((Core.view failed.next).graph.phase = Graph_failed);
  let duplicate =
    Core.step
      failed.next
      (Core.complete_open runner_effect (Error (error "again")) |> Option.get)
  in
  Alcotest.check
    Alcotest.int
    "duplicate completion ignored"
    0
    (List.length duplicate.effects);
  Alcotest.check
    Alcotest.bool
    "duplicate state stable"
    true
    (Core.equal_view (Core.view failed.next) (Core.view duplicate.next));
  let retry = Core.step state Start in
  let retry_effect = open_effect retry.effects in
  let opened =
    Core.engine_opened ~engine_id:"engine-1" ~graph_id:None ~basis:(Some 42L)
  in
  let succeeded =
    Core.step retry.next (Core.complete_open retry_effect (Ok opened) |> Option.get)
  in
  Alcotest.check
    Alcotest.bool
    "open phase"
    true
    ((Core.view succeeded.next).graph.phase = Graph_open)
;;

let test_graph_request_admission_across_lifecycle () =
  let closed = initial (local_target ()) in
  let first_id = request_id 1L in
  let before =
    Core.step closed (Graph_request { id = first_id; request = graph_info_request () })
  in
  Alcotest.check
    Alcotest.int
    "closed request replied"
    1
    (reply_count before.effects first_id);
  let starting = Core.step closed Start in
  let second_id = request_id 2L in
  let during =
    Core.step
      starting.next
      (Graph_request { id = second_id; request = graph_info_request () })
  in
  Alcotest.check
    Alcotest.int
    "opening request replied"
    1
    (reply_count during.effects second_id);
  let opened = opened_local () in
  let third_id = request_id 3L in
  let admitted =
    Core.step opened (Graph_request { id = third_id; request = graph_info_request () })
  in
  let runner_effect = execute_effect admitted.effects in
  Alcotest.check
    Alcotest.int
    "open request waits"
    0
    (reply_count admitted.effects third_id);
  let response =
    Protocol.failed
      ~request_id:(graph_info_request ()).request_id
      ~phase:Execute
      ~basis:(Some 42L)
      (error "synthetic response")
  in
  let completed =
    Core.step
      admitted.next
      (Core.complete_execute runner_effect (Ok response) |> Option.get)
  in
  Alcotest.check
    Alcotest.int
    "completion replied once"
    1
    (reply_count completed.effects third_id);
  let duplicate =
    Core.step
      completed.next
      (Core.complete_execute runner_effect (Ok response) |> Option.get)
  in
  Alcotest.check
    Alcotest.int
    "duplicate did not reply"
    0
    (reply_count duplicate.effects third_id)
;;

let test_shutdown_fences_pending_requests_and_late_completions () =
  let opened = opened_local () in
  let id = request_id 4L in
  let admitted =
    Core.step opened (Graph_request { id; request = graph_info_request () })
  in
  let runner_effect = execute_effect admitted.effects in
  let stopped = Core.step admitted.next Shutdown in
  Alcotest.check
    Alcotest.int
    "pending request closed once"
    1
    (reply_count stopped.effects id);
  Alcotest.check Alcotest.bool "shutdown phase" true (Core.view stopped.next).shutdown;
  let response =
    Protocol.failed
      ~request_id:(graph_info_request ()).request_id
      ~phase:Execute
      ~basis:None
      (error "late")
  in
  let late =
    Core.step
      stopped.next
      (Core.complete_execute runner_effect (Ok response) |> Option.get)
  in
  Alcotest.check Alcotest.int "late completion ignored" 0 (reply_count late.effects id)
;;

let test_sync_instructions_are_translated_in_order () =
  let state =
    initial
      ~sync:(sync_config ())
      (Config.Managed_sync { base_url = "https://api.logseq.io" })
  in
  let transition =
    Core.step state (Sync_event (Sync.Restore_local_account { user_id = "user-1" }))
  in
  let diagnostics = List.map Core.instruction_diagnostic transition.effects in
  Alcotest.check
    (Alcotest.list Alcotest.string)
    "child order"
    [ "publish:sync-state"; "run-sync:Load_catalog" ]
    diagnostics
;;

let test_replay_is_deterministic () =
  let replay () =
    let state = initial (local_target ()) in
    let started = Core.step state Start in
    let runner_effect = open_effect started.effects in
    let opened =
      Core.engine_opened ~engine_id:"engine-1" ~graph_id:None ~basis:(Some 42L)
    in
    let finished =
      Core.step started.next (Core.complete_open runner_effect (Ok opened) |> Option.get)
    in
    Core.view finished.next, started.effects, finished.effects
  in
  let first_view, first_start, first_finish = replay () in
  let second_view, second_start, second_finish = replay () in
  Alcotest.check Alcotest.bool "view replay" true (Core.equal_view first_view second_view);
  Alcotest.check
    Alcotest.bool
    "start effects replay"
    true
    (Core.equal_instructions first_start second_start);
  Alcotest.check
    Alcotest.bool
    "completion effects replay"
    true
    (Core.equal_instructions first_finish second_finish)
;;

let () =
  Alcotest.run
    "logseq db worker pure reducer"
    [ ( "lifecycle"
      , [ Alcotest.test_case
            "all target initializations"
            `Quick
            test_all_target_initializations_are_canonical
        ; Alcotest.test_case
            "open results are fenced"
            `Quick
            test_open_success_failure_and_duplicate_completion
        ; Alcotest.test_case
            "request admission follows lifecycle"
            `Quick
            test_graph_request_admission_across_lifecycle
        ; Alcotest.test_case
            "shutdown fences late work"
            `Quick
            test_shutdown_fences_pending_requests_and_late_completions
        ] )
    ; ( "composition"
      , [ Alcotest.test_case
            "sync instruction order"
            `Quick
            test_sync_instructions_are_translated_in_order
        ; Alcotest.test_case "deterministic replay" `Quick test_replay_is_deterministic
        ] )
    ]
;;
