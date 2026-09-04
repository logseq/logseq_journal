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
        ~time_zone_id:"UTC"
        ~utc_offset_seconds:0
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
  Runtime.set_calendar
    runtime
    { Journal_calendar.instant_unix_ms = 1_788_192_000_000L
    ; local_day = 20260901
    ; local_minute_of_day = 0
    ; locale = "en_US"
    ; time_zone_id = "UTC"
    ; utc_offset_seconds = 0
    ; generation = 1L
    ; lifecycle_generation = 0L
    }
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
            { revision_scope = V2_journal_index_revision
            ; scope_revision = "journal-scope-1"
            ; items = [ { page; journal_day = 20260901; revision = "page-1" } ]
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

let test_application_mutation_uses_target_local_revision () =
  let runtime = Runtime.create () in
  ignore (seed_visible_block runtime);
  let output =
    Runtime.submit
      runtime
      (Journal_graph_request.Update_source
         { mutation_id = "a2000000-0000-4000-a000-000000000001"
         ; block_id = Graph.Uuid.to_string block_uuid
         ; expected_revision = 1
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
            "mutation uses target-local revision"
            `Quick
            test_application_mutation_uses_target_local_revision
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
            "uninterested change does not hydrate"
            `Quick
            test_uninterested_change_is_acknowledged_without_hydration
        ] )
    ]
;;
