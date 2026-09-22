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
            { items = [ { page; journal_day = 20260901; revision = "page-1" } ]
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

let seed_large_feed runtime =
  set_calendar runtime;
  let records =
    List.init 48 (fun index ->
      { record with
        block =
          { block with
            uuid = uuid (Printf.sprintf "a1000000-0000-4000-9000-%012d" (index + 100))
          ; order = Printf.sprintf "a0U%06dU" index
          }
      })
  in
  let request =
    Runtime.submit
      runtime
      (Journal_graph_request.Load_feed
         { before_day = None
         ; day_limit = 1
         ; blocks_per_day = 64
         ; slot_limit = 128
         ; request_generation = 1L
         })
    |> fun output -> only "large feed" output.requests
  in
  let tree =
    Runtime.receive
      runtime
      (response
         request
         (Protocol.V2_journals_outcome
            { items = [ { page; journal_day = 20260901; revision = "page-1" } ]
            ; next_cursor = None
            }))
    |> fun output -> only "large feed tree" output.requests
  in
  let items =
    List.map
      (fun value ->
         Protocol.{ value; revision = "block-1"; depth = 0; parent = page_uuid })
      records
  in
  ignore
    (Runtime.receive
       runtime
       (response
          tree
          (Protocol.V2_page_tree_outcome
             { page = page_uuid; maximum_depth = 1; items; next_cursor = None })));
  records, items
;;

let consume_ack runtime output =
  List.filter
    (fun (request : Protocol.request) ->
       match request.command with
       | V2_ack_changes { generation; through } ->
         let ack =
           Runtime.receive
             runtime
             (response request (Protocol.V2_changes_acknowledged { generation; through }))
         in
         Alcotest.(check int)
           "ack does not exceed the full hydration window"
           0
           (List.length ack.requests);
         false
       | _ -> true)
    output.Runtime.requests
;;

let check_hydration_bound outstanding =
  if List.length outstanding > 4
  then
    Alcotest.failf
      "background burst has %d outstanding reads (maximum 4)"
      (List.length outstanding)
;;

let test_large_changes_are_bounded fail_one =
  let runtime = Runtime.create () in
  let records, _ = seed_large_feed runtime in
  let first, later =
    List.partition
      (fun (r : Protocol.v2_block_record) ->
         String.compare
           (Graph.Uuid.to_string r.block.uuid)
           "a1000000-0000-4000-9000-000000000140"
         < 0)
      records
  in
  let ids records =
    List.map (fun (r : Protocol.v2_block_record) -> r.block.uuid) records
  in
  let first_output = changed runtime (window ~blocks:(ids first) ()) in
  let outstanding = consume_ack runtime first_output in
  check_hydration_bound outstanding;
  let next_pull = pull runtime in
  let later_output =
    Runtime.receive
      runtime
      (response
         next_pull
         (Protocol.V2_changes
            { generation = "generation-1"
            ; from_exclusive = Some "revision-2"
            ; through = "revision-3"
            ; next = None
            ; windows =
                [ { (window ~blocks:(ids later) ()) with
                    id = "change-2"
                  ; predecessor = "revision-2"
                  ; successor = "revision-3"
                  }
                ]
            }))
  in
  let outstanding = outstanding @ consume_ack runtime later_output in
  check_hydration_bound outstanding;
  let foreground =
    Runtime.submit
      runtime
      (Journal_graph_request.Find_block (Graph.Uuid.to_string unrelated_uuid))
  in
  let foreground =
    only "foreground read bypasses background backlog" foreground.requests
  in
  let foreground_output =
    Runtime.receive
      runtime
      (response
         foreground
         (Protocol.V2_block_outcome
            (V2_missing_block { uuid = unrelated_uuid; revision = "missing" })))
  in
  Alcotest.(check int)
    "foreground completion does not expand background window"
    0
    (List.length foreground_output.requests);
  let rec drain seen removed failures = function
    | [] ->
      Alcotest.(check (list string))
        "every changed identity hydrated once"
        (List.sort String.compare (List.map Graph.Uuid.to_string (ids records)))
        (List.sort String.compare seen);
      Alcotest.(check int)
        "all missing blocks published"
        (if fail_one then 47 else 48)
        removed;
      Alcotest.(check int) "read failure preserved" (if fail_one then 1 else 0) failures
    | (request : Protocol.request) :: rest ->
      let id =
        match request.command with
        | V2_get_block { block; _ } -> block
        | _ -> Alcotest.fail "unexpected background request"
      in
      let outcome =
        if fail_one && List.length seen = 6
        then Protocol.V2_failed { code = "invalidRequest"; message = "Read unavailable" }
        else
          Protocol.V2_block_outcome (V2_missing_block { uuid = id; revision = "removed" })
      in
      let output = Runtime.receive runtime (response request outcome) in
      let duplicate = Runtime.receive runtime (response request outcome) in
      Alcotest.(check int)
        "duplicate completion does not dispatch"
        0
        (List.length duplicate.requests);
      Alcotest.(check int)
        "duplicate completion does not publish"
        0
        (List.length duplicate.responses);
      let removed, failures =
        List.fold_left
          (fun (removed, failures) result ->
             match result.Runtime.payload with
             | Block_removed { block_id } ->
               Alcotest.(check string)
                 "removed identity"
                 (Graph.Uuid.to_string id)
                 block_id;
               removed + 1, failures
             | Rejected (Worker_failure failure) ->
               Alcotest.(check string)
                 "failure message"
                 "Read unavailable"
                 (Logseq_db_worker.Error.message failure.error);
               removed, failures + 1
             | _ -> Alcotest.fail "unexpected hydration projection")
          (removed, failures)
          output.responses
      in
      let outstanding = rest @ output.requests in
      check_hydration_bound outstanding;
      drain (Graph.Uuid.to_string id :: seen) removed failures outstanding
  in
  drain [] 0 0 outstanding
;;

let test_reset_discards_background_backlog () =
  let runtime = Runtime.create () in
  let records, _ = seed_large_feed runtime in
  let output =
    changed
      runtime
      (window
         ~blocks:(List.map (fun (r : Protocol.v2_block_record) -> r.block.uuid) records)
         ())
  in
  let issued = consume_ack runtime output in
  check_hydration_bound issued;
  Runtime.reset runtime;
  List.iter
    (fun (request : Protocol.request) ->
       let output =
         Runtime.receive
           runtime
           (response
              request
              (Protocol.V2_failed { code = "invalidRequest"; message = "Old graph" }))
       in
       Alcotest.(check int)
         "old graph does not dispatch backlog"
         0
         (List.length output.requests);
       Alcotest.(check int) "old graph does not publish" 0 (List.length output.responses))
    issued;
  seed_feed runtime;
  let next = changed runtime (window ~blocks:[ block_uuid ] ()) in
  Alcotest.(check int)
    "new graph hydrates only its own identity"
    1
    (List.length (hydration_requests next))
;;

let test_resync_and_dependent_reads_share_hydration_bound () =
  let runtime = Runtime.create () in
  let records, items = seed_large_feed runtime in
  List.iter
    (fun (value : Protocol.v2_block_record) ->
       let request =
         Runtime.submit
           runtime
           (Journal_graph_request.Load_detail
              { block_id = Graph.Uuid.to_string value.block.uuid
              ; limit = 3
              ; after = None
              ; request_generation = 2L
              })
         |> fun output -> only "register detail" output.requests
       in
       let request =
         Runtime.receive
           runtime
           (response
              request
              (Protocol.V2_block_outcome
                 (V2_present_block { value; revision = "block-1" })))
         |> fun output -> only "register children" output.requests
       in
       ignore
         (Runtime.receive
            runtime
            (response
               request
               (Protocol.V2_children_outcome
                  { parent = value.block.uuid
                  ; revision_scope = V2_children_revision value.block.uuid
                  ; scope_revision = "children-1"
                  ; items = []
                  ; next_cursor = None
                  }))))
    records;
  let output =
    Runtime.reconcile_push
      runtime
      ~request_generation:3L
      (Protocol.V2_resync_required_push
         { api_version = Protocol.api_version
         ; generation = "generation-2"
         ; reason = "overflow"
         })
  in
  check_hydration_bound output.requests;
  let counts = Hashtbl.create 4 in
  let rec drain = function
    | [] -> ()
    | (request : Protocol.request) :: rest ->
      let kind, outcome =
        match request.command with
        | V2_graph_info ->
          ( "graph"
          , Protocol.V2_failed
              { code = "invalidRequest"; message = "Inspection unavailable" } )
        | V2_list_journals _ ->
          ( "journal"
          , Protocol.V2_journals_outcome
              { items = [ { page; journal_day = 20260901; revision = "page-2" } ]
              ; next_cursor = None
              } )
        | V2_get_page_tree _ ->
          ( "tree"
          , Protocol.V2_page_tree_outcome
              { page = page_uuid; maximum_depth = 1; items; next_cursor = None } )
        | V2_get_children { parent; _ } ->
          ( "children"
          , Protocol.V2_children_outcome
              { parent
              ; revision_scope = V2_children_revision parent
              ; scope_revision = "children-2"
              ; items = []
              ; next_cursor = None
              } )
        | _ -> Alcotest.fail "resync request outside retained interests"
      in
      Hashtbl.replace
        counts
        kind
        (1 + Option.value ~default:0 (Hashtbl.find_opt counts kind));
      let result = Runtime.receive runtime (response request outcome) in
      let outstanding = rest @ result.requests in
      check_hydration_bound outstanding;
      drain outstanding
  in
  drain output.requests;
  List.iter
    (fun (kind, expected) ->
       Alcotest.(check int)
         kind
         expected
         (Option.value ~default:0 (Hashtbl.find_opt counts kind)))
    [ "graph", 1; "journal", 1; "tree", 2; "children", 48 ]
;;

let test_queued_resync_announces_feed_refresh () =
  let runtime = Runtime.create () in
  let records, _ = seed_large_feed runtime in
  ignore
    (changed
       runtime
       (window
          ~blocks:(List.map (fun (r : Protocol.v2_block_record) -> r.block.uuid) records)
          ()));
  let output =
    Runtime.reconcile_push
      runtime
      ~request_generation:20L
      (Protocol.V2_resync_required_push
         { api_version = Protocol.api_version
         ; generation = "generation-2"
         ; reason = "overflow"
         })
  in
  Alcotest.(check int)
    "resync requests wait for background capacity"
    0
    (List.length output.requests);
  Alcotest.(check int)
    "refresh ownership is announced before queued reads"
    2
    (List.length output.responses);
  Alcotest.(check bool)
    "queued refresh retains its request generation"
    true
    (List.exists
       (fun result ->
          match result.Runtime.payload with
          | Feed_refresh_started { request_generation = 20L } -> true
          | _ -> false)
       output.responses)
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

let test_read_failure_conversion_preserves_category_and_ownership () =
  List.iter
    (fun code ->
       let runtime = Runtime.create () in
       seed_feed runtime;
       let request =
         Runtime.submit
           runtime
           (Journal_graph_request.Load_day_blocks
              { day = 20260901; after = None; limit = 64; request_generation = 23L })
         |> fun output -> only "day read" output.requests
       in
       let output =
         Runtime.receive
           runtime
           (response
              request
              (Protocol.V2_failed
                 { code = Logseq_db_worker.Error.code_string code
                 ; message = "Read diagnostic"
                 }))
       in
       match (only "day failure" output.responses).payload with
       | Runtime.Day_blocks_failed
           { day; request_generation; stale_cursor; failure = Worker_failure failure } ->
         Alcotest.(check int) "day ownership" 20260901 day;
         Alcotest.(check int64) "request ownership" 23L request_generation;
         Alcotest.(check bool)
           "stale category"
           (code = Logseq_db_worker.Error.Stale_read_cursor)
           stale_cursor;
         Alcotest.(check string)
           "original code"
           (Logseq_db_worker.Error.code_string code)
           (Logseq_db_worker.Error.code_string
              (Logseq_db_worker.Error.code failure.error));
         Alcotest.(check string)
           "original message"
           "Read diagnostic"
           (Logseq_db_worker.Error.message failure.error)
       | _ -> Alcotest.fail "read failure was routed as a mutation rejection")
    Logseq_db_worker.Error.
      [ Stale_read_cursor
      ; Invalid_request
      ; Closed_session
      ; Response_too_large
      ; Corrupt_storage
      ]
;;

let test_older_feed_uses_calendar_upper_bound () =
  List.iter
    (fun (before_day, expected) ->
       let runtime = Runtime.create () in
       set_calendar runtime;
       let output =
         Runtime.submit
           runtime
           (Journal_graph_request.Load_feed
              { before_day = Some before_day
              ; day_limit = 3
              ; blocks_per_day = 4
              ; slot_limit = 16
              ; request_generation = 7L
              })
       in
       let request = only "older journal request" output.requests in
       match request.command with
       | Protocol.V2_list_journals { from_day; through_day; _ } ->
         Alcotest.(check int) "unbounded lower date" 0 from_day;
         Alcotest.(check int) "exclusive calendar upper date" expected through_day
       | _ -> Alcotest.fail "older feed did not request journals")
    [ 20260907, 20260906
    ; 20260301, 20260228
    ; 20240301, 20240229
    ; 20260101, 20251231
    ; 10101, 0
    ]
;;

let test_detail_resolves_unretained_page () =
  let runtime = Runtime.create () in
  set_calendar runtime;
  let read =
    Runtime.submit
      runtime
      (Journal_graph_request.Load_detail
         { block_id = Graph.Uuid.to_string block_uuid
         ; after = None
         ; limit = 32
         ; request_generation = 91L
         })
    |> fun output -> only "detail root read" output.requests
  in
  let output =
    Runtime.receive
      runtime
      (response
         read
         (Protocol.V2_block_outcome
            (V2_present_block { value = record; revision = "block-1" })))
  in
  let read = only "unretained owning-page read" output.requests in
  (match read.command with
   | Protocol.V2_get_page { page; _ } when Graph.Uuid.equal page page_uuid -> ()
   | _ -> Alcotest.fail "detail did not resolve the actual owning page");
  let ordinary_page =
    { page with kind = Ordinary_page; name = "reference"; title = "Reference" }
  in
  let output =
    Runtime.receive
      runtime
      (response
         read
         (Protocol.V2_page_outcome
            (V2_present_page { page = ordinary_page; revision = "ordinary-page-1" })))
  in
  let children = only "ordinary page direct children" output.requests in
  let output =
    Runtime.receive
      runtime
      (response
         children
         (Protocol.V2_children_outcome
            { parent = block_uuid
            ; revision_scope = V2_children_revision block_uuid
            ; scope_revision = "children-1"
            ; items = []
            ; next_cursor = None
            }))
  in
  match (only "ordinary detail completion" output.responses).payload with
  | Runtime.Detail_loaded { request_generation = 91L; detail } ->
    Alcotest.(check (option int))
      "ordinary page does not fabricate a journal date"
      None
      (Journal_model.journal_day_opt detail.root)
  | _ -> Alcotest.fail "ordinary page detail did not load"
;;

let test_detail_forwards_child_cursor () =
  let runtime = Runtime.create () in
  seed_feed runtime;
  let cursor = Graph.Cursor.of_string "detail-next-page" |> Result.get_ok in
  let after : Journal_graph_projection.block_cursor =
    { after_sibling_order = "m"
    ; after_block_id = Graph.Uuid.to_string unrelated_uuid
    ; protocol_cursor = Some cursor
    }
  in
  let read =
    Runtime.submit
      runtime
      (Journal_graph_request.Load_detail
         { block_id = Graph.Uuid.to_string block_uuid
         ; after = Some after
         ; limit = 32
         ; request_generation = 92L
         })
    |> fun output -> only "continuation root read" output.requests
  in
  let output =
    Runtime.receive
      runtime
      (response
         read
         (Protocol.V2_block_outcome
            (V2_present_block { value = record; revision = "block-1" })))
  in
  let read = only "continuation child read" output.requests in
  match read.command with
  | Protocol.V2_get_children { cursor = Some actual; _ } when actual = cursor -> ()
  | _ -> Alcotest.fail "detail discarded the child continuation cursor"
;;

let test_status_failure_conversion () =
  List.iter
    (fun code ->
       let runtime = Runtime.create () in
       seed_feed runtime;
       let request =
         Runtime.submit
           runtime
           (Journal_graph_request.Set_task_state
              { mutation_id = "a1000000-0000-4000-a000-000000000001"
              ; block_id = Graph.Uuid.to_string block_uuid
              ; expected_revision = "block-1"
              ; task_state = Journal_model.Todo
              })
         |> fun output -> only "status mutation" output.requests
       in
       let output =
         Runtime.receive
           runtime
           (response
              request
              (Protocol.V2_failed
                 { code = Logseq_db_worker.Error.code_string code
                 ; message = "Status write diagnostic"
                 }))
       in
       if code = Logseq_db_worker.Error.Conflict
       then (
         Alcotest.(check int)
           "conflict waits for authoritative data"
           0
           (List.length output.responses);
         match (only "conflict refresh" output.requests).command with
         | Protocol.V2_get_page_tree { page; _ } ->
           Alcotest.(check string)
             "conflicted page"
             (Graph.Uuid.to_string page_uuid)
             (Graph.Uuid.to_string page)
         | _ -> Alcotest.fail "Conflict did not refresh its page tree")
       else (
         Alcotest.(check int)
           "non-conflict does not refresh as a conflict"
           0
           (List.length output.requests);
         match (only "status failure" output.responses).payload with
         | Runtime.Rejected (Worker_failure failure) ->
           Alcotest.(check string)
             "original code"
             (Logseq_db_worker.Error.code_string code)
             (Logseq_db_worker.Error.code_string
                (Logseq_db_worker.Error.code failure.error));
           Alcotest.(check string)
             "original message"
             "Status write diagnostic"
             (Logseq_db_worker.Error.message failure.error);
           Alcotest.(check string)
             "original request"
             (Graph.Uuid.to_string request.request_id)
             (Graph.Uuid.to_string failure.request_id)
         | _ -> Alcotest.fail "Status failure lost its worker error"))
    Logseq_db_worker.Error.[ Corrupt_storage; Invalid_request; Closed_session; Conflict ]
;;

type refresh_case =
  | Capture
  | Update
  | Update_conflict
  | Delete_conflict

type refresh_result =
  | Found
  | Missing
  | Cursor_failed

let earlier_members (page : Graph.page) =
  List.init (Protocol.maximum_page_size + 1) (fun index ->
    let block =
      { block with
        uuid = uuid (Printf.sprintf "a2000000-0000-4000-9000-%012d" (index + 1))
      ; page = page.uuid
      ; parent = page.uuid
      ; order = Printf.sprintf "a0U%06dU" index
      }
    in
    Protocol.
      { value = { record with block }
      ; revision = "earlier-1"
      ; depth = 0
      ; parent = page.uuid
      })
;;

let prepare_paged_refresh kind =
  let runtime = Runtime.create ~localtime:Unix.gmtime () in
  let sampler =
    Journal_calendar.Sampler.create
      ~clock:(fun () -> 1_788_192_000.)
      ~localtime:Unix.gmtime
      ()
  in
  let calendar = Journal_calendar.Sampler.sample sampler |> Result.get_ok in
  Runtime.set_calendar runtime calendar;
  let mutation_id = uuid "a1000000-0000-4000-a000-000000000021" in
  let receive request outcome = Runtime.receive runtime (response request outcome) in
  let next description output = only description output.Runtime.requests in
  let page, mutation =
    match kind with
    | Capture ->
      let creation_time = Journal_time.of_calendar calendar |> Result.get_ok in
      let lookup =
        Runtime.submit
          runtime
          (Journal_graph_request.Capture
             { calendar_generation = Journal_calendar.generation calendar
             ; command =
                 { mutation_id = Graph.Uuid.to_string mutation_id
                 ; block_id = Graph.Uuid.to_string block_uuid
                 ; sibling_order = "a1"
                 ; source = "Committed target"
                 ; task_state = Journal_model.No_status
                 ; creation_time
                 ; children = []
                 }
             })
        |> next "capture page lookup"
      in
      let page =
        match lookup.command with
        | V2_get_page { page = uuid; _ } ->
          { page with
            uuid
          ; kind = Journal_page { journal_day = Journal_time.local_day creation_time }
          }
        | _ -> Alcotest.fail "capture did not request its journal page"
      in
      let children =
        receive lookup (V2_page_outcome (V2_present_page { page; revision = "page-1" }))
        |> next "capture children revision"
      in
      let mutation =
        receive
          children
          (V2_children_outcome
             { parent = page.uuid
             ; revision_scope = V2_children_revision page.uuid
             ; scope_revision = "children-1"
             ; items =
                 List.map
                   (fun (item : Protocol.v2_tree_member) ->
                      Protocol.{ value = item.value; revision = item.revision })
                   (List.filteri
                      (fun index _ -> index < Protocol.maximum_page_size)
                      (earlier_members page))
             ; next_cursor =
                 Some (Graph.Cursor.of_string "existing-children" |> Result.get_ok)
             })
        |> next "capture insertion"
      in
      page, mutation
    | Update | Update_conflict | Delete_conflict ->
      let lookup =
        Runtime.submit
          runtime
          (Journal_graph_request.Load_detail
             { block_id = Graph.Uuid.to_string block_uuid
             ; after = None
             ; limit = 64
             ; request_generation = 20L
             })
        |> next "target lookup"
      in
      let page_lookup =
        receive
          lookup
          (V2_block_outcome
             (V2_present_block
                { value = { record with block = { block with order = "a1" } }
                ; revision = "block-1"
                }))
        |> next "target page lookup"
      in
      let children =
        receive
          page_lookup
          (V2_page_outcome (V2_present_page { page; revision = "page-1" }))
        |> next "target child lookup"
      in
      ignore
        (receive
           children
           (V2_children_outcome
              { parent = block_uuid
              ; revision_scope = V2_children_revision block_uuid
              ; scope_revision = "target-children-1"
              ; items = []
              ; next_cursor = None
              }));
      let command =
        if kind = Delete_conflict
        then
          Journal_graph_request.Delete_subtree
            { mutation_id = Graph.Uuid.to_string mutation_id
            ; block_id = Graph.Uuid.to_string block_uuid
            ; expected_revision = "block-1"
            }
        else
          Journal_graph_request.Update_source
            { mutation_id = Graph.Uuid.to_string mutation_id
            ; block_id = Graph.Uuid.to_string block_uuid
            ; expected_revision = "block-1"
            ; source = "Committed target"
            }
      in
      page, Runtime.submit runtime command |> next "target mutation"
  in
  let refresh =
    receive
      mutation
      (match kind with
       | Capture | Update ->
         V2_mutation_committed
           { mutation_id
           ; status = V2_applied
           ; generation = "graph-1"
           ; before_projection_revision = "projection-1"
           ; after_projection_revision = "projection-2"
           }
       | Update_conflict | Delete_conflict ->
         V2_failed
           { code = Logseq_db_worker.Error.code_string Conflict
           ; message = "Concurrent target change"
           })
    |> next "post-mutation refresh"
  in
  runtime, page, refresh
;;

let test_paged_mutation_refresh kind result =
  let runtime, page, refresh = prepare_paged_refresh kind in
  let cursor = Graph.Cursor.of_string "next-root-page" |> Result.get_ok in
  (* A valid full page of earlier roots does not contain the requested target. *)
  let members = earlier_members page in
  let prefix = List.filteri (fun index _ -> index < Protocol.maximum_page_size) members in
  let tail = List.nth members Protocol.maximum_page_size in
  let first =
    Runtime.receive
      runtime
      (response
         refresh
         (V2_page_tree_outcome
            { page = page.uuid
            ; maximum_depth = 1
            ; items = prefix
            ; next_cursor = Some cursor
            }))
  in
  Alcotest.(check int)
    "a partial prefix cannot complete or reject the mutation"
    0
    (List.length first.responses);
  let continuation = only "next authoritative page" first.requests in
  (match continuation.command with
   | V2_get_page_tree { page = actual; cursor = Some actual_cursor; _ } ->
     Alcotest.(check bool) "same journal" true (Graph.Uuid.equal actual page.uuid);
     Alcotest.(check string)
       "opaque cursor forwarded"
       (Graph.Cursor.to_string cursor)
       (Graph.Cursor.to_string actual_cursor)
   | _ -> Alcotest.fail "refresh did not continue its read without replaying the mutation");
  let target =
    { block with
      page = page.uuid
    ; parent = page.uuid
    ; order = "a1"
    ; title = "Committed target"
    }
  in
  let completed =
    Runtime.receive
      runtime
      (response
         continuation
         (match result with
          | Cursor_failed ->
            V2_failed
              { code = Logseq_db_worker.Error.code_string Stale_read_cursor
              ; message = "The graph changed during refresh"
              }
          | Found | Missing ->
            V2_page_tree_outcome
              { page = page.uuid
              ; maximum_depth = 1
              ; items =
                  (if result = Missing
                   then [ tail ]
                   else
                     [ tail
                     ; { value = { record with block = target }
                       ; revision = "target-2"
                       ; depth = 0
                       ; parent = page.uuid
                       }
                     ])
              ; next_cursor = None
              }))
  in
  Alcotest.(check int) "terminal page stops reading" 0 (List.length completed.requests);
  let first_response = List.hd completed.responses in
  match result, kind, first_response.payload with
  | Cursor_failed, _, Rejected (Worker_failure failure) ->
    Alcotest.(check bool)
      "cursor failure category is preserved"
      true
      (Logseq_db_worker.Error.code failure.error = Stale_read_cursor)
  | Missing, Delete_conflict, Subtree_deleted { deleted_count = 0; _ } -> ()
  | Missing, (Capture | Update | Update_conflict), Rejected (Projection_failure _) -> ()
  | Found, Capture, Block_captured { block = actual; _ }
  | Found, Update, Block_updated { block = actual; _ }
  | Found, Update_conflict, Update_conflict actual
  | Found, Delete_conflict, Delete_conflict actual ->
    Alcotest.(check string)
      "authoritative target"
      "Committed target"
      (Journal_model.source actual);
    if kind = Delete_conflict
    then (
      match List.tl completed.responses with
      | [ { payload = Page_tree_reconciled { value; _ } } ] ->
        Alcotest.(check int)
          "reconciliation retains the entire prefix"
          (Protocol.maximum_page_size + 2)
          (List.length value.entries)
      | _ -> Alcotest.fail "delete conflict omitted prefix reconciliation")
  | _ -> Alcotest.fail "unexpected paged mutation completion"
;;

let tree_page request items next_cursor =
  response
    request
    (Protocol.V2_page_tree_outcome
       { page = page_uuid; maximum_depth = 1; items; next_cursor })
;;

let child_members first count =
  List.init count (fun offset ->
    let index = first + offset in
    let child =
      { block with
        uuid = uuid (Printf.sprintf "a1000000-0000-4000-b000-%012d" index)
      ; parent = block_uuid
      ; order = Printf.sprintf "a%04d" index
      ; title = Printf.sprintf "Child %d" index
      }
    in
    Protocol.
      { value = { record with block = child }
      ; revision = "child-1"
      ; depth = 1
      ; parent = block_uuid
      })
;;

let initial_tree runtime =
  set_calendar runtime;
  let journals = load_feed runtime in
  Runtime.receive
    runtime
    (response
       journals
       (Protocol.V2_journals_outcome
          { items = [ { page; journal_day = 20260901; revision = "page-1" } ]
          ; next_cursor = None
          }))
  |> fun output -> only "initial tree" output.requests
;;

let check_tree_continuation output cursor =
  Alcotest.(check int)
    "no premature terminal response"
    0
    (List.length output.Runtime.responses);
  let request = only "one sequential continuation" output.requests in
  (match request.command with
   | Protocol.V2_get_page_tree
       { page = actual; maximum_depth; limit; cursor = Some actual_cursor; _ } ->
     Alcotest.(check bool) "same page" true (Graph.Uuid.equal page_uuid actual);
     Alcotest.(check int) "same depth" 1 maximum_depth;
     Alcotest.(check int) "same page budget" 4 limit;
     Alcotest.(check string)
       "opaque cursor"
       (Graph.Cursor.to_string cursor)
       (Graph.Cursor.to_string actual_cursor)
   | _ -> Alcotest.fail "expected bounded page-tree continuation");
  request
;;

let test_child_only_day_pages outcome =
  let runtime = Runtime.create () in
  let tree = initial_tree runtime in
  let cursor = Graph.Cursor.of_string "children-after-3" |> Result.get_ok in
  let root : Protocol.v2_tree_member =
    { value = record; revision = "root-1"; depth = 0; parent = page_uuid }
  in
  let initial =
    Runtime.receive runtime (tree_page tree (root :: child_members 1 3) (Some cursor))
  in
  let after =
    List.find_map
      (fun (response : Runtime.response) ->
         match response.payload with
         | Feed_loaded { feed; _ } -> (List.hd feed.days).continuation
         | _ -> None)
      initial.responses
    |> Option.get
  in
  let request =
    Runtime.submit
      runtime
      (Journal_graph_request.Load_day_blocks
         { day = 20260901; after = Some after; limit = 4; request_generation = 19L })
    |> fun output -> only "day page" output.requests
  in
  let request =
    List.fold_left
      (fun request first ->
         let cursor =
           Graph.Cursor.of_string (Printf.sprintf "children-after-%d" (first + 3))
           |> Result.get_ok
         in
         Runtime.receive runtime (tree_page request (child_members first 4) (Some cursor))
         |> fun output -> check_tree_continuation output cursor)
      request
      [ 4; 8 ]
  in
  let later =
    { root with
      value =
        { record with
          block = { block with uuid = unrelated_uuid; order = "b"; title = "Later root" }
        }
    }
  in
  if outcome = `Reset then Runtime.reset runtime;
  let completed =
    Runtime.receive
      runtime
      (if outcome = `Stale
       then
         response
           request
           (Protocol.V2_failed
              { code = Logseq_db_worker.Error.code_string Stale_read_cursor
              ; message = "Changed graph"
              })
       else
         tree_page
           request
           (if outcome = `Exhausted then child_members 12 2 else [ later ])
           None)
  in
  Alcotest.(check int) "no further read" 0 (List.length completed.requests);
  match outcome with
  | `Reset ->
    Alcotest.(check int) "late result fenced" 0 (List.length completed.responses)
  | `Stale ->
    (match (only "day failure" completed.responses).payload with
     | Day_blocks_failed { day; request_generation; stale_cursor; _ } ->
       Alcotest.(check int) "original day" 20260901 day;
       Alcotest.(check int64) "original generation" 19L request_generation;
       Alcotest.(check bool) "stale cursor category" true stale_cursor
     | _ -> Alcotest.fail "lost day failure")
  | `Found | `Exhausted ->
    (match (only "day completion" completed.responses).payload with
     | Day_blocks_loaded { request_generation; page } ->
       Alcotest.(check int64) "original generation" 19L request_generation;
       Alcotest.(check bool) "true exhaustion" true (page.continuation = None);
       Alcotest.(check (list string))
         "visible roots"
         (if outcome = `Found then [ "Later root" ] else [])
         (List.map
            (fun (entry : Journal_graph_projection.timeline_entry) ->
               Journal_model.source entry.block)
            page.entries)
     | _ -> Alcotest.fail "lost day completion")
;;

let test_feed_with_blank_root_continues () =
  let runtime = Runtime.create () in
  let tree = initial_tree runtime in
  let blank : Protocol.v2_tree_member =
    { value = { record with block = { block with title = " " } }
    ; revision = "root-1"
    ; depth = 0
    ; parent = page_uuid
    }
  in
  let cursor = Graph.Cursor.of_string "blank-root-children" |> Result.get_ok in
  let request =
    Runtime.receive runtime (tree_page tree (blank :: child_members 1 3) (Some cursor))
    |> fun output -> check_tree_continuation output cursor
  in
  let cursor = Graph.Cursor.of_string "blank-root-children-next" |> Result.get_ok in
  let request =
    Runtime.receive runtime (tree_page request (child_members 4 4) (Some cursor))
    |> fun output -> check_tree_continuation output cursor
  in
  let visible =
    { blank with
      value =
        { record with
          block =
            { block with uuid = unrelated_uuid; order = "b"; title = "Visible root" }
        }
    }
  in
  let completed = Runtime.receive runtime (tree_page request [ visible ] None) in
  Alcotest.(check int) "feed read complete" 0 (List.length completed.requests);
  match (only "visible feed" completed.responses).payload with
  | Feed_loaded { request_generation; feed; complete } ->
    Alcotest.(check int64) "feed generation" 7L request_generation;
    Alcotest.(check bool) "feed complete" true complete;
    let day = only "one day" feed.days in
    Alcotest.(check (list string))
      "visible feed entries"
      [ "Visible root" ]
      (List.map
         (fun (entry : Journal_graph_projection.timeline_entry) ->
            Journal_model.source entry.block)
         day.entries)
  | _ -> Alcotest.fail "lost initial feed"
;;

let () =
  Alcotest.run
    "journal graph runtime locality"
    [ ( "sparse tree pages"
      , [ Alcotest.test_case "children before a later root" `Quick (fun () ->
            test_child_only_day_pages `Found)
        ; Alcotest.test_case "children before true exhaustion" `Quick (fun () ->
            test_child_only_day_pages `Exhausted)
        ; Alcotest.test_case "stale child cursor keeps day scope" `Quick (fun () ->
            test_child_only_day_pages `Stale)
        ; Alcotest.test_case "reset fences child continuation" `Quick (fun () ->
            test_child_only_day_pages `Reset)
        ; Alcotest.test_case
            "blank root feed continues"
            `Quick
            test_feed_with_blank_root_continues
        ] )
    ; ( "paged mutation refresh"
      , List.concat_map
          (fun (name, kind) ->
             List.map
               (fun (suffix, result) ->
                  Alcotest.test_case
                    (name ^ " " ^ suffix)
                    `Quick
                    (fun () -> test_paged_mutation_refresh kind result))
               [ "found", Found; "missing", Missing; "cursor error", Cursor_failed ])
          [ "capture", Capture
          ; "update", Update
          ; "update conflict", Update_conflict
          ; "delete conflict", Delete_conflict
          ] )
    ; ( "detail"
      , [ Alcotest.test_case
            "resolve unretained page"
            `Quick
            test_detail_resolves_unretained_page
        ; Alcotest.test_case
            "retain child cursor"
            `Quick
            test_detail_forwards_child_cursor
        ] )
    ; ( "read conversion"
      , [ Alcotest.test_case
            "older feed uses an exclusive calendar upper bound"
            `Quick
            test_older_feed_uses_calendar_upper_bound
        ; Alcotest.test_case
            "read categories and ownership survive conversion"
            `Quick
            test_read_failure_conversion_preserves_category_and_ownership
        ] )
    ; ( "mutation conversion"
      , [ Alcotest.test_case
            "status failures preserve their category"
            `Quick
            test_status_failure_conversion
        ] )
    ; ( "bounded hydration"
      , [ Alcotest.test_case
            "queued resync announces refresh"
            `Quick
            test_queued_resync_announces_feed_refresh
        ; Alcotest.test_case "large overlapping deletions" `Quick (fun () ->
            test_large_changes_are_bounded false)
        ; Alcotest.test_case "failed read releases capacity" `Quick (fun () ->
            test_large_changes_are_bounded true)
        ; Alcotest.test_case
            "reset discards background work"
            `Quick
            test_reset_discards_background_backlog
        ; Alcotest.test_case
            "resync and dependent reads"
            `Quick
            test_resync_and_dependent_reads_share_hydration_bound
        ] )
    ; ( "changes"
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
