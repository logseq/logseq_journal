open Datascript
module ID = Bonsai_flutter_spec.Id

let fail format = Printf.ksprintf failwith format

let require condition format =
  Printf.ksprintf (fun message -> if not condition then failwith message) format
;;

let require_repository_ok = function
  | Ok value -> value
  | Error error ->
    fail "unexpected repository error: %s" (Journal_repository.Error.to_string error)
;;

let rec remove_tree path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Sys.readdir path |> Array.iter (fun name -> remove_tree (Filename.concat path name));
    Unix.rmdir path
  | _ -> Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
;;

let with_temp_startup ?(access_mode = Journal_startup.Read_write) test =
  let root = Filename.temp_file "journal-worker-" "" in
  Sys.remove root;
  Unix.mkdir root 0o700;
  Unix.mkdir (Filename.concat root "logseq_journal") 0o700;
  let root = Unix.realpath root in
  let startup : Journal_startup.t =
    { application_support_root = root
    ; expected_schema_version = Journal_schema.version
    ; initial_calendar =
        { instant_unix_ms = 1_786_204_800_000L
        ; local_day = 20260809
        ; local_minute_of_day = 0
        ; locale = "en_US"
        ; time_zone_id = "Asia/Shanghai"
        ; utc_offset_seconds = 28_800
        ; generation = 7L
        ; lifecycle_generation = 0L
        }
    ; access_mode
    ; diagnostic_mode = Operational_only
    }
  in
  Fun.protect ~finally:(fun () -> remove_tree root) (fun () -> test startup)
;;

let database_path startup =
  match
    Journal_storage_path.resolve
      ~support_root:startup.Journal_startup.application_support_root
      ~relative_path:Journal_startup.database_relative_path
  with
  | Ok value -> value
  | Error error ->
    fail "database path failed: %s" (Journal_storage_path.Error.to_string error)
;;

let start_result ~runtime_epoch startup =
  Worker_runtime.start
    ~runtime_epoch:(ID.Runtime.Epoch.of_int64 runtime_epoch)
    Journal_worker.service
    startup
;;

let start ~runtime_epoch startup =
  match start_result ~runtime_epoch startup with
  | Ok client -> client
  | Error error -> fail "worker startup failed: %s" error
;;

let accepted = function
  | Worker.Accepted request_id -> request_id
  | Full -> fail "worker request unexpectedly hit backpressure"
  | Not_ready -> fail "worker was not ready"
  | Stopping -> fail "worker was stopping"
;;

let rec drain_until client predicate events =
  let events = events @ Worker.For_testing.drain_events client ~max_events:64 in
  match List.find_opt predicate events with
  | Some event -> event
  | None ->
    Worker.For_testing.await_output client;
    drain_until client predicate events
;;

let ready client =
  Worker.For_testing.await_output client;
  match
    drain_until
      client
      (function
        | Worker.Push { payload = Journal_worker.Ready _; _ } -> true
        | Response _ | Terminal _ -> false)
      []
  with
  | Worker.Push { payload = Ready response; _ } -> response
  | Response _ | Terminal _ -> assert false
;;

let response client request =
  let request_id = accepted (Worker.send client request) in
  match
    drain_until
      client
      (function
        | Worker.Response { request_id = actual; _ } ->
          ID.Worker.Request_id.equal request_id actual
        | Push _ | Terminal _ -> false)
      []
  with
  | Worker.Response { outcome = Completed response; _ } -> response
  | Worker.Response { outcome = Failed error; _ } ->
    fail "worker callback failed: %s" error
  | Worker.Response { outcome = Cancelled; _ } -> fail "worker request was cancelled"
  | Worker.Response { outcome = Shutdown; _ } -> fail "worker request was shut down"
  | Push _ | Terminal _ -> assert false
;;

let responses client request_ids =
  let is_target request_id =
    List.exists (ID.Worker.Request_id.equal request_id) request_ids
  in
  let rec collect completed =
    if List.length completed = List.length request_ids
    then completed
    else (
      Worker.For_testing.await_output client;
      let completed =
        Worker.For_testing.drain_events client ~max_events:64
        |> List.fold_left
             (fun completed -> function
                | Worker.Response { request_id; outcome = Worker.Completed response; _ }
                  when is_target request_id -> (request_id, response) :: completed
                | Worker.Response { request_id; outcome = Worker.Failed error; _ }
                  when is_target request_id -> fail "worker callback failed: %s" error
                | Worker.Response { request_id; outcome = Worker.Cancelled; _ }
                  when is_target request_id -> fail "worker request was cancelled"
                | Worker.Response { request_id; outcome = Worker.Shutdown; _ }
                  when is_target request_id -> fail "worker request was shut down"
                | Worker.Response _ | Worker.Push _ | Worker.Terminal _ -> completed)
             completed
      in
      collect completed)
  in
  collect []
;;

let id kind index = Printf.sprintf "70000000-0000-4000-%s-%012d" kind index

let creation_time ?(minute = 0) day =
  let midnight =
    match day with
    | 20260808 -> 1_786_118_400_000L
    | 20260809 -> 1_786_204_800_000L
    | 20260810 -> 1_786_291_200_000L
    | _ -> fail "unsupported fixture day: %d" day
  in
  match
    Journal_time.create
      ~instant_unix_ms:(Int64.add midnight (Int64.of_int (minute * 60_000)))
      ~local_day:day
      ~local_minute_of_day:minute
      ~time_zone_id:"Asia/Shanghai"
      ~utc_offset_seconds:28_800
  with
  | Ok value -> value
  | Error error -> fail "creation time failed: %s" error
;;

let capture ?(day = 20260809) ?(source = "Worker source") index
  : Journal_repository.capture
  =
  { mutation_id = id "9000" index
  ; block_id = id "a000" index
  ; sibling_order = Printf.sprintf "%012d" index
  ; source
  ; task_state = Journal_model.Todo
  ; creation_time = creation_time ~minute:(index mod 1_440) day
  }
;;

let expect_store_ready disposition response =
  require
    (response.Journal_worker.payload = Journal_worker.Store_ready disposition)
    "worker did not report the expected store disposition"
;;

let expect_captured
      (command : Journal_repository.capture)
      (response : Journal_worker.response)
  =
  match response.Journal_worker.payload with
  | Journal_worker.Block_captured block ->
    require
      (String.equal (Journal_model.id block) command.Journal_repository.block_id)
      "captured block identity changed";
    block
  | _ -> fail "worker did not return Block_captured"
;;

let test_exclusive_session_status_shutdown_and_replacement () =
  with_temp_startup (fun startup ->
    let first = start ~runtime_epoch:1_001L startup in
    expect_store_ready Journal_storage.Initialized (ready first);
    let status = response first Journal_worker.Get_status in
    require
      (status.payload = Journal_worker.Status Journal_storage.Ready)
      "ready worker reported the wrong storage status";
    (match start_result ~runtime_epoch:1_002L startup with
     | Error _ -> ()
     | Ok competing ->
       Worker_runtime.stop competing;
       fail "a second Worker session attached concurrently");
    let command = capture 1 in
    ignore
      (response first (Journal_worker.Capture { calendar_generation = 7L; command })
       |> expect_captured command);
    Worker_runtime.stop first;
    require (Worker.For_testing.is_stopping first) "stopped worker remained active";
    let replacement = start ~runtime_epoch:1_003L startup in
    expect_store_ready Journal_storage.Restored (ready replacement);
    (match
       (response replacement (Journal_worker.Find_block command.block_id)).payload
     with
     | Block_found (Some block) ->
       require
         (String.equal (Journal_model.source block) command.source)
         "replacement worker lost durable source"
     | _ -> fail "replacement worker did not restore the block");
    Worker_runtime.stop replacement)
;;

let test_bounded_feed_day_children_detail_and_generations () =
  with_temp_startup (fun startup ->
    let client = start ~runtime_epoch:1_010L startup in
    ignore (ready client);
    let today = capture 10 in
    let older = capture ~day:20260808 11 in
    let parent =
      response
        client
        (Journal_worker.Capture { calendar_generation = 7L; command = today })
      |> expect_captured today
    in
    require
      ((response
          client
          (Journal_worker.Observe_calendar { generation = 8L; local_day = 20260808 }))
         .payload
       = Journal_worker.Calendar_observed 8L)
      "calendar did not move to the older fixture day";
    ignore
      (response
         client
         (Journal_worker.Capture { calendar_generation = 8L; command = older })
       |> expect_captured older);
    let child_command : Journal_repository.create_child =
      { mutation_id = id "9000" 12
      ; block_id = id "a000" 12
      ; parent_block_id = Journal_model.id parent
      ; expected_parent_revision = 1
      ; sibling_order = "000000000001"
      ; source = "Direct child"
      ; task_state = Journal_model.Not_a_task
      ; creation_time = creation_time ~minute:12 20260809
      }
    in
    (match (response client (Journal_worker.Create_child child_command)).payload with
     | Child_created { child; parent_revision = 2 } ->
       require
         (String.equal (Journal_model.id child) child_command.block_id)
         "child identity changed"
     | _ -> fail "worker did not create the direct child atomically");
    let feed =
      response
        client
        (Journal_worker.Load_feed
           { before_day = None
           ; day_limit = 1
           ; blocks_per_day = 1
           ; slot_limit = 3
           ; request_generation = 41L
           })
    in
    (match feed.payload with
     | Feed_loaded { request_generation = 41L; feed } ->
       require (List.length feed.days = 1) "feed ignored the day bound";
       require feed.has_more_days "feed lost its day continuation";
       require (feed.slot_count <= 3) "feed exceeded the logical slot bound"
     | _ -> fail "worker did not echo the feed request generation");
    let day_page =
      response
        client
        (Journal_worker.Load_day_blocks
           { day = 20260809; after = None; limit = 1; request_generation = 42L })
    in
    (match day_page.payload with
     | Day_blocks_loaded { request_generation = 42L; page } ->
       require (List.length page.blocks = 1) "day page ignored its row bound"
     | _ -> fail "worker did not echo the day request generation");
    let detail =
      response
        client
        (Journal_worker.Load_detail
           { block_id = today.block_id
           ; after = None
           ; limit = 1
           ; request_generation = 43L
           })
    in
    (match detail.payload with
     | Detail_loaded { request_generation = 43L; detail } ->
       require
         (String.equal (Journal_model.id detail.root) today.block_id)
         "detail root changed";
       require (List.length detail.children.blocks = 1) "detail child page is wrong"
     | _ -> fail "worker did not echo the Detail request generation");
    Worker_runtime.stop client)
;;

let test_mutation_idempotency_conflict_and_reconciliation () =
  with_temp_startup (fun startup ->
    let client = start ~runtime_epoch:1_020L startup in
    ignore (ready client);
    let command = capture 20 in
    let original =
      response client (Journal_worker.Capture { calendar_generation = 7L; command })
      |> expect_captured command
    in
    let duplicate =
      response client (Journal_worker.Capture { calendar_generation = 7L; command })
      |> expect_captured command
    in
    require
      (Journal_model.revision duplicate = Journal_model.revision original)
      "duplicate capture advanced the revision";
    let update : Journal_repository.update_source =
      { mutation_id = id "9000" 21
      ; block_id = command.block_id
      ; expected_revision = 1
      ; source = "Edited #tag @mention 👩🏽‍💻"
      }
    in
    let edited = response client (Journal_worker.Update_source update) in
    (match edited.payload with
     | Block_updated block ->
       require (Journal_model.revision block = 2) "edit revision is wrong";
       require
         (String.equal (Journal_model.source block) update.source)
         "literal source changed"
     | _ -> fail "worker did not apply the source edit");
    (match (response client (Journal_worker.Update_source update)).payload with
     | Block_updated block ->
       require (Journal_model.revision block = 2) "duplicate edit advanced revision"
     | _ -> fail "worker did not idempotently replay the source edit");
    let stale =
      { update with mutation_id = id "9000" 22; expected_revision = 1; source = "Stale" }
    in
    (match (response client (Journal_worker.Update_source stale)).payload with
     | Update_conflict block ->
       require (Journal_model.revision block = 2) "conflict lost the latest revision"
     | _ -> fail "stale edit did not return a typed conflict");
    let task : Journal_repository.set_task_state =
      { mutation_id = id "9000" 23
      ; block_id = command.block_id
      ; expected_revision = 2
      ; task_state = Journal_model.Done
      }
    in
    (match (response client (Journal_worker.Set_task_state task)).payload with
     | Block_updated block ->
       require (Journal_model.revision block = 3) "task revision is wrong";
       require
         (Journal_model.task_state block = Journal_model.Done)
         "task state did not become Done"
     | _ -> fail "worker did not apply the task transition");
    (match
       (response
          client
          (Journal_worker.Reconcile
             { mutation_id = task.mutation_id; block_id = command.block_id }))
         .payload
     with
     | Reconciled_applied block ->
       require (Journal_model.revision block = 3) "reconciliation returned stale data"
     | _ -> fail "worker did not confirm the applied mutation");
    (match
       (response
          client
          (Journal_worker.Reconcile
             { mutation_id = id "9000" 24; block_id = command.block_id }))
         .payload
     with
     | Reconciled_superseded _ -> ()
     | _ -> fail "worker did not distinguish a superseded mutation");
    (match
       (response
          client
          (Journal_worker.Reconcile
             { mutation_id = id "9000" 25; block_id = id "a000" 25 }))
         .payload
     with
     | Reconciled_not_applied -> ()
     | _ -> fail "worker did not distinguish an unapplied mutation");
    Worker_runtime.stop client)
;;

let test_calendar_and_runtime_generation_fencing () =
  with_temp_startup (fun startup ->
    let client = start ~runtime_epoch:1_030L startup in
    let ready_response = ready client in
    require
      (ready_response.calendar = startup.initial_calendar)
      "Worker Ready did not preserve the complete calendar snapshot";
    let stale_capture = capture ~day:20260808 30 in
    let rejected =
      response
        client
        (Journal_worker.Capture { calendar_generation = 7L; command = stale_capture })
    in
    require
      (rejected.payload = Journal_worker.Rejected Invalid_calendar_snapshot)
      "capture accepted creation facts for a different observed local day";
    require
      ((response
          client
          (Journal_worker.Observe_calendar { generation = 6L; local_day = 20260808 }))
         .payload
       = Journal_worker.Rejected Stale_calendar_generation)
      "stale calendar generation was accepted";
    require
      ((response
          client
          (Journal_worker.Observe_calendar { generation = 7L; local_day = 20260810 }))
         .payload
       = Journal_worker.Rejected Invalid_calendar_snapshot)
      "same calendar generation changed its local day";
    require
      ((response
          client
          (Journal_worker.Observe_calendar { generation = 8L; local_day = 20260810 }))
         .payload
       = Journal_worker.Calendar_observed 8L)
      "new calendar generation was not accepted";
    Worker.For_testing.inject_push
      client
      ~runtime_epoch:(ID.Runtime.Epoch.of_int64 1_029L)
      ~worker_generation:(Worker.worker_generation client)
      ~push_sequence:(ID.Worker.Push_sequence.of_int64 100L)
      ~topic:(ID.Worker.Push_topic.of_int 0)
      (Journal_worker.Ready ready_response);
    require
      (Worker.For_testing.drain_events client ~max_events:1 = [])
      "late output from an obsolete runtime epoch was delivered";
    Worker.For_testing.inject_push
      client
      ~runtime_epoch:(Worker.runtime_epoch client)
      ~worker_generation:(ID.Worker.Generation.of_int64 9_999L)
      ~push_sequence:(ID.Worker.Push_sequence.of_int64 101L)
      ~topic:(ID.Worker.Push_topic.of_int 0)
      (Journal_worker.Ready ready_response);
    require
      (Worker.For_testing.drain_events client ~max_events:1 = [])
      "late output from an obsolete worker generation was delivered";
    Worker_runtime.stop client)
;;

let test_rapid_repeated_actions_missing_block_and_deleted_parent () =
  with_temp_startup (fun startup ->
    let client = start ~runtime_epoch:1_035L startup in
    ignore (ready client);
    let command = capture ~source:"One admitted action" 35 in
    let request = Journal_worker.Capture { calendar_generation = 7L; command } in
    let first_id = accepted (Worker.send client request) in
    let second_id = accepted (Worker.send client request) in
    let completed = responses client [ first_id; second_id ] in
    require (List.length completed = 2) "rapid duplicate actions lost a response";
    List.iter
      (fun (_, response) ->
         let captured = expect_captured command response in
         require
           (Journal_model.revision captured = 1)
           "rapid duplicate action advanced the durable revision")
      completed;
    (match
       (response
          client
          (Journal_worker.Load_detail
             { block_id = id "a000" 36
             ; after = None
             ; limit = 64
             ; request_generation = 351L
             }))
         .payload
     with
     | Journal_worker.Rejected (Invalid_request message) ->
       require
         (String.equal message "detail root block does not exist")
         "missing Detail returned an ambiguous error: %S"
         message
     | _ -> fail "missing Detail did not return a typed unavailable result");
    let child : Journal_repository.create_child =
      { mutation_id = id "9000" 37
      ; block_id = id "a000" 37
      ; parent_block_id = id "a000" 38
      ; expected_parent_revision = 1
      ; sibling_order = "000000000037"
      ; source = "Child of deleted parent"
      ; task_state = Journal_model.Not_a_task
      ; creation_time = creation_time ~minute:37 20260809
      }
    in
    (match (response client (Journal_worker.Create_child child)).payload with
     | Journal_worker.Rejected (Invalid_request message) ->
       require
         (String.equal message "parent block does not exist")
         "deleted parent returned an ambiguous error: %S"
         message
     | _ -> fail "direct-child creation accepted a missing or deleted parent");
    Worker_runtime.stop client)
;;

let prepare_oversized_store startup =
  let path = database_path startup in
  let store =
    match Journal_storage.open_store ~canonical_path:path with
    | Ok (store, _) -> store
    | Error error -> fail "store setup failed: %s" (Journal_storage.Error.to_string error)
  in
  let command = capture 40 in
  let transaction =
    match
      Journal_repository.prepare_capture (Journal_storage.current_db store) command
      |> require_repository_ok
    with
    | Journal_repository.Apply transaction -> transaction
    | Already_applied _ -> fail "fresh oversized fixture already existed"
  in
  let report =
    match Journal_storage.transact store transaction with
    | Ok report -> report
    | Error error ->
      fail "fixture capture failed: %s" (Journal_storage.Error.to_string error)
  in
  ignore report;
  let oversized = String.make 65_537 'x' in
  let update =
    [ Add
        ( Lookup_ref (Journal_schema.Attr.block_id, Uuid command.block_id)
        , Journal_schema.Attr.block_source
        , String oversized )
    ]
  in
  (match Journal_storage.transact store update with
   | Ok _ -> ()
   | Error error ->
     fail "oversized fixture failed: %s" (Journal_storage.Error.to_string error));
  (match Journal_storage.close store with
   | Ok () -> ()
   | Error error ->
     fail "fixture close failed: %s" (Journal_storage.Error.to_string error));
  command
;;

let test_oversized_source_locks_mutations_and_all_responses_are_bounded () =
  with_temp_startup (fun startup ->
    let oversized = prepare_oversized_store startup in
    let client = start ~runtime_epoch:1_040L startup in
    expect_store_ready Journal_storage.Restored (ready client);
    let found = response client (Journal_worker.Find_block oversized.block_id) in
    (match found.payload with
     | Oversized_source value ->
       require (String.equal value.block_id oversized.block_id) "oversized ID changed";
       require (value.measured_bytes = 65_537) "oversized byte count changed"
     | _ -> fail "worker did not return typed oversized-source diagnostics");
    let blocked = capture 41 in
    require
      ((response
          client
          (Journal_worker.Capture { calendar_generation = 7L; command = blocked }))
         .payload
       = Journal_worker.Rejected Editing_locked)
      "oversized durable source did not lock mutations";
    require
      (Journal_worker.estimated_payload_bytes found <= 256 * 1_024)
      "oversized diagnostic exceeded the response budget";
    Worker_runtime.stop client);
  with_temp_startup (fun startup ->
    let client = start ~runtime_epoch:1_041L startup in
    ignore (ready client);
    for index = 50 to 54 do
      let command =
        capture ~source:(String.make 65_536 (Char.chr (97 + (index mod 20)))) index
      in
      let captured =
        response client (Journal_worker.Capture { calendar_generation = 7L; command })
      in
      ignore (expect_captured command captured);
      require
        (Journal_worker.estimated_payload_bytes captured <= 256 * 1_024)
        "mutation response exceeded the response budget"
    done;
    let loaded =
      response
        client
        (Journal_worker.Load_day_blocks
           { day = 20260809; after = None; limit = 64; request_generation = 50L })
    in
    require
      (loaded.payload
       = Journal_worker.Rejected
           (Invalid_request "Worker response exceeds the application budget"))
      "oversized aggregate response was not replaced deterministically";
    require
      (Journal_worker.estimated_payload_bytes loaded <= 256 * 1_024)
      "replacement rejection exceeded the response budget";
    Worker_runtime.stop client)
;;

let test_recovery_only_and_storage_failure_transition () =
  with_temp_startup ~access_mode:Journal_startup.Recovery_only (fun startup ->
    let client = start ~runtime_epoch:1_050L startup in
    ignore (ready client);
    let command = capture 60 in
    let rejected =
      response client (Journal_worker.Capture { calendar_generation = 7L; command })
    in
    require
      (rejected.payload = Journal_worker.Rejected Recovery_only)
      "recovery-only worker accepted a mutation";
    ignore
      (response
         client
         (Journal_worker.Load_feed
            { before_day = None
            ; day_limit = 1
            ; blocks_per_day = 1
            ; slot_limit = 2
            ; request_generation = 60L
            }));
    Worker_runtime.stop client);
  with_temp_startup (fun startup ->
    let client = start ~runtime_epoch:1_051L startup in
    ignore (ready client);
    let competing = Sqlite3.db_open (database_path startup) in
    Fun.protect
      ~finally:(fun () ->
        ignore (Sqlite3.exec competing "ROLLBACK");
        require (Sqlite3.db_close competing) "failed to close competing SQLite handle";
        Worker_runtime.stop client)
      (fun () ->
         let result = Sqlite3.exec competing "BEGIN EXCLUSIVE" in
         require
           (Sqlite3.Rc.is_success result)
           "failed to acquire competing SQLite lock: %s"
           (Sqlite3.Rc.to_string result);
         let command = capture 61 in
         let failed =
           response client (Journal_worker.Capture { calendar_generation = 7L; command })
         in
         require
           (failed.payload = Journal_worker.Rejected Storage_unavailable)
           "SQLite failure did not reject the mutation";
         require
           (failed.access_mode = Journal_startup.Recovery_only)
           "SQLite failure did not transition the worker to recovery-only mode";
         let status = response client Journal_worker.Get_status in
         require
           (status.payload = Journal_worker.Status Journal_storage.Terminal)
           "SQLite failure did not leave terminal storage status";
         require
           (status.access_mode = Journal_startup.Recovery_only)
           "terminal status did not preserve recovery-only mode"))
;;

let test_delete_subtree_is_durable_bounded_idempotent_and_updates_parent () =
  with_temp_startup (fun startup ->
    let client = start ~runtime_epoch:1_060L startup in
    ignore (ready client);
    let parent_command = capture 70 in
    let parent =
      response
        client
        (Journal_worker.Capture { calendar_generation = 7L; command = parent_command })
      |> expect_captured parent_command
    in
    let child_command : Journal_repository.create_child =
      { mutation_id = id "9000" 71
      ; block_id = id "a000" 71
      ; parent_block_id = Journal_model.id parent
      ; expected_parent_revision = 1
      ; sibling_order = "a"
      ; source = "Delete worker child"
      ; task_state = Journal_model.Not_a_task
      ; creation_time = creation_time ~minute:71 20260809
      }
    in
    let child =
      match (response client (Journal_worker.Create_child child_command)).payload with
      | Journal_worker.Child_created { child; parent_revision = 2 } -> child
      | _ -> fail "worker delete fixture child was not created"
    in
    let grandchild_command : Journal_repository.create_child =
      { mutation_id = id "9000" 72
      ; block_id = id "a000" 72
      ; parent_block_id = Journal_model.id child
      ; expected_parent_revision = 1
      ; sibling_order = "a"
      ; source = "Delete worker grandchild"
      ; task_state = Journal_model.Not_a_task
      ; creation_time = creation_time ~minute:72 20260809
      }
    in
    (match (response client (Journal_worker.Create_child grandchild_command)).payload with
     | Child_created _ -> ()
     | _ -> fail "worker delete fixture grandchild was not created");
    let child =
      match
        (response client (Journal_worker.Find_block (Journal_model.id child))).payload
      with
      | Block_found (Some child) -> child
      | _ -> fail "worker delete fixture child did not reload"
    in
    let stale : Journal_repository.delete_subtree =
      { mutation_id = id "9000" 73
      ; block_id = Journal_model.id child
      ; expected_revision = 99
      }
    in
    (match (response client (Journal_worker.Delete_subtree stale)).payload with
     | Journal_worker.Delete_conflict latest ->
       require
         (String.equal (Journal_model.id latest) (Journal_model.id child))
         "delete conflict returned wrong root"
     | _ -> fail "stale Worker delete did not conflict");
    let command : Journal_repository.delete_subtree =
      { mutation_id = id "9000" 74
      ; block_id = Journal_model.id child
      ; expected_revision = Journal_model.revision child
      }
    in
    let deleted = response client (Journal_worker.Delete_subtree command) in
    (match deleted.payload with
     | Journal_worker.Subtree_deleted
         { block_id; deleted_count = 2; parent = Some updated_parent } ->
       require (String.equal block_id command.block_id) "delete response changed root ID";
       require (Journal_model.revision updated_parent = 3) "returned parent is stale";
       require
         (Journal_model.child_count updated_parent = 0)
         "returned parent count is stale"
     | _ -> fail "Worker did not return bounded subtree deletion metadata");
    require
      (Journal_worker.estimated_payload_bytes deleted <= 256 * 1_024)
      "delete response exceeded Worker budget";
    (match (response client (Journal_worker.Delete_subtree command)).payload with
     | Subtree_deleted { deleted_count = 0; parent = None; _ } -> ()
     | _ -> fail "already-absent Worker delete was not idempotent");
    Worker_runtime.stop client;
    let replacement = start ~runtime_epoch:1_061L startup in
    ignore (ready replacement);
    List.iter
      (fun block_id ->
         match (response replacement (Journal_worker.Find_block block_id)).payload with
         | Block_found None -> ()
         | _ -> fail "deleted subtree member reappeared after restart")
      [ child_command.block_id; grandchild_command.block_id ];
    (match
       (response
          replacement
          (Journal_worker.Load_detail
             { block_id = parent_command.block_id
             ; after = None
             ; limit = 64
             ; request_generation = 75L
             }))
         .payload
     with
     | Detail_loaded { detail; _ } ->
       require (detail.children.blocks = []) "durable Detail retained deleted children"
     | _ -> fail "durable parent Detail did not reload");
    Worker_runtime.stop replacement);
  with_temp_startup ~access_mode:Journal_startup.Recovery_only (fun startup ->
    let client = start ~runtime_epoch:1_062L startup in
    ignore (ready client);
    let command : Journal_repository.delete_subtree =
      { mutation_id = id "9000" 76; block_id = id "a000" 76; expected_revision = 1 }
    in
    require
      ((response client (Journal_worker.Delete_subtree command)).payload
       = Journal_worker.Rejected Recovery_only)
      "recovery-only Worker accepted delete";
    Worker_runtime.stop client)
;;

let tests =
  [ ( "exclusive session, status, shutdown, and replacement"
    , test_exclusive_session_status_shutdown_and_replacement )
  ; ( "bounded feed, day, children, Detail, and generations"
    , test_bounded_feed_day_children_detail_and_generations )
  ; ( "mutation idempotency, conflict, and reconciliation"
    , test_mutation_idempotency_conflict_and_reconciliation )
  ; ( "calendar and runtime generation fencing"
    , test_calendar_and_runtime_generation_fencing )
  ; ( "rapid repeated actions, missing block, and deleted parent"
    , test_rapid_repeated_actions_missing_block_and_deleted_parent )
  ; ( "oversized source and bounded responses"
    , test_oversized_source_locks_mutations_and_all_responses_are_bounded )
  ; ( "recovery-only and storage failure transition"
    , test_recovery_only_and_storage_failure_transition )
  ; ( "durable bounded idempotent subtree deletion"
    , test_delete_subtree_is_durable_bounded_idempotent_and_updates_parent )
  ]
;;

let () =
  Fun.protect ~finally:Worker_runtime.For_testing.final_shutdown (fun () ->
    List.iter
      (fun (name, test) ->
         Printf.printf "running %s\n%!" name;
         test ())
      tests)
;;
