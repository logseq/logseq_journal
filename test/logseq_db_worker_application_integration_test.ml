module Graph = Logseq_db_types.Graph_types
module Protocol = Logseq_db_worker.Protocol
module Production_runtime = Journal_graph_runtime

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

  let receive runtime request raw =
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
      ignore
        (I.request
           session
           ~request_id:(W.request_id request.Protocol.request_id)
           operation
         |> Result.get_ok);
      (match
         I.reply
           session
           ~request_id:(W.request_id request.request_id)
           operation
           (S.Graph_response raw)
       with
       | Ok (W.Answered (Ok value)) ->
         Production_runtime.receive_worker_read
           ~origin:(session, budget)
           runtime
           ~request_id:request.request_id
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

let seed_visible_block ?(record = record) runtime =
  set_calendar runtime;
  let journals =
    Runtime.submit
      runtime
      (Journal_graph_request.Load_feed
         { cursor = None
         ; day_limit = 1
         ; root_limit = 2

         ; request_generation = 7L
         })
    |> fun output -> only "journal request" output.requests
  in
  let tree =
    Read_fixture.receive runtime journals (respond
         journals
         (Protocol.V2_journals_outcome
            { items = [ { page; journal_day = 20260901; revision = "page-1" } ]
            ; next_cursor = None
            }))
    |> fun output -> only "page-tree request" output.requests
  in
  let output = Read_fixture.receive
    runtime
    tree
    (respond
       tree
       (Protocol.V2_page_tree_outcome
          { page = page_uuid
          ; maximum_depth = 0
          ; items =
              [ { value = record; revision = "block-1"; depth = 0; parent = page_uuid } ]
          ; next_cursor = None
          })) in
  let child=only "bounded preview query" output.requests in
  Read_fixture.receive runtime child (respond child (Protocol.V2_children_outcome
      {parent=record.block.uuid;revision_scope=Worker_pure_data.V2_children_revision record.block.uuid;
       scope_revision="children-1";items=[];next_cursor=None}))
;;

let observe_graph_revision runtime projection_revision =
  let request = Runtime.start runtime in
  Read_fixture.receive runtime request
    (respond request
       (Protocol.V2_graph_info_outcome
          { graph_uuid = Read_fixture.W.graph_id Read_fixture.session
          ; graph_name = "Journal"
          ; schema = { major = 1; minor = 0 }
          ; admission_facts = []
          ; journal_title_format = None
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
    (Read_fixture.receive runtime request
    (respond request
          (Protocol.V2_block_outcome (Worker_pure_data.V2_present_block { value = record; revision }))))
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
    Read_fixture.receive runtime request
    (respond request
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
  match output.requests with
  | [ { Protocol.command =
          V2_set_task_status
            { block = target
            ; status
            ; preconditions = { blocks = [ (precondition_block, revision) ]; _ }
            ; _
            }
      ; _
      }
    ] ->
    Alcotest.(check string)
      "exact selected status UUID"
      "00000002-1827-5820-8200-000000000000"
      (Graph.Uuid.to_string status);
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
         ; task_state = Journal_model.Status "00000002-1827-5820-8200-000000000000"
         })
    |> fun output -> only "status mutation request" output.requests
  in
  let module W=Read_fixture.W in
  let module I=Read_fixture.I in
  let session=Read_fixture.session in
  let presentation=Option.get(W.selected Read_fixture.projection) in
  let mutation_id,command=Runtime.worker_mutation runtime mutation |> Option.get in
  let intent=W.mutation_intent session ~mutation_id command |> Result.get_ok in
  Alcotest.(check bool) "typed status conflict keeps original intent" true
    (Runtime.bind_mutation runtime mutation ~presentation ~intent:(W.Mutation_intent intent));
  let operation=W.Mutate intent in
  let request_id=W.request_id mutation.Protocol.request_id in
  ignore(I.request session ~request_id operation |> Result.get_ok);
  let progress=match I.reply session ~request_id operation
    (Read_fixture.S.Coordination_mutation_result{request_id=mutation.request_id;
      outcome=Logseq_db_worker_contract.Mutation_pure_wire.Rejected
        (respond mutation (Protocol.V2_failed{code="conflict";message="The mutation precondition did not match."}))}) with
    |Ok(W.Answered(Ok progress))->progress|_->Alcotest.fail "known conflict proof was not decoded" in
  let refresh = Runtime.receive_mutation runtime mutation progress
    |> fun output -> only "status conflict refresh" output.requests
  in
  let output =
    Read_fixture.receive runtime refresh
      (respond refresh (Protocol.V2_block_summary_outcome
        {lookup=Worker_pure_data.V2_present_block {value=record;revision="block-2"};
         page=Some (Worker_pure_data.V2_present_page {page;revision="page-1"});
         items=[];next_cursor=None;scope_revision="children-1";
         generation="graph-1";projection_revision="projection-2"}))
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
  match output.requests with
  | [ { Protocol.command =
          V2_delete_blocks
            { preconditions =
                { blocks = [ (precondition_block, block_revision) ]; scopes = []; _ }
            ; _
            }
      ; _
      }
    ] ->
    Alcotest.(check string)
      "delete precondition target"
      (Graph.Uuid.to_string block_uuid)
      (Graph.Uuid.to_string precondition_block);
    Alcotest.(check string) "caller-observed delete revision" "block-1" block_revision
  | _ -> Alcotest.fail "delete did not use only its caller-observed block revision"
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
    (respond block_request
         (Protocol.V2_block_outcome
            (Worker_pure_data.V2_present_block { value = record; revision = "block-detail-1" })))
    |> fun output -> only "detail children request" output.requests
  in
  ignore
    (Read_fixture.receive runtime children_request (respond
          children_request
          (Protocol.V2_children_outcome
             { parent = block_uuid
             ; revision_scope = Worker_pure_data.V2_children_revision block_uuid
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
         ; status_intent_revision = 0L
         ; expected_parent_revision = "block-detail-1"
         ; sibling_order = "a1"
         ; source = "Child"
         ; task_state = Journal_model.No_status
         ; creation_time = capture.creation_time
         ; status_confirmation = false
})
  in
  match output.requests with
  | [ { Protocol.command =
          V2_insert_blocks
            { parent
            ; preconditions =
                { blocks = [ (precondition_parent, parent_revision) ]
                ; scopes = [ (Worker_pure_data.V2_children_scope scope_parent, scope_revision) ]
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
    (respond pull
         (Protocol.V2_changes
            { generation = "generation-1"
            ; from_exclusive = None
            ; through = "revision-2"
            ; windows =
                [ { id = "revision-2"
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

let test_named_tags_reach_timeline_row () =
  let module Ui = Journal_view in
  let runtime = Runtime.create () in
  set_calendar runtime;
  let journals =
    Runtime.submit
      runtime
      (Journal_graph_request.Load_feed
         { cursor = None
         ; day_limit = 1
         ; root_limit = 2

         ; request_generation = 7L
         })
    |> fun out -> only "journals" out.requests
  in
  let tree =
    Read_fixture.receive runtime journals (respond
         journals
         (Protocol.V2_journals_outcome
            { items = [ { page; journal_day = 20260901; revision = "page-1" } ]
            ; next_cursor = None
            }))
    |> fun out -> only "tree" out.requests
  in
  let raw =
    Protocol.response_to_yojson
      (respond
         tree
         (Protocol.V2_page_tree_outcome
            { page = page_uuid
            ; maximum_depth = 0
            ; items =
                [ { value = record; revision = "block-1"; depth = 0; parent = page_uuid }
                ]
            ; next_cursor = None
            }))
  in
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
  let response =
    match Protocol.response_of_yojson (enrich raw) with
    | Ok value -> value
    | Error message -> Alcotest.failf "tag read rejected: %s" message
  in
  let output = Read_fixture.receive runtime tree response in
  let child=only "tagged root preview" output.requests in
  let output=Read_fixture.receive runtime child (respond child (Protocol.V2_children_outcome
      {parent=block_uuid;revision_scope=Worker_pure_data.V2_children_revision block_uuid;scope_revision="children-1";items=[];next_cursor=None})) in
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
    (respond pull
              (V2_changes
                 { generation = "generation-1"
                 ; from_exclusive = None
                 ; through = "revision-2"
                 ; windows =
                     [ { id = "revision-2"
                       ; predecessor = "revision-1"
                       ; successor = "revision-2"
                       ; block_uuids = [ block_uuid ]
                       ; page_uuids = []
                       ; structure_interests = []
                       }
                     ]
                 ; next = None
                 }))
       in
       let point =
         List.find
           (fun (request : Protocol.request) ->
              match request.command with
              | V2_get_outline_block _ -> true
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
    (respond point
              (V2_block_outcome
                 (Worker_pure_data.V2_present_block { value = updated; revision = "block-2" })))
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
