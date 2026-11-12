module Read = Worker_pure_read
module S = Logseq_db_worker_lui.Logseq_db_worker_lui_service
module Graph = Logseq_db_types.Graph_types
module Production_runtime = Journal_graph_runtime
module W = Journal_worker_coordination.Worker_api

let query_sample produce = function
  | S.Coordination_query r -> S.Coordination_queried
      {registration=r.registration;owner=r.owner;request_id=r.request_id;answer=produce r.read}
  | S.Coordination_confirm r -> S.Coordination_confirmed
      {registration=r.registration;owner=r.owner;presentation=r.presentation;request_id=r.request_id;answer=produce r.read}
  | _ -> failwith "Expected the original typed read request"
;;

let fixture_scope : type a. a Read.Timeline.query -> string = function
  | Read.Timeline.Dates _ -> "dates"
  | Read.Timeline.Roots page -> "roots:" ^ Graph.Uuid.to_string page
  | Read.Timeline.Preview_children parent -> "preview:" ^ Graph.Uuid.to_string parent
;;

let fixture_versions = Hashtbl.create 32
let fixture_version query =
  string_of_int (Option.value ~default:0 (Hashtbl.find_opt fixture_versions (fixture_scope query)))
;;

let fixture_packet budget query ~items ~next =
  let module F = Read.For_worker in
  let receipt = F.timeline_receipt ~owner:(F.read_budget_owner budget) ~query
      ~version:(fixture_version query) in
  F.timeline_packet ~receipt ~items:(Rrbvec.of_list items)
    ~next:(Option.map Graph.Cursor.to_string next)
;;

let fixture_cursor : type a. Read.read_budget -> a Read.query -> Graph.Cursor.t option = fun budget query ->
  match query with
  | Read.Timeline_read {after;_} ->
    Option.map (fun cursor -> Read.For_worker.timeline_cursor_position cursor
        |> Graph.Cursor.of_string |> Result.get_ok) after
  | _ -> Read.query_cursor (Read.For_worker.read_budget_owner budget) budget query
      |> Result.get_ok
;;

let journal_sample ~(items : Worker_pure_data.journal_item list) ~next =
  query_sample (fun (Read.Read_query (budget, query)) ->
    match query with
    | Read.Timeline_read {query=(Read.Timeline.Dates _ as timeline);_} ->
      Read.For_worker.answer budget query (Ok (Ok (fixture_packet budget timeline ~items ~next)))
    | _ -> failwith "Expected Timeline dates")
;;

let tree_sample ~(items : Worker_pure_data.tree_member list) ~next =
  query_sample (fun (Read.Read_query (budget, query)) ->
    match query with
    | Read.Timeline_read {query=(Read.Timeline.Roots _ as timeline);_} ->
      Read.For_worker.answer budget query (Ok (Ok (fixture_packet budget timeline ~items ~next)))
    | Read.Tree _ ->
      let module F = Read.For_worker in
      Read.For_worker.answer budget query (Ok (F.slice ~items
        ~next:(Option.map (fun cursor -> F.continuation ~owner:(F.read_budget_owner budget)
          ~budget ~key:(Read.query_key budget query) ~cursor) next)))
    | _ -> failwith "Expected page roots or full Detail tree")
;;

let children_sample ~parent ~scope_revision ~(items : Worker_pure_data.child_member list) ~next =
  query_sample (fun (Read.Read_query (budget, query)) ->
    match query with
    | Read.Timeline_read {query=(Read.Timeline.Preview_children _ as timeline);_} ->
      Read.For_worker.answer budget query (Ok (Ok (fixture_packet budget timeline ~items ~next)))
    | Read.Child_members _ ->
      let module F = Read.For_worker in
      F.answer budget query (Ok (F.children ~parent ~scope_revision
        ~revision_scope:(Worker_pure_data.V2_children_revision parent) ~items
        ~next:(Option.map (fun cursor -> F.continuation ~owner:(F.read_budget_owner budget)
          ~budget ~key:(Read.query_key budget query) ~cursor) next)))
    | _ -> failwith "Expected bounded Timeline preview or full Detail children")
;;

let check_sample = query_sample (fun (Read.Read_query (budget, query)) ->
  match query with
  | Read.Timeline_check receipts ->
    let checks = Rrbvec.map (fun (Read.Timeline.Receipt receipt) ->
      if Read.For_worker.timeline_receipt_version receipt =
          fixture_version (Read.For_worker.timeline_receipt_query receipt)
      then Ok () else Error (Read.Timeline.Invalidated Scope_changed)) receipts in
    Read.For_worker.answer budget query (Ok (Read.For_worker.timeline_check checks))
  | _ -> failwith "Expected same-snapshot Timeline receipt checks")
;;

let failed_sample error request = match request with
  | S.Coordination_acknowledge_changes r -> S.Coordination_changes_acknowledged
      {registration=r.registration;owner=r.owner;request_id=r.request_id;result=Error error}
  | request -> query_sample (fun (Read.Read_query(budget,query))->Read.For_worker.answer budget query(Error error)) request
;;

let ack_sample generation through = function
  | S.Coordination_acknowledge_changes r -> S.Coordination_changes_acknowledged
      {registration=r.registration;owner=r.owner;request_id=r.request_id;
       result=Ok(Read.For_worker.change_ack ~ack_owner:r.batch.change_owner ~generation ~through)}
  | _ -> failwith "Expected the original typed Changes acknowledgement"
;;

module Worker_producer = struct
  module W = Journal_worker_coordination.Worker_api
  module S = Logseq_db_worker_lui.Logseq_db_worker_lui_service

  let issuer, raw, projection, session =
    Coordination_test_fixture.fixture
      ~limits:
        { Coordination_test_fixture.limits with
          response_budget_bytes = Worker_pure_data.maximum_response_bytes
        }
      2800L
  ;;

  module I = (val issuer : Worker_effect_authority.ISSUER)
  module C = Journal_worker_coordination.Worker_pure_coordinator

  let state =
    C.step
      (C.initial
         ~client_id:
           (W.Uuid.of_string "98000000-0000-4000-8000-000000002800" |> Result.get_ok))
      (C.Worker_bound I.binding)
    |> fun step ->
    (C.step step.next (C.Bootstrap_received (I.binding, W.Ready projection))).next
  ;;

  let validate_session session =
    C.validate_session ~owner:(Option.get raw.baseline.state.sync.selected) state session
  ;;

  let budget maximum_items =
    W.read_budget session ~maximum_items ~maximum_bytes:Worker_pure_data.maximum_response_bytes
    |> Result.get_ok
  ;;

  (* Actual outgoing Service boundary. Business output remains its original
     logical ID; this fixture inspects the transport only to serve sealed cursors. *)
  let transport runtime id = match Production_runtime.worker_read runtime id with
    |Some(Production_runtime.Read read)->I.request session ~request_id:(W.request_id id)
        (W.Query(budget read.maximum_items,read.query))
    |Some(Production_runtime.Acknowledge{batch})->I.request session ~request_id:(W.request_id id)(W.Acknowledge_changes batch)
    |_->Error(W.Invalid_input "No current typed fixture operation")

  let deliver runtime request produce =
    match Production_runtime.worker_read runtime request with
    | Some (Production_runtime.Read read) ->
      let budget=budget read.maximum_items in
      let operation=W.Query(budget,read.query) in
      let source=I.request session ~request_id:(W.request_id request) operation |> Result.get_ok in
      (match I.reply session ~request_id:(W.request_id request) operation (produce source) with
       | Ok(W.Answered(Ok value))->Production_runtime.receive_worker_read ~origin:(session,budget)
           runtime ~request_id:request (Production_runtime.Query_result(read.query,value))
       | Ok(W.Answered(Error(W.Stale_read message)))->Production_runtime.receive_worker_read runtime ~request_id:request
           (Production_runtime.Read_failed{code=Logseq_db_worker.Error.Stale_read_cursor;message})
       | Ok(W.Answered(Error W.Response_budget_exceeded))->Production_runtime.receive_worker_read runtime ~request_id:request
           (Production_runtime.Read_failed{code=Logseq_db_worker.Error.Response_too_large;message="oversized fixture"})
       | Ok(W.Answered(Error(W.Db_error error)))->Production_runtime.receive_worker_read runtime ~request_id:request
           (Production_runtime.Read_error error)
       | _->Production_runtime.fail_request runtime request ~message:"Typed fixture response rejected")
    |Some(Production_runtime.Acknowledge{batch})->
      let operation=W.Acknowledge_changes batch in
      let source=I.request session ~request_id:(W.request_id request) operation |> Result.get_ok in
      (match I.reply session ~request_id:(W.request_id request) operation (produce source) with
       |Ok(W.Answered(Ok ack))->Production_runtime.receive_worker_read runtime ~request_id:request
           (Production_runtime.Changes_acknowledged ack)
       |_->failwith "Typed change ACK fixture rejected its original batch")
    |_->Production_runtime.receive_worker_read runtime ~request_id:request
        (Production_runtime.Read_failed{code=Logseq_db_worker.Error.Invalid_request;message="Retired fixture completion"})
  ;;

end

module Runtime = struct
  include Production_runtime
  let create ?localtime ?(validate_session=Worker_producer.validate_session) () =
    Production_runtime.create ?localtime ~validate_session ()


end

let uuid value = Graph.Uuid.of_string value |> Result.get_ok

let only description = function
  | [ value ] -> value
  | values ->
    Alcotest.failf "%s: expected one value, got %d" description (List.length values)
;;

let sample request produce = request,produce
let rec settle_fixture_checks runtime (output : Runtime.output) : Runtime.output =
  List.fold_left (fun (kept : Runtime.output) request ->
    match Runtime.worker_read runtime request with
    | Some (Runtime.Read { query = W.Timeline_check _; _ }) ->
      let next = Worker_producer.deliver runtime request check_sample
        |> settle_fixture_checks runtime in
      { Runtime.requests = kept.requests @ next.requests
      ; responses = kept.responses @ next.responses }
    | _ -> { kept with requests = kept.requests @ [request] })
    { Runtime.requests = []; responses = output.responses } output.requests
;;

let deliver_sample runtime (request,produce) =
  Worker_producer.deliver runtime request produce |> settle_fixture_checks runtime

let sample_bytes runtime (request,produce) =
  let source=Worker_producer.transport runtime request |> Result.get_ok in
  match produce source with
  |S.Coordination_queried{answer=Read.Query_answer(_,query,Ok value);_}->Read.encoded_value_bytes query value
  |_->failwith "Expected a typed value when measuring a synthetic response"
;;

let confirmed_sample issuer session presentation receipt request_id produce =
  let module I=(val issuer:Worker_effect_authority.ISSUER)in
  let operation=W.Confirm(presentation,receipt)in
  let source=I.request session ~request_id:(W.request_id request_id)operation |> Result.get_ok in
  match I.reply session ~request_id:(W.request_id request_id)operation (produce source)with
  |Ok(W.Answered(Ok proof))->proof
  |_->failwith "Production confirmation was rejected"
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

let record : Worker_pure_data.block_record =
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

(* Drive the actual child requests of a declared synthetic source. This is
   explicit fixture I/O; deliver_sample never splits or answers a packet. *)
let rec finish_previews runtime ~children (output:Runtime.output) : Runtime.output =
  List.fold_left (fun (kept:Runtime.output) id ->
    match Worker_producer.transport runtime id with
    |Ok(Worker_producer.S.Coordination_query{read=Read.Read_query(budget,(Read.Timeline_read {query=Read.Timeline.Preview_children parent;_} as query));_})->
      let cursor=fixture_cursor budget query in
      let limit=Read.For_worker.read_budget_maximum_items budget in
      let items=List.filter(fun (item:Worker_pure_data.child_member)->item.value.block.parent=parent)children
        |>List.sort(fun (a:Worker_pure_data.child_member) (b:Worker_pure_data.child_member)->compare(a.value.block.order,a.value.block.uuid)(b.value.block.order,b.value.block.uuid)) in
      let offset=Option.fold ~none:0 ~some:(fun cursor->Scanf.sscanf(Graph.Cursor.to_string cursor)"declared-preview:%d" Fun.id)cursor in
      let selected=List.take limit(List.drop offset items) in
      let consumed=offset+List.length selected in
      let next_cursor=if consumed<List.length items then Some(Graph.Cursor.of_string(Printf.sprintf "declared-preview:%d" consumed) |> Result.get_ok)else None in
      let next=deliver_sample runtime(sample id((children_sample ~parent:(parent) ~scope_revision:("fixture-children") ~items:(selected) ~next:(next_cursor)))) |> finish_previews runtime ~children in
      {Runtime.requests=kept.requests@next.requests;responses=kept.responses@next.responses}
    |_-> {kept with requests=kept.requests@[id]})
    {Runtime.requests=[];responses=output.responses} output.requests
;;

let seed_feed runtime =
  set_calendar runtime;
  let journals = load_feed runtime in
  let tree =
    deliver_sample
      runtime
      (sample
         journals
         ((journal_sample ~items:(([ { page; journal_day = 20260901; revision = "page-1" } ] : Worker_pure_data.journal_item list)) ~next:(None))))
    |> fun output -> only "initial page-tree request" output.requests
  in
  ignore
    (deliver_sample
       runtime
       (sample
          tree
          ((tree_sample ~items:(([ { value = record; revision = "block-1"; depth = 0; parent = page_uuid }
                 ] : Worker_pure_data.tree_member list)) ~next:(None)))) |> finish_previews runtime ~children:[]);
  ()
;;

let pull runtime =
  Runtime.reconcile_signal
    runtime
    ~request_generation:11L
    (Worker_pure_data.Changes_available { generation = "generation-1"
       ; through = "revision-2"
       })
  |> fun output -> only "change pull" output.requests
;;

let bump_fixture_scopes scopes =
  List.iter (fun scope ->
    let key = match scope with
      | Worker_pure_data.V2_journal_index_interest -> "dates"
      | Worker_pure_data.V2_page_tree_interest page -> "roots:" ^ Graph.Uuid.to_string page
      | Worker_pure_data.V2_children_interest parent -> "preview:" ^ Graph.Uuid.to_string parent
    in
    Hashtbl.replace fixture_versions key
      (1 + Option.value ~default:0 (Hashtbl.find_opt fixture_versions key)))
    scopes
;;

let changed runtime window =
  bump_fixture_scopes window.Worker_pure_data.structure_interests;
  let request = pull runtime in
  let after=match Runtime.worker_read runtime request with Some(Runtime.Read{query=W.Changes{after;_};_})->after|_->assert false in
  deliver_sample
    runtime
    (sample
       request
       ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok(F.change_batch ~change_owner:(F.read_budget_owner budget) ~generation:("generation-1") ~from_exclusive:(after) ~through:(window.Worker_pure_data.id) ~windows:([ window ]) ~next:(None)) in match query with |Read.Changes _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"))))
;;

let window ?(blocks = []) ?(pages = []) ?(scopes = []) () : Worker_pure_data.change_window =
  { id = "revision-2"
  ; predecessor = "revision-1"
  ; successor = "revision-2"
  ; block_uuids = blocks
  ; page_uuids = pages
  ; structure_interests = scopes
  }
;;

let hydration_requests runtime output =
  List.filter
    (fun (request : Graph.Uuid.t) ->
       match Runtime.worker_read runtime request with
       | Some (Runtime.Acknowledge {batch=_}) -> false
       | _ -> true)
    output.Runtime.requests
;;

let require_ack runtime output =
  Alcotest.(check int)
    "one acknowledgement"
    1
    (List.fold_left
       (fun count (request : Graph.Uuid.t) ->
          match Runtime.worker_read runtime request with
          | Some (Runtime.Acknowledge {batch=_}) -> count + 1
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
    deliver_sample
      runtime
      (sample
         request
         ((journal_sample ~items:(([ { page; journal_day = 20260901; revision = "page-1" } ] : Worker_pure_data.journal_item list)) ~next:(None))))
    |> fun output -> only "large feed tree" output.requests
  in
  let items =
    List.map
      (fun value ->
         Worker_pure_data.{ value; revision = "block-1"; depth = 0; parent = page_uuid })
      records
  in
  ignore
    (deliver_sample
       runtime
       (sample
          tree
          ((tree_sample ~items:((items : Worker_pure_data.tree_member list)) ~next:(None)))) |> finish_previews runtime ~children:[]);
  records, items
;;

let consume_ack runtime output =
  List.filter
    (fun (request : Graph.Uuid.t) ->
       match Runtime.worker_read runtime request with
       | Some (Runtime.Acknowledge {batch={generation; through; _}}) ->
         let ack =
           deliver_sample
             runtime
             (sample request ((ack_sample (generation) (through))))
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
      (fun (r : Worker_pure_data.block_record) ->
         String.compare
           (Graph.Uuid.to_string r.block.uuid)
           "a1000000-0000-4000-9000-000000000140"
         < 0)
      records
  in
  let ids records =
    List.map (fun (r : Worker_pure_data.block_record) -> r.block.uuid) records
  in
  let first_output = changed runtime (window ~blocks:(ids first) ()) in
  let outstanding = consume_ack runtime first_output in
  check_hydration_bound outstanding;
  let next_pull = pull runtime in
  let later_output =
    deliver_sample
      runtime
      (sample
         next_pull
         ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok(F.change_batch ~change_owner:(F.read_budget_owner budget) ~generation:("generation-1") ~from_exclusive:(Some "revision-2") ~through:("revision-3") ~next:(None) ~windows:([ { (window ~blocks:(ids later) ()) with
                    id = "revision-3"
                  ; predecessor = "revision-2"
                  ; successor = "revision-3"
                  }
                ])) in match query with |Read.Changes _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"))))
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
    deliver_sample
      runtime
      (sample
         foreground
         ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_missing_block { uuid = unrelated_uuid; revision = "missing" })) in match query with |Read.Outline_block _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"))))
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
    | (request : Graph.Uuid.t) :: rest ->
      let id =
        match Runtime.worker_read runtime request with
        | Some(Runtime.Read{query=W.Outline_block {uuid=block;_};_}) -> block
        | _ -> Alcotest.fail "unexpected background request"
      in
      let outcome =
        if fail_one && List.length seen = 6
        then (failed_sample (Read.Db_error(Logseq_db_worker.Error.create ~code:Invalid_request ~message:("Read unavailable") ~details:[]|>Result.get_ok)))
        else
          (query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_missing_block { uuid = id; revision = "removed" })) in match query with |Read.Outline_block _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"))
      in
      let output = deliver_sample runtime (sample request outcome) in
      let duplicate = deliver_sample runtime (sample request outcome) in
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
         ~blocks:(List.map (fun (r : Worker_pure_data.block_record) -> r.block.uuid) records)
         ())
  in
  let issued = consume_ack runtime output in
  check_hydration_bound issued;
  Runtime.reset runtime;
  List.iter
    (fun (request : Graph.Uuid.t) ->
       let output =
         deliver_sample
           runtime
           (sample
              request
              ((failed_sample (Read.Db_error(Logseq_db_worker.Error.create ~code:Invalid_request ~message:("Old graph") ~details:[]|>Result.get_ok)))))
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
    (List.length (hydration_requests runtime next))
;;

let test_resync_and_dependent_reads_share_hydration_bound () =
  let runtime = Runtime.create () in
  let records, items = seed_large_feed runtime in
  List.iter
    (fun (value : Worker_pure_data.block_record) ->
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
         deliver_sample
           runtime
           (sample
              request
              ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_present_block { value; revision = "block-1" })) in match query with |Read.Outline_block _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"))))
         |> fun output -> only "register children" output.requests
       in
       ignore
         (deliver_sample
            runtime
            (sample
               request
               ((children_sample ~parent:(value.block.uuid) ~scope_revision:("children-1") ~items:([]) ~next:(None))))))
    records;
  let output =
    Runtime.reconcile_signal
      runtime
      ~request_generation:3L
      (Worker_pure_data.Resync_required { generation = "generation-2"
         ; reason = "overflow"
         })
  in
  check_hydration_bound output.requests;
  let counts = Hashtbl.create 4 in
  let complete_feeds = ref 0 and reconciled_pages = ref 0 in
  let rec drain = function
    | [] -> ()
    | (request : Graph.Uuid.t) :: rest ->
      let kind, outcome =
        match Runtime.worker_read runtime request with
        | Some(Runtime.Read{query=W.Graph_info;_})->
          ( "graph"
          , (failed_sample (Read.Db_error(Logseq_db_worker.Error.create ~code:Invalid_request ~message:("Inspection unavailable") ~details:[]|>Result.get_ok))) )
        | Some(Runtime.Read{query=W.Timeline_read {query=W.Timeline.Dates _;_};_}) ->
          ( "journal"
          , (journal_sample ~items:(([ { page; journal_day = 20260901; revision = "page-2" } ] : Worker_pure_data.journal_item list)) ~next:(None)) )
        | Some(Runtime.Read{query=W.Timeline_read {query=W.Timeline.Roots _;_};_}) ->
          ( "tree"
          , (tree_sample ~items:((List.filter (fun (m:Worker_pure_data.tree_member)->m.depth=0) items : Worker_pure_data.tree_member list)) ~next:(None)) )
        | Some(Runtime.Read{query=W.Child_members {parent;_};_})
        | Some(Runtime.Read{query=W.Timeline_read {query=W.Timeline.Preview_children parent;_};_}) ->
          ( "children"
          , (children_sample ~parent:(parent) ~scope_revision:("children-2") ~items:([]) ~next:(None)) )
        | Some(Runtime.Read{query=W.Outline_block {uuid=id;_};_}) ->
          let value =
            List.find
              (fun (value : Worker_pure_data.block_record) ->
                 Graph.Uuid.equal value.block.uuid id)
              records
          in
          ( "block"
          , (query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_present_block { value; revision = "block-2" })) in match query with |Read.Outline_block _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch")) )
        | Some(Runtime.Read{query=W.Page _;_}) ->
          "page", (query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_present_page { page; revision = "page-2" })) in match query with |Read.Page _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"))
        | Some(Runtime.Read{query=W.Timeline_check _;_}) -> "check", check_sample
        | _ -> Alcotest.fail "resync request outside retained interests"
      in
      Hashtbl.replace
        counts
        kind
        (1 + Option.value ~default:0 (Hashtbl.find_opt counts kind));
      let result = deliver_sample runtime (sample request outcome) in
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
  Alcotest.(check int) "valid retained page needs no replacement" 0 !reconciled_pages;
  List.iter
    (fun (kind, expected) ->
       Alcotest.(check int)
         kind
         expected
         (Option.value ~default:0 (Hashtbl.find_opt counts kind)))
    (* The unchanged Timeline window is checked once; Detail retains its own
       independent child reads. No roots or previews need to be read again. *)
    [ "graph", 1; "check", 1; "journal", 1; "tree", 0; "children", 48; "block", 48; "page", 1 ]
;;

let test_queued_resync_announces_feed_refresh () =
  let runtime = Runtime.create () in
  let records, _ = seed_large_feed runtime in
  ignore
    (changed
       runtime
       (window
          ~blocks:(List.map (fun (r : Worker_pure_data.block_record) -> r.block.uuid) records)
          ()));
  let output =
    Runtime.reconcile_signal
      runtime
      ~request_generation:20L
      (Worker_pure_data.Resync_required { generation = "generation-2"
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
    (deliver_sample
       runtime
       (sample
          first_pull
          ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok(F.change_batch ~change_owner:(F.read_budget_owner budget) ~generation:("generation-1") ~from_exclusive:(None) ~through:("revision-2") ~windows:([]) ~next:(None)) in match query with |Read.Changes _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch")))));
  let restarted =
    Runtime.reconcile_signal
      runtime
      ~request_generation:12L
      (Worker_pure_data.Changes_available { generation = "generation-2"
         ; through = "revision-3"
         })
    |> fun output -> only "generation-change pull" output.requests
  in
  match Runtime.worker_read runtime restarted with
  | Some(Runtime.Read{query=W.Changes {generation="generation-2";after=None;_};_}) -> ()
  | Some(Runtime.Read{query=W.Changes _;_}) ->
    Alcotest.fail "Worker generation change retained an old continuation"
  | _ -> Alcotest.fail "Worker generation change did not restart the change pull"
;;

let test_uninterested_change_does_not_hydrate () =
  let runtime = Runtime.create () in
  let output = changed runtime (window ~blocks:[ unrelated_uuid ] ()) in
  require_ack runtime output;
  Alcotest.(check int)
    "uninterested hydration request count"
    0
    (List.length (hydration_requests runtime output))
;;

let test_one_block_change_hydrates_only_that_block () =
  let runtime = Runtime.create () in
  seed_feed runtime;
  let output = changed runtime (window ~blocks:[ block_uuid; unrelated_uuid ] ()) in
  require_ack runtime output;
  match List.map(Runtime.worker_read runtime) (hydration_requests runtime output) with
  | [ Some(Runtime.Read{query=W.Outline_block{uuid=block;_};_}) ] ->
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
  let hydration = only "point hydration" (hydration_requests runtime changed_output) in
  let updated_record =
    { record with block = { block with title = "Changed remotely" } }
  in
  let output =
    deliver_sample
      runtime
      (sample
         hydration
         ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_present_block { value = updated_record; revision = "block-2" })) in match query with |Read.Outline_block _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"))))
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
    changed runtime (window ~scopes:[ Worker_pure_data.V2_journal_index_interest ] ())
  in
  require_ack runtime output;
  match List.map(Runtime.worker_read runtime) (hydration_requests runtime output) with
  | [ Some(Runtime.Read{query=W.Timeline_read {query=W.Timeline.Dates _;_};_}) ] -> ()
  | requests ->
    Alcotest.failf
      "expected only the registered journal query, got %d requests"
      (List.length requests)
;;

let test_page_tree_interest_refetches_only_matching_tree () =
  let runtime = Runtime.create () in
  seed_feed runtime;
  let output =
    changed runtime (window ~scopes:[ Worker_pure_data.V2_page_tree_interest page_uuid ] ())
  in
  require_ack runtime output;
  match List.map(Runtime.worker_read runtime) (hydration_requests runtime output) with
  | [ Some(Runtime.Read{query=W.Timeline_read {query=W.Timeline.Roots page;_};_}) ] ->
    Alcotest.(check string)
      "hydrated page tree"
      (Graph.Uuid.to_string page_uuid)
      (Graph.Uuid.to_string page)
  | requests ->
    Alcotest.failf
      "expected only the matching page-tree query, got %d requests"
      (List.length requests)
;;

let seed_children_interest ?(scope_revision="scope-children-1") runtime =
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
    deliver_sample
      runtime
      (sample
         block_request
         ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_present_block { value = record; revision = "block-detail-1" })) in match query with |Read.Outline_block _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"))))
    |> fun output -> only "detail children request" output.requests
  in
  ignore
    (deliver_sample
       runtime
       (sample
          children_request
          ((children_sample ~parent:(block_uuid) ~scope_revision:(scope_revision) ~items:([]) ~next:(None)))));
  ()
;;

let test_children_interest_refetches_only_matching_children () =
  let runtime = Runtime.create () in
  seed_children_interest runtime;
  let output =
    changed runtime (window ~scopes:[ Worker_pure_data.V2_children_interest block_uuid ] ())
  in
  require_ack runtime output;
  match List.map(Runtime.worker_read runtime) (hydration_requests runtime output) with
  | [ Some(Runtime.Read{query=W.Child_members{parent;_};maximum_items=3});
      Some(Runtime.Read{query=W.Timeline_read {query=W.Timeline.Roots _;after=None};_}) ] ->
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
    Runtime.reconcile_signal
      runtime
      ~request_generation:12L
      (Worker_pure_data.Resync_required { generation = "generation-2"
         ; reason = "retention overflow"
         })
  in
  let graph_info, journals =
    List.fold_left
      (fun (graph_info, journals) (request : Graph.Uuid.t) ->
         match Runtime.worker_read runtime request with
         | Some(Runtime.Read{query=W.Graph_info;_})-> graph_info + 1, journals
         | Some(Runtime.Read{query=W.Timeline_read {query=W.Timeline.Dates _;_};_}) -> graph_info, journals + 1
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
    Runtime.reconcile_signal
      runtime
      ~request_generation:13L
      (Worker_pure_data.Resync_required { generation = "generation-3"
         ; reason = "retention overflow"
         })
  in
  let output = settle_fixture_checks runtime output in
  let observed = List.map (Runtime.worker_read runtime) output.requests in
  let graph = List.find (fun request -> match Runtime.worker_read runtime request with
    | Some(Runtime.Read{query=W.Graph_info;_}) -> true | _ -> false) output.requests in
  let drained = Runtime.fail_request runtime graph ~message:"Synthetic graph-info completion" in
  let observed = observed @ List.map (Runtime.worker_read runtime) drained.requests in
  let graph_info, journals, trees, children, blocks, pages =
    List.fold_left
      (fun (graph_info, journals, trees, children, blocks, pages) request ->
         match request with
         | Some(Runtime.Read{query=W.Graph_info;_})-> graph_info + 1, journals, trees, children, blocks, pages
         | Some(Runtime.Read{query=W.Timeline_read {query=W.Timeline.Dates _;_};_}) -> graph_info, journals + 1, trees, children, blocks, pages
         | Some(Runtime.Read{query=W.Timeline_read {query=W.Timeline.Roots _;_};_}) -> graph_info, journals, trees + 1, children, blocks, pages
         | Some(Runtime.Read{query=W.Child_members _;_}) -> graph_info, journals, trees, children + 1, blocks, pages
         | Some(Runtime.Read{query=W.Outline_block _;_}) -> graph_info,journals,trees,children,blocks+1,pages
         | Some(Runtime.Read{query=W.Page _;_}) -> graph_info,journals,trees,children,blocks,pages+1
         | _ -> Alcotest.fail "resync issued an unregistered query")
      (0, 0, 0, 0, 0, 0)
      observed
  in
  Alcotest.(check int) "graph-info rehydration" 1 graph_info;
  Alcotest.(check int) "journal rehydration" 1 journals;
  Alcotest.(check int) "valid retained roots need no reread" 0 trees;
  Alcotest.(check int) "children rehydration" 1 children;
  Alcotest.(check int) "Detail root metadata rehydration" 1 blocks;
  Alcotest.(check int) "Detail page metadata rehydration" 1 pages
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
         let output = deliver_sample runtime (sample request
             ((failed_sample (Read.Db_error(Logseq_db_worker.Error.create ~code:code ~message:"Read diagnostic" ~details:[] |> Result.get_ok))))) in
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
       if expected = 0 then (
         Alcotest.(check int) "earliest date exhausts without invalid query" 0 (List.length output.requests);
         match (only "earliest date completion" output.responses).payload with
         | Feed_loaded {complete=true;feed;_} -> Alcotest.(check bool) "earliest date has no continuation" true (feed.continuation=None)
         | _ -> Alcotest.fail "earliest date did not complete")
       else let request = only "older journal request" output.requests in
       match Runtime.worker_read runtime request with
       | Some(Runtime.Read{query=W.Timeline_read {query=W.Timeline.Dates {from_day;through_day};_};_}) ->
         Alcotest.(check bool) "first valid lower date" true (W.journal_day 10101=Ok from_day);
         Alcotest.(check bool) "exclusive calendar upper date" true (W.journal_day expected=Ok through_day)
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
    deliver_sample
      runtime
      (sample
         read
         ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_present_block
               { value = (if tagged then { record with tag_titles = [ "周末"; "旅行" ] } else record)
               ; revision = "block-1" })) in match query with |Read.Outline_block _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"))))
  in
  let read = only "unretained owning-page read" output.requests in
  (match Runtime.worker_read runtime read with
   | Some(Runtime.Read{query=W.Page {uuid=page;_};_}) when Graph.Uuid.equal page page_uuid -> ()
   | _ -> Alcotest.fail "detail did not resolve the actual owning page");
  let ordinary_page =
    { page with kind = Ordinary_page; name = "reference"; title = "Reference" }
  in
  let output =
    deliver_sample
      runtime
      (sample
         read
         ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_present_page { page = ordinary_page; revision = "ordinary-page-1" })) in match query with |Read.Page _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"))))
  in
  let children = only "ordinary page direct children" output.requests in
  let child_uuid = Graph.Uuid.of_string "a1000000-0000-4000-9000-000000000003" |> Result.get_ok in
  let output =
    deliver_sample
      runtime
      (sample
         children
         ((children_sample ~parent:(block_uuid) ~scope_revision:("children-1") ~items:((if tagged then
                [ { Worker_pure_data.value = { record with block =
                      { block with uuid = child_uuid; parent = block_uuid; title = "Child" }
                    ; tag_titles = [ "地图" ] }
                  ; revision = "child-1" } ] else [])) ~next:(None))))
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

let initial_detail_children runtime =
  let first =
    Runtime.submit
      runtime
      (Journal_graph_request.Load_detail
         { block_id = Graph.Uuid.to_string block_uuid
         ; after = None
         ; limit = 32
         ; request_generation = 91L
         })
    |> fun output -> only "detail root" output.requests
  in
  deliver_sample
    runtime
    (sample
       first
       ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_present_block { value = record; revision = "block-1" })) in match query with |Read.Outline_block _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"))))
  |> fun output -> only "detail children" output.requests
;;

let test_detail_children_use_owned_worker_query () =
  let runtime = Runtime.create () in
  seed_feed runtime;
  let original = initial_detail_children runtime in
  (match Production_runtime.worker_read runtime original with
   | Some
       (Production_runtime.Read
          { query = Journal_worker_coordination.Worker_api.Child_members _
          ; maximum_items = 32
          ; _
          }) -> ()
   | _ -> Alcotest.fail "Detail children bypassed typed coordinator");
  ignore (Runtime.abandon runtime original);
  match Production_runtime.worker_read runtime original with
  | None -> ()
  | _ -> Alcotest.fail "retired Detail children became legacy read"
;;

let test_detail_empty_more_preserves_cursor () =
  let runtime = Runtime.create () in
  seed_feed runtime;
  let original = initial_detail_children runtime in
  let cursor = Graph.Cursor.of_string "empty-detail-more" |> Result.get_ok in
  let output =
    deliver_sample
      runtime
      (sample
         original
         ((children_sample ~parent:(block_uuid) ~scope_revision:("children-1") ~items:([]) ~next:(Some cursor))))
  in
  match (only "empty More Detail still publishes" output.responses).payload with
  | Detail_loaded { detail; _ } ->
    Alcotest.(check bool)
      "empty page retains More"
      true
      (Option.is_some detail.children.continuation)
  | _ -> Alcotest.fail "empty More lost Detail owner"
;;

let test_detail_forwards_child_cursor () =
  let runtime = Runtime.create () in
  seed_feed runtime;
  let first = initial_detail_children runtime in
  let cursor = Graph.Cursor.of_string "detail-next-page" |> Result.get_ok in
  let output =
    deliver_sample
      runtime
      (sample
         first
         ((children_sample ~parent:(block_uuid) ~scope_revision:("children-1") ~items:([ { Worker_pure_data.value =
                      { record with
                        block =
                          { block with
                            uuid = unrelated_uuid
                          ; parent = block_uuid
                          ; order = "m"
                          }
                      }
                  ; revision = "child-1"
                  }
                ]) ~next:(Some cursor))))
  in
  let after =
    match (only "Detail initial page" output.responses).payload with
    | Detail_loaded { detail; _ } -> Option.get detail.children.continuation
    | _ -> Alcotest.fail "Detail initial page unavailable"
  in
  let wrong =
    Runtime.submit
      runtime
      (Journal_graph_request.Load_day_blocks
         { day = 20260901; after = Some after; limit = 1; request_generation = 93L })
  in
  Alcotest.(check int)
    "child cursor cannot dispatch Timeline read"
    0
    (List.length wrong.requests);
  (match (only "foreign family failure" wrong.responses).payload with
   | Day_blocks_failed { request_generation = 93L; _ } -> ()
   | _ -> Alcotest.fail "foreign child cursor lost Timeline owner");
  let first =
    Runtime.submit
      runtime
      (Journal_graph_request.Load_detail
         { block_id = Graph.Uuid.to_string block_uuid
         ; after = Some after
         ; limit = 9
         ; request_generation = 92L
         })
    |> fun output -> only "continuation root read" output.requests
  in
  let child =
    deliver_sample
      runtime
      (sample
         first
         ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_present_block { value = record; revision = "block-1" })) in match query with |Read.Outline_block _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"))))
    |> fun output -> only "continuation child read" output.requests
  in
  match Worker_producer.transport runtime child with
  | Ok(Worker_producer.S.Coordination_query{read=Read.Read_query(budget,(Read.Child_members{after=_;_} as query));_}) ->
      assert (Read.For_worker.read_budget_maximum_items budget=32);
      let actual=fixture_cursor budget query |> Option.get in
      assert (actual=cursor);()
  | _ -> Alcotest.fail "Detail lost sealed continuation or its original budget"
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
         Production_runtime.receive_worker_read runtime ~request_id:request
             (Production_runtime.Read_failed{code=code;message="Status write diagnostic"})
       in
       if code = Logseq_db_worker.Error.Conflict
       then (
         Alcotest.(check int)
           "conflict waits for authoritative data"
           0
           (List.length output.responses);
         match Runtime.worker_read runtime (only "conflict refresh" output.requests) with
         | Some(Runtime.Read{query=W.Block_summary {block;_};_}) ->
           Alcotest.(check string) "conflicted target"
             (Graph.Uuid.to_string block_uuid) (Graph.Uuid.to_string block)
         | _ -> Alcotest.fail "Conflict did not read its canonical target")
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
             (Graph.Uuid.to_string request)
             (Graph.Uuid.to_string failure.request_id)
         | _ -> Alcotest.fail "Status failure lost its worker error"))
    Logseq_db_worker.Error.[ Corrupt_storage; Invalid_request; Closed_session; Conflict ]
;;

type refresh_case =
  | Task_change
  | Task_conflict
  | Delete_conflict

type refresh_result =
  | Found
  | Missing
  | Cursor_failed

let prepare_unbound_mutation ?(ordinary=false) kind =
  let page=if ordinary then {page with kind=Ordinary_page;name="ordinary";title="Ordinary"} else page in
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
  let receive request outcome = deliver_sample runtime (sample request outcome) in
  let next description output = only description output.Runtime.requests in
  let page, mutation =
    match kind with
    | Task_change | Task_conflict | Delete_conflict ->
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
          ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_present_block
                { value = { record with block = { block with order = "a1" } }
                ; revision = "block-1"
                })) in match query with |Read.Outline_block _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch")))
        |> next "target page lookup"
      in
      let children =
        receive
          page_lookup
          ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_present_page { page; revision = "page-1" })) in match query with |Read.Page _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch")))
        |> next "target child lookup"
      in
      ignore
        (receive
           children
           ((children_sample ~parent:(block_uuid) ~scope_revision:("target-children-1") ~items:([]) ~next:(None))));
      let command =
        if kind = Delete_conflict
        then
          Journal_graph_request.Delete_subtree
            { mutation_id = Graph.Uuid.to_string mutation_id
            ; block_id = Graph.Uuid.to_string block_uuid
            ; expected_revision = "block-1"
            }
        else
          Journal_graph_request.Set_task_state
            { mutation_id = Graph.Uuid.to_string mutation_id
            ; block_id = Graph.Uuid.to_string block_uuid
            ; expected_revision = "block-1"
            ; task_state = Journal_model.Status "00000002-1827-5820-8200-000000000000"
            }
      in
      page, Runtime.submit runtime command |> next "target mutation"
  in
  runtime, page, mutation
;;

module Target_fixture = struct
  module W=Worker_producer.W
  module I=Worker_producer.I
  module S=Worker_producer.S
  let session=Worker_producer.session
  let presentation=Option.get(W.selected Worker_producer.projection)
  type t=Pending :
    { original:Graph.Uuid.t
    ; operation:'a W.request
    ; proof:(W.presentation * W.receipt) option
    ; deliver:'a W.reply -> Production_runtime.output
    } -> t

  let failure = function
    |W.Db_error error->Logseq_db_worker.Error.code error,Logseq_db_worker.Error.message error
    |Stale_read message->Logseq_db_worker.Error.Stale_read_cursor,message
    |Service_failed message|Invalid_input message|Protocol_mismatch message->Logseq_db_worker.Error.Invalid_request,message
    |_->Logseq_db_worker.Error.Closed_session,"The typed target read was interrupted."

  let query ?proof runtime original = match Production_runtime.worker_read runtime original with
    |Some(Production_runtime.Read read)->
      let budget=Worker_producer.budget read.maximum_items in
      Pending{original;operation=W.Query(budget,read.query);proof;deliver=(function
        |W.Answered(Ok value)->Production_runtime.receive_worker_read ~origin:(session,budget)
            runtime ~request_id:original (Production_runtime.Query_result(read.query,value))
        |Answered(Error error)->let code,message=failure error in
          Production_runtime.receive_worker_read runtime ~request_id:original (Production_runtime.Read_failed{code;message})
        |_->Production_runtime.fail_request runtime original ~message:"Typed target query did not complete")}
    |Some(Production_runtime.Confirm_readback read)->
      (* A fresh snapshot retry is still a Confirm of the original intent. *)
      let presentation,receipt=Option.get proof in
      Alcotest.(check bool) "snapshot retry retains original typed intent" true
        (W.encode_durable_intent(W.receipt_intent receipt)=W.encode_durable_intent read.intent
         && presentation=read.presentation);
      let complete result=Production_runtime.receive_worker_read runtime ~request_id:original result in
      Pending{original;operation=W.Confirm(read.presentation,receipt);proof;deliver=(function
        |W.Answered(Ok confirmation)->
          (match W.confirmation_primary confirmation with
           |Confirmed_block value->complete(Production_runtime.Query_result(read.query,value))
           |_->complete(Production_runtime.Read_failed{code=Logseq_db_worker.Error.Invalid_request;message="The canonical mutation target is unavailable."}))
        |Answered(Error error)->let code,message=failure error in complete(Production_runtime.Read_failed{code;message})
        |_->Production_runtime.fail_request runtime original ~message:"The original confirmation is still pending.")}
    |_->failwith "Target continuation must be an original typed read"

  let send (Pending pending) outcome =
    let request_id=W.request_id pending.original in
    let source=I.request session ~request_id pending.operation |> Result.get_ok in
    let reply_response=outcome source in
    let reply=match I.reply session ~request_id pending.operation reply_response with
      |Ok reply->reply|Error error->W.Answered(Error error) in
    pending.deliver reply

  let mutation runtime original outcome =
    let intent=match Production_runtime.worker_intent runtime original session |> Result.get_ok with W.Mutation_intent intent->intent|_->assert false in
    Alcotest.(check bool) "original typed target intent binds before execution" true
      (Production_runtime.bind_mutation runtime original ~presentation ~intent:(W.Mutation_intent intent));
    let request_id=W.request_id original in
    let operation=W.Mutate intent in
    ignore(I.request session ~request_id operation |> Result.get_ok);
    match I.reply session ~request_id operation
      (S.Coordination_mutation_result{request_id=original;outcome}) with
    |Ok(W.Answered(Ok submission))->intent,(match submission with
      |W.Submission_rejected error->W.Rejected error
      |Submission_unknown->W.Outcome_unknown
      |Submission_committed receipt->W.Committed_pending_presentation receipt)
    |_->failwith "Original typed mutation proof was rejected"

  let committed runtime original =
    let mutation_id=W.durable_intent_id(Production_runtime.worker_intent runtime original session |> Result.get_ok) in
    let _,progress=mutation runtime original
      (Logseq_db_worker_contract.Worker_pure_mutation.Committed
        ((Logseq_db_worker_contract.Worker_pure_mutation.For_worker.commit ~mutation_id:(mutation_id) ~status:(Worker_pure_data.V2_applied) ~generation:("generation:v1:1:1") ~before:("projection:v1:1") ~after:("projection:v1:2")))) in
    let receipt=match progress with W.Committed_pending_presentation receipt->receipt|_->assert false in
    Pending{original;operation=W.Confirm(presentation,receipt);proof=Some(presentation,receipt);deliver=(function
      |W.Answered(Ok confirmation)->Production_runtime.receive_mutation runtime original (W.Confirmed confirmation)
      |Answered(Error error)->let _,message=failure error in Production_runtime.mutation_waiting runtime original message
      |_->Production_runtime.mutation_waiting runtime original "Original confirmation is pending.")}

  let rejected runtime original =
    let _,progress=mutation runtime original
      (Logseq_db_worker_contract.Worker_pure_mutation.Rejected
        ((Logseq_db_worker.Error.create ~code:Conflict ~message:("Concurrent target change") ~details:[] |> Result.get_ok))) in
    let output=Production_runtime.receive_mutation runtime original progress in
    query runtime (only "post-rejection typed target read" output.requests)

  let summary pending page lookup children next_cursor revision =
    send pending ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok(F.block_summary ~lookup:(lookup) ~page:(Some(Worker_pure_data.V2_present_page{page;revision="page-1"})) ~items:(children) ~next:(Option.map(fun cursor->F.continuation ~owner:(F.read_budget_owner budget) ~budget ~key:(Read.query_key budget query) ~cursor)(next_cursor)) ~scope_revision:("target-children-1") ~generation:("graph-1") ~projection_revision:(revision)) in match query with |Read.Block_summary _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch")))

  let next runtime (Pending previous) label output=query ?proof:previous.proof runtime (only label output.Production_runtime.requests)
  let original(Pending pending)=pending.original
  (* Inspect the actual UI projection while leaving the durable settlement and
     its original proof intact in the output consumed by the application. *)
  let payload (response:Production_runtime.response)=match response.payload with
    |Mutation_settled(_,_,payload)->payload
    |payload->payload
end

let prepare_paged_refresh kind =
  let runtime,page,mutation=prepare_unbound_mutation kind in
  let target=match kind with
    |Task_change->Target_fixture.committed runtime mutation
    |Task_conflict|Delete_conflict->Target_fixture.rejected runtime mutation in
  runtime,page,target
;;


let check_target_summary (Target_fixture.Pending pending) cursor =
  let module W=Target_fixture.W in
  match pending.operation with
  |W.Confirm _->Alcotest.(check bool) "first target uses its original typed Confirm" true (cursor=None)
  |W.Query _->
    (match Target_fixture.I.request Target_fixture.session
      ~request_id:(W.request_id pending.original) pending.operation with
     |Ok(Target_fixture.S.Coordination_query{read=Read.Read_query(budget,(Read.Block_summary{block;after=_;_} as query));_})->
      let limit=Read.For_worker.read_budget_maximum_items budget in
      let actual=fixture_cursor budget query in
       Alcotest.(check bool) "target identity" true(Graph.Uuid.equal block block_uuid);
       Alcotest.(check int) "bounded target children" Worker_pure_data.default_page_size limit;
       Alcotest.(check bool) "target children cursor" true(actual=cursor)
     |_->Alcotest.fail "target must use the original typed summary query")
  |_->Alcotest.fail "target confirmation used another operation"
;;

let test_paged_mutation_refresh kind result =
  let runtime, page, refresh = prepare_paged_refresh kind in
  (
    check_target_summary refresh None;
    let target =
      { record with
        block =
          { block with page = page.uuid; parent = page.uuid; title = "Committed target" }
      }
    in
    let lookup = Worker_pure_data.V2_present_block { value = target; revision = "target-2" } in
    let completed =
      match result with
      | Found ->
        Target_fixture.summary refresh page lookup [] None "projection-2"
      | Missing ->
        Target_fixture.summary
             refresh
             page
             (Worker_pure_data.V2_missing_block { uuid = block_uuid; revision = "missing-2" })
             []
             None
             "projection-2"
      | Cursor_failed when kind=Task_change ->
        Target_fixture.send refresh ((failed_sample (Read.Stale_read ("Concurrent target change"))))
      | Cursor_failed ->
        let current = ref refresh in
        for _ = 1 to 2 do
          current := Target_fixture.send !current
            ((failed_sample (Read.Stale_read ("Concurrent target change"))))
            |> Target_fixture.next runtime !current "bounded canonical retry"
        done;
        Target_fixture.send !current
          ((failed_sample (Read.Stale_read ("Concurrent target change"))))
    in
    if kind=Task_change && result=Cursor_failed then (
      Alcotest.(check bool) "failed confirmation retains original intent" true
        (Runtime.pending_mutation runtime ~mutation_id:"a1000000-0000-4000-a000-000000000021"<>None);
      Alcotest.(check bool) "failed confirmation does not settle or ACK" false
        (List.exists(fun response->match response.Runtime.payload with Mutation_settled _->true|_->false)completed.responses))
    else Alcotest.(check int) "target terminal confirmation stops reading" 0(List.length completed.requests);
    if kind=Task_change && result=Cursor_failed then () else match
      result, kind, (match (only "owned canonical target terminal" completed.responses).payload with
       |Mutation_settled(_,_,payload)->payload|payload->payload)
    with
    | Found, Task_change, Block_updated { block; _ } ->
      Alcotest.(check string)
        "authoritative target after earlier siblings"
        "Committed target"
        (Journal_model.source block)
    | Cursor_failed, _, Mutation_failed { failure = Worker_failure failure; _ } ->
      Alcotest.(check bool)
        "cursor failure category is preserved"
        true
        (Logseq_db_worker.Error.code failure.error = Stale_read_cursor)
    | Found, Task_conflict, Update_conflict {block=actual;_}
    | Found, Delete_conflict, Delete_conflict {block=actual;_} ->
      Alcotest.(check string) "canonical conflicted target"
        "Committed target" (Journal_model.source actual)
    | Missing, Delete_conflict, Subtree_deleted {deleted_count=Some 0;_} -> ()
    | Missing, Task_change, Block_removed _ -> ()
    | Cursor_failed, Task_change, _ -> ()
    | Missing, _, Mutation_failed _ -> ()
    | _ -> Alcotest.fail "unexpected canonical mutation completion")
;;


(* The pure SDK cannot reproduce business ownership's journal-only page map.
   Exercise the public Runtime boundary with a real ordinary Detail and sealed
   canonical DTOs issued by the same typed Worker test issuer. *)
let test_ordinary_delete_readback committed paged () =
  let module W=Worker_producer.W in
  let module I=Worker_producer.I in
  let runtime,page,request=prepare_unbound_mutation ~ordinary:true Delete_conflict in
  let request=if committed then request else Target_fixture.original(Target_fixture.rejected runtime request) in
  let target={record with block={block with page=page.uuid;parent=page.uuid;title="Ordinary canonical target"}} in
  let lookup=Worker_pure_data.V2_present_block{value=target;revision="canonical-current"} in
  let summary _ cursor=(query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok(F.block_summary ~lookup:(lookup) ~page:(Some(Worker_pure_data.V2_present_page{page;revision="page-2"})) ~items:([]) ~next:(Option.map(fun cursor->F.continuation ~owner:(F.read_budget_owner budget) ~budget ~key:(Read.query_key budget query) ~cursor)(cursor)) ~scope_revision:("ordinary-children") ~generation:("generation:v1:1:1") ~projection_revision:("projection:v1:2")) in match query with |Read.Block_summary _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch")) in
  let output=if committed then (
    let session=Worker_producer.session in
    let presentation=Option.get(W.selected Worker_producer.projection) in
    let intent=match Runtime.worker_intent runtime request session |> Result.get_ok with W.Mutation_intent intent->intent|_->assert false in
    let mutation_id=W.mutation_intent_id intent in
    Alcotest.(check bool) "ordinary mutation business owner bound" true
      (Production_runtime.bind_mutation runtime request ~presentation ~intent:(W.Mutation_intent intent));
    let receipt=(let receipt_request_id=request in let packet=((Logseq_db_worker_contract.Worker_pure_mutation.For_worker.commit ~mutation_id:(mutation_id) ~status:(Worker_pure_data.V2_applied) ~generation:("generation:v1:1:1") ~before:("projection:v1:0") ~after:("projection:v1:1"))) in
      match I.reply session ~request_id:(W.request_id request) (W.Mutate intent)
        (Logseq_db_worker_lui.Logseq_db_worker_lui_service.Coordination_mutation_result
          {request_id=receipt_request_id;
           outcome=Logseq_db_worker_contract.Worker_pure_mutation.Committed packet}) with
      | Ok(W.Answered(Ok(W.Submission_committed proof))) -> proof
      | _ -> failwith "Production mutation receipt was rejected") in
    let confirmation=confirmed_sample Worker_producer.issuer session presentation receipt request
      (summary request(if paged then Some(Graph.Cursor.of_string "ordinary-more" |> Result.get_ok) else None)) in
    let output=Production_runtime.receive_mutation runtime request(W.Confirmed confirmation) in
    if paged then (
      Alcotest.(check bool) "ordinary More cannot settle before final DTO" false
        (List.exists(fun r->match r.Production_runtime.payload with Mutation_settled _->true|_->false)output.responses);
      let more=only "ordinary canonical More remains typed" output.requests in
      Worker_producer.deliver runtime more(summary more None)) else output)
    else Worker_producer.deliver runtime request(summary request None) in
  let current=List.find_map(fun response->match response.Runtime.payload with
    | Mutation_settled(_,_,Delete_reappeared{block;timeline_entry_update=None}) when committed->Some block
    | Mutation_settled(_,_,Delete_conflict{block;timeline_entry_update=None}) when not committed->Some block
    | _->None)output.responses in
  match current with
  | Some block->
    Alcotest.(check string) "ordinary canonical DTO is consumed" "Ordinary canonical target" (Journal_model.source block);
    Alcotest.(check(option int)) "ordinary page never invents journal date" None(Journal_model.journal_day_opt block)
  | None->Alcotest.fail "ordinary canonical delete readback could not settle"
;;

let test_conflict_missing_after_empty_more changed_version () =
  let runtime, page, first = prepare_paged_refresh Delete_conflict in
  let cursor = Graph.Cursor.of_string "empty-present-prefix" |> Result.get_ok in
  let prefix = Target_fixture.summary first page (Worker_pure_data.V2_present_block {value=record;revision="target-2"})
      [] (Some cursor) "projection-2" in
  let next = Target_fixture.next runtime first "empty More target continuation" prefix in
  let missing request revision = Target_fixture.summary request page
    (Worker_pure_data.V2_missing_block {uuid=block_uuid;revision="missing-2"}) [] None revision in
  let output = missing next (if changed_version then "projection-3" else "projection-2") in
  if changed_version then (
    Alcotest.(check int) "version change cannot confirm continuation absence" 0
      (List.length output.responses);
    let fresh = Target_fixture.next runtime next "fresh target read after version change" output in
    check_target_summary fresh None;
    let final = missing fresh "projection-3" in
    match (Target_fixture.payload (only "fresh complete absence" final.responses)) with
    | Subtree_deleted {deleted_count=Some 0;_} -> ()
    | _ -> Alcotest.fail "fresh authoritative absence was not accepted")
  else (
    Alcotest.(check int) "contradictory chain does not continue" 0
      (List.length output.requests);
    match (Target_fixture.payload (only "contradictory target response" output.responses)) with
    | Mutation_failed _ -> ()
    | _ -> Alcotest.fail "same-version present prefix became successful absence")
;;

(* F3 is owned by the public Runtime request/completion boundary. The original
   RED phase used wire representations before the new command existed,
   so baseline tests fail on the emitted read rather than missing OCaml types. *)
let target_refresh = function
  | `Status->prepare_paged_refresh Task_change
  | `Status_conflict->prepare_paged_refresh Task_conflict
  | `Delete_conflict->prepare_paged_refresh Delete_conflict
;;

let test_target_summary_uses_owned_worker_query () =
  let runtime,page,confirmation=target_refresh `Status in
  check_target_summary confirmation None;
  let value={record with block={block with parent=page.uuid;page=page.uuid}} in
  let output=Target_fixture.summary confirmation page
    (Worker_pure_data.V2_present_block{value;revision="canonical-2"}) []
    (Some(Graph.Cursor.of_string "owned-summary-next" |> Result.get_ok)) "projection-2" in
  let request=only "actual confirmed More" output.requests in
  (match Production_runtime.worker_read runtime request with
   |Some(Production_runtime.Read{query=Journal_worker_coordination.Worker_api.Block_summary{after=Some _;_};maximum_items})->
     Alcotest.(check int) "retained summary budget" Worker_pure_data.default_page_size maximum_items
   |_->Alcotest.fail "canonical More bypasses typed coordinator");
  Production_runtime.abandon runtime request;
  match Production_runtime.worker_read runtime request with
  |None->()
  |_->Alcotest.fail "retired summary falls back to legacy transport"
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
    Worker_pure_data.{ value = { record with block = child }; revision = "child-2" })
;;

let test_target_confirmation kind title count =
  let _runtime, page, refresh = target_refresh kind in
  check_target_summary refresh None;
  let canonical =
    { record with
      block = { block with page = page.uuid; parent = page.uuid; title; order = "z" }
    }
  in
  let children = summary_children ~page:page.uuid count in
  let complete =
    Target_fixture.summary
         refresh
         page
         (Worker_pure_data.V2_present_block { value = canonical; revision = "canonical-2" })
         children
         None
         "projection-2"
  in
  Alcotest.(check int)
    "target completion does not read siblings"
    0
    (List.length complete.requests);
  let payload = (Target_fixture.payload (only "target completion" complete.responses)) in
  let actual, entry =
    match kind, payload with
    | `Status, Runtime.Block_updated { block; timeline_entry_update } ->
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

;;

let test_target_children_continue () =
  let runtime, page, refresh = target_refresh `Status in
  let canonical =
    { record with
      block =
        { block with page = page.uuid; parent = page.uuid; title = "Canonical root" }
    }
  in
  let lookup =
    Worker_pure_data.V2_present_block { value = canonical; revision = "canonical-2" }
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
           index >= batch * Worker_pure_data.default_page_size
           && index < (batch + 1) * Worker_pure_data.default_page_size)
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
      Target_fixture.summary !current page lookup items cursor "projection-2"
    in
    if batch < 4
    then (
      Alcotest.(check int)
        "partial target children do not complete Status"
        0
        (List.length output.responses);
      current := Target_fixture.next runtime !current "target child continuation" output;
      previous_cursor := cursor)
    else completion := output
  done;
  match (Target_fixture.payload (only "all canonical children" !completion.responses)) with
  | Block_updated { block; timeline_entry_update = Some entry } ->
    Alcotest.(check int)
      "child count is not truncated"
      201
      (Journal_model.child_count block);
    Alcotest.(check int)
      "bounded target child preview"
      3
      (List.length entry.child_summaries)
  | _ -> Alcotest.fail "Status lost its canonical children"
;;

let test_target_repeated_cursor_settles () =
  let runtime, page, first = target_refresh `Status in
  let lookup =
    Worker_pure_data.V2_present_block
      { value =
          { record with block = { block with page = page.uuid; parent = page.uuid } }
      ; revision = "canonical-2"
      }
  in
  let cursor = Some (Graph.Cursor.of_string "nonadvancing-summary" |> Result.get_ok) in
  let page request =
    Target_fixture.summary request page lookup [] cursor "projection-2"
  in
  let next = page first |> Target_fixture.next runtime first "summary continuation" in
  let output = page next in
  Alcotest.(check int)
    "nonadvancing summary cannot continue"
    0
    (List.length output.requests);
  match (Target_fixture.payload (only "summary failure remains owned" output.responses)) with
  | Runtime.Mutation_waiting _ ->
    Alcotest.(check bool) "nonadvancing More preserves original intent" true
      (Runtime.pending_mutation runtime ~mutation_id:"a1000000-0000-4000-a000-000000000021"<>None)
  | _ -> Alcotest.fail "nonadvancing summary lost mutation owner"
;;

let test_target_terminal kind terminal =
  let runtime,page,target=target_refresh kind in
  check_target_summary target None;
  let original=Target_fixture.original target in
  let output=match terminal with
    |`Missing->Target_fixture.summary target page
      (Worker_pure_data.V2_missing_block{uuid=block_uuid;revision="missing"}) [] None "projection-2"
    |`Failure->Target_fixture.send target ((failed_sample (Read.Db_error(Logseq_db_worker.Error.create ~code:Closed_session ~message:("read unavailable") ~details:[]|>Result.get_ok))))
    |`Reset->Runtime.reset runtime;Target_fixture.summary target page
      (Worker_pure_data.V2_missing_block{uuid=block_uuid;revision="missing"}) [] None "projection-2" in
  match terminal with
  |`Reset->Alcotest.(check int) "old graph completion ignored" 0(List.length output.responses)
  |`Missing->
    (match (only "canonical absence is settled" output.responses).payload with
     |Mutation_settled(_,_,Block_removed{block_id})->
       Alcotest.(check string) "canonical absence retains target identity" (Graph.Uuid.to_string block_uuid) block_id
     |_->Alcotest.fail "canonical absence lost original durable ownership")
  |`Failure->
    Alcotest.(check bool) "confirmation failure preserves the original intent" true
      (Runtime.pending_mutation runtime ~mutation_id:"a1000000-0000-4000-a000-000000000021"<>None);
    Alcotest.(check bool) "confirmation failure does not pretend to settle or ACK" false
      (List.exists(fun response->match response.Runtime.payload with Mutation_settled _->true|_->false)output.responses);
    List.iter(fun (request:Graph.Uuid.t)->Alcotest.(check bool) "safe recovery retains original immutable payload" true
      (request=original))output.requests
;;

let test_target_version_fence () =
  let runtime, page, refresh = target_refresh `Status in
  check_target_summary refresh None;
  let canonical =
    { record with block = { block with page = page.uuid; parent = page.uuid } }
  in
  let lookup =
    Worker_pure_data.V2_present_block { value = canonical; revision = "canonical-2" }
  in
  let cursor = Graph.Cursor.of_string "target-children-next" |> Result.get_ok in
  let first =
    Target_fixture.summary
         refresh
         page
         lookup
         (summary_children ~page:page.uuid Worker_pure_data.default_page_size)
         (Some cursor)
         "projection-2"
  in
  let continuation = Target_fixture.next runtime refresh "target child continuation" first in
  let result =
    Target_fixture.summary continuation page lookup [] None "projection-3"
  in
  Alcotest.(check bool)
    "different snapshots cannot complete mixed Status"
    false
    (List.exists
       (fun value ->
          match Target_fixture.payload value with
          | Block_updated _ -> true
          | _ -> false)
       result.responses);
  let retry = Target_fixture.next runtime continuation "fresh canonical target retry" result in
  check_target_summary retry None
;;

let test_target_rejects_wrong_identity () =
  let runtime, page, refresh = target_refresh `Status in
  check_target_summary refresh None;
  let output =
    Target_fixture.summary
         refresh
         page
         (Worker_pure_data.V2_present_block
            { value = { record with block = { block with uuid = unrelated_uuid } }
            ; revision = "foreign"
            })
         []
         None
         "projection-2"
  in
  Alcotest.(check bool) "foreign canonical data never becomes an applied projection" false
    (List.exists(fun response->match response.Runtime.payload with Block_updated _|Mutation_settled _->true|_->false)output.responses);
  Alcotest.(check bool) "rejected canonical identity preserves original durable intent" true
    (Runtime.pending_mutation runtime ~mutation_id:"a1000000-0000-4000-a000-000000000021"<>None)

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
       let _runtime, page, refresh = target_refresh `Status in
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
         Target_fixture.summary
              refresh
              page
              (Worker_pure_data.V2_present_block { value = canonical; revision = "canonical-2" })
              [ image ]
              None
              "projection-2"
       in
       match
         (Target_fixture.payload (only "canonical blank/image or deep child completion" output.responses))
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
  let runtime,page,confirmation=target_refresh `Status in
  let value={record with block={block with page=page.uuid;parent=page.uuid}} in
  let prefix=Target_fixture.summary confirmation page
    (Worker_pure_data.V2_present_block{value;revision="canonical-2"}) []
    (Some(Graph.Cursor.of_string "stale-target-more" |> Result.get_ok)) "projection-2" in
  let current=ref(Target_fixture.next runtime confirmation "first typed canonical More" prefix) in
  let stale request=Target_fixture.send request
    ((failed_sample (Read.Stale_read ("Concurrent projection")))) in
  for _=1 to 2 do
    let output=stale !current in
    Alcotest.(check int) "retry does not prematurely complete Status" 0(List.length output.responses);
    current:=Target_fixture.next runtime !current "bounded fresh target retry" output;
    check_target_summary !current None
  done;
  let exhausted=stale !current in
  Alcotest.(check int) "stale retries stop" 0(List.length exhausted.requests);
  (match (only "owned retry exhaustion" exhausted.responses).payload with
   |Mutation_waiting{block_id;_}->Alcotest.(check string) "unknown confirmation retains target" (Graph.Uuid.to_string block_uuid) block_id
   |_->Alcotest.fail "stale retry exhaustion lost original pending intent");
  Alcotest.(check bool) "failed More never ACKs original intent" true
    (Runtime.pending_mutation runtime ~mutation_id:"a1000000-0000-4000-a000-000000000021"<>None)
;;

let test_target_newer_confirmation_fences_old () =
  List.iter(fun paged->
  let runtime,page,original_confirm=target_refresh `Status in
  let original=Target_fixture.original original_confirm in
  let older={record with block={block with title="Older local snapshot";page=page.uuid;parent=page.uuid}} in
  let old_confirm=if not paged then original_confirm else (
    let prefix=Target_fixture.summary original_confirm page
      (Worker_pure_data.V2_present_block{value=older;revision="canonical-2"}) []
      (Some(Graph.Cursor.of_string "old-canonical-more" |> Result.get_ok)) "projection-2" in
    Alcotest.(check int) "empty Partial cannot settle the admitted write" 0(List.length prefix.responses);
    Target_fixture.next runtime original_confirm "actual typed More snapshot" prefix) in
  let updates=changed runtime(window ~blocks:[block_uuid]()) in
  let point=only "remote change owns its point read" (hydration_requests runtime updates) in
  let newer={record with block={block with title="Newer remote value";page=page.uuid;parent=page.uuid}} in
  let applied=deliver_sample runtime
    (sample point((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_present_block{value=newer;revision="canonical-3"})) in match query with |Read.Outline_block _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch")))) in
  let applied=match applied.requests with
    |[]->applied
    |[context]->deliver_sample runtime
      (sample context((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_present_page{page;revision="page-3"})) in match query with |Read.Page _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"))))
    |_->Alcotest.fail "remote confirmation fence requested unrelated context" in
  Alcotest.(check bool) "newer remote point is actually applied first" true
    (List.exists(fun response->match Target_fixture.payload response with
      |Block_updated{block;_}->Journal_model.source block="Newer remote value"|_->false)applied.responses);
  let late=Target_fixture.summary old_confirm page
    (Worker_pure_data.V2_present_block{value=older;revision="canonical-2"}) [] None "projection-2" in
  Alcotest.(check bool) "old Confirm cannot overwrite an already applied remote point" false
    (List.exists(fun response->match Target_fixture.payload response with Block_updated _->true|_->false)late.responses);
  Alcotest.(check bool) "stale Confirm retains the original durable obligation" true
    (Runtime.pending_mutation runtime ~mutation_id:"a1000000-0000-4000-a000-000000000021"<>None);
  let retry=only "same intent is confirmed again rather than ACKed" late.requests in
  Alcotest.(check bool) "recovery keeps original immutable payload" true (retry=original);
  Alcotest.(check int) "a superseded sample adds no transient UI" 0(List.length late.responses);
  let Target_fixture.Pending pending=original_confirm in
  (match pending.operation with
   |Target_fixture.W.Confirm(presentation,receipt)->
     Alcotest.(check bool) "new confirmation attempt rebinds the original durable intent" true
       (Runtime.bind_mutation runtime retry ~presentation ~intent:(Target_fixture.W.receipt_intent receipt));
     let recovered=Target_fixture.summary original_confirm page
       (Worker_pure_data.V2_present_block{value=newer;revision="canonical-3"}) [] None "projection-3" in
     (match (only "fresh confirmation applies before original intent settlement" recovered.responses).payload with
      |Mutation_settled(intent,_,Block_updated{block;_})->
        Alcotest.(check bool) "fresh confirmation retains original durable identity" true
          (Target_fixture.W.encode_durable_intent intent=Target_fixture.W.encode_durable_intent(Target_fixture.W.receipt_intent receipt));
        Alcotest.(check string) "fresh canonical DTO agrees with the newer visible source" "Newer remote value"(Journal_model.source block)
      |_->Alcotest.fail "fresh confirmation lost its canonical DTO or original proof")
   |_->assert false)
) [false;true]
;;

let test_target_invisible_root_has_timeline_only_removal () =
  let _runtime, page, refresh = target_refresh `Status in
  check_target_summary refresh None;
  let canonical =
    { record with
      block = { block with title = ""; page = page.uuid; parent = page.uuid }
    }
  in
  let output =
    Target_fixture.summary
         refresh
         page
         (Worker_pure_data.V2_present_block { value = canonical; revision = "canonical-2" })
         []
         None
         "projection-2"
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
          match Target_fixture.payload value with
          | Block_removed _ -> true
          | _ -> false)
       output.responses)
;;

let test_target_confirmation_retains_page_interest completed =
  let runtime, page, refresh = target_refresh `Status in
  check_target_summary refresh None;
  let canonical =
    { record with block = { block with page = page.uuid; parent = page.uuid } }
  in
  if completed
  then
    ignore
      (Target_fixture.summary
            refresh
            page
            (Worker_pure_data.V2_present_block { value = canonical; revision = "canonical-2" })
            []
            None
            "projection-2");
  let output =
    changed runtime (window ~scopes:[ Worker_pure_data.V2_page_tree_interest page.uuid ] ())
  in
  require_ack runtime output;
  match hydration_requests runtime output with
  | [request] ->
    let actual=match Production_runtime.worker_read runtime request with
     | Some (Production_runtime.Read {query = Worker_producer.W.Timeline_read {query=W.Timeline.Roots page;_};_}) -> page
     | _ -> Alcotest.fail "target page refresh escaped typed Tree ownership" in
    Alcotest.(check bool)
      "target page remains subscribed to structural changes"
      true
      (Graph.Uuid.equal actual page.uuid)
  | requests ->
    Alcotest.failf
      "target page lost its structural interest: %d hydration requests"
      (List.length requests)
;;

let test_target_confirmation_retains_child_mutation_context () =
  let runtime, page, refresh = target_refresh `Status in
  let canonical =
    { record with block = { block with page = page.uuid; parent = page.uuid } }
  in
  let children = summary_children ~page:page.uuid 1 in
  let child = (List.hd children).Worker_pure_data.value.block.uuid in
  ignore
    (Target_fixture.summary
          refresh
          page
          (Worker_pure_data.V2_present_block { value = canonical; revision = "canonical-2" })
          children
          None
          "projection-2");
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
  let original=only "typed child status" status.requests in
  let actual=Runtime.worker_intent runtime original Worker_producer.session |> Result.get_ok in
  let expected=W.mutation_intent Worker_producer.session
    ~mutation_id:(uuid "a1000000-0000-4000-a000-000000000075")
    (W.Set_task_status{block=child;status=uuid "00000002-1827-5820-8200-000000000000";
      preconditions={blocks=[child,"child-2"];pages=[];scopes=[]}}) |> Result.get_ok in
  Alcotest.(check bytes) "canonical child retains exact status context"
    (W.encode_durable_intent(W.Mutation_intent expected))(W.encode_durable_intent actual)
;;

let tree_page request items next_cursor =
  sample
    request
    ((tree_sample ~items:((items : Worker_pure_data.tree_member list)) ~next:(next_cursor)))
;;

let initial_tree runtime =
  set_calendar runtime;
  let journals = load_feed runtime in
  deliver_sample
    runtime
    (sample
       journals
       ((journal_sample ~items:(([ { page; journal_day = 20260901; revision = "page-1" } ] : Worker_pure_data.journal_item list)) ~next:(None))))
  |> fun output -> only "initial tree" output.requests
;;

let check_tree_continuation runtime output cursor =
  Alcotest.(check int)
    "no premature terminal response"
    0
    (List.length output.Runtime.responses);
  let request = only "one sequential continuation" output.requests in
  (match Worker_producer.transport runtime request with
   | Ok(Worker_producer.S.Coordination_query{read=Read.Read_query(budget,(Read.Timeline_read {query=Read.Timeline.Roots actual;_} as query));_})->
      let actual_cursor=fixture_cursor budget query |> Option.get in
      let limit=Read.For_worker.read_budget_maximum_items budget in
     Alcotest.(check bool) "same page" true (Graph.Uuid.equal page_uuid actual);
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
  let root : Worker_pure_data.tree_member =
    { value = record; revision = "root-1"; depth = 0; parent = page_uuid }
  in
  let initial =
    (deliver_sample runtime (tree_page tree [root] (Some cursor)) |>finish_previews runtime ~children:[])
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
         deliver_sample runtime (tree_page request [] (Some cursor))
         |> fun output -> check_tree_continuation runtime output cursor)
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
    deliver_sample
      runtime
      (if outcome = `Stale
       then
         sample
           request
           ((failed_sample (Read.Db_error(Logseq_db_worker.Error.create ~code:Stale_read_cursor ~message:"Changed graph" ~details:[] |> Result.get_ok))))
       else
         tree_page
           request
           (if outcome = `Exhausted then [] else [ later ])
           None) |>finish_previews runtime ~children:[]
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
  let blank : Worker_pure_data.tree_member =
    { value = { record with block = { block with title = " " } }
    ; revision = "root-1"
    ; depth = 0
    ; parent = page_uuid
    }
  in
  let cursor = Graph.Cursor.of_string "blank-root-children" |> Result.get_ok in
  let request =
    (deliver_sample runtime (tree_page tree [blank] (Some cursor)) |>finish_previews runtime ~children:[])
    |> fun output -> check_tree_continuation runtime output cursor
  in
  let cursor = Graph.Cursor.of_string "blank-root-children-next" |> Result.get_ok in
  let request =
    deliver_sample runtime (tree_page request [] (Some cursor))
    |> fun output -> check_tree_continuation runtime output cursor
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
  let completed = (deliver_sample runtime (tree_page request [ visible ] None) |>finish_previews runtime ~children:[]) in
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

let graph_info_sample ~projection_revision ~journal_title_format =
  (query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok(F.graph_info ~graph_uuid:(Worker_producer.W.graph_id Worker_producer.session) ~graph_name:("Journal") ~schema:({ major = 65; minor = 33 }) ~admission_facts:([]) ~journal_title_format:(journal_title_format) ~limits:({ response_budget_bytes = 4_096
        ; outbox_max_records = 4_096
        ; outbox_max_bytes = 8 * 1_024 * 1_024
        ; change_max_items = 4_096
        ; change_max_bytes = 4 * 1_024 * 1_024
        ; dispatcher_capacity = 32
        ; wire_batch_max_bytes = 4 * 1_024 * 1_024
        }) ~generation:("generation-1") ~projection_revision) in match query with |Read.Graph_info->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"))
;;
let graph_info_outcome ~journal_title_format =
  graph_info_sample ~projection_revision:"projection-1" ~journal_title_format
;;


let create_journal_title ~journal_day ~journal_title_format =
  Logseq_db_types.Journal_title.for_journal_day ~pattern:journal_title_format journal_day |> Option.get
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
    deliver_sample
      runtime
      (sample
         journals
         ((journal_sample ~items:(([ { page; journal_day = 20260901; revision = "page-1" } ] : Worker_pure_data.journal_item list)) ~next:(None))))
    |> fun output -> only "reference page tree" output.requests
  in
  deliver_sample
    runtime
    (sample
       tree
       ((tree_sample ~items:(([ { value = { record with block = { block with title = source } }
                ; revision = "block-1"
                ; depth = 0
                ; parent = page_uuid
                }
              ] : Worker_pure_data.tree_member list)) ~next:(None)))) |> finish_previews runtime ~children:[]
;;

let target_response request title =
  sample
    request
    ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_present_block
          { value = { record with block = { block with uuid = target_uuid; title } }
          ; revision = title
          })) in match query with |Read.Outline_block _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch")))
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
  match Runtime.worker_read runtime request with
  | Some(Runtime.Read{query=W.Page {uuid=page;_};_}) ->
    deliver_sample runtime (sample request ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_missing_page {uuid=page;revision="page-absent"})) in match query with |Read.Page _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"))))
    |> fun output -> only "outline lookup after page absence" output.requests
  | Some(Runtime.Read{query=W.Outline_block _;_}) -> request
  | _ -> Alcotest.fail "not a reference lookup"
;;

let check_target_request runtime output =
  let request = only "shared reference point read" (hydration_requests runtime output)
    |> outline_after_page_miss runtime in
  Alcotest.(check bool)
    "reads only target UUID"
    true
    ((match Runtime.worker_read runtime request with Some(Runtime.Read{query=W.Outline_block{uuid;revision=None};_})->uuid=target_uuid|_->false));
  request
;;

let test_reference_hydration_and_changes () =
  let runtime = Runtime.create () in
  let request =
    reference_feed runtime (reference ^ " " ^ reference ^ " [[page]]")
    |> check_target_request runtime
  in
  let resolved = deliver_sample runtime (target_response request "Referenced content") in
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
    deliver_sample runtime (target_response changed_request "Edited content")
  in
  Alcotest.(check (option string))
    "target edit reaches UI"
    (Some "Edited content")
    (List.assoc_opt target_id (reference_updates updated) |> Option.join);
  let deleted_request =
    changed runtime (window ~blocks:[ target_uuid ] ()) |> check_target_request runtime
  in
  let deleted =
    deliver_sample
      runtime
      (sample
         deleted_request
         ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_missing_block { uuid = target_uuid; revision = "deleted" })) in match query with |Read.Outline_block _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"))))
  in
  Alcotest.(check bool)
    "missing target clears cached source"
    true
    (List.assoc_opt target_id (reference_updates deleted) = Some None);
  let recreated_request =
    changed runtime (window ~blocks:[ target_uuid ] ()) |> check_target_request runtime
  in
  ignore (deliver_sample runtime (target_response recreated_request "Recreated"));
  let resync =
    Runtime.reconcile_signal
      runtime
      ~request_generation:12L
      (Worker_pure_data.Resync_required { generation = "generation-2"
         ; reason = "consumer lagged"
         })
  in
  Alcotest.(check bool)
    "resync retains target interest"
    true
    (List.exists
       (fun (request : Graph.Uuid.t) ->
          (match Runtime.worker_read runtime request with Some(Runtime.Read{query=W.Page{uuid;revision=None};_})->uuid=target_uuid|_->false))
       resync.requests);
  Runtime.reset runtime;
  Alcotest.(check int)
    "reset discards old completion"
    0
    (List.length
       (deliver_sample runtime (target_response request "Old graph")).responses)
;;

let test_reference_cycle_and_failure () =
  let runtime = Runtime.create () in
  let request = reference_feed runtime reference |> check_target_request runtime in
  let output =
    deliver_sample
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
    deliver_sample
      runtime
      (sample
         changed_request
         ((failed_sample (Read.Service_failed (("InvalidRequest")^": "^("temporary read failure"))))))
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
         (List.length (hydration_requests runtime changed));
       let stale =
         deliver_sample
           runtime
           (if fail
            then
              sample
                request
                ((failed_sample (Read.Service_failed (("InvalidRequest")^": "^("old snapshot failed")))))
            else target_response request "Stale")
       in
       Alcotest.(check bool)
         "stale completion is not published"
         true
         (not (List.mem (target_id, Some "Stale") (reference_updates stale)));
       let fresh = check_target_request runtime stale in
       let result = deliver_sample runtime (target_response fresh "Fresh") in
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
    (List.length (hydration_requests runtime output))
;;

let test_abandoned_reference_can_refresh () =
  List.iter
    (fun fail ->
       let runtime = Runtime.create () in
       let request = reference_feed runtime reference |> check_target_request runtime in
       if fail
       then ignore (Runtime.fail_request runtime request ~message:"Worker interrupted")
       else Runtime.abandon runtime request;
       let late = deliver_sample runtime (target_response request "Late completion") in
       Alcotest.(check int)
         "interrupted completion is unowned"
         0
         (List.length late.responses + List.length late.requests);
       let fresh =
         changed runtime (window ~blocks:[ target_uuid ] ()) |> check_target_request runtime
       in
       ignore (deliver_sample runtime (target_response fresh "Recovered"));
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
    := deliver_sample
         runtime
         (sample
            request
            ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_present_block
                  { value =
                      { record with
                        block = { block with uuid = uuid (id n); title = link (n + 1) }
                      }
                  ; revision = "chain"
                  })) in match query with |Read.Outline_block _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"))))
  done;
  Alcotest.(check int) "deep chain stops at depth bound" 0 (List.length !output.requests);
  let output = reference_feed runtime (link Journal_model.maximum_reference_depth) in
  let request = only "shorter path discovers previously bounded target" output.requests in
  Alcotest.(check bool)
    "reads next nested target"
    true
    (match Runtime.worker_read runtime request with Some(Runtime.Read{query=W.Page{uuid=target;revision=None};_})->
      target=uuid(id(Journal_model.maximum_reference_depth+1))|_->false)
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
    deliver_sample
      runtime
      (sample
         request
         ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_missing_page
               { uuid =
                   (match Runtime.worker_read runtime request with
                    | Some(Runtime.Read{query=W.Page {uuid=page;_};_}) -> page
                    | _ -> assert false)
               ; revision = "missing"
               })) in match query with |Read.Page _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"))))
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
  deliver_sample
    runtime
    (sample
       request
       ((journal_sample ~items:(([ { page; journal_day = 20260901; revision = "page" } ] : Worker_pure_data.journal_item list)) ~next:(None))))
  |> fun output -> only "reference tree request" output.requests
;;

let reference_tree_response request title =
  let root = { record with block = { block with title = reference } } in
  let target =
    { record with block = { block with uuid = target_uuid; title; order = "b" } }
  in
  sample
    request
    ((tree_sample ~items:((List.map
             (fun value ->
                Worker_pure_data.{ value; revision = title; depth = 0; parent = page_uuid })
             [ root; target ] : Worker_pure_data.tree_member list)) ~next:(None)))
;;

let test_stale_feed_cannot_replace_reference_source () =
  List.iter
    (fun fresh_title ->
       let runtime = Runtime.create () in
       set_calendar runtime;
       let initial = begin_reference_tree runtime 7L in
       ignore ((deliver_sample runtime (reference_tree_response initial "Initial") |>finish_previews runtime ~children:[]));
       let old = begin_reference_tree runtime 8L in
       let current = begin_reference_tree runtime 9L in
       ignore ((deliver_sample runtime (reference_tree_response current fresh_title) |>finish_previews runtime ~children:[]));
       let changed_read =
         changed runtime (window ~blocks:[ target_uuid ] ()) |> check_target_request runtime
       in
       let stale = (deliver_sample runtime (reference_tree_response old "Stale") |>finish_previews runtime ~children:[]) in
       Alcotest.(check bool)
         "invalidated old snapshot cannot publish source"
         false
         (List.mem (target_id, Some "Stale") (reference_updates stale));
       let fresh = deliver_sample runtime (target_response changed_read fresh_title) in
       ignore fresh;
       let old = begin_reference_tree runtime 10L in
       let newer =
         changed runtime (window ~blocks:[ target_uuid ] ()) |> check_target_request runtime
       in
       ignore (deliver_sample runtime (target_response newer fresh_title));
       let stale = (deliver_sample runtime (reference_tree_response old "Rollback") |>finish_previews runtime ~children:[]) in
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
  ignore ((deliver_sample runtime (reference_tree_response initial "Old") |>finish_previews runtime ~children:[]));
  let changed_read =
    changed runtime (window ~blocks:[ target_uuid ] ()) |> check_target_request runtime
  in
  let failed =
    deliver_sample
      runtime
      (sample
         changed_read
         ((failed_sample (Read.Service_failed (("InvalidRequest")^": "^("temporary shared read failure"))))))
  in
  Alcotest.(check bool)
    "shared failure removes old source"
    true
    (List.mem (target_id, None) (reference_updates failed));
  let old = changed runtime (window ~blocks:[ target_uuid ] ()) |> check_target_request runtime in
  let newer =
    changed runtime (window ~blocks:[ target_uuid ] ()) |> check_target_request runtime
  in
  ignore (deliver_sample runtime (target_response newer "Fresh"));
  let failed =
    deliver_sample
      runtime
      (sample
         old
         ((failed_sample (Read.Service_failed (("InvalidRequest")^": "^("late failure"))))))
  in
  Alcotest.(check bool)
    "late failure cannot remove newer source"
    false
    (List.mem (target_id, None) (reference_updates failed));
  let retry =
    changed runtime (window ~blocks:[ target_uuid ] ()) |> check_target_request runtime
  in
  ignore (deliver_sample runtime (target_response retry "Recovered"))
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
  | Runtime.Capture_not_admitted{command;_} | Runtime.Capture_waiting{command;_} when kind=Capture_mutation ->
    Alcotest.(check string) "unadmitted mutation identity" mutation_id command.mutation_id;
    Alcotest.(check string) "unadmitted block identity" block_id command.block_id
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
  let runtime=Runtime.create ~localtime:Unix.gmtime () in
  set_calendar runtime;
  let creation_time=Journal_time.create ~instant_unix_ms:1_788_192_000_000L
    ~local_day:20260901 ~local_minute_of_day:0 |> Result.get_ok in
  let request=Runtime.submit runtime(Capture{calendar_generation=1L;command={
    mutation_id="a1000000-0000-4000-a000-0000000000c1";block_id=Graph.Uuid.to_string block_uuid;
    sibling_order="a";source="Retained source";task_state=Journal_model.No_status;
    creation_time;children=[];status_confirmation=false;status_intent_revision=0L}})
    |> fun output->only "atomic Capture root" output.requests in
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
    Production_runtime.receive_worker_read runtime ~request_id:request
             (Production_runtime.Read_failed{code=Logseq_db_worker.Error.Conflict;message="Conflict"})
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
           ; status_intent_revision = 0L
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
    ; status_intent_revision = 0L
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
    | Child_not_admitted {command;_} ->
      Alcotest.(check string) "unsent child" block_id command.block_id;
      Alcotest.(check string) "unsent child mutation" mutation_id command.mutation_id
    | _ -> Alcotest.fail "unsent child failure lost its draft identity"
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

module Copy = Journal_pure_copy
module Copy_worker = Journal_worker_coordination.Worker_api

type copy_query = Query : 'a Copy_worker.query -> copy_query

module Copy_issuer = struct
  let issuer, _, _, session = Coordination_test_fixture.fixture
    ~graph:(Worker_producer.W.graph_id Worker_producer.session)
    ~limits:{Coordination_test_fixture.limits with
      response_budget_bytes=Worker_pure_data.maximum_response_bytes} 2840L
  module I = (val issuer : Worker_effect_authority.ISSUER)
  let serial = ref 0
  let next_id () =
    incr serial;
    uuid(Printf.sprintf "a1000000-0000-4000-9000-%012x" !serial)
  let request query =
    let budget=Copy_worker.read_budget session ~maximum_items:Worker_pure_data.maximum_page_size
      ~maximum_bytes:Worker_pure_data.maximum_response_bytes |> Result.get_ok in
    Copy_worker.Query(budget,query)
  let wire query = I.request session ~request_id:(Copy_worker.request_id(next_id()))
    (request query) |> Result.get_ok
  let decode (type a) (query:a Copy_worker.query) outcome : (a, string) result =
    let id=next_id() in
    let request=request query in
    match I.request session ~request_id:(Copy_worker.request_id id) request with
    | Error _ -> Error "Read was not admitted"
    | Ok source ->
      match I.reply session ~request_id:(Copy_worker.request_id id) request (outcome source) with
      | Ok (Copy_worker.Answered(Ok value)) -> Ok value
      | Error _ | Ok _ -> Error "Worker rejected the read result"
end

let copy_read = function
  | [ Copy.Read (ticket, query, _) ] -> ticket, Query query
  | _ -> Alcotest.fail "Copy must issue one bounded subtree read"
;;

let copy_reply state effects packet =
  match effects with
  | [Copy.Read(ticket,query,outcome)] ->
    Copy.step state (match Copy_issuer.decode query packet with
      | Ok value -> Copy.Completed(ticket,outcome value)
      | Error message -> Copy.Read_failed(ticket,message))
  | effects -> Alcotest.failf "Copy must await one typed read (%s)"
    (String.concat "; " (List.map (function
      | Copy.Failed message -> "failed: " ^ message
      | Copied _ -> "copied" | Read _ -> "read") effects))
;;

let copy_info_result () =
  Copy_issuer.decode Copy_worker.Graph_info (graph_info_outcome ~journal_title_format:None)
  |> Result.get_ok |> fun info -> Copy.Info_result info
;;

let copy_start root =
  let state, effects = Copy.step Copy.initial (Copy.Start root) in
  Alcotest.(check bool)
    "Copy begins with graph version"
    true
    (match snd(copy_read effects) with Query Copy_worker.Graph_info -> true | _ -> false);
  let state, effects =
    copy_reply state effects (graph_info_outcome ~journal_title_format:None)
  in
  Alcotest.(check bool)
    "Copy reads selected root only"
    true
    (match snd (copy_read effects) with
     | Query (Copy_worker.Outline_block { uuid; _ }) -> Graph.Uuid.equal uuid root
     | _ -> false);
  state, effects
;;

let copy_children ?cursor ?(revision = "children-1") parent items =
  (children_sample ~parent:(parent) ~scope_revision:(revision) ~items:(items) ~next:(cursor))
;;

let copy_root state effects title =
  copy_reply
    state
    effects
    ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_present_block
          { value = { record with block = { block with title } }; revision = "root-1" })) in match query with |Read.Outline_block _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch")))
;;

let copy_child id parent title : Worker_pure_data.child_member =
  { value = { record with block = { block with uuid = id; parent; title } }
  ; revision = "child-1"
  }
;;

let copy_parent effects expected =
  match snd (copy_read effects) with
  | Query (Copy_worker.Child_members { parent; _ }) ->
    Alcotest.(check bool)
      "selected subtree parent"
      true
      (Graph.Uuid.equal parent expected)
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
     | Query (Copy_worker.Child_members _ as query) ->
       (match Copy_issuer.wire query with
        | Logseq_db_worker_lui.Logseq_db_worker_lui_service.Coordination_query
            {read=Read.Read_query(_,Read.Child_members {after=Some value;_});_} -> Read.For_worker.continuation_cursor value=cursor
        | _ -> false)
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
    (match snd(copy_read effects) with Query Copy_worker.Graph_info -> true | _ -> false);
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
      (Copy.Completed (ticket, copy_info_result ()))
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
      (Copy.Completed (ticket, copy_info_result ()))
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
    ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_missing_block {uuid=block_uuid;revision="missing"})) in match query with |Read.Outline_block _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"))) in
  copy_expect_failure missing_state missing_effects
    ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_missing_page {uuid=block_uuid;revision="missing"})) in match query with |Read.Page _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch")));
  let state, effects = copy_root state effects "Root" in
  copy_expect_failure
    state
    effects
    ((failed_sample (Read.Stale_read ("Changed"))));
  let ticket, _ = copy_read effects in
  let _, failed = Copy.step state (Copy.Read_failed (ticket, "Cancelled by Worker")) in
  Alcotest.(check bool)
    "worker failure never copies"
    true
    (match failed with
     | [ Copy.Failed _ ] -> true
     | _ -> false);
  let state, effects = copy_reply state effects (copy_children block_uuid []) in
  let changed=graph_info_sample ~projection_revision:"projection-2" ~journal_title_format:None in
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
    ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_present_block
          { value =
              { record with
                block = { block with title = String.make ((256 * 1024) + 1) 'x' }
              }
          ; revision = "root-1"
          })) in match query with |Read.Outline_block _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch")))
;;

let test_copy_result_fits_serialized_clipboard () =
  let maximum = 256 * 1024 in
  let check source effects =
    match Journal_platform.copy_text_request ~text:source with
    | Ok _ ->
      Alcotest.(check bool) "encodable outline is copied exactly" true
        (effects = [ Copy.Copied source ])
    | Error _ ->
      Alcotest.(check bool) "unencodable outline never produces Copied" true
        (match effects with [ Copy.Failed message ] -> message <> "" | _ -> false)
  in
  (* Each result stays inside the real read budget. The large clipboard value
     comes from an outline gathered across pages, as it does in production. *)
  let complete length character =
    let count=40 in
    let width=if character='\n' then 5 else 1 in
    let payload=length-4-(5*count) in
    let prefix="Root" ^ String.make (payload mod width) 'x' in
    let payload=payload/width in
    let children=List.init count (fun index ->
      let size=payload/count+(if index<payload mod count then 1 else 0) in
      copy_child (uuid(Printf.sprintf "a1000000-0000-4000-9100-%012x" index))
        block_uuid (String.make size character)) in
    let source=prefix ^ String.concat "" (List.map (fun (child:Worker_pure_data.child_member) ->
      "\n  - " ^ String.concat "\n    "
        (String.split_on_char '\n' child.Worker_pure_data.value.block.title)) children) in
    let state,effects=copy_start block_uuid in
    let state,effects=copy_root state effects prefix in
    let rec gather state effects page = function
      | [] -> state,effects
      | child::rest ->
        let cursor=if rest=[] then None else Some(Graph.Cursor.of_string
          (Printf.sprintf "copy-sized-page-%d" page) |> Result.get_ok) in
        let state,effects=copy_reply state effects
          (copy_children ?cursor block_uuid [child]) in
        gather state effects (page+1) rest in
    let state,effects=gather state effects 0 children in
    let state,effects=List.fold_left (fun (state,effects) (child:Worker_pure_data.child_member) ->
      copy_reply state effects (copy_children child.Worker_pure_data.value.block.uuid []))
      (state,effects) children in
    let effects=match effects with
      | [Copy.Read _] -> snd(copy_reply state effects
          (graph_info_outcome ~journal_title_format:None))
      | effects -> effects in
    source,effects
  in
  List.iter (fun (length,character) ->
    let source,effects=complete length character in check source effects)
    [maximum,'x'; maximum-11,'x'; maximum-10,'x'; maximum/2,'x';
     maximum/2,'"'; maximum/2,'\\'; maximum/2,'\n'; maximum/6,'\001';
     maximum/2+1,'\n'; maximum/2+2,'\n']
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
    deliver_sample
      runtime
      (sample
         request
         ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_present_block { value = record; revision = "root-1" })) in match query with |Read.Outline_block _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"))))
    |> fun output -> only "ordinary detail page" output.requests
  in
  let request =
    deliver_sample
      runtime
      (sample
         request
         ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_present_page { page = ordinary_page; revision = "page-1" })) in match query with |Read.Page _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"))))
    |> fun output -> only "ordinary detail children" output.requests
  in
  let child =
    { record with
      block = { block with uuid = unrelated_uuid; title = "Child"; parent = block_uuid }
    }
  in
  ignore
    (deliver_sample
       runtime
       (sample
          request
          ((children_sample ~parent:(block_uuid) ~scope_revision:("children-1") ~items:([ { value = child; revision = "child-1" } ]) ~next:(None)))));
  ordinary_page, child
;;

let test_ordinary_detail_point_change child_changed =
  let runtime = Runtime.create () in
  let _, child = seed_ordinary_detail runtime in
  let value = if child_changed then child else record in
  let output = changed runtime (window ~blocks:[ value.block.uuid ] ()) in
  let request = only "ordinary detail changed identity" (hydration_requests runtime output) in
  (match Runtime.worker_read runtime request with
   | Some(Runtime.Read{query=W.Outline_block {uuid=block;_};_}) ->
     Alcotest.(check bool)
       "only changed identity"
       true
       (Graph.Uuid.equal block value.block.uuid)
   | _ -> Alcotest.fail "ordinary detail did not point-read its changed identity");
  let output =
    deliver_sample
      runtime
      (sample
         request
         ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_present_block
               { value =
                   { value with block = { value.block with title = "Updated detail" } }
               ; revision = "detail-2"
               })) in match query with |Read.Outline_block _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"))))
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
         ~scopes:[ Worker_pure_data.V2_children_interest block_uuid ]
         ())
  in
  let point =
    List.find
      (fun (request : Graph.Uuid.t) ->
         match Runtime.worker_read runtime request with
         | Some(Runtime.Read{query=W.Outline_block _;_}) -> true
         | _ -> false)
      (hydration_requests runtime output)
  in
  let children =
    List.find
      (fun (request : Graph.Uuid.t) ->
         match Runtime.worker_read runtime request with
         | Some(Runtime.Read{query=W.Child_members _;_}) -> true
         | _ -> false)
      (hydration_requests runtime output)
  in
  ignore
    (deliver_sample
       runtime
       (sample
          point
          ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_present_block
                { value = { record with block = { block with title = "Fresh root" }; tag_titles = [ "Fresh tags" ] }
                ; revision = "root-2"
                })) in match query with |Read.Outline_block _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch")))));
  let output =
    deliver_sample
      runtime
      (sample
         children
         ((children_sample ~parent:(block_uuid) ~scope_revision:("children-2") ~items:([]) ~next:(None))))
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
    Runtime.reconcile_signal
      runtime
      ~request_generation:12L
      (Worker_pure_data.Resync_required { generation = "generation-2"
         ; reason = "overflow"
         })
  in
  Alcotest.(check bool)
    "resync must rehydrate ordinary detail root content"
    true
    (List.exists
       (fun (request : Graph.Uuid.t) ->
          match Runtime.worker_read runtime request with
          | Some(Runtime.Read{query=W.Outline_block {uuid=block;_};_}) -> Graph.Uuid.equal block block_uuid
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
    deliver_sample
      runtime
      (sample
         read
         ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok(F.favorites ~favorites_page:(Some favorites_page_uuid) ~generation:("generation-1") ~projection_revision:("revision-1") ~items:((if negative
                 then []
                 else
                   [ { membership_uuid
                     ; membership_order = "a"
                     ; membership_revision = "membership-1"
                     ; target =
                         Worker_pure_data.V2_favorite_block
                           { uuid = block_uuid
                           ; title = block.title
                           ; task_status = None
                           ; revision = "root-1"
                           }
                     }
                   ])) ~next:(Option.map(fun cursor->F.continuation ~owner:(F.read_budget_owner budget) ~budget ~key:(Read.query_key budget query) ~cursor)(None))) in match query with |Read.Favorites _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"))))
  in
  let visited = ref [] in
  let target_reads = ref 0 in
  let rec drain requests =
    match requests with
    | [] -> ()
    | (request : Graph.Uuid.t) :: rest ->
      let outcome =
        match Runtime.worker_read runtime request with
        | Some(Runtime.Read{query=W.Child_members {parent;_};_}) when Graph.Uuid.equal parent favorites_page_uuid
          ->
          (match Production_runtime.worker_read runtime request with
           | Some (Production_runtime.Read {query=Journal_worker_coordination.Worker_api.Child_members _;_}) -> ()
           | _ -> Alcotest.fail "favorite memberships bypassed typed coordinator");
          (children_sample ~parent:(parent) ~scope_revision:("favorites-memberships-1") ~items:([ { value =
                      { record with
                        block =
                          { block with uuid = membership_uuid; parent; page = parent }
                      }
                  ; revision = "membership-1"
                  }
                ]) ~next:(None))
        | Some(Runtime.Read{query=W.Outline_block {uuid=id;_};_}) ->
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
          (query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_present_block { value; revision = "dependency-1" })) in match query with |Read.Outline_block _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"))
        | Some(Runtime.Read{query=W.Page {uuid=id;_};_}) when Graph.Uuid.equal id page_uuid ->
          (query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_present_page { page; revision = "page-1" })) in match query with |Read.Page _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"))
        | _ -> Alcotest.fail "favorite dependency used an unbounded discovery request"
      in
      let output = deliver_sample runtime (sample request outcome) in
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
          (List.length (hydration_requests runtime output)))
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
    deliver_sample
      runtime
      (sample
         request
         ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok(F.change_batch ~change_owner:(F.read_budget_owner budget) ~generation:("generation-1") ~from_exclusive:(None) ~through:("revision-2") ~windows:([ window ~blocks:[ unrelated_uuid ] () ]) ~next:(None)) in match query with |Read.Changes _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"))))
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
    ; window ~scopes:[ Worker_pure_data.V2_children_interest favorites_page_uuid ] ()
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
       let read = only "bounded dependency recheck" (hydration_requests runtime out) in
       let out = deliver_sample runtime (sample read outcome) in
       Alcotest.(check bool)
         "changed target or eligibility invalidates favorites"
         true
         (invalidates_favorites out))
    [ ( window ~blocks:[ block_uuid ] ()
      , (query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_present_block
             { value =
                 { record with
                   block = { block with parent = ancestor_uuid; title = "Fresh favorite" }
                 }
             ; revision = "favorite-2"
             })) in match query with |Read.Outline_block _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch")) )
    ; ( window ~blocks:[ ancestor_uuid ] ()
      , (query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_missing_block { uuid = ancestor_uuid; revision = "missing-2" })) in match query with |Read.Outline_block _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch")) )
    ; ( window ~pages:[ page_uuid ] ()
      , (query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_present_page { page = { page with recycled = true }; revision = "page-2" })) in match query with |Read.Page _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"))
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
           [ Worker_pure_data.V2_children_interest page_uuid; Worker_pure_data.V2_page_tree_interest page_uuid ]
         ())
  in
  Alcotest.(check bool)
    "Capture sibling window preserves Favorites"
    false
    (invalidates_favorites output);
  List.iter
    (fun (request : Graph.Uuid.t) ->
       match Runtime.worker_read runtime request with
       | Some(Runtime.Read{query=W.Page {uuid=id;_};_}) when Graph.Uuid.equal id page_uuid ->
         let output =
           deliver_sample
             runtime
             (sample
                request
                ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_present_page { page; revision = "page-2" })) in match query with |Read.Page _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"))))
         in
         Alcotest.(check bool)
           "unchanged live ancestor preserves Favorites"
           false
           (invalidates_favorites output)
       | _ -> Alcotest.fail "sibling change escaped bounded ancestor point read")
    (hydration_requests runtime output)
;;

let test_favorite_ancestor_title_is_local () =
  let runtime = Runtime.create () in
  ignore (seed_favorite_dependencies runtime);
  let output = changed runtime (window ~blocks:[ ancestor_uuid ] ()) in
  Alcotest.(check bool)
    "ancestor window rechecks first"
    false
    (invalidates_favorites output);
  let read = only "ancestor point read" (hydration_requests runtime output) in
  let output =
    deliver_sample
      runtime
      (sample
         read
         ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_present_block
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
               })) in match query with |Read.Outline_block _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"))))
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
    deliver_sample
      runtime
      (sample
         read
         ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok(F.favorites ~favorites_page:(Some favorites_page_uuid) ~generation:("generation-1") ~projection_revision:("revision-1") ~items:([]) ~next:(Option.map(fun cursor->F.continuation ~owner:(F.read_budget_owner budget) ~budget ~key:(Read.query_key budget query) ~cursor)(None))) in match query with |Read.Favorites _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"))))
  in
  let rec drain batch requests =
    if batch > 20 then Alcotest.fail "Favorite dependencies exceeded 4096 without failure";
    let read = only "bounded membership page" requests in
    let items =
      List.init 200 (fun offset ->
        let uuid =
          uuid (Printf.sprintf "a2000000-0000-4000-8000-%012d" ((batch * 200) + offset))
        in
        Worker_pure_data.{ value =
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
      deliver_sample
        runtime
        (sample
           read
           ((children_sample ~parent:(favorites_page_uuid) ~scope_revision:("members-1") ~items:(items) ~next:(next_cursor))))
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

let test_changes_more_continues_after_ack () =
  let runtime=Runtime.create () in
  let first=pull runtime in
  let output=deliver_sample runtime(sample first((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok(F.change_batch ~change_owner:(F.read_budget_owner budget) ~generation:("generation-1") ~from_exclusive:(None) ~through:("w1") ~windows:([{(window ~blocks:[unrelated_uuid]()) with id="w1"}]) ~next:(Some "w1")) in match query with |Read.Changes _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch")))) in
  let ack=only "first page waits for ACK" output.requests in
  (match Runtime.worker_read runtime ack with Some(Runtime.Acknowledge _)->()|_->Alcotest.fail "More bypassed first page application ACK");
  let output=deliver_sample runtime(sample ack((ack_sample ("generation-1") ("w1")))) in
  let next=only "More schedules its next page after actual ACK" output.requests in
  (match Runtime.worker_read runtime next with Some(Runtime.Read{query=W.Changes{generation="generation-1";after=Some "w1"};_})->()
   | _->Alcotest.fail "More lost its actual acknowledged cursor");
  let output=deliver_sample runtime(sample next((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok(F.change_batch ~change_owner:(F.read_budget_owner budget) ~generation:("generation-1") ~from_exclusive:(Some "w1") ~through:("w2") ~windows:([{(window ~blocks:[unrelated_uuid]()) with id="w2"}]) ~next:(None)) in match query with |Read.Changes _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch")))) in
  let ack=only "last page ACK" output.requests in
  let output=deliver_sample runtime(sample ack((ack_sample ("generation-1") ("w2")))) in
  Alcotest.(check int) "no pull loop after Complete" 0(List.length output.requests)
;;

let test_projection_changes_are_owned () =
  let runtime = Runtime.create () in
  let output =
    Runtime.reconcile_signal
      runtime
      ~request_generation:11L
      (Worker_pure_data.Changes_available { generation = "generation-1"
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
    sample
      request
      ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok(F.change_batch ~change_owner:(F.read_budget_owner budget) ~generation:("generation-1") ~from_exclusive:(None) ~through:("revision-2") ~windows:([ change ]) ~next:(None)) in match query with |Read.Changes _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch")))
  in
  let output = deliver_sample runtime completion in
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
    (List.length (deliver_sample runtime completion).responses);
  let output =
    Runtime.reconcile_signal
      runtime
      ~request_generation:12L
      (Worker_pure_data.Resync_required { generation = "generation-2"
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

let journal_request_limit runtime request =
  match Runtime.worker_read runtime request with
  | Some(Runtime.Read{query=W.Timeline_read {query=W.Timeline.Dates _;_};maximum_items=limit;_}) -> limit
  | _ -> Alcotest.fail "expected journal listing"
;;

let test_feed_dates_use_owned_worker_query () =
  let runtime = Runtime.create () in
  let request = feed_window_request runtime ~days:3 ~slots:16 in
  (match Production_runtime.worker_read runtime request with
   | Some
       (Production_runtime.Read
          { query = Journal_worker_coordination.Worker_api.Timeline_read {query=Journal_worker_coordination.Worker_api.Timeline.Dates _;_}
          ; maximum_items = 3
          ; _
          }) -> ()
   | _ -> Alcotest.fail "feed dates bypass typed coordinator");
  ignore (Production_runtime.abandon runtime request);
  match Production_runtime.worker_read runtime request with
  | None -> ()
  | _ -> Alcotest.fail "retired feed dates fell back to legacy transport"
;;

let test_feed_publication_waits_for_same_snapshot_receipts () =
  let runtime = Runtime.create () in
  set_calendar runtime;
  let dates = load_feed runtime in
  let roots = Worker_producer.deliver runtime dates
      (journal_sample ~items:[Worker_pure_data.{page;journal_day=20260901;revision="page"}]
         ~next:None)
    |> fun output -> only "root packet request" output.requests in
  let preview = Worker_producer.deliver runtime roots
      (tree_sample ~items:[Worker_pure_data.{value=record;revision="root";depth=0;parent=page_uuid}]
         ~next:None)
    |> fun output -> only "preview packet request" output.requests in
  let pending = Worker_producer.deliver runtime preview
      (children_sample ~parent:block_uuid ~scope_revision:"preview" ~items:[] ~next:None) in
  Alcotest.(check bool) "unverified branches cannot publish a complete feed" false
    (List.exists (fun (response:Runtime.response) -> match response.payload with
      | Feed_loaded {complete=true;_} -> true | _ -> false) pending.responses);
  let request = only "one same-snapshot receipt verification" pending.requests in
  (match Runtime.worker_read runtime request with
   | Some (Runtime.Read {query=W.Timeline_check receipts;_}) ->
     Alcotest.(check bool) "both exhausted root and preview receipts are checked" true
       (Rrbvec.length receipts >= 2)
   | _ -> Alcotest.fail "combined feed was not checked through the typed Worker boundary");
  let complete = Worker_producer.deliver runtime request check_sample in
  Alcotest.(check int) "verified branches publish exactly once" 1
    (List.length (List.filter (fun (response:Runtime.response) -> match response.payload with
      | Feed_loaded {complete=true;_} -> true | _ -> false) complete.responses));
  let replay = Worker_producer.deliver runtime request check_sample in
  Alcotest.(check int) "replayed verification cannot publish twice" 0
    (List.length replay.responses)
;;

let pending_feed_check runtime ~empty =
  set_calendar runtime;
  let dates = load_feed runtime in
  let roots = Worker_producer.deliver runtime dates
      (journal_sample ~items:[Worker_pure_data.{page;journal_day=20260901;revision="page"}]
         ~next:None)
    |> fun output -> only "roots before validation" output.requests in
  let output = Worker_producer.deliver runtime roots
      (tree_sample ~items:(if empty then [] else
         [Worker_pure_data.{value=record;revision="root";depth=0;parent=page_uuid}])
         ~next:None) in
  let output = if empty then output else
      let preview = only "preview before validation" output.requests in
      Worker_producer.deliver runtime preview
        (children_sample ~parent:block_uuid ~scope_revision:"preview" ~items:[] ~next:None) in
  Alcotest.(check int) "nothing publishes before verification" 0 (List.length output.responses);
  only "combined verification" output.requests
;;

let test_empty_end_receipts_survive_resync () =
  let runtime = Runtime.create () in
  let request = pending_feed_check runtime ~empty:true in
  (match Runtime.worker_read runtime request with
   | Some (Runtime.Read {query=W.Timeline_check receipts;_}) ->
     Alcotest.(check int) "empty End roots and exhausted dates retained" 2 (Rrbvec.length receipts)
   | _ -> Alcotest.fail "empty feed bypassed validation");
  ignore (Worker_producer.deliver runtime request check_sample);
  let output = Runtime.reconcile_signal runtime ~request_generation:12L
      (Worker_pure_data.Resync_required {generation="generation-1";reason="gap"}) in
  Alcotest.(check bool) "resync checks retained empty scopes" true
    (List.exists (fun request -> match Runtime.worker_read runtime request with
       | Some (Runtime.Read {query=W.Timeline_check receipts;_}) -> Rrbvec.length receipts >= 2
       | _ -> false) output.requests)
;;

let test_stale_assembly_discards_prefix () =
  let runtime = Runtime.create () in
  let request = pending_feed_check runtime ~empty:false in
  let key = "roots:" ^ Graph.Uuid.to_string page_uuid in
  Hashtbl.replace fixture_versions key (1 + Option.value ~default:0 (Hashtbl.find_opt fixture_versions key));
  let output = Worker_producer.deliver runtime request check_sample in
  Alcotest.(check int) "mixed snapshots cannot publish" 0 (List.length output.responses);
  Alcotest.(check bool) "stale assembly restarts roots from beginning" true
    (List.exists (fun request -> match Runtime.worker_read runtime request with
      | Some (Runtime.Read {query=W.Timeline_read {query=W.Timeline.Roots _;after=None};_}) -> true
      | _ -> false) output.requests)
;;

let test_verification_reply_is_fenced terminal =
  let runtime = Runtime.create () in
  let request = pending_feed_check runtime ~empty:false in
  (match terminal with
   | `Cancel -> Runtime.abandon runtime request
   | `Refresh -> ignore (load_feed runtime)
   | `Reset -> Runtime.reset runtime);
  let output = Worker_producer.deliver runtime request check_sample in
  Alcotest.(check int) "retired verification publishes nothing" 0 (List.length output.responses);
  Alcotest.(check int) "retired verification schedules nothing" 0 (List.length output.requests)
;;

let test_timeline_proof_failure_is_explicit () =
  let runtime = Runtime.create () in
  set_calendar runtime;
  let request = load_feed runtime in
  let output = Worker_producer.deliver runtime request
      (query_sample (fun (Read.Read_query (budget,query)) -> match query with
        | Read.Timeline_read _ -> Read.For_worker.answer budget query
            (Ok (Error (Read.Timeline.Limit_exceeded "Timeline source exceeded its structural bound")))
        | _ -> failwith "Expected Timeline paging")) in
  Alcotest.(check int) "proof failures cannot spin" 0 (List.length output.requests);
  match (only "proof failure settles original request" output.responses).payload with
  | Feed_failed {request_generation=7L;failure=Projection_failure message} ->
    Alcotest.(check bool) "concrete proof cause survives" true
      (String.ends_with ~suffix:"Timeline source exceeded its structural bound" message)
  | _ -> Alcotest.fail "proof failure lost its typed read owner"
;;

let test_timeline_read_failed_preserves_worker_error () =
  let runtime = Runtime.create () in
  set_calendar runtime;
  let request = load_feed runtime in
  let error = Logseq_db_worker.Error.create ~code:Corrupt_storage
      ~message:"Timeline date storage failure" ~details:[] |> Result.get_ok in
  let output = Worker_producer.deliver runtime request
      (query_sample (fun (Read.Read_query (budget,query)) -> match query with
        | Read.Timeline_read _ -> Read.For_worker.answer budget query
            (Ok (Error (Read.Timeline.Read_failed (Read.Db_error error))))
        | _ -> failwith "Expected Timeline paging")) in
  Alcotest.(check int) "ordinary read errors do not invalidate or retry" 0 (List.length output.requests);
  match (only "concrete read error" output.responses).payload with
  | Feed_failed {request_generation=7L;failure=Worker_failure failure} ->
    Alcotest.(check string) "worker code retained" (Logseq_db_worker.Error.code_string Corrupt_storage)
      (Logseq_db_worker.Error.code_string (Logseq_db_worker.Error.code failure.error));
    Alcotest.(check string) "worker message retained" "Timeline date storage failure"
      (Logseq_db_worker.Error.message failure.error)
  | _ -> Alcotest.fail "paging read failure was flattened into projection text"
;;

let test_changefeed_fences_inflight_assembly_check () =
  let runtime = Runtime.create () in
  let old = pending_feed_check runtime ~empty:false in
  (* A parallel retained-root reconciliation owns the current page epoch even
     before the first feed assembly has become visible. *)
  let changed_output = changed runtime
      (window ~scopes:[Worker_pure_data.V2_page_tree_interest page_uuid] ()) in
  Alcotest.(check bool) "changefeed owns a replacement root read" true
    (List.exists (fun request -> match Runtime.worker_read runtime request with
      | Some(Runtime.Read{query=W.Timeline_read {query=W.Timeline.Roots _;after=None};_}) -> true
      | _ -> false) changed_output.requests);
  let late = Worker_producer.deliver runtime old check_sample in
  Alcotest.(check int) "superseded check cannot publish stale assembly" 0 (List.length late.responses);
  Alcotest.(check bool) "superseded startup assembly preserves its demand" true (late.requests <> [])
;;

let test_timeline_owner_change_revokes_pending_reads () =
  let runtime = Runtime.create () in
  let old = pending_feed_check runtime ~empty:false in
  let fresh = load_feed runtime in
  let revoked = Worker_producer.deliver runtime fresh
      (query_sample (fun (Read.Read_query (budget,query)) -> match query with
        | Read.Timeline_read _ -> Read.For_worker.answer budget query
            (Ok (Error (Read.Timeline.Invalidated Owner_changed)))
        | _ -> failwith "Expected Timeline paging")) in
  Alcotest.(check int) "owner revocation cannot retry" 0 (List.length revoked.requests);
  let late = Worker_producer.deliver runtime old check_sample in
  Alcotest.(check int) "revoked owner cannot install old receipts" 0 (List.length late.responses);
  Alcotest.(check int) "revoked owner cannot schedule old demand" 0 (List.length late.requests)
;;

let test_receipt_check_preserves_worker_error () =
  let runtime = Runtime.create () in
  let request = pending_feed_check runtime ~empty:false in
  let error = Logseq_db_worker.Error.create ~code:Corrupt_storage
      ~message:"Timeline proof storage failure" ~details:[] |> Result.get_ok in
  let output = Worker_producer.deliver runtime request
      (query_sample (fun (Read.Read_query (budget,query)) -> match query with
        | Read.Timeline_check receipts -> Read.For_worker.answer budget query
            (Ok (Read.For_worker.timeline_check
              (Rrbvec.map (fun _ -> Error (Read.Timeline.Read_failed (Read.Db_error error))) receipts)))
        | _ -> failwith "Expected Timeline checks")) in
  Alcotest.(check int) "proof read errors never spin" 0 (List.length output.requests);
  match (only "concrete proof read error" output.responses).payload with
  | Feed_failed {failure=Worker_failure failure;_} ->
    Alcotest.(check string) "proof worker code retained"
      (Logseq_db_worker.Error.code_string Corrupt_storage)
      (Logseq_db_worker.Error.code_string (Logseq_db_worker.Error.code failure.error))
  | _ -> Alcotest.fail "receipt failure was flattened into projection text"
;;

let test_receipt_owner_change_dominates_read_failure () =
  let runtime = Runtime.create () in
  let request = pending_feed_check runtime ~empty:false in
  let output = Worker_producer.deliver runtime request
      (query_sample (fun (Read.Read_query (budget,query)) -> match query with
        | Read.Timeline_check receipts ->
          let first = ref true in
          let results = Rrbvec.map (fun _ ->
            if !first then (first := false;
              Error (Read.Timeline.Read_failed (Read.Service_failed "Concurrent proof read error")))
            else Error (Read.Timeline.Invalidated Owner_changed)) receipts in
          Read.For_worker.answer budget query (Ok (Read.For_worker.timeline_check results))
        | _ -> failwith "Expected Timeline checks")) in
  Alcotest.(check int) "owner revocation cannot retry old proofs" 0 (List.length output.requests);
  match (only "owner revocation takes precedence" output.responses).payload with
  | Feed_failed {failure=Projection_failure message;_} ->
    Alcotest.(check string) "owner revocation is not hidden by a read error"
      (W.Timeline.error_message (Invalidated Owner_changed)) message
  | _ -> Alcotest.fail "owner revocation was hidden by another receipt failure"
;;

let test_private_children_without_owner_are_not_legacy () =
  let runtime = Runtime.create () in
  let request=uuid "f0000000-0000-4000-8000-000000000100"
  in
  match Production_runtime.worker_read runtime request with
  | None -> ()
  | _ -> Alcotest.fail "unowned child query fell back to legacy transport"
;;

let test_feed_dates_reject_invalid_local_boundary () =
  List.iter
    (fun before_day ->
       let runtime = Runtime.create () in
       let output =
         Runtime.submit
           runtime
           (Journal_graph_request.Load_feed
              { cursor = Some { before_day = Some before_day; skipped_day = None }
              ; root_limit = 1
              ; day_limit = 3
              ; request_generation = 321L
              })
       in
       Alcotest.(check int)
         "invalid range cannot dispatch"
         0
         (List.length output.requests);
       match (only "invalid range settles" output.responses).payload with
       | Feed_failed { request_generation = 321L; _ } -> ()
       | _ -> Alcotest.fail "invalid local date lost owner")
    [ 20260230; 20261301; 0; 100000101 ]
;;

let test_feed_date_budget_failure_restarts_bound_cursor () =
  let runtime = Runtime.create () in
  set_calendar ~clock:1_788_307_200. runtime;
  let first = feed_window_request runtime ~days:3 ~slots:16 in
  let item : Worker_pure_data.journal_item =
    { page; journal_day = 20260901; revision = "page-1" }
  in
  let more = Graph.Cursor.of_string "date-budget-after-one" |> Result.get_ok in
  let root =
    deliver_sample
      runtime
      (sample first ((journal_sample ~items:(([ item ] : Worker_pure_data.journal_item list)) ~next:(Some more))))
    |> fun o -> only "date roots" o.requests
  in
  let next =
    deliver_sample
      runtime
      (sample
         root
         ((tree_sample ~items:(([] : Worker_pure_data.tree_member list)) ~next:(None))))
    |> fun o -> only "date continuation" o.requests
  in
  let retry =
    deliver_sample
      runtime
      (sample next ((failed_sample (Read.Db_error(Logseq_db_worker.Error.create ~code:Response_too_large ~message:("oversize") ~details:[]|>Result.get_ok)))))
    |> fun o -> only "smaller date restart" o.requests
  in
  match Runtime.worker_read runtime retry with
  | Some(Runtime.Read{query=W.Timeline_read {query=W.Timeline.Dates {through_day;_};after=None};maximum_items=1;_}) when W.journal_day 20260901=Ok through_day -> ()
  | _ ->
    Alcotest.fail
      "changed budget reused a sealed cursor or lost inclusive recovery boundary"
;;

let test_typed_date_budget_failure_preserves_classification () =
  let runtime = Runtime.create () in
  let original = feed_window_request runtime ~days:3 ~slots:16 in
  let module F = Worker_producer in
  match Production_runtime.worker_read runtime original with
  | Some (Production_runtime.Read read) ->
    let operation = F.W.Query (F.budget read.maximum_items, read.query) in
    let source=F.I.request F.session ~request_id:(F.W.request_id original)operation |> Result.get_ok in
    let failure =
      sample original ((failed_sample (Read.Db_error(Logseq_db_worker.Error.create ~code:Response_too_large ~message:("oversize") ~details:[]|>Result.get_ok))))
    in
    (match
       F.I.reply
         F.session
         ~request_id:(F.W.request_id original)
         operation
         ((snd failure) source)
     with
     | Ok (F.W.Answered (Error (F.W.Db_error error))) ->
       Alcotest.(check bool) "recoverable database budget code" true
         (Logseq_db_worker.Error.code error=Logseq_db_worker.Error.Response_too_large);
       Alcotest.(check string) "original database budget message" "oversize"
         (Logseq_db_worker.Error.message error)
     | _ -> Alcotest.fail "typed sample discarded recoverable budget failure")
  | _ -> Alcotest.fail "missing typed date request"
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
  let item n : Worker_pure_data.journal_item =
    let id = uuid (Printf.sprintf "a3000000-0000-4000-8000-%012d" n) in
    { page = { page with uuid = id; properties = [ property ] }
    ; journal_day = 20260901
    ; revision = "page-window-revision"
    }
  in
  let encoded count =
    sample
      request
      ((journal_sample ~items:((List.init count item : Worker_pure_data.journal_item list)) ~next:(None)))
    |> sample_bytes runtime
  in
  Alcotest.(check bool)
    "full 200-item metadata batch exceeds real byte budget"
    true
    (encoded Worker_pure_data.maximum_page_size > Worker_pure_data.maximum_response_bytes);
  Alcotest.(check bool)
    "requested feed metadata fits unchanged byte budget"
    true
    (encoded (journal_request_limit runtime request) <= Worker_pure_data.maximum_response_bytes);
  Alcotest.(check int)
    "read only the seven requested days"
    7
    (journal_request_limit runtime request)
;;

let test_feed_continuation_reads_only_missing_days () =
  let runtime = Runtime.create () in
  set_calendar ~clock:1_788_278_400. runtime;
  let first = feed_window_request runtime ~days:3 ~slots:16 in
  let cursor = Graph.Cursor.of_string "journal-after-one" |> Result.get_ok in
  let valid : Worker_pure_data.journal_item = {page;journal_day=20260901;revision="journal-first"} in
  let output = deliver_sample runtime (sample first ((journal_sample ~items:(([valid;{valid with page={page with recycled=true}}] : Worker_pure_data.journal_item list)) ~next:(Some cursor)))) in
  let tree=only "resolve available date before fetching more metadata" output.requests in
  let output=deliver_sample runtime (sample tree ((tree_sample ~items:(([] : Worker_pure_data.tree_member list)) ~next:(None)))) in
  let next=only "continue journal cursor after empty date" output.requests in
  (match Worker_producer.transport runtime next with
   |Ok(Worker_producer.S.Coordination_query{read=Read.Read_query(budget,(Read.Timeline_read {query=Read.Timeline.Dates _;_} as query));_})->
      let actual=fixture_cursor budget query |> Option.get in
      let limit=Read.For_worker.read_budget_maximum_items budget in
     Alcotest.(check int) "metadata packet independent of root demand" 3 limit;
     Alcotest.(check bool) "opaque date cursor retained" true (actual=cursor)
   | _ -> Alcotest.fail "lost date continuation");
  let completed=deliver_sample runtime (sample next ((journal_sample ~items:(([] : Worker_pure_data.journal_item list)) ~next:(None)))) in
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
         (journal_request_limit runtime request))
    [ 1, 2, 1; 10, 6, 10; 500, 1000, Worker_pure_data.maximum_page_size ];
  let runtime = Runtime.create () in
  let request = feed_window_request runtime ~days:1 ~slots:2 in
  let oversized_page =
    { page with
      properties =
        List.init 5 (fun n ->
          { Graph.ident = Printf.sprintf "fixture/large-property-%d" n
          ; uuid = uuid (Printf.sprintf "a4000000-0000-4000-8000-%012d" n)
          ; title = String.make Worker_pure_data.maximum_title_bytes 'x'
          ; schema =
              { property_type = String; cardinality = One; hidden = false; public = true }
          ; values = []
          ; values_truncated = false
          })
    }
  in
  let oversized =
    sample
      request
      ((journal_sample ~items:(([ { page = oversized_page
               ; journal_day = 20260901
               ; revision = "large-singleton"
               }
             ] : Worker_pure_data.journal_item list)) ~next:(None)))
  in
  Alcotest.(check bool)
    "one complete oversized item cannot fit"
    true
    (sample_bytes runtime oversized > Worker_pure_data.maximum_response_bytes);
  let failed =
    deliver_sample
      runtime
      (sample
         request
         ((failed_sample (Read.Db_error(Logseq_db_worker.Error.create ~code:Response_too_large ~message:("The encoded read sample exceeded its byte limit.") ~details:[]|>Result.get_ok)))))
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
  let root : Worker_pure_data.tree_member =
    { value = record; revision = "root-1"; depth = 0; parent = page_uuid }
  in
  let items =
    root
    :: List.rev_map
         (fun (child : Worker_pure_data.child_member) ->
            Worker_pure_data.{ value = child.value
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
    deliver_sample
      runtime
      (sample
         journals
         ((journal_sample ~items:(([ { page; journal_day = 20260901; revision = "page-1" } ] : Worker_pure_data.journal_item list)) ~next:(None))))
    |> fun o -> only "preview feed tree" o.requests
  in
  let cursor = Graph.Cursor.of_string "preview-next-page" |> Result.get_ok in
  let feed = (deliver_sample runtime (tree_page tree (List.filter(fun (m:Worker_pure_data.tree_member)->m.depth=0)items) (Some cursor))
    |>finish_previews runtime ~children:(List.filter_map(fun (m:Worker_pure_data.tree_member)->if m.depth=1 then Some Worker_pure_data.{value=m.value;revision=m.revision}else None)items)) in
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
  (match Worker_producer.transport runtime day_read with
   |Ok(Worker_producer.S.Coordination_query{read=Read.Read_query(budget,(Read.Timeline_read {query=Read.Timeline.Roots _;_} as query));_})->
      let actual=fixture_cursor budget query |> Option.get in
     Alcotest.(check bool) "paging cursor unchanged" true (actual = cursor)
   | _ -> Alcotest.fail "preview cap changed day paging");
  let day_result = (deliver_sample runtime (tree_page day_read (List.filter(fun (m:Worker_pure_data.tree_member)->m.depth=0)items) None)
    |>finish_previews runtime ~children:(List.filter_map(fun (m:Worker_pure_data.tree_member)->if m.depth=1 then Some Worker_pure_data.{value=m.value;revision=m.revision}else None)items)) in
  (match (only "preview day result" day_result.responses).payload with
   | Feed_loaded {feed;complete=true;_} -> check_preview 3 (only "day entry" (List.hd feed.days).entries)
   | _ -> Alcotest.fail "preview day result lost owner");
  let changed_output =
    changed runtime (window ~scopes:[ Worker_pure_data.V2_page_tree_interest page_uuid ] ())
  in
  let refresh = only "preview remote structure" (hydration_requests runtime changed_output) in
  let remote = (deliver_sample runtime (tree_page refresh (List.filter(fun (m:Worker_pure_data.tree_member)->m.depth=0)items) None)
    |>finish_previews runtime ~children:(List.filter_map(fun (m:Worker_pure_data.tree_member)->if m.depth=1 then Some Worker_pure_data.{value=m.value;revision=m.revision}else None)items)) in
  (match (only "preview remote result" remote.responses).payload with
   | Page_tree_reconciled { value; _ } ->
     check_preview 3 (only "remote entry" value.entries)
   | _ -> Alcotest.fail "preview remote result lost owner");
;;

let test_bounded_preview_target_pages kind count () =
  let runtime, page, first = target_refresh kind in
  let canonical =
    { record with block = { block with page = page.uuid; parent = page.uuid } }
  in
  let lookup =
    Worker_pure_data.V2_present_block { value = canonical; revision = "canonical-2" }
  in
  let children = summary_children ~page:page.uuid count in
  let rec complete request cursor batch = function
    | [] ->
      Target_fixture.summary request page lookup [] None "projection-2"
    | remaining ->
      check_target_summary request cursor;
      let items = List.take Worker_pure_data.default_page_size remaining in
      let tail = List.drop Worker_pure_data.default_page_size remaining in
      let next =
        if tail = []
        then None
        else
          Some
            (Graph.Cursor.of_string (Printf.sprintf "preview-target-%d" batch)
             |> Result.get_ok)
      in
      let output =
        Target_fixture.summary request page lookup items next "projection-2"
      in
      (match next with
       | None -> output
       | Some _ ->
         Alcotest.(check int)
           "all raw pages complete before confirmation"
           0
           (List.length output.responses);
         complete
           (Target_fixture.next runtime request "unchanged target child continuation" output)
           next
           (batch + 1)
           tail)
  in
  let output = complete first None 0 children in
  let entry =
    List.find_map
      (fun r ->
         match Target_fixture.payload r with
         | Block_captured { timeline_entry_update = Some entry; _ }
         | Block_updated { timeline_entry_update = Some entry; _ }
         | Update_conflict {timeline_entry_update=Some entry;_}
         | Delete_conflict {timeline_entry_update=Some entry;_} -> Some entry
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
    |> List.mapi (fun index (child : Worker_pure_data.child_member) ->
      if index = 0
      then
        { child with
          Worker_pure_data.value =
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
    deliver_sample
      runtime
      (sample
         journals
         ((journal_sample ~items:(([ { page; journal_day = 20260901; revision = "page-1" } ] : Worker_pure_data.journal_item list)) ~next:(None))))
    |> fun output -> only "hidden parent tree" output.requests
  in
  let items =
    { Worker_pure_data.value = root; revision = "root-1"; depth = 0; parent = page_uuid }
    :: List.map
         (fun (child : Worker_pure_data.child_member) ->
            Worker_pure_data.{ value = child.value
              ; revision = child.revision
              ; depth = 1
              ; parent = block_uuid
              })
         children
  in
  let output = (deliver_sample runtime (tree_page tree (List.filter(fun (m:Worker_pure_data.tree_member)->m.depth=0)items) None)
    |>finish_previews runtime ~children:(List.filter_map(fun (m:Worker_pure_data.tree_member)->if m.depth=1 then Some Worker_pure_data.{value=m.value;revision=m.revision}else None)items)) in
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
    deliver_sample
      runtime
      (sample
         root_read
         ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_present_block { value = root; revision = "root-1" })) in match query with |Read.Outline_block _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"))))
    |> fun o -> only "complete Detail children" o.requests
  in
  let output =
    deliver_sample runtime (sample child_read (copy_children block_uuid children))
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
      (fun (state, effects) (child : Worker_pure_data.child_member) ->
         copy_parent effects child.Worker_pure_data.value.block.uuid;
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
                   (fun (c : Worker_pure_data.child_member) -> "\n  - " ^ c.value.block.title)
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
      { Worker_pure_data.value =
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
         { Worker_pure_data.value = root; revision = "root-1"; depth = 0; parent = page.uuid }
         :: List.map
              (fun (child : Worker_pure_data.child_member) ->
                 Worker_pure_data.{ value = child.value
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
         if visible then Some (Graph.Uuid.to_string r.Worker_pure_data.block.uuid) else None)
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
    deliver_sample
      runtime
      (sample
         journals
         ((journal_sample ~items:(([ { page; journal_day = 20260901; revision = "page-1" } ] : Worker_pure_data.journal_item list)) ~next:(None))))
    |> fun o -> only "visibility tree" o.requests
  in
  let cursor = Graph.Cursor.of_string "visibility-next" |> Result.get_ok in
  let output = (deliver_sample runtime (tree_page tree (List.filter(fun (m:Worker_pure_data.tree_member)->m.depth=0)items) (Some cursor))
    |>finish_previews runtime ~children:(List.filter_map(fun (m:Worker_pure_data.tree_member)->if m.depth=1 then Some Worker_pure_data.{value=m.value;revision=m.revision}else None)items)) in
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
  let output = (deliver_sample runtime (tree_page read (List.filter(fun (m:Worker_pure_data.tree_member)->m.depth=0)items) None)
    |>finish_previews runtime ~children:(List.filter_map(fun (m:Worker_pure_data.tree_member)->if m.depth=1 then Some Worker_pure_data.{value=m.value;revision=m.revision}else None)items)) in
  (match (only "visibility day" output.responses).payload with
   | Feed_loaded {feed;complete=true;_} -> check_parent_visibility roots (List.hd feed.days).entries
   | _ -> Alcotest.fail "visibility day owner lost");
  let refresh =
    changed runtime (window ~scopes:[ Worker_pure_data.V2_page_tree_interest page_uuid ] ())
    |> hydration_requests runtime
    |> only "visibility remote"
  in
  (match
     (only
        "visibility remote output"
        ((deliver_sample runtime (tree_page refresh (List.filter(fun (m:Worker_pure_data.tree_member)->m.depth=0)items) None)
    |>finish_previews runtime ~children:(List.filter_map(fun (m:Worker_pure_data.tree_member)->if m.depth=1 then Some Worker_pure_data.{value=m.value;revision=m.revision}else None)items))).responses)
       .payload
   with
   | Page_tree_reconciled { value; _ } -> check_parent_visibility roots value.entries
   | _ -> Alcotest.fail "visibility remote owner lost");
;;

let test_parent_visibility_confirmations () =
  List.iter
    (fun kind ->
       List.iter
         (fun (visible, index) ->
            let _runtime, page, refresh = target_refresh kind in
            let roots, children, _ = parent_visibility_fixture page in
            let _, canonical = List.nth roots index in
            let canonical =
              { canonical with block = { canonical.block with uuid = block_uuid } }
            in
            let output =
              Target_fixture.summary
                   refresh
                   page
                   (Worker_pure_data.V2_present_block { value = canonical; revision = "canonical-2" })
                   (children (index + 1) block_uuid)
                   None
                   "projection-2"
            in
            let actual, entry =
              List.find_map
                (fun r ->
                   match Target_fixture.payload r with
                   | Block_captured { block; timeline_entry_update }
                   | Block_updated { block; timeline_entry_update }
                   | Update_conflict {block;timeline_entry_update}
                   | Delete_conflict {block;timeline_entry_update} ->
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
    [ `Status; `Status_conflict; `Delete_conflict ]
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
  let child=deliver_sample runtime (sample read ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_present_block {value=root;revision="root-with-properties"})) in match query with |Read.Outline_block _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"))))
    |> fun o->only "property child read" o.requests in
  let children=(children_sample ~parent:(block_uuid) ~scope_revision:("children-1") ~items:([]) ~next:(None)) in
  let output=deliver_sample runtime (sample child children) in
  let reference=only "one deduplicated closed property reference" output.requests
    |> outline_after_page_miss runtime in
  (match Runtime.worker_read runtime reference with
   |Some(Runtime.Read{query=W.Outline_block {uuid=block;_};_})->Alcotest.(check string) "closed value UUID"
      (Graph.Uuid.to_string unrelated_uuid) (Graph.Uuid.to_string block)
   |_ ->Alcotest.fail "property value must use the existing bounded block read");
  let closed={record with block={block with uuid=unrelated_uuid;title="Yes";properties=[]}} in
  let output=deliver_sample runtime (sample reference ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_present_block {value=closed;revision="closed-1"})) in match query with |Read.Outline_block _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch")))) in
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
  let request = only "changed active journal detail" (hydration_requests runtime output) in
  let output = deliver_sample runtime (sample request
    ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_present_block
      {value={record with block={block with properties=[property]}}; revision="block-2"})) in match query with |Read.Outline_block _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch")))) in
  let reference = only "new property reference after sync" output.requests in
  match Runtime.worker_read runtime reference with
   | Some(Runtime.Read{query=W.Page {uuid=block;_};_}) -> Alcotest.(check string) "new closed value"
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
    deliver_sample
      runtime
      (sample
         root
         ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_present_block { value = record; revision = "root-1" })) in match query with |Read.Outline_block _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"))))
    |> fun o -> only "materialized parent page" o.requests
  in
  ignore
    (deliver_sample
       runtime
       (sample
          children
          ((children_sample ~parent:(block_uuid) ~scope_revision:("children-1") ~items:([ { value = leaf; revision = "leaf-1" } ]) ~next:(None)))));
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
    |> fun o -> only "materialized leaf sync" (hydration_requests runtime o)
  in
  let output =
    deliver_sample
      runtime
      (sample
         update
         ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_present_block
               { value =
                   { leaf with block = { leaf.block with properties = [ property ] } }
               ; revision = "leaf-2"
               })) in match query with |Read.Outline_block _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"))))
  in
  let read = only "displayed leaf property demand" output.requests in
  match Runtime.worker_read runtime read with
  | Some(Runtime.Read{query=W.Page {uuid=block;_};_}) ->
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
    |> fun o -> only "Timeline-only sync" (hydration_requests runtime o)
  in
  let output =
    deliver_sample
      runtime
      (sample
         update
         ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_present_block
               { value = { record with block = { block with properties = [ property ] } }
               ; revision = "root-2"
               })) in match query with |Read.Outline_block _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"))))
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
    deliver_sample
      runtime
      (sample
         root
         ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_present_block { value = record; revision = "root-1" })) in match query with |Read.Outline_block _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"))))
    |> fun o -> only "child property page" o.requests
  in
  let output =
    deliver_sample
      runtime
      (sample
         children
         ((children_sample ~parent:(block_uuid) ~scope_revision:("children-1") ~items:([ { value = leaf; revision = "leaf-1" } ]) ~next:(None))))
  in
  let request = only "returned child property demand" output.requests in
  match Runtime.worker_read runtime request with
  | Some(Runtime.Read{query=W.Page {uuid=block;_};_}) ->
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
         deliver_sample
           runtime
           (sample
              read
              ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_present_block
                    { value =
                        { record with block = { block with properties = [ property ] } }
                    ; revision = "root-1"
                    })) in match query with |Read.Outline_block _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"))))
         |> fun o -> only "page property children" o.requests
       in
       let output =
         deliver_sample
           runtime
           (sample
              children
              ((children_sample ~parent:(block_uuid) ~scope_revision:("children-1") ~items:([]) ~next:(None))))
       in
       let read = only "one deduplicated page value" output.requests in
       (match Runtime.worker_read runtime read with
        | Some(Runtime.Read{query=W.Page {uuid=page;_};_}) ->
          Alcotest.(check bool)
            "typed page UUID"
            true
            (Graph.Uuid.equal page unrelated_uuid)
        | _ -> Alcotest.fail "page/class property was routed to a block lookup");
       let output =
         deliver_sample
           runtime
           (sample
              read
              ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_present_page
                    { page =
                        { page with
                          uuid = unrelated_uuid
                        ; title = "Visible page title"
                        ; kind = Class_page
                        }
                    ; revision = "page-value-1"
                    })) in match query with |Read.Page _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"))))
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
         |> fun o -> only "changed page property value" (hydration_requests runtime o)
       in
       (match Runtime.worker_read runtime update with
        | Some(Runtime.Read{query=W.Page _;_}) -> ()
        | _ -> Alcotest.fail "page value change did not invalidate the typed cache");
       let output =
         deliver_sample
           runtime
           (sample
              update
              ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_present_page
                    { page =
                        { page with
                          uuid = unrelated_uuid
                        ; title = "Updated title"
                        ; kind = Class_page
                        }
                    ; revision = "page-value-2"
                    })) in match query with |Read.Page _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"))))
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
    let root : Worker_pure_data.tree_member =
      {value={record with block={block with title}};revision="root-1";depth=0;parent=page_uuid} in
    let first=(deliver_sample runtime (tree_page tree [root] None) |>finish_previews runtime ~children:[])
      |> fun o -> only "initial generic page reference" o.requests
      |> outline_after_page_miss runtime in
       (match Runtime.worker_read runtime first with
        | Some(Runtime.Read{query=W.Outline_block _;_}) -> ()
        | _ -> Alcotest.fail "expected generic block lookup");
    if not pending then ignore (deliver_sample runtime (sample first ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_missing_block {uuid=unrelated_uuid;revision="missing-1"})) in match query with |Read.Outline_block _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch")))));
    let property : Graph.property_summary =
      {ident="user.property/page";uuid=block_uuid;title="Actual page"
      ;schema={property_type=Page;cardinality=One;hidden=false;public=false}
      ;values=[Page_value unrelated_uuid];values_truncated=false} in
    let read=Runtime.submit runtime (Journal_graph_request.Load_detail
      {block_id=Graph.Uuid.to_string block_uuid;after=None;limit=128;request_generation=91L})
      |> fun o -> only "promoted Detail root" o.requests in
    let children=deliver_sample runtime (sample read ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_present_block {value={record with block={block with properties=[property]}};revision="root-2"})) in match query with |Read.Outline_block _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"))))
      |> fun o -> only "promoted Detail children" o.requests in
    let output=deliver_sample runtime (sample children ((children_sample ~parent:(block_uuid) ~scope_revision:("children-1") ~items:([]) ~next:(None)))) in
    let output=if pending then (
      Alcotest.(check int) "retain one pending reference read" 0 (List.length output.requests);
      deliver_sample runtime (sample first ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_missing_block {uuid=unrelated_uuid;revision="missing-1"})) in match query with |Read.Outline_block _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"))))) else output in
    let page_read=only "page type supersedes old block missing/pending cache" output.requests in
    (match Runtime.worker_read runtime page_read with
     |Some(Runtime.Read{query=W.Page {uuid=page;_};_})->Alcotest.(check bool) "promoted UUID" true (Graph.Uuid.equal page unrelated_uuid)
     |_ -> Alcotest.fail "semantic page type did not supersede the generic block lookup");
    let output=deliver_sample runtime (sample page_read ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_present_page {page={page with uuid=unrelated_uuid;title="Actual page title";kind=Ordinary_page};revision="actual-page-1"})) in match query with |Read.Page _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch")))) in
    Alcotest.(check bool) "promoted title published" true (List.exists (fun (r:Runtime.response)->match r.payload with
      |Reference_sources_changed values->List.mem (Graph.Uuid.to_string unrelated_uuid,Some "Actual page title") values
      |_ ->false) output.responses)) [false;true]
;;

let test_changed_tree_all_property_slice_continues () =
  let runtime = Runtime.create () in
  seed_feed runtime;
  let read =
    changed runtime (window ~scopes:[ Worker_pure_data.V2_page_tree_interest page_uuid ] ())
    |> fun o -> only "property-only changed tree" (hydration_requests runtime o)
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
  let root : Worker_pure_data.tree_member =
    { value =
        { record with
          block = { block with title = "Property value"; properties = [ marker ] }
        }
    ; revision = "property-1"
    ; depth = 0
    ; parent = page_uuid
    }
  in
  let output = (deliver_sample runtime (tree_page read [ root ] (Some cursor)) |>finish_previews runtime ~children:[]) in
  Alcotest.(check int)
    "do not replace day with a filtered empty slice"
    0
    (List.length output.responses);
  let next = only "continue past property roots" output.requests in
  (match Worker_producer.transport runtime next with
   |Ok(Worker_producer.S.Coordination_query{read=Read.Read_query(budget,(Read.Timeline_read {query=Read.Timeline.Roots _;_} as query));_})->
      let actual=fixture_cursor budget query |> Option.get in
     Alcotest.(check string)
       "same opaque cursor"
       (Graph.Cursor.to_string cursor)
       (Graph.Cursor.to_string actual)
   | _ -> Alcotest.fail "lost property-only continuation");
  let ordinary : Worker_pure_data.tree_member =
    { value = record; revision = "root-2"; depth = 0; parent = page_uuid }
  in
  let output = (deliver_sample runtime (tree_page next [ ordinary ] None) |>finish_previews runtime ~children:[]) in
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
let expect_reference_page runtime output id =
  let request = only "one deduplicated page-first request" (hydration_requests runtime output) in
  Alcotest.(check bool) "page lookup precedes outline lookup" true
    ((match Runtime.worker_read runtime request with Some(Runtime.Read{query=W.Page{uuid;revision=None};_})->uuid=id|_->false));
  request
;;

let missing_reference_page runtime request id =
  deliver_sample runtime
    (sample request ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_missing_page { uuid = id; revision = "page-absent" })) in match query with |Read.Page _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"))))
;;

let expect_reference_outline runtime output id =
  let request = only "one outline fallback after explicit page miss" (hydration_requests runtime output) in
  Alcotest.(check bool) "outline target" true
    ((match Runtime.worker_read runtime request with Some(Runtime.Read{query=W.Outline_block{uuid;revision=None};_})->uuid=id|_->false));
  request
;;

let reference_page_response ?(recycled = false) request kind title =
  sample request ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_present_page { page = { page with uuid = target_uuid; kind; title; recycled }
      ; revision = "resolved-page" })) in match query with |Read.Page _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch")))
;;

let test_reference_page_first_resolves_pages () =
  List.iter (fun kind ->
    let runtime = Runtime.create () in
    let request = reference_feed runtime (reference ^ " " ^ reference)
      |> fun output -> expect_reference_page runtime output target_uuid in
    let resolved = deliver_sample runtime
      (reference_page_response request kind "2026-09-01") in
    Alcotest.(check (option string)) "actual page title is published"
      (Some "2026-09-01") (List.assoc_opt target_id (reference_updates resolved) |> Option.join);
    Alcotest.(check int) "present page never queries outline" 0 (List.length resolved.requests);
    let cached = reference_feed runtime reference in
    Alcotest.(check int) "positive page source is reused" 0 (List.length cached.requests);
    let refresh = changed runtime (window ~pages:[target_uuid] ())
      |> fun output -> expect_reference_page runtime output target_uuid in
    let updated = deliver_sample runtime (reference_page_response refresh kind "Edited page") in
    Alcotest.(check (option string)) "page change invalidates typed cache"
      (Some "Edited page") (List.assoc_opt target_id (reference_updates updated) |> Option.join))
    [Graph.Journal_page {journal_day=20260901}; Ordinary_page]
;;

let test_reference_page_miss_then_outline () =
  let runtime = Runtime.create () in
  let page_read = reference_feed runtime reference
    |> fun output -> expect_reference_page runtime output target_uuid in
  let fallback = missing_reference_page runtime page_read target_uuid in
  Alcotest.(check bool) "page miss is not a negative target result" false
    (List.mem (target_id,None) (reference_updates fallback));
  let outline = expect_reference_outline runtime fallback target_uuid in
  Alcotest.(check int) "duplicate source joins pending fallback" 0
    (List.length (reference_feed runtime (reference ^ " " ^ reference)).requests);
  let resolved = deliver_sample runtime (target_response outline "Outline body") in
  Alcotest.(check (option string)) "outline source resolves after page absence"
    (Some "Outline body") (List.assoc_opt target_id (reference_updates resolved) |> Option.join);
  Alcotest.(check int) "positive outline source is reused" 0
    (List.length (reference_feed runtime reference).requests)
;;

let test_reference_negative_cache_requires_both_misses () =
  let runtime = Runtime.create () in
  let page_read = reference_feed runtime reference
    |> fun output -> expect_reference_page runtime output target_uuid in
  let fallback = missing_reference_page runtime page_read target_uuid in
  let outline = expect_reference_outline runtime fallback target_uuid in
  let missing = deliver_sample runtime (sample outline ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_missing_block {uuid=target_uuid;revision="outline-absent"})) in match query with |Read.Outline_block _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch")))) in
  Alcotest.(check bool) "both misses publish unavailable source" true
    (List.mem (target_id,None) (reference_updates missing));
  Alcotest.(check int) "both misses are cached" 0
    (List.length (reference_feed runtime reference).requests)
;;

let test_reference_errors_and_cancellation_retry_page_first () =
  List.iter (fun outline_stage -> List.iter (fun terminal ->
    let runtime=Runtime.create () in
    let first=reference_feed runtime reference
      |> fun output->expect_reference_page runtime output target_uuid in
    let current=if outline_stage then
      missing_reference_page runtime first target_uuid |> fun output->expect_reference_outline runtime output target_uuid
      else first in
    let failed = match terminal with
      | 0 -> deliver_sample runtime (sample current
          ((failed_sample (Read.Service_failed (("StorageBusy")^": "^("transient"))))))
      | 1 -> Runtime.fail_request runtime current ~message:"Worker cancelled"
      | _ -> Runtime.abandon runtime current; {Runtime.requests=[];responses=[]} in
    Alcotest.(check int) "failure/cancel is not page absence" 0 (List.length failed.requests);
    let retry=reference_feed runtime reference
      |> fun output->expect_reference_page runtime output target_uuid in
    let late=deliver_sample runtime (reference_page_response first Ordinary_page "Late") in
    Alcotest.(check int) "old terminal cannot complete the retry" 0
      (List.length late.requests+List.length late.responses);
    let fresh=deliver_sample runtime (reference_page_response retry Ordinary_page "Recovered") in
    Alcotest.(check (option string)) "retry is not poisoned by negative cache"
      (Some "Recovered") (List.assoc_opt target_id (reference_updates fresh) |> Option.join)) [0;1;2]) [false;true]
;;

let test_reference_reset_discards_both_stages () =
  List.iter (fun outline_stage ->
    let runtime=Runtime.create () in
    let first=reference_feed runtime reference |> fun output->expect_reference_page runtime output target_uuid in
    let old=if outline_stage then missing_reference_page runtime first target_uuid
      |> fun output->expect_reference_outline runtime output target_uuid else first in
    Runtime.reset runtime;
    let fresh=reference_feed runtime reference |> fun output->expect_reference_page runtime output target_uuid in
    let late=deliver_sample runtime
      (if outline_stage then target_response old "Old graph"
       else reference_page_response old Ordinary_page "Old graph") in
    Alcotest.(check int) "reset rejects old graph completion" 0
      (List.length late.requests+List.length late.responses);
    let result=deliver_sample runtime (reference_page_response fresh Ordinary_page "New graph") in
    Alcotest.(check (option string)) "new graph owns source"
      (Some "New graph") (List.assoc_opt target_id (reference_updates result) |> Option.join)) [false;true]
;;

let test_reference_invalidation_restarts_page_phase () =
  List.iter (fun outline_stage ->
    let runtime=Runtime.create () in
    let first=reference_feed runtime reference |> fun output->expect_reference_page runtime output target_uuid in
    let current=if outline_stage then missing_reference_page runtime first target_uuid
      |> fun output->expect_reference_outline runtime output target_uuid else first in
    let invalidated=changed runtime (window ~pages:[target_uuid] ()) in
    Alcotest.(check int) "in-flight invalidations coalesce" 0
      (List.length (hydration_requests runtime invalidated));
    let stale=deliver_sample runtime
      (if outline_stage then target_response current "Stale"
       else sample current ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_missing_page {uuid=target_uuid;revision="old-page-miss"})) in match query with |Read.Page _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch")))) in
    Alcotest.(check bool) "stale phase never publishes" false
      (List.mem (target_id,Some "Stale") (reference_updates stale));
    let refresh=expect_reference_page runtime stale target_uuid in
    let result=deliver_sample runtime (reference_page_response refresh Ordinary_page "Fresh") in
    Alcotest.(check (option string)) "invalidation restarts from page"
      (Some "Fresh") (List.assoc_opt target_id (reference_updates result) |> Option.join)) [false;true]
;;

let test_reference_fallback_keeps_original_epoch () =
  let runtime=Runtime.create () in
  let old=reference_feed runtime reference |> fun output->expect_reference_page runtime output target_uuid in
  let newer=begin_reference_tree runtime 20L in
  let newest = (deliver_sample runtime (reference_tree_response newer "Newer fragment") |>finish_previews runtime ~children:[]) in
  Alcotest.(check (option string)) "newer fragment publishes source"
    (Some "Newer fragment") (List.assoc_opt target_id (reference_updates newest) |> Option.join);
  let fallback=missing_reference_page runtime old target_uuid in
  let completed=match hydration_requests runtime fallback with
    | [] -> fallback
    | [_] -> deliver_sample runtime (target_response
        (expect_reference_outline runtime fallback target_uuid) "Older fallback")
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
    let request : Graph.Uuid.t = Queue.pop pending in
    let outcome=match Runtime.worker_read runtime request with
      | Some(Runtime.Read{query=W.Page {uuid=page;_};_})->incr pages;(query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_missing_page {uuid=page;revision="page-missing"})) in match query with |Read.Page _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"))
      | Some(Runtime.Read{query=W.Outline_block {uuid=block;_};_})->incr outlines;(query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_missing_block {uuid=block;revision="outline-missing"})) in match query with |Read.Outline_block _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"))
      | _->Alcotest.fail "unexpected hydration request" in
    List.iter (fun request->Queue.push request pending)
      (deliver_sample runtime (sample request outcome)).requests;
    Alcotest.(check bool) "both phases share four-read admission" true (Queue.length pending<=4)
  done;
  Alcotest.(check int) "one page read per UUID" 30 !pages;
  Alcotest.(check int) "one fallback per explicit miss" 30 !outlines;
  Alcotest.(check int) "negative results remain deduplicated" 0
    (List.length (reference_feed runtime source).requests)
;;

let test_recycled_reference_page_never_falls_back () =
  let runtime=Runtime.create () in
  let first=reference_feed runtime reference |> fun output->expect_reference_page runtime output target_uuid in
  let hidden=deliver_sample runtime (reference_page_response ~recycled:true first Ordinary_page "Hidden") in
  Alcotest.(check int) "existing recycled page is not a missing page" 0 (List.length hidden.requests);
  Alcotest.(check bool) "recycled title is never shown" false
    (List.mem (target_id,Some "Hidden") (reference_updates hidden));
  ignore (reference_feed runtime reference |> fun output->expect_reference_page runtime output target_uuid)
;;

let test_reference_failed_read_retains_epoch_fence () =
  List.iter (fun abandon ->
    let runtime=Runtime.create () in
    let first=reference_feed runtime reference |> fun output->expect_reference_page runtime output target_uuid in
    let old_fragment=begin_reference_tree runtime 11L in
    ignore (changed runtime (window ~pages:[target_uuid] ()));
    let retry=missing_reference_page runtime first target_uuid
      |> fun output->expect_reference_page runtime output target_uuid in
    if abandon then Runtime.abandon runtime retry
    else ignore (Runtime.fail_request runtime retry ~message:"transient failure");
    let late=(deliver_sample runtime (reference_tree_response old_fragment "Rollback") |>finish_previews runtime ~children:[]) in
    Alcotest.(check bool) "failure/cancel preserves its epoch fence" false
      (List.mem (target_id,Some "Rollback") (reference_updates late));
    let retry_output =
      if hydration_requests runtime late <> [] then late
      else reference_feed runtime reference
    in
    ignore (expect_reference_page runtime retry_output target_uuid);
    Alcotest.(check int) "pending retry remains deduplicated" 0
      (List.length (reference_feed runtime reference).requests)) [false;true]
;;

let test_reference_abandon_preserves_newer_source () =
  let runtime=Runtime.create () in
  let old=reference_feed runtime reference |> fun output->expect_reference_page runtime output target_uuid in
  let older_fragment=begin_reference_tree runtime 12L in
  let current_fragment=begin_reference_tree runtime 13L in
  let fresh=(deliver_sample runtime (reference_tree_response current_fragment "Current") |>finish_previews runtime ~children:[]) in
  Alcotest.(check bool) "fresh fragment published" true
    (List.mem (target_id,Some "Current") (reference_updates fresh));
  Runtime.abandon runtime old;
  let rollback=(deliver_sample runtime (reference_tree_response older_fragment "Rollback") |>finish_previews runtime ~children:[]) in
  Alcotest.(check bool) "abandon cannot delete a newer source fence" false
    (List.mem (target_id,Some "Rollback") (reference_updates rollback));
  Alcotest.(check int) "newer source remains cached" 0
    (List.length (reference_feed runtime reference).requests)
;;

let test_reference_shared_failure_can_retry_discovery () =
  let runtime=Runtime.create () in
  set_calendar runtime;
  let initial=begin_reference_tree runtime 14L in
  ignore ((deliver_sample runtime (reference_tree_response initial "Loaded") |>finish_previews runtime ~children:[]));
  let update=changed runtime (window ~blocks:[target_uuid] ())
    |> check_target_request runtime in
  ignore (Runtime.fail_request runtime update ~message:"shared point-read failed");
  ignore (reference_feed runtime reference |> fun output->expect_reference_page runtime output target_uuid)
;;

let test_reference_page_survives_unrelated_outline_miss () =
  let runtime=Runtime.create () in
  let first=reference_feed runtime reference |> fun output->expect_reference_page runtime output target_uuid in
  ignore (deliver_sample runtime (reference_page_response first Ordinary_page "Actual page"));
  let wrong_projection=Runtime.submit runtime (Journal_graph_request.Find_block target_id)
    |> fun output->only "independent outline request" output.requests in
  let missing=deliver_sample runtime (sample wrong_projection ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_missing_block {uuid=target_uuid;revision="not-an-outline"})) in match query with |Read.Outline_block _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch")))) in
  Alcotest.(check bool) "outline miss does not invalidate an existing page" false
    (List.mem (target_id,None) (reference_updates missing));
  Alcotest.(check int) "existing page stays positively cached" 0
    (List.length (reference_feed runtime reference).requests)
;;

let test_reference_shared_page_miss_is_not_negative_cache () =
  let runtime=Runtime.create () in
  let first=reference_feed runtime reference |> fun output->expect_reference_page runtime output target_uuid in
  ignore (deliver_sample runtime (reference_page_response first Ordinary_page "Actual page"));
  let root=Runtime.submit runtime (Journal_graph_request.Load_detail
    {block_id=Graph.Uuid.to_string block_uuid;after=None;limit=128;request_generation=22L})
    |> fun output->only "unretained owning page root" output.requests in
  let owning=deliver_sample runtime (sample root ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_present_block {value={record with block={block with page=target_uuid;parent=target_uuid}};revision="owning"})) in match query with |Read.Outline_block _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"))))
    |> fun output->only "owning page metadata read" output.requests in
  ignore (missing_reference_page runtime owning target_uuid);
  ignore (reference_feed runtime reference |> fun output->expect_reference_page runtime output target_uuid)
;;

let test_typed_metadata_preserves_newer_reference_fence () =
  let runtime=Runtime.create () in
  let first=reference_feed runtime reference |> fun output->expect_reference_page runtime output target_uuid in
  let property : Graph.property_summary =
    {ident="user.property/page";uuid=block_uuid;title="Actual page"
    ;schema={property_type=Page;cardinality=One;hidden=false;public=false}
    ;values=[Page_value target_uuid];values_truncated=false} in
  let root=Runtime.submit runtime (Journal_graph_request.Load_detail
    {block_id=Graph.Uuid.to_string block_uuid;after=None;limit=128;request_generation=31L})
    |> fun output->only "old typed Detail root" output.requests in
  let children=deliver_sample runtime (sample root ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_present_block {value={record with block={block with properties=[property]}};revision="typed"})) in match query with |Read.Outline_block _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"))))
    |> fun output->only "old typed Detail children" output.requests in
  let middle=begin_reference_tree runtime 32L in
  ignore (changed runtime (window ~pages:[target_uuid] ()));
  let fresh=missing_reference_page runtime first target_uuid
    |> fun output->expect_reference_page runtime output target_uuid in
  ignore (Runtime.fail_request runtime fresh ~message:"newer failure fence");
  ignore (deliver_sample runtime (sample children ((children_sample ~parent:(block_uuid) ~scope_revision:("typed") ~items:([]) ~next:(None)))));
  let late=(deliver_sample runtime (reference_tree_response middle "Rollback") |>finish_previews runtime ~children:[]) in
  Alcotest.(check bool) "old typed metadata cannot lower a newer fence" false
    (List.mem (target_id,Some "Rollback") (reference_updates late))
;;

let test_dirty_abandon_keeps_reference_retryable () =
  List.iter (fun positive ->
    let runtime=Runtime.create () in
    let first=reference_feed runtime reference |> fun output->expect_reference_page runtime output target_uuid in
    if positive then ignore (deliver_sample runtime (reference_page_response first Ordinary_page "Before"))
    else (
      let outline=missing_reference_page runtime first target_uuid
        |> fun output->expect_reference_outline runtime output target_uuid in
      ignore (deliver_sample runtime (sample outline ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_missing_block {uuid=target_uuid;revision="missing"})) in match query with |Read.Outline_block _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"))))));
    let pending=changed runtime (window ~pages:[target_uuid] ())
      |> fun output->expect_reference_page runtime output target_uuid in
    ignore (changed runtime (window ~pages:[target_uuid] ()));
    Runtime.abandon runtime pending;
    ignore (reference_feed runtime reference |> fun output->expect_reference_page runtime output target_uuid)) [false;true]
;;

(* Root dispatch and mutation confirmation are owned by Runtime; no public pure
   reducer emits these protocol reads. Test only its public submit/receive boundary. *)
let page_detail_seed runtime children =
  set_calendar runtime;
  let out = Runtime.submit runtime (Journal_graph_request.Load_detail
    {block_id=Graph.Uuid.to_string page_uuid; after=None; limit=128; request_generation=801L}) in
  let root = only "page root lookup" out.requests in
  let root = match Runtime.worker_read runtime root with
    | Some(Runtime.Read{query=W.Page {uuid=id;_};_}) when Graph.Uuid.equal id page_uuid -> root
    | Some(Runtime.Read{query=W.Outline_block _;_}) ->
      deliver_sample runtime (sample root ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_missing_block {uuid=page_uuid; revision="absent-outline"})) in match query with |Read.Outline_block _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"))))
      |> fun out -> only "outline miss must resolve page" out.requests
    | _ -> Alcotest.fail "unexpected root lookup" in
  Alcotest.(check bool) "page root is resolved as a page" true
    ((match Runtime.worker_read runtime root with Some(Runtime.Read{query=W.Page{uuid;revision=None};_})->uuid=page_uuid|_->false));
  let child_read = deliver_sample runtime (sample root ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_present_page {page; revision="page-1"})) in match query with |Read.Page _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"))))
    |> fun out -> only "page root children" out.requests in
  (match Runtime.worker_read runtime child_read with
   | Some(Runtime.Read{query=W.Child_members {parent;_};maximum_items=128;_}) when Graph.Uuid.equal parent page_uuid -> ()
   | _ -> Alcotest.fail "page children escaped selected page");
  let out = deliver_sample runtime (sample child_read (copy_children page_uuid children)) in
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
         ; status_intent_revision = 0L
         ; expected_parent_revision = Journal_model.revision detail.root
         ; sibling_order = "z"
         ; source = "Append only here"
         ; task_state = No_status
         ; creation_time = Journal_model.creation_time detail.root
         ; status_confirmation = false
         }
       in
    let request=Runtime.submit runtime (Create_child command) |> fun out->only "page append" out.requests in
    let expected=W.mutation_intent Worker_producer.session ~mutation_id:unrelated_uuid
      (W.Insert_blocks{parent=page_uuid;roots=[{uuid=unrelated_uuid;title=command.source;children=[]}];
        preconditions={blocks=[];pages=[page_uuid,"page-1"];scopes=[Worker_pure_data.V2_children_scope page_uuid,"children-1"]}}) |> Result.get_ok in
    Alcotest.(check bytes) "page revision, never outline revision"
      (W.encode_durable_intent(W.Mutation_intent expected))
      (W.encode_durable_intent(Runtime.worker_intent runtime request Worker_producer.session |> Result.get_ok));
    let module W=Worker_producer.W in let module I=Worker_producer.I in
    let presentation=Option.get(W.selected Worker_producer.projection) in
    let intent=match Runtime.worker_intent runtime request Worker_producer.session |> Result.get_ok with W.Mutation_intent intent->intent|_->assert false in
    let mutation_id=W.mutation_intent_id intent in
    Alcotest.(check bool) "page insertion bound to typed owner" true
      (Runtime.bind_mutation runtime request ~presentation ~intent:(W.Mutation_intent intent));
    let receipt=(let receipt_request_id=request in let packet=((Logseq_db_worker_contract.Worker_pure_mutation.For_worker.commit ~mutation_id:(mutation_id) ~status:(Worker_pure_data.V2_applied) ~generation:("generation:v1:1:1") ~before:("projection:v1:1") ~after:("projection:v1:2"))) in
      match I.reply Worker_producer.session ~request_id:(W.request_id request) (W.Mutate intent)
        (Logseq_db_worker_lui.Logseq_db_worker_lui_service.Coordination_mutation_result
          {request_id=receipt_request_id;
           outcome=Logseq_db_worker_contract.Worker_pure_mutation.Committed packet}) with
      | Ok(W.Answered(Ok(W.Submission_committed proof))) -> proof
      | _ -> failwith "Production mutation receipt was rejected") in
    let child=copy_child unrelated_uuid page_uuid command.source in
    let confirmation=confirmed_sample Worker_producer.issuer Worker_producer.session presentation receipt request (((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok(F.block_summary ~lookup:(Worker_pure_data.V2_present_block{value=child.value;revision=child.revision}) ~page:(Some(Worker_pure_data.V2_present_page{page;revision="page-2"})) ~items:([]) ~next:(Option.map(fun cursor->F.continuation ~owner:(F.read_budget_owner budget) ~budget ~key:(Read.query_key budget query) ~cursor)(None)) ~scope_revision:("children-1") ~generation:("generation:v1:1:1") ~projection_revision:("projection:v1:2")) in match query with |Read.Block_summary _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch")))) in
    let parent_read=Runtime.receive_mutation runtime request(W.Confirmed confirmation)
      |> fun out->only "confirm selected page parent" out.requests in
    Alcotest.(check bool) "confirm page through page API" true
      ((match Runtime.worker_read runtime parent_read with Some(Runtime.Read{query=W.Page{uuid;revision=None};_})->uuid=page_uuid|_->false));
    let done_=deliver_sample runtime (sample parent_read ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_present_page {page;revision="page-2"})) in match query with |Read.Page _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch")))) in
    let child,parent=done_.responses |> List.find_map (fun r -> match r.Runtime.payload with
      | Child_projection_ready {result=Child_created{child;parent;_};_}->Some(child,parent)
      | _->None) |> Option.get in
    Alcotest.(check string) "completed child page" (Graph.Uuid.to_string page_uuid) (Journal_model.page_id child);
    Alcotest.(check string) "completed parent is page" (Graph.Uuid.to_string page_uuid) (Journal_model.id parent))
    [[]; [copy_child block_uuid page_uuid "First child"]]
;;

let test_recycled_page_root_is_removed () =
  let runtime=Runtime.create () in
  ignore (page_detail_seed runtime []);
  let request=changed runtime (window ~pages:[page_uuid] ())
    |> fun out->only "page recycle refresh" (hydration_requests runtime out) in
  let out=deliver_sample runtime (sample request ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_present_page {page={page with recycled=true};revision="recycled"})) in match query with |Read.Page _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch")))) in
  Alcotest.(check bool) "recycled page root becomes unavailable" true
    (List.exists (fun r->match r.Runtime.payload with
      | Block_removed {block_id}->block_id=Graph.Uuid.to_string page_uuid | _->false) out.responses)
;;

let test_page_root_block_change_uses_page_identity () =
  let runtime=Runtime.create () in
  ignore (page_detail_seed runtime []);
  let out=changed runtime (window ~blocks:[page_uuid] ()) in
  Alcotest.(check bool) "page root point change is not an outline lookup" false
    (List.exists (fun (r:Graph.Uuid.t)->(match Runtime.worker_read runtime r with Some(Runtime.Read{query=W.Outline_block{uuid;revision=None};_})->uuid=page_uuid|_->false)) out.requests);
  Alcotest.(check bool) "page root point change refreshes page" true
    (List.exists (fun (r:Graph.Uuid.t)->(match Runtime.worker_read runtime r with Some(Runtime.Read{query=W.Page{uuid;revision=None};_})->uuid=page_uuid|_->false)) out.requests)
;;

let test_page_root_refresh_and_resync () =
  let runtime=Runtime.create () in
  ignore (page_detail_seed runtime []);
  let fresh=changed runtime (window ~pages:[page_uuid] ())
    |> fun out->only "one owned page refresh" (hydration_requests runtime out) in
  let result=deliver_sample runtime (sample fresh ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_present_page {page={page with title="Renamed page"};revision="page-2"})) in match query with |Read.Page _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch")))) in
  let detail=result.responses |> List.find_map (fun r-> match r.Runtime.payload with
    | Children_reconciled detail -> Some detail | _->None) |> Option.get in
  Alcotest.(check string) "renamed page root reconciles" "Renamed page" (Journal_model.source detail.root);
  Alcotest.(check string) "page revision reconciles" "page-2" (Journal_model.revision detail.root);
  let out=Runtime.reconcile_signal runtime ~request_generation:12L
    (Worker_pure_data.Resync_required {generation="generation-2";reason="overflow"}) in
  Alcotest.(check bool) "page root is never rehydrated as outline" false
    (List.exists (fun (r:Graph.Uuid.t)->(match Runtime.worker_read runtime r with Some(Runtime.Read{query=W.Outline_block{uuid;revision=None};_})->uuid=page_uuid|_->false)) out.requests)
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
      |> fun out -> hydration_requests runtime out
      |> List.filter (fun (request:Graph.Uuid.t) ->
        (match Runtime.worker_read runtime request with Some(Runtime.Read{query=W.Page{uuid;revision=None};_})->uuid=page_uuid|_->false))
      |> only "one owning page refresh" in
    let complete request = deliver_sample runtime (sample request ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_present_page {page={page with properties=[property;hidden]};revision="page-2"})) in match query with |Read.Page _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch")))) in
    let out=complete (refresh ()) in
    if page_root then (
      let reference=expect_reference_page runtime out target_uuid in
      Alcotest.(check int) "duplicate values share one read; hidden properties have no demand"
        1 (List.length out.requests);
      let resolved=deliver_sample runtime (reference_page_response reference Ordinary_page "Linked title") in
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
  deliver_sample runtime (sample read ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok(F.favorites ~favorites_page:(None) ~generation:("g") ~projection_revision:("p") ~next:(Option.map(fun cursor->F.continuation ~owner:(F.read_budget_owner budget) ~budget ~key:(Read.query_key budget query) ~cursor)(None)) ~items:([{membership_uuid;membership_order="a";membership_revision="m";
       target=Worker_pure_data.V2_favorite_block {uuid=block_uuid;title;task_status=None;revision="b"}}])) in match query with |Read.Favorites _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"))))
;;

let test_favorites_share_reference_cache () =
  let runtime=Runtime.create () in
  set_calendar runtime;
  let out=favorites_reference_source runtime (reference ^ " " ^ reference) in
  let page_read=out.requests |> List.filter (fun (r:Graph.Uuid.t)->
    (match Runtime.worker_read runtime r with Some(Runtime.Read{query=W.Page{uuid;revision=None};_})->uuid=target_uuid|_->false)) |> only "duplicate favorite reference uses one page read" in
  let out=deliver_sample runtime (reference_page_response page_read
    (Graph.Journal_page {journal_day=20260901}) "Tuesday, September 1st, 2026") in
  Alcotest.(check (option string)) "favorite journal page keeps actual date title"
    (Some "Tuesday, September 1st, 2026")
    (List.assoc_opt target_id (reference_updates out) |> Option.join);
  let duplicate=favorites_reference_source runtime reference in
  Alcotest.(check int) "favorite reload shares positive reference cache" 0
    (List.length (List.filter (fun (r:Graph.Uuid.t)->(match Runtime.worker_read runtime r with Some(Runtime.Read{query=W.Page{uuid;revision=None};_})->uuid=target_uuid|_->false)) duplicate.requests));
  let late_runtime=Runtime.create () in
  let old=favorites_reference_source late_runtime reference in
  let old_read=old.requests |> List.find (fun (r:Graph.Uuid.t)->(match Runtime.worker_read late_runtime r with Some(Runtime.Read{query=W.Page{uuid;revision=None};_})->uuid=target_uuid|_->false)) in
  Runtime.reset late_runtime;
  let late=deliver_sample late_runtime (reference_page_response old_read Ordinary_page "Old graph") in
  Alcotest.(check int) "late Favorites reference is fenced by graph reset" 0 (List.length late.responses)
;;

let test_favorites_outline_and_missing_reference () =
  List.iter (fun missing ->
    let runtime=Runtime.create () in
    let out=favorites_reference_source runtime (reference ^ reference) in
    let page_read=out.requests |> List.find (fun (r:Graph.Uuid.t)->
      (match Runtime.worker_read runtime r with Some(Runtime.Read{query=W.Page{uuid;revision=None};_})->uuid=target_uuid|_->false)) in
    let fallback=missing_reference_page runtime page_read target_uuid in
    let outline=expect_reference_outline runtime fallback target_uuid in
    let out=deliver_sample runtime (if missing then sample outline ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_missing_block {uuid=target_uuid;revision="absent"})) in match query with |Read.Outline_block _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"))) else target_response outline "Outline title") in
    Alcotest.(check (option string)) "Favorites shares outline and missing source results"
      (if missing then None else Some "Outline title")
      (List.assoc_opt target_id (reference_updates out) |> Option.join)) [false;true]
;;

(* The scheduler is owned by Runtime, so use only its public demands and
   completions. Every Present value below describes the requested entity. *)
let scheduling_uuid family n =
  uuid (Printf.sprintf "a8000000-0000-4000-%04d-%012d" family n)
;;

let scheduling_block n : Worker_pure_data.block_record =
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
  deliver_sample runtime (sample read ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok(F.favorites ~favorites_page:(None) ~generation:("g") ~projection_revision:("p") ~next:(Option.map(fun cursor->F.continuation ~owner:(F.read_budget_owner budget) ~budget ~key:(Read.query_key budget query) ~cursor)(None)) ~items:(List.init count (fun n ->
        let value = scheduling_block n in
        { Worker_pure_data.membership_uuid = scheduling_uuid 7000 n
        ; membership_order = string_of_int n; membership_revision = "m"
        ; target = Worker_pure_data.V2_favorite_block
            { uuid = value.block.uuid; title = value.block.title
            ; task_status = None; revision = "b" } }))) in match query with |Read.Favorites _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"))))
;;

let scheduling_reply runtime (request : Graph.Uuid.t) =
  match Runtime.worker_read runtime request with
  | Some(Runtime.Read{query=W.Outline_block {uuid=requested;_};_}) ->
    let n = List.find (fun n -> Graph.Uuid.equal requested (scheduling_uuid 9000 n))
      (List.init 12 Fun.id) in
    sample request ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_present_block { value = scheduling_block n; revision = "b" })) in match query with |Read.Outline_block _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch")))
  | Some(Runtime.Read{query=W.Page {uuid=requested;_};_}) ->
    sample request ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_present_page
      { page = { page with uuid = requested; kind = Ordinary_page
                ; title =
                    (if Graph.Uuid.equal requested target_uuid
                     then "Resolved"
                     else "Parent")
                }
      ; revision = "p" })) in match query with |Read.Page _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch")))
  | _ -> Alcotest.fail "unexpected scheduling demand"
;;

let drain_scheduling ?(cancel_count = 0) runtime output =
  let issued = Hashtbl.create 32 in
  let target_reads = ref 0 and updates = ref [] in
  let collect (output : Runtime.output) =
    updates := reference_updates output @ !updates;
    List.iter (fun (request : Graph.Uuid.t) ->
      let key = Graph.Uuid.to_string request in
      Alcotest.(check bool) "one delivery per request ID" false (Hashtbl.mem issued key);
      Hashtbl.add issued key ();
      if (match Runtime.worker_read runtime request with Some(Runtime.Read{query=W.Page{uuid;revision=None};_})->uuid=target_uuid|_->false)
      then incr target_reads) output.requests
  in
  collect output;
  let rec loop completed outstanding =
    check_hydration_bound outstanding;
    match outstanding with
    | [] -> ()
    | request :: rest ->
      let reply=scheduling_reply runtime request in
      let next = if completed < cancel_count then
          Runtime.fail_request runtime request ~message:"Worker cancelled"
        else deliver_sample runtime reply in
      let duplicate = deliver_sample runtime reply in
      Alcotest.(check int) "late or repeated completion cannot dispatch" 0
        (List.length duplicate.requests);
      Alcotest.(check int) "late or repeated completion cannot publish" 0
        (List.length duplicate.responses);
      collect next;
      loop (completed + 1) (rest @ next.requests)
  in
  loop 0 output.requests;
  Alcotest.(check int) "queued target page is delivered exactly once" 1 !target_reads;
  Alcotest.(check (option string)) "target sample reaches shared cache"
    (Some "Resolved") (List.assoc_opt target_id !updates |> Option.join);
  let fresh = scheduling_favorites runtime 4 902L in
  Alcotest.(check int) "all four slots are free after draining" 4
    (List.length fresh.requests);
  Alcotest.(check (list string)) "no earlier queued identity leaks into a fresh window"
    (List.init 4 (fun n -> Graph.Uuid.to_string (scheduling_uuid 9000 n)) |> List.sort String.compare)
    (List.map (fun (request : Graph.Uuid.t) -> match Runtime.worker_read runtime request with
      | Some(Runtime.Read{query=W.Outline_block {uuid=block;_};_}) -> Graph.Uuid.to_string block
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
  let pending_replies=List.map(scheduling_reply runtime) old.requests in
  Runtime.reset runtime;
  List.iter (fun reply ->
    let late = deliver_sample runtime reply in
    Alcotest.(check int) "old scope cannot dispatch queued reads" 0
      (List.length late.requests);
    Alcotest.(check int) "old scope cannot publish sources" 0
      (List.length late.responses)) pending_replies;
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
    let next = deliver_sample runtime (scheduling_reply runtime request) in
    { Runtime.requests = out.requests @ next.requests
    ; responses = out.responses @ next.responses }) current old.requests in
  drain_scheduling runtime resumed
;;

(* Worker admission belongs to transport. Test only that missing boundary,
   with a real Runtime output; do not duplicate DB/effect-runner coverage. *)
(* Transport owns admission refusal, and Runtime owns preservation of the
   correctly typed DB completion. Neither is produced by Root_navigation. *)
let test_timeline_admission_keeps_refusal_cause () =
  let module E=Logseq_db_worker.Error in
  List.iter (fun (refusal,expected) ->
    let runtime=Production_runtime.create () in
    set_calendar runtime;
    let output=Production_runtime.submit runtime (Journal_graph_request.Load_feed
      {cursor=None;day_limit=7;root_limit=32;request_generation=1L}) in
    let delivery=Journal_graph_transport.deliver ~runtime ~send:(fun _->refusal) output in
    match delivery.responses with
    | [{Production_runtime.payload=Feed_failed {failure=Worker_failure failure;_}}] ->
      Alcotest.(check string) "date read operation" "listTimelineDates" failure.operation;
      Alcotest.(check (option string)) "precise admission cause" (Some expected)
        (E.trace failure.error).origin.code;
      if refusal=Journal_graph_transport.Full then
        Alcotest.(check bool) "queue full is not database closed" false
          (E.code failure.error=E.Closed_session)
    | _ -> Alcotest.fail "expected original feed failure")
    Journal_graph_transport.[Full,"queueFull";Not_ready,"notReady";Stopping,"stopping"]
;;

let test_timeline_read_preserves_typed_origin () =
  let module E=Logseq_db_worker.Error in
  List.iter(fun category->
    let runtime=Production_runtime.create () in
    set_calendar runtime;
    let output=Production_runtime.submit runtime(Journal_graph_request.Load_feed
      {cursor=None;day_limit=7;root_limit=32;request_generation=1L}) in
    let request=only "timeline dates" output.requests in
    let origin=E.create_cause ~component:E.Read_model ~operation:"snapshot"
      ~code:(Some category) ~message:("Typed cause: " ^ category) |> Result.get_ok in
    let original=E.create_with_origin ~code:E.Closed_session ~message:"Timeline read unavailable"
      ~details:[E.{name="phase";value=Detail_string "snapshot"}] ~origin |> Result.get_ok in
    let result=Production_runtime.receive_worker_read runtime ~request_id:request
      (Production_runtime.Read_error original) in
    match result.responses with
    | [{Production_runtime.payload=Feed_failed {failure=Worker_failure failure;_}}] ->
      Alcotest.(check string) "same error including trace and details"
        (Yojson.Safe.to_string(E.to_yojson original))
        (Yojson.Safe.to_string(E.to_yojson failure.error));
      Alcotest.(check int) "late failure remains retired" 0
        (List.length(Production_runtime.receive_worker_read runtime ~request_id:request
          (Production_runtime.Read_error original)).responses)
    | _ -> Alcotest.fail "expected typed feed failure")
    ["Database_closed";"Snapshot_released";"Snapshot_generation_invalidated"]
;;

let test_reference_and_favorites_preserve_typed_origin () =
  let module E=Logseq_db_worker.Error in
  let module A=Application.Root_navigation in
  let check runtime request =
    let origin=E.create_cause ~component:E.Storage ~operation:"sqliteStep"
      ~code:(Some "SQLITE_CORRUPT") ~message:"SQLite reported corrupt storage"
      |> Result.get_ok in
    let original=E.create_with_origin ~code:E.Corrupt_storage
      ~message:"Read failed" ~details:[] ~origin |> Result.get_ok in
    let output=deliver_sample runtime (sample request (failed_sample (W.Db_error original))) in
    let response=List.filter(fun (response:Runtime.response)->match response.payload with
      | Diagnostic _ -> true | _ -> false) output.responses
      |> only "typed diagnostic event" in
    (match response.payload with
     | Diagnostic failure->
       Alcotest.(check string) "original cause remains intact"
         (Yojson.Safe.to_string(E.to_yojson original))
         (Yojson.Safe.to_string(E.to_yojson failure.error))
     | _ -> assert false);
    let state,_=A.step (A.create ~graph_generation:7) (Completed response) in
    Alcotest.(check (option string)) "visible diagnostic retains storage cause"
      (Some "SQLITE_CORRUPT") (List.assoc_opt "Origin code" (A.diagnostic_rows state))
  in
  let reference_runtime=Runtime.create () in
  let request=reference_feed reference_runtime reference |> check_target_request reference_runtime in
  check reference_runtime request;
  let favorites_runtime=Runtime.create () in
  set_calendar favorites_runtime;
  let request=Runtime.submit favorites_runtime (Load_favorites
    {graph_generation=7;request_generation=1L;limit=50;cursor=None})
    |> fun output->only "favorites read" output.requests in
  check favorites_runtime request
;;

let test_rejected_delivery_retires_unsent_queue () =
  List.iter (fun refusal ->
    let runtime = Runtime.create () in
    set_calendar runtime;
    let output = scheduling_favorites runtime 8 900L in
    let pending_replies=List.map(scheduling_reply runtime) output.requests in
    let attempts = ref 0 in
    let delivery = Journal_graph_transport.deliver ~runtime
      ~send:(fun _ -> incr attempts; refusal) output in
    Alcotest.(check int) "refusal is never retried" 1 !attempts;
    Alcotest.(check bool) "refusal remains explicit" true (Option.is_some delivery.error);
    List.iter (fun reply ->
      let late = deliver_sample runtime reply in
      Alcotest.(check int) "rejected request cannot publish late response" 0
        (List.length late.responses)) pending_replies;
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
  let out = deliver_sample runtime (sample read ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok(F.favorites ~favorites_page:(None) ~generation:("g") ~projection_revision:("p") ~next:(Option.map(fun cursor->F.continuation ~owner:(F.read_budget_owner budget) ~budget ~key:(Read.query_key budget query) ~cursor)(None)) ~items:([{ Worker_pure_data.membership_uuid; membership_order = "a"; membership_revision = "m"
        ; target = Worker_pure_data.V2_favorite_page { uuid = page_uuid; title = reference; revision = "p" } }])) in match query with |Read.Favorites _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch")))) in
  let reference_read = out.requests |> List.filter (fun (r : Graph.Uuid.t) ->
    (match Runtime.worker_read runtime r with Some(Runtime.Read{query=W.Page{uuid;revision=None};_})->uuid=target_uuid|_->false))
    |> only "Favorite page title demands page-first reference" in
  let resolved = deliver_sample runtime
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
  let page_read = deliver_sample runtime (sample root ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_missing_block { uuid = page_uuid; revision = "no-outline" })) in match query with |Read.Outline_block _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"))))
    |> fun out -> only "detail page fallback" out.requests in
  let out = deliver_sample runtime (sample page_read ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_present_page { page = { page with kind = Ordinary_page; title = reference }
    ; revision = "p" })) in match query with |Read.Page _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch")))) in
  let children = out.requests |> List.find (fun (r : Graph.Uuid.t) ->
      match Runtime.worker_read runtime r with
      | Some(Runtime.Read{query=W.Child_members _;_}) -> true
      | _ -> false)
  in
  let loaded = deliver_sample runtime (sample children ((children_sample ~parent:(page_uuid) ~scope_revision:("c") ~items:([]) ~next:(None)))) in
  let refs = out.requests @ loaded.requests |> List.filter (fun (r : Graph.Uuid.t) ->
    (match Runtime.worker_read runtime r with Some(Runtime.Read{query=W.Page{uuid;revision=None};_})->uuid=target_uuid|_->false)) in
  let ref_read = only "empty page detail root demands reference" refs in
  let resolved = deliver_sample runtime
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
    let state,effects=copy_reply state effects ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_missing_block {uuid=page_uuid;revision="no-outline"})) in match query with |Read.Outline_block _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"))) in
    Alcotest.(check bool) "copy resolves exact page" true
      (match snd(copy_read effects) with
       | Query(Copy_worker.Page {uuid;revision=None}) -> Graph.Uuid.equal uuid page_uuid
       | _ -> false);
    let state,effects=copy_reply state effects ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_present_page {page;revision="page-1"})) in match query with |Read.Page _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"))) in
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
                  ; status_intent_revision = 0L
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
  let find_catalog runtime requests =
    List.find
      (fun (r : Graph.Uuid.t) ->
         match Runtime.worker_read runtime r with
         | Some(Runtime.Read{query=W.Task_statuses _;_}) -> true
         | _ -> false)
      requests
  in
  let start () =
    let runtime = Runtime.create () in
    let started = Runtime.start runtime in
    let output =
      deliver_sample
        runtime
        (sample started (graph_info_outcome ~journal_title_format:None))
    in
    runtime, find_catalog runtime output.requests
  in
  let catalog items next_cursor =
    (query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok(F.task_status_catalog ~property_uuid:(Some page_uuid) ~default_status:(None) ~items:(items) ~next:(Option.map(fun cursor->F.continuation ~owner:(F.read_budget_owner budget) ~budget ~key:(Read.query_key budget query) ~cursor)(next_cursor))) in match query with |Read.Task_statuses _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"))
  in
  let runtime, first = start () in
  let page2 =
    deliver_sample
      runtime
      (sample
         first
         (catalog [] (Some (Graph.Cursor.of_string "next" |> Result.get_ok))))
    |> fun out -> find_catalog runtime out.requests
  in
  let delta =
    changed runtime (window ~blocks:[ unrelated_uuid ] ())
    |> fun out ->
    List.find
      (fun (r : Graph.Uuid.t) ->
         match Runtime.worker_read runtime r with
         | Some(Runtime.Read{query=W.Task_status_definitions _;_}) -> true
         | _ -> false)
      out.requests
  in
  ignore
    (deliver_sample
       runtime
       (sample delta ((query_sample(fun(Read.Read_query(budget,query))->match query with |Read.Task_status_definitions _->Read.For_worker.answer budget query(Ok([ None ]))|_->failwith "Expected task definitions")))));
  let done_ = deliver_sample runtime (sample page2 (catalog [ definition ] None)) in
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
  ignore (deliver_sample runtime (sample first (catalog [ definition ] None)));
  let delta =
    changed runtime (window ~blocks:[ unrelated_uuid ] ())
    |> fun out ->
    List.find
      (fun (r : Graph.Uuid.t) ->
         match Runtime.worker_read runtime r with
         | Some(Runtime.Read{query=W.Task_status_definitions _;_}) -> true
         | _ -> false)
      out.requests
  in
  let reload =
    Runtime.submit runtime Load_task_statuses |> fun out -> find_catalog runtime out.requests
  in
  ignore (deliver_sample runtime (sample reload (catalog [] None)));
  let stale =
    deliver_sample
      runtime
      (sample delta ((query_sample(fun(Read.Read_query(budget,query))->match query with |Read.Task_status_definitions _->Read.For_worker.answer budget query(Ok([ Some definition ]))|_->failwith "Expected task definitions"))))
  in
  Alcotest.(check int)
    "old lookup cannot restore catalog deletion"
    0
    (List.length stale.responses)
;;

(* Core cannot reproduce the business Runtime's old sub-operation allocator. *)
let child_identity_insert runtime =
  let child=uuid "a1000000-0000-4000-9000-000000000081" in
  let mutation_id=uuid "a1000000-0000-4000-a000-000000000081" in
  let command : Journal_graph_projection.create_child =
    {mutation_id=Graph.Uuid.to_string mutation_id;block_id=Graph.Uuid.to_string child;
     parent_block_id=Graph.Uuid.to_string block_uuid;calendar_generation=1L;
     status_intent_revision=0L;expected_parent_revision="block-detail-1";sibling_order="a";source="Stable child";
     task_state=Status "00000002-1615-5853-7700-000000000000";status_confirmation=true;
     creation_time=Journal_time.create ~instant_unix_ms:1_788_192_000_000L
       ~local_day:20260901 ~local_minute_of_day:0 |> Result.get_ok} in
  Runtime.submit runtime(Create_child command)
  |> fun output -> only "child insertion" output.Runtime.requests
;;
(* SDK progress alone cannot exercise the business dispatcher's delivery state.
   Use its public transition, with the same typed intent as a real bound write. *)
let test_unknown_mutation_recovery_issues_original () =
  let module W=Worker_producer.W in
    let runtime,_,request=prepare_unbound_mutation ~ordinary:true Delete_conflict in
    let presentation=Option.get(W.selected Worker_producer.projection) in
    let intent=match Runtime.worker_intent runtime request Worker_producer.session |> Result.get_ok with W.Mutation_intent intent->intent|_->assert false in
    Alcotest.(check bool) "original mutation bound before Unknown" true
      (Runtime.bind_mutation runtime request ~presentation ~intent:(W.Mutation_intent intent));
    let output=Runtime.receive_mutation runtime request W.Outcome_unknown in
    let resumed=only "one automatic original-intent continuation" output.requests in
    Alcotest.(check bool) "continuation preserves original wire" true (resumed=request);
    Alcotest.(check bool) "public transition issues continuation before returning" true
      (Runtime.worker_intent runtime resumed Worker_producer.session=Ok(W.Mutation_intent intent));
    Alcotest.(check bool) "same-intent continuation can bind its next receipt" true
      (Runtime.bind_mutation runtime resumed ~presentation ~intent:(W.Mutation_intent intent))
;;

let child_identity_runtime () =
  let runtime=Runtime.create () in seed_children_interest runtime;set_calendar runtime;runtime
;;
let test_child_unknown_wire_survives_reset ?(status=false) () =
  let module W=Journal_worker_coordination.Worker_api in
  let runtime=child_identity_runtime() in
  let insert=child_identity_insert runtime in
  let issuer,_,projection,session=Coordination_test_fixture.fixture 5530L in
  let module I=(val issuer:Worker_effect_authority.ISSUER) in
  let presentation=Option.get(W.selected projection) in
  let original=match Runtime.worker_intent runtime (insert) session |> Result.get_ok with W.Mutation_intent intent->intent|_->assert false in
  let mutation_id=W.mutation_intent_id original in
  Alcotest.(check bool) "original Child binds" true(Runtime.bind_mutation runtime insert ~presentation ~intent:(W.Mutation_intent original));
  let original=if not status then (
    ignore(Runtime.receive_mutation runtime insert W.Outcome_unknown); original)
    else (
      let child=uuid "a1000000-0000-4000-9000-000000000081" in
      let target={record with block={block with uuid=child;title="Stable child";parent=block_uuid};task_status=None} in
      let receipt=(let receipt_request_id=insert in let packet=((Logseq_db_worker_contract.Worker_pure_mutation.For_worker.commit ~mutation_id:(mutation_id) ~status:(Worker_pure_data.V2_applied) ~generation:("generation:v1:1:1") ~before:("projection:v1:0") ~after:("projection:v1:1"))) in
      match I.reply session ~request_id:(W.request_id insert) (W.Mutate original)
        (Logseq_db_worker_lui.Logseq_db_worker_lui_service.Coordination_mutation_result
          {request_id=receipt_request_id;
           outcome=Logseq_db_worker_contract.Worker_pure_mutation.Committed packet}) with
      | Ok(W.Answered(Ok(W.Submission_committed proof))) -> proof
      | _ -> failwith "Production mutation receipt was rejected") in
      let summary=(query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok(F.block_summary ~lookup:(Worker_pure_data.V2_present_block{value=target;revision="original-child-precondition"}) ~page:(Some(Worker_pure_data.V2_present_page{page;revision="page-original"})) ~items:([]) ~next:(Option.map(fun cursor->F.continuation ~owner:(F.read_budget_owner budget) ~budget ~key:(Read.query_key budget query) ~cursor)(None)) ~scope_revision:("original-child-scope") ~generation:("generation:v1:1:1") ~projection_revision:("projection:v1:1")) in match query with |Read.Block_summary _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch")) in
      let proof=confirmed_sample issuer session presentation receipt insert (summary) in
      let parent=Production_runtime.receive_mutation runtime insert(W.Confirmed proof)
        |> fun output->only "canonical Child parent" output.Runtime.requests in
      let output=deliver_sample runtime (sample parent((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_present_block{value=record;revision="new-parent-state"})) in match query with |Read.Outline_block _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch")))) in
      let root,round=List.find_map(fun response->match response.Runtime.payload with
        | Child_projection_ready{root;round;_}->Some(root,round)|_->None)output.responses |> Option.get in
      let ack=Production_runtime.child_projection_applied runtime ~root ~round ~presentation
        |> fun output->only "insert prefix ACK" output.Runtime.requests in
      let canonical=Production_runtime.receive_child_ack runtime ack (Ok())
        |> fun output->only "fresh child before status" output.Runtime.requests in
      let value=match W.confirmation_primary proof with Confirmed_block value->value|_->assert false in
      let pending=Production_runtime.receive_worker_read runtime ~request_id:canonical (Journal_graph_runtime.Query_result(W.Block_summary{block=root;after=None},value))
        |> fun output->only "original status attempt" output.Runtime.requests in
      let intent=match Runtime.worker_intent runtime (pending) session |> Result.get_ok with W.Mutation_intent intent->intent|_->assert false in
      Alcotest.(check bool) "original status binds" true(Runtime.bind_mutation runtime pending ~presentation ~intent:(W.Mutation_intent intent));
      ignore(Runtime.receive_mutation runtime pending W.Outcome_unknown);intent) in
  let business_command,chain=Production_runtime.retained_child_chains runtime |> fun values->Rrbvec.nth values 0 in
  Runtime.reset runtime;set_calendar runtime;
  seed_children_interest ~scope_revision:"scope-children-after-reopen" runtime;
  let retry=Production_runtime.submit ~child_chain:chain runtime (Journal_graph_request.Create_child business_command)
    |> fun output->only "restored Child insertion" output.Runtime.requests in
  let retried=match Runtime.worker_intent runtime (retry) session |> Result.get_ok with W.Mutation_intent intent->intent|_->assert false in
  Alcotest.(check string) "unknown Child keeps the complete original intent across reset"
    (Bytes.to_string(W.encode_durable_intent(W.Mutation_intent original)))(Bytes.to_string(W.encode_durable_intent(W.Mutation_intent retried)))
;;

let test_child_typed_insert_admission () =
  let runtime=child_identity_runtime() in
  let insert=child_identity_insert runtime in
  let actual=Runtime.worker_intent runtime insert Worker_producer.session |> Result.get_ok in
  let expected=W.mutation_intent Worker_producer.session
    ~mutation_id:(uuid "a1000000-0000-4000-a000-000000000081")
    (W.Insert_blocks{parent=block_uuid;roots=[{uuid=uuid "a1000000-0000-4000-9000-000000000081";title="Stable child";children=[]}];
      preconditions={blocks=[block_uuid,"block-detail-1"];pages=[];scopes=[Worker_pure_data.V2_children_scope block_uuid,"scope-children-1"]}}) |> Result.get_ok in
  Alcotest.(check bytes) "child insertion preserves its actual typed durable payload"
    (W.encode_durable_intent(W.Mutation_intent expected))(W.encode_durable_intent actual);
  Alcotest.(check bool) "mutation cannot be dispatched through read interface" true
    (Runtime.worker_read runtime insert=None)
;;
(* The public business reducer has no graph transport lifecycle. Exercise the
   narrow pure dispatcher boundary that owns synchronous admission refusal. *)
let test_typed_child_planning_refusal_retains_transport () =
  let module W=Journal_worker_coordination.Worker_api in
  List.iter(fun refusal->
    let runtime=child_identity_runtime() in
    let insert=child_identity_insert runtime in
    let _,_,projection,session=Coordination_test_fixture.fixture 5521L in
    let presentation=Option.get(W.selected projection) in
    let intent=match Runtime.worker_intent runtime (insert) session |> Result.get_ok with W.Mutation_intent intent->intent|_->assert false in
  let id=W.mutation_intent_id intent in
    Alcotest.(check bool) "typed child bound before admission" true
      (Runtime.bind_mutation runtime insert ~presentation ~intent:(W.Mutation_intent intent));
    let delivery=Journal_graph_transport.deliver ~runtime ~send:(fun _->refusal)
      {Runtime.requests=[insert];responses=[]} in
    Alcotest.(check (option string)) "retryable Child admission does not retire the graph" None delivery.error;
    Alcotest.(check bool) "pending Child keeps a visible retry owner" true
      (delivery.responses<>[]);
    let ordinary=Runtime.submit runtime(Find_block(Graph.Uuid.to_string unrelated_uuid)) in
    let mixed=Journal_graph_transport.deliver ~runtime ~send:(fun _->refusal)
      {Runtime.requests=insert::ordinary.requests;responses=[]} in
    Alcotest.(check bool) "ordinary failures in a mixed batch remain transport failures" true
      (mixed.error<>None);
    let retained=Production_runtime.retained_child_chains runtime in
    Alcotest.(check int) "original child remains owned after refused transport" 1(Rrbvec.length retained);
    let command,_=Rrbvec.nth retained 0 in
    Alcotest.(check string) "refused transport retains the original immutable mutation"
      (Graph.Uuid.to_string id)command.mutation_id;
    let late=Runtime.receive_mutation runtime insert W.Outcome_unknown in
    Alcotest.(check bool) "late completion from the earlier round cannot restart work" true
      (late.requests=[] && late.responses=[]))
    Journal_graph_transport.[Full;Not_ready;Stopping]
;;

let test_unbound_child_refusal_is_not_admitted () =
  let runtime=child_identity_runtime()in
  let request=child_identity_insert runtime in
  let delivery=Journal_graph_transport.deliver ~runtime ~send:(fun _->Journal_graph_transport.Not_ready)
    {Runtime.requests=[request];responses=[]}in
  Alcotest.(check bool) "known unsent child is not an unknown outcome"true
    (match delivery.responses with [{Runtime.payload=Child_not_admitted _}]->true|_->false);
  Alcotest.(check (option string)) "local refusal does not retire the graph"None delivery.error
;;

let test_child_error_continuations_retire () =
  let module W=Journal_worker_coordination.Worker_api in
  let runtime=child_identity_runtime()in
  let original=child_identity_insert runtime in
  let _,_,projection,session=Coordination_test_fixture.fixture 5521L in
  let presentation=Option.get(W.selected projection)in
  let request=ref original in
  for _=1 to 20 do
    let intent=match Runtime.worker_intent runtime (!request) session |> Result.get_ok with W.Mutation_intent intent->intent|_->assert false in
    Alcotest.(check bool) "actual continuation binds before its completion"true
      (Runtime.bind_mutation runtime !request ~presentation ~intent:(W.Mutation_intent intent));
    let previous= !request in
    let output=Runtime.mutation_waiting runtime previous "Transient confirmation failure"in
    if previous<>original then
      Alcotest.(check bool) "completed physical request no longer owns a route"true
        (Result.is_error(Runtime.worker_intent runtime previous session));
    let output=if output.requests<>[]then output else
      let pending=Production_runtime.take_insertion_recoveries runtime in
      Alcotest.(check int) "one delayed continuation only"1(Rrbvec.length pending);
      let root,recovery=Rrbvec.nth pending 0 in
      Production_runtime.resume_insertion_recovery runtime ~root recovery in
    request:=only "next original continuation"output.requests;
    Alcotest.(check bool) "public error transition issued its actual continuation"true
      (Result.is_ok(Runtime.worker_intent runtime !request session));
    Alcotest.(check int) "the immutable root remains owned"1
      (Rrbvec.length(Production_runtime.retained_child_chains runtime))
  done
;;

let test_task_catalog_generation_and_deltas () =
  let runtime = Runtime.create () in
  let initial = Runtime.start runtime in
  let outcome=graph_info_outcome ~journal_title_format:None in
  let output = deliver_sample runtime (sample initial outcome) in
  let catalog =
    List.find
      (fun (r : Graph.Uuid.t) ->
         match Runtime.worker_read runtime r with
         | Some(Runtime.Read{query=W.Task_statuses _;_}) -> true
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
    deliver_sample
      runtime
      (sample
         catalog
         ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok(F.task_status_catalog ~property_uuid:(Some page_uuid) ~default_status:(None) ~items:(choices) ~next:(Option.map(fun cursor->F.continuation ~owner:(F.read_budget_owner budget) ~budget ~key:(Read.query_key budget query) ~cursor)(None))) in match query with |Read.Task_statuses _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"))))
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
      (fun (r : Graph.Uuid.t) ->
         match Runtime.worker_read runtime r with
         | Some(Runtime.Read{query=W.Task_status_definitions _;_}) -> true
         | _ -> false)
      output.requests
  in
  Alcotest.(check bool)
    "no full catalog refresh for rename"
    false
    (List.exists
       (fun (r : Graph.Uuid.t) ->
          match Runtime.worker_read runtime r with
          | Some(Runtime.Read{query=W.Task_statuses _;_}) -> true
          | _ -> false)
       output.requests);
  let renamed =
    deliver_sample
      runtime
      (sample
         delta
         ((query_sample(fun(Read.Read_query(budget,query))->match query with |Read.Task_status_definitions _->Read.For_worker.answer budget query(Ok([ Some (definition 0 "Renamed") ]))|_->failwith "Expected task definitions"))))
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
    (deliver_sample
       runtime
       (sample
          newer
          ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok(F.task_status_catalog ~property_uuid:(Some page_uuid) ~default_status:(None) ~items:([ definition 0 "Newest" ]) ~next:(Option.map(fun cursor->F.continuation ~owner:(F.read_budget_owner budget) ~budget ~key:(Read.query_key budget query) ~cursor)(None))) in match query with |Read.Task_statuses _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch")))));
  let stale =
    deliver_sample
      runtime
      (sample
         reload
         ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok(F.task_status_catalog ~property_uuid:(Some page_uuid) ~default_status:(None) ~items:([ definition 0 "Stale" ]) ~next:(Option.map(fun cursor->F.continuation ~owner:(F.read_budget_owner budget) ~budget ~key:(Read.query_key budget query) ~cursor)(None))) in match query with |Read.Task_statuses _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"))))
  in
  Alcotest.(check int)
    "older catalog completion is ignored"
    0
    (List.length stale.responses);
  let old_failure =
    deliver_sample
      runtime
      (sample
         failing
         ((failed_sample (Read.Service_failed (("invalid-request")^": "^("Old catalog error"))))))
  in
  Alcotest.(check int)
    "old catalog failure is ignored"
    0
    (List.length old_failure.responses);
  let resync =
    Runtime.reconcile_signal
      runtime
      ~request_generation:99L
      (Worker_pure_data.Resync_required { generation = "generation-2"
         ; reason = "overflow"
         })
  in
  let graph =
    List.find (fun (r : Graph.Uuid.t) -> (match Runtime.worker_read runtime r with Some(Runtime.Read{query=W.Graph_info;_})->true|_->false)) resync.requests
  in
  let refreshed = deliver_sample runtime (sample graph outcome) in
  Alcotest.(check bool)
    "resync refreshes status catalog"
    true
    (List.exists
       (fun (r : Graph.Uuid.t) ->
          match Runtime.worker_read runtime r with
          | Some(Runtime.Read{query=W.Task_statuses _;_}) -> true
          | _ -> false)
       (resync.requests @ refreshed.requests));
  Runtime.reset runtime;
  let late =
    deliver_sample
      runtime
      (sample
         delta
         ((query_sample(fun(Read.Read_query(budget,query))->match query with |Read.Task_status_definitions _->Read.For_worker.answer budget query(Ok([ Some (definition 0 "Renamed") ]))|_->failwith "Expected task definitions"))))
  in
  Alcotest.(check int) "old graph catalog ignored" 0 (List.length late.responses)
;;

(* Exercise the production Runtime with valid bounded Worker pages. The fixture
   is ordered input, not a second implementation of Timeline projection. *)
type root_fixture =
  { owner : Graph.page
  ; roots : Worker_pure_data.block_record list
  ; descendants : (Graph.Uuid.t * Worker_pure_data.block_record list) list
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
      (fun (r : Worker_pure_data.block_record) ->
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

let drive_root_output ?(split_bytes = false) ?(filter_omitted = false) runtime fixtures (start : Runtime.output) =
  let queue = Queue.create () in
  let seen = ref []
  and outputs = ref start.responses in
  List.iter (fun r -> Queue.push r queue) start.requests;
  let children = List.concat_map (fun f -> f.descendants) fixtures in
  let ticks = ref 0 in
  while not (Queue.is_empty queue) do
    incr ticks;
    if !ticks > 1000 then Alcotest.fail "initial feed did not converge";
    let request : Graph.Uuid.t = Queue.pop queue in
    seen := Runtime.worker_read runtime request :: !seen;
    let outcome =
      match Worker_producer.transport runtime request with
      |Ok(Worker_producer.S.Coordination_query{read=Read.Read_query(budget,(Read.Timeline_read {query=Read.Timeline.Dates {from_day=sealed_from_day;through_day=sealed_through_day};_} as query));_})->
      let cursor=fixture_cursor budget query in
      let from_day=Read.For_worker.journal_day_value sealed_from_day in
      let through_day=Read.For_worker.journal_day_value sealed_through_day in
      let limit=Read.For_worker.read_budget_maximum_items budget in
        let fixtures = List.filter (fun f -> match f.owner.kind with Journal_page {journal_day} -> from_day <= journal_day && journal_day <= through_day | _ -> false) fixtures in
        let selected, next_cursor = root_slice fixtures limit cursor in
        (journal_sample ~items:((List.map
                (fun f ->
                   let journal_day =
                     match f.owner.kind with
                     | Journal_page { journal_day } -> journal_day
                     | _ -> assert false
                   in
                   Worker_pure_data.{ page = f.owner; journal_day; revision = "page-1" })
                selected : Worker_pure_data.journal_item list)) ~next:(next_cursor))
      |Ok(Worker_producer.S.Coordination_query{read=Read.Read_query(budget,(Read.Timeline_read {query=Read.Timeline.Roots page;_} as query));_})->
      let cursor=fixture_cursor budget query in
      let limit=Read.For_worker.read_budget_maximum_items budget in
        (match Production_runtime.worker_read runtime request with
         | Some (Production_runtime.Read {query=Journal_worker_coordination.Worker_api.Timeline_read {query=Journal_worker_coordination.Worker_api.Timeline.Roots _;_};_})->()
         | _->Alcotest.fail "feed roots bypassed typed coordinator");

        if split_bytes && limit > 2
        then
          (failed_sample (Read.Db_error(Logseq_db_worker.Error.create ~code:Response_too_large ~message:("Fixture encoded byte limit") ~details:[]|>Result.get_ok)))
        else (
          let fixture =
            List.find (fun f -> Graph.Uuid.equal page f.owner.uuid) fixtures
          in
          let selected, next_cursor = root_slice fixture.roots limit cursor in
          (tree_sample ~items:((List.map
                  (fun value ->
                     Worker_pure_data.{ value; revision = "root-1"; depth = 0; parent = page })
                  (if filter_omitted then List.filter (fun (value:Worker_pure_data.block_record)->value.block.title<>"__pbt-omitted-root__") selected else selected) : Worker_pure_data.tree_member list)) ~next:(next_cursor)))
      |Ok(Worker_producer.S.Coordination_query{read=Read.Read_query(budget,(Read.Timeline_read {query=Read.Timeline.Preview_children parent;_} as query));_})->
      let cursor=fixture_cursor budget query in
      let limit=Read.For_worker.read_budget_maximum_items budget in
        (match Production_runtime.worker_read runtime request with
         | Some (Production_runtime.Read {query=Journal_worker_coordination.Worker_api.Timeline_read {query=Journal_worker_coordination.Worker_api.Timeline.Preview_children _;_};_}) -> ()
         | _ -> Alcotest.fail "feed preview bypassed typed coordinator");
        Alcotest.(check bool) "preview requests stay bounded" true (limit <= 3);
        if split_bytes && limit > 1
        then
          (failed_sample (Read.Db_error(Logseq_db_worker.Error.create ~code:Response_too_large ~message:("Fixture preview byte limit") ~details:[]|>Result.get_ok)))
        else (
          let values = Option.value (List.assoc_opt parent children) ~default:[] in
          let selected, next_cursor = root_slice values limit cursor in
          (children_sample ~parent:(parent) ~scope_revision:("children-1") ~items:(List.map (fun value -> Worker_pure_data.{ value; revision = "child-1" }) selected) ~next:(next_cursor)))
      |Ok(Worker_producer.S.Coordination_query{read=Read.Read_query(_,Read.Timeline_check _);_})->
        check_sample
      |Ok(Worker_producer.S.Coordination_acknowledge_changes _)->
        (ack_sample ("generation-1") ("revision-2"))
      | _ -> Alcotest.fail "unexpected initial feed query"
    in
    let delivered = deliver_sample runtime (sample request outcome) in
    Alcotest.(check int)
      "duplicate completion is ignored"
      0
      (List.length (deliver_sample runtime (sample request outcome)).responses);
    outputs := !outputs @ delivered.responses;
    List.iter (fun r -> Queue.push r queue) delivered.requests
  done;
  !outputs, List.rev !seen
;;

let drive_roots ?(split_bytes = false) ?(filter_omitted = false) runtime fixtures start =
  let outputs, seen = drive_root_output ~split_bytes ~filter_omitted runtime fixtures start in
  let complete =
    List.filter_map
      (fun (r : Runtime.response) ->
         match r.payload with
         | Feed_loaded { feed; complete = true; _ } -> Some feed
         | _ -> None)
      outputs
  in
  if complete = [] then
    List.iter (fun (response:Runtime.response) -> match response.payload with
      | Feed_failed {failure=Projection_failure message;_}
      | Day_blocks_failed {failure=Projection_failure message;_}
      | Rejected (Projection_failure message) -> Format.eprintf "Timeline fixture failure: %s@." message
      | Feed_failed {failure=Worker_failure failure;_}
      | Day_blocks_failed {failure=Worker_failure failure;_} -> Format.eprintf "Timeline fixture worker failure: %s@." (Logseq_db_worker.Error.message failure.error)
      | _ -> ()) outputs;
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
      (fun (r : Worker_pure_data.block_record) ->
         { r with block = { r.block with parent = id; page = id } })
      fixture.roots
  in
  let descendants =
    List.map
      (fun (root, values) ->
         ( root
         , List.map
             (fun (r : Worker_pure_data.block_record) ->
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
let test_empty_today_sync_retires_initial_feed () =
  List.iter
    (fun history_first ->
       let runtime = Runtime.create ~localtime:Unix.gmtime () in
       set_priority_calendar runtime;
       let today = normal_journal_fixture 29 0 0
       and synced_today = normal_journal_fixture 29 3 0
       and older = normal_journal_fixture 30 1 0 in
       let dates = only "initial Today query" (initial_roots runtime 7L).requests in
       let tree =
         deliver_sample runtime
           (sample dates
              ((journal_sample ~items:(([ { page = today.owner; journal_day = 20260901; revision = "page-1" } ] : Worker_pure_data.journal_item list)) ~next:(Some (root_cursor 1)))))
         |> fun output -> only "empty Today roots" output.requests
       in
       let history =
         deliver_sample runtime
           (sample tree
              ((tree_sample ~items:(([] : Worker_pure_data.tree_member list)) ~next:(None))))
         |> fun output -> only "held initial history query" output.requests
       in
       let refresh =
         changed runtime
           (window ~pages:[ today.owner.uuid ]
              ~scopes:[ Worker_pure_data.V2_page_tree_interest today.owner.uuid ] ())
       in
       let fixtures = [ synced_today; older ] in
       let finish_history () =
         drive_root_output runtime fixtures { Runtime.requests = [ history ]; responses = [] }
         |> fst
       in
       let outputs =
         if history_first then (
           let history = finish_history () in
           let refreshed, _ = drive_root_output runtime fixtures refresh in
           history @ refreshed)
         else (
           let refreshed, _ = drive_root_output runtime fixtures refresh in
           refreshed @ finish_history ())
       in
       let final_feed =
         List.fold_left
           (fun feed (r : Runtime.response) ->
              match r.payload with
              | Feed_loaded { feed; complete = true; _ } -> Some feed
              | _ -> feed)
           None
           outputs
         |> function Some feed -> feed | None -> Alcotest.fail "No completed feed after sync"
       in
       let today_ids =
         List.concat_map
           (fun (day : Journal_graph_projection.day_feed) ->
              if day.page.id = Graph.Uuid.to_string today.owner.uuid
              then List.map (fun (e : Journal_graph_projection.timeline_entry) -> Journal_model.id e.block) day.entries
              else [])
           final_feed.days
       in
       Alcotest.(check (list string))
         (Printf.sprintf "synced Today survives initial history (history_first=%b)" history_first)
         (List.map (fun (r : Worker_pure_data.block_record) -> Graph.Uuid.to_string r.block.uuid) synced_today.roots)
         today_ids)
    [ true; false ]
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
                       (fun r ->
                          match r with
                          | Some(Runtime.Read{query=W.Timeline_read {query=W.Timeline.Roots page;_};_}) -> Some page
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
                   |> List.map (fun (r : Worker_pure_data.block_record) ->
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
                          ~scopes:[ Worker_pure_data.V2_page_tree_interest current.owner.uuid ]
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
                let failed =
                  deliver_sample
                    runtime
                    (sample
                       root
                       ((failed_sample ((if mode="retry" then Read.Service_failed "Normal remote structure revision changed" else Read.Stale_read "Normal remote structure revision changed")))))
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
                       (fun (r : Worker_pure_data.block_record) ->
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
      (fun (r : Graph.Uuid.t) ->
         match Runtime.worker_read runtime r with
         | Some(Runtime.Read{query=W.Outline_block {uuid=block;_};_}) -> Graph.Uuid.equal block block_id
         | _ -> false)
      output.requests
  in
  let complete runtime request value =
    deliver_sample
      runtime
      (sample
         request
         ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_present_block { value; revision = "changed-block" })) in match query with |Read.Outline_block _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"))))
  in
  let context_request runtime output page =
    List.find_opt
      (fun (r : Graph.Uuid.t) ->
         match Runtime.worker_read runtime r with
         | Some(Runtime.Read{query=W.Page {uuid=id;_};_}) -> Graph.Uuid.equal id page
         | _ -> false)
      output.Runtime.requests
  in
  let require_context runtime output page =
    match context_request runtime output page with
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
                let request = require_context runtime first target.owner.uuid in
                deliver_sample
                  runtime
                  (sample
                     request
                     ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_present_page { page = target.owner; revision = "new-page" })) in match query with |Read.Page _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch")))))
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
    let lookup = require_context runtime unresolved target.owner.uuid in
    let back =
      complete
        runtime
        (point runtime before.block.uuid)
        { before with block = { before.block with title = "Moved back normally" } }
    in
    ignore (only "new source observation" (updates back));
    let late =
      deliver_sample
        runtime
        (sample
           lookup
           ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_present_page { page = target.owner; revision = "old-target-page" })) in match query with |Read.Page _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"))))
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
    let lookup = require_context runtime unresolved target.owner.uuid in
    let missing =
      deliver_sample
        runtime
        (sample
           lookup
           ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_missing_page { uuid = target.owner.uuid; revision = "missing-page" })) in match query with |Read.Page _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"))))
    in
    Alcotest.(check int)
      "missing context never becomes a Timeline model"
      0
      (List.length (updates missing)));
  if !failures <> [] then Alcotest.fail (String.concat "\n" (List.rev !failures))
;;

let test_resync_retires_changed_points () =
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
  let complete runtime request value =
    deliver_sample
      runtime
      (sample
         request
         ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_present_block { value; revision = "point-before-resync" })) in match query with |Read.Outline_block _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"))))
  in
  let point ?(generation = "generation-1") runtime block_id =
    let pull =
      Runtime.reconcile_signal
        runtime
        ~request_generation:803L
        (Worker_pure_data.Changes_available { generation; through = "revision-2" })
    in
    let output =
      deliver_sample
        runtime
        (sample
           (only "point change pull" pull.requests)
           ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok(F.change_batch ~change_owner:(F.read_budget_owner budget) ~generation:(generation) ~from_exclusive:(None) ~through:("revision-2") ~windows:([ window ~blocks:[ block_id ] () ]) ~next:(None)) in match query with |Read.Changes _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"))))
    in
    List.find
      (fun (r : Graph.Uuid.t) ->
         match Runtime.worker_read runtime r with
         | Some(Runtime.Read{query=W.Outline_block {uuid=block;_};_}) -> Graph.Uuid.equal block block_id
         | _ -> false)
      output.requests
  in
  let run boundary pending_context move_back =
    let runtime = Runtime.create ~localtime:Unix.gmtime () in
    set_priority_calendar runtime;
    let source = normal_journal_fixture 29 2 0
    and target = normal_journal_fixture 0 0 0 in
    ignore (drive_roots runtime [ source ] (initial_roots runtime 801L));
    let before = List.hd source.roots in
    let moved =
      { before with
        block =
          { before.block with
            page = target.owner.uuid
          ; parent = target.owner.uuid
          ; title = "Before resync"
          }
      }
    in
    let old = point runtime before.block.uuid in
    let held =
      if pending_context
      then (
        let unresolved = complete runtime old moved in
        Alcotest.(check int)
          "unknown destination waits for metadata"
          0
          (List.length (updates unresolved));
        List.find
          (fun (r : Graph.Uuid.t) ->
             match Runtime.worker_read runtime r with
             | Some(Runtime.Read{query=W.Page {uuid=page;_};_}) -> Graph.Uuid.equal page target.owner.uuid
             | _ -> false)
          unresolved.requests)
      else old
    in
    let fresh =
      let value = if move_back then before else moved in
      { value with block = { value.block with title = "After resync" } }
    in
    let fixtures =
      if move_back
      then [ target; { source with roots = fresh :: List.tl source.roots } ]
      else
        [ { target with roots = [ fresh ] }
        ; { source with roots = List.tl source.roots }
        ]
    in
    bump_fixture_scopes [Worker_pure_data.V2_journal_index_interest;
      Worker_pure_data.V2_page_tree_interest source.owner.uuid;
      Worker_pure_data.V2_page_tree_interest target.owner.uuid];
    (match boundary with
     | `Reset -> Runtime.reset runtime
     | (`Push | `Pull) as boundary ->
       let start =
         match boundary with
         | `Push ->
           Runtime.reconcile_signal
             runtime
             ~request_generation:802L
             (Worker_pure_data.Resync_required { generation = "generation-2"
                ; reason = "retention overflow"
                })
         | `Pull ->
           let request=pull runtime in
           let module W=Worker_producer.W in
           let module I=Worker_producer.I in
           (match Production_runtime.worker_read runtime request with
            |Some(Production_runtime.Read read)->
              let operation=W.Query(Worker_producer.budget read.maximum_items,read.query) in
              let request_id=W.request_id request in
              let source=I.request Worker_producer.session ~request_id operation |> Result.get_ok in
              (match I.reply Worker_producer.session ~request_id operation
                (failed_sample (Read.Resync_required "retention overflow") source) with
               |Ok(W.Answered(Error(W.Resync_required reason)))->
                 Production_runtime.receive_worker_read ~resync_generation:802L runtime
                   ~request_id:request (Production_runtime.Changes_resync reason)
               |_->Alcotest.fail "actual typed Changes resync was not decoded")
            |_->Alcotest.fail "resync boundary did not retain its typed query")
       in
       (* Hold unrelated graph-info work; complete the real Feed and retained
          page requests before the previously issued point/context response. *)
       let start =
         { start with
           requests =
             List.filter
               (fun (r : Graph.Uuid.t) ->
                  match Runtime.worker_read runtime r with
                  | Some(Runtime.Read{query=W.Timeline_read {query=W.Timeline.Dates _;_};_}) | Some(Runtime.Read{query=W.Timeline_read {query=W.Timeline.Roots _;_};_}) | Some(Runtime.Read{query=W.Timeline_read {query=W.Timeline.Preview_children _;_};_}) | Some(Runtime.Read{query=W.Timeline_check _;_}) -> true
                  | _ -> false)
               start.requests
         }
       in
       let outputs, _ = drive_root_output runtime fixtures start in
       let published =
         List.concat_map
           (fun (r : Runtime.response) ->
              match r.payload with
              | Feed_loaded { feed; complete = true; _ } ->
                List.concat_map
                  (fun (d : Journal_graph_projection.day_feed) -> d.entries)
                  feed.days
              | Page_tree_reconciled { value; _ } -> value.entries
              | _ -> [])
           outputs
       in
       let latest =
         List.find
           (fun (e : Journal_graph_projection.timeline_entry) ->
              Journal_model.id e.block = Graph.Uuid.to_string before.block.uuid)
           published
       in
       Alcotest.(check string)
         "fresh roots publish before the late result"
         "After resync"
         (Journal_model.source latest.block);
       Alcotest.(check string)
         "fresh roots have the current page"
         (Graph.Uuid.to_string fresh.block.page)
         (Journal_model.page_id latest.block));
    let late =
      if pending_context
      then
        deliver_sample
          runtime
          (sample
             held
             ((query_sample (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_present_page
                   { page = target.owner; revision = "valid-late-page-metadata" })) in match query with |Read.Page _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"))))
      else complete runtime held moved
    in
    Alcotest.(check int)
      "retired observation cannot publish the saved old value"
      0
      (List.length late.responses);
    Alcotest.(check int)
      "retired point cannot start a new context lookup"
      0
      (List.length late.requests);
    if boundary <> `Reset
    then (
      let current =
        complete runtime (point ~generation:"generation-2" runtime fresh.block.uuid) fresh
      in
      let block = only "a new point after resync still publishes" (updates current) in
      Alcotest.(check string)
        "new observation is not retired"
        "After resync"
        (Journal_model.source block))
  in
  List.iter
    (fun boundary ->
       List.iter
         (fun pending_context ->
            List.iter
              (fun move_back ->
                 check
                   (Printf.sprintf
                      "%s context=%b moved-back=%b"
                      (if boundary = `Push then "push" else "pull")
                      pending_context
                      move_back)
                   (fun () -> run boundary pending_context move_back))
              [ false; true ])
         [ false; true ])
    [ `Push; `Pull ];
  List.iter
    (fun pending_context ->
       check (Printf.sprintf "reset context=%b" pending_context) (fun () ->
         run `Reset pending_context false))
    [ false; true ];
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
       (fun (r : Worker_pure_data.block_record) -> Graph.Uuid.to_string r.block.uuid)
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
  match Worker_producer.transport runtime (only "later roots read" output.requests) with
  |Ok(Worker_producer.S.Coordination_query{read=Read.Read_query(budget,(Read.Timeline_read {query=Read.Timeline.Roots _;_} as query));_})->
      let cursor=fixture_cursor budget query in
      let limit=Read.For_worker.read_budget_maximum_items budget in
    Alcotest.(check int) "continuation uses current thirty-item demand" 30 limit;
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

let test_date_cursor_recovery_is_bounded_and_owned () =
  (* Worker failures exercise recovery, not storage cursor invalidation. *)
  List.iter
    (fun ending ->
       let runtime = Runtime.create ~localtime:Unix.gmtime () in
       set_calendar ~clock:1_788_307_200. runtime;
       let first = normal_journal_fixture 29 1 0 in
       let older = normal_journal_fixture 30 1 0 in
       let same_day =
         let id = uuid "00000002-2026-0901-0000-000000000000" in
         let root = only "fixture root" first.roots in
         { owner = { first.owner with uuid = id }
         ; roots =
             [ { root with
                 block =
                   { root.block with
                     uuid = uuid "00000002-2026-0901-0000-000000000001"
                   ; parent = id
                   ; page = id
                   }
               } ]
         ; descendants = []
         }
       in
       let day fixture =
         match fixture.owner.kind with
         | Journal_page { journal_day } -> journal_day
         | _ -> assert false
       in
       let dates request fixtures next_cursor =
         deliver_sample runtime (sample request ((journal_sample ~items:((List.map (fun f -> ({ page = f.owner; journal_day = day f
                                            ; revision = "page-1" } : Worker_pure_data.journal_item))
                   fixtures : Worker_pure_data.journal_item list)) ~next:(next_cursor))))
       in
       let listing ?(quiet = true) (output : Production_runtime.output) cursor through =
         if quiet then
           Alcotest.(check int) "date recovery publishes nothing" 0
             (List.length output.responses);
         let request = only "one date catalog read" output.requests in
         (match Worker_producer.transport runtime request with
          |Ok(Worker_producer.S.Coordination_query{read=Read.Read_query(budget,(Read.Timeline_read {query=Read.Timeline.Dates {through_day=sealed_through_day;_};_} as query));_})->
      let actual=fixture_cursor budget query in
      let through_day=Read.For_worker.journal_day_value sealed_through_day in
      let limit=Read.For_worker.read_budget_maximum_items budget in
            Alcotest.(check bool) "date continuation" true (actual = cursor);
            Alcotest.(check int) "date query bound" through through_day;
            Alcotest.(check int) "bounded metadata packet" 1 limit
          | _ -> Alcotest.fail "expected only a date catalog read");
         request
       in
       let complete_date request fixture next_cursor expected_limit through =
         let tree = dates request [ fixture ] next_cursor
           |> fun output -> only "date root read" output.requests in
         (match Runtime.worker_read runtime tree with
          | Some(Runtime.Read{query=W.Timeline_read {query=W.Timeline.Roots _;_};maximum_items=limit;_}) ->
            Alcotest.(check int) "retains remaining root quota" expected_limit limit
          | _ -> Alcotest.fail "expected root query");
         let root = only "fixture root" fixture.roots in
         let preview =
           deliver_sample runtime (sample tree ((tree_sample ~items:(([ { value = root; revision = "root-1"; depth = 0
                           ; parent = fixture.owner.uuid } ] : Worker_pure_data.tree_member list)) ~next:(None))))
           |> fun output -> only "root preview" output.requests
         in
         let output = deliver_sample runtime (sample preview ((children_sample ~parent:(root.block.uuid) ~scope_revision:("children-1") ~items:([]) ~next:(None)))) in
         listing ~quiet:false output next_cursor through
       in
       let stale request =
         deliver_sample runtime (sample request ((failed_sample (Read.Stale_read ("The read continuation is no longer current.")))))
       in
       (* Recovery rereads the oldest observed date inclusively. *)
       let recover request =
         let retry = listing (stale request) None 20260901 in
         let duplicate = stale request in
         Alcotest.(check int) "duplicate failure cannot retry" 0
           (List.length duplicate.requests + List.length duplicate.responses);
         retry
       in
       let replay request fixtures cursor =
         listing (dates request fixtures (Some cursor)) (Some cursor) 20260901
       in
       let initial =
         Runtime.submit runtime (Journal_graph_request.Load_feed
             { cursor = None; root_limit = 4; day_limit = 1; request_generation = 77L })
         |> fun output -> listing ~quiet:false output None 99991231
       in
       let next = complete_date initial first (Some (root_cursor 1)) 4 99991231 in
       let next = replay (recover next) [ first ] (root_cursor 2) in
       let next = complete_date next same_day (Some (root_cursor 3)) 3 20260901 in
       let next = replay (recover next) [ first ] (root_cursor 4) in
       let next = replay next [ same_day ] (root_cursor 5) in
       let next = complete_date next older (Some (root_cursor 6)) 2 20260901 in
       match ending with
       | `Complete ->
         let output = dates next [] None in
         (match (only "recovered feed completion" output.responses).payload with
          | Feed_loaded { request_generation = 77L; feed; complete = true } ->
            Alcotest.(check (list string)) "same-day pages once, consumed roots once"
              (List.map (fun f -> Graph.Uuid.to_string (only "fixture root" f.roots).block.uuid)
                 [ first; same_day; older ])
              (List.concat_map (fun (day : Journal_graph_projection.day_feed) ->
                   List.map (fun (entry : Journal_graph_projection.timeline_entry) ->
                       Journal_model.id entry.block) day.entries) feed.days)
          | _ -> Alcotest.fail "date recovery lost feed ownership")
       | `Exhaust ->
         let output = stale next in
         Alcotest.(check int) "finite recovery budget" 0 (List.length output.requests);
         (match (only "terminal stale cursor failure" output.responses).payload with
          | Feed_failed { request_generation = 77L; failure = Worker_failure failure } ->
            Alcotest.(check string) "terminal operation retained" "listTimelineDates"
              failure.operation
          | _ -> Alcotest.fail "retry exhaustion lost failure ownership")
       | `Supersede ->
         ignore (Runtime.submit runtime (Journal_graph_request.Load_feed
             { cursor = None; root_limit = 4; day_limit = 1; request_generation = 78L }));
         let output = dates next [] None in
         Alcotest.(check int) "superseded recovery cannot publish or continue" 0
           (List.length output.requests + List.length output.responses))
    [ `Complete; `Exhaust; `Supersede ]
;;

let test_later_date_cursor_no_progress_settles () =
  let runtime=Runtime.create ~localtime:Unix.gmtime () in
  set_calendar runtime;
  let fixture=root_fixture 0 31 0 in
  let feed,_=drive_roots runtime [fixture;root_fixture 1 1 0] (initial_roots runtime 77L) in
  let day=List.hd feed.days in
  let root=Runtime.submit runtime (Journal_graph_request.Load_day_blocks
      {day=day.page.day;after=day.continuation;limit=30;request_generation=78L})
    |> fun o->only "later tail query" o.requests in
  let output=deliver_sample runtime (sample root ((tree_sample ~items:(([] : Worker_pure_data.tree_member list)) ~next:(None)))) in
  let listing=only "older date query" output.requests in
  let cursor=root_cursor 1 in
  let output=deliver_sample runtime (sample listing ((journal_sample ~items:(([] : Worker_pure_data.journal_item list)) ~next:(Some cursor)))) in
  let repeated=only "next date packet" output.requests in
  let output=deliver_sample runtime (sample repeated ((journal_sample ~items:(([] : Worker_pure_data.journal_item list)) ~next:(Some cursor)))) in
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
             match r with
             | Some(Runtime.Read{query=W.Timeline_read {query=W.Timeline.Dates _;_};_}) -> true
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
      (fun i (r : Worker_pure_data.block_record) ->
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
             match r with
             | Some(Runtime.Read{query=W.Timeline_read {query=W.Timeline.Preview_children _;_};_}) -> true
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
    deliver_sample
      runtime
      (sample old ((journal_sample ~items:(([] : Worker_pure_data.journal_item list)) ~next:(None))))
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
  match Runtime.worker_read runtime (only "older dates still use existing request" start.requests) with
  | Some(Runtime.Read{query=W.Timeline_read {query=W.Timeline.Dates {through_day;_};_};maximum_items=limit;_}) ->
    Alcotest.(check int) "older metadata quota remains seven" 7 limit;
    Alcotest.(check bool) "calendar upper bound remains" true (W.journal_day 20260831=Ok through_day)
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
      (window ~scopes:[ Worker_pure_data.V2_page_tree_interest (List.hd fixtures).owner.uuid ] ())
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
      (window ~scopes:[ Worker_pure_data.V2_page_tree_interest fixture.owner.uuid ] ())
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

let fixture_root_tree runtime fixture (request : Graph.Uuid.t) =
  match Worker_producer.transport runtime request with
  |Ok(Worker_producer.S.Coordination_query{read=Read.Read_query(budget,(Read.Timeline_read {query=Read.Timeline.Roots page;_} as query));_})->
      let cursor=fixture_cursor budget query in
      let limit=Read.For_worker.read_budget_maximum_items budget in
    let selected, next_cursor = root_slice fixture.roots limit cursor in
    (tree_sample ~items:((List.map (fun value ->
          Worker_pure_data.{ value; revision = "root-1"; depth = 0; parent = page }) selected : Worker_pure_data.tree_member list)) ~next:(next_cursor))
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
    List.filter_map (fun (r : Worker_pure_data.block_record) ->
      if Graph.Uuid.equal r.block.uuid deleted.block.uuid then None
      else if Graph.Uuid.equal r.block.uuid edited.block.uuid then
        Some { r with block = { r.block with title = "Remote suffix edit" } }
      else Some r) fixture.roots } in
  let refresh =
    if resync then (
      bump_fixture_scopes [Worker_pure_data.V2_page_tree_interest fixture.owner.uuid;
        Worker_pure_data.V2_journal_index_interest];
      Runtime.reconcile_signal runtime ~request_generation:90L
        (Worker_pure_data.Resync_required { generation = "generation-2"
           ; reason = "overflow" }) |> settle_fixture_checks runtime)
    else changed runtime (window ~scopes:
        [ Worker_pure_data.V2_page_tree_interest fixture.owner.uuid
        ; Worker_pure_data.V2_journal_index_interest ] ())
  in
  let tree = List.find (fun (r : Graph.Uuid.t) -> match Runtime.worker_read runtime r with
      | Some(Runtime.Read{query=W.Timeline_read {query=W.Timeline.Roots _;_};_}) -> true | _ -> false) refresh.requests in
  let dates = List.find (fun (r : Graph.Uuid.t) -> match Runtime.worker_read runtime r with
      | Some(Runtime.Read{query=W.Timeline_read {query=W.Timeline.Dates _;_};_}) -> true | _ -> false) refresh.requests in
  let held = match stage with
    | `Root -> { Runtime.requests = [tree]; responses = [] }
    | `Preview | `Continuation ->
      deliver_sample runtime (sample tree (fixture_root_tree runtime fresh tree))
  in
  let held = match stage with
    | `Root | `Preview -> held
    | `Continuation ->
      let rec finish_previews (output : Runtime.output) =
        let request = only "one retained refresh continuation" output.requests in
        match Runtime.worker_read runtime request with
        | Some(Runtime.Read{query=W.Timeline_read {query=W.Timeline.Roots _;_};_}) -> output
        | Some(Runtime.Read{query=W.Timeline_read {query=W.Timeline.Preview_children parent;_};_}) ->
          finish_previews (deliver_sample runtime (sample request
              ((children_sample ~parent:(parent) ~scope_revision:("children-1") ~items:([]) ~next:(None)))))
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

let test_scope_change_restarts_without_old_prefix () =
  let runtime = Runtime.create ~localtime:Unix.gmtime () in
  set_calendar runtime;
  let fixture = root_fixture 0 4 0 in
  let dates = load_feed runtime in
  let day = match fixture.owner.kind with Journal_page {journal_day} -> journal_day | _ -> assert false in
  let roots = deliver_sample runtime (sample dates
      (journal_sample ~items:[Worker_pure_data.{page=fixture.owner;journal_day=day;revision="page"}] ~next:None))
    |> fun output -> only "first root packet" output.requests in
  let partial = deliver_sample runtime (sample roots
      (tree_sample ~items:(List.take 2 fixture.roots |> List.map (fun value ->
          Worker_pure_data.{value;revision="old-root";depth=0;parent=fixture.owner.uuid}))
         ~next:(Some (root_cursor 2)))) |> finish_previews runtime ~children:[] in
  let continuation = only "continued root packet" partial.requests in
  let restarted = Worker_producer.deliver runtime continuation
      (query_sample (fun (Read.Read_query (budget,query)) -> match query with
        | Read.Timeline_read _ -> Read.For_worker.answer budget query
            (Ok (Error (Read.Timeline.Invalidated Scope_changed)))
        | _ -> failwith "Expected Timeline paging")) in
  Alcotest.(check int) "invalidated prefix cannot publish" 0 (List.length restarted.responses);
  let removed = List.hd fixture.roots in
  let fresh = {fixture with roots=List.tl fixture.roots} in
  let feed, _ = drive_roots runtime [fresh] restarted in
  let entries = (only "fresh day" feed.days).entries in
  Alcotest.(check int) "fresh scope contains exactly the new roots" 3 (List.length entries);
  Alcotest.(check bool) "old prefix was discarded rather than appended" false
    (List.exists (fun (entry:Journal_graph_projection.timeline_entry) ->
      Journal_model.id entry.block = Graph.Uuid.to_string removed.block.uuid) entries)
;;

let test_continuation_scope_change_uses_stale_recovery () =
  let runtime = Runtime.create ~localtime:Unix.gmtime () in
  set_calendar runtime;
  let fixture = root_fixture 0 40 0 in
  let feed, _ = drive_roots runtime [fixture] (initial_roots runtime 77L) in
  let day = List.hd feed.days in
  let request = Runtime.submit runtime (Journal_graph_request.Load_day_blocks
      {day=day.page.day;after=day.continuation;limit=30;request_generation=78L})
    |> fun output -> only "continued day request" output.requests in
  let output = Worker_producer.deliver runtime request
      (query_sample (fun (Read.Read_query (budget,query)) -> match query with
        | Read.Timeline_read _ -> Read.For_worker.answer budget query
            (Ok (Error (Read.Timeline.Invalidated Scope_changed)))
        | _ -> failwith "Expected Timeline paging")) in
  Alcotest.(check bool) "published prefix requires stale recovery" true
    (List.exists (fun (r:Runtime.response) -> match r.payload with
      | Day_blocks_failed {stale_cursor=true;_} -> true | _ -> false) output.responses);
  Alcotest.(check int) "no internal replacement can append to the old prefix" 0
    (List.length output.requests)
;;

let test_reassigned_journal_day_reprojects_entries () =
  let runtime = Runtime.create ~localtime:Unix.gmtime () in
  set_calendar runtime;
  let fixture = root_fixture 0 1 0 in
  ignore (drive_roots runtime [fixture] (initial_roots runtime 77L));
  let day = 20260929 in
  let fresh = {fixture with owner={fixture.owner with kind=Journal_page {journal_day=day}}} in
  let feed, _ = drive_roots runtime [fresh]
      (changed runtime (window ~scopes:[Worker_pure_data.V2_journal_index_interest] ())) in
  let loaded = only "reassigned day" feed.days in
  Alcotest.(check int) "entry follows the current journal page context" day
    (Journal_model.journal_day (only "reassigned entry" loaded.entries).block)
;;

let test_accumulated_sibling_scope_change_converges () =
  let runtime = Runtime.create ~localtime:Unix.gmtime () in
  set_calendar runtime;
  let first = root_fixture 0 1 0 and second = root_fixture 1 1 0 in
  let dates = load_feed runtime in
  let items = List.map (fun fixture ->
    let journal_day = match fixture.owner.kind with Journal_page {journal_day} -> journal_day | _ -> assert false in
    Worker_pure_data.{page=fixture.owner;journal_day;revision="page"}) [first;second] in
  let output = Worker_producer.deliver runtime dates (journal_sample ~items ~next:None) in
  let root = only "first root" output.requests in
  let output = Worker_producer.deliver runtime root
    (tree_sample ~items:[Worker_pure_data.{value=List.hd first.roots;revision="root";depth=0;parent=first.owner.uuid}] ~next:None)
    |> fun output -> Worker_producer.deliver runtime (only "preview" output.requests)
      (children_sample ~parent:(List.hd first.roots).block.uuid ~scope_revision:"children" ~items:[] ~next:None) in
  let output = Worker_producer.deliver runtime (only "first assembly check" output.requests) check_sample in
  let output = Worker_producer.deliver runtime (only "second root" output.requests)
    (tree_sample ~items:[Worker_pure_data.{value=List.hd second.roots;revision="root";depth=0;parent=second.owner.uuid}] ~next:None)
    |> fun output -> Worker_producer.deliver runtime (only "preview" output.requests)
      (children_sample ~parent:(List.hd second.roots).block.uuid ~scope_revision:"children" ~items:[] ~next:None) in
  bump_fixture_scopes [Worker_pure_data.V2_page_tree_interest first.owner.uuid];
  let output = Worker_producer.deliver runtime (only "second assembly check" output.requests) check_sample in
  Alcotest.(check bool) "stale accumulated scan restarts before publication" true
    (List.exists (fun request -> match Runtime.worker_read runtime request with
      | Some(Runtime.Read {query=W.Timeline_read {query=W.Timeline.Dates _;_};_}) -> true
      | _ -> false) output.requests);
  let fresh = {first with roots=[]} in
  let feed, _ = drive_roots runtime [fresh;second] output in
  Alcotest.(check bool) "stale accumulated sibling data is replaced" false
    (List.exists (fun (day:Journal_graph_projection.day_feed) ->
      List.exists (fun (entry:Journal_graph_projection.timeline_entry) ->
        Journal_model.id entry.block = Graph.Uuid.to_string (List.hd first.roots).block.uuid) day.entries) feed.days)
;;

let test_dates_change_preserves_retained_root_prefix () =
  let runtime = Runtime.create ~localtime:Unix.gmtime () in
  let fixture = root_fixture 0 90 0 in
  load_ninety_roots runtime fixture;
  let feed, seen = drive_roots runtime [fixture]
      (changed runtime (window ~scopes:[Worker_pure_data.V2_journal_index_interest] ())) in
  let day = only "date refresh preserves its retained day" feed.days in
  Alcotest.(check (list string)) "date refresh retains the original root prefix"
    (List.take 30 fixture.roots |> List.map (fun (r:Worker_pure_data.block_record) -> Graph.Uuid.to_string r.block.uuid))
    (List.map (fun (e:Journal_graph_projection.timeline_entry) -> Journal_model.id e.block) day.entries);
  Alcotest.(check int) "unchanged roots and previews require no reread" 0
    (List.length (List.filter (function
      | Some(Runtime.Read{query=W.Timeline_read {query=W.Timeline.Roots _;_};_})
      | Some(Runtime.Read{query=W.Timeline_read {query=W.Timeline.Preview_children _;_};_}) -> true
      | _ -> false) seen))
;;

let pending_retained_assembly_check runtime fixture =
  let day = match fixture.owner.kind with Journal_page {journal_day} -> journal_day | _ -> assert false in
  let root = Runtime.submit runtime (Journal_graph_request.Load_day_blocks
      {day;after=None;limit=1;request_generation=990L})
    |> fun output -> only "retained root request" output.requests in
  let preview = Worker_producer.deliver runtime root
      (tree_sample ~items:[Worker_pure_data.{value=List.hd fixture.roots;revision="root";depth=0;parent=fixture.owner.uuid}]
         ~next:None) |> fun output -> only "retained preview request" output.requests in
  Worker_producer.deliver runtime preview
    (children_sample ~parent:(List.hd fixture.roots).block.uuid ~scope_revision:"children" ~items:[] ~next:None)
  |> fun output -> only "retained assembly check" output.requests
;;

(* Runtime owns Timeline interests and serialized read eligibility. These pure
   calls use its public planner/completion boundary, without an effect runner. *)
let retirement_probe runtime =
  Runtime.reconcile_signal runtime ~request_generation:990L
    (Worker_pure_data.Resync_required {generation="generation-1";reason="retirement probe"})
;;

let receipt_count runtime (output : Runtime.output) =
  List.fold_left (fun count request -> match Runtime.worker_read runtime request with
    | Some (Runtime.Read {query=W.Timeline_check receipts;_}) -> count + Rrbvec.length receipts
    | _ -> count) 0 output.requests
;;

let probe_receipts runtime =
  let output = retirement_probe runtime in
  let count = receipt_count runtime output in
  List.iter (Runtime.abandon runtime) output.requests;
  count
;;

let retained_feed feed =
  let module T = Journal_timeline_state in
  T.empty ~today:20260901
  |> fun state -> T.begin_request state ~generation:989L (T.Feed {cursor=None})
  |> fun state -> T.apply_feed state ~generation:989L feed
;;

let test_retirement_preserves_hidden_rows () =
  let module T = Journal_timeline_state in
  let runtime = Runtime.create ~localtime:Unix.gmtime () in
  set_calendar runtime;
  let first = root_fixture 0 2 0 and second = root_fixture 1 1 0 in
  let feed,_ = drive_roots runtime [first;second] (initial_roots runtime 989L) in
  let before = retained_feed feed in
  Alcotest.(check int) "initial retained receipts" 6 (probe_receipts runtime);
  let second_page = List.find (fun (d:Journal_graph_projection.day_feed) ->
    d.page.id = Graph.Uuid.to_string second.owner.uuid) feed.days in
  let hidden = Journal_graph_projection.block ~page:second_page.page ~revision:"hidden"
      ~child_count:0 ~time_context:{localtime=Unix.gmtime}
      {(List.hd second.roots).block with title=""} |> Result.get_ok in
  let after = T.replace_block before hidden
    |> fun state -> T.remove_block state ~block_id:(Graph.Uuid.to_string (List.hd first.roots).block.uuid) in
  ignore (Runtime.retire_timeline runtime ~before ~after);
  Alcotest.(check bool) "hidden placeholder remains addressable" true
    (Option.is_some (T.find_block after ~block_id:(Journal_model.id hidden)));
  Alcotest.(check int) "only the removed root preview is retired" 5 (probe_receipts runtime);
  ignore (Runtime.retire_timeline runtime ~before:after ~after:(T.observe_visible_range after ~first_index:0 ~last_exclusive:1));
  Alcotest.(check int) "scroll demand preserves retained proofs" 5 (probe_receipts runtime)
;;

let test_retirement_removes_pages_and_late_installs () =
  let module T = Journal_timeline_state in
  let runtime = Runtime.create ~localtime:Unix.gmtime () in
  set_calendar runtime;
  let first = root_fixture 0 1 0 and second = root_fixture 1 1 0 in
  let feed,_ = drive_roots runtime [first;second] (initial_roots runtime 989L) in
  let before = retained_feed feed in
  let old = pending_retained_assembly_check runtime first in
  let reply = Worker_producer.transport runtime old |> Result.get_ok |> check_sample in
  let after = T.empty ~today:20260901 in
  ignore (Runtime.retire_timeline runtime ~before ~after);
  let probe = retirement_probe runtime in
  Alcotest.(check int) "all receipts retire with the absent window" 0 (receipt_count runtime probe);
  let roots = List.filter (fun request -> match Runtime.worker_read runtime request with
    | Some (Runtime.Read {query=W.Timeline_read {query=W.Timeline.Roots _;_};_}) -> true
    | _ -> false) probe.requests in
  Alcotest.(check int) "absent page interests schedule no root reads" 0 (List.length roots);
  List.iter (Runtime.abandon runtime) probe.requests;
  ignore (drive_roots runtime [first;second] (initial_roots runtime 991L));
  let late = Worker_producer.deliver runtime old (fun _ -> reply) in
  Alcotest.(check int) "retired check cannot install into the same page identity" 0 (List.length late.responses);
  Alcotest.(check int) "retired check creates no replacement requests" 0 (List.length late.requests);
  Alcotest.(check int) "reloaded receipts are not inflated by old proofs" 5 (probe_receipts runtime);
  Runtime.reset runtime;
  Alcotest.(check int) "owner reset retains no receipts" 0 (probe_receipts runtime)
;;

let test_retirement_fences_page_aba_without_losing_siblings () =
  let runtime = Runtime.create ~localtime:Unix.gmtime () in
  set_calendar runtime;
  let first = root_fixture 0 1 0 and second = root_fixture 1 1 0 in
  let feed,_ = drive_roots runtime [first;second] (initial_roots runtime 989L) in
  let before = retained_feed feed in
  let old = only "held changed root read" (hydration_requests runtime
    (changed runtime (window ~scopes:[Worker_pure_data.V2_page_tree_interest first.owner.uuid] ()))) in
  let packet = sample old (fixture_root_tree runtime first old) in
  let after = retained_feed {feed with days=List.filter
    (fun (day:Journal_graph_projection.day_feed) -> day.page.id=Graph.Uuid.to_string second.owner.uuid) feed.days} in
  ignore (Runtime.retire_timeline runtime ~before ~after);
  let probe = retirement_probe runtime in
  Alcotest.(check int) "surviving page keeps its root and preview proofs" 3 (receipt_count runtime probe);
  Alcotest.(check int) "retired interest creates no replacement root request" 0
    (List.length (List.filter (fun request -> match Runtime.worker_read runtime request with
      | Some (Runtime.Read {query=W.Timeline_read {query=W.Timeline.Roots _;_};_}) -> true
      | _ -> false) probe.requests));
  List.iter (Runtime.abandon runtime) probe.requests;
  ignore (drive_roots runtime [first;second] (initial_roots runtime 991L));
  let late = deliver_sample runtime packet in
  Alcotest.(check int) "old page incarnation cannot publish" 0 (List.length late.responses);
  Alcotest.(check int) "old page incarnation cannot continue previews" 0 (List.length late.requests)
;;

let test_replaced_date_query_retires_old_receipts () =
  let runtime = Runtime.create ~localtime:Unix.gmtime () in
  set_calendar runtime;
  let fixtures = List.init 3 (fun i -> root_fixture i 1 0) in
  let feed,_ = drive_roots runtime fixtures
    (Runtime.submit runtime (Journal_graph_request.Load_feed
      {cursor=None;root_limit=2;day_limit=7;request_generation=989L})) in
  Alcotest.(check int) "two retained pages and their date query" 5 (probe_receipts runtime);
  ignore (drive_roots runtime fixtures
    (Runtime.submit runtime (Journal_graph_request.Load_feed
      {cursor=feed.continuation;root_limit=30;day_limit=7;request_generation=990L})));
  Alcotest.(check int) "replacement date query keeps one receipt and all three pages" 7 (probe_receipts runtime)
;;

let hold_retirement_reply runtime request produce =
  match Runtime.worker_read runtime request with
  | Some (Runtime.Read {query;maximum_items}) ->
    let budget = Worker_producer.budget maximum_items in
    let operation = W.Query (budget,query) in
    let source = Worker_producer.I.request Worker_producer.session
      ~request_id:(W.request_id request) operation |> Result.get_ok in
    (match Worker_producer.I.reply Worker_producer.session
      ~request_id:(W.request_id request) operation (produce source) with
     | Ok (W.Answered (Ok value)) -> Runtime.Query_result (query,value)
     | _ -> Alcotest.fail "could not hold the original typed retirement reply")
  | _ -> Alcotest.fail "retirement reply needs a dispatched read"
;;

let test_full_retirement_revokes_catalog kind () =
  let runtime = Runtime.create ~localtime:Unix.gmtime () in
  set_calendar runtime;
  let fixtures = List.init 2 (fun i -> root_fixture i 1 0) in
  let feed,_ = drive_roots runtime fixtures (initial_roots runtime 989L) in
  let before = retained_feed feed in
  let journal fixture = Worker_pure_data.{page=fixture.owner;
    journal_day=(match fixture.owner.kind with Journal_page {journal_day}->journal_day|_->assert false);
    revision="page-1"} in
  let old,produce = match kind with
    | `Dates -> only "held catalog" (initial_roots runtime 990L).requests,
      journal_sample ~items:(List.map journal fixtures) ~next:None
    | `Today ->
      let dates = only "future catalog" (initial_roots runtime 990L).requests in
      let output = Worker_producer.deliver runtime dates
        (journal_sample ~items:[journal (List.hd fixtures)] ~next:(Some (root_cursor 1))) in
      only "priority Today read" output.requests,
      journal_sample ~items:[] ~next:None
    | `Publish ->
      let output = retirement_probe runtime in
      let check = only "retained window validation" (List.filter (fun request ->
        match Runtime.worker_read runtime request with
        | Some (Runtime.Read {query=W.Timeline_check _;_})->true|_->false) output.requests) in
      List.iter (fun request -> if request<>check then Runtime.abandon runtime request) output.requests;
      let dates = Worker_producer.deliver runtime check check_sample
        |> fun output -> only "validated prefix catalog" output.requests in
      let output = Worker_producer.deliver runtime dates
        (journal_sample ~items:(List.map journal fixtures) ~next:None) in
      only "reused prefix publication check" output.requests,check_sample
  in
  let reply = hold_retirement_reply runtime old produce in
  ignore (Runtime.retire_timeline runtime ~before ~after:(Journal_timeline_state.empty ~today:20260901));
  Alcotest.(check bool) "full retirement releases the original request and payload" true
    (Runtime.worker_read runtime old=None);
  let late = Runtime.receive_worker_read runtime ~request_id:old reply in
  Alcotest.(check int) "retired traversal emits no requests" 0 (List.length late.requests);
  Alcotest.(check int) "retired traversal installs no projection" 0 (List.length late.responses);
  Alcotest.(check int) "retired traversal restores no receipts" 0 (probe_receipts runtime)
;;

let retirement_outline_count runtime (output:Runtime.output) =
  List.fold_left (fun count request -> match Runtime.worker_read runtime request with
    | Some (Runtime.Read {query=W.Outline_block _;_})->count+1|_->count) 0 output.requests
;;

let test_retirement_preserves_cross_page_observations () =
  let module T = Journal_timeline_state in
  let runtime = Runtime.create ~localtime:Unix.gmtime () in
  set_calendar runtime;
  let first = root_fixture 0 1 0 and second = root_fixture 1 1 0 in
  let feed,_ = drive_roots runtime [first;second] (initial_roots runtime 989L) in
  let before = retained_feed feed in
  let original = List.hd first.roots in
  let moved = {original with block={original.block with page=second.owner.uuid;parent=second.owner.uuid}} in
  let fresh,_ = drive_roots runtime
    [{first with roots=[];descendants=[]};{second with roots=moved::second.roots}]
    (initial_roots runtime 990L) in
  let entry = List.find (fun (entry:Journal_graph_projection.timeline_entry) ->
    Journal_model.id entry.block=Graph.Uuid.to_string original.block.uuid)
    (List.concat_map (fun (day:Journal_graph_projection.day_feed)->day.entries) fresh.days) in
  let after = T.replace_timeline_entry before entry in
  ignore (Runtime.retire_timeline runtime ~before ~after);
  Alcotest.(check bool) "moved root remains retained on B" true
    (Option.exists (fun block -> Journal_model.page_id block=Graph.Uuid.to_string second.owner.uuid)
      (T.find_block after ~block_id:(Journal_model.id entry.block)));
  let output = changed runtime (window ~blocks:[original.block.uuid] ()) in
  Alcotest.(check int) "B observations still schedule the moved block point read" 1
    (retirement_outline_count runtime output)
;;

let test_retirement_removes_preview_only_observations () =
  let module T = Journal_timeline_state in
  let runtime = Runtime.create ~localtime:Unix.gmtime () in
  set_calendar runtime;
  let fixture = root_fixture 0 1 3 in
  let feed,_ = drive_roots runtime [fixture] (initial_roots runtime 989L) in
  let before = retained_feed feed in
  let entry = List.hd (List.hd feed.days).entries in
  let removed = List.hd entry.child_summaries in
  let replacement = {entry with child_summaries=List.tl entry.child_summaries} in
  let after = T.replace_timeline_entry before replacement in
  ignore (Runtime.retire_timeline runtime ~before ~after);
  Alcotest.(check int) "retained parent keeps current preview receipt coverage" 3 (probe_receipts runtime);
  Alcotest.(check bool) "preview replacement keeps the parent" true
    (T.find_block after ~block_id:(Journal_model.id entry.block)=Some entry.block);
  let output = changed runtime (window ~blocks:[uuid removed.block_id] ()) in
  Alcotest.(check int) "removed preview child no longer schedules point reads" 0
    (retirement_outline_count runtime output);
  let kept = List.hd replacement.child_summaries in
  let output = changed runtime (window ~blocks:[uuid kept.block_id] ()) in
  Alcotest.(check int) "remaining preview child keeps its observation" 1
    (retirement_outline_count runtime output)
;;

let retirement_change_token root scopes =
  let module C = Journal_worker_coordination.Worker_pure_coordinator in
  let budget = Worker_producer.budget Worker_pure_data.maximum_page_size in
  let operation = W.Query (budget,W.Changes {generation="generation-1";after=None}) in
  let ticket,planned = C.request Worker_producer.state Worker_producer.session operation |> Result.get_ok in
  let source = Worker_producer.I.request Worker_producer.session ~request_id:(C.ticket_id ticket) operation |> Result.get_ok in
  let produce = query_sample (fun (Read.Read_query (budget,query))->match query with
    | Read.Changes _ -> Read.For_worker.answer budget query (Ok (Read.For_worker.change_batch
        ~change_owner:(Read.For_worker.read_budget_owner budget) ~generation:"generation-1"
        ~from_exclusive:None ~through:"revision-2" ~windows:[window ~scopes ()] ~next:None))
    | _ -> Alcotest.fail "expected the token's Changes query") in
  let batch = match Worker_producer.I.reply Worker_producer.session
    ~request_id:(C.ticket_id ticket) operation (produce source) with
    | Ok (W.Answered (Ok batch))->batch|_->Alcotest.fail "could not deliver the token's batch" in
  let admitted = C.step planned.next (C.Admitted (ticket,Coordination_test_fixture.Id.Worker.Request_id.one)) in
  let completed = C.step admitted.next (C.Completed (ticket,W.Answered (Ok batch))) in
  C.begin_change_application completed.next batch ~root |> Result.get_ok |> fst
;;

let test_retirement_releases_queued_consumers () =
  let module C = Journal_worker_coordination.Worker_pure_coordinator in
  let events = ref [] in
  let runtime = Production_runtime.create ~localtime:Unix.gmtime
    ~validate_session:Worker_producer.validate_session ~on_change:(fun event->events:=event::!events) () in
  set_calendar runtime;
  let fixtures = List.init 8 (fun i -> root_fixture i 1 0) in
  let feed,_ = drive_roots runtime fixtures (initial_roots runtime 989L) in
  let scopes = List.map (fun fixture->Worker_pure_data.V2_page_tree_interest fixture.owner.uuid) fixtures in
  let pull = pull runtime in
  let token = retirement_change_token pull scopes in
  Alcotest.(check bool) "attach the delivered pure change application" true
    (Runtime.set_change_application runtime ~request_id:pull token);
  bump_fixture_scopes scopes;
  let output = deliver_sample runtime (sample pull (query_sample (fun (Read.Read_query (budget,query))->match query with
    | Read.Changes _ -> Read.For_worker.answer budget query (Ok (Read.For_worker.change_batch
        ~change_owner:(Read.For_worker.read_budget_owner budget) ~generation:"generation-1"
        ~from_exclusive:None ~through:"revision-2" ~windows:[window ~scopes ()] ~next:None))
    | _ -> Alcotest.fail "expected the attached Changes query"))) in
  let children = List.fold_left (fun children -> function
    | C.Change_consumer_expanded (actual,_,ids) when actual=token -> Rrbvec.append children ids
    | _ -> children) Rrbvec.empty !events in
  let roots = Rrbvec.filter (fun id -> match Runtime.worker_read runtime id with
    | Some (Runtime.Read {query=W.Timeline_read {query=W.Timeline.Roots _;_};_})->true|_->false) children in
  Alcotest.(check int) "four root reads are active before retirement" 4 (Rrbvec.length roots);
  ignore (Runtime.retire_timeline runtime ~before:(retained_feed feed) ~after:(Journal_timeline_state.empty ~today:20260901));
  let retired = List.filter_map (function C.Change_consumer_retired (actual,id) when actual=token->Some id|_->None) !events in
  Alcotest.(check int) "all eight active and queued Feed consumers retire" 8 (List.length retired);
  Alcotest.(check bool) "active Feed payloads are released" true
    (Rrbvec.for_all (fun id->Runtime.worker_read runtime id=None) roots);
  let ack = only "non-Feed ACK remains independent" (List.filter (fun id->match Runtime.worker_read runtime id with
    | Some (Runtime.Acknowledge _)->true|_->false) output.requests) in
  let output = Worker_producer.deliver runtime ack (ack_sample "generation-1" "revision-2") in
  Alcotest.(check int) "ACK cannot drain retired queued reads" 0 (List.length output.requests)
;;

let test_retirement_single_entry_allocation () =
  let runtime = Runtime.create ~localtime:Unix.gmtime () in
  set_calendar runtime;
  let fixture = root_fixture 0 1 0 in
  let feed,_ = drive_roots runtime [fixture] (initial_roots runtime 989L) in
  let day = List.hd feed.days in
  let measure count =
    let entries = List.init count (fun n ->
      let record = List.hd fixture.roots in
      let block = Journal_graph_projection.block ~page:day.page ~revision:"large" ~child_count:0
        ~time_context:{localtime=Unix.gmtime} {record.block with
          uuid=uuid (Printf.sprintf "a7600000-0000-4000-8000-%012d" n);order=Printf.sprintf "%012d" n}
        |> Result.get_ok in
      ({block;child_summaries=[]}:Journal_graph_projection.timeline_entry)) in
    let before = retained_feed {feed with days=[{day with entries}];slot_count=count+1} in
    let entry = List.hd entries in
    let after = Journal_timeline_state.replace_timeline_entry before
      {entry with block=Journal_model.with_tag_titles entry.block ~tag_titles:["Changed"]} in
    let start = Gc.allocated_bytes () in
    ignore (Journal_timeline_state.retired ~before ~after);
    Gc.allocated_bytes () -. start
  in
  let small = measure 1024 and large = measure 8192 in
  Printf.eprintf "retirement-allocation: 1024=%.0f bytes; 8192=%.0f bytes\n%!" small large;
  Alcotest.(check bool) "single-entry retirement does not rebuild all retained collections" true
    (large < (small *. 4.) +. 16384.)
;;

let test_assembly_recovers_other_invalid_retained_scope () =
  let runtime = Runtime.create ~localtime:Unix.gmtime () in
  set_calendar runtime;
  let first = root_fixture 0 1 0 and second = root_fixture 1 1 0 in
  ignore (drive_roots runtime [first;second] (initial_roots runtime 989L));
  let request = pending_retained_assembly_check runtime first in
  bump_fixture_scopes [Worker_pure_data.V2_page_tree_interest second.owner.uuid];
  let output = Worker_producer.deliver runtime request check_sample in
  Alcotest.(check bool) "a changed retained sibling scope gets its own fresh read" true
    (List.exists (fun request -> match Runtime.worker_read runtime request with
      | Some(Runtime.Read{query=W.Timeline_read {query=W.Timeline.Roots page;after=None};_}) ->
        Graph.Uuid.equal page second.owner.uuid
      | _ -> false) output.requests);
  Alcotest.(check int) "unverified assembly remains unpublished" 0 (List.length output.responses)
;;

let test_late_check_cannot_restore_invalidated_receipts () =
  let runtime = Runtime.create ~localtime:Unix.gmtime () in
  set_calendar runtime;
  let first = root_fixture 0 1 0 and second = root_fixture 1 1 0 in
  ignore (drive_roots runtime [first;second] (initial_roots runtime 989L));
  let old = pending_retained_assembly_check runtime first in
  let old_reply = Worker_producer.transport runtime old |> Result.get_ok |> check_sample in
  ignore (changed runtime (window ~scopes:[Worker_pure_data.V2_page_tree_interest second.owner.uuid] ()));
  let late = Worker_producer.deliver runtime old (fun _ -> old_reply) in
  Alcotest.(check int) "an older snapshot cannot republish invalidated retained scopes" 0
    (List.length late.responses);
  Alcotest.(check bool) "current assembly is checked again after coalesced invalidation" true
    (List.exists (fun request -> match Runtime.worker_read runtime request with
      | Some(Runtime.Read{query=W.Timeline_check _;_}) -> true | _ -> false) late.requests)
;;

let test_newer_reconciliation_fences_old_results () =
  let runtime = Runtime.create ~localtime:Unix.gmtime () in
  let fixture = root_fixture 0 90 0 in
  load_ninety_roots runtime fixture;
  let refresh () = changed runtime
      (window ~scopes:[Worker_pure_data.V2_page_tree_interest fixture.owner.uuid] ()) in
  let old = only "held old reconciliation" (hydration_requests runtime (refresh ())) in
  let fresh, _ = drive_root_output runtime [fixture] (refresh ()) in
  Alcotest.(check int) "newer reconciliation publishes once" 1
    (List.length (List.filter (fun (r : Runtime.response) -> match r.payload with
         | Page_tree_reconciled _ -> true | _ -> false) fresh));
  let late = deliver_sample runtime (sample old (fixture_root_tree runtime fixture old)) in
  Alcotest.(check int) "older reconciliation cannot publish" 0 (List.length late.responses);
  Alcotest.(check int) "older reconciliation cannot continue" 0 (List.length late.requests);
  let old_graph = only "held retired graph reconciliation" (hydration_requests runtime (refresh ())) in
  let retired_packet=sample old_graph (fixture_root_tree runtime fixture old_graph) in
  Runtime.reset runtime;
  let retired = deliver_sample runtime retired_packet in
  Alcotest.(check int) "retired graph cannot publish" 0 (List.length retired.responses);
  Alcotest.(check int) "retired graph cannot continue" 0 (List.length retired.requests)
;;

(* The epoch belongs to the public business read planner, not the pure SDK.
   A real page reconciliation can finish while the first prefix is still held. *)
let test_initial_reconciliation_restarts_prefix () =
  let runtime=Runtime.create ~localtime:Unix.gmtime () in
  set_calendar runtime;
  let fixture=root_fixture 0 40 0 in
  let day=match fixture.owner.kind with Journal_page{journal_day}->journal_day|_->assert false in
  let rec hold_roots output =
    let request=only "initial date/root request" output.Runtime.requests in
    match Worker_producer.transport runtime request with
    |Ok(Worker_producer.S.Coordination_query{read=Read.Read_query(_,Read.Timeline_read {query=Read.Timeline.Roots _;_});_})->
      request
    |Ok(Worker_producer.S.Coordination_query{read=Read.Read_query(_,Read.Timeline_read {query=Read.Timeline.Dates {from_day=sealed_from_day;through_day=sealed_through_day};_});_})->
      let from_day=Read.For_worker.journal_day_value sealed_from_day in
      let through_day=Read.For_worker.journal_day_value sealed_through_day in
      let items=if from_day<=day && day<=through_day then
        [Worker_pure_data.{page=fixture.owner;journal_day=day;revision="page-1"}] else [] in
      hold_roots(deliver_sample runtime(sample request((journal_sample ~items:((items : Worker_pure_data.journal_item list)) ~next:(None)))))
    | _->Alcotest.fail "unexpected initial query"
  in
  let old=hold_roots(initial_roots runtime 77L)in
  let refreshed=changed runtime(window ~scopes:[Worker_pure_data.V2_page_tree_interest fixture.owner.uuid]())in
  ignore(drive_root_output runtime[fixture]refreshed);
  let packet=sample old((tree_sample ~items:((List.take 30 fixture.roots |> List.map(fun value->Worker_pure_data.{value;revision="old";depth=0;parent=fixture.owner.uuid}) : Worker_pure_data.tree_member list)) ~next:(Some(root_cursor 30))))in
  let restarted=deliver_sample runtime packet in
  Alcotest.(check bool) "reconciliation restarts the initial prefix without user failure"true
    (restarted.requests<>[] && not(List.exists(fun r->match r.Runtime.payload with Feed_failed _->true|_->false)restarted.responses));
  let feed,_=drive_roots runtime[fixture]restarted in
  Alcotest.(check int) "restart preserves the original visible root budget"30
    (List.fold_left(fun n (day:Journal_graph_projection.day_feed)->n+List.length day.entries)0 feed.days);
  let duplicate=deliver_sample runtime packet in
  Alcotest.(check bool) "retired prefix cannot restart or publish twice"true
    (duplicate.requests=[] && duplicate.responses=[])
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
      (window ~scopes:[ Worker_pure_data.V2_page_tree_interest fixture.owner.uuid ] ())
  in
  ignore (drive_root_output runtime [ fixture ] fresh);
  let values = List.take 30 (List.drop 30 fixture.roots) in
  let stale =
    deliver_sample
      runtime
      (sample
         old
         ((tree_sample ~items:((List.map
                  (fun value ->
                     Worker_pure_data.{ value; revision = "old"; depth = 0; parent = fixture.owner.uuid })
                  values : Worker_pure_data.tree_member list)) ~next:(Some (root_cursor 60)))))
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
    deliver_sample
      runtime
      (sample old ((journal_sample ~items:(([] : Worker_pure_data.journal_item list)) ~next:(None))))
  in
  Alcotest.(check int)
    "superseded initial generation is ignored"
    0
    (List.length out.responses);
  ignore (drive_roots runtime [ root_fixture 0 1 0 ] fresh);
  let runtime = Runtime.create () in
  let listing = only "singleton listing" (initial_roots runtime 77L).requests in
  let out =
    deliver_sample
      runtime
      (sample
         listing
         ((failed_sample (Read.Db_error(Logseq_db_worker.Error.create ~code:Response_too_large ~message:("oversized metadata") ~details:[]|>Result.get_ok)))))
  in
  let rec exhaust output =
    match output.Runtime.requests with
    | [] -> output.responses
    | request :: _ ->
      exhaust
        (deliver_sample
           runtime
           (sample
              request
              ((failed_sample (Read.Db_error(Logseq_db_worker.Error.create ~code:Response_too_large ~message:("oversized singleton") ~details:[]|>Result.get_ok))))))
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

let test_root_sealed_budget_preserves_visible_quota_and_tail () =
  let runtime = Runtime.create ~localtime:Unix.gmtime () in
  set_calendar runtime;
  let fixture = root_fixture 0 80 0 in
  let fixture =
    { fixture with
      roots =
        List.mapi
          (fun index (value : Worker_pure_data.block_record) ->
             if index < 20
             then { value with block = { value.block with title = "" } }
             else value)
          fixture.roots
    }
  in
  let first, seen1 = drive_roots runtime [ fixture ] (initial_roots runtime 901L) in
  let day = only "one root page" first.days in
  Alcotest.(check int) "first visible quota exact" 30 (List.length day.entries);
  let second, seen2 =
    drive_roots
      runtime
      [ fixture ]
      (Runtime.submit
         runtime
         (Journal_graph_request.Load_day_blocks
            { day = day.page.day
            ; after = day.continuation
            ; limit = 30
            ; request_generation = 902L
            }))
  in
  Alcotest.(check int)
    "next visible quota includes retained tail"
    30
    (List.fold_left
       (fun n (day : Journal_graph_projection.day_feed) -> n + List.length day.entries)
       0
       second.days);
  let reads =
    List.filter_map
      (fun r ->
         match r with
         | Some(Runtime.Read{query=W.Timeline_read {query=W.Timeline.Roots _;_};maximum_items=limit;_}) -> Some limit
         | _ -> None)
      (seen1 @ seen2)
  in
  Alcotest.(check (list int)) "root reads use remaining visible demand" [ 30; 20; 30 ] reads;
  let ids =
    List.concat_map
      (fun (feed : Journal_graph_projection.feed) ->
         List.concat_map
           (fun (day : Journal_graph_projection.day_feed) ->
              List.map
                (fun (entry : Journal_graph_projection.timeline_entry) ->
                   Journal_model.id entry.block)
                day.entries)
           feed.days)
      [ first; second ]
  in
  Alcotest.(check int)
    "over-read tail neither lost nor repeated"
    60
    (List.length (List.sort_uniq String.compare ids))
;;

let test_root_quota_generated_traces () =
  (* Every fixture has <=180 roots. Omitted source slots can produce an empty packet with More;
     cursor production still passes through the real Worker issuer decoder. *)
  let run (flags, initial, quotas, mode, split) =
    let module C = Journal_worker_coordination.Worker_pure_coordinator in
    let core = ref Worker_producer.state in
    let owner = ref (Option.get Worker_producer.raw.baseline.state.sync.selected) in
    let runtime =
      Runtime.create
        ~localtime:Unix.gmtime
        ~validate_session:(fun session -> C.validate_session ~owner:!owner !core session)
        ()
    in
    set_calendar runtime;
    let fixture = root_fixture 0 (List.length flags) 0 in
    let roots =
      List.map2
        (fun kind (value : Worker_pure_data.block_record) ->
           { value with
             block =
               { value.block with
                 title =
                   (if kind = 1
                    then ""
                    else if kind = 2
                    then "__pbt-omitted-root__"
                    else value.block.title)
               }
           })
        flags
        fixture.roots
    in
    let fixture = { fixture with roots } in
    let expected =
      List.filter_map
        (fun (value : Worker_pure_data.block_record) ->
           if value.block.title = "__pbt-omitted-root__" || value.block.title = ""
           then None
           else Some (Graph.Uuid.to_string value.block.uuid))
        roots
    in
    let first =
      Runtime.submit
        runtime
        (Journal_graph_request.Load_feed
           { cursor = None
           ; root_limit = initial
           ; day_limit = 1
           ; request_generation = 950L
           })
    in
    let first, _ =
      drive_roots ~filter_omitted:true ~split_bytes:split runtime [ fixture ] first
    in
    let feed_ids (feed : Journal_graph_projection.feed) =
      List.concat_map
        (fun (day : Journal_graph_projection.day_feed) ->
           List.map
             (fun (entry : Journal_graph_projection.timeline_entry) ->
                Journal_model.id entry.block)
             day.entries)
        feed.days
    in
    let rec consume round quota quotas previous (feed : Journal_graph_projection.feed) =
      if round > List.length flags + 2
      then failwith "generated root trace did not terminate";
      let batch = feed_ids feed in
      let remaining = List.length expected - List.length previous in
      if List.length batch <> min quota remaining
      then failwith "generated root trace violated exact visible quota";
      let seen = previous @ batch in
      if List.take (List.length seen) expected <> seen
      then failwith "generated root trace lost, reordered or duplicated an item";
      match
        List.find_map
          (fun (day : Journal_graph_projection.day_feed) ->
             Option.map (fun cursor -> day.page.day, cursor) day.continuation)
          feed.days
      with
      | None ->
        if seen <> expected
        then failwith "generated root trace completed a Partial prefix"
      | Some (day, cursor) ->
        let quota, quotas =
          match quotas with
          | [] -> initial, []
          | q :: rest -> q, rest
        in
        if round = 0 && mode <> 0
        then (
          (match mode with
           | 1 ->
             owner
             := { !owner with graph_id = uuid "98000000-0000-4000-8000-000000000099" }
           | 2 ->
             let _, transition =
               C.prepare_host_change
                 !core
                 (Journal_worker_coordination.Worker_api.Graph_will_close !owner.graph_id)
               |> Result.get_ok
             in
             core := transition.next
           | _ ->
             ignore
               (changed
                  runtime
                  (window
                     ~scopes:[ Worker_pure_data.V2_page_tree_interest fixture.owner.uuid ]
                     ())));
          let output =
            Runtime.submit
              runtime
              (Journal_graph_request.Load_day_blocks
                 { day; after = Some cursor; limit = quota; request_generation = 951L })
          in
          if output.requests <> [] then failwith "revoked root cursor issued new reads";
          match
            (only "revoked generated root cursor settles" output.responses).payload
          with
          | Day_blocks_failed { stale_cursor = true; _ } -> ()
          | _ -> failwith "revoked root cursor exposed retained data")
        else (
          let next, _ =
            drive_roots
              ~filter_omitted:true
              ~split_bytes:split
              runtime
              [ fixture ]
              (Runtime.submit
                 runtime
                 (Journal_graph_request.Load_day_blocks
                    { day
                    ; after = Some cursor
                    ; limit = quota
                    ; request_generation = Int64.of_int (952 + round)
                    }))
          in
          consume (round + 1) quota quotas seen next)
    in
    consume 0 initial quotas [] first
  in
  let fails case =
    try
      run case;
      false
    with
    | _ -> true
  in
  let rec shrink ((flags, initial, quotas, mode, split) as case) =
    let half = List.length flags / 2 in
    let candidates =
      (if flags = []
       then []
       else
         [ List.take half flags, initial, quotas, mode, split
         ; List.drop (max 1 half) flags, initial, quotas, mode, split
         ])
      @ (if initial = 1 then [] else [ flags, 1, quotas, mode, split ])
      @
      match quotas with
      | [] -> []
      | _ :: rest -> [ flags, initial, rest, mode, split ]
    in
    match List.find_opt fails candidates with
    | None -> case
    | Some smaller -> shrink smaller
  in
  for seed = 0 to 99 do
    let random = Random.State.make [| 33991; seed |] in
    let count = 1 + Random.State.int random 180 in
    let flags = List.init count (fun _ -> Random.State.int random 3) in
    let initial = 1 + Random.State.int random 30 in
    let quotas = List.init 8 (fun _ -> 1 + Random.State.int random 30) in
    let case =
      ( flags
      , initial
      , quotas
      , (if seed mod 5 = 0 then 1 + (seed mod 3) else 0)
      , seed mod 8 = 0 )
    in
    if fails case
    then (
      let flags, initial, quotas, mode, split = shrink case in
      Alcotest.failf
        "root quota seed=%d reduced flags=%s initial=%d quotas=%s mode=%d split=%b (%s)"
        seed
        (String.concat "" (List.map string_of_int flags))
        initial
        (String.concat "," (List.map string_of_int quotas))
        mode
        split
        (try run (flags,initial,quotas,mode,split); "passed" with exn -> Printexc.to_string exn))
  done;
  (* Force the final-page buffered-tail case for every authority revocation. *)
  List.iter
    (fun mode ->
       run (List.init 60 (fun n -> if n < 20 then 1 else 0), 30, [ 30 ], mode, false))
    [ 1; 2; 3 ]
;;

let () =
  Alcotest.run
    "journal graph runtime locality"
    [ ( "status recovery"
      , [ Alcotest.test_case
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
         Alcotest.test_case "Status completions" `Quick test_parent_visibility_confirmations])
    ; ( "bounded Timeline preview"
      , [ Alcotest.test_case "feed, day, remote and legacy refresh paths" `Quick test_bounded_preview_tree_paths
        ; Alcotest.test_case "Status 10050 children stays bounded" `Quick (test_bounded_preview_target_pages `Status 10050)
        ; Alcotest.test_case "Status conflict 10050 children stays bounded" `Quick (test_bounded_preview_target_pages `Status_conflict 10050)
        ; Alcotest.test_case "Delete conflict 10050 children stays bounded" `Quick (test_bounded_preview_target_pages `Delete_conflict 10050)
        ; Alcotest.test_case "Detail and Copy remain complete" `Quick test_preview_preserves_full_detail_and_copy
        ])
    ; ( "Timeline retirement rework"
      , [ Alcotest.test_case "full retirement revokes Root_dates" `Quick (test_full_retirement_revokes_catalog `Dates)
        ; Alcotest.test_case "full retirement revokes Root_today" `Quick (test_full_retirement_revokes_catalog `Today)
        ; Alcotest.test_case "full retirement revokes Check Publish" `Quick (test_full_retirement_revokes_catalog `Publish)
        ; Alcotest.test_case "cross-page observations" `Quick test_retirement_preserves_cross_page_observations
        ; Alcotest.test_case "preview-only observations" `Quick test_retirement_removes_preview_only_observations
        ; Alcotest.test_case "active and queued consumers" `Quick test_retirement_releases_queued_consumers
        ; Alcotest.test_case "single-entry allocation" `Quick test_retirement_single_entry_allocation ])
    ; ( "Timeline retirement"
      , [ Alcotest.test_case "retained hidden rows" `Quick test_retirement_preserves_hidden_rows
        ; Alcotest.test_case "absent pages and late installs" `Quick test_retirement_removes_pages_and_late_installs
        ; Alcotest.test_case "page ABA and surviving sibling" `Quick test_retirement_fences_page_aba_without_losing_siblings
        ; Alcotest.test_case "replaced date query" `Quick test_replaced_date_query_retires_old_receipts ])
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
    ; ("child status identity",[
        Alcotest.test_case "typed insertion admission" `Quick test_child_typed_insert_admission;
        Alcotest.test_case "unknown Child preserves wire across reset" `Quick (fun ()->test_child_unknown_wire_survives_reset ());
        Alcotest.test_case "unknown Child status preserves preconditions across reset" `Quick (fun ()->test_child_unknown_wire_survives_reset ~status:true ());
        Alcotest.test_case "reference and favorites typed origins reach Diagnostics" `Quick test_reference_and_favorites_preserve_typed_origin;
        Alcotest.test_case "timeline read preserves typed origin" `Quick test_timeline_read_preserves_typed_origin;
        Alcotest.test_case "timeline admission retains cause" `Quick test_timeline_admission_keeps_refusal_cause;
        Alcotest.test_case "typed admission refusal retains graph" `Quick test_typed_child_planning_refusal_retains_transport;
        Alcotest.test_case "failed physical continuations retire before delayed recovery" `Quick test_child_error_continuations_retire;
        Alcotest.test_case "unbound child refusal remains known not admitted" `Quick test_unbound_child_refusal_is_not_admitted])
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
    ; ( "cross-page ownership", [Alcotest.test_case "point context and retirement" `Quick test_changed_point_ownership;
        Alcotest.test_case "resync retires point observations" `Quick test_resync_retires_changed_points] )
    ; ( "initial thirty roots", [
        Alcotest.test_case "continued scope uses stale recovery" `Quick test_continuation_scope_change_uses_stale_recovery;
        Alcotest.test_case "reassigned day reprojects entries" `Quick test_reassigned_journal_day_reprojects_entries;
        Alcotest.test_case "accumulated sibling converges" `Quick test_accumulated_sibling_scope_change_converges;
        Alcotest.test_case "sealed root budget retains tail and exact visible quotas" `Quick test_root_sealed_budget_preserves_visible_quota_and_tail;
        Alcotest.test_case "generated root quotas, empty More and revoked tails" `Quick test_root_quota_generated_traces;
        Alcotest.test_case "dates use owned Worker query" `Quick test_feed_dates_use_owned_worker_query;
        Alcotest.test_case "feed publication waits for same-snapshot receipts" `Quick test_feed_publication_waits_for_same_snapshot_receipts;
        Alcotest.test_case "empty End receipts survive resync" `Quick test_empty_end_receipts_survive_resync;
        Alcotest.test_case "stale assembly discards prefix" `Quick test_stale_assembly_discards_prefix;
        Alcotest.test_case "assembly recovers other retained scopes" `Quick test_assembly_recovers_other_invalid_retained_scope;
        Alcotest.test_case "late check cannot restore invalid receipts" `Quick test_late_check_cannot_restore_invalidated_receipts;
        Alcotest.test_case "receipt check preserves Worker error" `Quick test_receipt_check_preserves_worker_error;
        Alcotest.test_case "owner revocation dominates mixed check failures" `Quick test_receipt_owner_change_dominates_read_failure;
        Alcotest.test_case "scope changes discard accumulated prefix" `Quick test_scope_change_restarts_without_old_prefix;
        Alcotest.test_case "changefeed fences inflight assembly check" `Quick test_changefeed_fences_inflight_assembly_check;
        Alcotest.test_case "Timeline owner revokes pending checks" `Quick test_timeline_owner_change_revokes_pending_reads;
        Alcotest.test_case "proof failure is explicit" `Quick test_timeline_proof_failure_is_explicit;
        Alcotest.test_case "paging read error preserves Worker error" `Quick test_timeline_read_failed_preserves_worker_error;
        Alcotest.test_case "date changes preserve retained prefix" `Quick test_dates_change_preserves_retained_root_prefix;
        Alcotest.test_case "cancel fences verification" `Quick (fun () -> test_verification_reply_is_fenced `Cancel);
        Alcotest.test_case "refresh fences verification" `Quick (fun () -> test_verification_reply_is_fenced `Refresh);
        Alcotest.test_case "reset fences verification" `Quick (fun () -> test_verification_reply_is_fenced `Reset);
        Alcotest.test_case "unowned children refuse legacy dispatch" `Quick test_private_children_without_owner_are_not_legacy;
        Alcotest.test_case "dates reject invalid local boundary" `Quick test_feed_dates_reject_invalid_local_boundary;
        Alcotest.test_case "date budget recovery restarts sealed cursor" `Quick test_feed_date_budget_failure_restarts_bound_cursor;
        Alcotest.test_case "date budget error remains typed" `Quick test_typed_date_budget_failure_preserves_classification;
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
        Alcotest.test_case "empty Today sync retires initial feed" `Quick test_empty_today_sync_retires_initial_feed;
        Alcotest.test_case "superseded continuation settles" `Quick test_initial_later_read_superseded;
        Alcotest.test_case "reconciliation restarts held initial prefix" `Quick test_initial_reconciliation_restarts_prefix;
        Alcotest.test_case "later batch fills across dates" `Quick test_later_thirty_crosses_dates;
        Alcotest.test_case "date cursor recovery is bounded and owned" `Quick test_date_cursor_recovery_is_bounded_and_owned;
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
      , [ Alcotest.test_case "summary uses owned Worker query" `Quick test_target_summary_uses_owned_worker_query
        ; Alcotest.test_case "conflict missing after empty More rejected" `Quick
            (test_conflict_missing_after_empty_more false)
        ; Alcotest.test_case "conflict changed version retries before absence" `Quick
            (test_conflict_missing_after_empty_more true)
        ; Alcotest.test_case "Status last root does not read siblings" `Quick (fun () ->
            test_target_confirmation `Status "Stored status target" 2)
        ; Alcotest.test_case "Status targeted confirmation" `Quick (fun () ->
            test_target_confirmation `Status "Retained block" 0)
        ; Alcotest.test_case
            "Blank canonical target completes without fabricated entry"
            `Quick
            (fun () -> test_target_confirmation `Status "" 0)
        ; Alcotest.test_case "Repeated target cursor settles" `Quick test_target_repeated_cursor_settles
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
        ; Alcotest.test_case "Target page retains structure interest" `Quick (fun () ->
            test_target_confirmation_retains_page_interest true)
        ; Alcotest.test_case
            "Pending Target page retains structure interest"
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
            [ "Status", `Status ] )
    ; ("ordinary delete readback",[
        Alcotest.test_case "known rejection reads ordinary current target" `Quick(test_ordinary_delete_readback false false);
        Alcotest.test_case "committed present ordinary target consumes actual DTO" `Quick(test_ordinary_delete_readback true false);
        Alcotest.test_case "ordinary canonical More applies before settlement" `Quick(test_ordinary_delete_readback true true)])
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
          [ "status", Task_change
          ; "status conflict", Task_conflict
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
      , [ Alcotest.test_case "children use owned Worker query" `Quick test_detail_children_use_owned_worker_query;
          Alcotest.test_case "empty More retains continuation" `Quick test_detail_empty_more_preserves_cursor;
 Alcotest.test_case
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
        ; Alcotest.test_case "Unknown mutation issues original continuation" `Quick
            test_unknown_mutation_recovery_issues_original
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
      , [ Alcotest.test_case "More continues only after ACK" `Quick test_changes_more_continues_after_ack; Alcotest.test_case
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
