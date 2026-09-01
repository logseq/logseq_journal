module Core = Logseq_db_worker_pure_reducer.Core
module Sync = Logseq_sync_pure_reducer.Core
module Config = Logseq_db_worker.Config
module Protocol = Logseq_db_worker.Protocol

let uuid value = Logseq_db_types.Graph_types.Uuid.of_string value |> Result.get_ok

let worker_config () =
  Config.create
    ~application_support_directory:"/tmp/logseq-db-worker-reducer-contract"
    ~target:(Managed_sync { base_url = "https://api.logseq.io" })
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

let initial () =
  Core.config ~worker:(worker_config ()) ~sync:(sync_config ())
  |> Core.initial
  |> Result.get_ok
;;

let graph_info_request () =
  Protocol.
    { api_version
    ; request_id = uuid "10000000-0000-4000-8000-000000000001"
    ; command = Read Graph_info
    }
;;

let test_managed_worker_starts_without_local_open () =
  let transition = Core.step (initial ()) Core.Start in
  Alcotest.check Alcotest.int "no local open effects" 0 (List.length transition.effects);
  Alcotest.check
    Alcotest.bool
    "graph starts closed"
    true
    ((Core.view transition.next).graph.phase = Core.Graph_closed)
;;

let test_closed_graph_request_replies_once () =
  let id = Core.request_id_of_int64 1L in
  let transition =
    Core.step (initial ()) (Core.Graph_request { id; request = graph_info_request () })
  in
  let replies =
    List.filter
      (function
        | Core.Publish (Core.Reply (actual, _)) -> Core.equal_request_id actual id
        | Run_worker _ | Run_sync _ | Publish _ -> false)
      transition.effects
  in
  Alcotest.check Alcotest.int "one terminal reply" 1 (List.length replies)
;;

let test_sync_instructions_are_translated_in_order () =
  let transition =
    Core.step
      (initial ())
      (Sync_event (Sync.Restore_local_account { user_id = "user-1" }))
  in
  Alcotest.check
    (Alcotest.list Alcotest.string)
    "child order"
    [ "publish:sync-state"; "run-sync:Load_catalog" ]
    (List.map Core.instruction_diagnostic transition.effects)
;;

let test_replay_is_deterministic () =
  let replay () =
    let transition =
      Core.step
        (initial ())
        (Sync_event (Sync.Restore_local_account { user_id = "user-1" }))
    in
    Core.view transition.next, transition.effects
  in
  let first_view, first_effects = replay () in
  let second_view, second_effects = replay () in
  Alcotest.check Alcotest.bool "view replay" true (Core.equal_view first_view second_view);
  Alcotest.check
    Alcotest.bool
    "effect replay"
    true
    (Core.equal_instructions first_effects second_effects)
;;

let () =
  Alcotest.run
    "logseq db worker pure reducer"
    [ ( "managed lifecycle"
      , [ Alcotest.test_case
            "start has no local open"
            `Quick
            test_managed_worker_starts_without_local_open
        ; Alcotest.test_case
            "closed request replies"
            `Quick
            test_closed_graph_request_replies_once
        ; Alcotest.test_case
            "sync instruction order"
            `Quick
            test_sync_instructions_are_translated_in_order
        ; Alcotest.test_case "deterministic replay" `Quick test_replay_is_deterministic
        ] )
    ]
;;
