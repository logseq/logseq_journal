module Read = Worker_pure_read
module Graph = Logseq_db_types.Graph_types
module Production_runtime = Journal_graph_runtime
module W = Journal_worker_coordination.Worker_api

(* Domain fixtures use the public typed read boundary. The database Service is
   exercised separately by worker_coordination_runtime_test. *)
module Read_fixture = struct
  module W = Journal_worker_coordination.Worker_api
  module C = Journal_worker_coordination.Worker_pure_coordinator
  module S = Logseq_db_worker_lui.Logseq_db_worker_lui_service

  let issuer, raw, projection, session =
    Coordination_test_fixture.fixture
      ~limits:
        { Coordination_test_fixture.limits with
          response_budget_bytes = Worker_pure_data.maximum_response_bytes
        }
      2900L
  ;;

  module I = (val issuer : Worker_effect_authority.ISSUER)

  let state =
    let bound =
      C.step
        (C.initial
           ~client_id:
             (W.Uuid.of_string "98000000-0000-4000-8000-000000002900" |> Result.get_ok))
        (C.Worker_bound I.binding)
    in
    (C.step bound.next (C.Bootstrap_received (I.binding, W.Ready projection))).next
  ;;

  let validate_session session =
    C.validate_session ~owner:(Option.get raw.baseline.state.sync.selected) state session
  ;;

  let receive runtime request produce =
    match Production_runtime.worker_read runtime request with
    | Some (Production_runtime.Read read) ->
      let budget =
        W.read_budget
          session
          ~maximum_items:read.maximum_items
          ~maximum_bytes:Worker_pure_data.maximum_response_bytes
        |> Result.get_ok
      in
      let operation = W.Query (budget, read.query) in
      let response=match I.request session ~request_id:(W.request_id request)operation|>Result.get_ok with
        |S.Coordination_query source->S.Coordination_queried{registration=source.registration;owner=source.owner;
          request_id=source.request_id;answer=produce source.read}
        |_->Alcotest.fail "domain fixture did not issue the original typed query"in
      (match I.reply session ~request_id:(W.request_id request)operation response with
       | Ok (W.Answered (Ok value)) ->
         Production_runtime.receive_worker_read
           ~origin:(session, budget)
           runtime
           ~request_id:request
           (Journal_graph_runtime.Query_result(read.query,value))
       | _ -> Alcotest.fail "typed domain fixture response rejected")
    | _ -> Alcotest.fail "expected a typed domain read"
  ;;
end

module Runtime = struct
  include Production_runtime

  let create ?localtime () =
    Production_runtime.create
      ?localtime
      ~validate_session:Read_fixture.validate_session
      ()
  ;;
end

let uuid value = Graph.Uuid.of_string value |> Result.get_ok

let only label = function
  | [ value ] -> value
  | values -> Alcotest.failf "%s: expected one value, got %d" label (List.length values)
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

let record : Worker_pure_data.block_record =
  { block; task_status = None; rendered_page_title = page.title; tag_titles = [] }
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
  ; status_confirmation = false
  ; status_intent_revision = 0L
}
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

let timeline_packet budget query items =
  let module F = Read.For_worker in
  let receipt =
    F.timeline_receipt ~owner:(F.read_budget_owner budget) ~query ~version:"scope-1"
  in
  F.timeline_packet ~receipt ~items:(Rrbvec.of_list items) ~next:None
;;

let receive_timeline_check runtime request =
  Read_fixture.receive runtime request (fun (Read.Read_query (budget, query)) ->
    match query with
    | Read.Timeline_check receipts ->
      Read.For_worker.answer budget query
        (Ok (Read.For_worker.timeline_check (Rrbvec.map (fun _ -> Ok ()) receipts)))
    | _ -> Alcotest.fail "expected a Timeline receipt check")
;;

let seed_visible_block ?(record = record) runtime =
  set_calendar runtime;
  let dates =
    Runtime.submit
      runtime
      (Journal_graph_request.Load_feed
         { cursor = None
         ; day_limit = 1
         ; root_limit = 2
         ; request_generation = 7L
         })
    |> fun output -> only "Timeline dates request" output.requests
  in
  let roots =
    Read_fixture.receive runtime dates (fun (Read.Read_query (budget, query)) ->
      match query with
      | Read.Timeline_read { query = (Read.Timeline.Dates _ as timeline); _ } ->
        Read.For_worker.answer budget query
          (Ok (Ok (timeline_packet budget timeline
                     [ { page; journal_day = 20260901; revision = "page-1" } ])))
      | _ -> Alcotest.fail "expected Timeline dates")
    |> fun output -> only "Timeline roots request" output.requests
  in
  let preview =
    Read_fixture.receive runtime roots (fun (Read.Read_query (budget, query)) ->
      match query with
      | Read.Timeline_read { query = (Read.Timeline.Roots owner as timeline); _ } ->
        Alcotest.(check bool) "Timeline roots page" true (Graph.Uuid.equal owner page_uuid);
        Read.For_worker.answer budget query
          (Ok (Ok (timeline_packet budget timeline
                     [ { value = record; revision = "block-1"; depth = 0; parent = page_uuid } ])))
      | _ -> Alcotest.fail "expected Timeline roots")
    |> fun output -> only "Timeline preview request" output.requests
  in
  let check =
    Read_fixture.receive runtime preview (fun (Read.Read_query (budget, query)) ->
      match query with
      | Read.Timeline_read { query = (Read.Timeline.Preview_children parent as timeline); _ } ->
        Alcotest.(check bool) "Timeline preview parent" true
          (Graph.Uuid.equal parent record.block.uuid);
        Read.For_worker.answer budget query (Ok (Ok (timeline_packet budget timeline [])))
      | _ -> Alcotest.fail "expected Timeline preview")
    |> fun output -> only "Timeline receipt check" output.requests
  in
  receive_timeline_check runtime check
;;

let observe_graph_revision runtime projection_revision =
  let request = Runtime.start runtime in
  Read_fixture.receive runtime request
    (((fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok(F.graph_info ~graph_uuid:(Read_fixture.W.graph_id Read_fixture.session) ~graph_name:("Journal") ~schema:({ major = 1; minor = 0 }) ~admission_facts:([]) ~journal_title_format:(None) ~limits:({ response_budget_bytes = 4_096
              ; outbox_max_records = 4_096
              ; outbox_max_bytes = 8 * 1_024 * 1_024
              ; change_max_items = 4_096
              ; change_max_bytes = 4 * 1_024 * 1_024
              ; dispatcher_capacity = 32
              ; wire_batch_max_bytes = 4 * 1_024 * 1_024
              }) ~generation:("generation-1") ~projection_revision:(projection_revision)) in match query with |Read.Graph_info->F.answer budget query value |_->failwith "Synthetic sample query family mismatch")))
;;

let refresh_private_block_revision runtime revision =
  let request =
    Runtime.submit
      runtime
      (Journal_graph_request.Find_block (Graph.Uuid.to_string block_uuid))
    |> fun output -> only "point block request" output.requests
  in
  ignore
    (Read_fixture.receive runtime request
    (((fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_present_block { value = record; revision })) in match query with |Read.Outline_block _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"))))
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
  (match Runtime.worker_read runtime request with
   | Some(Runtime.Read{query=W.Admission;_})-> ()
   | _ -> Alcotest.fail "admission inspection did not use the Worker protocol command");
  let output =
    Read_fixture.receive runtime request
    (((fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok(Worker_pure_data.{ active_records = 3
            ; active_bytes = 1536
            ; protected_wire_bytes = 512
            ; retained_origin_evidence_bytes = 256
            ; maximum_records = 1000
            ; maximum_bytes = 8 * 1024 * 1024
            }) in match query with |Read.Admission->F.answer budget query value |_->failwith "Synthetic sample query family mismatch")))
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
         ; task_state = Journal_model.Status "00000002-1827-5820-8200-000000000000"
         })
  in
  let original=only "typed mutation" output.requests in
  let actual=Runtime.worker_intent runtime original Read_fixture.session |> Result.get_ok in
  let expected=W.mutation_intent Read_fixture.session ~mutation_id:(uuid "a2000000-0000-4000-a000-000000000003")
    (W.Set_task_status{block=block_uuid;status=uuid "00000002-1827-5820-8200-000000000000";preconditions={blocks=[block_uuid,"block-1"];pages=[];scopes=[]}}) |> Result.get_ok in
  Alcotest.(check bytes) "caller-observed status revision"
    (W.encode_durable_intent(W.Mutation_intent expected)) (W.encode_durable_intent actual)
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
         ; task_state = Journal_model.Status "00000002-1827-5820-8200-000000000000"
         })
    |> fun output -> only "status mutation request" output.requests
  in
  let module W=Read_fixture.W in
  let module I=Read_fixture.I in
  let session=Read_fixture.session in
  let presentation=Option.get(W.selected Read_fixture.projection) in
  let intent=match Runtime.worker_intent runtime mutation session |> Result.get_ok with W.Mutation_intent intent->intent|_->assert false in
  Alcotest.(check bool) "typed status conflict keeps original intent" true
    (Result.is_ok (Runtime.bind_mutation runtime mutation ~presentation ~intent:(W.Mutation_intent intent)));
  let operation=W.Mutate intent in
  let request_id=W.request_id mutation in
  ignore(I.request session ~request_id operation |> Result.get_ok);
  let progress=match I.reply session ~request_id operation
    (Read_fixture.S.Coordination_mutation_result{request_id=mutation;
      outcome=Logseq_db_worker_contract.Worker_pure_mutation.Rejected
        (Logseq_db_worker.Error.create ~code:Conflict
          ~message:"The mutation precondition did not match." ~details:[]|>Result.get_ok)}) with
    |Ok(W.Answered(Ok submission))->(match submission with
      |W.Submission_rejected error->W.Rejected error
      |Submission_unknown->W.Outcome_unknown
      |Submission_committed receipt->W.Committed_pending_presentation receipt)
    |_->Alcotest.fail "known conflict proof was not decoded" in
  let refresh = Runtime.receive_mutation runtime mutation progress
    |> fun output -> only "status conflict refresh" output.requests
  in
  let output =
    Read_fixture.receive runtime refresh
      (((fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok(F.block_summary ~lookup:(Worker_pure_data.V2_present_block {value=record;revision="block-2"}) ~page:(Some (Worker_pure_data.V2_present_page {page;revision="page-1"})) ~items:([]) ~next:(Option.map(fun cursor->F.continuation ~owner:(F.read_budget_owner budget) ~budget ~key:(Read.query_key budget query) ~cursor)(None)) ~scope_revision:("children-1") ~generation:("graph-1") ~projection_revision:("projection-2")) in match query with |Read.Block_summary _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch")))
  in
  match output.responses with
  | [ { Runtime.payload = Mutation_settled(_,_,Update_conflict {block=latest;_}) } ] ->
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
  let original=only "typed mutation" output.requests in
  let actual=Runtime.worker_intent runtime original Read_fixture.session |> Result.get_ok in
  let expected=W.mutation_intent Read_fixture.session ~mutation_id:(uuid "a2000000-0000-4000-a000-000000000004")
    (W.Delete_blocks{root=block_uuid;preconditions={blocks=[block_uuid,"block-1"];pages=[];scopes=[]}}) |> Result.get_ok in
  Alcotest.(check bytes) "caller-observed delete revision"
    (W.encode_durable_intent(W.Mutation_intent expected)) (W.encode_durable_intent actual)
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
    Read_fixture.receive runtime block_request
    (((fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_present_block { value = record; revision = "block-detail-1" })) in match query with |Read.Outline_block _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch")))
    |> fun output -> only "detail children request" output.requests
  in
  ignore
    (Read_fixture.receive runtime children_request (((fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok(F.children ~parent:(block_uuid) ~revision_scope:(Worker_pure_data.V2_children_revision block_uuid) ~scope_revision:("children-scope-1") ~items:([]) ~next:(Option.map(fun cursor->F.continuation ~owner:(F.read_budget_owner budget) ~budget ~key:(Read.query_key budget query) ~cursor)(None))) in match query with |Read.Child_members _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"))))
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
         ; status_intent_revision = 0L
         ; expected_parent_revision = "block-detail-1"
         ; sibling_order = "a1"
         ; source = "Child"
         ; task_state = Journal_model.No_status
         ; creation_time = capture.creation_time
         ; status_confirmation = false
})
  in
  let original=only "typed mutation" output.requests in
  let actual=Runtime.worker_intent runtime original Read_fixture.session |> Result.get_ok in
  let expected=W.mutation_intent Read_fixture.session ~mutation_id:(uuid "a2000000-0000-4000-a000-000000000005")
    (W.Insert_blocks{parent=block_uuid;roots=[{uuid=uuid "a2000000-0000-4000-9000-000000000005";title="Child";children=[]}];preconditions={blocks=[block_uuid,"block-detail-1"];pages=[];scopes=[Worker_pure_data.V2_children_scope block_uuid,"children-scope-1"]}}) |> Result.get_ok in
  Alcotest.(check bytes) "caller-observed parent and children scope"
    (W.encode_durable_intent(W.Mutation_intent expected)) (W.encode_durable_intent actual)
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
  | [ { Runtime.payload =
          Capture_not_admitted{command={mutation_id;block_id;_};message}
      ; _
      }
    ] ->
    Alcotest.(check string)
      "failure keeps admitted mutation"
      capture.mutation_id
      mutation_id;
    Alcotest.(check string) "failure keeps admitted block" capture.block_id block_id;
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
    Runtime.reconcile_signal
      runtime
      ~request_generation:11L
      (Worker_pure_data.Changes_available { generation = "generation-1"
         ; through = "revision-2"
         })
    |> fun output -> only "pull request" output.requests
  in
  let unrelated = uuid "a2000000-0000-4000-9000-000000000099" in
  let output =
    Read_fixture.receive runtime pull
    (((fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok(F.change_batch ~change_owner:(F.read_budget_owner budget) ~generation:("generation-1") ~from_exclusive:(None) ~through:("revision-2") ~windows:([ { id = "revision-2"
                  ; predecessor = "revision-1"
                  ; successor = "revision-2"
                  ; block_uuids = [ unrelated ]
                  ; page_uuids = []
                  ; structure_interests = []
                  }
                ]) ~next:(None)) in match query with |Read.Changes _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch")))
  in
  let checks, requests =
    List.partition
      (fun request ->
         match Runtime.worker_read runtime request with
         | Some (Runtime.Read { query = W.Timeline_check _; _ }) -> true
         | _ -> false)
      output.requests
  in
  let checked = receive_timeline_check runtime (only "retained Timeline check" checks) in
  Alcotest.(check int) "valid retained scopes do not request hydration" 0
    (List.length checked.requests);
  Alcotest.(check bool) "uninterested change does not update the feed" true
    (List.for_all
       (fun (response : Runtime.response) ->
          match response.payload with
          | Projection_changes _ -> true
          | _ -> false)
       (output.responses @ checked.responses));
  match List.map (Runtime.worker_read runtime) requests with
  | [ Some (Runtime.Acknowledge { batch = { through = "revision-2"; _ } }) ] -> ()
  | _ -> Alcotest.fail "uninterested change must only validate receipts and acknowledge"
;;

let test_named_tags_reach_timeline_row () =
  let module Ui = Journal_view in
  let runtime = Runtime.create () in
  let raw=Worker_pure_data.block_record_to_yojson record in
  let rec enrich = function
    | `Assoc fields ->
      let fields = List.map (fun (k, v) -> k, enrich v) fields in
      if List.mem_assoc "rendered_page_title" fields
      then
        `Assoc
          (List.map
             (fun (name, value) ->
                if name = "tag_titles"
                then name, `List [ `String "户外"; `String "周末计划" ]
                else name, value)
             fields)
      else `Assoc fields
    | `List values -> `List (List.map enrich values)
    | value -> value
  in
  let tagged=match Worker_pure_data.block_record_of_yojson(enrich raw)with
    |Ok value->value|Error message->Alcotest.failf "tag DTO rejected: %s" message in
  let output = seed_visible_block ~record:tagged runtime in
  let entry =
    List.find_map
      (fun (r : Runtime.response) ->
         match r.payload with
         | Feed_loaded { feed; _ } ->
           List.find_map
             (fun (d : Journal_graph_projection.day_feed) ->
                match d.entries with
                | head :: _ -> Some head
                | [] -> None)
             feed.days
         | _ -> None)
      output.responses
    |> Option.get
  in
  let batches = ref [] in
  let backend : Lui_protocol.backend =
    { backend_profile = Lui_protocol.profile IOS SwiftUIHost
    ; apply_batch =
        (fun b ->
          batches := b :: !batches;
          true)
    }
  in
  let view =
    Journal_row.view
      ~show_timestamp:false
      ~render_media:(fun ~title:_ ~root:_ ~image_children:_ child -> child)
      entry
  in
  let app =
    Lui_app.create_with_extensions
      backend
      Journal_lui_native.registry
      ()
      (fun () () -> ())
      (fun _ _ _ -> Ui.mount view)
  in
  Fun.protect
    ~finally:(fun () -> ignore (Lui_app.dispose app))
    (fun () ->
       ignore (Lui_app.start app);
       ignore (Lui_app.flush app);
       let ops = List.concat_map (fun (b : Lui_protocol.patch_batch) -> b.ops) !batches in
       Alcotest.(check bool)
         "tag labels reach actual timeline UI"
         true
         (List.exists
            (function
              | Lui_protocol.SetProp (_, TextValue, StringValue "#户外  #周末计划") -> true
              | _ -> false)
            ops))
;;

let test_point_read_tag_metadata () =
  List.iter
    (fun titles ->
       let runtime = Runtime.create ~localtime:Unix.gmtime () in
       let tagged =
         { record with
           block = { block with tags = [ page_uuid ] }
         ; tag_titles = [ "before" ]
         }
       in
       ignore (seed_visible_block ~record:tagged runtime);
       let pull =
         Runtime.reconcile_signal
           runtime
           ~request_generation:11L
           (Worker_pure_data.Changes_available { generation = "generation-1"; through = "revision-2" })
         |> fun output -> only "change request" output.requests
       in
       let hydrated =
         Read_fixture.receive runtime pull
    (((fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok(F.change_batch ~change_owner:(F.read_budget_owner budget) ~generation:("generation-1") ~from_exclusive:(None) ~through:("revision-2") ~windows:([ { id = "revision-2"
                       ; predecessor = "revision-1"
                       ; successor = "revision-2"
                       ; block_uuids = [ block_uuid ]
                       ; page_uuids = []
                       ; structure_interests = []
                       }
                     ]) ~next:(None)) in match query with |Read.Changes _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch")))
       in
       let point =
         List.find
           (fun (request : Graph.Uuid.t) ->
              match Runtime.worker_read runtime request with
              | Some(Runtime.Read{query=W.Outline_block _;_}) -> true
              | _ -> false)
           hydrated.requests
       in
       let updated =
         { tagged with
           block =
             { block with
               title = "Remote edit"
             ; tags = (if titles = [] then [] else [ page_uuid ])
             }
         ; tag_titles = titles
         }
       in
       let output =
         Read_fixture.receive runtime point
    (((fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_present_block { value = updated; revision = "block-2" })) in match query with |Read.Outline_block _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch")))
       in
       let projected =
         List.find_map
           (fun (response : Runtime.response) ->
              match response.payload with
              | Block_updated { block; _ } -> Some block
              | _ -> None)
           output.responses
         |> Option.get
       in
       Alcotest.(check (list string))
         "point read replaces tag metadata"
         titles
         (Journal_model.tag_titles projected);
       Alcotest.(check string)
         "updated body"
         "Remote edit"
         (Journal_model.source projected))
    [ [ "before" ]; [ "after"; "中文" ]; [] ]
;;

let () =
  Alcotest.run
    "Worker application integration"
    [ ( "v2 boundary"
      , [ Alcotest.test_case "point read tag metadata" `Quick test_point_read_tag_metadata
        ; Alcotest.test_case
            "named tags reach timeline row"
            `Quick
            test_named_tags_reach_timeline_row
        ; Alcotest.test_case
            "read response becomes normalized feed"
            `Quick
            test_worker_read_becomes_normalized_application_feed
        ; Alcotest.test_case
            "admission inspection preserves graph generation"
            `Quick
            test_admission_inspection_preserves_graph_generation
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
