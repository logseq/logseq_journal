module Graph = Logseq_db_types.Graph_types
module Protocol = Logseq_db_worker.Protocol
module Production_runtime = Journal_graph_runtime

(* Older domain fixtures describe a source tree in one value. Serve that
   synthetic source through the production root-only and bounded-child API;
   the pagination tests below still provide and inspect exact Worker packets. *)
let fixture_requests = Hashtbl.create 32
let fixture_days = Hashtbl.create 32

module Runtime = struct
  include Production_runtime

  let receive runtime (Protocol.V2_response envelope as raw) =
    let key = Graph.Uuid.to_string envelope.request_id in
    match Hashtbl.find_opt fixture_requests key, envelope.outcome with
    | Some (Protocol.V2_get_page_tree {maximum_depth=0;_}),
      Protocol.V2_page_tree_outcome ({maximum_depth=1;items;page;_} as source) ->
      Hashtbl.remove fixture_requests key;
      let roots=List.filter (fun (m:Protocol.v2_tree_member)->m.depth=0) items in
      let result=Production_runtime.receive runtime
          (Protocol.V2_response {envelope with outcome=V2_page_tree_outcome {source with maximum_depth=0;items=roots}}) in
      let rec serve (output:Production_runtime.output) =
        List.fold_left (fun (kept:Production_runtime.output) (request:Protocol.request) ->
          let outcome = match request.command with
            | V2_get_children {parent;limit;cursor;_}
              when limit <= 3 && List.exists (fun (m:Protocol.v2_tree_member)->Graph.Uuid.equal m.value.block.uuid parent) roots ->
              let children=List.filter (fun (m:Protocol.v2_tree_member)->m.depth=1 && Graph.Uuid.equal m.parent parent) items
                |> List.sort (fun (a:Protocol.v2_tree_member) (b:Protocol.v2_tree_member) -> compare (a.value.block.order,Graph.Uuid.to_string a.value.block.uuid) (b.value.block.order,Graph.Uuid.to_string b.value.block.uuid)) in
              let offset=Option.fold ~none:0 ~some:(fun c->Scanf.sscanf (Graph.Cursor.to_string c) "preview:%d" Fun.id) cursor in
              let selected=List.take limit (List.drop offset children) in
              let next_cursor=if offset+List.length selected < List.length children then Some (Graph.Cursor.of_string (Printf.sprintf "preview:%d" (offset+List.length selected)) |> Result.get_ok) else None in
              Some (Protocol.V2_children_outcome {parent;revision_scope=V2_children_revision parent;scope_revision="fixture-children";
                items=List.map (fun (m:Protocol.v2_tree_member)->Protocol.{value=m.value;revision=m.revision}) selected;next_cursor})
            | V2_list_journals {through_day;_}
              when Option.fold ~none:false ~some:(fun day->through_day<day) (Hashtbl.find_opt fixture_days (Graph.Uuid.to_string page)) ->
              Some (Protocol.V2_journals_outcome {items=[];next_cursor=None})
            | _ -> None
          in
          match outcome with
          | None -> {kept with requests=kept.requests@[request]}
          | Some outcome ->
            let next=serve (Production_runtime.receive runtime (Protocol.V2_response {api_version=Protocol.api_version;request_id=request.request_id;outcome})) in
            {requests=kept.requests@next.requests;responses=kept.responses@next.responses})
          {requests=[];responses=output.responses} output.requests
      in serve result
    | _ -> Production_runtime.receive runtime raw
end

let uuid value = Graph.Uuid.of_string value |> Result.get_ok

let only description = function
  | [ value ] -> value
  | values ->
    Alcotest.failf "%s: expected one value, got %d" description (List.length values)
;;

let request_id (request : Protocol.request) = request.request_id

let response request outcome =
  Hashtbl.replace fixture_requests (Graph.Uuid.to_string request.Protocol.request_id) request.command;
  (match outcome with
   | Protocol.V2_journals_outcome {items;_} -> List.iter (fun (i:Protocol.v2_journal_item)->Hashtbl.replace fixture_days (Graph.Uuid.to_string i.page.uuid) i.journal_day) items
   | _ -> ());
  Protocol.V2_response
    { api_version = Protocol.api_version; request_id = request_id request; outcome }
;;

let set_calendar ?(clock=1_788_192_000.) runtime =
  let sampler =
    Journal_calendar.Sampler.create
      ~clock:(fun () -> clock)
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
  { block; task_status = None; rendered_page_title = page.title; tag_titles = [] }
;;

let load_feed runtime =
  Runtime.submit
    runtime
    (Journal_graph_request.Load_feed
       { cursor = None
       ; day_limit = 3
       ; root_limit = 4

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
         { cursor = None
         ; day_limit = 1
         ; root_limit = 64

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
        | V2_get_outline_block { block; _ } -> block
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
  let complete_feeds = ref 0 and reconciled_pages = ref 0 in
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
        | V2_get_page_tree {maximum_depth;_} ->
          ( "tree"
          , Protocol.V2_page_tree_outcome
              { page = page_uuid; maximum_depth; items=List.filter (fun (m:Protocol.v2_tree_member)->m.depth<=maximum_depth) items; next_cursor = None } )
        | V2_get_children { parent; _ } ->
          ( "children"
          , Protocol.V2_children_outcome
              { parent
              ; revision_scope = V2_children_revision parent
              ; scope_revision = "children-2"
              ; items = []
              ; next_cursor = None
              } )
        | V2_get_outline_block { block = id; _ } ->
          let value =
            List.find
              (fun (value : Protocol.v2_block_record) ->
                 Graph.Uuid.equal value.block.uuid id)
              records
          in
          ( "block"
          , Protocol.V2_block_outcome (V2_present_block { value; revision = "block-2" }) )
        | V2_get_page _ ->
          "page", Protocol.V2_page_outcome (V2_present_page { page; revision = "page-2" })
        | _ -> Alcotest.fail "resync request outside retained interests"
      in
      Hashtbl.replace
        counts
        kind
        (1 + Option.value ~default:0 (Hashtbl.find_opt counts kind));
      let result = Production_runtime.receive runtime (response request outcome) in
      List.iter (fun (r : Runtime.response) -> match r.payload with
        | Feed_loaded { complete = true; _ } -> incr complete_feeds
        | Page_tree_reconciled { value; _ } ->
          incr reconciled_pages;
          Alcotest.(check int) "retained page reconciliation is complete" 48
            (List.length value.entries)
        | _ -> ()) result.responses;
      let outstanding = rest @ result.requests in
      check_hydration_bound outstanding;
      drain outstanding
  in
  drain output.requests;
  Alcotest.(check int) "resync prefix completes" 1 !complete_feeds;
  Alcotest.(check int) "resync retained page also completes" 1 !reconciled_pages;
  List.iter
    (fun (kind, expected) ->
       Alcotest.(check int)
         kind
         expected
         (Option.value ~default:0 (Hashtbl.find_opt counts kind)))
    (* 48 Detail reads plus 48 previews for each of the prefix and retained
       page owners. Cancelling either Timeline owner is not a valid bound. *)
    [ "graph", 1; "journal", 1; "tree", 2; "children", 144; "block", 48; "page", 1 ]
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
    3
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
  | [ { Protocol.command = V2_get_outline_block { block; _ }; _ } ] ->
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
  | [ { Protocol.command = V2_get_page_tree { page; maximum_depth = 0; _ }; _ } ] ->
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
       let rec reject request =
         let output = Runtime.receive runtime (response request
             (Protocol.V2_failed {code=Logseq_db_worker.Error.code_string code;message="Read diagnostic"})) in
         match output.requests with
         | [retry] when code=Logseq_db_worker.Error.Response_too_large -> reject retry
         | _ -> output
       in
       let output = reject request in
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
              { cursor = Some {before_day=Some before_day;skipped_day=None}
              ; day_limit = 3
              ; root_limit = 4

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

let test_detail_resolves_unretained_page ?(tagged = false) () =
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
            (V2_present_block
               { value = (if tagged then { record with tag_titles = [ "周末"; "旅行" ] } else record)
               ; revision = "block-1" })))
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
  let child_uuid = Graph.Uuid.of_string "a1000000-0000-4000-9000-000000000003" |> Result.get_ok in
  let output =
    Runtime.receive
      runtime
      (response
         children
         (Protocol.V2_children_outcome
            { parent = block_uuid
            ; revision_scope = V2_children_revision block_uuid
            ; scope_revision = "children-1"
            ; items = (if tagged then
                [ { Protocol.value = { record with block =
                      { block with uuid = child_uuid; parent = block_uuid; title = "Child" }
                    ; tag_titles = [ "地图" ] }
                  ; revision = "child-1" } ] else [])
            ; next_cursor = None
            }))
  in
  match (only "ordinary detail completion" output.responses).payload with
  | Runtime.Detail_loaded { request_generation = 91L; detail } ->
    Alcotest.(check (option int))
      "ordinary page does not fabricate a journal date"
      None
      (Journal_model.journal_day_opt detail.root);
    if tagged then (
      Alcotest.(check (list string)) "Detail preserves root tags returned by its reader"
        [ "周末"; "旅行" ] (Journal_model.tag_titles detail.root);
      Alcotest.(check (list string)) "Detail preserves child tags returned by its reader"
        [ "地图" ] (Journal_model.tag_titles (only "tagged child" detail.children.blocks)))
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
              ; task_state = Journal_model.Status "00000002-1615-5853-7700-000000000000"
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
         | Runtime.Mutation_failed
             { kind = Status_mutation; failure = Worker_failure failure; _ } ->
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
                 ; status_confirmation = false
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

let summary_response request page lookup children next_cursor revision =
  response
    request
    (Protocol.V2_block_summary_outcome
       { lookup
       ; page = Some (V2_present_page { page; revision = "page-1" })
       ; items = children
       ; next_cursor
       ; scope_revision = "target-children-1"
       ; generation = "graph-1"
       ; projection_revision = revision
       })
;;

let check_target_summary (request : Protocol.request) cursor =
  match request.command with
  | V2_get_outline_block_summary { block; limit; cursor = actual_cursor } ->
    Alcotest.(check bool) "target identity" true (Graph.Uuid.equal block block_uuid);
    Alcotest.(check int) "bounded target children" Protocol.default_page_size limit;
    Alcotest.(check bool) "target children cursor" true (actual_cursor = cursor)
  | _ -> Alcotest.fail "confirmation must issue one canonical target read"
;;

let test_paged_mutation_refresh kind result =
  let runtime, page, refresh = prepare_paged_refresh kind in
  if kind = Capture || kind = Update
  then (
    check_target_summary refresh None;
    let target =
      { record with
        block =
          { block with page = page.uuid; parent = page.uuid; title = "Committed target" }
      }
    in
    let lookup = Protocol.V2_present_block { value = target; revision = "target-2" } in
    let completed =
      match result with
      | Found ->
        Runtime.receive
          runtime
          (summary_response refresh page lookup [] None "projection-2")
      | Missing ->
        Runtime.receive
          runtime
          (summary_response
             refresh
             page
             (V2_missing_block { uuid = block_uuid; revision = "missing-2" })
             []
             None
             "projection-2")
      | Cursor_failed ->
        let current = ref refresh in
        for _ = 1 to 2 do
          current
          := Runtime.receive
               runtime
               (response
                  !current
                  (V2_failed
                     { code = Logseq_db_worker.Error.code_string Stale_read_cursor
                     ; message = "Concurrent target change"
                     }))
             |> fun output -> only "bounded canonical retry" output.requests
        done;
        Runtime.receive
          runtime
          (response
             !current
             (V2_failed
                { code = Logseq_db_worker.Error.code_string Stale_read_cursor
                ; message = "Concurrent target change"
                }))
    in
    Alcotest.(check int)
      "target terminal confirmation stops reading"
      0
      (List.length completed.requests);
    match
      result, kind, (only "owned canonical target terminal" completed.responses).payload
    with
    | Found, Capture, Block_captured { block; _ }
    | Found, Update, Block_updated { block; _ } ->
      Alcotest.(check string)
        "authoritative target after earlier siblings"
        "Committed target"
        (Journal_model.source block)
    | Cursor_failed, _, Mutation_failed { failure = Worker_failure failure; _ } ->
      Alcotest.(check bool)
        "cursor failure category is preserved"
        true
        (Logseq_db_worker.Error.code failure.error = Stale_read_cursor)
    | Missing, _, Mutation_failed _ -> ()
    | _ -> Alcotest.fail "unexpected canonical mutation completion")
  else (
    let cursor = Graph.Cursor.of_string "next-root-page" |> Result.get_ok in
    (* A valid full page of earlier roots does not contain the requested target. *)
    let members = earlier_members page in
    let prefix =
      List.filteri (fun index _ -> index < Protocol.maximum_page_size) members
    in
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
     | _ ->
       Alcotest.fail "refresh did not continue its read without replaying the mutation");
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
    | Cursor_failed, _, Mutation_failed { failure = Worker_failure failure; _ } ->
      Alcotest.(check bool)
        "cursor failure category is preserved"
        true
        (Logseq_db_worker.Error.code failure.error = Stale_read_cursor)
    | Missing, Delete_conflict, Subtree_deleted { deleted_count = 0; _ } -> ()
    | ( Missing
      , (Capture | Update | Update_conflict)
      , Mutation_failed { failure = Projection_failure _; _ } ) -> ()
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
    | _ -> Alcotest.fail "unexpected paged mutation completion")
;;

(* F3 is owned by the public Runtime request/completion boundary. The original
   RED phase used wire representations before the new command existed,
   so baseline tests fail on the emitted read rather than missing OCaml types. *)
let target_refresh kind =
  match kind with
  | `Capture -> prepare_paged_refresh Capture
  | `Update -> prepare_paged_refresh Update
  | `Status ->
    let runtime = Runtime.create ~localtime:Unix.gmtime () in
    seed_feed runtime;
    let mutation =
      Runtime.submit
        runtime
        (Journal_graph_request.Set_task_state
           { mutation_id = "a1000000-0000-4000-a000-000000000072"
           ; block_id = Graph.Uuid.to_string block_uuid
           ; expected_revision = "block-1"
           ; task_state = Journal_model.Status "00000002-1827-5820-8200-000000000000"
           })
      |> fun output -> only "status mutation" output.requests
    in
    let refresh =
      Runtime.receive
        runtime
        (response
           mutation
           (Protocol.V2_mutation_committed
              { mutation_id = uuid "a1000000-0000-4000-a000-000000000072"
              ; status = V2_applied
              ; generation = "graph-1"
              ; before_projection_revision = "projection-1"
              ; after_projection_revision = "projection-2"
              }))
      |> fun output -> only "status confirmation" output.requests
    in
    runtime, page, refresh
;;

let summary_children ?(page = page_uuid) count =
  List.init count (fun index ->
    let child =
      { block with
        uuid = uuid (Printf.sprintf "a1000000-0000-4000-b000-%012d" index)
      ; page
      ; parent = block_uuid
      ; order = Printf.sprintf "b%04d" index
      ; title = Printf.sprintf "Canonical child %d" index
      }
    in
    Protocol.{ value = { record with block = child }; revision = "child-2" })
;;

let test_target_confirmation kind title count =
  let runtime, page, refresh = target_refresh kind in
  check_target_summary refresh None;
  let canonical =
    { record with
      block = { block with page = page.uuid; parent = page.uuid; title; order = "z" }
    }
  in
  let children = summary_children ~page:page.uuid count in
  let complete =
    Runtime.receive
      runtime
      (summary_response
         refresh
         page
         (V2_present_block { value = canonical; revision = "canonical-2" })
         children
         None
         "projection-2")
  in
  Alcotest.(check int)
    "target completion does not read siblings"
    0
    (List.length complete.requests);
  let payload = (only "target completion" complete.responses).payload in
  let actual, entry =
    match kind, payload with
    | `Capture, Runtime.Block_captured { block; timeline_entry_update }
    | (`Update | `Status), Runtime.Block_updated { block; timeline_entry_update } ->
      block, timeline_entry_update
    | _ -> Alcotest.fail "target completion lost mutation ownership"
  in
  Alcotest.(check string) "canonical stored source" title (Journal_model.source actual);
  Alcotest.(check string)
    "canonical revision"
    "canonical-2"
    (Journal_model.revision actual);
  Alcotest.(check int) "canonical children count" count (Journal_model.child_count actual);
  (match entry with
   | Some entry ->
     Alcotest.(check int)
       "bounded canonical child summaries"
       (min 3 count)
       (List.length entry.child_summaries)
   | None -> Alcotest.(check string) "blank root is not fabricated as visible" "" title);
  let duplicate =
    Runtime.receive
      runtime
      (summary_response
         refresh
         page
         (V2_present_block { value = canonical; revision = "canonical-2" })
         children
         None
         "projection-2")
  in
  Alcotest.(check int) "completion is consumed once" 0 (List.length duplicate.responses)
;;

let test_target_children_continue () =
  let runtime, page, refresh = target_refresh `Capture in
  let canonical =
    { record with
      block =
        { block with page = page.uuid; parent = page.uuid; title = "Canonical root" }
    }
  in
  let lookup =
    Protocol.V2_present_block { value = canonical; revision = "canonical-2" }
  in
  let children = summary_children ~page:page.uuid 201 in
  let current = ref refresh in
  let previous_cursor = ref None in
  let completion = ref Runtime.{ requests = []; responses = [] } in
  for batch = 0 to 4 do
    check_target_summary !current !previous_cursor;
    let items =
      List.filteri
        (fun index _ ->
           index >= batch * Protocol.default_page_size
           && index < (batch + 1) * Protocol.default_page_size)
        children
    in
    let cursor =
      if batch = 4
      then None
      else
        Some
          (Graph.Cursor.of_string (Printf.sprintf "target-children-%d" batch)
           |> Result.get_ok)
    in
    let output =
      Runtime.receive
        runtime
        (summary_response !current page lookup items cursor "projection-2")
    in
    if batch < 4
    then (
      Alcotest.(check int)
        "partial target children do not complete Capture"
        0
        (List.length output.responses);
      current := only "target child continuation" output.requests;
      previous_cursor := cursor)
    else completion := output
  done;
  match (only "all canonical children" !completion.responses).payload with
  | Block_captured { block; timeline_entry_update = Some entry } ->
    Alcotest.(check int)
      "child count is not truncated"
      201
      (Journal_model.child_count block);
    Alcotest.(check int)
      "bounded target child preview"
      3
      (List.length entry.child_summaries)
  | _ -> Alcotest.fail "Capture lost its canonical children"
;;

let test_target_terminal kind terminal =
  let runtime, page, refresh = target_refresh kind in
  check_target_summary refresh None;
  let completion =
    match terminal with
    | `Missing ->
      summary_response
        refresh
        page
        (V2_missing_block { uuid = block_uuid; revision = "missing" })
        []
        None
        "projection-2"
    | `Failure ->
      response
        refresh
        (Protocol.V2_failed { code = "ClosedSession"; message = "read unavailable" })
    | `Reset ->
      Runtime.reset runtime;
      summary_response
        refresh
        page
        (V2_missing_block { uuid = block_uuid; revision = "missing" })
        []
        None
        "projection-2"
  in
  let output = Runtime.receive runtime completion in
  if terminal = `Reset
  then
    Alcotest.(check int) "old graph completion ignored" 0 (List.length output.responses)
  else (
    match (only "owned target failure" output.responses).payload with
    | Runtime.Mutation_failed { kind = actual; block_id; _ } ->
      Alcotest.(check bool)
        "mutation kind preserved"
        true
        (actual
         =
         if kind = `Capture
         then Capture_mutation
         else if kind = `Status
         then Status_mutation
         else Source_mutation);
      Alcotest.(check string)
        "mutation block identity"
        (Graph.Uuid.to_string block_uuid)
        block_id
    | _ -> Alcotest.fail "target failure lost admitted mutation identity")
;;

let test_target_version_fence () =
  let runtime, page, refresh = target_refresh `Capture in
  check_target_summary refresh None;
  let canonical =
    { record with block = { block with page = page.uuid; parent = page.uuid } }
  in
  let lookup =
    Protocol.V2_present_block { value = canonical; revision = "canonical-2" }
  in
  let cursor = Graph.Cursor.of_string "target-children-next" |> Result.get_ok in
  let first =
    Runtime.receive
      runtime
      (summary_response
         refresh
         page
         lookup
         (summary_children ~page:page.uuid Protocol.default_page_size)
         (Some cursor)
         "projection-2")
  in
  let continuation = only "target child continuation" first.requests in
  let result =
    Runtime.receive
      runtime
      (summary_response continuation page lookup [] None "projection-3")
  in
  Alcotest.(check bool)
    "different snapshots cannot complete mixed Capture"
    false
    (List.exists
       (fun value ->
          match value.Runtime.payload with
          | Block_captured _ -> true
          | _ -> false)
       result.responses);
  let retry = only "fresh canonical target retry" result.requests in
  check_target_summary retry None
;;

let test_target_rejects_wrong_identity () =
  let runtime, page, refresh = target_refresh `Update in
  check_target_summary refresh None;
  let output =
    Runtime.receive
      runtime
      (summary_response
         refresh
         page
         (V2_present_block
            { value = { record with block = { block with uuid = unrelated_uuid } }
            ; revision = "foreign"
            })
         []
         None
         "projection-2")
  in
  match (only "foreign target failure" output.responses).payload with
  | Runtime.Mutation_failed _ -> ()
  | _ -> Alcotest.fail "foreign canonical block cannot confirm admitted target"
;;

let asset_type_property : Graph.property_summary =
  { ident = "logseq.property.asset/type"
  ; uuid = uuid "a1000000-0000-4000-b000-000000000999"
  ; title = "Asset type"
  ; schema = { property_type = String; cardinality = One; hidden = false; public = false }
  ; values = [ String_value "png" ]
  ; values_truncated = false
  }
;;

let test_target_blank_image_and_deep_child () =
  List.iter
    (fun child_target ->
       let runtime, page, refresh = target_refresh `Update in
       check_target_summary refresh None;
       let canonical =
         { record with
           block =
             { block with
               title = ""
             ; page = page.uuid
             ; parent = (if child_target then unrelated_uuid else page.uuid)
             }
         }
       in
       let image = List.hd (summary_children 1) in
       let image =
         { image with
           value =
             { image.value with
               block = { image.value.block with properties = [ asset_type_property ] }
             }
         }
       in
       let output =
         Runtime.receive
           runtime
           (summary_response
              refresh
              page
              (V2_present_block { value = canonical; revision = "canonical-2" })
              [ image ]
              None
              "projection-2")
       in
       match
         (only "canonical blank/image or deep child completion" output.responses).payload
       with
       | Runtime.Block_updated { block; timeline_entry_update } ->
         Alcotest.(check int)
           "canonical target has its child"
           1
           (Journal_model.child_count block);
         Alcotest.(check bool)
           "child image content does not retain an empty parent"
           false
           (Option.is_some timeline_entry_update)
       | _ -> Alcotest.fail "deep child or blank image target was not confirmed")
    [ false; true ]
;;

let test_target_stale_recovery_is_bounded () =
  let runtime, _, refresh = target_refresh `Capture in
  check_target_summary refresh None;
  let stale request =
    response
      request
      (Protocol.V2_failed { code = "staleReadCursor"; message = "Concurrent projection" })
  in
  let current = ref refresh in
  for _ = 1 to 2 do
    let output = Runtime.receive runtime (stale !current) in
    Alcotest.(check int)
      "retry does not prematurely complete Capture"
      0
      (List.length output.responses);
    current := only "bounded fresh target retry" output.requests;
    check_target_summary !current None
  done;
  let exhausted = Runtime.receive runtime (stale !current) in
  Alcotest.(check int) "stale retries stop" 0 (List.length exhausted.requests);
  match (only "owned retry exhaustion" exhausted.responses).payload with
  | Runtime.Mutation_failed { kind = Capture_mutation; _ } -> ()
  | _ -> Alcotest.fail "stale retry exhaustion lost Capture owner"
;;

let test_target_newer_confirmation_fences_old () =
  let runtime, page, old_read = target_refresh `Update in
  check_target_summary old_read None;
  let mutation =
    Runtime.submit
      runtime
      (Journal_graph_request.Update_source
         { mutation_id = "a1000000-0000-4000-a000-000000000073"
         ; block_id = Graph.Uuid.to_string block_uuid
         ; expected_revision = "block-1"
         ; source = "Newer intent"
         })
    |> fun output -> only "newer admitted update" output.requests
  in
  let newer_read =
    Runtime.receive
      runtime
      (response
         mutation
         (Protocol.V2_mutation_committed
            { mutation_id = uuid "a1000000-0000-4000-a000-000000000073"
            ; status = V2_applied
            ; generation = "graph-1"
            ; before_projection_revision = "projection-2"
            ; after_projection_revision = "projection-3"
            }))
    |> fun output -> only "newer confirmation" output.requests
  in
  check_target_summary newer_read None;
  let canonical title revision request =
    summary_response
      request
      page
      (V2_present_block
         { value =
             { record with
               block = { block with title; page = page.uuid; parent = page.uuid }
             }
         ; revision
         })
      []
      None
      "projection-3"
  in
  ignore (Runtime.receive runtime (canonical "Newer stored" "canonical-3" newer_read));
  let late = Runtime.receive runtime (canonical "Older stored" "canonical-2" old_read) in
  Alcotest.(check bool)
    "superseded read cannot overwrite newer canonical state"
    false
    (List.exists
       (fun value ->
          match value.Runtime.payload with
          | Block_updated _ -> true
          | _ -> false)
       late.responses)
;;

let test_target_invisible_root_has_timeline_only_removal () =
  let runtime, page, refresh = target_refresh `Update in
  check_target_summary refresh None;
  let canonical =
    { record with
      block = { block with title = ""; page = page.uuid; parent = page.uuid }
    }
  in
  let output =
    Runtime.receive
      runtime
      (summary_response
         refresh
         page
         (V2_present_block { value = canonical; revision = "canonical-2" })
         []
         None
         "projection-2")
  in
  Alcotest.(check int)
    "canonical blank title confirms using existing presentation semantics"
    1
    (List.length output.responses);
  Alcotest.(check bool)
    "visibility is not deletion of the detail or child"
    false
    (List.exists
       (fun value ->
          match value.Runtime.payload with
          | Block_removed _ -> true
          | _ -> false)
       output.responses)
;;

let test_target_confirmation_retains_page_interest completed =
  let runtime, page, refresh = target_refresh `Capture in
  check_target_summary refresh None;
  let canonical =
    { record with block = { block with page = page.uuid; parent = page.uuid } }
  in
  if completed
  then
    ignore
      (Runtime.receive
         runtime
         (summary_response
            refresh
            page
            (V2_present_block { value = canonical; revision = "canonical-2" })
            []
            None
            "projection-2"));
  let output =
    changed runtime (window ~scopes:[ Protocol.V2_page_tree_interest page.uuid ] ())
  in
  require_ack output;
  match hydration_requests output with
  | [ { Protocol.command = V2_get_page_tree { page = actual; maximum_depth = 1; _ }; _ } ]
    ->
    Alcotest.(check bool)
      "new Capture page remains subscribed to structural changes"
      true
      (Graph.Uuid.equal actual page.uuid)
  | requests ->
    Alcotest.failf
      "captured page lost its structural interest: %d hydration requests"
      (List.length requests)
;;

let test_target_confirmation_retains_child_mutation_context () =
  let runtime, page, refresh = target_refresh `Capture in
  let canonical =
    { record with block = { block with page = page.uuid; parent = page.uuid } }
  in
  let children = summary_children ~page:page.uuid 1 in
  let child = (List.hd children).Protocol.value.block.uuid in
  ignore
    (Runtime.receive
       runtime
       (summary_response
          refresh
          page
          (V2_present_block { value = canonical; revision = "canonical-2" })
          children
          None
          "projection-2"));
  let source =
    Runtime.submit
      runtime
      (Journal_graph_request.Update_source
         { mutation_id = "a1000000-0000-4000-a000-000000000074"
         ; block_id = Graph.Uuid.to_string child
         ; expected_revision = "child-2"
         ; source = "Child edited"
         })
  in
  (match source.requests with
   | [ { Protocol.command = V2_save_block { block; _ }; _ } ] ->
     Alcotest.(check bool)
       "canonical child keeps its page for source edits"
       true
       (Graph.Uuid.equal block child)
   | _ -> Alcotest.fail "target summary lost child's mutation context");
  let status =
    Runtime.submit
      runtime
      (Journal_graph_request.Set_task_state
         { mutation_id = "a1000000-0000-4000-a000-000000000075"
         ; block_id = Graph.Uuid.to_string child
         ; expected_revision = "child-2"
         ; task_state = Journal_model.Status "00000002-1827-5820-8200-000000000000"
         })
  in
  match status.requests with
  | [ { Protocol.command = V2_set_task_status { block; _ }; _ } ] ->
    Alcotest.(check bool)
      "canonical child keeps its page for status edits"
      true
      (Graph.Uuid.equal block child)
  | _ -> Alcotest.fail "target summary lost child's status context"
;;

let tree_page request items next_cursor =
  response
    request
    (Protocol.V2_page_tree_outcome
       { page = page_uuid; maximum_depth = 1; items; next_cursor })
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
     Alcotest.(check int) "root-only depth" 0 maximum_depth;
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
    Runtime.receive runtime (tree_page tree [root] (Some cursor))
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
         Runtime.receive runtime (tree_page request [] (Some cursor))
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
           (if outcome = `Exhausted then [] else [ later ])
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
     | Feed_loaded { request_generation; feed; complete=true } ->
       let entries = List.concat_map (fun (d:Journal_graph_projection.day_feed)->d.entries) feed.days in
       Alcotest.(check int64) "original generation" 19L request_generation;
       Alcotest.(check bool) "true exhaustion" true (Option.is_none feed.continuation);
       Alcotest.(check (list string))
         "visible roots"
         (if outcome = `Found then [ "Later root" ] else [])
         (List.map
            (fun (entry : Journal_graph_projection.timeline_entry) ->
               Journal_model.source entry.block)
            entries)
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
    Runtime.receive runtime (tree_page tree [blank] (Some cursor))
    |> fun output -> check_tree_continuation output cursor
  in
  let cursor = Graph.Cursor.of_string "blank-root-children-next" |> Result.get_ok in
  let request =
    Runtime.receive runtime (tree_page request [] (Some cursor))
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

let graph_info_outcome ~journal_title_format =
  Protocol.V2_graph_info_outcome
    { graph_uuid = uuid "a1000000-0000-4000-8000-0000000000ff"
    ; graph_name = "Journal"
    ; schema = { major = 65; minor = 33 }
    ; admission_facts = []
    ; journal_title_format
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
    ; projection_revision = "projection-1"
    }
;;

let capture_format_read ~journal_day =
  let runtime = Runtime.create ~localtime:Unix.gmtime () in
  let sampler =
    Journal_calendar.Sampler.create
      ~clock:(fun () -> 1_788_192_000.)
      ~localtime:Unix.gmtime
      ()
  in
  let calendar = Journal_calendar.Sampler.sample sampler |> Result.get_ok in
  Runtime.set_calendar runtime calendar;
  let creation_time =
    Journal_time.create
      ~instant_unix_ms:1_788_192_000_000L
      ~local_day:journal_day
      ~local_minute_of_day:0
    |> Result.get_ok
  in
  let lookup =
    Runtime.submit
      runtime
      (Journal_graph_request.Capture
         { calendar_generation = Journal_calendar.generation calendar
         ; command =
             { mutation_id = "a1000000-0000-4000-a000-0000000000c1"
             ; block_id = Graph.Uuid.to_string block_uuid
             ; sibling_order = "a1"
             ; source = "Captured block"
             ; task_state = Journal_model.No_status
             ; creation_time
             ; children = []
             ; status_confirmation = false
             }
         })
    |> fun output -> only "capture page lookup" output.requests
  in
  let page =
    match lookup.command with
    | V2_get_page { page; _ } -> page
    | _ -> Alcotest.fail "capture did not request its journal page"
  in
  let format_read =
    Runtime.receive
      runtime
      (response
         lookup
         (Protocol.V2_page_outcome (V2_missing_page { uuid = page; revision = "page-1" })))
    |> fun output -> only "journal title format read" output.requests
  in
  (match format_read.command with
   | V2_graph_info -> ()
   | _ -> Alcotest.fail "missing journal page did not read the title format");
  runtime, page, format_read
;;

let create_journal_title ~journal_day ~journal_title_format =
  let runtime, page, format_read = capture_format_read ~journal_day in
  let creation =
    Runtime.receive
      runtime
      (response format_read (graph_info_outcome ~journal_title_format))
    |> fun output -> only "journal page creation" output.requests
  in
  match creation.command with
  | V2_create_journal_page { page = created; journal_day = day; title; _ } ->
    Alcotest.(check bool) "journal page identity" true (Graph.Uuid.equal created page);
    Alcotest.(check int) "journal day" journal_day day;
    title
  | _ -> Alcotest.fail "format read did not continue to journal page creation"
;;

let test_journal_title_defaults_to_upstream_format () =
  Alcotest.(check string)
    "default format"
    "Sep 19th, 2026"
    (create_journal_title ~journal_day:20260919 ~journal_title_format:None)
;;

let test_journal_title_uses_configured_format () =
  Alcotest.(check string)
    "configured ISO format"
    "2026-09-19"
    (create_journal_title ~journal_day:20260919 ~journal_title_format:(Some "yyyy-MM-dd"));
  Alcotest.(check string)
    "weekday and ordinal tokens"
    "Saturday, Sep 19th, 2026"
    (create_journal_title
       ~journal_day:20260919
       ~journal_title_format:(Some "EEEE, MMM do, yyyy"))
;;

let test_journal_title_falls_back_on_invalid_format () =
  Alcotest.(check string)
    "unsupported token falls back to the upstream default"
    "Sep 19th, 2026"
    (create_journal_title ~journal_day:20260919 ~journal_title_format:(Some "yyyy-QQ-dd"))
;;

let test_journal_title_failed_format_read_rejects () =
  let runtime, _, format_read = capture_format_read ~journal_day:20260919 in
  let completed =
    Runtime.receive
      runtime
      (response
         format_read
         (Protocol.V2_failed
            { code = Logseq_db_worker.Error.code_string Closed_session
            ; message = "Snapshot unavailable"
            }))
  in
  Alcotest.(check int)
    "no creation after a failed read"
    0
    (List.length completed.requests);
  match (only "capture rejected" completed.responses).payload with
  | Mutation_failed { kind = Capture_mutation; failure = Worker_failure _; _ } -> ()
  | _ -> Alcotest.fail "a failed format read lost its admitted capture"
;;

let test_journal_title_ordinals_and_boundaries () =
  List.iter
    (fun (journal_day, expected) ->
       Alcotest.(check string)
         (Printf.sprintf "%d" journal_day)
         expected
         (create_journal_title ~journal_day ~journal_title_format:None))
    [ 20260901, "Sep 1st, 2026"
    ; 20260902, "Sep 2nd, 2026"
    ; 20260903, "Sep 3rd, 2026"
    ; 20260911, "Sep 11th, 2026"
    ; 20260912, "Sep 12th, 2026"
    ; 20260913, "Sep 13th, 2026"
    ; 20260921, "Sep 21st, 2026"
    ; 20260922, "Sep 22nd, 2026"
    ; 20260923, "Sep 23rd, 2026"
    ; 20260831, "Aug 31st, 2026"
    ; 20261001, "Oct 1st, 2026"
    ; 20261231, "Dec 31st, 2026"
    ; 20270101, "Jan 1st, 2027"
    ; 20280229, "Feb 29th, 2028"
    ]
;;

let target_uuid = uuid "a1000000-0000-4000-9000-000000000050"
let target_id = Graph.Uuid.to_string target_uuid
let reference = "[[" ^ target_id ^ "]]"

let reference_feed runtime source =
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
    |> fun output -> only "reference page tree" output.requests
  in
  Runtime.receive
    runtime
    (response
       tree
       (Protocol.V2_page_tree_outcome
          { page = page_uuid
          ; maximum_depth = 1
          ; items =
              [ { value = { record with block = { block with title = source } }
                ; revision = "block-1"
                ; depth = 0
                ; parent = page_uuid
                }
              ]
          ; next_cursor = None
          }))
;;

let target_response request title =
  response
    request
    (Protocol.V2_block_outcome
       (V2_present_block
          { value = { record with block = { block with uuid = target_uuid; title } }
          ; revision = title
          }))
;;

let reference_updates output =
  List.concat_map
    (fun response ->
       match response.Runtime.payload with
       | Runtime.Reference_sources_changed values -> values
       | _ -> [])
    output.Runtime.responses
;;

let outline_after_page_miss runtime request =
  match request.Protocol.command with
  | V2_get_page {page;_} ->
    Runtime.receive runtime (response request (Protocol.V2_page_outcome
      (V2_missing_page {uuid=page;revision="page-absent"})))
    |> fun output -> only "outline lookup after page absence" output.requests
  | V2_get_outline_block _ -> request
  | _ -> Alcotest.fail "not a reference lookup"
;;

let check_target_request runtime output =
  let request = only "shared reference point read" (hydration_requests output)
    |> outline_after_page_miss runtime in
  Alcotest.(check bool)
    "reads only target UUID"
    true
    (request.Protocol.command = V2_get_outline_block { block = target_uuid; revision = None });
  request
;;

let test_reference_hydration_and_changes () =
  let runtime = Runtime.create () in
  let request =
    reference_feed runtime (reference ^ " " ^ reference ^ " [[page]]")
    |> check_target_request runtime
  in
  let resolved = Runtime.receive runtime (target_response request "Referenced content") in
  Alcotest.(check (option string))
    "target is shared with UI"
    (Some "Referenced content")
    (List.assoc_opt target_id (reference_updates resolved) |> Option.join);
  Alcotest.(check int)
    "duplicate and literal links cause no extra requests"
    0
    (List.length resolved.requests);
  let changed_request =
    changed runtime (window ~blocks:[ target_uuid; unrelated_uuid ] ())
    |> check_target_request runtime
  in
  let updated =
    Runtime.receive runtime (target_response changed_request "Edited content")
  in
  Alcotest.(check (option string))
    "target edit reaches UI"
    (Some "Edited content")
    (List.assoc_opt target_id (reference_updates updated) |> Option.join);
  let deleted_request =
    changed runtime (window ~blocks:[ target_uuid ] ()) |> check_target_request runtime
  in
  let deleted =
    Runtime.receive
      runtime
      (response
         deleted_request
         (Protocol.V2_block_outcome
            (V2_missing_block { uuid = target_uuid; revision = "deleted" })))
  in
  Alcotest.(check bool)
    "missing target clears cached source"
    true
    (List.assoc_opt target_id (reference_updates deleted) = Some None);
  let recreated_request =
    changed runtime (window ~blocks:[ target_uuid ] ()) |> check_target_request runtime
  in
  ignore (Runtime.receive runtime (target_response recreated_request "Recreated"));
  let resync =
    Runtime.reconcile_push
      runtime
      ~request_generation:12L
      (Protocol.V2_resync_required_push
         { api_version = Protocol.api_version
         ; generation = "generation-2"
         ; reason = "consumer lagged"
         })
  in
  Alcotest.(check bool)
    "resync retains target interest"
    true
    (List.exists
       (fun (request : Protocol.request) ->
          request.command = V2_get_page { page = target_uuid; revision = None })
       resync.requests);
  Runtime.reset runtime;
  Alcotest.(check int)
    "reset discards old completion"
    0
    (List.length
       (Runtime.receive runtime (target_response request "Old graph")).responses)
;;

let test_reference_cycle_and_failure () =
  let runtime = Runtime.create () in
  let request = reference_feed runtime reference |> check_target_request runtime in
  let output =
    Runtime.receive
      runtime
      (target_response request ("[[" ^ Graph.Uuid.to_string block_uuid ^ "]]"))
  in
  Alcotest.(check int)
    "known cyclic root does not trigger another read"
    0
    (List.length output.requests);
  let changed_request =
    changed runtime (window ~blocks:[ target_uuid ] ()) |> check_target_request runtime
  in
  let failed =
    Runtime.receive
      runtime
      (response
         changed_request
         (Protocol.V2_failed
            { code = "InvalidRequest"; message = "temporary read failure" }))
  in
  Alcotest.(check bool)
    "failed target clears stale content"
    true
    (List.assoc_opt target_id (reference_updates failed) = Some None);
  ignore (changed runtime (window ~blocks:[ target_uuid ] ()) |> check_target_request runtime)
;;

let test_reference_invalidation_during_read () =
  List.iter
    (fun fail ->
       let runtime = Runtime.create () in
       let request = reference_feed runtime reference |> check_target_request runtime in
       let changed = changed runtime (window ~blocks:[ target_uuid ] ()) in
       Alcotest.(check int)
         "pending target invalidation coalesces"
         0
         (List.length (hydration_requests changed));
       let stale =
         Runtime.receive
           runtime
           (if fail
            then
              response
                request
                (Protocol.V2_failed
                   { code = "InvalidRequest"; message = "old snapshot failed" })
            else target_response request "Stale")
       in
       Alcotest.(check bool)
         "stale completion is not published"
         true
         (not (List.mem (target_id, Some "Stale") (reference_updates stale)));
       let fresh = check_target_request runtime stale in
       let result = Runtime.receive runtime (target_response fresh "Fresh") in
       Alcotest.(check (option string))
         "newest content wins"
         (Some "Fresh")
         (List.assoc_opt target_id (reference_updates result) |> Option.join))
    [ false; true ]
;;

let test_reference_to_loaded_block_shares_change_read () =
  let runtime = Runtime.create () in
  let id = Graph.Uuid.to_string block_uuid in
  let initial = reference_feed runtime ("Self [[" ^ id ^ "]]") in
  Alcotest.(check int)
    "loaded target needs no extra read"
    0
    (List.length initial.requests);
  let output = changed runtime (window ~blocks:[ block_uuid ] ()) in
  Alcotest.(check int)
    "loaded target shares its existing changed-block read"
    1
    (List.length (hydration_requests output))
;;

let test_abandoned_reference_can_refresh () =
  List.iter
    (fun fail ->
       let runtime = Runtime.create () in
       let request = reference_feed runtime reference |> check_target_request runtime in
       if fail
       then ignore (Runtime.fail_request runtime request ~message:"Worker interrupted")
       else Runtime.abandon runtime request;
       let late = Runtime.receive runtime (target_response request "Late completion") in
       Alcotest.(check int)
         "interrupted completion is unowned"
         0
         (List.length late.responses + List.length late.requests);
       let fresh =
         changed runtime (window ~blocks:[ target_uuid ] ()) |> check_target_request runtime
       in
       ignore (Runtime.receive runtime (target_response fresh "Recovered"));
       let duplicate = Runtime.fail_request runtime request ~message:"Late terminal" in
       Alcotest.(check int)
         "duplicate old terminal is unowned"
         0
         (List.length duplicate.responses + List.length duplicate.requests))
    [ false; true ]
;;

let test_shorter_reference_path_discovers_nested_targets () =
  let runtime = Runtime.create () in
  let id n = Printf.sprintf "a3000000-0000-4000-9000-%012d" n in
  let link n = "[[" ^ id n ^ "]]" in
  let output = ref (reference_feed runtime (link 1)) in
  for n = 1 to Journal_model.maximum_reference_depth do
    let request = only "chain point read" !output.requests |> outline_after_page_miss runtime in
    output
    := Runtime.receive
         runtime
         (response
            request
            (Protocol.V2_block_outcome
               (V2_present_block
                  { value =
                      { record with
                        block = { block with uuid = uuid (id n); title = link (n + 1) }
                      }
                  ; revision = "chain"
                  })))
  done;
  Alcotest.(check int) "deep chain stops at depth bound" 0 (List.length !output.requests);
  let output = reference_feed runtime (link Journal_model.maximum_reference_depth) in
  let request = only "shorter path discovers previously bounded target" output.requests in
  Alcotest.(check bool)
    "reads next nested target"
    true
    (request.Protocol.command
     = V2_get_page
         { page = uuid (id (Journal_model.maximum_reference_depth + 1))
         ; revision = None
         })
;;

let test_reference_burst_is_bounded () =
  let runtime = Runtime.create () in
  let source =
    String.concat
      " "
      (List.init 30 (fun index ->
         Printf.sprintf "[[a2000000-0000-4000-9000-%012x]]" index))
  in
  let output = reference_feed runtime source in
  Alcotest.(check int)
    "reference discovery shares four-read hydration budget"
    4
    (List.length output.requests);
  let request = List.hd output.requests in
  let output =
    Runtime.receive
      runtime
      (response
         request
         (Protocol.V2_page_outcome
            (V2_missing_page
               { uuid =
                   (match request.command with
                    | V2_get_page { page; _ } -> page
                    | _ -> assert false)
               ; revision = "missing"
               })))
  in
  Alcotest.(check int)
    "completion drains one queued lookup"
    1
    (List.length output.requests)
;;

let begin_reference_tree runtime generation =
  let request =
    Runtime.submit
      runtime
      (Journal_graph_request.Load_feed
         { cursor = None
         ; day_limit = 3
         ; root_limit = 4

         ; request_generation = generation
         })
    |> fun output -> only "reference journal request" output.requests
  in
  Runtime.receive
    runtime
    (response
       request
       (Protocol.V2_journals_outcome
          { items = [ { page; journal_day = 20260901; revision = "page" } ]
          ; next_cursor = None
          }))
  |> fun output -> only "reference tree request" output.requests
;;

let reference_tree_response request title =
  let root = { record with block = { block with title = reference } } in
  let target =
    { record with block = { block with uuid = target_uuid; title; order = "b" } }
  in
  response
    request
    (Protocol.V2_page_tree_outcome
       { page = page_uuid
       ; maximum_depth = 1
       ; next_cursor = None
       ; items =
           List.map
             (fun value ->
                Protocol.{ value; revision = title; depth = 0; parent = page_uuid })
             [ root; target ]
       })
;;

let test_stale_feed_cannot_replace_reference_source () =
  List.iter
    (fun fresh_title ->
       let runtime = Runtime.create () in
       set_calendar runtime;
       let initial = begin_reference_tree runtime 7L in
       ignore (Runtime.receive runtime (reference_tree_response initial "Initial"));
       let old = begin_reference_tree runtime 8L in
       let current = begin_reference_tree runtime 9L in
       ignore (Runtime.receive runtime (reference_tree_response current fresh_title));
       let changed_read =
         changed runtime (window ~blocks:[ target_uuid ] ()) |> check_target_request runtime
       in
       let stale = Runtime.receive runtime (reference_tree_response old "Stale") in
       Alcotest.(check bool)
         "invalidated old snapshot cannot publish source"
         false
         (List.mem (target_id, Some "Stale") (reference_updates stale));
       let fresh = Runtime.receive runtime (target_response changed_read fresh_title) in
       ignore fresh;
       let old = begin_reference_tree runtime 10L in
       let newer =
         changed runtime (window ~blocks:[ target_uuid ] ()) |> check_target_request runtime
       in
       ignore (Runtime.receive runtime (target_response newer fresh_title));
       let stale = Runtime.receive runtime (reference_tree_response old "Rollback") in
       Alcotest.(check bool)
         "newer completion fences older feed, even equal title"
         false
         (List.mem (target_id, Some "Rollback") (reference_updates stale)))
    [ "Fresh"; "Initial" ]
;;

let test_shared_change_failure_invalidates_reference () =
  let runtime = Runtime.create () in
  set_calendar runtime;
  let initial = begin_reference_tree runtime 7L in
  ignore (Runtime.receive runtime (reference_tree_response initial "Old"));
  let changed_read =
    changed runtime (window ~blocks:[ target_uuid ] ()) |> check_target_request runtime
  in
  let failed =
    Runtime.receive
      runtime
      (response
         changed_read
         (Protocol.V2_failed
            { code = "InvalidRequest"; message = "temporary shared read failure" }))
  in
  Alcotest.(check bool)
    "shared failure removes old source"
    true
    (List.mem (target_id, None) (reference_updates failed));
  let old = changed runtime (window ~blocks:[ target_uuid ] ()) |> check_target_request runtime in
  let newer =
    changed runtime (window ~blocks:[ target_uuid ] ()) |> check_target_request runtime
  in
  ignore (Runtime.receive runtime (target_response newer "Fresh"));
  let failed =
    Runtime.receive
      runtime
      (response
         old
         (Protocol.V2_failed { code = "InvalidRequest"; message = "late failure" }))
  in
  Alcotest.(check bool)
    "late failure cannot remove newer source"
    false
    (List.mem (target_id, None) (reference_updates failed));
  let retry =
    changed runtime (window ~blocks:[ target_uuid ] ()) |> check_target_request runtime
  in
  ignore (Runtime.receive runtime (target_response retry "Recovered"))
;;

let expect_admitted_failure description ~kind ~mutation_id ~block_id output =
  match (only description output.Runtime.responses).payload with
  | Runtime.Mutation_failed owner ->
    Alcotest.(check bool) "original mutation category" true (owner.kind = kind);
    Alcotest.(check string) "admitted mutation identity" mutation_id owner.mutation_id;
    Alcotest.(check string) "admitted block identity" block_id owner.block_id;
    (match owner.failure with
     | Worker_failure failure ->
       Alcotest.(check bool)
         "transport failure category"
         true
         (Logseq_db_worker.Error.code failure.error = Closed_session)
     | Projection_failure _ -> ())
  | _ -> Alcotest.fail (description ^ ": admitted owner was lost")
;;

let test_background_failure_keeps_sync_owner () =
  let runtime = Runtime.create () in
  seed_feed runtime;
  let request = pull runtime in
  let output = Runtime.fail_request runtime request ~message:"Background unavailable" in
  match (only "background failure" output.responses).payload with
  | Runtime.Rejected (Worker_failure _) -> ()
  | _ -> Alcotest.fail "background failure was attributed to a mutation"
;;

let test_capture_failure_keeps_admitted_owner () =
  let runtime, _, request = capture_format_read ~journal_day:20260901 in
  Runtime.fail_request runtime request ~message:"Admitted capture unavailable"
  |> expect_admitted_failure
       "capture failure"
       ~kind:Capture_mutation
       ~mutation_id:"a1000000-0000-4000-a000-0000000000c1"
       ~block_id:(Graph.Uuid.to_string block_uuid)
;;

let test_status_failure_keeps_admitted_owner () =
  let runtime = Runtime.create () in
  seed_feed runtime;
  let request =
    Runtime.submit
      runtime
      (Journal_graph_request.Set_task_state
         { mutation_id = "a1000000-0000-4000-a000-000000000071"
         ; block_id = Graph.Uuid.to_string block_uuid
         ; expected_revision = "block-1"
         ; task_state = Journal_model.Status "00000002-1827-5820-8200-000000000000"
         })
    |> fun output -> only "admitted status" output.requests
  in
  let followup =
    Runtime.receive
      runtime
      (response
         request
         (Protocol.V2_failed
            { code = Logseq_db_worker.Error.code_string Conflict; message = "Conflict" }))
    |> fun output -> only "admitted conflict refresh" output.requests
  in
  Runtime.fail_request runtime followup ~message:"Status refresh unavailable"
  |> expect_admitted_failure
       "status conflict refresh failure"
       ~kind:Status_mutation
       ~mutation_id:"a1000000-0000-4000-a000-000000000071"
       ~block_id:(Graph.Uuid.to_string block_uuid)
;;

let test_submit_rejections_keep_admitted_identity () =
  let runtime = Runtime.create () in
  let mutation_id = "invalid-admitted-mutation"
  and block_id = "invalid-admitted-block" in
  let check kind request =
    Runtime.submit runtime request
    |> expect_admitted_failure "submit rejection" ~kind ~mutation_id ~block_id
  in
  check
    Source_mutation
    (Journal_graph_request.Update_source
       { mutation_id; block_id; expected_revision = "old"; source = "Draft" });
  check
    Status_mutation
    (Journal_graph_request.Set_task_state
       { mutation_id
       ; block_id
       ; expected_revision = "old"
       ; task_state = Journal_model.Status "00000002-1827-5820-8200-000000000000"
       });
  check
    Delete_subtree_mutation
    (Journal_graph_request.Delete_subtree
       { mutation_id; block_id; expected_revision = "old" });
  let creation_time =
    Journal_time.create
      ~instant_unix_ms:1_788_192_000_000L
      ~local_day:20260901
      ~local_minute_of_day:0
    |> Result.get_ok
  in
  check
    Capture_mutation
    (Journal_graph_request.Capture
       { calendar_generation = 99L
       ; command =
           { mutation_id
           ; block_id
           ; sibling_order = "a"
           ; source = "Draft"
           ; task_state = No_status
           ; creation_time
           ; children = []
           ; status_confirmation = false
           }
       })
;;

let test_child_failure_retains_admitted_child () =
  let runtime = Runtime.create () in
  seed_children_interest runtime;
  let sampler =
    Journal_calendar.Sampler.create
      ~clock:(fun () -> 1_788_192_000.)
      ~localtime:Unix.gmtime
      ()
  in
  ignore (Journal_calendar.Sampler.sample sampler |> Result.get_ok);
  let calendar = Journal_calendar.Sampler.sample sampler |> Result.get_ok in
  Runtime.set_calendar runtime calendar;
  let mutation_id = "a1000000-0000-4000-a000-000000000081"
  and block_id = "a1000000-0000-4000-9000-000000000081" in
  let command : Journal_graph_projection.create_child =
    { mutation_id
    ; block_id
    ; parent_block_id = Graph.Uuid.to_string block_uuid
    ; calendar_generation = Journal_calendar.generation calendar
    ; expected_parent_revision = "block-detail-1"
    ; sibling_order = "a"
    ; source = "Child draft"
    ; task_state = No_status
    ; creation_time =
        Journal_time.create
          ~instant_unix_ms:1_788_192_000_000L
          ~local_day:20260901
          ~local_minute_of_day:0
        |> Result.get_ok
    ; status_confirmation = false
    }
  in
  let check output =
    match (only "child failure" output.Runtime.responses).payload with
    | Child_failed owner ->
      Alcotest.(check string) "admitted child" block_id owner.block_id;
      Alcotest.(check string) "admitted child mutation" mutation_id owner.mutation_id
    | _ -> Alcotest.fail "child failure lost admitted child owner"
  in
  check
    (Runtime.submit
       runtime
       (Journal_graph_request.Create_child { command with calendar_generation = 99L }));
  let request =
    Runtime.submit runtime (Journal_graph_request.Create_child command)
    |> fun output -> only "admitted child mutation" output.requests
  in
  check (Runtime.fail_request runtime request ~message:"Child unavailable");
  let duplicate = Runtime.fail_request runtime request ~message:"Late duplicate" in
  Alcotest.(check int)
    "duplicate error has no admitted owner"
    0
    (List.length duplicate.responses)
;;

module Copy = Runtime.Copy

let copy_read = function
  | [ Copy.Read (ticket, command) ] -> ticket, command
  | _ -> Alcotest.fail "Copy must issue one bounded subtree read"
;;

let copy_reply state effects outcome =
  let ticket, _ = copy_read effects in
  Copy.step state (Copy.Completed (ticket, outcome))
;;

let copy_start root =
  let state, effects = Copy.step Copy.initial (Copy.Start root) in
  Alcotest.(check bool)
    "Copy begins with graph version"
    true
    (snd (copy_read effects) = Protocol.V2_graph_info);
  let state, effects =
    copy_reply state effects (graph_info_outcome ~journal_title_format:None)
  in
  Alcotest.(check bool)
    "Copy reads selected root only"
    true
    (match snd (copy_read effects) with
     | Protocol.V2_get_outline_block { block; _ } -> Graph.Uuid.equal block root
     | _ -> false);
  state, effects
;;

let copy_children ?cursor ?(revision = "children-1") parent items =
  Protocol.V2_children_outcome
    { parent
    ; revision_scope = V2_children_revision parent
    ; scope_revision = revision
    ; items
    ; next_cursor = cursor
    }
;;

let copy_root state effects title =
  copy_reply
    state
    effects
    (Protocol.V2_block_outcome
       (V2_present_block
          { value = { record with block = { block with title } }; revision = "root-1" }))
;;

let copy_child id parent title : Protocol.v2_child_member =
  { value = { record with block = { block with uuid = id; parent; title } }
  ; revision = "child-1"
  }
;;

let copy_parent effects expected =
  match snd (copy_read effects) with
  | Protocol.V2_get_children { parent; limit; _ } ->
    Alcotest.(check bool)
      "selected subtree parent"
      true
      (Graph.Uuid.equal parent expected);
    Alcotest.(check bool) "bounded child page" true (limit <= Protocol.maximum_page_size)
  | _ -> Alcotest.fail "Copy attempted a read outside the selected subtree"
;;

let test_copy_nested_paginated_text () =
  let first = unrelated_uuid in
  let second = uuid "a1000000-0000-4000-9000-000000000002" in
  let nested = uuid "a1000000-0000-4000-9000-000000000003" in
  let cursor = Graph.Cursor.of_string "copy-page-2" |> Result.get_ok in
  let state, effects = copy_start block_uuid in
  let state, effects = copy_root state effects "Root\noriginal line" in
  copy_parent effects block_uuid;
  let state, effects =
    copy_reply
      state
      effects
      (copy_children ~cursor block_uuid [ copy_child first block_uuid "Child\n续行" ])
  in
  copy_parent effects block_uuid;
  Alcotest.(check bool)
    "all child pages requested"
    true
    (match snd (copy_read effects) with
     | Protocol.V2_get_children { cursor = Some value; _ } -> value = cursor
     | _ -> false);
  let state, effects =
    copy_reply
      state
      effects
      (copy_children block_uuid [ copy_child second block_uuid "" ])
  in
  copy_parent effects first;
  let state, effects =
    copy_reply state effects (copy_children first [ copy_child nested first "孙子😀" ])
  in
  copy_parent effects nested;
  let state, effects = copy_reply state effects (copy_children nested []) in
  copy_parent effects second;
  let state, effects = copy_reply state effects (copy_children second []) in
  Alcotest.(check bool)
    "verify graph version after complete subtree"
    true
    (snd (copy_read effects) = Protocol.V2_graph_info);
  let _, effects =
    copy_reply state effects (graph_info_outcome ~journal_title_format:None)
  in
  Alcotest.(check bool)
    "original root and all ordered descendants"
    true
    (effects = [ Copy.Copied "Root\noriginal line\n  - Child\n    续行\n    - 孙子😀\n  - " ])
;;

let test_copy_empty_and_root_whitespace () =
  List.iter
    (fun source ->
       let state, effects = copy_start block_uuid in
       let state, effects = copy_root state effects source in
       let state, effects = copy_reply state effects (copy_children block_uuid []) in
       let _, effects =
         copy_reply state effects (graph_info_outcome ~journal_title_format:None)
       in
       Alcotest.(check bool)
         "empty/whitespace root is copied exactly"
         true
         (effects = [ Copy.Copied source ]))
    [ ""; "  Root\n\n" ]
;;

let test_copy_cancel_and_replacement () =
  let state, effects = Copy.step Copy.initial (Copy.Start block_uuid) in
  let ticket, _ = copy_read effects in
  let canceled, effects = Copy.step state Copy.Cancel in
  Alcotest.(check bool) "cancel emits no clipboard result" true (effects = []);
  let _, effects =
    Copy.step
      canceled
      (Copy.Completed (ticket, graph_info_outcome ~journal_title_format:None))
  in
  Alcotest.(check bool) "late cancelled completion ignored" true (effects = []);
  let replacement, effects = Copy.step state (Copy.Start unrelated_uuid) in
  Alcotest.(check bool)
    "replacement uses a fresh ticket"
    true
    (fst (copy_read effects) <> ticket);
  let _, effects =
    Copy.step
      replacement
      (Copy.Completed (ticket, graph_info_outcome ~journal_title_format:None))
  in
  Alcotest.(check bool) "late replaced completion ignored" true (effects = [])
;;

let copy_expect_failure state effects outcome =
  let _, effects = copy_reply state effects outcome in
  Alcotest.(check bool)
    "failure never copies a partial subtree"
    true
    (match effects with
     | [ Copy.Failed message ] -> message <> ""
     | _ -> false)
;;

let test_copy_rejects_missing_failed_or_changed_graph () =
  let state, effects = copy_start block_uuid in
  let missing_state, missing_effects = copy_reply state effects
    (Protocol.V2_block_outcome (V2_missing_block {uuid=block_uuid;revision="missing"})) in
  copy_expect_failure missing_state missing_effects
    (Protocol.V2_page_outcome (V2_missing_page {uuid=block_uuid;revision="missing"}));
  let state, effects = copy_root state effects "Root" in
  copy_expect_failure
    state
    effects
    (Protocol.V2_failed { code = "staleReadCursor"; message = "Changed" });
  let ticket, _ = copy_read effects in
  let _, failed = Copy.step state (Copy.Read_failed (ticket, "Cancelled by Worker")) in
  Alcotest.(check bool)
    "worker failure never copies"
    true
    (match failed with
     | [ Copy.Failed _ ] -> true
     | _ -> false);
  let state, effects = copy_reply state effects (copy_children block_uuid []) in
  let changed =
    match graph_info_outcome ~journal_title_format:None with
    | Protocol.V2_graph_info_outcome info ->
      Protocol.V2_graph_info_outcome { info with projection_revision = "projection-2" }
    | _ -> assert false
  in
  copy_expect_failure state effects changed
;;

let test_copy_rejects_wrong_owner_cycle_and_cursor () =
  let state, effects = copy_start block_uuid in
  let state, effects = copy_root state effects "Root" in
  copy_expect_failure state effects (copy_children unrelated_uuid []);
  copy_expect_failure
    state
    effects
    (copy_children block_uuid [ copy_child block_uuid block_uuid "Cycle" ]);
  copy_expect_failure
    state
    effects
    (copy_children block_uuid [ copy_child unrelated_uuid page_uuid "Wrong parent" ]);
  let cursor = Graph.Cursor.of_string "repeated" |> Result.get_ok in
  let state, effects =
    copy_reply
      state
      effects
      (copy_children ~cursor block_uuid [ copy_child unrelated_uuid block_uuid "Child" ])
  in
  copy_expect_failure state effects (copy_children ~cursor block_uuid []);
  copy_expect_failure state effects (copy_children ~revision:"children-2" block_uuid [])
;;

let test_copy_rejects_oversized_text () =
  let state, effects = copy_start block_uuid in
  copy_expect_failure
    state
    effects
    (Protocol.V2_block_outcome
       (V2_present_block
          { value =
              { record with
                block = { block with title = String.make ((256 * 1024) + 1) 'x' }
              }
          ; revision = "root-1"
          }))
;;

let test_copy_result_fits_serialized_clipboard () =
  let maximum = 256 * 1024 in
  let complete source =
    let state, effects = copy_start block_uuid in
    let state, effects = copy_root state effects source in
    let state, effects = copy_reply state effects (copy_children block_uuid []) in
    snd (copy_reply state effects (graph_info_outcome ~journal_title_format:None))
  in
  let check source effects =
    match Journal_platform.copy_text_request ~text:source with
    | Ok _ ->
      Alcotest.(check bool)
        "encodable text is copied exactly"
        true
        (effects = [ Copy.Copied source ])
    | Error _ ->
      Alcotest.(check bool)
        "unencodable JSON never produces Copied"
        true
        (match effects with
         | [ Copy.Failed message ] -> message <> ""
         | _ -> false)
  in
  List.iter
    (fun source -> check source (complete source))
    [ String.make maximum 'x'
    ; String.make (maximum - 11) 'x'
    ; String.make (maximum - 10) 'x'
    ; String.make (maximum / 2) '"'
    ; String.make (maximum / 2) '\\'
    ; String.make (maximum / 2) '\n'
    ; String.make (maximum / 6) '\001'
    ; String.make ((maximum - 11) / 2) '\n' ^ "a"
    ; String.make ((maximum - 11) / 2) '\n' ^ "ab"
    ];
  List.iter
    (fun root_length ->
       let root = String.make root_length 'x' in
       let child = copy_child unrelated_uuid block_uuid "\"" in
       let state, effects = copy_start block_uuid in
       let state, effects = copy_root state effects root in
       let state, effects =
         copy_reply state effects (copy_children block_uuid [ child ])
       in
       let state, effects = copy_reply state effects (copy_children unrelated_uuid []) in
       let _, effects =
         copy_reply state effects (graph_info_outcome ~journal_title_format:None)
       in
       check (root ^ "\n  - \"") effects)
    [ maximum - 19; maximum - 18 ]
;;

let seed_ordinary_detail runtime =
  set_calendar runtime;
  let ordinary_page =
    { page with kind = Ordinary_page; name = "reference"; title = "Reference" }
  in
  let request =
    Runtime.submit
      runtime
      (Journal_graph_request.Load_detail
         { block_id = Graph.Uuid.to_string block_uuid
         ; after = None
         ; limit = 3
         ; request_generation = 91L
         })
    |> fun output -> only "ordinary detail root" output.requests
  in
  let request =
    Runtime.receive
      runtime
      (response
         request
         (Protocol.V2_block_outcome
            (V2_present_block { value = record; revision = "root-1" })))
    |> fun output -> only "ordinary detail page" output.requests
  in
  let request =
    Runtime.receive
      runtime
      (response
         request
         (Protocol.V2_page_outcome
            (V2_present_page { page = ordinary_page; revision = "page-1" })))
    |> fun output -> only "ordinary detail children" output.requests
  in
  let child =
    { record with
      block = { block with uuid = unrelated_uuid; title = "Child"; parent = block_uuid }
    }
  in
  ignore
    (Runtime.receive
       runtime
       (response
          request
          (Protocol.V2_children_outcome
             { parent = block_uuid
             ; revision_scope = V2_children_revision block_uuid
             ; scope_revision = "children-1"
             ; items = [ { value = child; revision = "child-1" } ]
             ; next_cursor = None
             })));
  ordinary_page, child
;;

let test_ordinary_detail_point_change child_changed =
  let runtime = Runtime.create () in
  let _, child = seed_ordinary_detail runtime in
  let value = if child_changed then child else record in
  let output = changed runtime (window ~blocks:[ value.block.uuid ] ()) in
  let request = only "ordinary detail changed identity" (hydration_requests output) in
  (match request.command with
   | V2_get_outline_block { block; _ } ->
     Alcotest.(check bool)
       "only changed identity"
       true
       (Graph.Uuid.equal block value.block.uuid)
   | _ -> Alcotest.fail "ordinary detail did not point-read its changed identity");
  let output =
    Runtime.receive
      runtime
      (response
         request
         (Protocol.V2_block_outcome
            (V2_present_block
               { value =
                   { value with block = { value.block with title = "Updated detail" } }
               ; revision = "detail-2"
               })))
  in
  let published =
    List.find_map
      (fun result ->
         match result.Runtime.payload with
         | Block_updated { block; _ } -> Some block
         | _ -> None)
      output.responses
  in
  match published with
  | Some block ->
    Alcotest.(check string)
      "fresh ordinary detail source"
      "Updated detail"
      (Journal_model.source block)
  | None -> Alcotest.fail "ordinary detail changed identity did not publish"
;;

let test_detail_children_uses_latest_root () =
  let runtime = Runtime.create () in
  seed_children_interest runtime;
  let output =
    changed
      runtime
      (window
         ~blocks:[ block_uuid ]
         ~scopes:[ Protocol.V2_children_interest block_uuid ]
         ())
  in
  let point =
    List.find
      (fun (request : Protocol.request) ->
         match request.command with
         | V2_get_outline_block _ -> true
         | _ -> false)
      (hydration_requests output)
  in
  let children =
    List.find
      (fun (request : Protocol.request) ->
         match request.command with
         | V2_get_children _ -> true
         | _ -> false)
      (hydration_requests output)
  in
  ignore
    (Runtime.receive
       runtime
       (response
          point
          (Protocol.V2_block_outcome
             (V2_present_block
                { value = { record with block = { block with title = "Fresh root" }; tag_titles = [ "Fresh tags" ] }
                ; revision = "root-2"
                }))));
  let output =
    Runtime.receive
      runtime
      (response
         children
         (Protocol.V2_children_outcome
            { parent = block_uuid
            ; revision_scope = V2_children_revision block_uuid
            ; scope_revision = "children-2"
            ; items = []
            ; next_cursor = None
            }))
  in
  match
    List.find_map
      (fun result ->
         match result.Runtime.payload with
         | Children_reconciled detail -> Some detail
         | _ -> None)
      output.responses
  with
  | Some detail ->
    Alcotest.(check string)
      "children must not restore stale root"
      "Fresh root"
      (Journal_model.source detail.root)
    ; Alcotest.(check (list string)) "reconciled Detail keeps latest root tags"
        [ "Fresh tags" ] (Journal_model.tag_titles detail.root)
  | None -> Alcotest.fail "changed children were not reconciled"
;;

let test_detail_resync_reads_latest_root () =
  let runtime = Runtime.create () in
  ignore (seed_ordinary_detail runtime);
  let output =
    Runtime.reconcile_push
      runtime
      ~request_generation:12L
      (Protocol.V2_resync_required_push
         { api_version = Protocol.api_version
         ; generation = "generation-2"
         ; reason = "overflow"
         })
  in
  Alcotest.(check bool)
    "resync must rehydrate ordinary detail root content"
    true
    (List.exists
       (fun (request : Protocol.request) ->
          match request.command with
          | V2_get_outline_block { block; _ } -> Graph.Uuid.equal block block_uuid
          | _ -> false)
       output.requests)
;;

let favorites_page_uuid = uuid "a1000000-0000-4000-8000-000000000009"
let membership_uuid = uuid "a1000000-0000-4000-9000-000000000009"
let ancestor_uuid = uuid "a1000000-0000-4000-9000-000000000008"

let seed_favorite_dependencies
      ?(negative = false)
      ?(before_target = fun () -> ())
      ?(target_title = fun _ -> block.title)
      ?(on_output = fun (_ : Runtime.output) -> ())
      runtime
  =
  set_calendar runtime;
  let request : Journal_graph_request.favorites_request =
    { graph_generation = 1; request_generation = 1L; limit = 50; cursor = None }
  in
  let read =
    Runtime.submit runtime (Journal_graph_request.Load_favorites request)
    |> fun output -> only "favorites read" output.requests
  in
  let output =
    Runtime.receive
      runtime
      (response
         read
         (Protocol.V2_favorites_outcome
            { favorites_page = Some favorites_page_uuid
            ; generation = "generation-1"
            ; projection_revision = "revision-1"
            ; items =
                (if negative
                 then []
                 else
                   [ { membership_uuid
                     ; membership_order = "a"
                     ; membership_revision = "membership-1"
                     ; target =
                         V2_favorite_block
                           { uuid = block_uuid
                           ; title = block.title
                           ; task_status = None
                           ; revision = "root-1"
                           }
                     }
                   ])
            ; next_cursor = None
            }))
  in
  let visited = ref [] in
  let target_reads = ref 0 in
  let rec drain requests =
    match requests with
    | [] -> ()
    | (request : Protocol.request) :: rest ->
      let outcome =
        match request.command with
        | V2_get_children { parent; _ } when Graph.Uuid.equal parent favorites_page_uuid
          ->
          Protocol.V2_children_outcome
            { parent
            ; revision_scope = V2_children_revision parent
            ; scope_revision = "favorites-memberships-1"
            ; items =
                [ { value =
                      { record with
                        block =
                          { block with uuid = membership_uuid; parent; page = parent }
                      }
                  ; revision = "membership-1"
                  }
                ]
            ; next_cursor = None
            }
        | V2_get_outline_block { block = id; _ } ->
          visited := Graph.Uuid.to_string id :: !visited;
          let value =
            if Graph.Uuid.equal id block_uuid
            then (
              incr target_reads;
              if !target_reads = 1 then before_target ();
              { record with
                block =
                  { block with
                    parent = ancestor_uuid
                  ; title = target_title !target_reads
                  }
              })
            else if Graph.Uuid.equal id ancestor_uuid
            then
              { record with
                block = { block with uuid = ancestor_uuid; parent = page_uuid }
              }
            else Alcotest.fail "dependency read escaped favorite ancestry"
          in
          Protocol.V2_block_outcome
            (V2_present_block { value; revision = "dependency-1" })
        | V2_get_page { page = id; _ } when Graph.Uuid.equal id page_uuid ->
          Protocol.V2_page_outcome (V2_present_page { page; revision = "page-1" })
        | _ -> Alcotest.fail "favorite dependency used an unbounded discovery request"
      in
      let output = Runtime.receive runtime (response request outcome) in
      on_output output;
      let pending = rest @ output.requests in
      check_hydration_bound pending;
      drain pending
  in
  check_hydration_bound output.requests;
  drain output.requests;
  !visited
;;

let invalidates_favorites output =
  List.exists
    (fun result ->
       match result.Runtime.payload with
       | Favorites_invalidated -> true
       | _ -> false)
    output.Runtime.responses
;;

let test_favorite_dependencies_are_read () =
  let runtime = Runtime.create () in
  let visited = seed_favorite_dependencies runtime in
  Alcotest.(check (list string))
    "favorite target and ancestors resolved using bounded point reads"
    (List.sort
       String.compare
       [ Graph.Uuid.to_string block_uuid; Graph.Uuid.to_string ancestor_uuid ])
    (List.sort_uniq String.compare visited)
;;

let test_favorite_pending_target_change_is_rechecked () =
  let runtime = Runtime.create () in
  let invalidated = ref false in
  let visited =
    seed_favorite_dependencies
      runtime
      ~before_target:(fun () ->
        let output = changed runtime (window ~blocks:[ block_uuid ] ()) in
        Alcotest.(check int)
          "held point query retains one slot"
          0
          (List.length (hydration_requests output)))
      ~target_title:(fun count -> if count = 1 then block.title else "Fresh favorite")
      ~on_output:(fun output ->
        invalidated := !invalidated || invalidates_favorites output)
  in
  Alcotest.(check int)
    "owned target change rechecks once after old completion"
    2
    (List.length (List.filter (String.equal (Graph.Uuid.to_string block_uuid)) visited));
  Alcotest.(check bool) "fresh target title invalidates old Favorites" true !invalidated
;;

let test_negative_favorite_membership_intersects () =
  let runtime = Runtime.create () in
  ignore (seed_favorite_dependencies ~negative:true runtime);
  Alcotest.(check bool)
    "negative membership is retained as a dependency"
    true
    (invalidates_favorites (changed runtime (window ~blocks:[ membership_uuid ] ())))
;;

let test_favorite_changes_locality () =
  let runtime = Runtime.create () in
  ignore (seed_favorite_dependencies runtime);
  let request = pull runtime in
  let output =
    Runtime.receive
      runtime
      (response
         request
         (Protocol.V2_changes
            { generation = "generation-1"
            ; from_exclusive = Some "revision-1"
            ; through = "revision-2"
            ; windows = [ window ~blocks:[ unrelated_uuid ] () ]
            ; next = None
            }))
  in
  Alcotest.(check bool)
    "unrelated owned changes preserve favorites"
    false
    (invalidates_favorites output);
  List.iter
    (fun window ->
       Alcotest.(check bool)
         "membership intersection invalidates favorites"
         true
         (invalidates_favorites (changed runtime window)))
    [ window ~blocks:[ membership_uuid ] ()
    ; window ~scopes:[ Protocol.V2_children_interest favorites_page_uuid ] ()
    ];
  List.iter
    (fun (window, outcome) ->
       let runtime = Runtime.create () in
       ignore (seed_favorite_dependencies runtime);
       let out = changed runtime window in
       Alcotest.(check bool)
         "dependency facts are rechecked before invalidating"
         false
         (invalidates_favorites out);
       let read = only "bounded dependency recheck" (hydration_requests out) in
       let out = Runtime.receive runtime (response read outcome) in
       Alcotest.(check bool)
         "changed target or eligibility invalidates favorites"
         true
         (invalidates_favorites out))
    [ ( window ~blocks:[ block_uuid ] ()
      , Protocol.V2_block_outcome
          (V2_present_block
             { value =
                 { record with
                   block = { block with parent = ancestor_uuid; title = "Fresh favorite" }
                 }
             ; revision = "favorite-2"
             }) )
    ; ( window ~blocks:[ ancestor_uuid ] ()
      , Protocol.V2_block_outcome
          (V2_missing_block { uuid = ancestor_uuid; revision = "missing-2" }) )
    ; ( window ~pages:[ page_uuid ] ()
      , Protocol.V2_page_outcome
          (V2_present_page { page = { page with recycled = true }; revision = "page-2" })
      )
    ]
;;

let test_favorite_sibling_structure_is_local () =
  let runtime = Runtime.create () in
  ignore (seed_favorite_dependencies runtime);
  let output =
    changed
      runtime
      (window
         ~blocks:[ unrelated_uuid ]
         ~pages:[ page_uuid ]
         ~scopes:
           [ Protocol.V2_children_interest page_uuid; V2_page_tree_interest page_uuid ]
         ())
  in
  Alcotest.(check bool)
    "Capture sibling window preserves Favorites"
    false
    (invalidates_favorites output);
  List.iter
    (fun (request : Protocol.request) ->
       match request.command with
       | V2_get_page { page = id; _ } when Graph.Uuid.equal id page_uuid ->
         let output =
           Runtime.receive
             runtime
             (response
                request
                (Protocol.V2_page_outcome (V2_present_page { page; revision = "page-2" })))
         in
         Alcotest.(check bool)
           "unchanged live ancestor preserves Favorites"
           false
           (invalidates_favorites output)
       | _ -> Alcotest.fail "sibling change escaped bounded ancestor point read")
    (hydration_requests output)
;;

let test_favorite_ancestor_title_is_local () =
  let runtime = Runtime.create () in
  ignore (seed_favorite_dependencies runtime);
  let output = changed runtime (window ~blocks:[ ancestor_uuid ] ()) in
  Alcotest.(check bool)
    "ancestor window rechecks first"
    false
    (invalidates_favorites output);
  let read = only "ancestor point read" (hydration_requests output) in
  let output =
    Runtime.receive
      runtime
      (response
         read
         (Protocol.V2_block_outcome
            (V2_present_block
               { value =
                   { record with
                     block =
                       { block with
                         uuid = ancestor_uuid
                       ; parent = page_uuid
                       ; title = "Renamed ancestor"
                       }
                   }
               ; revision = "ancestor-2"
               })))
  in
  Alcotest.(check bool)
    "ancestor title does not alter favorite membership"
    false
    (invalidates_favorites output)
;;

let test_favorite_dependency_limit () =
  let runtime = Runtime.create () in
  set_calendar runtime;
  let request : Journal_graph_request.favorites_request =
    { graph_generation = 1; request_generation = 1L; limit = 50; cursor = None }
  in
  let read =
    Runtime.submit runtime (Journal_graph_request.Load_favorites request)
    |> fun out -> only "favorites" out.requests
  in
  let output =
    Runtime.receive
      runtime
      (response
         read
         (Protocol.V2_favorites_outcome
            { favorites_page = Some favorites_page_uuid
            ; generation = "generation-1"
            ; projection_revision = "revision-1"
            ; items = []
            ; next_cursor = None
            }))
  in
  let rec drain batch requests =
    if batch > 20 then Alcotest.fail "Favorite dependencies exceeded 4096 without failure";
    let read = only "bounded membership page" requests in
    let items =
      List.init 200 (fun offset ->
        let uuid =
          uuid (Printf.sprintf "a2000000-0000-4000-8000-%012d" ((batch * 200) + offset))
        in
        Protocol.
          { value =
              { record with
                block =
                  { block with
                    uuid
                  ; parent = favorites_page_uuid
                  ; page = favorites_page_uuid
                  }
              }
          ; revision = "member-1"
          })
    in
    let next_cursor =
      Some (Graph.Cursor.of_string (Printf.sprintf "members-%d" batch) |> Result.get_ok)
    in
    let out =
      Runtime.receive
        runtime
        (response
           read
           (Protocol.V2_children_outcome
              { parent = favorites_page_uuid
              ; revision_scope = V2_children_revision favorites_page_uuid
              ; scope_revision = "members-1"
              ; items
              ; next_cursor
              }))
    in
    if
      List.exists
        (fun result ->
           match result.Runtime.payload with
           | Rejected _ -> true
           | _ -> false)
        out.responses
    then Alcotest.(check int) "failure stops discovery" 0 (List.length out.requests)
    else drain (batch + 1) out.requests
  in
  drain 0 output.requests
;;

let test_projection_changes_are_owned () =
  let runtime = Runtime.create () in
  let output =
    Runtime.reconcile_push
      runtime
      ~request_generation:11L
      (Protocol.V2_changes_available
         { api_version = Protocol.api_version
         ; generation = "generation-1"
         ; through = "revision-2"
         })
  in
  Alcotest.(check bool)
    "push emits no premature projection invalidation"
    false
    (invalidates_favorites output);
  let request = only "owned changes pull" output.requests in
  let change = window ~blocks:[ unrelated_uuid ] () in
  let completion =
    response
      request
      (Protocol.V2_changes
         { generation = "generation-1"
         ; from_exclusive = None
         ; through = "revision-2"
         ; windows = [ change ]
         ; next = None
         })
  in
  let output = Runtime.receive runtime completion in
  Alcotest.(check int)
    "owned changes publish once"
    1
    (List.fold_left
       (fun count result ->
          match result.Runtime.payload with
          | Projection_changes [ actual ] when actual = change -> count + 1
          | _ -> count)
       0
       output.responses);
  Alcotest.(check int)
    "duplicate completion publishes nothing"
    0
    (List.length (Runtime.receive runtime completion).responses);
  let output =
    Runtime.reconcile_push
      runtime
      ~request_generation:12L
      (Protocol.V2_resync_required_push
         { api_version = Protocol.api_version
         ; generation = "generation-2"
         ; reason = "overflow"
         })
  in
  Alcotest.(check bool)
    "real resync emits projection resync"
    true
    (List.exists
       (fun result ->
          match result.Runtime.payload with
          | Projection_resync -> true
          | _ -> false)
       output.responses);
  Alcotest.(check bool)
    "real resync invalidates favorites"
    true
    (invalidates_favorites output)
;;

let feed_window_request runtime ~days ~slots:_ =
  Runtime.submit
    runtime
    (Journal_graph_request.Load_feed
       { cursor = None
       ; day_limit = days
       ; root_limit = 1

       ; request_generation = 7L
       })
  |> fun output -> only "journal window request" output.requests
;;

let journal_request_limit request =
  match request.Protocol.command with
  | V2_list_journals { limit; _ } -> limit
  | _ -> Alcotest.fail "expected journal listing"
;;

let test_feed_window_fits_encoded_response_budget () =
  let runtime = Runtime.create () in
  let request = feed_window_request runtime ~days:7 ~slots:128 in
  let property : Graph.property_summary =
    { ident = "fixture/property"
    ; uuid = unrelated_uuid
    ; title = String.make 2048 'p'
    ; schema =
        { property_type = String; cardinality = One; hidden = false; public = true }
    ; values = [ String_value "complete value" ]
    ; values_truncated = false
    }
  in
  let item n : Protocol.v2_journal_item =
    let id = uuid (Printf.sprintf "a3000000-0000-4000-8000-%012d" n) in
    { page = { page with uuid = id; properties = [ property ] }
    ; journal_day = 20260901
    ; revision = "page-window-revision"
    }
  in
  let encoded count =
    response
      request
      (V2_journals_outcome { items = List.init count item; next_cursor = None })
    |> Protocol.encoded_response_bytes
  in
  Alcotest.(check bool)
    "full 200-item metadata batch exceeds real byte budget"
    true
    (encoded Protocol.maximum_page_size > Protocol.maximum_response_bytes);
  Alcotest.(check bool)
    "requested feed metadata fits unchanged byte budget"
    true
    (encoded (journal_request_limit request) <= Protocol.maximum_response_bytes);
  Alcotest.(check int)
    "read only the seven requested days"
    7
    (journal_request_limit request)
;;

let test_feed_continuation_reads_only_missing_days () =
  let runtime = Runtime.create () in
  set_calendar ~clock:1_788_278_400. runtime;
  let first = feed_window_request runtime ~days:3 ~slots:16 in
  let cursor = Graph.Cursor.of_string "journal-after-one" |> Result.get_ok in
  let valid : Protocol.v2_journal_item = {page;journal_day=20260901;revision="journal-first"} in
  let output = Runtime.receive runtime (response first (V2_journals_outcome
      {items=[valid;{valid with page={page with recycled=true}}];next_cursor=Some cursor})) in
  let tree=only "resolve available date before fetching more metadata" output.requests in
  let output=Runtime.receive runtime (response tree (V2_page_tree_outcome
      {page=page_uuid;maximum_depth=0;items=[];next_cursor=None})) in
  let next=only "continue journal cursor after empty date" output.requests in
  (match next.command with
   | V2_list_journals {limit;cursor=Some actual;_} ->
     Alcotest.(check int) "metadata packet independent of root demand" 3 limit;
     Alcotest.(check bool) "opaque date cursor retained" true (actual=cursor)
   | _ -> Alcotest.fail "lost date continuation");
  let completed=Runtime.receive runtime (response next (V2_journals_outcome {items=[];next_cursor=None})) in
  match (only "exhausted empty dates complete" completed.responses).payload with
  | Feed_loaded {feed;complete=true;_} ->
    Alcotest.(check bool) "true exhaustion" false (Option.is_some feed.continuation);
    Alcotest.(check int) "empty dates consume no roots" 0 (List.length feed.days)
  | _ -> Alcotest.fail "lost complete empty feed"
;;

let test_feed_window_bounds_and_singleton_failure () =
  List.iter
    (fun (days, slots, expected) ->
       let runtime = Runtime.create () in
       let request = feed_window_request runtime ~days ~slots in
       Alcotest.(check int)
         "day, slot and protocol bounds"
         expected
         (journal_request_limit request))
    [ 1, 2, 1; 10, 6, 10; 500, 1000, Protocol.maximum_page_size ];
  let runtime = Runtime.create () in
  let request = feed_window_request runtime ~days:1 ~slots:2 in
  let oversized_page =
    { page with
      properties =
        List.init 5 (fun n ->
          { Graph.ident = Printf.sprintf "fixture/large-property-%d" n
          ; uuid = uuid (Printf.sprintf "a4000000-0000-4000-8000-%012d" n)
          ; title = String.make Protocol.maximum_title_bytes 'x'
          ; schema =
              { property_type = String; cardinality = One; hidden = false; public = true }
          ; values = []
          ; values_truncated = false
          })
    }
  in
  let oversized =
    response
      request
      (V2_journals_outcome
         { items =
             [ { page = oversized_page
               ; journal_day = 20260901
               ; revision = "large-singleton"
               }
             ]
         ; next_cursor = None
         })
  in
  Alcotest.(check bool)
    "one complete oversized item cannot fit"
    true
    (Protocol.encoded_response_bytes oversized > Protocol.maximum_response_bytes);
  let failed =
    Runtime.receive
      runtime
      (response
         request
         (V2_failed
            { code = "responseTooLarge"
            ; message = "The encoded read response exceeded its byte limit."
            }))
  in
  Alcotest.(check int) "no automatic singleton retry loop" 0 (List.length failed.requests);
  match (only "visible singleton failure" failed.responses).payload with
  | Feed_failed { failure = Worker_failure failure; _ } ->
    Alcotest.(check string)
      "failure keeps operation identity"
      "listTimelineDates"
      failure.operation
  | _ -> Alcotest.fail "oversized singleton was hidden or truncated"
;;


(* Timeline preview ownership is exposed by Runtime's public requests and
   completions. Raw member reads/counts and Detail/Copy have separate owners. *)
let check_preview count (entry : Journal_graph_projection.timeline_entry) =
  Alcotest.(check int)
    "actual child count retained"
    count
    (Journal_model.child_count entry.block);
  Alcotest.(check int)
    "at most three projected child summaries"
    (min 3 count)
    (List.length entry.child_summaries);
  Alcotest.(check (list string))
    "first three ordered child summaries"
    (List.init (min 3 count) (fun n -> Printf.sprintf "Canonical child %d" n))
    (List.map
       (fun (summary : Journal_graph_projection.child_summary) -> summary.source)
       entry.child_summaries)
;;

let test_bounded_preview_tree_paths () =
  let count = 199 in
  let children = summary_children count in
  let root : Protocol.v2_tree_member =
    { value = record; revision = "root-1"; depth = 0; parent = page_uuid }
  in
  let items =
    root
    :: List.rev_map
         (fun (child : Protocol.v2_child_member) ->
            Protocol.
              { value = child.value
              ; revision = child.revision
              ; depth = 1
              ; parent = block_uuid
              })
         children
  in
  let runtime = Runtime.create ~localtime:Unix.gmtime () in
  set_calendar runtime;
  let journals =
    Runtime.submit
      runtime
      (Journal_graph_request.Load_feed
         { cursor = None
         ; day_limit = 1
         ; root_limit = 200

         ; request_generation = 7L
         })
    |> fun o -> only "preview feed journals" o.requests
  in
  let tree =
    Runtime.receive
      runtime
      (response
         journals
         (Protocol.V2_journals_outcome
            { items = [ { page; journal_day = 20260901; revision = "page-1" } ]
            ; next_cursor = None
            }))
    |> fun o -> only "preview feed tree" o.requests
  in
  let cursor = Graph.Cursor.of_string "preview-next-page" |> Result.get_ok in
  let feed = Runtime.receive runtime (tree_page tree items (Some cursor)) in
  let day =
    List.find_map
      (fun r ->
         match r.Runtime.payload with
         | Feed_loaded { feed; _ } -> Some (List.hd feed.days)
         | _ -> None)
      feed.responses
    |> Option.get
  in
  check_preview 3 (only "feed entry" day.entries);
  let day_read =
    Runtime.submit
      runtime
      (Journal_graph_request.Load_day_blocks
         { day = 20260901
         ; after = day.continuation
         ; limit = 200
         ; request_generation = 8L
         })
    |> fun o -> only "preview day continuation" o.requests
  in
  (match day_read.command with
   | V2_get_page_tree { cursor = Some actual; _ } ->
     Alcotest.(check bool) "paging cursor unchanged" true (actual = cursor)
   | _ -> Alcotest.fail "preview cap changed day paging");
  let day_result = Runtime.receive runtime (tree_page day_read items None) in
  (match (only "preview day result" day_result.responses).payload with
   | Feed_loaded {feed;complete=true;_} -> check_preview 3 (only "day entry" (List.hd feed.days).entries)
   | _ -> Alcotest.fail "preview day result lost owner");
  let changed_output =
    changed runtime (window ~scopes:[ Protocol.V2_page_tree_interest page_uuid ] ())
  in
  let refresh = only "preview remote structure" (hydration_requests changed_output) in
  let remote = Runtime.receive runtime (tree_page refresh items None) in
  (match (only "preview remote result" remote.responses).payload with
   | Page_tree_reconciled { value; _ } ->
     check_preview 3 (only "remote entry" value.entries)
   | _ -> Alcotest.fail "preview remote result lost owner");
  (* Delete conflict exercises the legacy page-tree refresh projection rather
     than canonical target-summary confirmation. *)
  let runtime, _, refresh = prepare_paged_refresh Delete_conflict in
  let legacy = Runtime.receive runtime (tree_page refresh items None) in
  let value =
    List.find_map
      (fun r ->
         match r.Runtime.payload with
         | Page_tree_reconciled { value; _ } -> Some value
         | _ -> None)
      legacy.responses
    |> Option.get
  in
  check_preview count (only "legacy refresh entry" value.entries)
;;

let test_bounded_preview_target_pages kind count () =
  let runtime, page, first = target_refresh kind in
  let canonical =
    { record with block = { block with page = page.uuid; parent = page.uuid } }
  in
  let lookup =
    Protocol.V2_present_block { value = canonical; revision = "canonical-2" }
  in
  let children = summary_children ~page:page.uuid count in
  let rec complete request cursor batch = function
    | [] ->
      Runtime.receive
        runtime
        (summary_response request page lookup [] None "projection-2")
    | remaining ->
      check_target_summary request cursor;
      let items = List.take Protocol.default_page_size remaining in
      let tail = List.drop Protocol.default_page_size remaining in
      let next =
        if tail = []
        then None
        else
          Some
            (Graph.Cursor.of_string (Printf.sprintf "preview-target-%d" batch)
             |> Result.get_ok)
      in
      let output =
        Runtime.receive
          runtime
          (summary_response request page lookup items next "projection-2")
      in
      (match next with
       | None -> output
       | Some _ ->
         Alcotest.(check int)
           "all raw pages complete before confirmation"
           0
           (List.length output.responses);
         complete
           (only "unchanged target child continuation" output.requests)
           next
           (batch + 1)
           tail)
  in
  let output = complete first None 0 children in
  let entry =
    List.find_map
      (fun r ->
         match r.Runtime.payload with
         | Block_captured { timeline_entry_update = Some entry; _ }
         | Block_updated { timeline_entry_update = Some entry; _ } -> Some entry
         | _ -> None)
      output.responses
    |> Option.get
  in
  check_preview count entry
;;

let test_preview_preserves_full_detail_and_copy () =
  let count = 199 in
  let children =
    summary_children count
    |> List.mapi (fun index (child : Protocol.v2_child_member) ->
      if index = 0
      then
        { child with
          Protocol.value =
            { child.value with
              block = { child.value.block with properties = [ asset_type_property ] }
            }
        }
      else child)
  in
  let root = { record with block = { block with title = "" } } in
  let runtime = Runtime.create ~localtime:Unix.gmtime () in
  set_calendar runtime;
  let journals =
    Runtime.submit
      runtime
      (Journal_graph_request.Load_feed
         { cursor = None
         ; day_limit = 1
         ; root_limit = 200

         ; request_generation = 7L
         })
    |> fun output -> only "hidden parent feed" output.requests
  in
  let tree =
    Runtime.receive
      runtime
      (response
         journals
         (V2_journals_outcome
            { items = [ { page; journal_day = 20260901; revision = "page-1" } ]
            ; next_cursor = None
            }))
    |> fun output -> only "hidden parent tree" output.requests
  in
  let items =
    { Protocol.value = root; revision = "root-1"; depth = 0; parent = page_uuid }
    :: List.map
         (fun (child : Protocol.v2_child_member) ->
            Protocol.
              { value = child.value
              ; revision = child.revision
              ; depth = 1
              ; parent = block_uuid
              })
         children
  in
  let output = Runtime.receive runtime (tree_page tree items None) in
  (match (only "hidden parent projected" output.responses).payload with
   | Feed_loaded { feed; _ } ->
     Alcotest.(check int)
       "child image cannot retain empty parent"
       0
       (List.fold_left (fun n (d:Journal_graph_projection.day_feed)->n+List.length d.entries) 0 feed.days)
   | _ -> Alcotest.fail "hidden parent feed failed");
  let root_read =
    Runtime.submit
      runtime
      (Journal_graph_request.Load_detail
         { block_id = Graph.Uuid.to_string block_uuid
         ; after = None
         ; limit = 200
         ; request_generation = 99L
         })
    |> fun o -> only "complete Detail root" o.requests
  in
  let child_read =
    Runtime.receive
      runtime
      (response
         root_read
         (Protocol.V2_block_outcome
            (V2_present_block { value = root; revision = "root-1" })))
    |> fun o -> only "complete Detail children" o.requests
  in
  let output =
    Runtime.receive runtime (response child_read (copy_children block_uuid children))
  in
  (match (only "complete Detail" output.responses).payload with
   | Detail_loaded { detail; _ } ->
     Alcotest.(check int)
       "Detail retains all raw children"
       count
       (List.length detail.children.blocks);
     Alcotest.(check string)
       "Detail retains final child text"
       "Canonical child 198"
       (Journal_model.source (List.nth detail.children.blocks 198))
   | _ -> Alcotest.fail "complete Detail result lost owner");
  let state, effects = copy_start block_uuid in
  let state, effects = copy_root state effects root.block.title in
  let state, effects = copy_reply state effects (copy_children block_uuid children) in
  let state, effects =
    List.fold_left
      (fun (state, effects) (child : Protocol.v2_child_member) ->
         copy_parent effects child.Protocol.value.block.uuid;
         copy_reply state effects (copy_children child.value.block.uuid []))
      (state, effects)
      children
  in
  let _, effects =
    copy_reply state effects (graph_info_outcome ~journal_title_format:None)
  in
  Alcotest.(check bool)
    "Copy retains every original child, without preview truncation"
    true
    (effects
     = [ Copy.Copied
           (root.block.title
            ^ String.concat
                ""
                (List.map
                   (fun (c : Protocol.v2_child_member) -> "\n  - " ^ c.value.block.title)
                   children))
       ])
;;

(* Runtime owns Timeline projection; canonical hidden roots remain available
   to mutation completion, Detail and Copy through the same existing reads. *)
let parent_visibility_fixture (page : Graph.page) =
  let property ident property_type values =
    { asset_type_property with
      ident
    ; schema = { asset_type_property.schema with property_type }
    ; values
    }
  in
  let root n title properties tags tag_titles task_status =
    { record with
      block =
        { block with
          uuid = uuid (Printf.sprintf "a5000000-0000-4000-8000-%012d" n)
        ; title
        ; page = page.Graph.uuid
        ; parent = page.uuid
        ; order = Printf.sprintf "a%02d" n
        ; properties
        ; tags
        }
    ; tag_titles
    ; task_status
    }
  in
  let tag = uuid "a5000000-0000-4000-b000-000000000001" in
  let child_id n j = uuid (Printf.sprintf "a5000000-0000-4000-9000-%06d%06d" n j) in
  let own_asset = property "logseq.property/asset" Asset [ Asset_value (child_id 1 4) ] in
  let status =
    property
      "logseq.property/status"
      Default
      [ Default_value "logseq.property/status.doing" ]
  in
  let roots =
    [ false, root 1 " \t\n" [] [] [] None
    ; true, root 2 "Visible parent" [] [] [] None
    ; true, root 3 "" [] [ tag ] [ "Work" ] None
    ; true, root 4 "" [ asset_type_property ] [] [] None
    ; ( true
      , root
          5
          ""
          [ { asset_type_property with values = [ String_value "pdf" ] } ]
          []
          []
          None )
    ; true, root 6 "" [ own_asset ] [] [] None
    ; ( false
      , root
          7
          ""
          [ status ]
          []
          []
          (Some
             (Logseq_db_types.Graph_types.Uuid.of_string
                "00000002-1840-1229-0800-000000000000"
              |> Result.get_ok)) )
    ; ( true
      , root
          8
          ""
          [ status ]
          [ tag ]
          [ "Task" ]
          (Some
             (Logseq_db_types.Graph_types.Uuid.of_string
                "00000002-1840-1229-0800-000000000000"
              |> Result.get_ok)) )
    ]
  in
  let children n parent =
    List.init 4 (fun offset ->
      let j = offset + 1 in
      { Protocol.value =
          { record with
            block =
              { block with
                uuid = child_id n j
              ; page = page.uuid
              ; parent
              ; order = Printf.sprintf "a%d" j
              ; title = (if j = 4 then "Child image" else " ")
              ; properties = (if j = 4 then [ asset_type_property ] else [])
              }
          }
      ; revision = "child-1"
      })
  in
  let items =
    List.mapi
      (fun index (_, root) ->
         { Protocol.value = root; revision = "root-1"; depth = 0; parent = page.uuid }
         :: List.map
              (fun (child : Protocol.v2_child_member) ->
                 Protocol.
                   { value = child.value
                   ; revision = child.revision
                   ; depth = 1
                   ; parent = root.block.uuid
                   })
              (children (index + 1) root.block.uuid))
      roots
    |> List.concat
  in
  roots, children, items
;;

let check_parent_visibility roots entries =
  let expected =
    List.filter_map
      (fun (visible, r) ->
         if visible then Some (Graph.Uuid.to_string r.Protocol.block.uuid) else None)
      roots
  in
  Alcotest.(check (list string))
    "only parent text, tags or attachments qualify"
    expected
    (List.map
       (fun (e : Journal_graph_projection.timeline_entry) -> Journal_model.id e.block)
       entries);
  let feed : Journal_graph_projection.feed =
    { days =
        [ { page =
              { id = Graph.Uuid.to_string page_uuid; day = 20260901; title = page.title }
          ; entries
          ; has_more_entries = false
          ; continuation = None
          }
        ]
    ; slot_count = 1 + List.length entries
    ; continuation = None; prioritized_day = None
    }
  in
  let state =
    Journal_timeline_state.empty ~today:20260902
    |> fun s ->
    Journal_timeline_state.begin_request s ~generation:1L (Feed { cursor = None })
    |> fun s -> Journal_timeline_state.apply_feed s ~generation:1L feed
  in
  let shown =
    Journal_timeline_state.fold_slots
      (fun ids -> function
         | Top_level e -> Journal_model.id e.block :: ids
         | _ -> ids)
      []
      state
    |> List.rev
  in
  Alcotest.(check (list string))
    "tag/attachment metadata survives Timeline state"
    expected
    shown
;;

let test_parent_visibility_tree_paths () =
  let roots, _, items = parent_visibility_fixture page in
  let runtime = Runtime.create ~localtime:Unix.gmtime () in
  set_calendar runtime;
  let journals =
    Runtime.submit
      runtime
      (Journal_graph_request.Load_feed
         { cursor = None
         ; day_limit = 1
         ; root_limit = 200

         ; request_generation = 7L
         })
    |> fun o -> only "visibility feed" o.requests
  in
  let tree =
    Runtime.receive
      runtime
      (response
         journals
         (V2_journals_outcome
            { items = [ { page; journal_day = 20260901; revision = "page-1" } ]
            ; next_cursor = None
            }))
    |> fun o -> only "visibility tree" o.requests
  in
  let cursor = Graph.Cursor.of_string "visibility-next" |> Result.get_ok in
  let output = Runtime.receive runtime (tree_page tree items (Some cursor)) in
  let day =
    List.find_map
      (fun r ->
         match r.Runtime.payload with
         | Feed_loaded { feed; _ } -> Some (List.hd feed.days)
         | _ -> None)
      output.responses
    |> Option.get
  in
  check_parent_visibility roots day.entries;
  let read =
    Runtime.submit
      runtime
      (Journal_graph_request.Load_day_blocks
         { day = 20260901
         ; after = day.continuation
         ; limit = 200
         ; request_generation = 8L
         })
    |> fun o -> only "visibility continuation" o.requests
  in
  let output = Runtime.receive runtime (tree_page read items None) in
  (match (only "visibility day" output.responses).payload with
   | Feed_loaded {feed;complete=true;_} -> check_parent_visibility roots (List.hd feed.days).entries
   | _ -> Alcotest.fail "visibility day owner lost");
  let refresh =
    changed runtime (window ~scopes:[ V2_page_tree_interest page_uuid ] ())
    |> hydration_requests
    |> only "visibility remote"
  in
  (match
     (only
        "visibility remote output"
        (Runtime.receive runtime (tree_page refresh items None)).responses)
       .payload
   with
   | Page_tree_reconciled { value; _ } -> check_parent_visibility roots value.entries
   | _ -> Alcotest.fail "visibility remote owner lost");
  let runtime, _, refresh = prepare_paged_refresh Delete_conflict in
  let output = Runtime.receive runtime (tree_page refresh items None) in
  let entries =
    List.find_map
      (fun r ->
         match r.Runtime.payload with
         | Page_tree_reconciled { value; _ } -> Some value.entries
         | _ -> None)
      output.responses
    |> Option.get
  in
  check_parent_visibility roots entries
;;

let test_parent_visibility_confirmations () =
  List.iter
    (fun kind ->
       List.iter
         (fun (visible, index) ->
            let runtime, page, refresh = target_refresh kind in
            let roots, children, _ = parent_visibility_fixture page in
            let _, canonical = List.nth roots index in
            let canonical =
              { canonical with block = { canonical.block with uuid = block_uuid } }
            in
            let output =
              Runtime.receive
                runtime
                (summary_response
                   refresh
                   page
                   (V2_present_block { value = canonical; revision = "canonical-2" })
                   (children (index + 1) block_uuid)
                   None
                   "projection-2")
            in
            let actual, entry =
              List.find_map
                (fun r ->
                   match r.Runtime.payload with
                   | Block_captured { block; timeline_entry_update }
                   | Block_updated { block; timeline_entry_update } ->
                     Some (block, timeline_entry_update)
                   | _ -> None)
                output.responses
              |> Option.get
            in
            Alcotest.(check bool)
              "canonical parent visibility"
              visible
              (Option.is_some entry);
            Alcotest.(check int)
              "hidden completion retains raw children"
              4
              (Journal_model.child_count actual);
            Alcotest.(check int)
              "no new attachment or amplified read"
              0
              (List.length output.requests))
         (List.mapi
            (fun index (v, _) -> v, index)
            (let roots, _, _ = parent_visibility_fixture page in
             roots)))
    [ `Capture; `Update; `Status ]
;;


(* The public runtime owner must discover properties only on Detail demand,
   sharing the existing deduplicated reference cache with ordinary text. *)
let test_detail_property_reference_reads_are_deduplicated () =
  let runtime=Runtime.create () in
  seed_feed runtime;
  let property:Graph.property_summary=
    {ident="user.property/repro";uuid=unrelated_uuid;title="Reproducible?"
    ;schema={property_type=Default;cardinality=Many;hidden=false;public=false}
    ;values=[Default_value (Graph.Uuid.to_string unrelated_uuid);Default_value (Graph.Uuid.to_string unrelated_uuid)]
    ;values_truncated=false} in
  let root={record with block={block with properties=[property]}} in
  let read=Runtime.submit runtime (Journal_graph_request.Load_detail
    {block_id=Graph.Uuid.to_string block_uuid;after=None;limit=128;request_generation=91L})
    |> fun o->only "property root read" o.requests in
  let child=Runtime.receive runtime (response read (Protocol.V2_block_outcome
    (V2_present_block {value=root;revision="root-with-properties"})))
    |> fun o->only "property child read" o.requests in
  let children=Protocol.V2_children_outcome
    {parent=block_uuid;revision_scope=V2_children_revision block_uuid;scope_revision="children-1";items=[];next_cursor=None} in
  let output=Runtime.receive runtime (response child children) in
  let reference=only "one deduplicated closed property reference" output.requests
    |> outline_after_page_miss runtime in
  (match reference.command with
   |Protocol.V2_get_outline_block {block;_}->Alcotest.(check string) "closed value UUID"
      (Graph.Uuid.to_string unrelated_uuid) (Graph.Uuid.to_string block)
   |_ ->Alcotest.fail "property value must use the existing bounded block read");
  let closed={record with block={block with uuid=unrelated_uuid;title="Yes";properties=[]}} in
  let output=Runtime.receive runtime (response reference (Protocol.V2_block_outcome
    (V2_present_block {value=closed;revision="closed-1"}))) in
  Alcotest.(check int) "no repeated reference read" 0 (List.length output.requests);
  Alcotest.(check bool) "closed value enters reference presentation cache" true
    (List.exists (fun (r:Runtime.response)->match r.payload with
      |Reference_sources_changed values->List.mem (Graph.Uuid.to_string unrelated_uuid,Some "Yes") values
      |_ ->false) output.responses)
;;

let test_changed_journal_detail_discovers_property_reference () =
  let runtime = Runtime.create () in
  seed_children_interest runtime;
  let property : Graph.property_summary =
    { ident = "user.property/repro"
    ; uuid = uuid "a1000000-0000-4000-8000-000000000012"
    ; title = "Reproducible?"
    ; schema = { property_type=Default; cardinality=One; hidden=false; public=false }
    ; values = [Default_value (Graph.Uuid.to_string unrelated_uuid)]
    ; values_truncated = false } in
  let output = changed runtime (window ~blocks:[block_uuid] ()) in
  let request = only "changed active journal detail" (hydration_requests output) in
  let output = Runtime.receive runtime (response request
    (Protocol.V2_block_outcome (V2_present_block
      {value={record with block={block with properties=[property]}}; revision="block-2"}))) in
  let reference = only "new property reference after sync" output.requests in
  match reference.command with
   | Protocol.V2_get_page {page=block;_} -> Alcotest.(check string) "new closed value"
       (Graph.Uuid.to_string unrelated_uuid) (Graph.Uuid.to_string block)
  | _ -> Alcotest.fail "sync did not use the owned reference reader"
;;

let test_materialized_detail_leaf_discovers_property_reference () =
  let runtime = Runtime.create () in
  seed_feed runtime;
  let leaf_uuid = uuid "a1000000-0000-4000-9000-000000000013" in
  let leaf =
    { record with
      block =
        { block with uuid = leaf_uuid; parent = block_uuid; title = "Materialized leaf" }
    }
  in
  let root =
    Runtime.submit
      runtime
      (Journal_graph_request.Load_detail
         { block_id = Graph.Uuid.to_string block_uuid
         ; after = None
         ; limit = 128
         ; request_generation = 41L
         })
    |> fun o -> only "materialized root" o.requests
  in
  let children =
    Runtime.receive
      runtime
      (response
         root
         (Protocol.V2_block_outcome
            (V2_present_block { value = record; revision = "root-1" })))
    |> fun o -> only "materialized parent page" o.requests
  in
  ignore
    (Runtime.receive
       runtime
       (response
          children
          (Protocol.V2_children_outcome
             { parent = block_uuid
             ; revision_scope = V2_children_revision block_uuid
             ; scope_revision = "children-1"
             ; items = [ { value = leaf; revision = "leaf-1" } ]
             ; next_cursor = None
             })));
  (* This node is displayed, but no own children page is requested: exactly
     the runtime ownership state of a depth/budget boundary Detail leaf. *)
  let property : Graph.property_summary =
    { ident = "user.property/repro"
    ; uuid = uuid "a1000000-0000-4000-8000-000000000012"
    ; title = "Reproducible?"
    ; schema =
        { property_type = Default; cardinality = One; hidden = false; public = false }
    ; values = [ Default_value (Graph.Uuid.to_string unrelated_uuid) ]
    ; values_truncated = false
    }
  in
  let update =
    changed runtime (window ~blocks:[ leaf_uuid ] ())
    |> fun o -> only "materialized leaf sync" (hydration_requests o)
  in
  let output =
    Runtime.receive
      runtime
      (response
         update
         (Protocol.V2_block_outcome
            (V2_present_block
               { value =
                   { leaf with block = { leaf.block with properties = [ property ] } }
               ; revision = "leaf-2"
               })))
  in
  let read = only "displayed leaf property demand" output.requests in
  match read.command with
  | Protocol.V2_get_page { page=block; _ } ->
    Alcotest.(check string)
      "leaf closed value UUID"
      (Graph.Uuid.to_string unrelated_uuid)
      (Graph.Uuid.to_string block)
  | _ -> Alcotest.fail "materialized Detail leaf did not demand its property"
;;

let test_timeline_only_property_update_does_not_hydrate () =
  let runtime = Runtime.create () in
  seed_feed runtime;
  let property : Graph.property_summary =
    { ident = "user.property/repro"
    ; uuid = uuid "a1000000-0000-4000-8000-000000000012"
    ; title = "Reproducible?"
    ; schema =
        { property_type = Default; cardinality = One; hidden = false; public = false }
    ; values = [ Default_value (Graph.Uuid.to_string unrelated_uuid) ]
    ; values_truncated = false
    }
  in
  let update =
    changed runtime (window ~blocks:[ block_uuid ] ())
    |> fun o -> only "Timeline-only sync" (hydration_requests o)
  in
  let output =
    Runtime.receive
      runtime
      (response
         update
         (Protocol.V2_block_outcome
            (V2_present_block
               { value = { record with block = { block with properties = [ property ] } }
               ; revision = "root-2"
               })))
  in
  Alcotest.(check int)
    "Timeline alone must not hydrate property values"
    0
    (List.length output.requests)
;;

let test_detail_child_property_reference_without_child_load () =
  let runtime = Runtime.create () in
  seed_feed runtime;
  let property : Graph.property_summary =
    { ident = "user.property/reference"
    ; uuid = uuid "a1000000-0000-4000-8000-000000000012"
    ; title = "Reference"
    ; schema = { property_type = Node; cardinality = One; hidden = false; public = false }
    ; values = [ Node_value unrelated_uuid ]
    ; values_truncated = false
    }
  in
  let leaf =
    { record with
      block =
        { block with
          uuid = uuid "a1000000-0000-4000-9000-000000000013"
        ; parent = block_uuid
        ; title = "Leaf"
        ; properties = [ property ]
        }
    }
  in
  let root =
    Runtime.submit
      runtime
      (Journal_graph_request.Load_detail
         { block_id = Graph.Uuid.to_string block_uuid
         ; after = None
         ; limit = 128
         ; request_generation = 41L
         })
    |> fun o -> only "child property root" o.requests
  in
  let children =
    Runtime.receive
      runtime
      (response
         root
         (Protocol.V2_block_outcome
            (V2_present_block { value = record; revision = "root-1" })))
    |> fun o -> only "child property page" o.requests
  in
  let output =
    Runtime.receive
      runtime
      (response
         children
         (Protocol.V2_children_outcome
            { parent = block_uuid
            ; revision_scope = V2_children_revision block_uuid
            ; scope_revision = "children-1"
            ; items = [ { value = leaf; revision = "leaf-1" } ]
            ; next_cursor = None
            }))
  in
  let request = only "returned child property demand" output.requests in
  match request.command with
  | Protocol.V2_get_page { page=block; _ } ->
    Alcotest.(check bool)
      "child property target"
      true
      (Graph.Uuid.equal block unrelated_uuid)
  | _ -> Alcotest.fail "child field was left unresolved until own children load"
;;

let test_detail_page_and_class_property_uses_page_lookup () =
  List.iter
    (fun (typ, value) ->
       let runtime = Runtime.create () in
       seed_feed runtime;
       let property : Graph.property_summary =
         { ident = "user.property/page"
         ; uuid = block_uuid
         ; title = "Page reference"
         ; schema =
             { property_type = typ; cardinality = Many; hidden = false; public = false }
         ; values = [ value; value ]
         ; values_truncated = false
         }
       in
       let read =
         Runtime.submit
           runtime
           (Journal_graph_request.Load_detail
              { block_id = Graph.Uuid.to_string block_uuid
              ; after = None
              ; limit = 128
              ; request_generation = 91L
              })
         |> fun o -> only "page property root" o.requests
       in
       let children =
         Runtime.receive
           runtime
           (response
              read
              (Protocol.V2_block_outcome
                 (V2_present_block
                    { value =
                        { record with block = { block with properties = [ property ] } }
                    ; revision = "root-1"
                    })))
         |> fun o -> only "page property children" o.requests
       in
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
       let read = only "one deduplicated page value" output.requests in
       (match read.command with
        | Protocol.V2_get_page { page; _ } ->
          Alcotest.(check bool)
            "typed page UUID"
            true
            (Graph.Uuid.equal page unrelated_uuid)
        | _ -> Alcotest.fail "page/class property was routed to a block lookup");
       let output =
         Runtime.receive
           runtime
           (response
              read
              (Protocol.V2_page_outcome
                 (V2_present_page
                    { page =
                        { page with
                          uuid = unrelated_uuid
                        ; title = "Visible page title"
                        ; kind = Class_page
                        }
                    ; revision = "page-value-1"
                    })))
       in
       Alcotest.(check int) "no duplicate page read" 0 (List.length output.requests);
       Alcotest.(check bool)
         "page title published"
         true
         (List.exists
            (fun (r : Runtime.response) ->
               match r.payload with
               | Reference_sources_changed values ->
                 List.mem
                   (Graph.Uuid.to_string unrelated_uuid, Some "Visible page title")
                   values
               | _ -> false)
            output.responses);
       let update =
         changed runtime (window ~pages:[ unrelated_uuid ] ())
         |> fun o -> only "changed page property value" (hydration_requests o)
       in
       (match update.command with
        | Protocol.V2_get_page _ -> ()
        | _ -> Alcotest.fail "page value change did not invalidate the typed cache");
       let output =
         Runtime.receive
           runtime
           (response
              update
              (Protocol.V2_page_outcome
                 (V2_present_page
                    { page =
                        { page with
                          uuid = unrelated_uuid
                        ; title = "Updated title"
                        ; kind = Class_page
                        }
                    ; revision = "page-value-2"
                    })))
       in
       Alcotest.(check bool)
         "updated page title published"
         true
         (List.exists
            (fun (r : Runtime.response) ->
               match r.payload with
               | Reference_sources_changed values ->
                 List.mem
                   (Graph.Uuid.to_string unrelated_uuid, Some "Updated title")
                   values
               | _ -> false)
            output.responses))
    [ Graph.Page, Graph.Page_value unrelated_uuid
    ; Graph.Class, Graph.Class_value unrelated_uuid
    ]
;;

let test_page_property_promotes_prior_block_reference () =
  List.iter (fun pending ->
    let runtime=Runtime.create () in
    let tree=initial_tree runtime in
    let title="See [[" ^ Graph.Uuid.to_string unrelated_uuid ^ "]]" in
    let root : Protocol.v2_tree_member =
      {value={record with block={block with title}};revision="root-1";depth=0;parent=page_uuid} in
    let first=Runtime.receive runtime (tree_page tree [root] None)
      |> fun o -> only "initial generic page reference" o.requests
      |> outline_after_page_miss runtime in
       (match first.command with
        | Protocol.V2_get_outline_block _ -> ()
        | _ -> Alcotest.fail "expected generic block lookup");
    if not pending then ignore (Runtime.receive runtime (response first (Protocol.V2_block_outcome
      (V2_missing_block {uuid=unrelated_uuid;revision="missing-1"}))));
    let property : Graph.property_summary =
      {ident="user.property/page";uuid=block_uuid;title="Actual page"
      ;schema={property_type=Page;cardinality=One;hidden=false;public=false}
      ;values=[Page_value unrelated_uuid];values_truncated=false} in
    let read=Runtime.submit runtime (Journal_graph_request.Load_detail
      {block_id=Graph.Uuid.to_string block_uuid;after=None;limit=128;request_generation=91L})
      |> fun o -> only "promoted Detail root" o.requests in
    let children=Runtime.receive runtime (response read (Protocol.V2_block_outcome
      (V2_present_block {value={record with block={block with properties=[property]}};revision="root-2"})))
      |> fun o -> only "promoted Detail children" o.requests in
    let output=Runtime.receive runtime (response children (Protocol.V2_children_outcome
      {parent=block_uuid;revision_scope=V2_children_revision block_uuid;scope_revision="children-1";items=[];next_cursor=None})) in
    let output=if pending then (
      Alcotest.(check int) "retain one pending reference read" 0 (List.length output.requests);
      Runtime.receive runtime (response first (Protocol.V2_block_outcome
        (V2_missing_block {uuid=unrelated_uuid;revision="missing-1"})))) else output in
    let page_read=only "page type supersedes old block missing/pending cache" output.requests in
    (match page_read.command with
     |Protocol.V2_get_page {page;_}->Alcotest.(check bool) "promoted UUID" true (Graph.Uuid.equal page unrelated_uuid)
     |_ -> Alcotest.fail "semantic page type did not supersede the generic block lookup");
    let output=Runtime.receive runtime (response page_read (Protocol.V2_page_outcome
      (V2_present_page {page={page with uuid=unrelated_uuid;title="Actual page title";kind=Ordinary_page};revision="actual-page-1"}))) in
    Alcotest.(check bool) "promoted title published" true (List.exists (fun (r:Runtime.response)->match r.payload with
      |Reference_sources_changed values->List.mem (Graph.Uuid.to_string unrelated_uuid,Some "Actual page title") values
      |_ ->false) output.responses)) [false;true]
;;

let test_changed_tree_all_property_slice_continues () =
  let runtime = Runtime.create () in
  seed_feed runtime;
  let read =
    changed runtime (window ~scopes:[ Protocol.V2_page_tree_interest page_uuid ] ())
    |> fun o -> only "property-only changed tree" (hydration_requests o)
  in
  let marker : Graph.property_summary =
    { ident = "logseq.property/created-from-property"
    ; uuid = unrelated_uuid
    ; title = "Created from property"
    ; schema =
        { property_type = Entity; cardinality = One; hidden = true; public = false }
    ; values = [ Entity_value unrelated_uuid ]
    ; values_truncated = false
    }
  in
  let cursor = Graph.Cursor.of_string "after-property-only-slice" |> Result.get_ok in
  let root : Protocol.v2_tree_member =
    { value =
        { record with
          block = { block with title = "Property value"; properties = [ marker ] }
        }
    ; revision = "property-1"
    ; depth = 0
    ; parent = page_uuid
    }
  in
  let output = Runtime.receive runtime (tree_page read [ root ] (Some cursor)) in
  Alcotest.(check int)
    "do not replace day with a filtered empty slice"
    0
    (List.length output.responses);
  let next = only "continue past property roots" output.requests in
  (match next.command with
   | Protocol.V2_get_page_tree { cursor = Some actual; _ } ->
     Alcotest.(check string)
       "same opaque cursor"
       (Graph.Cursor.to_string cursor)
       (Graph.Cursor.to_string actual)
   | _ -> Alcotest.fail "lost property-only continuation");
  let ordinary : Protocol.v2_tree_member =
    { value = record; revision = "root-2"; depth = 0; parent = page_uuid }
  in
  let output = Runtime.receive runtime (tree_page next [ ordinary ] None) in
  Alcotest.(check bool)
    "later ordinary root retained"
    true
    (List.exists
       (fun (r : Runtime.response) ->
          match r.payload with
          | Page_tree_reconciled { value; _ } ->
            List.length value.entries = 1 && value.continuation = None
          | _ -> false)
       output.responses)
;;

(* The runtime owns reference discovery and its private cache; exercise its
   public requests/completions instead of injecting an application cache result. *)
let expect_reference_page output id =
  let request = only "one deduplicated page-first request" (hydration_requests output) in
  Alcotest.(check bool) "page lookup precedes outline lookup" true
    (request.Protocol.command = V2_get_page { page = id; revision = None });
  request
;;

let missing_reference_page runtime request id =
  Runtime.receive runtime
    (response request (Protocol.V2_page_outcome
      (V2_missing_page { uuid = id; revision = "page-absent" })))
;;

let expect_reference_outline output id =
  let request = only "one outline fallback after explicit page miss" (hydration_requests output) in
  Alcotest.(check bool) "outline target" true
    (request.Protocol.command = V2_get_outline_block { block = id; revision = None });
  request
;;

let reference_page_response ?(recycled = false) request kind title =
  response request (Protocol.V2_page_outcome
    (V2_present_page { page = { page with uuid = target_uuid; kind; title; recycled }
      ; revision = "resolved-page" }))
;;

let test_reference_page_first_resolves_pages () =
  List.iter (fun kind ->
    let runtime = Runtime.create () in
    let request = reference_feed runtime (reference ^ " " ^ reference)
      |> fun output -> expect_reference_page output target_uuid in
    let resolved = Runtime.receive runtime
      (reference_page_response request kind "2026-09-01") in
    Alcotest.(check (option string)) "actual page title is published"
      (Some "2026-09-01") (List.assoc_opt target_id (reference_updates resolved) |> Option.join);
    Alcotest.(check int) "present page never queries outline" 0 (List.length resolved.requests);
    let cached = reference_feed runtime reference in
    Alcotest.(check int) "positive page source is reused" 0 (List.length cached.requests);
    let refresh = changed runtime (window ~pages:[target_uuid] ())
      |> fun output -> expect_reference_page output target_uuid in
    let updated = Runtime.receive runtime (reference_page_response refresh kind "Edited page") in
    Alcotest.(check (option string)) "page change invalidates typed cache"
      (Some "Edited page") (List.assoc_opt target_id (reference_updates updated) |> Option.join))
    [Graph.Journal_page {journal_day=20260901}; Ordinary_page]
;;

let test_reference_page_miss_then_outline () =
  let runtime = Runtime.create () in
  let page_read = reference_feed runtime reference
    |> fun output -> expect_reference_page output target_uuid in
  let fallback = missing_reference_page runtime page_read target_uuid in
  Alcotest.(check bool) "page miss is not a negative target result" false
    (List.mem (target_id,None) (reference_updates fallback));
  let outline = expect_reference_outline fallback target_uuid in
  Alcotest.(check int) "duplicate source joins pending fallback" 0
    (List.length (reference_feed runtime (reference ^ " " ^ reference)).requests);
  let resolved = Runtime.receive runtime (target_response outline "Outline body") in
  Alcotest.(check (option string)) "outline source resolves after page absence"
    (Some "Outline body") (List.assoc_opt target_id (reference_updates resolved) |> Option.join);
  Alcotest.(check int) "positive outline source is reused" 0
    (List.length (reference_feed runtime reference).requests)
;;

let test_reference_negative_cache_requires_both_misses () =
  let runtime = Runtime.create () in
  let page_read = reference_feed runtime reference
    |> fun output -> expect_reference_page output target_uuid in
  let fallback = missing_reference_page runtime page_read target_uuid in
  let outline = expect_reference_outline fallback target_uuid in
  let missing = Runtime.receive runtime (response outline (Protocol.V2_block_outcome
    (V2_missing_block {uuid=target_uuid;revision="outline-absent"}))) in
  Alcotest.(check bool) "both misses publish unavailable source" true
    (List.mem (target_id,None) (reference_updates missing));
  Alcotest.(check int) "both misses are cached" 0
    (List.length (reference_feed runtime reference).requests)
;;

let test_reference_errors_and_cancellation_retry_page_first () =
  List.iter (fun outline_stage -> List.iter (fun terminal ->
    let runtime=Runtime.create () in
    let first=reference_feed runtime reference
      |> fun output->expect_reference_page output target_uuid in
    let current=if outline_stage then
      missing_reference_page runtime first target_uuid |> fun output->expect_reference_outline output target_uuid
      else first in
    let failed = match terminal with
      | 0 -> Runtime.receive runtime (response current
          (Protocol.V2_failed {code="StorageBusy";message="transient"}))
      | 1 -> Runtime.fail_request runtime current ~message:"Worker cancelled"
      | _ -> Runtime.abandon runtime current; {Runtime.requests=[];responses=[]} in
    Alcotest.(check int) "failure/cancel is not page absence" 0 (List.length failed.requests);
    let retry=reference_feed runtime reference
      |> fun output->expect_reference_page output target_uuid in
    let late=Runtime.receive runtime (reference_page_response first Ordinary_page "Late") in
    Alcotest.(check int) "old terminal cannot complete the retry" 0
      (List.length late.requests+List.length late.responses);
    let fresh=Runtime.receive runtime (reference_page_response retry Ordinary_page "Recovered") in
    Alcotest.(check (option string)) "retry is not poisoned by negative cache"
      (Some "Recovered") (List.assoc_opt target_id (reference_updates fresh) |> Option.join)) [0;1;2]) [false;true]
;;

let test_reference_reset_discards_both_stages () =
  List.iter (fun outline_stage ->
    let runtime=Runtime.create () in
    let first=reference_feed runtime reference |> fun output->expect_reference_page output target_uuid in
    let old=if outline_stage then missing_reference_page runtime first target_uuid
      |> fun output->expect_reference_outline output target_uuid else first in
    Runtime.reset runtime;
    let fresh=reference_feed runtime reference |> fun output->expect_reference_page output target_uuid in
    let late=Runtime.receive runtime
      (if outline_stage then target_response old "Old graph"
       else reference_page_response old Ordinary_page "Old graph") in
    Alcotest.(check int) "reset rejects old graph completion" 0
      (List.length late.requests+List.length late.responses);
    let result=Runtime.receive runtime (reference_page_response fresh Ordinary_page "New graph") in
    Alcotest.(check (option string)) "new graph owns source"
      (Some "New graph") (List.assoc_opt target_id (reference_updates result) |> Option.join)) [false;true]
;;

let test_reference_invalidation_restarts_page_phase () =
  List.iter (fun outline_stage ->
    let runtime=Runtime.create () in
    let first=reference_feed runtime reference |> fun output->expect_reference_page output target_uuid in
    let current=if outline_stage then missing_reference_page runtime first target_uuid
      |> fun output->expect_reference_outline output target_uuid else first in
    let invalidated=changed runtime (window ~pages:[target_uuid] ()) in
    Alcotest.(check int) "in-flight invalidations coalesce" 0
      (List.length (hydration_requests invalidated));
    let stale=Runtime.receive runtime
      (if outline_stage then target_response current "Stale"
       else response current (Protocol.V2_page_outcome
         (V2_missing_page {uuid=target_uuid;revision="old-page-miss"}))) in
    Alcotest.(check bool) "stale phase never publishes" false
      (List.mem (target_id,Some "Stale") (reference_updates stale));
    let refresh=expect_reference_page stale target_uuid in
    let result=Runtime.receive runtime (reference_page_response refresh Ordinary_page "Fresh") in
    Alcotest.(check (option string)) "invalidation restarts from page"
      (Some "Fresh") (List.assoc_opt target_id (reference_updates result) |> Option.join)) [false;true]
;;

let test_reference_fallback_keeps_original_epoch () =
  let runtime=Runtime.create () in
  let old=reference_feed runtime reference |> fun output->expect_reference_page output target_uuid in
  let newer=begin_reference_tree runtime 20L in
  let newest = Runtime.receive runtime (reference_tree_response newer "Newer fragment") in
  Alcotest.(check (option string)) "newer fragment publishes source"
    (Some "Newer fragment") (List.assoc_opt target_id (reference_updates newest) |> Option.join);
  let fallback=missing_reference_page runtime old target_uuid in
  let completed=match hydration_requests fallback with
    | [] -> fallback
    | [_] -> Runtime.receive runtime (target_response
        (expect_reference_outline fallback target_uuid) "Older fallback")
    | _ -> Alcotest.fail "duplicate fallback" in
  Alcotest.(check bool) "old two-stage lookup cannot replace a newer fragment" false
    (List.mem (target_id,Some "Older fallback") (reference_updates completed));
  let cached=reference_feed runtime reference in
  Alcotest.(check int) "newer cached source remains available without a retry"
    0 (List.length cached.requests);
  Alcotest.(check bool) "older missing result cannot clear a newer source" false
    (List.mem (target_id,None) (reference_updates completed))
;;

let test_reference_two_stage_burst_stays_bounded () =
  let runtime=Runtime.create () in
  let source=String.concat " " (List.init 30 (fun n->
    Printf.sprintf "[[a4000000-0000-4000-9000-%012d]]" n)) in
  let pending=Queue.create () in
  List.iter (fun request->Queue.push request pending) (reference_feed runtime source).requests;
  Alcotest.(check int) "four initial page reads" 4 (Queue.length pending);
  let pages=ref 0 and outlines=ref 0 in
  while not (Queue.is_empty pending) do
    let request : Protocol.request = Queue.pop pending in
    let outcome=match request.command with
      | V2_get_page {page;_}->incr pages;Protocol.V2_page_outcome
          (V2_missing_page {uuid=page;revision="page-missing"})
      | V2_get_outline_block {block;_}->incr outlines;Protocol.V2_block_outcome
          (V2_missing_block {uuid=block;revision="outline-missing"})
      | _->Alcotest.fail "unexpected hydration request" in
    List.iter (fun request->Queue.push request pending)
      (Runtime.receive runtime (response request outcome)).requests;
    Alcotest.(check bool) "both phases share four-read admission" true (Queue.length pending<=4)
  done;
  Alcotest.(check int) "one page read per UUID" 30 !pages;
  Alcotest.(check int) "one fallback per explicit miss" 30 !outlines;
  Alcotest.(check int) "negative results remain deduplicated" 0
    (List.length (reference_feed runtime source).requests)
;;

let test_recycled_reference_page_never_falls_back () =
  let runtime=Runtime.create () in
  let first=reference_feed runtime reference |> fun output->expect_reference_page output target_uuid in
  let hidden=Runtime.receive runtime (reference_page_response ~recycled:true first Ordinary_page "Hidden") in
  Alcotest.(check int) "existing recycled page is not a missing page" 0 (List.length hidden.requests);
  Alcotest.(check bool) "recycled title is never shown" false
    (List.mem (target_id,Some "Hidden") (reference_updates hidden));
  ignore (reference_feed runtime reference |> fun output->expect_reference_page output target_uuid)
;;

let test_reference_failed_read_retains_epoch_fence () =
  List.iter (fun abandon ->
    let runtime=Runtime.create () in
    let first=reference_feed runtime reference |> fun output->expect_reference_page output target_uuid in
    let old_fragment=begin_reference_tree runtime 11L in
    ignore (changed runtime (window ~pages:[target_uuid] ()));
    let retry=missing_reference_page runtime first target_uuid
      |> fun output->expect_reference_page output target_uuid in
    if abandon then Runtime.abandon runtime retry
    else ignore (Runtime.fail_request runtime retry ~message:"transient failure");
    let late=Runtime.receive runtime (reference_tree_response old_fragment "Rollback") in
    Alcotest.(check bool) "failure/cancel preserves its epoch fence" false
      (List.mem (target_id,Some "Rollback") (reference_updates late));
    let retry_output =
      if hydration_requests late <> [] then late
      else reference_feed runtime reference
    in
    ignore (expect_reference_page retry_output target_uuid);
    Alcotest.(check int) "pending retry remains deduplicated" 0
      (List.length (reference_feed runtime reference).requests)) [false;true]
;;

let test_reference_abandon_preserves_newer_source () =
  let runtime=Runtime.create () in
  let old=reference_feed runtime reference |> fun output->expect_reference_page output target_uuid in
  let older_fragment=begin_reference_tree runtime 12L in
  let current_fragment=begin_reference_tree runtime 13L in
  let fresh=Runtime.receive runtime (reference_tree_response current_fragment "Current") in
  Alcotest.(check bool) "fresh fragment published" true
    (List.mem (target_id,Some "Current") (reference_updates fresh));
  Runtime.abandon runtime old;
  let rollback=Runtime.receive runtime (reference_tree_response older_fragment "Rollback") in
  Alcotest.(check bool) "abandon cannot delete a newer source fence" false
    (List.mem (target_id,Some "Rollback") (reference_updates rollback));
  Alcotest.(check int) "newer source remains cached" 0
    (List.length (reference_feed runtime reference).requests)
;;

let test_reference_shared_failure_can_retry_discovery () =
  let runtime=Runtime.create () in
  set_calendar runtime;
  let initial=begin_reference_tree runtime 14L in
  ignore (Runtime.receive runtime (reference_tree_response initial "Loaded"));
  let update=changed runtime (window ~blocks:[target_uuid] ())
    |> check_target_request runtime in
  ignore (Runtime.fail_request runtime update ~message:"shared point-read failed");
  ignore (reference_feed runtime reference |> fun output->expect_reference_page output target_uuid)
;;

let test_reference_page_survives_unrelated_outline_miss () =
  let runtime=Runtime.create () in
  let first=reference_feed runtime reference |> fun output->expect_reference_page output target_uuid in
  ignore (Runtime.receive runtime (reference_page_response first Ordinary_page "Actual page"));
  let wrong_projection=Runtime.submit runtime (Journal_graph_request.Find_block target_id)
    |> fun output->only "independent outline request" output.requests in
  let missing=Runtime.receive runtime (response wrong_projection (Protocol.V2_block_outcome
    (V2_missing_block {uuid=target_uuid;revision="not-an-outline"}))) in
  Alcotest.(check bool) "outline miss does not invalidate an existing page" false
    (List.mem (target_id,None) (reference_updates missing));
  Alcotest.(check int) "existing page stays positively cached" 0
    (List.length (reference_feed runtime reference).requests)
;;

let test_reference_shared_page_miss_is_not_negative_cache () =
  let runtime=Runtime.create () in
  let first=reference_feed runtime reference |> fun output->expect_reference_page output target_uuid in
  ignore (Runtime.receive runtime (reference_page_response first Ordinary_page "Actual page"));
  let root=Runtime.submit runtime (Journal_graph_request.Load_detail
    {block_id=Graph.Uuid.to_string block_uuid;after=None;limit=128;request_generation=22L})
    |> fun output->only "unretained owning page root" output.requests in
  let owning=Runtime.receive runtime (response root (Protocol.V2_block_outcome
    (V2_present_block {value={record with block={block with page=target_uuid;parent=target_uuid}};revision="owning"})))
    |> fun output->only "owning page metadata read" output.requests in
  ignore (missing_reference_page runtime owning target_uuid);
  ignore (reference_feed runtime reference |> fun output->expect_reference_page output target_uuid)
;;

let test_typed_metadata_preserves_newer_reference_fence () =
  let runtime=Runtime.create () in
  let first=reference_feed runtime reference |> fun output->expect_reference_page output target_uuid in
  let property : Graph.property_summary =
    {ident="user.property/page";uuid=block_uuid;title="Actual page"
    ;schema={property_type=Page;cardinality=One;hidden=false;public=false}
    ;values=[Page_value target_uuid];values_truncated=false} in
  let root=Runtime.submit runtime (Journal_graph_request.Load_detail
    {block_id=Graph.Uuid.to_string block_uuid;after=None;limit=128;request_generation=31L})
    |> fun output->only "old typed Detail root" output.requests in
  let children=Runtime.receive runtime (response root (Protocol.V2_block_outcome
    (V2_present_block {value={record with block={block with properties=[property]}};revision="typed"})))
    |> fun output->only "old typed Detail children" output.requests in
  let middle=begin_reference_tree runtime 32L in
  ignore (changed runtime (window ~pages:[target_uuid] ()));
  let fresh=missing_reference_page runtime first target_uuid
    |> fun output->expect_reference_page output target_uuid in
  ignore (Runtime.fail_request runtime fresh ~message:"newer failure fence");
  ignore (Runtime.receive runtime (response children (Protocol.V2_children_outcome
    {parent=block_uuid;revision_scope=V2_children_revision block_uuid;scope_revision="typed";items=[];next_cursor=None})));
  let late=Runtime.receive runtime (reference_tree_response middle "Rollback") in
  Alcotest.(check bool) "old typed metadata cannot lower a newer fence" false
    (List.mem (target_id,Some "Rollback") (reference_updates late))
;;

let test_dirty_abandon_keeps_reference_retryable () =
  List.iter (fun positive ->
    let runtime=Runtime.create () in
    let first=reference_feed runtime reference |> fun output->expect_reference_page output target_uuid in
    if positive then ignore (Runtime.receive runtime (reference_page_response first Ordinary_page "Before"))
    else (
      let outline=missing_reference_page runtime first target_uuid
        |> fun output->expect_reference_outline output target_uuid in
      ignore (Runtime.receive runtime (response outline (Protocol.V2_block_outcome
        (V2_missing_block {uuid=target_uuid;revision="missing"})))));
    let pending=changed runtime (window ~pages:[target_uuid] ())
      |> fun output->expect_reference_page output target_uuid in
    ignore (changed runtime (window ~pages:[target_uuid] ()));
    Runtime.abandon runtime pending;
    ignore (reference_feed runtime reference |> fun output->expect_reference_page output target_uuid)) [false;true]
;;

(* Root dispatch and mutation confirmation are owned by Runtime; no public pure
   reducer emits these protocol reads. Test only its public submit/receive boundary. *)
let page_detail_seed runtime children =
  set_calendar runtime;
  let out = Runtime.submit runtime (Journal_graph_request.Load_detail
    {block_id=Graph.Uuid.to_string page_uuid; after=None; limit=128; request_generation=801L}) in
  let root = only "page root lookup" out.requests in
  let root = match root.command with
    | V2_get_page {page=id;_} when Graph.Uuid.equal id page_uuid -> root
    | V2_get_outline_block _ ->
      Runtime.receive runtime (response root (Protocol.V2_block_outcome
        (V2_missing_block {uuid=page_uuid; revision="absent-outline"})))
      |> fun out -> only "outline miss must resolve page" out.requests
    | _ -> Alcotest.fail "unexpected root lookup" in
  Alcotest.(check bool) "page root is resolved as a page" true
    (root.command = V2_get_page {page=page_uuid; revision=None});
  let child_read = Runtime.receive runtime (response root (Protocol.V2_page_outcome
    (V2_present_page {page; revision="page-1"})))
    |> fun out -> only "page root children" out.requests in
  (match child_read.command with
   | V2_get_children {parent;limit=128;_} when Graph.Uuid.equal parent page_uuid -> ()
   | _ -> Alcotest.fail "page children escaped selected page");
  let out = Runtime.receive runtime (response child_read (copy_children page_uuid children)) in
  out.responses |> List.find_map (fun r -> match r.Runtime.payload with
    | Detail_loaded {detail;_} -> Some detail | _ -> None) |> Option.get
;;

let test_page_detail_root_and_append () =
  List.iter (fun children ->
    let runtime=Runtime.create () in
    let detail=page_detail_seed runtime children in
    Alcotest.(check string) "page root title" page.title (Journal_model.source detail.root);
    Alcotest.(check string) "page root page identity" (Graph.Uuid.to_string page_uuid)
      (Journal_model.page_id detail.root);
    Alcotest.(check int) "page children" (List.length children) (List.length detail.children.blocks);
    let command : Journal_graph_projection.create_child =
         { mutation_id = Graph.Uuid.to_string unrelated_uuid
         ; calendar_generation = 1L
         ; block_id = Graph.Uuid.to_string unrelated_uuid
         ; parent_block_id = Graph.Uuid.to_string page_uuid
         ; expected_parent_revision = Journal_model.revision detail.root
         ; sibling_order = "z"
         ; source = "Append only here"
         ; task_state = No_status
         ; creation_time = Journal_model.creation_time detail.root
         ; status_confirmation = false
         }
       in
    let request=Runtime.submit runtime (Create_child command) |> fun out->only "page append" out.requests in
    (match request.command with
     | V2_insert_blocks {parent;preconditions;_} ->
       Alcotest.(check bool) "exact page parent" true (Graph.Uuid.equal parent page_uuid);
       Alcotest.(check bool) "page revision, never outline revision" true
         (preconditions = {Protocol.blocks=[];pages=[page_uuid,"page-1"];
           scopes=[V2_children_scope page_uuid,"children-1"]})
     | _->Alcotest.fail "page append failed to issue scoped insert");
    let child_read=Runtime.receive runtime (response request (Protocol.V2_mutation_committed
      {mutation_id=unrelated_uuid;status=V2_applied;generation="graph-1";
       before_projection_revision="projection-1";after_projection_revision="projection-2"}))
      |> fun out->only "read inserted page child" out.requests in
    let child=copy_child unrelated_uuid page_uuid command.source in
    let parent_read=Runtime.receive runtime (response child_read (Protocol.V2_block_outcome
      (V2_present_block {value=child.value;revision=child.revision})))
      |> fun out->only "confirm selected page parent" out.requests in
    Alcotest.(check bool) "confirm page through page API" true
      (parent_read.command=V2_get_page {page=page_uuid;revision=None});
    let done_=Runtime.receive runtime (response parent_read (Protocol.V2_page_outcome
      (V2_present_page {page;revision="page-2"}))) in
    let child,parent=done_.responses |> List.find_map (fun r -> match r.Runtime.payload with
      | Child_created {child;parent;_}->Some(child,parent) | _->None) |> Option.get in
    Alcotest.(check string) "completed child page" (Graph.Uuid.to_string page_uuid) (Journal_model.page_id child);
    Alcotest.(check string) "completed parent is page" (Graph.Uuid.to_string page_uuid) (Journal_model.id parent))
    [[]; [copy_child block_uuid page_uuid "First child"]]
;;

let test_recycled_page_root_is_removed () =
  let runtime=Runtime.create () in
  ignore (page_detail_seed runtime []);
  let request=changed runtime (window ~pages:[page_uuid] ())
    |> fun out->only "page recycle refresh" (hydration_requests out) in
  let out=Runtime.receive runtime (response request (Protocol.V2_page_outcome
    (V2_present_page {page={page with recycled=true};revision="recycled"}))) in
  Alcotest.(check bool) "recycled page root becomes unavailable" true
    (List.exists (fun r->match r.Runtime.payload with
      | Block_removed {block_id}->block_id=Graph.Uuid.to_string page_uuid | _->false) out.responses)
;;

let test_page_root_block_change_uses_page_identity () =
  let runtime=Runtime.create () in
  ignore (page_detail_seed runtime []);
  let out=changed runtime (window ~blocks:[page_uuid] ()) in
  Alcotest.(check bool) "page root point change is not an outline lookup" false
    (List.exists (fun (r:Protocol.request)->r.command=V2_get_outline_block {block=page_uuid;revision=None}) out.requests);
  Alcotest.(check bool) "page root point change refreshes page" true
    (List.exists (fun (r:Protocol.request)->r.command=V2_get_page {page=page_uuid;revision=None}) out.requests)
;;

let test_page_root_refresh_and_resync () =
  let runtime=Runtime.create () in
  ignore (page_detail_seed runtime []);
  let fresh=changed runtime (window ~pages:[page_uuid] ())
    |> fun out->only "one owned page refresh" (hydration_requests out) in
  let result=Runtime.receive runtime (response fresh (Protocol.V2_page_outcome
    (V2_present_page {page={page with title="Renamed page"};revision="page-2"}))) in
  let detail=result.responses |> List.find_map (fun r-> match r.Runtime.payload with
    | Children_reconciled detail -> Some detail | _->None) |> Option.get in
  Alcotest.(check string) "renamed page root reconciles" "Renamed page" (Journal_model.source detail.root);
  Alcotest.(check string) "page revision reconciles" "page-2" (Journal_model.revision detail.root);
  let out=Runtime.reconcile_push runtime ~request_generation:12L
    (Protocol.V2_resync_required_push {api_version=Protocol.api_version;generation="generation-2";reason="overflow"}) in
  Alcotest.(check bool) "page root is never rehydrated as outline" false
    (List.exists (fun (r:Protocol.request)->r.command=V2_get_outline_block {block=page_uuid;revision=None}) out.requests)
;;

let test_page_property_refresh_discovers_references () =
  List.iter (fun page_root ->
    let runtime=Runtime.create () in
    if page_root then ignore (page_detail_seed runtime [])
    else seed_children_interest runtime;
    let property : Graph.property_summary =
      {ident="user.property/page";uuid=block_uuid;title="Linked page"
      ;schema={property_type=Page;cardinality=Many;hidden=false;public=false}
      ;values=[Page_value target_uuid;Page_value target_uuid];values_truncated=false} in
    let hidden={property with ident="user.property/hidden";uuid=unrelated_uuid;
      schema={property.schema with hidden=true};values=[Page_value unrelated_uuid]} in
    let refresh () = changed runtime (window ~pages:[page_uuid] ())
      |> fun out -> hydration_requests out
      |> List.filter (fun (request:Protocol.request) ->
        request.command = V2_get_page {page=page_uuid;revision=None})
      |> only "one owning page refresh" in
    let complete request = Runtime.receive runtime (response request (Protocol.V2_page_outcome
      (V2_present_page {page={page with properties=[property;hidden]};revision="page-2"}))) in
    let out=complete (refresh ()) in
    if page_root then (
      let reference=expect_reference_page out target_uuid in
      Alcotest.(check int) "duplicate values share one read; hidden properties have no demand"
        1 (List.length out.requests);
      let resolved=Runtime.receive runtime (reference_page_response reference Ordinary_page "Linked title") in
      Alcotest.(check (option string)) "new page property reference resolves"
        (Some "Linked title") (List.assoc_opt target_id (reference_updates resolved) |> Option.join);
      Alcotest.(check int) "unchanged property reuses shared cache" 0
        (List.length (complete (refresh ())).requests))
    else Alcotest.(check int) "outline detail does not demand undisplayed page properties"
      0 (List.length out.requests)) [true;false]
;;

let favorites_reference_source runtime title =
  let request : Journal_graph_request.favorites_request =
    {graph_generation=1;request_generation=802L;limit=50;cursor=None} in
  let read=Runtime.submit runtime (Load_favorites request) |> fun out->only "favorite list" out.requests in
  Runtime.receive runtime (response read (Protocol.V2_favorites_outcome
    {favorites_page=None;generation="g";projection_revision="p";next_cursor=None;
     items=[{membership_uuid;membership_order="a";membership_revision="m";
       target=V2_favorite_block {uuid=block_uuid;title;task_status=None;revision="b"}}]}))
;;

let test_favorites_share_reference_cache () =
  let runtime=Runtime.create () in
  set_calendar runtime;
  let out=favorites_reference_source runtime (reference ^ " " ^ reference) in
  let page_read=out.requests |> List.filter (fun (r:Protocol.request)->
    r.command=V2_get_page {page=target_uuid;revision=None}) |> only "duplicate favorite reference uses one page read" in
  let out=Runtime.receive runtime (reference_page_response page_read
    (Graph.Journal_page {journal_day=20260901}) "Tuesday, September 1st, 2026") in
  Alcotest.(check (option string)) "favorite journal page keeps actual date title"
    (Some "Tuesday, September 1st, 2026")
    (List.assoc_opt target_id (reference_updates out) |> Option.join);
  let duplicate=favorites_reference_source runtime reference in
  Alcotest.(check int) "favorite reload shares positive reference cache" 0
    (List.length (List.filter (fun (r:Protocol.request)->r.command=V2_get_page {page=target_uuid;revision=None}) duplicate.requests));
  let late_runtime=Runtime.create () in
  let old=favorites_reference_source late_runtime reference in
  let old_read=old.requests |> List.find (fun (r:Protocol.request)->r.command=V2_get_page {page=target_uuid;revision=None}) in
  Runtime.reset late_runtime;
  let late=Runtime.receive late_runtime (reference_page_response old_read Ordinary_page "Old graph") in
  Alcotest.(check int) "late Favorites reference is fenced by graph reset" 0 (List.length late.responses)
;;

let test_favorites_outline_and_missing_reference () =
  List.iter (fun missing ->
    let runtime=Runtime.create () in
    let out=favorites_reference_source runtime (reference ^ reference) in
    let page_read=out.requests |> List.find (fun (r:Protocol.request)->
      r.command=V2_get_page {page=target_uuid;revision=None}) in
    let fallback=missing_reference_page runtime page_read target_uuid in
    let outline=expect_reference_outline fallback target_uuid in
    let out=Runtime.receive runtime (if missing then response outline (Protocol.V2_block_outcome
      (V2_missing_block {uuid=target_uuid;revision="absent"})) else target_response outline "Outline title") in
    Alcotest.(check (option string)) "Favorites shares outline and missing source results"
      (if missing then None else Some "Outline title")
      (List.assoc_opt target_id (reference_updates out) |> Option.join)) [false;true]
;;

(* The scheduler is owned by Runtime, so use only its public demands and
   completions. Every Present value below describes the requested entity. *)
let scheduling_uuid family n =
  uuid (Printf.sprintf "a8000000-0000-4000-%04d-%012d" family n)
;;

let scheduling_block n : Protocol.v2_block_record =
  let parent = scheduling_uuid 8000 n in
  { record with
    block =
      { block with
        uuid = scheduling_uuid 9000 n
      ; parent
      ; page = parent
      ; title = (if n = 0 then "Favorite " ^ reference else "Favorite block")
      }
  }
;;

let scheduling_favorites runtime count generation =
  let request : Journal_graph_request.favorites_request =
    { graph_generation = 1; request_generation = generation; limit = 50; cursor = None }
  in
  let read = Runtime.submit runtime (Load_favorites request)
    |> fun out -> only "Favorite list demand" out.requests in
  Runtime.receive runtime (response read (Protocol.V2_favorites_outcome
    { favorites_page = None; generation = "g"; projection_revision = "p"
    ; next_cursor = None
    ; items = List.init count (fun n ->
        let value = scheduling_block n in
        { Protocol.membership_uuid = scheduling_uuid 7000 n
        ; membership_order = string_of_int n; membership_revision = "m"
        ; target = V2_favorite_block
            { uuid = value.block.uuid; title = value.block.title
            ; task_status = None; revision = "b" } }) }))
;;

let scheduling_reply (request : Protocol.request) =
  match request.command with
  | V2_get_outline_block { block = requested; _ } ->
    let n = List.find (fun n -> Graph.Uuid.equal requested (scheduling_uuid 9000 n))
      (List.init 12 Fun.id) in
    response request (Protocol.V2_block_outcome
      (V2_present_block { value = scheduling_block n; revision = "b" }))
  | V2_get_page { page = requested; _ } ->
    response request (Protocol.V2_page_outcome (V2_present_page
      { page = { page with uuid = requested; kind = Ordinary_page
                ; title =
                    (if Graph.Uuid.equal requested target_uuid
                     then "Resolved"
                     else "Parent")
                }
      ; revision = "p" }))
  | _ -> Alcotest.fail "unexpected scheduling demand"
;;

let drain_scheduling ?(cancel_count = 0) runtime output =
  let issued = Hashtbl.create 32 in
  let target_reads = ref 0 and updates = ref [] in
  let collect (output : Runtime.output) =
    updates := reference_updates output @ !updates;
    List.iter (fun (request : Protocol.request) ->
      let key = Graph.Uuid.to_string request.request_id in
      Alcotest.(check bool) "one delivery per request ID" false (Hashtbl.mem issued key);
      Hashtbl.add issued key ();
      if request.command = V2_get_page { page = target_uuid; revision = None }
      then incr target_reads) output.requests
  in
  collect output;
  let rec loop completed outstanding =
    check_hydration_bound outstanding;
    match outstanding with
    | [] -> ()
    | request :: rest ->
      let next = if completed < cancel_count then
          Runtime.fail_request runtime request ~message:"Worker cancelled"
        else Runtime.receive runtime (scheduling_reply request) in
      let duplicate = Runtime.receive runtime (scheduling_reply request) in
      Alcotest.(check int) "late or repeated completion cannot dispatch" 0
        (List.length duplicate.requests);
      Alcotest.(check int) "late or repeated completion cannot publish" 0
        (List.length duplicate.responses);
      collect next;
      loop (completed + 1) (rest @ next.requests)
  in
  loop 0 output.requests;
  Alcotest.(check int) "queued target page is delivered exactly once" 1 !target_reads;
  Alcotest.(check (option string)) "target response reaches shared cache"
    (Some "Resolved") (List.assoc_opt target_id !updates |> Option.join);
  let fresh = scheduling_favorites runtime 4 902L in
  Alcotest.(check int) "all four slots are free after draining" 4
    (List.length fresh.requests);
  Alcotest.(check (list string)) "no earlier queued identity leaks into a fresh window"
    (List.init 4 (fun n -> Graph.Uuid.to_string (scheduling_uuid 9000 n)) |> List.sort String.compare)
    (List.map (fun (request : Protocol.request) -> match request.command with
      | V2_get_outline_block { block; _ } -> Graph.Uuid.to_string block
      | _ -> Alcotest.fail "fresh window returned a leftover request") fresh.requests
     |> List.sort String.compare)
;;

let test_favorite_dependencies_drain_once () =
  List.iter (fun count ->
    let runtime = Runtime.create () in
    set_calendar runtime;
    drain_scheduling runtime (scheduling_favorites runtime count 900L)) [4; 8]
;;

let test_favorite_cancel_releases_slot () =
  List.iter (fun cancel_count ->
    let runtime = Runtime.create () in
    set_calendar runtime;
    drain_scheduling ~cancel_count runtime (scheduling_favorites runtime 8 900L)) [1; 4]
;;

let test_favorite_scope_discards_queued_reads () =
  let runtime = Runtime.create () in
  set_calendar runtime;
  let old = scheduling_favorites runtime 8 900L in
  Runtime.reset runtime;
  List.iter (fun request ->
    let late = Runtime.receive runtime (scheduling_reply request) in
    Alcotest.(check int) "old scope cannot dispatch queued reads" 0
      (List.length late.requests);
    Alcotest.(check int) "old scope cannot publish sources" 0
      (List.length late.responses)) old.requests;
  drain_scheduling runtime (scheduling_favorites runtime 8 901L)
;;

let test_favorite_epoch_preserves_new_queue () =
  let runtime = Runtime.create () in
  set_calendar runtime;
  let old = scheduling_favorites runtime 8 900L in
  let current = scheduling_favorites runtime 8 901L in
  Alcotest.(check int) "new epoch shares the outstanding window" 0
    (List.length current.requests);
  let resumed = List.fold_left (fun (out : Runtime.output) request ->
    let next = Runtime.receive runtime (scheduling_reply request) in
    { Runtime.requests = out.requests @ next.requests
    ; responses = out.responses @ next.responses }) current old.requests in
  drain_scheduling runtime resumed
;;

(* Worker admission belongs to transport. Test only that missing boundary,
   with a real Runtime output; do not duplicate DB/effect-runner coverage. *)
let test_rejected_delivery_retires_unsent_queue () =
  List.iter (fun refusal ->
    let runtime = Runtime.create () in
    set_calendar runtime;
    let output = scheduling_favorites runtime 8 900L in
    let attempts = ref 0 in
    let delivery = Journal_graph_transport.deliver ~runtime
      ~send:(fun _ -> incr attempts; refusal) output in
    Alcotest.(check int) "refusal is never retried" 1 !attempts;
    Alcotest.(check bool) "refusal remains explicit" true (Option.is_some delivery.error);
    List.iter (fun request ->
      let late = Runtime.receive runtime (scheduling_reply request) in
      Alcotest.(check int) "rejected request cannot publish late response" 0
        (List.length late.responses)) output.requests;
    drain_scheduling runtime (scheduling_favorites runtime 8 901L))
    Journal_graph_transport.[Full; Not_ready; Stopping]
;;

let test_favorite_page_title_discovers_reference () =
  let runtime = Runtime.create () in
  set_calendar runtime;
  let request : Journal_graph_request.favorites_request =
    { graph_generation = 1; request_generation = 903L; limit = 50; cursor = None } in
  let read = Runtime.submit runtime (Load_favorites request)
    |> fun out -> only "Favorite page list" out.requests in
  let out = Runtime.receive runtime (response read (Protocol.V2_favorites_outcome
    { favorites_page = None; generation = "g"; projection_revision = "p"
    ; next_cursor = None
    ; items = [{ Protocol.membership_uuid; membership_order = "a"; membership_revision = "m"
        ; target = V2_favorite_page { uuid = page_uuid; title = reference; revision = "p" } }] })) in
  let reference_read = out.requests |> List.filter (fun (r : Protocol.request) ->
    r.command = V2_get_page { page = target_uuid; revision = None })
    |> only "Favorite page title demands page-first reference" in
  let resolved = Runtime.receive runtime
    (reference_page_response reference_read Ordinary_page "Resolved") in
  Alcotest.(check (option string)) "Favorite page source is accepted" (Some "Resolved")
    (List.assoc_opt target_id (reference_updates resolved) |> Option.join)
;;

let test_page_detail_root_title_discovers_reference () =
  let runtime = Runtime.create () in
  set_calendar runtime;
  let root = Runtime.submit runtime (Load_detail
    { block_id = Graph.Uuid.to_string page_uuid; after = None
    ; limit = 50; request_generation = 904L })
    |> fun out -> only "detail root" out.requests in
  let page_read = Runtime.receive runtime (response root (Protocol.V2_block_outcome
    (V2_missing_block { uuid = page_uuid; revision = "no-outline" })))
    |> fun out -> only "detail page fallback" out.requests in
  let out = Runtime.receive runtime (response page_read (Protocol.V2_page_outcome
    (V2_present_page { page = { page with kind = Ordinary_page; title = reference }
    ; revision = "p" }))) in
  let children = out.requests |> List.find (fun (r : Protocol.request) ->
      match r.command with
      | V2_get_children _ -> true
      | _ -> false)
  in
  let loaded = Runtime.receive runtime (response children (Protocol.V2_children_outcome
    { parent = page_uuid; revision_scope = V2_children_revision page_uuid
    ; scope_revision = "c"; items = []; next_cursor = None })) in
  let refs = out.requests @ loaded.requests |> List.filter (fun (r : Protocol.request) ->
    r.command = V2_get_page { page = target_uuid; revision = None }) in
  let ref_read = only "empty page detail root demands reference" refs in
  let resolved = Runtime.receive runtime
    (reference_page_response ref_read Ordinary_page "Resolved") in
  let lookup id = List.assoc_opt id (reference_updates resolved) |> Option.join in
  let runs = Journal_model.Title.render ~lookup reference in
  Alcotest.(check string) "page root displays the shared result" "Resolved"
    (Journal_model.Title.plain runs);
  Alcotest.(check bool) "reference expansion is not clickable" true
    (List.for_all (fun (run : Journal_model.Title.run) -> run.url = None) runs)
;;

let test_copy_page_root () =
  List.iter (fun populated ->
    let state,effects=copy_start page_uuid in
    let state,effects=copy_reply state effects (Protocol.V2_block_outcome
      (V2_missing_block {uuid=page_uuid;revision="no-outline"})) in
    Alcotest.(check bool) "copy resolves exact page" true
      (snd(copy_read effects)=V2_get_page {page=page_uuid;revision=None});
    let state,effects=copy_reply state effects (Protocol.V2_page_outcome
      (V2_present_page {page;revision="page-1"})) in
    copy_parent effects page_uuid;
    let state,effects=copy_reply state effects (copy_children page_uuid
      (if populated then [copy_child block_uuid page_uuid "Child"] else [])) in
    let state,effects=if populated then copy_reply state effects (copy_children block_uuid []) else state,effects in
    let _,effects=copy_reply state effects (graph_info_outcome ~journal_title_format:None) in
    Alcotest.(check bool) "page title and exact descendants copied" true
      (effects=[Copy.Copied (page.title ^ if populated then "\n  - Child" else "")])) [false;true]
;;

let test_invalid_status_precedes_insert () =
  List.iter
    (fun task_state ->
       let runtime = Runtime.create () in
       set_calendar runtime;
       let creation_time =
         Journal_time.create
           ~instant_unix_ms:1_788_192_000_000L
           ~local_day:20260901
           ~local_minute_of_day:0
         |> Result.get_ok
       in
       let output =
         Runtime.submit
           runtime
           (Journal_graph_request.Capture
              { calendar_generation = 1L
              ; command =
                  { mutation_id = "a1000000-0000-4000-a000-0000000000c1"
                  ; block_id = Graph.Uuid.to_string block_uuid
                  ; sibling_order = "a"
                  ; source = "Retained draft"
                  ; task_state
                  ; creation_time
                  ; children = []
                  ; status_confirmation = false
                  }
              })
       in
       Alcotest.(check int)
         "invalid status cannot start Capture insertion"
         0
         (List.length output.requests);
       expect_admitted_failure
         "invalid status keeps Capture owner"
         ~kind:Capture_mutation
         ~mutation_id:"a1000000-0000-4000-a000-0000000000c1"
         ~block_id:(Graph.Uuid.to_string block_uuid)
         output)
    Journal_model.[ Default_status; Invalid_status "broken"; Status "not-a-uuid" ]
;;

let test_catalog_and_lookup_cross_fences () =
  let definition : Graph.task_status_definition =
    { uuid = unrelated_uuid
    ; title = "Old"
    ; ident = None
    ; order = "a"
    ; checkbox_state = None
    }
  in
  let find_catalog requests =
    List.find
      (fun (r : Protocol.request) ->
         match r.command with
         | V2_list_task_statuses _ -> true
         | _ -> false)
      requests
  in
  let start () =
    let runtime = Runtime.create () in
    let started = Runtime.start runtime in
    let output =
      Runtime.receive
        runtime
        (response started (graph_info_outcome ~journal_title_format:None))
    in
    runtime, find_catalog output.requests
  in
  let catalog items next_cursor =
    Protocol.V2_task_statuses_outcome
      { property_uuid = Some page_uuid; default_status = None; items; next_cursor }
  in
  let runtime, first = start () in
  let page2 =
    Runtime.receive
      runtime
      (response
         first
         (catalog [] (Some (Graph.Cursor.of_string "next" |> Result.get_ok))))
    |> fun out -> find_catalog out.requests
  in
  let delta =
    changed runtime (window ~blocks:[ unrelated_uuid ] ())
    |> fun out ->
    List.find
      (fun (r : Protocol.request) ->
         match r.command with
         | V2_get_task_status_definitions _ -> true
         | _ -> false)
      out.requests
  in
  ignore
    (Runtime.receive
       runtime
       (response delta (V2_task_status_definitions_outcome [ None ])));
  let done_ = Runtime.receive runtime (response page2 (catalog [ definition ] None)) in
  Alcotest.(check bool)
    "late page cannot restore deleted status"
    true
    (List.exists
       (fun r ->
          match r.Runtime.payload with
          | Task_statuses_changed { items; _ } -> Rrbvec.is_empty items
          | _ -> false)
       done_.responses);
  let runtime, first = start () in
  ignore (Runtime.receive runtime (response first (catalog [ definition ] None)));
  let delta =
    changed runtime (window ~blocks:[ unrelated_uuid ] ())
    |> fun out ->
    List.find
      (fun (r : Protocol.request) ->
         match r.command with
         | V2_get_task_status_definitions _ -> true
         | _ -> false)
      out.requests
  in
  let reload =
    Runtime.submit runtime Load_task_statuses |> fun out -> find_catalog out.requests
  in
  ignore (Runtime.receive runtime (response reload (catalog [] None)));
  let stale =
    Runtime.receive
      runtime
      (response delta (V2_task_status_definitions_outcome [ Some definition ]))
  in
  Alcotest.(check int)
    "old lookup cannot restore catalog deletion"
    0
    (List.length stale.responses)
;;

let test_capture_recovery_explicit_clear () =
  let runtime = Runtime.create () in
  set_calendar runtime;
  let creation_time =
    Journal_time.create
      ~instant_unix_ms:1_788_192_000_000L
      ~local_day:20260901
      ~local_minute_of_day:0
    |> Result.get_ok
  in
  let next out = only "capture recovery continuation" out.Runtime.requests in
  let lookup =
    Runtime.submit
      runtime
      (Capture
         { calendar_generation = 1L
         ; command =
             { mutation_id = "a1000000-0000-4000-a000-0000000000c1"
             ; block_id = Graph.Uuid.to_string block_uuid
             ; sibling_order = "a"
             ; source = "Retained"
             ; task_state = No_status
             ; status_confirmation = true
             ; creation_time
             ; children = []
             }
         })
    |> next
  in
  let target_page =
    match lookup.command with
    | V2_get_page { page = id; _ } -> { page with uuid = id }
    | _ -> assert false
  in
  let children =
    Runtime.receive
      runtime
      (response
         lookup
         (V2_page_outcome (V2_present_page { page = target_page; revision = "p" })))
    |> next
  in
  let insert =
    Runtime.receive
      runtime
      (response
         children
         (V2_children_outcome
            { parent = target_page.uuid
            ; revision_scope = V2_children_revision target_page.uuid
            ; scope_revision = "c"
            ; items = []
            ; next_cursor = None
            }))
    |> next
  in
  let mutation_id =
    match insert.command with
    | V2_insert_blocks { mutation_id; _ } -> mutation_id
    | _ -> assert false
  in
  let read =
    Runtime.receive
      runtime
      (response
         insert
         (V2_mutation_committed
            { mutation_id
            ; status = V2_already_applied
            ; generation = "g"
            ; before_projection_revision = "p"
            ; after_projection_revision = "p"
            }))
    |> next
  in
  let clear =
    Runtime.receive
      runtime
      (response
         read
         (V2_block_outcome
            (V2_present_block
               { value =
                   { record with
                     block = { block with page = target_page.uuid }
                   ; task_status = Some unrelated_uuid
                   }
               ; revision = "b"
               })))
    |> next
  in
  Alcotest.(check bool)
    "Clear recovery writes explicit clear"
    true
    (match clear.command with
     | V2_clear_task_status { block = id; _ } -> Graph.Uuid.equal id block_uuid
     | _ -> false)
;;

let test_child_recovery_explicit_clear () =
  let runtime = Runtime.create () in
  seed_children_interest runtime;
  set_calendar runtime;
  let child_uuid = uuid "a1000000-0000-4000-9000-000000000081" in
  let creation_time =
    Journal_time.create
      ~instant_unix_ms:1_788_192_000_000L
      ~local_day:20260901
      ~local_minute_of_day:0
    |> Result.get_ok
  in
  let next out = only "Append recovery continuation" out.Runtime.requests in
  let insert =
    Runtime.submit
      runtime
      (Create_child
         { mutation_id = "a1000000-0000-4000-a000-000000000081"
         ; block_id = Graph.Uuid.to_string child_uuid
         ; parent_block_id = Graph.Uuid.to_string block_uuid
         ; calendar_generation = 1L
         ; expected_parent_revision = "block-detail-1"
         ; sibling_order = "a"
         ; source = "Retained child"
         ; task_state = No_status
         ; status_confirmation = true
         ; creation_time
         })
    |> next
  in
  let mutation_id =
    match insert.command with
    | V2_insert_blocks { mutation_id; _ } -> mutation_id
    | _ -> assert false
  in
  let read =
    Runtime.receive
      runtime
      (response
         insert
         (V2_mutation_committed
            { mutation_id
            ; status = V2_already_applied
            ; generation = "g"
            ; before_projection_revision = "p"
            ; after_projection_revision = "p"
            }))
    |> next
  in
  let clear =
    Runtime.receive
      runtime
      (response
         read
         (V2_block_outcome
            (V2_present_block
               { value =
                   { record with
                     block = { block with uuid = child_uuid; parent = block_uuid }
                   ; task_status = Some unrelated_uuid
                   }
               ; revision = "b"
               })))
    |> next
  in
  Alcotest.(check bool)
    "Append Clear recovery writes explicit clear"
    true
    (match clear.command with
     | V2_clear_task_status { block = id; _ } -> Graph.Uuid.equal id child_uuid
     | _ -> false)
;;

let test_task_catalog_generation_and_deltas () =
  let runtime = Runtime.create () in
  let initial = Runtime.start runtime in
  let raw =
    Yojson.Safe.from_string
      {|["V2_response",{"api_version":2,"request_id":"00000000-0000-4000-8000-000000000001","outcome":["V2_graph_info_outcome",{"graph_uuid":"a1000000-0000-4000-8000-000000000001","graph_name":"Synthetic","schema":{"major":65,"minor":33},"admission_facts":[],"journal_title_format":null,"generation":"generation-1","projection_revision":"revision-1","limits":{"response_budget_bytes":1048576,"outbox_max_records":100,"outbox_max_bytes":1048576,"change_max_items":256,"change_max_bytes":1048576,"dispatcher_capacity":100,"wire_batch_max_bytes":1048576}}]}]|}
  in
  let (Protocol.V2_response { outcome; _ }) =
    Protocol.response_of_yojson raw |> Result.get_ok
  in
  let output = Runtime.receive runtime (response initial outcome) in
  let catalog =
    List.find
      (fun (r : Protocol.request) ->
         match r.command with
         | V2_list_task_statuses _ -> true
         | _ -> false)
      output.requests
  in
  let definition n title : Graph.task_status_definition =
    { uuid = uuid (Printf.sprintf "b1000000-0000-4000-8000-%012d" n)
    ; title
    ; ident = None
    ; order = string_of_int n
    ; checkbox_state = None
    }
  in
  let choices = List.init 12 (fun n -> definition n "Same name") in
  let output =
    Runtime.receive
      runtime
      (response
         catalog
         (V2_task_statuses_outcome
            { property_uuid = Some page_uuid
            ; default_status = None
            ; items = choices
            ; next_cursor = None
            }))
  in
  Alcotest.(check bool)
    "catalog published"
    true
    (List.exists
       (fun r ->
          match r.Runtime.payload with
          | Task_statuses_changed { items; complete = true; _ } ->
            Rrbvec.length items = 12
          | _ -> false)
       output.responses);
  let output = changed runtime (window ~blocks:[ (List.hd choices).uuid ] ()) in
  let delta =
    List.find
      (fun (r : Protocol.request) ->
         match r.command with
         | V2_get_task_status_definitions _ -> true
         | _ -> false)
      output.requests
  in
  Alcotest.(check bool)
    "no full catalog refresh for rename"
    false
    (List.exists
       (fun (r : Protocol.request) ->
          match r.command with
          | V2_list_task_statuses _ -> true
          | _ -> false)
       output.requests);
  let renamed =
    Runtime.receive
      runtime
      (response
         delta
         (V2_task_status_definitions_outcome [ Some (definition 0 "Renamed") ]))
  in
  Alcotest.(check bool)
    "rename changes label while retaining UUID"
    true
    (List.exists
       (fun r ->
          match r.Runtime.payload with
          | Task_statuses_changed { items; _ } ->
            Rrbvec.to_seq items
            |> Seq.exists (fun (d : Graph.task_status_definition) ->
              d.title = "Renamed" && Graph.Uuid.equal d.uuid (List.hd choices).uuid)
          | _ -> false)
       renamed.responses);
  let reload =
    Runtime.submit runtime Journal_graph_request.Load_task_statuses
    |> fun output -> only "catalog retry" output.requests
  in
  let failing =
    Runtime.submit runtime Journal_graph_request.Load_task_statuses
    |> fun output -> only "old catalog failure" output.requests
  in
  let newer =
    Runtime.submit runtime Journal_graph_request.Load_task_statuses
    |> fun output -> only "newer catalog retry" output.requests
  in
  ignore
    (Runtime.receive
       runtime
       (response
          newer
          (V2_task_statuses_outcome
             { property_uuid = Some page_uuid
             ; default_status = None
             ; items = [ definition 0 "Newest" ]
             ; next_cursor = None
             })));
  let stale =
    Runtime.receive
      runtime
      (response
         reload
         (V2_task_statuses_outcome
            { property_uuid = Some page_uuid
            ; default_status = None
            ; items = [ definition 0 "Stale" ]
            ; next_cursor = None
            }))
  in
  Alcotest.(check int)
    "older catalog completion is ignored"
    0
    (List.length stale.responses);
  let old_failure =
    Runtime.receive
      runtime
      (response
         failing
         (V2_failed { code = "invalid-request"; message = "Old catalog error" }))
  in
  Alcotest.(check int)
    "old catalog failure is ignored"
    0
    (List.length old_failure.responses);
  let resync =
    Runtime.reconcile_push
      runtime
      ~request_generation:99L
      (Protocol.V2_resync_required_push
         { api_version = Protocol.api_version
         ; generation = "generation-2"
         ; reason = "overflow"
         })
  in
  let graph =
    List.find (fun (r : Protocol.request) -> r.command = V2_graph_info) resync.requests
  in
  let refreshed = Runtime.receive runtime (response graph outcome) in
  Alcotest.(check bool)
    "resync refreshes status catalog"
    true
    (List.exists
       (fun (r : Protocol.request) ->
          match r.command with
          | V2_list_task_statuses _ -> true
          | _ -> false)
       (resync.requests @ refreshed.requests));
  Runtime.reset runtime;
  let late =
    Runtime.receive
      runtime
      (response
         delta
         (V2_task_status_definitions_outcome [ Some (definition 0 "Renamed") ]))
  in
  Alcotest.(check int) "old graph catalog ignored" 0 (List.length late.responses)
;;

(* Exercise the production Runtime with valid bounded Worker pages. The fixture
   is ordered input, not a second implementation of Timeline projection. *)
type root_fixture =
  { owner : Graph.page
  ; roots : Protocol.v2_block_record list
  ; descendants : (Graph.Uuid.t * Protocol.v2_block_record list) list
  }

let root_fixture index count child_count =
  let day = 20260930 - index in
  let owner =
    { page with
      uuid = uuid (Printf.sprintf "a7000000-0000-4000-8000-%012d" index)
    ; title = Printf.sprintf "Journal %d" day
    ; kind = Journal_page { journal_day = day }
    }
  in
  let roots =
    List.init count (fun n ->
      { record with
        block =
          { block with
            uuid = uuid (Printf.sprintf "a7100000-0000-4000-8000-%06d%06d" index n)
          ; parent = owner.uuid
          ; page = owner.uuid
          ; title = Printf.sprintf "Root %d/%d" index n
          ; order = Printf.sprintf "%06d" n
          }
      })
  in
  let descendants =
    List.map
      (fun (r : Protocol.v2_block_record) ->
         ( r.block.uuid
         , List.init child_count (fun n ->
             { record with
               block =
                 { block with
                   uuid =
                     uuid
                       (Printf.sprintf
                          "a7200000-0000-4000-%04d-%012d"
                          index
                          ((int_of_string r.block.order * 100000) + n))
                 ; parent = r.block.uuid
                 ; page = owner.uuid
                 ; title = Printf.sprintf "Child %d" n
                 ; order = Printf.sprintf "%06d" n
                 ; properties = (if n = 1 then [ asset_type_property ] else [])
                 }
             }) ))
      roots
  in
  { owner; roots; descendants }
;;

let root_cursor n =
  Graph.Cursor.of_string ("fixture-offset:" ^ string_of_int n) |> Result.get_ok
;;

let root_offset = function
  | None -> 0
  | Some cursor -> Scanf.sscanf (Graph.Cursor.to_string cursor) "fixture-offset:%d" Fun.id
;;

let root_slice values limit cursor =
  let offset = root_offset cursor in
  let values = List.filteri (fun i _ -> i >= offset) values in
  let selected = List.take limit values in
  ( selected
  , if List.length values > List.length selected
    then Some (root_cursor (offset + List.length selected))
    else None )
;;

let initial_roots runtime generation =
  Runtime.submit
    runtime
    (Journal_graph_request.Load_feed
       { cursor = None; root_limit = 30; day_limit = 7; request_generation = generation })
;;

let drive_root_output ?(split_bytes = false) runtime fixtures (start : Runtime.output) =
  let queue = Queue.create () in
  let seen = ref []
  and outputs = ref start.responses in
  List.iter (fun r -> Queue.push r queue) start.requests;
  let children = List.concat_map (fun f -> f.descendants) fixtures in
  let ticks = ref 0 in
  while not (Queue.is_empty queue) do
    incr ticks;
    if !ticks > 1000 then Alcotest.fail "initial feed did not converge";
    let request : Protocol.request = Queue.pop queue in
    seen := request :: !seen;
    let outcome : Protocol.v2_outcome =
      match request.command with
      | V2_list_journals { limit; cursor; from_day; through_day; _ } ->
        let fixtures = List.filter (fun f -> match f.owner.kind with Journal_page {journal_day} -> from_day <= journal_day && journal_day <= through_day | _ -> false) fixtures in
        let selected, next_cursor = root_slice fixtures limit cursor in
        V2_journals_outcome
          { items =
              List.map
                (fun f ->
                   let journal_day =
                     match f.owner.kind with
                     | Journal_page { journal_day } -> journal_day
                     | _ -> assert false
                   in
                   Protocol.{ page = f.owner; journal_day; revision = "page-1" })
                selected
          ; next_cursor
          }
      | V2_get_page_tree { page; maximum_depth; limit; cursor; _ } ->
        Alcotest.(check int) "roots do not consume child budget" 0 maximum_depth;
        if split_bytes && limit > 2
        then
          V2_failed { code = "responseTooLarge"; message = "Fixture encoded byte limit" }
        else (
          let fixture =
            List.find (fun f -> Graph.Uuid.equal page f.owner.uuid) fixtures
          in
          let selected, next_cursor = root_slice fixture.roots limit cursor in
          V2_page_tree_outcome
            { page
            ; maximum_depth
            ; items =
                List.map
                  (fun value ->
                     Protocol.{ value; revision = "root-1"; depth = 0; parent = page })
                  selected
            ; next_cursor
            })
      | V2_get_children { parent; limit; cursor; _ } ->
        Alcotest.(check bool) "preview requests stay bounded" true (limit <= 3);
        if split_bytes && limit > 1
        then
          V2_failed { code = "responseTooLarge"; message = "Fixture preview byte limit" }
        else (
          let values = Option.value (List.assoc_opt parent children) ~default:[] in
          let selected, next_cursor = root_slice values limit cursor in
          V2_children_outcome
            { parent
            ; revision_scope = V2_children_revision parent
            ; scope_revision = "children-1"
            ; items =
                List.map (fun value -> Protocol.{ value; revision = "child-1" }) selected
            ; next_cursor
            })
      | V2_ack_changes _ ->
        V2_changes_acknowledged { generation = "generation-1"; through = "revision-2" }
      | _ -> Alcotest.fail "unexpected initial feed query"
    in
    let delivered = Runtime.receive runtime (response request outcome) in
    Alcotest.(check int)
      "duplicate completion is ignored"
      0
      (List.length (Runtime.receive runtime (response request outcome)).responses);
    outputs := !outputs @ delivered.responses;
    List.iter (fun r -> Queue.push r queue) delivered.requests
  done;
  !outputs, List.rev !seen
;;

let drive_roots ?(split_bytes = false) runtime fixtures start =
  let outputs, seen = drive_root_output ~split_bytes runtime fixtures start in
  let complete =
    List.filter_map
      (fun (r : Runtime.response) ->
         match r.payload with
         | Feed_loaded { feed; complete = true; _ } -> Some feed
         | _ -> None)
      outputs
  in
  only "one complete initial feed" complete, seen
;;

let normal_journal_fixture index count child_count =
  let fixture = root_fixture index count child_count in
  let day = if index = 30 then 20260831 else 20260930 - index in
  let id =
    uuid
      (Printf.sprintf
         "00000001-%04d-%04d-0000-000000000000"
         (day / 10000)
         (day mod 10000))
  in
  let owner =
    { fixture.owner with
      uuid = id
    ; name = string_of_int day
    ; title = string_of_int day
    ; kind = Journal_page { journal_day = day }
    }
  in
  let roots =
    List.map
      (fun (r : Protocol.v2_block_record) ->
         { r with block = { r.block with parent = id; page = id } })
      fixture.roots
  in
  let descendants =
    List.map
      (fun (root, values) ->
         ( root
         , List.map
             (fun (r : Protocol.v2_block_record) ->
                { r with block = { r.block with page = id } })
             values ))
      fixture.descendants
  in
  { owner; roots; descendants }
;;

let set_priority_calendar runtime =
  let sampler =
    Journal_calendar.Sampler.create
      ~clock:(fun () -> 1_788_278_400.)
      ~localtime:Unix.gmtime
      ()
  in
  Runtime.set_calendar runtime (Journal_calendar.Sampler.sample sampler |> Result.get_ok)
;;
let test_today_priority_batch () =
  let failures = ref [] in
  let check name f =
    try f () with
    | exn -> failures := (name ^ ": " ^ Printexc.to_string exn) :: !failures
  in
  List.iter
    (fun future_count ->
       List.iter
         (fun today_count ->
            check
              (Printf.sprintf "future=%d today=%d" future_count today_count)
              (fun () ->
                 let runtime = Runtime.create ~localtime:Unix.gmtime () in
                 set_priority_calendar runtime;
                 let future = normal_journal_fixture 0 future_count 4 in
                 let today = normal_journal_fixture 29 (max 0 today_count) 4 in
                 let older = normal_journal_fixture 30 3 0 in
                 let older =
                   { older with
                     owner =
                       { older.owner with
                         kind = Journal_page { journal_day = 20260831 }
                       ; name = "20260831"
                       ; title = "2026-08-31"
                       }
                   }
                 in
                 let fixtures =
                   if today_count < 0 then [ future; older ] else [ future; today; older ]
                 in
                 let feed, seen =
                   drive_roots runtime fixtures (initial_roots runtime 501L)
                 in
                 let entries =
                   List.concat_map
                     (fun (d : Journal_graph_projection.day_feed) -> d.entries)
                     feed.days
                 in
                 let today_entries =
                   List.filter
                     (fun (e : Journal_graph_projection.timeline_entry) ->
                        Journal_model.journal_day e.block = 20260901)
                     entries
                 in
                 Alcotest.(check int)
                   "Today occupies first batch before future roots"
                   (min 30 (max 0 today_count))
                   (List.length today_entries);
                 Alcotest.(check int)
                   "one shared thirty-root budget"
                   (min 30 (future_count + max 0 today_count + 3))
                   (List.length entries);
                 if today_count > 0
                 then (
                   let first_page =
                     List.find_map
                       (fun (r : Protocol.request) ->
                          match r.command with
                          | V2_get_page_tree { page; _ } -> Some page
                          | _ -> None)
                       seen
                   in
                   Alcotest.(check bool)
                     "Today root read occurs first"
                     true
                     (first_page = Some today.owner.uuid));
                 List.iter
                   (fun (e : Journal_graph_projection.timeline_entry) ->
                      if Journal_model.journal_day e.block <> 20260831
                      then
                        Alcotest.(check int)
                          "priority keeps independent previews"
                          3
                          (List.length e.child_summaries))
                   entries))
         [ -1; 0; 1; 29; 30; 31; 61 ])
    [ 0; 29; 30; 31 ];
  check "multiple future dates" (fun () ->
    let runtime = Runtime.create ~localtime:Unix.gmtime () in
    set_priority_calendar runtime;
    let older = normal_journal_fixture 30 1 0 in
    let older =
      { older with
        owner =
          { older.owner with
            kind = Journal_page { journal_day = 20260831 }
          ; name = "20260831"
          ; title = "2026-08-31"
          }
      }
    in
    let fixtures =
      List.init 10 (fun i -> normal_journal_fixture i 4 0) @ [ normal_journal_fixture 29 2 0; older ]
    in
    let feed, _ = drive_roots runtime fixtures (initial_roots runtime 502L) in
    let today =
      List.find_opt
        (fun (d : Journal_graph_projection.day_feed) -> d.page.day = 20260901)
        feed.days
    in
    Alcotest.(check int)
      "Today outside metadata packet still loads first"
      2
      (Option.fold
         ~none:0
         ~some:(fun (d : Journal_graph_projection.day_feed) -> List.length d.entries)
         today));
  if !failures <> [] then Alcotest.fail (String.concat "\n" (List.rev !failures))
;;
let test_today_priority_continuations () =
  let failures = ref [] in
  let check name f =
    try f () with
    | exn -> failures := (name ^ ": " ^ Printexc.to_string exn) :: !failures
  in
  List.iter
    (fun today_count ->
       List.iter
         (fun future_count ->
            check
              (Printf.sprintf "drain Today=%d future=%d" today_count future_count)
              (fun () ->
                 let runtime = Runtime.create ~localtime:Unix.gmtime () in
                 set_priority_calendar runtime;
                 let future = normal_journal_fixture 0 future_count 0
                 and today = normal_journal_fixture 29 (max 0 today_count) 0 in
                 let older = normal_journal_fixture 30 3 0 in
                 let older =
                   { older with
                     owner =
                       { older.owner with
                         kind = Journal_page { journal_day = 20260831 }
                       ; name = "20260831"
                       ; title = "2026-08-31"
                       }
                   }
                 in
                 let fixtures =
                   if today_count < 0 then [ future; older ] else [ future; today; older ]
                 in
                 let expected =
                   List.concat_map (fun f -> f.roots) fixtures
                   |> List.map (fun (r : Protocol.v2_block_record) ->
                     Graph.Uuid.to_string r.block.uuid)
                   |> List.sort String.compare
                 in
                 let rec drain generation output loaded =
                   if generation > 520L
                   then Alcotest.fail "priority pagination did not exhaust";
                   let feed, _ = drive_roots runtime fixtures output in
                   let entries =
                     List.concat_map
                       (fun (d : Journal_graph_projection.day_feed) -> d.entries)
                       feed.days
                   in
                   Alcotest.(check bool)
                     "each batch stays within thirty roots"
                     true
                     (List.length entries <= 30);
                   let ids =
                     List.map
                       (fun (e : Journal_graph_projection.timeline_entry) ->
                          Journal_model.id e.block)
                       entries
                   in
                   Alcotest.(check bool)
                     "subsequent batches never reread a selected root"
                     true
                     (List.for_all (fun id -> not (List.mem id loaded)) ids);
                   let loaded = loaded @ ids in
                   let next =
                     match
                       List.find_opt
                         (fun (d : Journal_graph_projection.day_feed) ->
                            d.has_more_entries)
                         feed.days
                     with
                     | Some d ->
                       Some
                         (Journal_graph_request.Load_day_blocks
                            { day = d.page.day
                            ; after = d.continuation
                            ; limit = 30
                            ; request_generation = Int64.succ generation
                            })
                     | None ->
                       Option.map
                         (fun cursor ->
                            Journal_graph_request.Load_feed
                              { cursor = Some cursor
                              ; root_limit = 30
                              ; day_limit = 7
                              ; request_generation = Int64.succ generation
                              })
                         feed.continuation
                   in
                   match next with
                   | None -> loaded
                   | Some request ->
                     drain (Int64.succ generation) (Runtime.submit runtime request) loaded
                 in
                 let loaded = drain 501L (initial_roots runtime 501L) [] in
                 Alcotest.(check (list string))
                   "all deferred future and older roots eventually load exactly once"
                   expected
                   (List.sort String.compare loaded)))
         [ 0; 29; 30; 31 ])
    [ -1; 0; 1; 29; 30; 31; 61 ];
  check "new day reselects priority" (fun () ->
    let runtime = Runtime.create ~localtime:Unix.gmtime () in
    let clock = ref 1_788_278_400. in
    let sampler =
      Journal_calendar.Sampler.create ~clock:(fun () -> !clock) ~localtime:Unix.gmtime ()
    in
    Runtime.set_calendar runtime (Journal_calendar.Sampler.sample sampler |> Result.get_ok);
    let today = normal_journal_fixture 29 1 0
    and tomorrow = normal_journal_fixture 28 31 0 in
    ignore (drive_roots runtime [ tomorrow; today ] (initial_roots runtime 501L));
    clock := !clock +. 86_400.;
    Runtime.set_calendar runtime (Journal_calendar.Sampler.sample sampler |> Result.get_ok);
    let feed, _ = drive_roots runtime [ tomorrow; today ] (initial_roots runtime 502L) in
    let days =
      List.concat_map
        (fun (d : Journal_graph_projection.day_feed) ->
           List.map (fun _ -> d.page.day) d.entries)
        feed.days
    in
    Alcotest.(check (list int))
      "midnight uses new Today within the same quota"
      (List.init 30 (fun _ -> 20260902))
      days);
  if !failures <> [] then Alcotest.fail (String.concat "\n" (List.rev !failures))
;;
(* A normal remote structure edit can retire the Worker cursor. Exercise both
   public owners: Timeline restarts the day, Runtime must retain later dates. *)
let test_today_date_traversal_survives_recovery () =
  let module T = Journal_timeline_state in
  let failures = ref [] in
  let check name f =
    try f () with
    | exn -> failures := (name ^ ": " ^ Printexc.to_string exn) :: !failures
  in
  List.iter
    (fun mode ->
       List.iter
         (fun today_count ->
            check (Printf.sprintf "%s Today=%d" mode today_count) (fun () ->
              let runtime = Runtime.create ~localtime:Unix.gmtime () in
              let clock = ref 1_788_278_400. in
              let sampler =
                Journal_calendar.Sampler.create
                  ~clock:(fun () -> !clock)
                  ~localtime:Unix.gmtime
                  ()
              in
              Runtime.set_calendar
                runtime
                (Journal_calendar.Sampler.sample sampler |> Result.get_ok);
              let future = normal_journal_fixture 0 31 0
              and original_today = normal_journal_fixture 29 today_count 0
              and older = normal_journal_fixture 30 3 0 in
              let fixtures = ref [ future; original_today; older ] in
              let first, _ = drive_roots runtime !fixtures (initial_roots runtime 601L) in
              let state =
                ref
                  (T.empty ~today:20260901
                   |> fun state ->
                   T.begin_request state ~generation:601L (Feed { cursor = None })
                   |> fun state -> T.apply_feed state ~generation:601L first)
              in
              let generation = ref 602L
              and day = ref 20260901 in
              if mode = "midnight"
              then (
                clock := !clock +. 86_400.;
                Runtime.set_calendar
                  runtime
                  (Journal_calendar.Sampler.sample sampler |> Result.get_ok);
                let new_today = normal_journal_fixture 28 today_count 0 in
                fixtures := [ future; new_today; original_today; older ];
                day := 20260902;
                state := T.set_today !state ~today:!day;
                let feed, _ =
                  drive_roots runtime !fixtures (initial_roots runtime !generation)
                in
                (state
                 := T.begin_request
                      !state
                      ~generation:!generation
                      (Feed { cursor = None })
                    |> fun state ->
                    T.refresh_feed state ~generation:!generation ~complete:true feed);
                generation := Int64.succ !generation);
              let current =
                List.find
                  (fun f ->
                     match f.owner.kind with
                     | Journal_page { journal_day } -> journal_day = !day
                     | _ -> false)
                  !fixtures
              in
              let edited = List.hd current.roots in
              let roots =
                if mode = "reconcile-delete"
                then List.take (List.length current.roots - 1) current.roots
                else if mode = "reconcile"
                then
                  { edited with
                    block = { edited.block with title = "Normal remote edit" }
                  }
                  :: List.tl current.roots
                else
                  current.roots
                  @ [ { edited with
                        block =
                          { edited.block with
                            uuid =
                              uuid (Printf.sprintf "a7300000-0000-4000-8000-%012d" !day)
                          ; title = "Normal remote root insert"
                          ; order = "z"
                          }
                      }
                    ]
              in
              let changed_page =
                { current with
                  roots
                ; owner =
                    { current.owner with
                      updated_at_ms = Int64.succ current.owner.updated_at_ms
                    }
                }
              in
              fixtures
              := List.map
                   (fun f ->
                      if Graph.Uuid.equal f.owner.uuid current.owner.uuid
                      then changed_page
                      else f)
                   !fixtures;
              if mode = "reconcile" || mode = "reconcile-delete"
              then (
                let outputs, _ =
                  drive_root_output
                    runtime
                    !fixtures
                    (changed
                       runtime
                       (window
                          ~scopes:[ Protocol.V2_page_tree_interest current.owner.uuid ]
                          ()))
                in
                let page, value =
                  List.find_map
                    (fun (r : Runtime.response) ->
                       match r.payload with
                       | Page_tree_reconciled { page; value } -> Some (page, value)
                       | _ -> None)
                    outputs
                  |> Option.get
                in
                state := T.replace_timeline_entry_page !state ~page value)
              else (
                let count = T.retained_slot_count !state in
                state
                := T.observe_visible_range !state ~first_index:0 ~last_exclusive:count;
                let request = T.next_request !state |> Option.get in
                let command =
                  match request with
                  | T.Day { day; after } ->
                    Journal_graph_request.Load_day_blocks
                      { day; after; limit = 30; request_generation = !generation }
                  | _ -> Alcotest.fail "Today continuation missing"
                in
                state := T.begin_request !state ~generation:!generation request;
                let root =
                  only "one continued root read" (Runtime.submit runtime command).requests
                in
                let code = if mode = "retry" then "unavailable" else "staleReadCursor" in
                let failed =
                  Runtime.receive
                    runtime
                    (response
                       root
                       (V2_failed
                          { code; message = "Normal remote structure revision changed" }))
                in
                List.iter
                  (fun (r : Runtime.response) ->
                     match r.payload with
                     | Day_blocks_failed { request_generation; day; stale_cursor; _ } ->
                       state
                       := T.fail_day_request
                            !state
                            ~generation:request_generation
                            ~day
                            ~stale_cursor
                            ~message:"Remote update"
                     | _ -> ())
                  failed.responses;
                if mode = "retry" then state := T.retry_day !state ~day:!day;
                (match T.next_request !state with
                 | Some (Day { after = None; _ }) -> ()
                 | _ ->
                   Alcotest.fail
                     "recovery did not restart without the invalid root cursor");
                generation := Int64.succ !generation);
              let iterations = ref 0 in
              let rec drain () =
                incr iterations;
                if !iterations > 15 then Alcotest.fail "recovery did not settle";
                let size = T.retained_slot_count !state in
                state
                := T.observe_visible_range !state ~first_index:0 ~last_exclusive:size;
                match T.next_request !state with
                | None -> ()
                | Some request ->
                  let command =
                    match request with
                    | T.Day { day; after } ->
                      Journal_graph_request.Load_day_blocks
                        { day; after; limit = 30; request_generation = !generation }
                    | Feed { cursor } ->
                      Load_feed
                        { cursor
                        ; root_limit = 30
                        ; day_limit = 7
                        ; request_generation = !generation
                        }
                  in
                  state := T.begin_request !state ~generation:!generation request;
                  let feed, _ =
                    drive_roots runtime !fixtures (Runtime.submit runtime command)
                  in
                  let anchor = T.retained_slot !state (T.first_visible_index !state) in
                  state := T.apply_feed !state ~generation:!generation feed;
                  (match anchor with
                   | Some (T.Top_level old) ->
                     let fresh = T.retained_slot !state (T.first_visible_index !state) in
                     Alcotest.(check (option string))
                       "recovery preserves the visible UUID anchor"
                       (Some (Journal_model.id old.block))
                       (match fresh with
                        | Some (T.Top_level e) -> Some (Journal_model.id e.block)
                        | _ -> None)
                   | _ -> ());
                  generation := Int64.succ !generation;
                  drain ()
              in
              drain ();
              let actual =
                T.fold_slots
                  (fun ids -> function
                     | T.Top_level e -> Journal_model.id e.block :: ids
                     | _ -> ids)
                  []
                  !state
                |> List.sort String.compare
              in
              let expected =
                List.concat_map
                  (fun f ->
                     List.map
                       (fun (r : Protocol.v2_block_record) ->
                          Graph.Uuid.to_string r.block.uuid)
                       f.roots)
                  !fixtures
                |> List.sort String.compare
              in
              Alcotest.(check (list string))
                "recovery preserves exact Today, deferred future and past UUID set"
                expected
                actual;
              let days =
                T.fold_slots
                  (fun days -> function
                     | T.Top_level e -> Journal_model.journal_day e.block :: days
                     | _ -> days)
                  []
                  !state
                |> List.rev
              in
              Alcotest.(check (list int))
                "recovery keeps chronological display order"
                (List.sort (fun a b -> Int.compare b a) days)
                days))
         [ 31; 61 ])
    [ "stale"; "retry"; "reconcile"; "reconcile-delete"; "midnight" ];
  if !failures <> [] then Alcotest.fail (String.concat "\n" (List.rev !failures))
;;

let test_changed_point_ownership () =
  let failures = ref [] in
  let check name f =
    try f () with
    | exn -> failures := (name ^ ": " ^ Printexc.to_string exn) :: !failures
  in
  let updates output =
    List.filter_map
      (fun (r : Runtime.response) ->
         match r.payload with
         | Block_updated { block; _ } -> Some block
         | _ -> None)
      output.Runtime.responses
  in
  let point runtime block_id =
    let output = changed runtime (window ~blocks:[ block_id ] ()) in
    List.find
      (fun (r : Protocol.request) ->
         match r.command with
         | V2_get_outline_block { block; _ } -> Graph.Uuid.equal block block_id
         | _ -> false)
      output.requests
  in
  let complete runtime request value =
    Runtime.receive
      runtime
      (response
         request
         (V2_block_outcome (V2_present_block { value; revision = "changed-block" })))
  in
  let context_request output page =
    List.find_opt
      (fun (r : Protocol.request) ->
         match r.command with
         | V2_get_page { page = id; _ } -> Graph.Uuid.equal id page
         | _ -> false)
      output.Runtime.requests
  in
  let require_context output page =
    match context_request output page with
    | Some request -> request
    | None -> Alcotest.fail "moved point must resolve its actual page"
  in
  let setup known =
    let runtime = Runtime.create ~localtime:Unix.gmtime () in
    set_priority_calendar runtime;
    let source = normal_journal_fixture 29 2 0
    and target = normal_journal_fixture 0 1 0 in
    ignore
      (drive_roots
         runtime
         (if known then [ target; source ] else [ source ])
         (initial_roots runtime 701L));
    runtime, source, target
  in
  List.iter
    (fun (known, child, ordinary) ->
       check
         (Printf.sprintf "known=%b child=%b ordinary=%b" known child ordinary)
         (fun () ->
            let runtime, source, target = setup known in
            let target =
              if ordinary
              then { target with owner = { target.owner with kind = Ordinary_page } }
              else target
            in
            let before = List.hd source.roots in
            let value =
              { before with
                block =
                  { before.block with
                    page = target.owner.uuid
                  ; parent =
                      (if child
                       then (List.hd target.roots).block.uuid
                       else target.owner.uuid)
                  ; title = "Normal moved point"
                  }
              }
            in
            let first = complete runtime (point runtime before.block.uuid) value in
            let output =
              if known
              then first
              else (
                Alcotest.(check int)
                  "unknown page cannot publish a guessed date"
                  0
                  (List.length (updates first));
                let request = require_context first target.owner.uuid in
                Runtime.receive
                  runtime
                  (response
                     request
                     (V2_page_outcome
                        (V2_present_page { page = target.owner; revision = "new-page" }))))
            in
            let block = only "one correctly contextualized update" (updates output) in
            Alcotest.(check string)
              "returned page owns the model"
              (Graph.Uuid.to_string target.owner.uuid)
              (Journal_model.page_id block);
            Alcotest.(check (option int))
              "date comes from the actual page"
              (if ordinary then None else Some 20260930)
              (Journal_model.journal_day_opt block);
            Alcotest.(check (option string))
              "root or child parent uses actual page"
              (if child
               then Some (Graph.Uuid.to_string (List.hd target.roots).block.uuid)
               else None)
              (Journal_model.parent_id block)))
    [ true, false, false
    ; true, true, false
    ; false, false, false
    ; false, true, false
    ; false, false, true
    ];
  check "newer point retires an old point" (fun () ->
    let runtime, source, target = setup true in
    let before = List.hd source.roots in
    let old = point runtime before.block.uuid in
    let fresh = point runtime before.block.uuid in
    let moved =
      { before with
        block =
          { before.block with
            page = target.owner.uuid
          ; parent = target.owner.uuid
          ; title = "New moved value"
          }
      }
    in
    ignore (complete runtime fresh moved);
    let late =
      complete
        runtime
        old
        { before with block = { before.block with title = "Old source value" } }
    in
    Alcotest.(check int)
      "old point cannot restore source ownership"
      0
      (List.length (updates late)));
  check "newer point retires old page resolution" (fun () ->
    let runtime, source, target = setup false in
    let before = List.hd source.roots in
    let moved =
      { before with
        block = { before.block with page = target.owner.uuid; parent = target.owner.uuid }
      }
    in
    let unresolved = complete runtime (point runtime before.block.uuid) moved in
    let lookup = require_context unresolved target.owner.uuid in
    let back =
      complete
        runtime
        (point runtime before.block.uuid)
        { before with block = { before.block with title = "Moved back normally" } }
    in
    ignore (only "new source observation" (updates back));
    let late =
      Runtime.receive
        runtime
        (response
           lookup
           (V2_page_outcome
              (V2_present_page { page = target.owner; revision = "old-target-page" })))
    in
    Alcotest.(check int)
      "late context cannot resurrect old move"
      0
      (List.length (updates late)));
  check "missing moved page does not publish mixed context" (fun () ->
    let runtime, source, target = setup false in
    let before = List.hd source.roots in
    let value =
      { before with
        block = { before.block with page = target.owner.uuid; parent = target.owner.uuid }
      }
    in
    let unresolved = complete runtime (point runtime before.block.uuid) value in
    let lookup = require_context unresolved target.owner.uuid in
    let missing =
      Runtime.receive
        runtime
        (response
           lookup
           (V2_page_outcome
              (V2_missing_page { uuid = target.owner.uuid; revision = "missing-page" })))
    in
    Alcotest.(check int)
      "missing context never becomes a Timeline model"
      0
      (List.length (updates missing)));
  if !failures <> [] then Alcotest.fail (String.concat "\n" (List.rev !failures))
;;

let test_initial_thirty_roots () =
  let runtime = Runtime.create ~localtime:Unix.gmtime () in
  set_calendar runtime;
  let fixtures = [ root_fixture 0 20 4; root_fixture 1 20 4; root_fixture 2 20 4 ] in
  let feed, _ = drive_roots runtime fixtures (initial_roots runtime 77L) in
  let entries =
    List.concat_map (fun (d : Journal_graph_projection.day_feed) -> d.entries) feed.days
  in
  Alcotest.(check int)
    "headers and previews do not consume roots"
    30
    (List.length entries);
  Alcotest.(check (list string))
    "date and sibling order"
    (List.map
       (fun (r : Protocol.v2_block_record) -> Graph.Uuid.to_string r.block.uuid)
       ((List.nth fixtures 0).roots @ List.take 10 (List.nth fixtures 1).roots))
    (List.map
       (fun (e : Journal_graph_projection.timeline_entry) -> Journal_model.id e.block)
       entries);
  List.iter
    (fun (e : Journal_graph_projection.timeline_entry) ->
       Alcotest.(check int)
         "every selected root has its preview"
         3
         (List.length e.child_summaries);
       Alcotest.(check bool)
         "asset child metadata survives"
         true
         (List.exists
            (fun (c : Journal_graph_projection.child_summary) ->
               c.asset_file_type = Some "png")
            e.child_summaries))
    entries;
  let last = List.hd (List.rev feed.days) in
  Alcotest.(check bool)
    "same-day continuation retained"
    true
    (Option.is_some last.continuation);
  let output =
    Runtime.submit
      runtime
      (Journal_graph_request.Load_day_blocks
         { day = last.page.day
         ; after = last.continuation
         ; limit = 30
         ; request_generation = 78L
         })
  in
  match (only "later roots read" output.requests).command with
  | V2_get_page_tree { maximum_depth; limit; cursor; _ } ->
    Alcotest.(check int) "later quota is thirty" 30 limit;
    Alcotest.(check int) "root cursor keeps root shape" 0 maximum_depth;
    Alcotest.(check int) "same-day cursor follows tenth root" 10 (root_offset cursor)
  | _ -> Alcotest.fail "later root cursor changed protocol shape"
;;

let test_later_thirty_crosses_dates () =
  let runtime = Runtime.create ~localtime:Unix.gmtime () in
  set_calendar runtime;
  let fixtures = [root_fixture 0 40 5;root_fixture 1 50 5] in
  let feed,_ = drive_roots runtime fixtures (initial_roots runtime 77L) in
  let day=List.hd feed.days in
  let output=Runtime.submit runtime (Journal_graph_request.Load_day_blocks
      {day=day.page.day;after=day.continuation;limit=30;request_generation=78L}) in
  let feed,_=drive_roots runtime fixtures output in
  Alcotest.(check int) "every later batch fills thirty roots across dates" 30
    (List.fold_left (fun n (d:Journal_graph_projection.day_feed)->n+List.length d.entries) 0 feed.days);
  Alcotest.(check (list int)) "same-day tail then older date" [10;20]
    (List.map (fun (d:Journal_graph_projection.day_feed)->List.length d.entries) feed.days);
  let last=List.hd (List.rev feed.days) in
  let third,_=drive_roots runtime fixtures (Runtime.submit runtime (Journal_graph_request.Load_day_blocks
      {day=last.page.day;after=last.continuation;limit=30;request_generation=79L})) in
  Alcotest.(check int) "third batch remains thirty" 30
    (List.fold_left (fun n (d:Journal_graph_projection.day_feed)->n+List.length d.entries) 0 third.days);
  let ids feeds=List.concat_map (fun (f:Journal_graph_projection.feed)->
      List.concat_map (fun (d:Journal_graph_projection.day_feed)->List.map
          (fun (e:Journal_graph_projection.timeline_entry)->Journal_model.id e.block) d.entries) f.days) feeds in
  let all=ids [feed;third] in
  Alcotest.(check int) "continuations do not repeat roots" 60 (List.length (List.sort_uniq String.compare all))
;;

let test_later_date_cursor_no_progress_settles () =
  let runtime=Production_runtime.create ~localtime:Unix.gmtime () in
  set_calendar runtime;
  let fixture=root_fixture 0 31 0 in
  let feed,_=drive_roots runtime [fixture;root_fixture 1 1 0] (initial_roots runtime 77L) in
  let day=List.hd feed.days in
  let root=Runtime.submit runtime (Journal_graph_request.Load_day_blocks
      {day=day.page.day;after=day.continuation;limit=30;request_generation=78L})
    |> fun o->only "later tail query" o.requests in
  let output=Production_runtime.receive runtime (response root (V2_page_tree_outcome
      {page=fixture.owner.uuid;maximum_depth=0;items=[];next_cursor=None})) in
  let listing=only "older date query" output.requests in
  let cursor=root_cursor 1 in
  let output=Production_runtime.receive runtime (response listing (V2_journals_outcome {items=[];next_cursor=Some cursor})) in
  let repeated=only "next date packet" output.requests in
  let output=Production_runtime.receive runtime (response repeated (V2_journals_outcome {items=[];next_cursor=Some cursor})) in
  match (only "visible terminal failure" output.responses).payload with
  | Day_blocks_failed {request_generation=78L;day=20260930;_}->()
  | _ -> Alcotest.fail "date cursor failure lost its continuation owner"
;;

let test_initial_sparse_roots () =
  let runtime = Runtime.create ~localtime:Unix.gmtime () in
  set_calendar runtime;
  let fixtures =
    List.init 18 (fun i -> root_fixture i (if i mod 3 = 0 then 0 else 3) 0)
  in
  let feed, seen = drive_roots runtime fixtures (initial_roots runtime 77L) in
  Alcotest.(check int)
    "sparse dates fill thirty"
    30
    (List.fold_left
       (fun n (d : Journal_graph_projection.day_feed) -> n + List.length d.entries)
       0
       feed.days);
  Alcotest.(check bool)
    "continues beyond first seven dates"
    true
    (List.length
       (List.filter
          (fun r ->
             match r.Protocol.command with
             | V2_list_journals _ -> true
             | _ -> false)
          seen)
     > 1)
;;

let test_initial_filtered_exhaustion () =
  let runtime = Runtime.create ~localtime:Unix.gmtime () in
  set_calendar runtime;
  let fixture = root_fixture 0 3 0 in
  let hidden =
    { record with
      block =
        { block with
          uuid = unrelated_uuid
        ; page = fixture.owner.uuid
        ; parent = fixture.owner.uuid
        ; title = ""
        }
    }
  in
  let fixtures = [ { fixture with roots = hidden :: fixture.roots } ] in
  let feed, _ = drive_roots runtime fixtures (initial_roots runtime 77L) in
  Alcotest.(check int)
    "blank rows do not count"
    3
    (List.fold_left
       (fun n (d : Journal_graph_projection.day_feed) -> n + List.length d.entries)
       0
       feed.days);
  Alcotest.(check bool)
    "exhausted feed has no false continuation"
    false
    (Option.is_some feed.continuation)
;;

let test_initial_wide_preview () =
  let runtime = Runtime.create ~localtime:Unix.gmtime () in
  set_calendar runtime;
  let fixture = root_fixture 0 1 10050 in
  let parent, values = List.hd fixture.descendants in
  let marker : Graph.property_summary =
    { asset_type_property with
      ident = "logseq.property/created-from-property"
    ; values = [ Entity_value unrelated_uuid ]
    }
  in
  let values =
    List.mapi
      (fun i (r : Protocol.v2_block_record) ->
         if i < 3 then { r with block = { r.block with properties = [ marker ] } } else r)
      values
  in
  let feed, seen =
    drive_roots
      runtime
      [ { fixture with descendants = [ parent, values ] } ]
      (initial_roots runtime 77L)
  in
  let entry = List.hd (List.hd feed.days).entries in
  Alcotest.(check (list string))
    "skip property values without draining branch"
    [ "Child 3"; "Child 4"; "Child 5" ]
    (List.map
       (fun (c : Journal_graph_projection.child_summary) -> c.source)
       entry.child_summaries);
  Alcotest.(check int)
    "two small child pages suffice"
    2
    (List.length
       (List.filter
          (fun r ->
             match r.Protocol.command with
             | V2_get_children _ -> true
             | _ -> false)
          seen))
;;

let test_initial_byte_splitting () =
  let runtime = Runtime.create ~localtime:Unix.gmtime () in
  set_calendar runtime;
  let feed, _ =
    drive_roots
      ~split_bytes:true
      runtime
      [ root_fixture 0 35 4 ]
      (initial_roots runtime 77L)
  in
  let entries =
    List.concat_map (fun (d : Journal_graph_projection.day_feed) -> d.entries) feed.days
  in
  Alcotest.(check int) "byte splitting still fills thirty" 30 (List.length entries);
  List.iter
    (fun (e : Journal_graph_projection.timeline_entry) ->
       Alcotest.(check int)
         "small packets retain three previews"
         3
         (List.length e.child_summaries))
    entries
;;

let test_initial_reset_and_later_quota () =
  let runtime = Runtime.create () in
  let old = only "initial listing" (initial_roots runtime 77L).requests in
  Runtime.reset runtime;
  let delivered =
    Runtime.receive
      runtime
      (response old (V2_journals_outcome { items = []; next_cursor = None }))
  in
  Alcotest.(check int) "reset fences old result" 0 (List.length delivered.responses);
  let start =
    Runtime.submit
      runtime
      (Journal_graph_request.Load_feed
         { cursor = Some {before_day=Some 20260901;skipped_day=None}
         ; day_limit = 7
         ; root_limit = 30

         ; request_generation = 78L
         })
  in
  match (only "older dates still use existing request" start.requests).command with
  | V2_list_journals { limit; through_day; _ } ->
    Alcotest.(check int) "older metadata quota remains seven" 7 limit;
    Alcotest.(check int) "calendar upper bound remains" 20260831 through_day
  | _ -> Alcotest.fail "older feed changed shape"
;;

let test_initial_refresh_range split_bytes () =
  let runtime = Runtime.create ~localtime:Unix.gmtime () in
  set_calendar runtime;
  let fixtures = [ root_fixture 0 150 1 ] in
  let feed, _ = drive_roots ~split_bytes runtime fixtures (initial_roots runtime 77L) in
  let day = List.hd feed.days in
  let expected = if split_bytes then 30 else 60 in
  if not split_bytes
  then (
    let later =
      Runtime.submit
        runtime
        (Journal_graph_request.Load_day_blocks
           { day = day.page.day
           ; after = day.continuation
           ; limit = 30
           ; request_generation = 78L
           })
    in
    let results, _ = drive_root_output runtime fixtures later in
    match
      List.find_map
        (fun (r : Runtime.response) ->
           match r.payload with
           | Feed_loaded { feed; complete=true; _ } -> Some (List.hd feed.days)
           | _ -> None)
        results
    with
    | Some page ->
      Alcotest.(check int) "later batch is thirty" 30 (List.length page.entries)
    | None -> Alcotest.fail "later roots never completed");
  let refreshed =
    changed
      runtime
      (window ~scopes:[ Protocol.V2_page_tree_interest (List.hd fixtures).owner.uuid ] ())
  in
  let results, _ = drive_root_output runtime fixtures refreshed in
  let page =
    List.find_map
      (fun (r : Runtime.response) ->
         match r.payload with
         | Page_tree_reconciled { value; _ } -> Some value
         | _ -> None)
      results
  in
  match page with
  | Some page ->
    Alcotest.(check int)
      "refresh preserves the loaded root prefix"
      expected
      (List.length page.entries)
  | None -> Alcotest.fail "root reconciliation never completed"
;;

let test_initial_refresh_after_restarting_prefix () =
  let runtime = Runtime.create ~localtime:Unix.gmtime () in
  set_calendar runtime;
  let fixture = root_fixture 0 150 0 in
  let feed, _ = drive_roots runtime [ fixture ] (initial_roots runtime 77L) in
  let day = List.hd feed.days in
  ignore
    (drive_root_output
       runtime
       [ fixture ]
       (Runtime.submit
          runtime
          (Journal_graph_request.Load_day_blocks
             { day = day.page.day
             ; after = day.continuation
             ; limit = 30
             ; request_generation = 78L
             })));
  let inserted =
    { record with
      block =
        { block with
          uuid = unrelated_uuid
        ; parent = fixture.owner.uuid
        ; page = fixture.owner.uuid
        ; title = "New leading root"
        ; order = "-0001"
        }
    }
  in
  let newer = { fixture with roots = inserted :: fixture.roots } in
  ignore (drive_roots runtime [ newer ] (initial_roots runtime 79L));
  let fresh =
    changed
      runtime
      (window ~scopes:[ Protocol.V2_page_tree_interest fixture.owner.uuid ] ())
  in
  let outputs, _ = drive_root_output runtime [ newer ] fresh in
  let page =
    List.find_map
      (fun (r : Runtime.response) ->
         match r.payload with
         | Page_tree_reconciled { value; _ } -> Some value
         | _ -> None)
      outputs
    |> Option.get
  in
  Alcotest.(check int)
    "new prefix keeps the previous suffix through its last root"
    61
    (List.length page.entries)
;;

let load_ninety_roots runtime fixture =
  set_calendar runtime;
  let feed, _ = drive_roots runtime [ fixture ] (initial_roots runtime 77L) in
  let day = ref (List.hd feed.days) in
  for generation = 78 to 79 do
    let output = Runtime.submit runtime
        (Journal_graph_request.Load_day_blocks
           { day = !day.page.day; after = !day.continuation; limit = 30
           ; request_generation = Int64.of_int generation }) in
    let feed, _ = drive_roots runtime [ fixture ] output in
    day := List.hd feed.days
  done
;;

let fixture_root_tree fixture (request : Protocol.request) =
  match request.command with
  | V2_get_page_tree { page; maximum_depth; limit; cursor; _ } ->
    let selected, next_cursor = root_slice fixture.roots limit cursor in
    Protocol.V2_page_tree_outcome
      { page; maximum_depth
      ; items = List.map (fun value ->
          Protocol.{ value; revision = "root-1"; depth = 0; parent = page }) selected
      ; next_cursor }
  | _ -> Alcotest.fail "expected a retained root read"
;;

(* Both refresh owners are created by the public invalidation event. Hold the
   reconciliation at each asynchronous boundary while the prefix finishes. *)
let test_prefix_preserves_reconciliation ~resync stage () =
  let runtime = Runtime.create ~localtime:Unix.gmtime () in
  let fixture = root_fixture 0 90 0 in
  load_ninety_roots runtime fixture;
  let edited = List.nth fixture.roots 70 in
  let deleted = List.nth fixture.roots 80 in
  let fresh = { fixture with roots =
    List.filter_map (fun (r : Protocol.v2_block_record) ->
      if Graph.Uuid.equal r.block.uuid deleted.block.uuid then None
      else if Graph.Uuid.equal r.block.uuid edited.block.uuid then
        Some { r with block = { r.block with title = "Remote suffix edit" } }
      else Some r) fixture.roots } in
  let refresh =
    if resync then Runtime.reconcile_push runtime ~request_generation:90L
        (Protocol.V2_resync_required_push
           { api_version = Protocol.api_version; generation = "generation-2"
           ; reason = "overflow" })
    else changed runtime (window ~scopes:
        [ Protocol.V2_page_tree_interest fixture.owner.uuid
        ; V2_journal_index_interest ] ())
  in
  let tree = List.find (fun (r : Protocol.request) -> match r.command with
      | V2_get_page_tree _ -> true | _ -> false) refresh.requests in
  let dates = List.find (fun (r : Protocol.request) -> match r.command with
      | V2_list_journals _ -> true | _ -> false) refresh.requests in
  let held = match stage with
    | `Root -> { Runtime.requests = [tree]; responses = [] }
    | `Preview | `Continuation ->
      Runtime.receive runtime (response tree (fixture_root_tree fresh tree))
  in
  let held = match stage with
    | `Root | `Preview -> held
    | `Continuation ->
      let rec finish_previews (output : Runtime.output) =
        let request = only "one retained refresh continuation" output.requests in
        match request.command with
        | V2_get_page_tree _ -> output
        | V2_get_children { parent; _ } ->
          finish_previews (Runtime.receive runtime (response request
              (Protocol.V2_children_outcome
                 { parent; revision_scope = V2_children_revision parent
                 ; scope_revision = "children-1"; items = []; next_cursor = None })))
        | _ -> Alcotest.fail "unexpected reconciliation request"
      in
      finish_previews held
  in
  let prefix, _ = drive_roots runtime [fresh]
      { Runtime.requests = [dates]; responses = [] } in
  Alcotest.(check int) "prefix still publishes thirty roots" 30
    (List.length (List.hd prefix.days).entries);
  let outputs, _ = drive_root_output runtime [fresh] held in
  let reconciled = List.filter_map (fun (r : Runtime.response) -> match r.payload with
      | Page_tree_reconciled {value;_} -> Some value | _ -> None) outputs in
  let value = only "retained suffix reconciliation must finish" reconciled in
  Alcotest.(check int) "remote deletion removes a retained suffix root" 89
    (List.length value.entries);
  Alcotest.(check bool) "deleted suffix UUID is absent" false
    (List.exists (fun (e : Journal_graph_projection.timeline_entry) ->
       Journal_model.id e.block = Graph.Uuid.to_string deleted.block.uuid) value.entries);
  let updated = List.find (fun (e : Journal_graph_projection.timeline_entry) ->
      Journal_model.id e.block = Graph.Uuid.to_string edited.block.uuid) value.entries in
  Alcotest.(check string) "retained suffix contains the remote edit"
    "Remote suffix edit" (Journal_model.source updated.block)
;;

let test_newer_reconciliation_fences_old_results () =
  let runtime = Runtime.create ~localtime:Unix.gmtime () in
  let fixture = root_fixture 0 90 0 in
  load_ninety_roots runtime fixture;
  let refresh () = changed runtime
      (window ~scopes:[Protocol.V2_page_tree_interest fixture.owner.uuid] ()) in
  let old = only "held old reconciliation" (hydration_requests (refresh ())) in
  let fresh, _ = drive_root_output runtime [fixture] (refresh ()) in
  Alcotest.(check int) "newer reconciliation publishes once" 1
    (List.length (List.filter (fun (r : Runtime.response) -> match r.payload with
         | Page_tree_reconciled _ -> true | _ -> false) fresh));
  let late = Runtime.receive runtime (response old (fixture_root_tree fixture old)) in
  Alcotest.(check int) "older reconciliation cannot publish" 0 (List.length late.responses);
  Alcotest.(check int) "older reconciliation cannot continue" 0 (List.length late.requests);
  let old_graph = only "held retired graph reconciliation" (hydration_requests (refresh ())) in
  Runtime.reset runtime;
  let retired = Runtime.receive runtime
      (response old_graph (fixture_root_tree fixture old_graph)) in
  Alcotest.(check int) "retired graph cannot publish" 0 (List.length retired.responses);
  Alcotest.(check int) "retired graph cannot continue" 0 (List.length retired.requests)
;;

let test_initial_later_read_superseded () =
  let runtime = Runtime.create ~localtime:Unix.gmtime () in
  set_calendar runtime;
  let fixture = root_fixture 0 150 1 in
  let feed, _ = drive_roots runtime [ fixture ] (initial_roots runtime 77L) in
  let day = List.hd feed.days in
  let pending =
    Runtime.submit
      runtime
      (Journal_graph_request.Load_day_blocks
         { day = day.page.day
         ; after = day.continuation
         ; limit = 30
         ; request_generation = 78L
         })
  in
  let old = only "held later request" pending.requests in
  let fresh =
    changed
      runtime
      (window ~scopes:[ Protocol.V2_page_tree_interest fixture.owner.uuid ] ())
  in
  ignore (drive_root_output runtime [ fixture ] fresh);
  let values = List.take 30 (List.drop 30 fixture.roots) in
  let stale =
    Runtime.receive
      runtime
      (response
         old
         (V2_page_tree_outcome
            { page = fixture.owner.uuid
            ; maximum_depth = 0
            ; items =
                List.map
                  (fun value ->
                     Protocol.
                       { value; revision = "old"; depth = 0; parent = fixture.owner.uuid })
                  values
            ; next_cursor = Some (root_cursor 60)
            }))
  in
  Alcotest.(check bool)
    "superseded later request settles rather than wedging pagination"
    true
    (List.exists
       (fun (r : Runtime.response) ->
          match r.payload with
          | Day_blocks_failed { stale_cursor = true; _ } -> true
          | _ -> false)
       stale.responses)
;;

let test_initial_superseded_and_singleton () =
  let runtime = Runtime.create ~localtime:Unix.gmtime () in
  set_calendar runtime;
  let old = only "old listing" (initial_roots runtime 77L).requests in
  let fresh = initial_roots runtime 78L in
  let out =
    Runtime.receive
      runtime
      (response old (V2_journals_outcome { items = []; next_cursor = None }))
  in
  Alcotest.(check int)
    "superseded initial generation is ignored"
    0
    (List.length out.responses);
  ignore (drive_roots runtime [ root_fixture 0 1 0 ] fresh);
  let runtime = Runtime.create () in
  let listing = only "singleton listing" (initial_roots runtime 77L).requests in
  let out =
    Runtime.receive
      runtime
      (response
         listing
         (V2_failed { code = "responseTooLarge"; message = "oversized metadata" }))
  in
  let rec exhaust output =
    match output.Runtime.requests with
    | [] -> output.responses
    | request :: _ ->
      exhaust
        (Runtime.receive
           runtime
           (response
              request
              (V2_failed { code = "responseTooLarge"; message = "oversized singleton" })))
  in
  let results = exhaust out in
  Alcotest.(check bool)
    "singleton oversize is explicit, not an empty feed"
    true
    (List.exists
       (fun (r : Runtime.response) ->
          match r.payload with
          | Feed_failed _ -> true
          | _ -> false)
       results)
;;

let () =
  Alcotest.run
    "journal graph runtime locality"
    [ ( "status recovery"
      , [ Alcotest.test_case
            "explicit clear after lost response"
            `Quick
            test_capture_recovery_explicit_clear
        ; Alcotest.test_case
            "Append explicit clear after lost response"
            `Quick
            test_child_recovery_explicit_clear
        ; Alcotest.test_case
            "catalog and delta cross fences"
            `Quick
            test_catalog_and_lookup_cross_fences
        ] )
    ; ( "task status admission"
      , [ Alcotest.test_case
            "invalid status before insertion"
            `Quick
            test_invalid_status_precedes_insert
        ] )
    ; ( "task catalog"
      , [ Alcotest.test_case
            "generation and targeted deltas"
            `Quick
            test_task_catalog_generation_and_deltas
        ] )
    ; ( "unified request scheduling"
      , [ Alcotest.test_case
            "four and eight Favorites drain exactly once"
            `Quick
            test_favorite_dependencies_drain_once
        ; Alcotest.test_case
            "cancelled dependency releases capacity"
            `Quick
            test_favorite_cancel_releases_slot
        ; Alcotest.test_case
            "scope reset discards old queue"
            `Quick
            test_favorite_scope_discards_queued_reads
        ; Alcotest.test_case
            "Favorite epoch preserves new queue"
            `Quick
            test_favorite_epoch_preserves_new_queue
        ; Alcotest.test_case
            "refused delivery settles all unsent demands"
            `Quick
            test_rejected_delivery_retires_unsent_queue
        ; Alcotest.test_case
            "Favorite page discovers title reference"
            `Quick
            test_favorite_page_title_discovers_reference
        ; Alcotest.test_case
            "empty page detail discovers root reference"
            `Quick
            test_page_detail_root_title_discovers_reference
      ]);
      ("Favorites page detail", [Alcotest.test_case "page property refresh discovers references" `Quick test_page_property_refresh_discovers_references; Alcotest.test_case "page root and scoped append" `Quick test_page_detail_root_and_append; Alcotest.test_case "copy page root and empty page" `Quick test_copy_page_root; Alcotest.test_case "recycled page is unavailable" `Quick test_recycled_page_root_is_removed; Alcotest.test_case "page point-change identity" `Quick test_page_root_block_change_uses_page_identity; Alcotest.test_case "page root refresh and resync" `Quick test_page_root_refresh_and_resync; Alcotest.test_case "Favorites share page-first reference cache" `Quick test_favorites_share_reference_cache; Alcotest.test_case "Favorites outline and absent references" `Quick test_favorites_outline_and_missing_reference]); ( "review reference ownership", [
        Alcotest.test_case "typed metadata retains newer fence" `Quick test_typed_metadata_preserves_newer_reference_fence;
        Alcotest.test_case "dirty abandon remains retryable" `Quick test_dirty_abandon_keeps_reference_retryable;
        Alcotest.test_case "failed lookup retains epoch fence" `Quick test_reference_failed_read_retains_epoch_fence;
        Alcotest.test_case "abandon retains newer source" `Quick test_reference_abandon_preserves_newer_source;
        Alcotest.test_case "shared failure can retry discovery" `Quick test_reference_shared_failure_can_retry_discovery;
        Alcotest.test_case "outline miss cannot hide a page" `Quick test_reference_page_survives_unrelated_outline_miss;
        Alcotest.test_case "shared page miss remains retryable" `Quick test_reference_shared_page_miss_is_not_negative_cache])
    ; ( "page-first UUID references", [
        Alcotest.test_case "journal and ordinary page sources" `Quick test_reference_page_first_resolves_pages;
        Alcotest.test_case "explicit page miss then outline" `Quick test_reference_page_miss_then_outline;
        Alcotest.test_case "only both misses cache absence" `Quick test_reference_negative_cache_requires_both_misses;
        Alcotest.test_case "errors and cancellation retry" `Quick test_reference_errors_and_cancellation_retry_page_first;
        Alcotest.test_case "reset fences both stages" `Quick test_reference_reset_discards_both_stages;
        Alcotest.test_case "invalidation restarts page lookup" `Quick test_reference_invalidation_restarts_page_phase;
        Alcotest.test_case "fallback inherits original epoch" `Quick test_reference_fallback_keeps_original_epoch;
        Alcotest.test_case "two-stage bursts remain bounded" `Quick test_reference_two_stage_burst_stays_bounded;
        Alcotest.test_case "recycled page is not missing" `Quick test_recycled_reference_page_never_falls_back])
    ; ( "property references", [Alcotest.test_case "Detail closed property deduplicates" `Quick test_detail_property_reference_reads_are_deduplicated
      ;Alcotest.test_case "changed journal Detail discovers property" `Quick test_changed_journal_detail_discovers_property_reference
      ;Alcotest.test_case "materialized Detail leaf discovers property" `Quick test_materialized_detail_leaf_discovers_property_reference
      ;Alcotest.test_case "returned child property resolves without own load" `Quick test_detail_child_property_reference_without_child_load
      ;Alcotest.test_case "page/class properties use page lookup" `Quick test_detail_page_and_class_property_uses_page_lookup
      ;Alcotest.test_case "page type supersedes cached or pending block reference" `Quick test_page_property_promotes_prior_block_reference
      ;Alcotest.test_case "filtered changed tree follows continuation" `Quick test_changed_tree_all_property_slice_continues
      ;Alcotest.test_case "Timeline-only property change does not hydrate" `Quick test_timeline_only_property_update_does_not_hydrate] )
    ; ( "parent-only Timeline visibility"
      , [Alcotest.test_case "feed day remote legacy and metadata" `Quick test_parent_visibility_tree_paths;
         Alcotest.test_case "Capture Update Status completions" `Quick test_parent_visibility_confirmations])
    ; ( "bounded Timeline preview"
      , [ Alcotest.test_case "feed, day, remote and legacy refresh paths" `Quick test_bounded_preview_tree_paths
        ; Alcotest.test_case "Capture 10050 children stays bounded" `Quick (test_bounded_preview_target_pages `Capture 10050)
        ; Alcotest.test_case "Update 10050 children stays bounded" `Quick (test_bounded_preview_target_pages `Update 10050)
        ; Alcotest.test_case "Status 10050 children stays bounded" `Quick (test_bounded_preview_target_pages `Status 10050)
        ; Alcotest.test_case "Detail and Copy remain complete" `Quick test_preview_preserves_full_detail_and_copy
        ])
    ; ( "journal window budget"
      , [ Alcotest.test_case
            "complete metadata fits requested window"
            `Quick
            test_feed_window_fits_encoded_response_budget
        ; Alcotest.test_case
            "continuation reads missing days"
            `Quick
            test_feed_continuation_reads_only_missing_days
        ; Alcotest.test_case
            "bounds and oversized singleton remain explicit"
            `Quick
            test_feed_window_bounds_and_singleton_failure
        ] )
    ; ( "copy subtree"
      , [ Alcotest.test_case
            "serialized clipboard payload bound"
            `Quick
            test_copy_result_fits_serialized_clipboard
        ; Alcotest.test_case
            "nested complete pagination and multiline"
            `Quick
            test_copy_nested_paginated_text
        ; Alcotest.test_case
            "empty and whitespace text"
            `Quick
            test_copy_empty_and_root_whitespace
        ; Alcotest.test_case
            "cancel and replaced ownership"
            `Quick
            test_copy_cancel_and_replacement
        ; Alcotest.test_case
            "missing failed and changed graph"
            `Quick
            test_copy_rejects_missing_failed_or_changed_graph
        ; Alcotest.test_case
            "owner cycle and cursor fences"
            `Quick
            test_copy_rejects_wrong_owner_cycle_and_cursor
        ; Alcotest.test_case
            "oversized text fails without truncation"
            `Quick
            test_copy_rejects_oversized_text
        ] )
    ; ( "block references"
      , [ Alcotest.test_case
            "stale feed source fence"
            `Quick
            test_stale_feed_cannot_replace_reference_source
        ; Alcotest.test_case
            "shared change failure invalidates source"
            `Quick
            test_shared_change_failure_invalidates_reference
        ; Alcotest.test_case
            "hydration, edits, deletion and reset"
            `Quick
            test_reference_hydration_and_changes
        ; Alcotest.test_case
            "cycles and failure recovery"
            `Quick
            test_reference_cycle_and_failure
        ; Alcotest.test_case
            "invalidation during a pending read"
            `Quick
            test_reference_invalidation_during_read
        ; Alcotest.test_case
            "loaded target shares changed read"
            `Quick
            test_reference_to_loaded_block_shares_change_read
        ; Alcotest.test_case
            "abandoned reference can refresh"
            `Quick
            test_abandoned_reference_can_refresh
        ; Alcotest.test_case
            "shorter path discovers bounded target"
            `Quick
            test_shorter_reference_path_discovers_nested_targets
        ; Alcotest.test_case "bounded burst" `Quick test_reference_burst_is_bounded
        ] )
    ; ( "cross-page ownership", [Alcotest.test_case "point context and retirement" `Quick test_changed_point_ownership] )
    ; ( "initial thirty roots", [
        Alcotest.test_case "Today first within root budget" `Quick test_today_priority_batch;
        Alcotest.test_case "Today date traversal survives recovery" `Quick test_today_date_traversal_survives_recovery;
        Alcotest.test_case "Today priority continuations and midnight" `Quick test_today_priority_continuations;
        Alcotest.test_case "thirty roots, previews, assets and continuation" `Quick test_initial_thirty_roots;
        Alcotest.test_case "sparse dates continue past seven" `Quick test_initial_sparse_roots;
        Alcotest.test_case "filtered roots and exhaustion" `Quick test_initial_filtered_exhaustion;
        Alcotest.test_case "wide branches have bounded previews" `Quick test_initial_wide_preview;
        Alcotest.test_case "encoded byte splitting preserves demand" `Quick test_initial_byte_splitting;
        Alcotest.test_case "reset fences and later quotas" `Quick test_initial_reset_and_later_quota;
        Alcotest.test_case "refresh after byte splitting" `Quick (test_initial_refresh_range true);
        Alcotest.test_case "refresh retains later suffix" `Quick (test_initial_refresh_range false);
        Alcotest.test_case "supersession and explicit singleton failure" `Quick test_initial_superseded_and_singleton;
        Alcotest.test_case "restart retains loaded suffix through insertion" `Quick test_initial_refresh_after_restarting_prefix;
        Alcotest.test_case "superseded continuation settles" `Quick test_initial_later_read_superseded;
        Alcotest.test_case "later batch fills across dates" `Quick test_later_thirty_crosses_dates;
        Alcotest.test_case "later date cursor failure settles" `Quick test_later_date_cursor_no_progress_settles;
        Alcotest.test_case "resync prefix cannot cancel retained tree" `Quick
          (test_prefix_preserves_reconciliation ~resync:true `Root);
        Alcotest.test_case "resync prefix cannot cancel retained previews" `Quick
          (test_prefix_preserves_reconciliation ~resync:true `Preview);
        Alcotest.test_case "resync prefix cannot cancel retained continuation" `Quick
          (test_prefix_preserves_reconciliation ~resync:true `Continuation);
        Alcotest.test_case "journal change prefix cannot cancel retained tree" `Quick
          (test_prefix_preserves_reconciliation ~resync:false `Root);
        Alcotest.test_case "newer changes and graph reset still fence reconciliation" `Quick
          test_newer_reconciliation_fences_old_results])
    ; ( "sparse tree pages"
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
    ; ( "target mutation confirmation"
      , [ Alcotest.test_case
            "Capture targeted canonical block and children"
            `Quick
            (fun () -> test_target_confirmation `Capture "Stored capture" 3)
        ; Alcotest.test_case "Update last root does not read siblings" `Quick (fun () ->
            test_target_confirmation `Update "Stored update" 2)
        ; Alcotest.test_case "Status targeted confirmation" `Quick (fun () ->
            test_target_confirmation `Status "Retained block" 0)
        ; Alcotest.test_case
            "Blank canonical target completes without fabricated entry"
            `Quick
            (fun () -> test_target_confirmation `Update "" 0)
        ; Alcotest.test_case
            "Target children paginate independently of siblings"
            `Quick
            test_target_children_continue
        ; Alcotest.test_case
            "Target child snapshots cannot be mixed"
            `Quick
            test_target_version_fence
        ; Alcotest.test_case
            "Foreign target is rejected"
            `Quick
            test_target_rejects_wrong_identity
        ; Alcotest.test_case
            "Blank image and deep child semantics"
            `Quick
            test_target_blank_image_and_deep_child
        ; Alcotest.test_case
            "Stale target recovery is bounded"
            `Quick
            test_target_stale_recovery_is_bounded
        ; Alcotest.test_case
            "Newer target confirmation fences old"
            `Quick
            test_target_newer_confirmation_fences_old
        ; Alcotest.test_case
            "Canonical child mutation context retained"
            `Quick
            test_target_confirmation_retains_child_mutation_context
        ; Alcotest.test_case "Capture page retains structure interest" `Quick (fun () ->
            test_target_confirmation_retains_page_interest true)
        ; Alcotest.test_case
            "Pending Capture page retains structure interest"
            `Quick
            (fun () -> test_target_confirmation_retains_page_interest false)
        ; Alcotest.test_case
            "Invisible root retains existing completion semantics"
            `Quick
            test_target_invisible_root_has_timeline_only_removal
        ]
        @ List.concat_map
            (fun (name, kind) ->
               List.map
                 (fun (suffix, terminal) ->
                    Alcotest.test_case
                      (name ^ " " ^ suffix)
                      `Quick
                      (fun () -> test_target_terminal kind terminal))
                 [ "missing", `Missing; "failure", `Failure; "graph reset", `Reset ])
            [ "Capture", `Capture; "Update", `Update; "Status", `Status ] )
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
    ; ( "projection dependencies"
      , [ Alcotest.test_case "ordinary detail root changes" `Quick (fun () ->
            test_ordinary_detail_point_change false)
        ; Alcotest.test_case "ordinary detail child changes" `Quick (fun () ->
            test_ordinary_detail_point_change true)
        ; Alcotest.test_case
            "children retain latest root"
            `Quick
            test_detail_children_uses_latest_root
        ; Alcotest.test_case
            "detail resync refreshes root"
            `Quick
            test_detail_resync_reads_latest_root
        ; Alcotest.test_case
            "favorites resolve ancestry"
            `Quick
            test_favorite_dependencies_are_read
        ; Alcotest.test_case
            "Favorite pending target changes recheck"
            `Quick
            test_favorite_pending_target_change_is_rechecked
        ; Alcotest.test_case
            "negative favorites retain membership dependencies"
            `Quick
            test_negative_favorite_membership_intersects
        ; Alcotest.test_case
            "favorites owned dependency intersection"
            `Quick
            test_favorite_changes_locality
        ; Alcotest.test_case
            "Favorite Capture sibling structure is local"
            `Quick
            test_favorite_sibling_structure_is_local
        ; Alcotest.test_case
            "Favorite ancestor title is local"
            `Quick
            test_favorite_ancestor_title_is_local
        ; Alcotest.test_case
            "Favorite dependency limit fails explicitly"
            `Quick
            test_favorite_dependency_limit
        ; Alcotest.test_case
            "projection changes ownership and real resync"
            `Quick
            test_projection_changes_are_owned
        ] )
    ; ( "detail"
      , [ Alcotest.test_case
            "resolve unretained page"
            `Quick
            (fun () -> test_detail_resolves_unretained_page ())
        ; Alcotest.test_case "Detail reader preserves root and child tags" `Quick
            (fun () -> test_detail_resolves_unretained_page ~tagged:true ())
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
    ; ( "journal title format"
      , [ Alcotest.test_case
            "missing format uses the upstream default"
            `Quick
            test_journal_title_defaults_to_upstream_format
        ; Alcotest.test_case
            "configured format"
            `Quick
            test_journal_title_uses_configured_format
        ; Alcotest.test_case
            "invalid format falls back to the upstream default"
            `Quick
            test_journal_title_falls_back_on_invalid_format
        ; Alcotest.test_case
            "failed format read rejects the capture"
            `Quick
            test_journal_title_failed_format_read_rejects
        ; Alcotest.test_case
            "ordinal and calendar boundaries"
            `Quick
            test_journal_title_ordinals_and_boundaries
        ] )
    ; ( "admitted failure ownership"
      , [ Alcotest.test_case
            "background failure keeps sync owner"
            `Quick
            test_background_failure_keeps_sync_owner
        ; Alcotest.test_case
            "capture failure keeps admitted owner"
            `Quick
            test_capture_failure_keeps_admitted_owner
        ; Alcotest.test_case
            "status refresh failure keeps admitted owner"
            `Quick
            test_status_failure_keeps_admitted_owner
        ; Alcotest.test_case
            "submit rejections keep admitted identity"
            `Quick
            test_submit_rejections_keep_admitted_identity
        ; Alcotest.test_case
            "child failure retains admitted child"
            `Quick
            test_child_failure_retains_admitted_child
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
