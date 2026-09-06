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
    ; command = V2_graph_info
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
  match List.map Core.instruction_diagnostic transition.effects with
  | [ "publish:sync-output"; run ] ->
    Alcotest.check
      Alcotest.bool
      "load catalog follows state publication"
      true
      (String.starts_with ~prefix:"run-sync:request:" run)
  | values -> Alcotest.failf "unexpected child order: %s" (String.concat ", " values)
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

let worker_open_graph () =
  let graph : Sync.graph =
    { graph_id = uuid "11111111-1111-4111-8111-111111111111"
    ; name = "Journal"
    ; schema = { major = 1; minor = 0; exact = true }
    ; encrypted = false
    }
  in
  let auth =
    Core.step
      (initial ())
      (Sync_event (Sync.Account_authenticated { user_id = Some "user" }))
  in
  let fetched =
    List.find_map
      (function
        | Core.Run_sync (Sync.Request (ticket, Sync.Fetch_catalog _)) ->
          Some
            (Core.Sync_event
               (Sync.Runner_completed (Sync.Completion (ticket, Ok [ graph ]))))
        | _ -> None)
      auth.effects
    |> Option.get
  in
  let catalog = Core.step auth.next fetched in
  let selected =
    Core.step catalog.next (Sync_event (Sync.Graph_selected graph.graph_id))
  in
  let inspected =
    List.find_map
      (function
        | Core.Run_worker
            (Core.Request
               (ticket, Core.Handle_sync_worker_effect (Sync.Inspect_mirror request))) ->
          Some
            (Core.Runner_completed
               (Core.Sync_worker_effect_completed
                  ( ticket
                  , Ok
                      { Core.event =
                          Some (Sync.Mirror_inspected (Sync.Mirror_available request))
                      ; lifecycle = Core.Lifecycle_unchanged
                      } )))
        | _ -> None)
      selected.effects
    |> Option.get
  in
  let attaching = Core.step selected.next inspected in
  let attached, scope =
    List.find_map
      (function
        | Core.Run_worker
            (Core.Request
               (ticket, Core.Handle_sync_worker_effect (Sync.Attach_graph request))) ->
          let token =
            Logseq_overlay_db.Types.sync_token_of_string "sync-token:v1:worker-delete"
            |> Result.get_ok
          in
          let checkpoint =
            Logseq_overlay_db.Types.Server_cursor.of_string "server-cursor:v1:0"
            |> Result.get_ok
          in
          let sync =
            Logseq_overlay_db.Types.sync_view ~token ~checkpoint ~submissions:[]
          in
          let opened =
            Core.database_opened ~database_id:"db-delete" ~graph_id:graph.graph_id
          in
          Some
            ( Core.Runner_completed
                (Core.Sync_worker_effect_completed
                   ( ticket
                   , Ok
                       { Core.event =
                           Some (Sync.Graph_attached { scope = request.scope; sync })
                       ; lifecycle =
                           Core.Lifecycle_opened (opened, request.scope.graph_generation)
                       } ))
            , request.scope )
        | _ -> None)
      attaching.effects
    |> Option.get
  in
  let ready = Core.step attaching.next attached in
  ready.next, scope
;;

let test_local_deletion_drains_worker_operations () =
  let ready, scope = worker_open_graph () in
  let request = graph_info_request () in
  let executing =
    Core.step ready (Core.Graph_request { id = Core.request_id_of_int64 11L; request })
  in
  let completion =
    List.find_map
      (function
        | Core.Run_worker instruction ->
          Core.complete_execute
            instruction
            (Error
               (Logseq_db_worker.Error.create
                  ~code:Closed_session
                  ~message:"Request finished."
                  ~details:[]
                |> Result.get_ok))
        | _ -> None)
      executing.effects
    |> Option.get
  in
  let inspecting = Core.step executing.next (Sync_event Sync.Local_outbox_changed) in
  let inspection_completion =
    List.find_map
      (function
        | Core.Run_worker
            (Core.Request (ticket, Core.Handle_sync_worker_effect (Sync.Inspect_sync _)))
          ->
          Some
            (Core.Runner_completed
               (Core.Sync_worker_effect_completed
                  ( ticket
                  , Error
                      (Logseq_db_worker.Error.create
                         ~code:Closed_session
                         ~message:"Inspection finished."
                         ~details:[]
                       |> Result.get_ok) )))
        | _ -> None)
      inspecting.effects
    |> Option.get
  in
  let deleting =
    Core.step
      inspecting.next
      (Sync_event (Sync.Local_cache_deletion_requested scope.graph_id))
  in
  Alcotest.(check bool)
    "graph closes admission immediately"
    true
    ((Core.view deleting.next).graph.phase = Core.Graph_closing);
  let has_close effects =
    List.exists
      (function
        | Core.Run_worker
            (Core.Request (_, Core.Handle_sync_worker_effect (Sync.Detach_graph _))) ->
          true
        | _ -> false)
      effects
  in
  Alcotest.(check bool)
    "close waits for executing work"
    false
    (has_close deleting.effects);
  let edit =
    { request with
      Protocol.command =
        Protocol.V2_save_block
          { mutation_id = uuid "20000000-0000-4000-8000-000000000001"
          ; block = uuid "30000000-0000-4000-8000-000000000001"
          ; title = "Must not be saved after deletion admission"
          ; preconditions = { blocks = []; pages = []; scopes = [] }
          }
    }
  in
  let rejected =
    Core.step
      deleting.next
      (Core.Graph_request { id = Core.request_id_of_int64 12L; request = edit })
  in
  Alcotest.(check bool)
    "new editing receives a terminal reply and no execution"
    true
    (List.exists
       (function
         | Core.Publish (Core.Reply _) -> true
         | _ -> false)
       rejected.effects
     && not
          (List.exists
             (function
               | Core.Run_worker _ -> true
               | _ -> false)
             rejected.effects));
  let one_finished = Core.step rejected.next completion in
  Alcotest.(check bool)
    "close still waits for sync DB operation"
    false
    (has_close one_finished.effects);
  let drained = Core.step one_finished.next inspection_completion in
  Alcotest.(check bool)
    "all DB completions release one close"
    true
    (has_close drained.effects);
  let duplicate = Core.step drained.next inspection_completion in
  Alcotest.(check bool)
    "duplicate completion cannot release another close"
    true
    (duplicate.effects = []);
  let close_failure =
    List.find_map
      (function
        | Core.Run_worker
            (Core.Request (ticket, Core.Handle_sync_worker_effect (Sync.Detach_graph _)))
          ->
          Some
            (Core.Runner_completed
               (Core.Sync_worker_effect_completed
                  ( ticket
                  , Error
                      (Logseq_db_worker.Error.create
                         ~code:Closed_session
                         ~message:"private close details"
                         ~details:[]
                       |> Result.get_ok) )))
        | _ -> None)
      drained.effects
    |> Option.get
  in
  let failed = Core.step drained.next close_failure in
  Alcotest.(check bool)
    "worker forwards close failure to owner"
    true
    ((Core.view failed.next).sync.snapshot.local_deletion
     = Some (Sync.Deletion_failed Sync.Closing_graph));
  Alcotest.(check bool)
    "close failure never deletes"
    false
    (List.exists
       (function
         | Core.Run_worker
             (Core.Request (_, Core.Handle_sync_worker_effect (Sync.Delete_mirror _))) ->
           true
         | _ -> false)
       failed.effects)
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
        ; Alcotest.test_case
            "deletion drains executing work"
            `Quick
            test_local_deletion_drains_worker_operations
        ; Alcotest.test_case "deterministic replay" `Quick test_replay_is_deterministic
        ] )
    ]
;;
