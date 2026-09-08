module Core = Logseq_db_worker_pure_reducer.Core
module Runner = Logseq_db_worker_effect_runner.Effect_runner
module Sync = Logseq_sync_pure_reducer.Core
module P = Logseq_db_worker.Protocol
module Runtime = Journal_graph_runtime
module Graph = Logseq_db_types.Graph_types
module Fixture = Test_support

let require condition message = if not condition then failwith message
let uuid value = Graph.Uuid.of_string value |> Result.get_ok

let only = function
  | [ value ] -> value
  | _ -> failwith "expected one result"
;;

type worker =
  { request : P.request -> P.response
  ; drain : unit -> unit
  ; pushes : P.push Queue.t
  }

let with_worker ?limits:overlay_limits run =
  Fixture.with_temp_directory "journal-mutation-regression-" (fun support ->
    ignore (Fixture.seed_mirror support);
    Eio_main.run (fun _ ->
      Eio.Switch.run (fun sw ->
        let config =
          Logseq_db_worker.Config.create
            ~application_support_directory:support
            ~target:(Managed_sync { base_url = "https://example.invalid" })
            ~compatibility_profile:Logseq_65_33_or_newer
            ~response_budget_bytes:P.maximum_response_bytes
            ~default_page_size:P.default_page_size
          |> Result.get_ok
        in
        let limits =
          Sync.limits
            ~maximum_response_bytes:P.maximum_response_bytes
            ~maximum_artifact_bytes:1048576
            ~submission_batch_size:32
          |> Result.get_ok
        in
        let sync =
          Sync.config
            ~managed_sync_origin:(Uri.of_string "https://example.invalid")
            ~limits
          |> Result.get_ok
        in
        let state =
          ref (Core.initial (Core.config ~worker:config ~sync) |> Result.get_ok)
        in
        let events = Queue.create () in
        let replies = Hashtbl.create 8 in
        let pushes = Queue.create () in
        let post event = Queue.add event events in
        let graph : Sync.graph =
          { graph_id = Fixture.graph_uuid
          ; name = "Mutation fixture"
          ; schema = { major = 65; minor = 33; exact = true }
          ; encrypted = false
          }
        in
        let sync_runner =
          Runner.sync_runner
            ~submit:(function
              | Sync.Request (ticket, Sync.Load_catalog _) ->
                let cache =
                  Sync.catalog_cache
                    ~user_id:"fixture-user"
                    ~graphs:[ graph ]
                    ~selected_graph:(Some graph.graph_id)
                in
                post
                  (Core.Sync_event
                     (Sync.Runner_completed (Sync.Completion (ticket, Ok (Some cache)))))
              | Sync.Request (ticket, Sync.Save_catalog _) ->
                post
                  (Core.Sync_event
                     (Sync.Runner_completed (Sync.Completion (ticket, Ok ()))))
              | Cancel_effects _ | Start_websocket _ | Close_websocket _ -> ()
              | effect_ ->
                failwith
                  ("unexpected sync effect: " ^ Sync.runner_effect_diagnostic effect_))
            ~shutdown:(fun () -> ())
            ()
        in
        let dependencies =
          Runner.dependencies
            ~runtime:(Runner.runtime ~fork:(fun ~sw:_ task -> task ()) |> Result.get_ok)
            ~config
            ~overlay:
              (Fixture.dependencies_with_limits
                 ~behavior:"worker change-window consumer"
                 (Option.value
                    overlay_limits
                    ~default:(Fixture.limits ~behavior:"worker changes")))
            ~sync_runner
            ~publish:(function
              | Core.Graph_push push -> Queue.add push pushes
              | _ -> ())
          |> Result.get_ok
        in
        let runner = Runner.create ~sw dependencies ~post |> Result.get_ok in
        let rec drain_events () =
          if not (Queue.is_empty events)
          then (
            let transition = Core.step !state (Queue.take events) in
            state := transition.next;
            List.iter
              (function
                | Core.Publish (Reply (id, response)) ->
                  Hashtbl.replace replies (Core.request_id_to_int64 id) response
                | instruction -> Runner.submit runner instruction)
              transition.effects;
            drain_events ())
        in
        let drain () =
          for _ = 1 to 4 do
            drain_events ();
            Eio.Fiber.yield ()
          done;
          drain_events ()
        in
        Fun.protect
          ~finally:(fun () -> Runner.shutdown runner)
          (fun () ->
             post
               (Core.Sync_event (Sync.Restore_local_account { user_id = "fixture-user" }));
             drain ();
             require
               ((Core.view !state).graph.phase = Graph_open)
               "fixture graph did not open";
             let next = ref 0L in
             let request request =
               next := Int64.succ !next;
               let id = Core.request_id_of_int64 !next in
               post (Core.Graph_request { id; request });
               drain ();
               let reply = Hashtbl.find_opt replies !next |> Option.get in
               Hashtbl.remove replies !next;
               reply
             in
             run { request; drain; pushes }))))
;;

let rec deliver worker runtime (output : Runtime.output) =
  output.responses
  @ List.concat_map
      (fun request ->
         worker.request request |> Runtime.receive runtime |> deliver worker runtime)
      output.requests
;;

let command ordinal command : P.request =
  { api_version = P.api_version; request_id = Fixture.mutation_uuid ordinal; command }
;;

let outcome worker ordinal value =
  let (P.V2_response { outcome; _ }) = worker.request (command ordinal value) in
  outcome
;;

let block_revision worker block =
  match outcome worker 801 (P.V2_get_block { block; revision = None }) with
  | V2_block_outcome (V2_present_block { revision; _ }) -> revision
  | _ -> failwith "worker block missing"
;;

let save worker ordinal block title =
  let revision = block_revision worker block in
  match
    outcome
      worker
      ordinal
      (P.V2_save_block
         { mutation_id = Fixture.mutation_uuid ordinal
         ; block
         ; title
         ; preconditions = { blocks = [ block, revision ]; pages = []; scopes = [] }
         })
  with
  | V2_mutation_committed _ -> ()
  | _ -> failwith "fixture save failed"
;;

let last_push worker =
  worker.drain ();
  let rec take latest =
    if Queue.is_empty worker.pushes
    then Option.get latest
    else take (Some (Queue.take worker.pushes))
  in
  take None
;;

let test_acknowledged_cursor () =
  with_worker (fun worker ->
    save worker 901 Fixture.authoritative_block_uuid "First visible change";
    let generation =
      match last_push worker with
      | P.V2_changes_available { generation; _ } -> generation
      | _ -> failwith "expected exact change push"
    in
    let first =
      outcome worker 902 (P.V2_pull_changes { generation; after = None; limit = 256 })
    in
    let through =
      match first with
      | V2_changes { through; windows = _ :: _; _ } -> through
      | _ -> failwith "first change window missing"
    in
    ignore (outcome worker 903 (P.V2_ack_changes { generation; through }));
    save worker 904 Fixture.authoritative_block_uuid "Second visible change";
    ignore (last_push worker);
    (match
       outcome
         worker
         905
         (P.V2_pull_changes { generation; after = Some through; limit = 256 })
     with
     | V2_changes { windows = _ :: _; _ } -> ()
     | _ -> failwith "acknowledged cursor lost the next real change window");
    ignore (outcome worker 906 (P.V2_ack_changes { generation; through }));
    match
      outcome
        worker
        907
        (P.V2_pull_changes { generation; after = Some through; limit = 256 })
    with
    | V2_changes { windows = _ :: _; _ } -> ()
    | _ -> failwith "duplicate acknowledgement discarded an unseen window")
;;

let test_empty_cursor_and_unknown_ack () =
  with_worker (fun worker ->
    let generation =
      match outcome worker 920 P.V2_graph_info with
      | V2_graph_info_outcome { generation; _ } -> generation
      | _ -> failwith "missing graph generation"
    in
    let empty =
      outcome worker 921 (P.V2_pull_changes { generation; after = None; limit = 256 })
    in
    let after =
      match empty with
      | V2_changes { windows = []; through; _ } -> through
      | _ -> failwith "initial window is not empty"
    in
    ignore (outcome worker 922 (P.V2_ack_changes { generation; through = after }));
    save worker 923 Fixture.authoritative_block_uuid "First change after empty inspection";
    ignore (last_push worker);
    (match
       outcome
         worker
         924
         (P.V2_pull_changes { generation; after = Some after; limit = 1 })
     with
     | V2_changes { windows = [ _ ]; _ } -> ()
     | _ -> failwith "empty-read boundary swallowed the first real change");
    (match
       outcome worker 925 (P.V2_ack_changes { generation; through = "unknown-cursor" })
     with
     | V2_resync_required _ -> ()
     | _ -> failwith "unknown acknowledgement was not rejected");
    (match
       outcome
         worker
         926
         (P.V2_pull_changes { generation; after = Some after; limit = 256 })
     with
     | V2_changes { windows = [ _ ]; _ } -> ()
     | _ -> failwith "unknown acknowledgement removed retained changes");
    match
      outcome
        worker
        927
        (P.V2_pull_changes { generation = "stale-generation"; after = None; limit = 256 })
    with
    | V2_resync_required _ -> ()
    | _ -> failwith "stale generation was admitted")
;;

let test_retained_window_pagination () =
  with_worker (fun worker ->
    for index = 1 to 70 do
      save
        worker
        (1000 + index)
        Fixture.authoritative_block_uuid
        (Printf.sprintf "Ordered change %d" index);
      ignore (last_push worker)
    done;
    let generation =
      match outcome worker 1100 P.V2_graph_info with
      | V2_graph_info_outcome { generation; _ } -> generation
      | _ -> failwith "missing graph generation"
    in
    let pull after limit =
      outcome worker 1101 (P.V2_pull_changes { generation; after; limit })
    in
    let all =
      match pull None 100 with
      | V2_changes { windows; next = None; _ } -> windows
      | _ -> failwith "retained window collection was truncated"
    in
    require (List.length all = 70) "publication lost a retained change";
    let rec ordered = function
      | (left : P.v2_change_window) :: ((right : P.v2_change_window) :: _ as rest) ->
        require
          (left.successor = right.predecessor)
          "projection revision chain was reordered";
        ordered rest
      | _ -> ()
    in
    ordered all;
    (match pull None 0 with
     | V2_changes { windows = []; through; next = Some next; _ } ->
       require
         (through = "change-window:v1:0" && next = through)
         "zero-limit cursor advanced"
     | _ -> failwith "zero-limit pull did not retain continuation");
    let rec pages after collected =
      match pull after 7 with
      | V2_changes { windows; through; next; _ } ->
        let collected = collected @ windows in
        (match next with
         | None -> collected
         | Some cursor ->
           require (cursor = through && windows <> []) "page cursor failed to advance";
           pages (Some cursor) collected)
      | _ -> failwith "retained page cursor was rejected"
    in
    require (pages None [] = all) "pagination changed window contents";
    let boundary = (List.nth all 31).id in
    ignore (outcome worker 1102 (P.V2_ack_changes { generation; through = boundary }));
    (match pull (Some boundary) 100 with
     | V2_changes { windows; _ } ->
       require (List.length windows = 38) "ack retained the wrong suffix"
     | _ -> failwith "acknowledged boundary was rejected");
    List.iter
      (fun cursor ->
         match pull (Some cursor) 1 with
         | V2_resync_required _ -> ()
         | _ -> failwith "nonexact or evicted cursor was accepted")
      [ (List.hd all).id; "change-window:v1:032"; "change-window:v1:999" ];
    require (List.length all = 70) "ack mutated an already returned page")
;;

let test_resync_clears_retained_windows () =
  let limits =
    { (Fixture.limits ~behavior:"window resync") with change_max_items = 16 }
  in
  with_worker ~limits (fun worker ->
    for index = 1 to 64 do
      save
        worker
        (3000 + index)
        Fixture.authoritative_block_uuid
        (Printf.sprintf "Before reset %d" index);
      ignore (last_push worker)
    done;
    let generation, old_cursor =
      match outcome worker 3100 P.V2_graph_info with
      | V2_graph_info_outcome { generation; _ } ->
        (match
           outcome worker 3101 (P.V2_pull_changes { generation; after = None; limit = 1 })
         with
         | V2_changes { windows = [ window ]; _ } -> generation, window.id
         | _ -> failwith "resync fixture did not retain changes")
      | _ -> failwith "missing generation"
    in
    let parent = Fixture.page_uuid in
    let page_revision =
      match outcome worker 3102 (P.V2_get_page { page = parent; revision = None }) with
      | V2_page_outcome (V2_present_page { revision; _ }) -> revision
      | _ -> failwith "resync page missing"
    in
    let scope_revision =
      match
        outcome
          worker
          3103
          (P.V2_get_children { parent; limit = 1; cursor = None; revision = None })
      with
      | V2_children_outcome { scope_revision; _ } -> scope_revision
      | _ -> failwith "resync scope missing"
    in
    let roots =
      [ P.
          { uuid = Fixture.mutation_uuid 3200
          ; title = "Resync tree"
          ; children =
              List.init 32 (fun n ->
                P.
                  { uuid = Fixture.mutation_uuid (3201 + n)
                  ; title = "Child"
                  ; children = []
                  })
          }
      ]
    in
    Gc.full_major ();
    let before = (Gc.stat ()).live_words in
    (match
       outcome
         worker
         3104
         (P.V2_insert_blocks
            { mutation_id = Fixture.mutation_uuid 3300
            ; parent
            ; roots
            ; preconditions =
                { blocks = []
                ; pages = [ parent, page_revision ]
                ; scopes = [ V2_children_scope parent, scope_revision ]
                }
            })
     with
     | V2_mutation_committed _ -> ()
     | _ -> failwith "resync insertion failed");
    (match last_push worker with
     | P.V2_resync_required_push _ -> ()
     | _ -> failwith "oversized publication did not request resync");
    (match
       outcome worker 3105 (P.V2_pull_changes { generation; after = None; limit = 100 })
     with
     | V2_changes { windows = []; next = None; _ } -> ()
     | _ -> failwith "resync retained obsolete windows");
    (match
       outcome
         worker
         3106
         (P.V2_pull_changes { generation; after = Some old_cursor; limit = 1 })
     with
     | V2_resync_required _ -> ()
     | _ -> failwith "resync admitted a discarded cursor");
    Gc.full_major ();
    Printf.printf
      "RESYNC_LIVE_WORDS before=%d after=%d\n%!"
      before
      (Gc.stat ()).live_words;
    save worker 3400 Fixture.authoritative_block_uuid "After reset";
    ignore (last_push worker);
    match
      outcome worker 3401 (P.V2_pull_changes { generation; after = None; limit = 100 })
    with
    | V2_changes { windows = [ _ ]; _ } -> ()
    | _ -> failwith "resync swallowed a later publication")
;;

let runtime () =
  let runtime = Runtime.create ~localtime:Unix.gmtime () in
  let sampler =
    Journal_calendar.Sampler.create
      ~clock:(fun () -> 1_704_067_200.)
      ~localtime:Unix.gmtime
      ()
  in
  ignore (Journal_calendar.Sampler.sample sampler |> Result.get_ok);
  Runtime.set_calendar runtime (Journal_calendar.Sampler.sample sampler |> Result.get_ok);
  runtime
;;

let capture worker runtime ordinal task_state =
  let creation_time =
    Journal_time.create
      ~instant_unix_ms:1_704_067_200_000L
      ~local_day:20240101
      ~local_minute_of_day:0
    |> Result.get_ok
  in
  let output =
    Runtime.submit
      runtime
      (Journal_graph_request.Capture
         { calendar_generation = 1L
         ; command =
             { mutation_id = Graph.Uuid.to_string (Fixture.mutation_uuid ordinal)
             ; block_id = Graph.Uuid.to_string (Fixture.mutation_uuid (ordinal + 100))
             ; sibling_order = string_of_int ordinal
             ; source = "Captured regression block"
             ; task_state
             ; creation_time
             ; children = []
             }
         })
  in
  match deliver worker runtime output with
  | [ { Runtime.payload = Block_captured { block; _ } } ] -> block
  | responses ->
    List.iter
      (fun response ->
         match response.Runtime.payload with
         | Rejected (Worker_failure failure) ->
           print_endline (Logseq_db_worker.Error.message failure.error)
         | Rejected (Projection_failure message) -> print_endline message
         | _ -> ())
      responses;
    failwith "capture did not complete"
;;

let test_delete_conflict_recovery () =
  with_worker (fun worker ->
    let runtime = runtime () in
    let captured = capture worker runtime 910 Journal_model.Todo in
    let block_id = Journal_model.id captured in
    save worker 911 (uuid block_id) "Concurrent edit before delete deadline";
    let deletion revision ordinal =
      Journal_graph_request.Delete_subtree
        { mutation_id = Graph.Uuid.to_string (Fixture.mutation_uuid ordinal)
        ; block_id
        ; expected_revision = revision
        }
    in
    let responses =
      Runtime.submit runtime (deletion (Journal_model.revision captured) 912)
      |> deliver worker runtime
    in
    let latest =
      List.find_map
        (fun response ->
           match response.Runtime.payload with
           | Delete_conflict block -> Some block
           | _ -> None)
        responses
    in
    let latest =
      match latest with
      | Some block -> block
      | None -> failwith "delete conflict did not reconcile the authoritative target"
    in
    require
      (Journal_model.source latest = "Concurrent edit before delete deadline")
      "delete recovery retained stale source";
    let responses =
      Runtime.submit runtime (deletion (Journal_model.revision latest) 913)
      |> deliver worker runtime
    in
    require
      (List.exists
         (fun response ->
            match response.Runtime.payload with
            | Subtree_deleted _ -> true
            | _ -> false)
         responses)
      "second delete failed after authoritative reconciliation")
;;

let test_reconciled_capture_status () =
  with_worker (fun worker ->
    let runtime = runtime () in
    let captured = capture worker runtime 930 Journal_model.No_status in
    let sync () =
      let push = last_push worker in
      Runtime.reconcile_push runtime ~request_generation:11L push
      |> deliver worker runtime
    in
    ignore (sync ());
    let block_id = Journal_model.id captured in
    save worker 931 (uuid block_id) "Reconciled capture";
    let responses = sync () in
    let latest =
      List.find_map
        (fun response ->
           match response.Runtime.payload with
           | Block_updated { block; _ } when Journal_model.id block = block_id ->
             Some block
           | Page_tree_reconciled { value; _ } ->
             List.find_map
               (fun (entry : Journal_graph_projection.timeline_entry) ->
                  if Journal_model.id entry.block = block_id
                  then Some entry.block
                  else None)
               value.entries
           | _ -> None)
        responses
    in
    let latest =
      match latest with
      | Some block -> block
      | None ->
        failwith
          "authoritative target revision never reached caller-visible reconciliation"
    in
    require
      (Journal_model.revision latest = block_revision worker (uuid block_id))
      "reconciliation emitted obsolete block revision";
    save worker 932 Fixture.authoritative_block_uuid "Unrelated target change";
    let responses =
      Runtime.submit
        runtime
        (Journal_graph_request.Set_task_state
           { mutation_id = Graph.Uuid.to_string (Fixture.mutation_uuid 933)
           ; block_id
           ; expected_revision = Journal_model.revision latest
           ; task_state = Journal_model.Backlog
           })
      |> deliver worker runtime
    in
    require
      (List.exists
         (fun response ->
            match response.Runtime.payload with
            | Block_updated { block; _ } ->
              Journal_model.task_state block = Journal_model.Backlog
            | _ -> false)
         responses)
      "first status change falsely conflicted after reconciliation and unrelated write";
    let pending = Runtime.submit runtime (Journal_graph_request.Find_block block_id) in
    let response = worker.request (only pending.requests) in
    Runtime.reset runtime;
    let stale = Runtime.receive runtime response in
    require
      (stale.requests = [] && stale.responses = [])
      "stale graph completion survived runtime reset")
;;

let () =
  let failures = ref [] in
  List.iter
    (fun (name, test) ->
       try
         test ();
         Printf.printf "PASS %s\n%!" name
       with
       | exn ->
         failures := name :: !failures;
         Printf.printf "FAIL %s: %s\n%!" name (Printexc.to_string exn))
    [ "Resync clears retained windows", test_resync_clears_retained_windows
    ; "Retained window pagination", test_retained_window_pagination
    ; "M03 real worker acknowledged change cursor", test_acknowledged_cursor
    ; "M03 empty cursor and unknown acknowledgement", test_empty_cursor_and_unknown_ack
    ; "M03 reconciled capture first status", test_reconciled_capture_status
    ; "M03 captured Todo delete conflict recovery", test_delete_conflict_recovery
    ];
  require (!failures = []) "macOS mutation runtime regressions failed";
  print_endline "MACOS_MUTATION_RUNTIME_TESTS_PASSED"
;;
