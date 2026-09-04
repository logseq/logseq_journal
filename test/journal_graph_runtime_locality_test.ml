module Graph = Logseq_db_types.Graph_types
module Protocol = Logseq_db_worker.Protocol
module Runtime = Journal_graph_runtime

let uuid value = Graph.Uuid.of_string value |> Result.get_ok

let only description = function
  | [ value ] -> value
  | values ->
    Alcotest.failf "%s: expected one value, got %d" description (List.length values)
;;

let request_id (request : Protocol.request) = request.request_id

let response request outcome =
  Protocol.V2_response
    { api_version = Protocol.api_version; request_id = request_id request; outcome }
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

let page_uuid = uuid "a1000000-0000-4000-8000-000000000001"
let block_uuid = uuid "a1000000-0000-4000-9000-000000000001"
let unrelated_uuid = uuid "a1000000-0000-4000-9000-000000000099"

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
  ; title = "Retained block"
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

let load_feed runtime =
  Runtime.submit
    runtime
    (Journal_graph_request.Load_feed
       { before_day = None
       ; day_limit = 3
       ; blocks_per_day = 4
       ; slot_limit = 16
       ; request_generation = 7L
       })
  |> fun output -> only "initial journal request" output.requests
;;

let seed_feed runtime =
  set_calendar runtime;
  let journals = load_feed runtime in
  let tree =
    Runtime.receive
      runtime
      (response
         journals
         (Protocol.V2_journals_outcome
            { revision_scope = V2_journal_index_revision
            ; scope_revision = "scope-journal-1"
            ; items = [ { page; journal_day = 20260901; revision = "page-1" } ]
            ; next_cursor = None
            }))
    |> fun output -> only "initial page-tree request" output.requests
  in
  ignore
    (Runtime.receive
       runtime
       (response
          tree
          (Protocol.V2_page_tree_outcome
             { page = page_uuid
             ; maximum_depth = 1
             ; revision_scope =
                 V2_page_tree_revision { page = page_uuid; maximum_depth = 1 }
             ; scope_revision = "scope-tree-1"
             ; items =
                 [ { value = record; revision = "block-1"; depth = 0; parent = page_uuid }
                 ]
             ; next_cursor = None
             })));
  ()
;;

let pull runtime =
  Runtime.reconcile_push
    runtime
    ~request_generation:11L
    (Protocol.V2_changes_available
       { api_version = Protocol.api_version
       ; generation = "generation-1"
       ; through = "revision-2"
       })
  |> fun output -> only "change pull" output.requests
;;

let changed runtime window =
  let request = pull runtime in
  Runtime.receive
    runtime
    (response
       request
       (Protocol.V2_changes
          { generation = "generation-1"
          ; from_exclusive = Some "revision-1"
          ; through = "revision-2"
          ; windows = [ window ]
          ; next = None
          }))
;;

let window ?(blocks = []) ?(pages = []) ?(scopes = []) () : Protocol.v2_change_window =
  { id = "change-1"
  ; predecessor = "revision-1"
  ; successor = "revision-2"
  ; block_uuids = blocks
  ; page_uuids = pages
  ; structure_interests = scopes
  }
;;

let hydration_requests output =
  List.filter
    (fun (request : Protocol.request) ->
       match request.command with
       | V2_ack_changes _ -> false
       | _ -> true)
    output.Runtime.requests
;;

let require_ack output =
  Alcotest.(check int)
    "one acknowledgement"
    1
    (List.fold_left
       (fun count (request : Protocol.request) ->
          match request.command with
          | V2_ack_changes _ -> count + 1
          | _ -> count)
       0
       output.Runtime.requests)
;;

let test_worker_generation_change_restarts_pull_without_cursor () =
  let runtime = Runtime.create () in
  let first_pull = pull runtime in
  ignore
    (Runtime.receive
       runtime
       (response
          first_pull
          (Protocol.V2_changes
             { generation = "generation-1"
             ; from_exclusive = None
             ; through = "revision-2"
             ; windows = []
             ; next = None
             })));
  let restarted =
    Runtime.reconcile_push
      runtime
      ~request_generation:12L
      (Protocol.V2_changes_available
         { api_version = Protocol.api_version
         ; generation = "generation-2"
         ; through = "revision-3"
         })
    |> fun output -> only "generation-change pull" output.requests
  in
  match restarted.command with
  | V2_pull_changes { generation = "generation-2"; after = None; _ } -> ()
  | V2_pull_changes _ ->
    Alcotest.fail "Worker generation change retained an old continuation"
  | _ -> Alcotest.fail "Worker generation change did not restart the change pull"
;;

let test_uninterested_change_does_not_hydrate () =
  let runtime = Runtime.create () in
  let output = changed runtime (window ~blocks:[ unrelated_uuid ] ()) in
  require_ack output;
  Alcotest.(check int)
    "uninterested hydration request count"
    0
    (List.length (hydration_requests output))
;;

let test_one_block_change_hydrates_only_that_block () =
  let runtime = Runtime.create () in
  seed_feed runtime;
  let output = changed runtime (window ~blocks:[ block_uuid; unrelated_uuid ] ()) in
  require_ack output;
  match hydration_requests output with
  | [ { Protocol.command = V2_get_block { block; _ }; _ } ] ->
    Alcotest.(check string)
      "hydrated block"
      (Graph.Uuid.to_string block_uuid)
      (Graph.Uuid.to_string block)
  | requests ->
    Alcotest.failf
      "expected one point-block hydration, got %d requests"
      (List.length requests)
;;

let test_one_block_hydration_emits_only_changed_fragment () =
  let runtime = Runtime.create () in
  seed_feed runtime;
  let changed_output = changed runtime (window ~blocks:[ block_uuid ] ()) in
  let hydration = only "point hydration" (hydration_requests changed_output) in
  let updated_record =
    { record with block = { block with title = "Changed remotely" } }
  in
  let output =
    Runtime.receive
      runtime
      (response
         hydration
         (Protocol.V2_block_outcome
            (V2_present_block { value = updated_record; revision = "block-2" })))
  in
  Alcotest.(check int) "no follow-up hydration" 0 (List.length output.requests);
  match output.responses with
  | [ { Runtime.payload = Block_updated { block; timeline_entry_update = None }; _ } ] ->
    Alcotest.(check string)
      "updated block ID"
      (Graph.Uuid.to_string block_uuid)
      (Journal_model.id block);
    Alcotest.(check string)
      "updated source"
      "Changed remotely"
      (Journal_model.source block)
  | responses ->
    Alcotest.failf
      "expected one normalized block fragment, got %d responses"
      (List.length responses)
;;

let test_journal_interest_refetches_only_journal_query () =
  let runtime = Runtime.create () in
  ignore (load_feed runtime);
  let output =
    changed runtime (window ~scopes:[ Protocol.V2_journal_index_interest ] ())
  in
  require_ack output;
  match hydration_requests output with
  | [ { Protocol.command = V2_list_journals _; _ } ] -> ()
  | requests ->
    Alcotest.failf
      "expected only the registered journal query, got %d requests"
      (List.length requests)
;;

let test_page_tree_interest_refetches_only_matching_tree () =
  let runtime = Runtime.create () in
  seed_feed runtime;
  let output =
    changed runtime (window ~scopes:[ Protocol.V2_page_tree_interest page_uuid ] ())
  in
  require_ack output;
  match hydration_requests output with
  | [ { Protocol.command = V2_get_page_tree { page; maximum_depth = 1; _ }; _ } ] ->
    Alcotest.(check string)
      "hydrated page tree"
      (Graph.Uuid.to_string page_uuid)
      (Graph.Uuid.to_string page)
  | requests ->
    Alcotest.failf
      "expected only the matching page-tree query, got %d requests"
      (List.length requests)
;;

let seed_children_interest runtime =
  seed_feed runtime;
  let block_request =
    Runtime.submit
      runtime
      (Journal_graph_request.Load_detail
         { block_id = Graph.Uuid.to_string block_uuid
         ; after = None
         ; limit = 3
         ; request_generation = 9L
         })
    |> fun output -> only "detail block request" output.requests
  in
  let children_request =
    Runtime.receive
      runtime
      (response
         block_request
         (Protocol.V2_block_outcome
            (V2_present_block { value = record; revision = "block-detail-1" })))
    |> fun output -> only "detail children request" output.requests
  in
  ignore
    (Runtime.receive
       runtime
       (response
          children_request
          (Protocol.V2_children_outcome
             { parent = block_uuid
             ; revision_scope = V2_children_revision block_uuid
             ; scope_revision = "scope-children-1"
             ; items = []
             ; next_cursor = None
             })));
  ()
;;

let test_children_interest_refetches_only_matching_children () =
  let runtime = Runtime.create () in
  seed_children_interest runtime;
  let output =
    changed runtime (window ~scopes:[ Protocol.V2_children_interest block_uuid ] ())
  in
  require_ack output;
  match hydration_requests output with
  | [ { Protocol.command = V2_get_children { parent; limit = 3; _ }; _ } ] ->
    Alcotest.(check string)
      "hydrated children parent"
      (Graph.Uuid.to_string block_uuid)
      (Graph.Uuid.to_string parent)
  | requests ->
    Alcotest.failf
      "expected only the matching children query, got %d requests"
      (List.length requests)
;;

let test_resync_rehydrates_graph_and_registered_journal_interest () =
  let runtime = Runtime.create () in
  ignore (load_feed runtime);
  let output =
    Runtime.reconcile_push
      runtime
      ~request_generation:12L
      (Protocol.V2_resync_required_push
         { api_version = Protocol.api_version
         ; generation = "generation-2"
         ; reason = "retention overflow"
         })
  in
  let graph_info, journals =
    List.fold_left
      (fun (graph_info, journals) (request : Protocol.request) ->
         match request.command with
         | V2_graph_info -> graph_info + 1, journals
         | V2_list_journals _ -> graph_info, journals + 1
         | _ -> Alcotest.fail "resync issued a request outside the registered interests")
      (0, 0)
      output.requests
  in
  Alcotest.(check int) "graph-info rehydration" 1 graph_info;
  Alcotest.(check int) "journal-interest rehydration" 1 journals
;;

let test_resync_rehydrates_all_registered_structure_interests () =
  let runtime = Runtime.create () in
  seed_children_interest runtime;
  let output =
    Runtime.reconcile_push
      runtime
      ~request_generation:13L
      (Protocol.V2_resync_required_push
         { api_version = Protocol.api_version
         ; generation = "generation-3"
         ; reason = "retention overflow"
         })
  in
  let graph_info, journals, trees, children =
    List.fold_left
      (fun (graph_info, journals, trees, children) (request : Protocol.request) ->
         match request.command with
         | V2_graph_info -> graph_info + 1, journals, trees, children
         | V2_list_journals _ -> graph_info, journals + 1, trees, children
         | V2_get_page_tree _ -> graph_info, journals, trees + 1, children
         | V2_get_children _ -> graph_info, journals, trees, children + 1
         | _ -> Alcotest.fail "resync issued an unregistered query")
      (0, 0, 0, 0)
      output.requests
  in
  Alcotest.(check int) "graph-info rehydration" 1 graph_info;
  Alcotest.(check int) "journal rehydration" 1 journals;
  Alcotest.(check int) "page-tree rehydration" 1 trees;
  Alcotest.(check int) "children rehydration" 1 children
;;

let () =
  Alcotest.run
    "journal graph runtime locality"
    [ ( "changes"
      , [ Alcotest.test_case
            "Worker generation change restarts pull without a cursor"
            `Quick
            test_worker_generation_change_restarts_pull_without_cursor
        ; Alcotest.test_case
            "uninterested UUID does not hydrate"
            `Quick
            test_uninterested_change_does_not_hydrate
        ; Alcotest.test_case
            "one-block intersection hydrates one block"
            `Quick
            test_one_block_change_hydrates_only_that_block
        ; Alcotest.test_case
            "one-block hydration replaces one fragment"
            `Quick
            test_one_block_hydration_emits_only_changed_fragment
        ; Alcotest.test_case
            "journal interest refetches journal query"
            `Quick
            test_journal_interest_refetches_only_journal_query
        ; Alcotest.test_case
            "page-tree interest refetches matching tree"
            `Quick
            test_page_tree_interest_refetches_only_matching_tree
        ; Alcotest.test_case
            "children interest refetches matching children"
            `Quick
            test_children_interest_refetches_only_matching_children
        ; Alcotest.test_case
            "resync rehydrates current interests"
            `Quick
            test_resync_rehydrates_graph_and_registered_journal_interest
        ; Alcotest.test_case
            "resync rehydrates every structure interest"
            `Quick
            test_resync_rehydrates_all_registered_structure_interests
        ] )
    ]
;;
