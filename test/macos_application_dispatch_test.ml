module Test = Bonsai_flutter_test
module Service = Logseq_db_worker_bonsai.Logseq_db_worker_bonsai_service
module P = Logseq_db_worker.Protocol
module Wire = Bonsai_flutter_protocol
module ID = Bonsai_flutter_spec.Id

let require condition message = if not condition then failwith message

let graph_id =
  Logseq_db_types.Graph_types.Uuid.of_string "70000000-0000-4000-b000-000000000001"
  |> Result.get_ok
;;

let inspections = ref 0
let graph_reads = ref 0
let unavailable = ref false
let service_failure = ref false
let counts = ref 0

let inspection : P.v2_admission_inspection =
  { active_records = 0
  ; active_bytes = 0
  ; protected_wire_bytes = 0
  ; retained_origin_evidence_bytes = 0
  ; maximum_records = 200
  ; maximum_bytes = 4096
  }
;;

module Graph = Logseq_db_types.Graph_types

let block_id = "70000000-0000-4000-a000-000000000001"
let block_uuid = Graph.Uuid.of_string block_id |> Result.get_ok

let page : Graph.page =
  { uuid = graph_id
  ; name = "20260831"
  ; title = "2026-08-31"
  ; kind = Journal_page { journal_day = 20260831 }
  ; created_at_ms = 1_788_192_000_000L
  ; updated_at_ms = 1_788_192_000_000L
  ; recycled = false
  ; tags = []
  ; properties = []
  }
;;

let title = ref "Before remote update"
let revision = ref "block-1"
let deleted = ref false
let deletes = ref 0
let emit = ref (fun (_ : Service.push) -> ())

let record () : P.v2_block_record =
  { block =
      { uuid = block_uuid
      ; title = !title
      ; parent = graph_id
      ; page = graph_id
      ; order = "a"
      ; created_at_ms = 1_788_192_000_000L
      ; updated_at_ms = 1_788_192_000_000L
      ; refs = []
      ; tags = []
      ; properties = []
      }
  ; task_status = None
  ; rendered_page_title = page.title
  }
;;

let service =
  Worker.Service.create
    ~push_topic_count:5
    ~concurrency:Worker.Service.Serial
    ~init:(fun context (_ : Journal_startup.t) ->
      (emit
       := fun push ->
            Worker.Session_context.emit context ~topic:Service.invalidation_topic push);
      Ok ())
    ~handle:(fun _ () -> function
       | Service.Get_graph_state ->
         Ok
           (Service.Graph_state
              { generation = 0; graph_id = None; phase = Graph_closed; error = None })
       | Client_command _ -> Ok Service.Client_command_completed
       | Graph_request request ->
         if request.P.command = P.V2_inspect_admission && !service_failure
         then (
           incr inspections;
           Error "fixture worker failure")
         else (
           let outcome =
             match request.P.command with
             | V2_graph_info ->
               incr graph_reads;
               P.V2_graph_info_outcome
                 { graph_uuid = graph_id
                 ; graph_name = "Admission fixture"
                 ; schema = { major = 65; minor = 33 }
                 ; admission_facts = []
                 ; generation = "generation-1"
                 ; projection_revision = "projection-1"
                 ; limits =
                     { response_budget_bytes = 1048576
                     ; outbox_max_records = 200
                     ; outbox_max_bytes = 4096
                     ; change_max_items = 256
                     ; change_max_bytes = 1048576
                     ; dispatcher_capacity = 100
                     ; wire_batch_max_bytes = 4096
                     }
                 }
             | V2_list_journals _ ->
               P.V2_journals_outcome
                 { revision_scope = V2_journal_index_revision
                 ; scope_revision = "index-1"
                 ; items = [ { page; journal_day = 20260831; revision = "page-1" } ]
                 ; next_cursor = None
                 }
             | V2_get_page_tree { page; maximum_depth; _ } ->
               P.V2_page_tree_outcome
                 { page
                 ; maximum_depth
                 ; revision_scope = V2_page_tree_revision { page; maximum_depth }
                 ; scope_revision = "tree-1"
                 ; items =
                     (if !deleted
                      then []
                      else
                        [ { value = record ()
                          ; revision = !revision
                          ; depth = 0
                          ; parent = graph_id
                          }
                        ])
                 ; next_cursor = None
                 }
             | V2_delete_blocks { mutation_id; preconditions; _ } ->
               incr deletes;
               if preconditions.blocks <> [ block_uuid, !revision ]
               then P.V2_failed { code = "conflict"; message = "target changed" }
               else (
                 deleted := true;
                 P.V2_mutation_committed
                   { mutation_id
                   ; status = V2_applied
                   ; generation = "generation-1"
                   ; before_projection_revision = "projection-1"
                   ; after_projection_revision = "projection-2"
                   })
             | V2_inspect_admission ->
               incr inspections;
               if !unavailable
               then
                 P.V2_failed { code = "closedSession"; message = "fixture unavailable" }
               else P.V2_admission_outcome { inspection with active_records = !counts }
             | _ -> failwith "unexpected fixture request"
           in
           Ok
             (Service.Graph_response
                (P.V2_response
                   { api_version = P.api_version
                   ; request_id = request.request_id
                   ; outcome
                   }))))
    ~shutdown:(fun () -> ())
    ()
;;

let application_payload =
  Logseq_db_worker.Config.create
    ~application_support_directory:"/tmp/unused-admission-fixture"
    ~target:(Managed_sync { base_url = "https://example.invalid" })
    ~compatibility_profile:Logseq_65_33_or_newer
    ~response_budget_bytes:P.maximum_response_bytes
    ~default_page_size:P.default_page_size
  |> Result.get_ok
  |> Journal_startup.encode
  |> Result.get_ok
;;

let envelope tag source =
  let bytes = Bytes.make (32 + String.length source) '\000' in
  Bytes.blit_string "LJP2" 0 bytes 0 4;
  Bytes.set_uint16_le bytes 4 2;
  Bytes.set_uint16_le bytes 6 tag;
  Bytes.set_int32_le bytes 24 (Int32.of_int (String.length source));
  Bytes.blit_string source 0 bytes 32 (String.length source);
  bytes
;;

let respond_preferences handle epoch =
  let frame = Test.Handle.last_frame handle |> Option.get in
  let wire = Wire.Binary_codec.decode frame.bytes |> Result.get_ok in
  let request_id =
    List.find_map
      (function
        | Wire.Wire_frame.Application_request { request_id; payload }
          when Bytes.equal payload Journal_platform.typography_preset_preference_request
          -> Some request_id
        | _ -> None)
      wire.operations
    |> Option.get
  in
  Test.Handle.present handle;
  let event : Wire.Inbound_event.t =
    { sequence = ID.Runtime.Event_sequence.of_int64 1L
    ; displayed_revision = Test.Handle.revision handle
    ; node_id = ID.Ui.Node_id.zero
    ; handler_id = ID.Ui.Handler_id.zero
    ; event_tag = Wire.Generated_protocol.Event_tag.application_response
    ; payload =
        Application_response
          { request_id
          ; payload = envelope 17 {|{"key":"typographyPreset","value":null}|}
          }
    }
  in
  Test.Handle.pump_next handle ~events:{ runtime_epoch = epoch; events = [ event ] } ()
;;

let press handle epoch sequence test_id =
  let node = Test.Handle.find handle (Test.Query.test_id test_id) |> Option.get in
  let binding =
    Array.find_opt
      (fun binding ->
         Bonsai_flutter_ui.Event.Tag.equal
           binding.Bonsai_flutter_runtime.Mounted_tree.Mounted_binding.event_tag
           Bonsai_flutter_ui.Event.Tag.Press)
      node.event_bindings
    |> Option.get
  in
  let event : Wire.Inbound_event.t =
    { sequence = ID.Runtime.Event_sequence.of_int64 sequence
    ; displayed_revision = Test.Handle.revision handle
    ; node_id = node.node_id
    ; handler_id = binding.handler_id
    ; event_tag = Wire.Generated_protocol.Event_tag.press
    ; payload = Unit
    }
  in
  Test.Handle.pump_next handle ~events:{ runtime_epoch = epoch; events = [ event ] } ();
  Test.Handle.present handle
;;

let native_delete handle epoch sequence =
  let node =
    Test.Handle.find handle (Test.Query.test_id ("journal-row-slidable:" ^ block_id))
    |> Option.get
  in
  let binding =
    Array.find_opt
      (fun binding ->
         Bonsai_flutter_ui.Event.Tag.equal
           binding.Bonsai_flutter_runtime.Mounted_tree.Mounted_binding.event_tag
           Bonsai_flutter_ui.Event.Tag.Native_event)
      node.event_bindings
    |> Option.get
  in
  let payload = Bytes.make 4 '\000' in
  Bytes.set_int32_le payload 0 1l;
  let event : Wire.Inbound_event.t =
    { sequence = ID.Runtime.Event_sequence.of_int64 sequence
    ; displayed_revision = Test.Handle.revision handle
    ; node_id = node.node_id
    ; handler_id = binding.handler_id
    ; event_tag = Wire.Generated_protocol.Event_tag.native_event
    ; payload =
        Native_event
          { kind_id = Bonsai_flutter_ui.Native_widget.Slidable.kind_id
          ; version = 3
          ; event_id = Bonsai_flutter_ui.Native_widget.Slidable.action_pressed_event_id
          ; payload
          }
    }
  in
  Test.Handle.pump_next handle ~events:{ runtime_epoch = epoch; events = [ event ] } ();
  Test.Handle.present handle
;;

let undo handle epoch sequence request_id =
  let event : Wire.Inbound_event.t =
    { sequence = ID.Runtime.Event_sequence.of_int64 sequence
    ; displayed_revision = Test.Handle.revision handle
    ; node_id = ID.Ui.Node_id.zero
    ; handler_id = ID.Ui.Handler_id.zero
    ; event_tag = Wire.Generated_protocol.Event_tag.host_response
    ; payload =
        Host_response { request_id; status = Host_ok; value = Bytes.make 1 '\000' }
    }
  in
  Test.Handle.pump_next handle ~events:{ runtime_epoch = epoch; events = [ event ] } ();
  Test.Handle.present handle
;;

let undo_request handle =
  let rec find remaining =
    let frame = Test.Handle.last_frame handle |> Option.get in
    let frame = Wire.Binary_codec.decode frame.bytes |> Result.get_ok in
    match
      List.find_map
        (function
          | Wire.Wire_frame.Host_request
              { request_id; payload = Show_snack_bar { action_label = Some "Undo"; _ } }
            -> Some request_id
          | _ -> None)
        frame.operations
    with
    | Some request_id -> request_id
    | None when remaining > 0 ->
      Test.Handle.present handle;
      Test.Handle.pump_next handle ();
      Test.Handle.present handle;
      find (remaining - 1)
    | None -> failwith "delete did not offer Undo"
  in
  find 20
;;

let pump handle =
  for _ = 1 to 20 do
    Test.Handle.present handle;
    Test.Handle.pump_next handle ()
  done;
  Test.Handle.present handle
;;

let () =
  let epoch = ID.Runtime.Epoch.of_int64 8001L in
  let calendar_sampler =
    Journal_calendar.Sampler.create
      ~clock:(fun () -> 1_788_192_000.)
      ~localtime:Unix.gmtime
      ()
  in
  let time_source = Bonsai.Time_source.create ~start:Core.Time_ns.epoch in
  let handle =
    Test.Handle.create_app
      ~runtime_epoch:epoch
      ~time_source
      (Application.For_testing.app_with_service ~calendar_sampler service)
      ~application_payload
  in
  Fun.protect
    ~finally:(fun () -> Test.Handle.shutdown handle)
    (fun () ->
       respond_preferences handle epoch;
       pump handle;
       !emit
         (Service.Graph_state_changed
            { generation = 1; graph_id = Some graph_id; phase = Graph_open; error = None });
       pump handle;
       require (!graph_reads = 1) "open graph did not receive graph-info request";
       press handle epoch 2L "journal-account-menu-button";
       press handle epoch 3L "journal-account-diagnostics";
       pump handle;
       require (!inspections = 1) "opening Diagnostics did not dispatch its inspection";
       require
         (Test.Handle.find handle (Test.Query.visible_text "0 / 200") <> None)
         "zero-count inspection did not become Available";
       let reopen sequence =
         press handle epoch sequence "journal-diagnostics-close";
         press handle epoch (Int64.succ sequence) "journal-account-menu-button";
         press handle epoch (Int64.add sequence 2L) "journal-account-diagnostics";
         pump handle
       in
       counts := 3;
       reopen 4L;
       require (!inspections = 2) "reopen did not start one fresh inspection";
       require
         (Test.Handle.find handle (Test.Query.visible_text "3 / 200") <> None)
         "nonzero metrics lost";
       unavailable := true;
       reopen 7L;
       require (!inspections = 3) "unavailable inspection was not dispatched";
       require
         (Test.Handle.find_all handle (Test.Query.visible_text "Not available")
          |> List.length
          >= 4)
         "unavailable completion left Loading";
       unavailable := false;
       service_failure := true;
       reopen 10L;
       require (!inspections = 4) "failed service inspection was not dispatched";
       require
         (Test.Handle.find_all handle (Test.Query.visible_text "Not available")
          |> List.length
          >= 4)
         "worker service failure left Loading";
       service_failure := false;
       reopen 13L;
       require (!inspections = 5) "reopen after failure retained orphaned request";
       require
         (Test.Handle.find handle (Test.Query.visible_text "3 / 200") <> None)
         "reopen after failure did not recover";
       press handle epoch 16L "journal-diagnostics-close";
       native_delete handle epoch 17L;
       let undo_id = undo_request handle in
       require (!deletes = 0) "delete dispatched before Undo deadline";
       require
         (Test.Handle.find
            handle
            (Test.Query.test_id ("journal-row-slidable:" ^ block_id))
          = None)
         "delete did not hide row";
       title := "After remote update";
       revision := "block-2";
       !emit
         (Service.Graph_push
            (P.V2_resync_required_push
               { api_version = P.api_version
               ; generation = "generation-1"
               ; reason = "fixture authoritative refresh"
               }));
       pump handle;
       require
         (Test.Handle.find
            handle
            (Test.Query.test_id ("journal-row-slidable:" ^ block_id))
          = None)
         "reconciliation resurrected a row during the Undo window";
       undo handle epoch 18L undo_id;
       pump handle;
       require
         (Test.Handle.find handle (Test.Query.visible_text "After remote update") <> None)
         "Undo discarded latest target text";
       ignore (Test.Handle.pump handle ~monotonic_now_ns:6_000_000_000L ());
       pump handle;
       require (!deletes = 0) "cancelled Undo deadline emitted a delete";
       native_delete handle epoch 19L;
       pump handle;
       ignore (Test.Handle.pump handle ~monotonic_now_ns:12_000_000_000L ());
       pump handle;
       require
         (!deletes = 1 && !deleted)
         "second delete did not commit once using the reconciled revision";
       require
         (Test.Handle.find
            handle
            (Test.Query.test_id ("journal-row-slidable:" ^ block_id))
          = None)
         "committed delete restored the row";
       print_endline "MACOS_APPLICATION_DISPATCH_TESTS_PASSED")
;;
