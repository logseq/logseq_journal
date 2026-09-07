module Graph = Logseq_db_types.Graph_types
module Protocol = Logseq_db_worker.Protocol
module Runtime = Journal_graph_runtime

let uuid value = Graph.Uuid.of_string value |> Result.get_ok

let only label = function
  | [ value ] -> value
  | values -> Alcotest.failf "%s: expected one value, got %d" label (List.length values)
;;

let respond (request : Protocol.request) outcome =
  Protocol.V2_response
    { api_version = Protocol.api_version; request_id = request.request_id; outcome }
;;

let page_uuid = uuid "a2000000-0000-4000-8000-000000000001"
let block_uuid = uuid "a2000000-0000-4000-9000-000000000001"

let page : Graph.page =
  { uuid = page_uuid
  ; name = "20260901"
  ; title = "2026-09-01"
  ; kind = Journal_page { journal_day = 20260901 }
  ; created_at_ms = 1_788_192_000_000L
  ; updated_at_ms = 1_788_192_000_000L
  ; recycled = false
  ; tags = []
  ; properties = []
  }
;;

let block : Graph.block =
  { uuid = block_uuid
  ; title = "Current title"
  ; parent = page_uuid
  ; page = page_uuid
  ; order = "a"
  ; created_at_ms = 1_788_192_000_000L
  ; updated_at_ms = 1_788_192_000_000L
  ; refs = []
  ; tags = []
  ; properties = []
  }
;;

let record : Protocol.v2_block_record =
  { block; task_status = None; rendered_page_title = page.title }
;;

let capture : Journal_graph_projection.capture =
  { mutation_id = "a2000000-0000-4000-a000-000000000002"
  ; block_id = "a2000000-0000-4000-9000-000000000002"
  ; sibling_order = "000000000002"
  ; source = "Captured locally"
  ; task_state = Journal_model.No_status
  ; creation_time =
      Journal_time.create
        ~instant_unix_ms:1_788_220_800_000L
        ~local_day:20260901
        ~local_minute_of_day:0
      |> Result.get_ok
  ; children = []
  }
;;

let capture_page_request_for runtime command =
  Runtime.submit
    runtime
    (Journal_graph_request.Capture { calendar_generation = 1L; command })
  |> fun output -> only "capture page request" output.requests
;;

let set_calendar runtime =
  let sampler =
    Journal_calendar.Sampler.create
      ~clock:(fun () -> 1_788_192_000.)
      ~localtime:Unix.gmtime
      ()
  in
  ignore (Journal_calendar.Sampler.sample sampler |> Result.get_ok);
  let calendar = Journal_calendar.Sampler.sample sampler |> Result.get_ok in
  Runtime.set_calendar runtime calendar
;;

let seed_visible_block runtime =
  set_calendar runtime;
  let journals =
    Runtime.submit
      runtime
      (Journal_graph_request.Load_feed
         { before_day = None
         ; day_limit = 1
         ; blocks_per_day = 2
         ; slot_limit = 4
         ; request_generation = 7L
         })
    |> fun output -> only "journal request" output.requests
  in
  let tree =
    Runtime.receive
      runtime
      (respond
         journals
         (Protocol.V2_journals_outcome
            { items = [ { page; journal_day = 20260901; revision = "page-1" } ]
            ; next_cursor = None
            }))
    |> fun output -> only "page-tree request" output.requests
  in
  Runtime.receive
    runtime
    (respond
       tree
       (Protocol.V2_page_tree_outcome
          { page = page_uuid
          ; maximum_depth = 1
          ; revision_scope = V2_page_tree_revision { page = page_uuid; maximum_depth = 1 }
          ; scope_revision = "tree-scope-1"
          ; items =
              [ { value = record; revision = "block-1"; depth = 0; parent = page_uuid } ]
          ; next_cursor = None
          }))
;;

let observe_graph_revision runtime projection_revision =
  let request = Runtime.start runtime in
  Runtime.receive
    runtime
    (respond
       request
       (Protocol.V2_graph_info_outcome
          { graph_uuid = page_uuid
          ; graph_name = "Journal"
          ; schema = { major = 1; minor = 0 }
          ; admission_facts = []
          ; limits =
              { response_budget_bytes = 4_096
              ; outbox_max_records = 4_096
              ; outbox_max_bytes = 8 * 1_024 * 1_024
              ; change_max_items = 4_096
              ; change_max_bytes = 4 * 1_024 * 1_024
              ; dispatcher_capacity = 32
              ; wire_batch_max_bytes = 4 * 1_024 * 1_024
              }
          ; generation = "generation-1"
          ; projection_revision
          }))
;;

let refresh_private_block_revision runtime revision =
  let request =
    Runtime.submit
      runtime
      (Journal_graph_request.Find_block (Graph.Uuid.to_string block_uuid))
    |> fun output -> only "point block request" output.requests
  in
  ignore
    (Runtime.receive
       runtime
       (respond
          request
          (Protocol.V2_block_outcome (V2_present_block { value = record; revision }))))
;;

let test_worker_read_becomes_normalized_application_feed () =
  let runtime = Runtime.create () in
  let output = seed_visible_block runtime in
  match output.responses with
  | [ { Runtime.payload = Feed_loaded { feed; complete = true; request_generation = 7L }
      ; _
      }
    ] ->
    let day = only "feed day" feed.days in
    let entry = only "feed entry" day.entries in
    Alcotest.(check string)
      "normalized block ID"
      (Graph.Uuid.to_string block_uuid)
      (Journal_model.id entry.block);
    Alcotest.(check string)
      "normalized title"
      "Current title"
      (Journal_model.source entry.block)
  | responses ->
    Alcotest.failf "expected one completed feed response, got %d" (List.length responses)
;;

let test_admission_inspection_preserves_graph_generation () =
  let runtime = Runtime.create () in
  let request =
    Runtime.submit
      runtime
      (Journal_graph_request.Inspect_admission
         { graph_generation = 9; request_generation = 1L })
    |> fun output -> only "admission inspection request" output.requests
  in
  (match request.command with
   | V2_inspect_admission -> ()
   | _ -> Alcotest.fail "admission inspection did not use the Worker protocol command");
  let output =
    Runtime.receive
      runtime
      (respond
         request
         (Protocol.V2_admission_outcome
            { active_records = 3
            ; active_bytes = 1536
            ; protected_wire_bytes = 512
            ; retained_origin_evidence_bytes = 256
            ; maximum_records = 1000
            ; maximum_bytes = 8 * 1024 * 1024
            }))
  in
  match output.responses with
  | [ { Runtime.payload =
          Admission_inspected
            { request = { graph_generation = 9; request_generation = 1L }; observation }
      }
    ] ->
    Alcotest.(check int) "active records" 3 observation.active_records;
    Alcotest.(check int) "active bytes" 1536 observation.active_bytes;
    Alcotest.(check int) "maximum bytes" (8 * 1024 * 1024) observation.maximum_bytes
  | _ -> Alcotest.fail "admission inspection did not retain its graph generation"
;;

let test_application_mutation_uses_target_local_revision () =
  let runtime = Runtime.create () in
  ignore (seed_visible_block runtime);
  refresh_private_block_revision runtime "block-2";
  let output =
    Runtime.submit
      runtime
      (Journal_graph_request.Update_source
         { mutation_id = "a2000000-0000-4000-a000-000000000001"
         ; block_id = Graph.Uuid.to_string block_uuid
         ; expected_revision = "block-1"
         ; source = "Edited locally"
         })
  in
  match output.requests with
  | [ { Protocol.command =
          V2_save_block
            { block
            ; title
            ; preconditions = { blocks = [ (precondition_block, revision) ]; _ }
            ; _
            }
      ; _
      }
    ] ->
    Alcotest.(check string) "save title" "Edited locally" title;
    Alcotest.(check string)
      "save target"
      (Graph.Uuid.to_string block_uuid)
      (Graph.Uuid.to_string block);
    Alcotest.(check string)
      "precondition target"
      (Graph.Uuid.to_string block_uuid)
      (Graph.Uuid.to_string precondition_block);
    Alcotest.(check string) "target-local revision" "block-1" revision
  | _ -> Alcotest.fail "expected one Worker v2 saveBlock request"
;;

let test_unrelated_projection_revision_does_not_reject_status_mutation () =
  let runtime = Runtime.create () in
  ignore (observe_graph_revision runtime "projection-1");
  ignore (seed_visible_block runtime);
  ignore (observe_graph_revision runtime "projection-2");
  let output =
    Runtime.submit
      runtime
      (Journal_graph_request.Set_task_state
         { mutation_id = "a2000000-0000-4000-a000-000000000003"
         ; block_id = Graph.Uuid.to_string block_uuid
         ; expected_revision = "block-1"
         ; task_state = Journal_model.Done
         })
  in
  match output.requests with
  | [ { Protocol.command =
          V2_set_task_status
            { block = target
            ; status = V2_done
            ; preconditions = { blocks = [ (precondition_block, revision) ]; _ }
            ; _
            }
      ; _
      }
    ] ->
    Alcotest.(check string)
      "status target"
      (Graph.Uuid.to_string block_uuid)
      (Graph.Uuid.to_string target);
    Alcotest.(check string)
      "status precondition target"
      (Graph.Uuid.to_string block_uuid)
      (Graph.Uuid.to_string precondition_block);
    Alcotest.(check string) "caller-observed status revision" "block-1" revision
  | _ ->
    Alcotest.fail "unrelated projection revision prevented the status Worker mutation"
;;

let test_status_conflict_refreshes_authoritative_block () =
  let runtime = Runtime.create () in
  ignore (seed_visible_block runtime);
  let mutation =
    Runtime.submit
      runtime
      (Journal_graph_request.Set_task_state
         { mutation_id = "a2000000-0000-4000-a000-000000000006"
         ; block_id = Graph.Uuid.to_string block_uuid
         ; expected_revision = "block-1"
         ; task_state = Journal_model.Done
         })
    |> fun output -> only "status mutation request" output.requests
  in
  let refresh =
    Runtime.receive
      runtime
      (respond
         mutation
         (Protocol.V2_failed
            { code = "conflict"; message = "The mutation precondition did not match." }))
    |> fun output -> only "status conflict refresh" output.requests
  in
  let output =
    Runtime.receive
      runtime
      (respond
         refresh
         (Protocol.V2_page_tree_outcome
            { page = page_uuid
            ; maximum_depth = 1
            ; revision_scope =
                V2_page_tree_revision { page = page_uuid; maximum_depth = 1 }
            ; scope_revision = "tree-scope-2"
            ; items =
                [ { value = record; revision = "block-2"; depth = 0; parent = page_uuid }
                ]
            ; next_cursor = None
            }))
  in
  match output.responses with
  | [ { Runtime.payload = Update_conflict latest } ] ->
    Alcotest.(check string)
      "authoritative conflict revision"
      "block-2"
      (Journal_model.revision latest);
    Alcotest.(check bool)
      "authoritative conflict status"
      true
      (Journal_model.task_state latest = Journal_model.No_status)
  | _ -> Alcotest.fail "status conflict did not return the authoritative block"
;;

let test_delete_uses_caller_observed_block_revision () =
  let runtime = Runtime.create () in
  ignore (seed_visible_block runtime);
  refresh_private_block_revision runtime "block-2";
  let output =
    Runtime.submit
      runtime
      (Journal_graph_request.Delete_subtree
         { mutation_id = "a2000000-0000-4000-a000-000000000004"
         ; block_id = Graph.Uuid.to_string block_uuid
         ; expected_revision = "block-1"
         })
  in
  match output.requests with
  | [ { Protocol.command =
          V2_delete_blocks
            { preconditions =
                { blocks = [ (precondition_block, block_revision) ]
                ; scopes = [ (V2_page_tree_scope _, scope_revision) ]
                ; _
                }
            ; _
            }
      ; _
      }
    ] ->
    Alcotest.(check string)
      "delete precondition target"
      (Graph.Uuid.to_string block_uuid)
      (Graph.Uuid.to_string precondition_block);
    Alcotest.(check string) "caller-observed delete revision" "block-1" block_revision;
    Alcotest.(check string) "retained delete scope" "tree-scope-1" scope_revision
  | _ -> Alcotest.fail "delete did not preserve its block and structure preconditions"
;;

let seed_parent_children_interest runtime =
  let block_request =
    Runtime.submit
      runtime
      (Journal_graph_request.Load_detail
         { block_id = Graph.Uuid.to_string block_uuid
         ; after = None
         ; limit = 4
         ; request_generation = 8L
         })
    |> fun output -> only "detail block request" output.requests
  in
  let children_request =
    Runtime.receive
      runtime
      (respond
         block_request
         (Protocol.V2_block_outcome
            (V2_present_block { value = record; revision = "block-detail-1" })))
    |> fun output -> only "detail children request" output.requests
  in
  ignore
    (Runtime.receive
       runtime
       (respond
          children_request
          (Protocol.V2_children_outcome
             { parent = block_uuid
             ; revision_scope = V2_children_revision block_uuid
             ; scope_revision = "children-scope-1"
             ; items = []
             ; next_cursor = None
             })))
;;

let test_create_child_uses_caller_observed_parent_revision () =
  let runtime = Runtime.create () in
  ignore (seed_visible_block runtime);
  seed_parent_children_interest runtime;
  refresh_private_block_revision runtime "block-detail-2";
  let output =
    Runtime.submit
      runtime
      (Journal_graph_request.Create_child
         { mutation_id = "a2000000-0000-4000-a000-000000000005"
         ; calendar_generation = 1L
         ; block_id = "a2000000-0000-4000-9000-000000000005"
         ; parent_block_id = Graph.Uuid.to_string block_uuid
         ; expected_parent_revision = "block-detail-1"
         ; sibling_order = "a1"
         ; source = "Child"
         ; task_state = Journal_model.No_status
         ; creation_time = capture.creation_time
         })
  in
  match output.requests with
  | [ { Protocol.command =
          V2_insert_blocks
            { parent
            ; preconditions =
                { blocks = [ (precondition_parent, parent_revision) ]
                ; scopes = [ (V2_children_scope scope_parent, scope_revision) ]
                ; _
                }
            ; _
            }
      ; _
      }
    ] ->
    List.iter
      (fun actual ->
         Alcotest.(check string)
           "child parent"
           (Graph.Uuid.to_string block_uuid)
           (Graph.Uuid.to_string actual))
      [ parent; precondition_parent; scope_parent ];
    Alcotest.(check string)
      "caller-observed parent revision"
      "block-detail-1"
      parent_revision;
    Alcotest.(check string) "retained children scope" "children-scope-1" scope_revision
  | _ -> Alcotest.fail "child creation did not preserve parent and scope preconditions"
;;

let capture_present_page runtime request =
  Runtime.receive
    runtime
    (respond
       request
       (Protocol.V2_page_outcome (V2_present_page { page; revision = "page-1" })))
;;

let respond_capture_children runtime request scope_revision =
  Runtime.receive
    runtime
    (respond
       request
       (Protocol.V2_children_outcome
          { parent = page_uuid
          ; revision_scope = V2_children_revision page_uuid
          ; scope_revision
          ; items = [ { value = record; revision = "block-1" } ]
          ; next_cursor = None
          }))
;;

let capture_insert_request_for runtime command =
  let request = capture_page_request_for runtime command in
  capture_present_page runtime request
  |> fun output ->
  only "capture children preflight" output.requests |> respond_capture_children runtime
;;

let capture_insert_request runtime = capture_insert_request_for runtime capture

let test_capture_refreshes_children_revision_before_insert () =
  let runtime = Runtime.create () in
  ignore (seed_visible_block runtime);
  let output = capture_insert_request runtime "tree-scope-2" in
  match output.requests with
  | [ { Protocol.command =
          V2_insert_blocks
            { parent
            ; roots = [ tree ]
            ; preconditions =
                { pages = [ (precondition_page, page_revision) ]
                ; scopes = [ (V2_children_scope scope_page, scope_revision) ]
                ; _
                }
            ; _
            }
      ; _
      }
    ] ->
    Alcotest.(check string)
      "insert parent"
      (Graph.Uuid.to_string page_uuid)
      (Graph.Uuid.to_string parent);
    Alcotest.(check string) "insert title" capture.source tree.title;
    Alcotest.(check string)
      "page precondition"
      (Graph.Uuid.to_string page_uuid)
      (Graph.Uuid.to_string precondition_page);
    Alcotest.(check string) "page revision" "page-1" page_revision;
    Alcotest.(check string)
      "scope page"
      (Graph.Uuid.to_string page_uuid)
      (Graph.Uuid.to_string scope_page);
    Alcotest.(check string) "scope revision" "tree-scope-2" scope_revision
  | _ -> Alcotest.fail "Capture did not refresh the children revision before insertion"
;;

let test_capture_retries_after_revision_conflict () =
  let runtime = Runtime.create () in
  ignore (seed_visible_block runtime);
  let insert =
    capture_insert_request runtime "tree-scope-2"
    |> fun output -> only "first capture insert" output.requests
  in
  let retry_children =
    Runtime.receive
      runtime
      (respond
         insert
         (Protocol.V2_failed
            { code = "conflict"; message = "The mutation precondition did not match." }))
    |> fun output -> only "capture conflict retry" output.requests
  in
  let output = respond_capture_children runtime retry_children "tree-scope-3" in
  match output.requests with
  | [ { Protocol.command =
          V2_insert_blocks
            { mutation_id; preconditions = { scopes = [ (_, scope_revision) ]; _ }; _ }
      ; _
      }
    ] ->
    Alcotest.(check string)
      "same mutation ID"
      capture.mutation_id
      (Graph.Uuid.to_string mutation_id);
    Alcotest.(check string) "refreshed scope revision" "tree-scope-3" scope_revision
  | _ -> Alcotest.fail "Capture did not retry with a refreshed children revision"
;;

let capture_task = { capture with task_state = Journal_model.Todo }

let captured_block : Graph.block =
  { block with
    uuid = uuid capture_task.block_id
  ; title = capture_task.source
  ; order = capture_task.sibling_order
  }
;;

let captured_record : Protocol.v2_block_record =
  { record with block = captured_block; task_status = None }
;;

let committed request =
  respond
    request
    (Protocol.V2_mutation_committed
       { mutation_id = uuid capture_task.mutation_id
       ; status = V2_applied
       ; generation = "generation-1"
       ; before_projection_revision = "projection-1"
       ; after_projection_revision = "projection-2"
       })
;;

let capture_task_block_request runtime =
  let insert =
    capture_insert_request_for runtime capture_task "tree-scope-2"
    |> fun output -> only "capture task insert" output.requests
  in
  Runtime.receive runtime (committed insert)
  |> fun output -> only "captured task block read" output.requests
;;

let test_capture_task_reads_inserted_block_revision_before_status () =
  let runtime = Runtime.create () in
  ignore (seed_visible_block runtime);
  let block_request = capture_task_block_request runtime in
  (match block_request.command with
   | V2_get_block { block; revision = None } ->
     Alcotest.(check string)
       "captured block read target"
       capture_task.block_id
       (Graph.Uuid.to_string block)
   | _ -> Alcotest.fail "captured task did not read its inserted block");
  let output =
    Runtime.receive
      runtime
      (respond
         block_request
         (Protocol.V2_block_outcome
            (V2_present_block { value = captured_record; revision = "captured-block-1" })))
  in
  match output.requests with
  | [ { Protocol.command =
          V2_set_task_status
            { block
            ; status = V2_todo
            ; preconditions = { blocks = [ (precondition_block, revision) ]; _ }
            ; _
            }
      ; _
      }
    ] ->
    Alcotest.(check string)
      "status target"
      capture_task.block_id
      (Graph.Uuid.to_string block);
    Alcotest.(check string)
      "status precondition target"
      capture_task.block_id
      (Graph.Uuid.to_string precondition_block);
    Alcotest.(check string) "captured block revision" "captured-block-1" revision
  | _ -> Alcotest.fail "captured task did not use its retained block revision"
;;

let test_capture_task_fails_closed_when_inserted_block_is_missing () =
  let runtime = Runtime.create () in
  ignore (seed_visible_block runtime);
  let block_request = capture_task_block_request runtime in
  let output =
    Runtime.receive
      runtime
      (respond
         block_request
         (Protocol.V2_block_outcome
            (V2_missing_block { uuid = captured_block.uuid; revision = "missing-block-1" })))
  in
  Alcotest.(check int) "no status mutation" 0 (List.length output.requests);
  match output.responses with
  | [ { Runtime.payload = Rejected (Projection_failure message); _ } ] ->
    Alcotest.(check string)
      "missing captured block"
      "The captured block is unavailable."
      message
  | _ -> Alcotest.fail "missing captured block did not fail closed"
;;

let test_stale_calendar_generation_rejects_capture_before_worker_io () =
  let runtime = Runtime.create () in
  let sampler =
    Journal_calendar.Sampler.create
      ~clock:(fun () -> 1_788_192_000.)
      ~localtime:Unix.gmtime
      ()
  in
  ignore (Journal_calendar.Sampler.sample sampler |> Result.get_ok);
  let current = Journal_calendar.Sampler.sample sampler |> Result.get_ok in
  Runtime.set_calendar runtime current;
  let output =
    Runtime.submit
      runtime
      (Journal_graph_request.Capture { calendar_generation = 0L; command = capture })
  in
  Alcotest.(check int) "no stale worker request" 0 (List.length output.requests);
  match output.responses with
  | [ { Runtime.payload = Rejected (Projection_failure message); _ } ] ->
    Alcotest.(check string)
      "stale calendar rejection"
      "The local calendar changed before capture admission."
      message
  | _ -> Alcotest.fail "stale calendar generation did not reject capture"
;;

let test_uninterested_change_is_acknowledged_without_hydration () =
  let runtime = Runtime.create () in
  ignore (seed_visible_block runtime);
  let pull =
    Runtime.reconcile_push
      runtime
      ~request_generation:11L
      (Protocol.V2_changes_available
         { api_version = Protocol.api_version
         ; generation = "generation-1"
         ; through = "revision-2"
         })
    |> fun output -> only "pull request" output.requests
  in
  let unrelated = uuid "a2000000-0000-4000-9000-000000000099" in
  let output =
    Runtime.receive
      runtime
      (respond
         pull
         (Protocol.V2_changes
            { generation = "generation-1"
            ; from_exclusive = None
            ; through = "revision-2"
            ; windows =
                [ { id = "change-1"
                  ; predecessor = "revision-1"
                  ; successor = "revision-2"
                  ; block_uuids = [ unrelated ]
                  ; page_uuids = []
                  ; structure_interests = []
                  }
                ]
            ; next = None
            }))
  in
  match output.requests with
  | [ { Protocol.command = V2_ack_changes { through = "revision-2"; _ }; _ } ] -> ()
  | _ -> Alcotest.fail "uninterested change must only produce an acknowledgement"
;;

let () =
  Alcotest.run
    "Worker application integration"
    [ ( "v2 boundary"
      , [ Alcotest.test_case
            "read response becomes normalized feed"
            `Quick
            test_worker_read_becomes_normalized_application_feed
        ; Alcotest.test_case
            "admission inspection preserves graph generation"
            `Quick
            test_admission_inspection_preserves_graph_generation
        ; Alcotest.test_case
            "mutation uses target-local revision"
            `Quick
            test_application_mutation_uses_target_local_revision
        ; Alcotest.test_case
            "unrelated projection does not reject status mutation"
            `Quick
            test_unrelated_projection_revision_does_not_reject_status_mutation
        ; Alcotest.test_case
            "status conflict refreshes authoritative block"
            `Quick
            test_status_conflict_refreshes_authoritative_block
        ; Alcotest.test_case
            "delete uses caller-observed block revision"
            `Quick
            test_delete_uses_caller_observed_block_revision
        ; Alcotest.test_case
            "child creation uses caller-observed parent revision"
            `Quick
            test_create_child_uses_caller_observed_parent_revision
        ; Alcotest.test_case
            "Capture refreshes children revision"
            `Quick
            test_capture_refreshes_children_revision_before_insert
        ; Alcotest.test_case
            "Capture retries revision conflicts"
            `Quick
            test_capture_retries_after_revision_conflict
        ; Alcotest.test_case
            "Capture task retains inserted block revision"
            `Quick
            test_capture_task_reads_inserted_block_revision_before_status
        ; Alcotest.test_case
            "Capture task rejects a missing inserted block"
            `Quick
            test_capture_task_fails_closed_when_inserted_block_is_missing
        ; Alcotest.test_case
            "stale calendar generation rejects Capture"
            `Quick
            test_stale_calendar_generation_rejects_capture_before_worker_io
        ; Alcotest.test_case
            "uninterested change does not hydrate"
            `Quick
            test_uninterested_change_is_acknowledged_without_hydration
        ] )
    ]
;;
