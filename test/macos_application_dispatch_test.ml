module Test = Bonsai_swiftui_test
module Service = Logseq_db_worker_bonsai.Logseq_db_worker_bonsai_service
module P = Logseq_db_worker.Protocol
module Wire = Bonsai_swiftui_protocol
module ID = Bonsai_swiftui_spec.Id

let require condition message = if not condition then failwith message

let graph_id =
  Logseq_db_types.Graph_types.Uuid.of_string "70000000-0000-4000-b000-000000000001"
  |> Result.get_ok
;;

let inspections = ref 0
let graph_reads = ref 0
let journal_ranges = ref []
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

let mutation_failure = ref false
let status_writes = ref 0
let initial_feed_failure = ref false
let favorites_service_failure = ref false
let favorites_reads = ref 0
let favorites_fail = ref false
let client_commands = ref []

let service =
  Worker.Service.create
    ~push_topic_count:6
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
       | Asset_command _ | Release_asset_file _ -> Ok Client_command_completed
       | Acquire_asset_file _ | Acquire_imported_file _ -> Ok (Asset_file None)
       | Client_command command ->
         client_commands := command :: !client_commands;
         Ok Service.Client_command_completed
       | Graph_request request ->
         if request.P.command = P.V2_inspect_admission && !service_failure
         then (
           incr inspections;
           Error "fixture worker failure")
         else if
           match request.P.command with
           | P.V2_list_favorites _ -> !favorites_service_failure
           | _ -> false
         then (
           incr favorites_reads;
           Error "Favorites worker stopped")
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
             | V2_list_favorites _ ->
               incr favorites_reads;
               if !favorites_fail
               then
                 P.V2_failed
                   { code = "corruptStorage"; message = "Favorites fixture read failed" }
               else
                 P.V2_favorites_outcome
                   { favorites_page = Some graph_id
                   ; generation = "generation-1"
                   ; projection_revision = "projection-1"
                   ; next_cursor = None
                   ; items =
                       [ { membership_uuid = graph_id
                         ; membership_order = "a0"
                         ; membership_revision = "membership-1"
                         ; target =
                             V2_favorite_page
                               { uuid = graph_id
                               ; title = "Design notes"
                               ; revision = "page-1"
                               }
                         }
                       ; { membership_uuid = block_uuid
                         ; membership_order = "a1"
                         ; membership_revision = "membership-2"
                         ; target =
                             V2_favorite_block
                               { uuid = block_uuid
                               ; title = "Review navigation"
                               ; task_status = Some V2_doing
                               ; revision = "block-1"
                               }
                         }
                       ]
                   }
             | V2_list_journals _ when !initial_feed_failure ->
               P.V2_failed
                 { code = "corruptStorage"; message = "Journal fixture read failed" }
             | V2_list_journals { from_day; through_day; _ } ->
               journal_ranges := (from_day, through_day) :: !journal_ranges;
               P.V2_journals_outcome
                 { items = [ { page; journal_day = 20260831; revision = "page-1" } ]
                 ; next_cursor = None
                 }
             | V2_list_assets _ ->
               P.V2_assets_outcome
                 { generation = "generation-1"
                 ; projection_revision = "projection-1"
                 ; items = []
                 ; next_cursor = None
                 }
             | V2_get_page_tree { page; maximum_depth; _ } ->
               P.V2_page_tree_outcome
                 { page
                 ; maximum_depth
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
             | V2_get_block _ ->
               P.V2_block_outcome
                 (V2_present_block { value = record (); revision = !revision })
             | V2_get_children { parent; _ } ->
               let root = record () in
               let child =
                 { root with
                   block =
                     { root.block with
                       uuid =
                         Graph.Uuid.of_string "70000000-0000-4000-a000-000000000002"
                         |> Result.get_ok
                     ; parent = block_uuid
                     ; title = "Outline child"
                     }
                 }
               in
               P.V2_children_outcome
                 { parent
                 ; revision_scope = V2_children_revision parent
                 ; scope_revision = "children-1"
                 ; items = [ { value = child; revision = "child-1" } ]
                 ; next_cursor = None
                 }
             | V2_set_task_status _ | V2_clear_task_status _ ->
               incr status_writes;
               P.V2_failed
                 { code = "corruptStorage"
                 ; message = "Fixture mutation could not be stored"
                 }
             | V2_delete_blocks { mutation_id; preconditions; _ } ->
               incr deletes;
               if !mutation_failure
               then
                 P.V2_failed
                   { code = "corruptStorage"
                   ; message = "Fixture mutation could not be stored"
                   }
               else if preconditions.blocks <> [ block_uuid, !revision ]
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

(* Export every accepted frame from one application session for native checks. *)
let frame_directory = Sys.getenv_opt "JOURNAL_ROOT_FRAME_DIR"
let frame_phase = ref "disabled"
let frame_number = ref 0
let previous_frame = ref None

let export_frame handle =
  match frame_directory, Test.Handle.last_frame handle with
  | Some directory, Some frame
    when !frame_phase <> "disabled" && !previous_frame <> Some frame.bytes ->
    previous_frame := Some frame.bytes;
    let path =
      Filename.concat directory (Printf.sprintf "%04d-%s.bin" !frame_number !frame_phase)
    in
    incr frame_number;
    let channel = open_out_bin path in
    Fun.protect
      ~finally:(fun () -> close_out channel)
      (fun () -> output_bytes channel frame.bytes)
  | _ -> ()
;;

let press_node handle epoch sequence node =
  let binding =
    Array.find_opt
      (fun binding ->
         Bonsai_swiftui_ui.Event.Tag.equal
           binding.Bonsai_swiftui_runtime.Mounted_tree.Mounted_binding.event_tag
           Bonsai_swiftui_ui.Event.Tag.Press)
      node.Bonsai_swiftui_runtime.Mounted_tree.Snapshot.event_bindings
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
  export_frame handle;
  Test.Handle.present handle
;;

let select_picker handle epoch sequence id =
  let node = Test.Handle.find handle (Test.Query.kind "picker") |> Option.get in
  let binding =
    Array.find_opt
      (fun binding ->
         Bonsai_swiftui_ui.Event.Tag.equal
           binding.Bonsai_swiftui_runtime.Mounted_tree.Mounted_binding.event_tag
           Bonsai_swiftui_ui.Event.Tag.Picker_selected)
      node.Bonsai_swiftui_runtime.Mounted_tree.Snapshot.event_bindings
    |> Option.get
  in
  let event : Wire.Inbound_event.t =
    { sequence = ID.Runtime.Event_sequence.of_int64 sequence
    ; displayed_revision = Test.Handle.revision handle
    ; node_id = node.node_id
    ; handler_id = binding.handler_id
    ; event_tag = Wire.Generated_protocol.Event_tag.picker_selected
    ; payload = Int64 id
    }
  in
  Test.Handle.pump_next handle ~events:{ runtime_epoch = epoch; events = [ event ] } ();
  export_frame handle;
  Test.Handle.present handle
;;

let select_account handle epoch sequence id =
  let node = Test.Handle.find handle (Test.Query.kind "menu") |> Option.get in
  let binding =
    Array.find_opt
      (fun binding ->
         Bonsai_swiftui_ui.Event.Tag.equal
           binding.Bonsai_swiftui_runtime.Mounted_tree.Mounted_binding.event_tag
           Bonsai_swiftui_ui.Event.Tag.Menu_action)
      node.Bonsai_swiftui_runtime.Mounted_tree.Snapshot.event_bindings
    |> Option.get
  in
  let event : Wire.Inbound_event.t =
    { sequence = ID.Runtime.Event_sequence.of_int64 sequence
    ; displayed_revision = Test.Handle.revision handle
    ; node_id = node.node_id
    ; handler_id = binding.handler_id
    ; event_tag = Wire.Generated_protocol.Event_tag.menu_action
    ; payload = Int64 id
    }
  in
  Test.Handle.pump_next handle ~events:{ runtime_epoch = epoch; events = [ event ] } ();
  export_frame handle;
  Test.Handle.present handle
;;

let native_back handle epoch sequence =
  let node = Test.Handle.find handle (Test.Query.kind "navigation_stack") |> Option.get in
  let binding =
    Array.find_opt
      (fun binding ->
         Bonsai_swiftui_ui.Event.Tag.equal
           binding.Bonsai_swiftui_runtime.Mounted_tree.Mounted_binding.event_tag
           Bonsai_swiftui_ui.Event.Tag.Navigation_path_changed)
      node.Bonsai_swiftui_runtime.Mounted_tree.Snapshot.event_bindings
    |> Option.get
  in
  let event : Wire.Inbound_event.t =
    { sequence = ID.Runtime.Event_sequence.of_int64 sequence
    ; displayed_revision = Test.Handle.revision handle
    ; node_id = node.node_id
    ; handler_id = binding.handler_id
    ; event_tag = Wire.Generated_protocol.Event_tag.navigation_path_changed
    ; payload = Navigation_path_changed []
    }
  in
  Test.Handle.pump_next handle ~events:{ runtime_epoch = epoch; events = [ event ] } ();
  export_frame handle;
  Test.Handle.present handle
;;

let button_within handle node =
  let rec contains widget candidate =
    widget == candidate
    || Array.exists
         (fun child -> contains child candidate)
         (let (Av view) = Bonsai_swiftui_ui.View.Private.view widget in
          view.children)
  in
  Test.Handle.find_all handle (Test.Query.kind "button")
  |> List.find (fun candidate ->
    contains
      node.Bonsai_swiftui_runtime.Mounted_tree.Snapshot.widget
      candidate.Bonsai_swiftui_runtime.Mounted_tree.Snapshot.widget)
;;

let press handle epoch sequence test_id =
  let node = Test.Handle.find handle (Test.Query.test_id test_id) |> Option.get in
  press_node handle epoch sequence (button_within handle node)
;;

let native_timeline_action handle epoch sequence action =
  let node =
    Test.Handle.find
      handle
      (Test.Query.key (Bonsai_swiftui_ui.Key.string (action ^ ":" ^ block_id)))
    |> Option.get
  in
  press_node handle epoch sequence node
;;

let native_delete handle epoch sequence =
  native_timeline_action handle epoch sequence "delete"
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
  export_frame handle;
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
              { request_id; payload = Show_notice { action_label = Some "Undo"; _ } } ->
            Some request_id
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
    (* The fixture service runs on a worker thread. Let it consume queued work
       before advancing the next deterministic UI pump. *)
    Thread.delay 0.001;
    Test.Handle.present handle;
    Test.Handle.pump_next handle ();
    export_frame handle
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
       export_frame handle;
       pump handle;
       !emit
         (Service.Graph_state_changed
            { generation = 1; graph_id = Some graph_id; phase = Graph_open; error = None });
       pump handle;
       require (!graph_reads = 1) "open graph did not receive graph-info request";
       select_account handle epoch 3L 1L;
       pump handle;
       require (!inspections = 1) "opening Diagnostics did not dispatch its inspection";
       require
         (Test.Handle.find handle (Test.Query.visible_text "0 / 200") <> None)
         "zero-count inspection did not become Available";
       let reopen sequence =
         press handle epoch sequence "journal-diagnostics-close";
         select_account handle epoch (Int64.add sequence 2L) 1L;
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
            (Test.Query.key
               (Bonsai_swiftui_ui.Key.string ("journal-row-actions:" ^ block_id)))
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
            (Test.Query.key
               (Bonsai_swiftui_ui.Key.string ("journal-row-actions:" ^ block_id)))
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
            (Test.Query.key
               (Bonsai_swiftui_ui.Key.string ("journal-row-actions:" ^ block_id)))
          = None)
         "committed delete restored the row";
       ())
;;

let select_tab handle epoch sequence index =
  let label = if index = 0L then "Journals" else "Favorites" in
  let node = Test.Handle.find handle (Test.Query.semantics_label label) |> Option.get in
  press_node handle epoch sequence (button_within handle node);
  pump handle
;;

let () =
  let epoch = ID.Runtime.Epoch.of_int64 8002L in
  frame_phase := "startup";
  let handle =
    Test.Handle.create_app
      ~runtime_epoch:epoch
      ~time_source:(Bonsai.Time_source.create ~start:Core.Time_ns.epoch)
      (Application.For_testing.app_with_service
         ~calendar_sampler:
           (Journal_calendar.Sampler.create
              ~clock:(fun () -> 1_788_192_000.)
              ~localtime:Unix.gmtime
              ())
         service)
      ~application_payload
  in
  Fun.protect
    ~finally:(fun () -> Test.Handle.shutdown handle)
    (fun () ->
       export_frame handle;
       pump handle;
       if Option.is_some frame_directory
       then (
         !emit
           (Service.Client_state_changed
              { snapshot =
                  { sync_phase = Connecting
                  ; catalog = []
                  ; selected_graph = Some graph_id
                  ; applied_server_t = Some 0
                  ; timeline_presentation_pending = false
                  ; startup =
                      { authenticated = true
                      ; catalog_loading = false
                      ; awaiting_selection = false
                      ; restoring_local = false
                      ; bootstrapping = false
                      ; awaiting_e2ee_password = false
                      ; failure = None
                      ; account_generation = 1
                      ; graph_generation = 7
                      ; presentation_generation = 1
                      }
                  ; last_error = None
                  ; local_deletion = None
                  }
              ; diagnostics = { groups = [] }
              });
         pump handle);
       frame_phase := "journals";
       !emit
         (Service.Graph_state_changed
            { generation = 7; graph_id = Some graph_id; phase = Graph_open; error = None });
       pump handle;
       frame_phase := "journals";
       export_frame handle;
       require (!favorites_reads = 0) "Favorites delayed or joined Journals startup";
       require
         (Test.Handle.find handle (Test.Query.test_id "journal-capture-open") <> None)
         "Journals has no Capture";
       frame_phase := "favorites";
       select_tab handle epoch 2L 1L;
       require (!favorites_reads = 1) "Favorites selection did not lazily read once";
       require
         (Test.Handle.find handle (Test.Query.visible_text "Design notes") <> None)
         "ordinary favorite page is missing";
       require
         (Test.Handle.find handle (Test.Query.visible_text "Review navigation") <> None)
         "favorite block is missing";
       require
         (Test.Handle.find handle (Test.Query.test_id "journal-capture-open") <> None)
         "Favorites lost the shared Capture action";
       List.iter
         (fun id ->
            require
              (Test.Handle.find handle (Test.Query.test_id id) = None)
              "Favorites rendered an interactive row")
         [ "journal-row-slidable:" ^ block_id; "journal-row-toggle-children:" ^ block_id ];
       select_tab handle epoch 3L 1L;
       require (!favorites_reads = 1) "reselection restarted Favorites";
       require
         (Test.Handle.find handle (Test.Query.kind "native_list") <> None)
         "Favorites must use a public native List";
       require
         (Test.Handle.find handle (Test.Query.kind "navigation_link") <> None)
         "Favorite block activation must use Navigation_link";
       frame_phase := "returned";
       select_tab handle epoch 4L 0L;
       require
         (Test.Handle.find handle (Test.Query.test_id "journal-capture-open") <> None)
         "return to Journals lost Capture";
       frame_phase := "favorites-again";
       select_tab handle epoch 5L 1L;
       require (!favorites_reads = 1) "clean cache was reloaded";
       favorites_service_failure := true;
       !emit
         (Service.Graph_push
            (P.V2_resync_required_push
               { api_version = P.api_version
               ; generation = "generation-1"
               ; reason = "favorite refresh"
               }));
       pump handle;
       require (!favorites_reads = 2) "Favorites refresh was not dispatched";
       require
         (Test.Handle.find handle (Test.Query.visible_text "Retry") <> None)
         "Favorites worker failure left a pending read without Retry";
       require
         (Test.Handle.find handle (Test.Query.visible_text "Design notes") <> None)
         "Favorites worker failure discarded cached rows";
       favorites_service_failure := false;
       press handle epoch 6L "favorites-retry-button";
       pump handle;
       require (!favorites_reads = 3) "Favorites did not recover from worker failure";
       if Option.is_some frame_directory
       then (
         frame_phase := "returned-sync";
         select_tab handle epoch 7L 0L;
         frame_phase := "favorites-sync";
         select_tab handle epoch 8L 1L);
       let link =
         Test.Handle.find
           handle
           (Test.Query.key (Bonsai_swiftui_ui.Key.string ("favorite-open:" ^ block_id)))
         |> Option.get
       in
       press_node handle epoch 9L link;
       pump handle;
       require
         (Test.Handle.find handle (Test.Query.test_id "journal-detail-outline") <> None)
         "Favorites native link did not open its block destination";
       print_endline "FAVORITES_APPLICATION_VIEW_TESTS_PASSED")
;;

(* Repeated public Timeline.observe_visible_range produces equal state and the
   same request; the pure reducer cannot reproduce native binding churn. The
   application view boundary owns handler allocation. Exercise that boundary
   without duplicating the regression in transport or native gesture tests. *)
let () =
  deleted := false;
  let epoch = ID.Runtime.Epoch.of_int64 8004L in
  let handle =
    Test.Handle.create_app
      ~runtime_epoch:epoch
      ~time_source:(Bonsai.Time_source.create ~start:Core.Time_ns.epoch)
      (Application.For_testing.app_with_service service)
      ~application_payload
  in
  Fun.protect
    ~finally:(fun () -> Test.Handle.shutdown handle)
    (fun () ->
       pump handle;
       !emit
         (Service.Graph_state_changed
            { generation = 1; graph_id = Some graph_id; phase = Graph_open; error = None });
       pump handle;
       let collection () =
         Test.Handle.find handle (Test.Query.test_id "journal-timeline") |> Option.get
       in
       let identity = (collection ()).node_id in
       let scroll _sequence _pixels _delta =
         Test.Handle.visible_range
           handle
           (Test.Query.test_id "journal-timeline")
           ~first_index:0L
           ~last_exclusive:1L;
         Test.Handle.present handle;
         require
           ((collection ()).node_id = identity)
           "scrolling replaced the timeline collection"
       in
       let completion_binding () =
         Array.find_opt
           (fun binding ->
              Bonsai_swiftui_ui.Event.Tag.equal
                binding.Bonsai_swiftui_runtime.Mounted_tree.Mounted_binding.event_tag
                Bonsai_swiftui_ui.Event.Tag.List_scroll_completed)
           (collection ()).event_bindings
         |> Option.get
       in
       let completion = completion_binding () in
       scroll 2L 40.5 40.5;
       require
         (completion_binding () = completion)
         "viewport state changed the owner of an in-flight scroll completion";
       require
         (Test.Handle.find handle (Test.Query.test_id "journal-root-navigation") <> None)
         "downward scrolling unmounted the system toolbar";
       scroll 3L 10.25 (-30.25);
       require
         (Test.Handle.find handle (Test.Query.test_id "journal-root-navigation") <> None)
         "upward scrolling unmounted the system toolbar";
       scroll 4L 60.75 50.5;
       pump handle;
       let bindings = (collection ()).event_bindings in
       scroll 5L 0. (-60.75);
       pump handle;
       require
         ((collection ()).event_bindings = bindings)
         "an unchanged visible range replaced native action bindings");
  print_endline "TIMELINE_SCROLL_IDENTITY_PASSED"
;;

(* The outline reducer already covers branch state. This native-view port
   checks only admission and routing of rendered disclosure and Back controls. *)
let () =
  deleted := false;
  let epoch = ID.Runtime.Epoch.of_int64 8005L in
  let handle =
    Test.Handle.create_app
      ~runtime_epoch:epoch
      ~time_source:(Bonsai.Time_source.create ~start:Core.Time_ns.epoch)
      (Application.For_testing.app_with_service service)
      ~application_payload
  in
  Fun.protect
    ~finally:(fun () -> Test.Handle.shutdown handle)
    (fun () ->
       pump handle;
       !emit
         (Service.Graph_state_changed
            { generation = 1; graph_id = Some graph_id; phase = Graph_open; error = None });
       pump handle;
       native_timeline_action handle epoch 2L "open";
       pump handle;
       let child_visible () =
         Test.Handle.find
           handle
           (Test.Query.test_id "detail-block:70000000-0000-4000-a000-000000000002")
         <> None
       in
       require (child_visible ()) "detail did not show its initial child";
       let outline =
         Test.Handle.find handle (Test.Query.test_id "journal-detail-outline")
         |> Option.get
       in
       require
         (Bonsai_swiftui_ui.View.For_testing.kind_name outline.widget = "Native_list")
         "outline must use public native List disclosure rows";
       let disclose sequence expanded =
         let node =
           Test.Handle.find handle (Test.Query.test_id ("detail-disclosure:" ^ block_id))
           |> Option.get
         in
         let binding =
           Array.find_opt
             (fun binding ->
                Bonsai_swiftui_ui.Event.Tag.equal
                  binding.Bonsai_swiftui_runtime.Mounted_tree.Mounted_binding.event_tag
                  Bonsai_swiftui_ui.Event.Tag.Value_changed)
             node.event_bindings
           |> Option.get
         in
         let event : Wire.Inbound_event.t =
           { sequence = ID.Runtime.Event_sequence.of_int64 sequence
           ; displayed_revision = Test.Handle.revision handle
           ; node_id = node.node_id
           ; handler_id = binding.handler_id
           ; event_tag = Wire.Generated_protocol.Event_tag.value_changed
           ; payload = Bool expanded
           }
         in
         Test.Handle.pump_next
           handle
           ~events:{ runtime_epoch = epoch; events = [ event ] }
           ();
         export_frame handle;
         Test.Handle.present handle
       in
       let completion_binding () =
         let node =
           Test.Handle.find handle (Test.Query.test_id "journal-detail-outline")
           |> Option.get
         in
         Array.find_opt
           (fun binding ->
              Bonsai_swiftui_ui.Event.Tag.equal
                binding.Bonsai_swiftui_runtime.Mounted_tree.Mounted_binding.event_tag
                Bonsai_swiftui_ui.Event.Tag.List_scroll_completed)
           node.event_bindings
         |> Option.get
       in
       let completion = completion_binding () in
       disclose 3L false;
       pump handle;
       require (not (child_visible ())) "native disclosure did not collapse the root";
       disclose 4L true;
       pump handle;
       require (child_visible ()) "native disclosure did not expand the root";
       require
         (completion_binding () = completion)
         "disclosure state changed its scroll completion owner";
       require
         (Test.Handle.find handle (Test.Query.test_id "detail-back") = None)
         "detail contains a duplicate Back button";
       native_back handle epoch 5L;
       pump handle;
       require
         (Test.Handle.find handle (Test.Query.test_id "journal-detail-route") = None)
         "detail Back did not restore the originating list");
  print_endline "DETAIL_DISCLOSURE_DISPATCH_PASSED"
;;

(* View metadata is owned by Application's renderer, not the sync reducer.
   Valid public snapshots and native Press events reproduce these failures. *)
let test_native_button_semantics name catalog =
  let epoch = ID.Runtime.Epoch.of_int64 8003L in
  let time_source = Bonsai.Time_source.create ~start:Core.Time_ns.epoch in
  let handle =
    Test.Handle.create_app
      ~runtime_epoch:epoch
      ~time_source
      (Application.For_testing.app_with_service service)
      ~application_payload
  in
  Fun.protect
    ~finally:(fun () -> Test.Handle.shutdown handle)
    (fun () ->
       pump handle;
       match catalog with
       | None ->
         !emit
           (Service.Graph_state_changed
              { generation = 1
              ; graph_id = Some graph_id
              ; phase = Graph_open
              ; error = None
              });
         pump handle;
         select_account handle epoch 3L 1L;
         pump handle;
         require
           (Test.Handle.find handle (Test.Query.kind "form") <> None)
           "diagnostics Form did not render";
         press handle epoch 7L "journal-diagnostics-close";
         pump handle;
         require
           (Test.Handle.find handle (Test.Query.test_id "journal-diagnostics-dialog-page")
            = None)
           "native Close did not dismiss Diagnostics"
       | Some catalog ->
         !emit
           (Service.Client_state_changed
              { snapshot =
                  { sync_phase = Offline
                  ; catalog
                  ; selected_graph = None
                  ; applied_server_t = None
                  ; timeline_presentation_pending = false
                  ; startup =
                      { authenticated = true
                      ; catalog_loading = false
                      ; awaiting_selection = true
                      ; restoring_local = false
                      ; bootstrapping = false
                      ; awaiting_e2ee_password = false
                      ; failure = None
                      ; account_generation = 1
                      ; graph_generation = 1
                      ; presentation_generation = 1
                      }
                  ; last_error = None
                  ; local_deletion = None
                  }
              ; diagnostics = { groups = [] }
              });
         pump handle;
         press handle epoch 2L "graph-picker-refresh";
         pump handle;
         if catalog <> []
         then (
           press handle epoch 3L ("graph-picker:" ^ Graph.Uuid.to_string graph_id);
           pump handle));
  Printf.printf "NATIVE_BUTTON_SEMANTICS_PASSED %s\n" name
;;

(* Startup's public pure state already reports the E2ee recovery correctly.
   Missing password controls belong to the application presentation boundary. *)
let test_native_unlock_recovery () =
  List.iter
    (fun (failed, named) ->
       let epoch = ID.Runtime.Epoch.of_int64 (if failed then 8011L else 8010L) in
       let handle =
         Test.Handle.create_app
           ~runtime_epoch:epoch
           ~time_source:(Bonsai.Time_source.create ~start:Core.Time_ns.epoch)
           (Application.For_testing.app_with_service service)
           ~application_payload
       in
       Fun.protect
         ~finally:(fun () -> Test.Handle.shutdown handle)
         (fun () ->
            pump handle;
            let snapshot : Service.snapshot =
              { sync_phase = Offline
              ; catalog =
                  (if named
                   then
                     [ { graph_id
                       ; name = "Research journal — 中文 👩🏽‍💻"
                       ; schema = { major = 1; minor = 0; exact = false }
                       ; encrypted = true
                       }
                     ]
                   else [])
              ; selected_graph = Some graph_id
              ; applied_server_t = None
              ; timeline_presentation_pending = false
              ; startup =
                  { authenticated = true
                  ; catalog_loading = false
                  ; awaiting_selection = false
                  ; restoring_local = false
                  ; bootstrapping = false
                  ; awaiting_e2ee_password = not failed
                  ; failure = (if failed then Some During_e2ee else None)
                  ; account_generation = 1
                  ; graph_generation = 1
                  ; presentation_generation = 1
                  }
              ; last_error =
                  (if failed then Some "Incorrect encryption password" else None)
              ; local_deletion = None
              }
            in
            !emit
              (Service.Client_state_changed { snapshot; diagnostics = { groups = [] } });
            pump handle;
            require
              (Test.Handle.find handle (Test.Query.test_id "e2ee-password-editor") <> None)
              "unlock recovery omitted the password editor";
            require
              (Test.Handle.find handle (Test.Query.test_id "e2ee-password-cancel") <> None)
              "unlock omitted its native Cancel action";
            require
              (Test.Handle.find
                 handle
                 (Test.Query.visible_text
                    (if named then "Research journal — 中文 👩🏽‍💻" else "Encrypted graph"))
               <> None)
              "unlock omitted readable graph context";
            require
              (Test.Handle.find handle (Test.Query.visible_text "Choose another graph")
               <> None)
              "unlock cancellation does not explain its destination";
            if failed
            then
              require
                (Test.Handle.find
                   handle
                   (Test.Query.visible_text "Incorrect encryption password")
                 <> None)
                "unlock recovery omitted the inline failure";
            client_commands := [];
            let field () =
              Test.Handle.find handle (Test.Query.kind "secure_field") |> Option.get
            in
            let editor_state () =
              let node = field () in
              let (Av view) = Bonsai_swiftui_ui.View.Private.view node.widget in
              match view.node with
              | Text_field { session_id; value; secure; _ } ->
                require secure "unlock input lost secure semantics";
                session_id, Bonsai_swiftui_ui.Text_editing.Value.text value
              | _ -> failwith "unlock editor is not a native secure field"
            in
            let edit_password sequence text =
              let node = field () in
              let (Av view) = Bonsai_swiftui_ui.View.Private.view node.widget in
              let session_id, local_revision, base_document_revision =
                match view.node with
                | Text_field { session_id; accepted_local_revision; document_revision; _ }
                  ->
                  ( session_id
                  , ID.Text_input.Local_revision.succ accepted_local_revision
                  , document_revision )
                | _ -> failwith "unlock editor is not a native text input"
              in
              let binding =
                Array.find_opt
                  (fun binding ->
                     Bonsai_swiftui_ui.Event.Tag.equal
                       binding
                         .Bonsai_swiftui_runtime.Mounted_tree.Mounted_binding.event_tag
                       Bonsai_swiftui_ui.Event.Tag.Text_edit)
                  node.event_bindings
                |> Option.get
              in
              let cursor = Bonsai_swiftui_ui.Text_editing.Utf16.length text in
              let event : Wire.Inbound_event.t =
                { sequence = ID.Runtime.Event_sequence.of_int64 sequence
                ; displayed_revision = Test.Handle.revision handle
                ; node_id = node.node_id
                ; handler_id = binding.handler_id
                ; event_tag = Wire.Generated_protocol.Event_tag.text_edit
                ; payload =
                    Text_edit
                      { session_id
                      ; local_revision
                      ; base_document_revision
                      ; text
                      ; selection = { start_utf16 = cursor; end_utf16 = cursor }
                      ; composing = None
                      }
                }
              in
              Test.Handle.pump_next
                handle
                ~events:{ runtime_epoch = epoch; events = [ event ] }
                ();
              pump handle;
              require (snd (editor_state ()) = text) "unlock did not admit native input"
            in
            let keyboard_submit sequence =
              let node = field () in
              let binding =
                Array.find_opt
                  (fun binding ->
                     Bonsai_swiftui_ui.Event.Tag.equal
                       binding
                         .Bonsai_swiftui_runtime.Mounted_tree.Mounted_binding.event_tag
                       Bonsai_swiftui_ui.Event.Tag.Text_submit)
                  node.event_bindings
                |> Option.get
              in
              let event : Wire.Inbound_event.t =
                { sequence = ID.Runtime.Event_sequence.of_int64 sequence
                ; displayed_revision = Test.Handle.revision handle
                ; node_id = node.node_id
                ; handler_id = binding.handler_id
                ; event_tag = Wire.Generated_protocol.Event_tag.text_submit
                ; payload = Text (snd (editor_state ()))
                }
              in
              Test.Handle.pump_next
                handle
                ~events:{ runtime_epoch = epoch; events = [ event ] }
                ()
            in
            keyboard_submit 2L;
            pump handle;
            require (!client_commands = []) "empty unlock submitted a password";
            edit_password 3L "synthetic first attempt";
            let submitted_session = fst (editor_state ()) in
            press handle epoch 4L "e2ee-password-submit";
            pump handle;
            require
              (!client_commands
               = [ Service.Submit_e2ee_password "synthetic first attempt" ])
              "unlock did not submit exactly the entered password";
            let fresh_session, source = editor_state () in
            require (source = "") "unlock retained submitted secret input";
            require
              (not (ID.Text_input.Session_id.equal submitted_session fresh_session))
              "unlock reused the submitted editor session";
            let retry_snapshot =
              { snapshot with
                startup =
                  { snapshot.startup with
                    awaiting_e2ee_password = false
                  ; failure = Some During_e2ee
                  }
              ; last_error = Some "Incorrect encryption password"
              }
            in
            !emit
              (Service.Client_state_changed
                 { snapshot = retry_snapshot; diagnostics = { groups = [] } });
            pump handle;
            require
              (Test.Handle.find
                 handle
                 (Test.Query.visible_text "Incorrect encryption password")
               <> None)
              "retry omitted the inline failure";
            client_commands := [];
            edit_password 5L "synthetic correction 中文";
            keyboard_submit 6L;
            pump handle;
            require
              (!client_commands
               = [ Service.Submit_e2ee_password "synthetic correction 中文" ])
              "retry did not submit exactly the corrected password";
            require (snd (editor_state ()) = "") "retry retained submitted secret input";
            edit_password 7L "synthetic canceled input";
            client_commands := [];
            press handle epoch 8L "e2ee-password-cancel";
            pump handle;
            require
              (List.mem Service.Return_to_graph_picker !client_commands)
              "Cancel did not return to graph selection";
            require
              (not
                 (List.exists
                    (function
                      | Service.Submit_e2ee_password _ -> true
                      | _ -> false)
                    !client_commands))
              "Cancel submitted an encryption password"))
    [ true, true; false, true; true, false; false, false ];
  print_endline "NATIVE_UNLOCK_RECOVERY_PASSED"
;;

let () = test_native_unlock_recovery ()

let () =
  let failures =
    List.filter_map
      (fun (name, catalog) ->
         try
           test_native_button_semantics name catalog;
           None
         with
         | exn -> Some (name ^ ": " ^ Printexc.to_string exn))
      [ "settings", None
      ; "empty picker", Some []
      ; ( "populated picker"
        , Some
            [ { Logseq_db_types.Managed_graph.graph_id
              ; name = "Native graph"
              ; schema = { major = 65; minor = 33; exact = true }
              ; encrypted = false
              }
            ] )
      ]
  in
  if failures <> [] then failwith (String.concat "\n" failures);
  print_endline "NATIVE_BUTTON_SUITE_PASSED"
;;

(* Application owns feed failure presentation. Root_navigation's public reducer
   cannot receive the manager snapshot or expose the rendered root choice. *)
let () =
  List.iter
    (fun (managed, presentation_pending) ->
       let epoch = ID.Runtime.Epoch.of_int64 (if managed then 8021L else 8020L) in
       initial_feed_failure := true;
       let handle =
         Test.Handle.create_app
           ~runtime_epoch:epoch
           ~time_source:(Bonsai.Time_source.create ~start:Core.Time_ns.epoch)
           (Application.For_testing.app_with_service service)
           ~application_payload
       in
       Fun.protect
         ~finally:(fun () ->
           initial_feed_failure := false;
           Test.Handle.shutdown handle)
         (fun () ->
            pump handle;
            let publish_manager generation =
              if managed
              then (
                let snapshot : Service.snapshot =
                  { sync_phase = Current
                  ; catalog = []
                  ; selected_graph = Some graph_id
                  ; applied_server_t = Some 0
                  ; timeline_presentation_pending = presentation_pending
                  ; startup =
                      { authenticated = true
                      ; catalog_loading = false
                      ; awaiting_selection = false
                      ; restoring_local = false
                      ; bootstrapping = false
                      ; awaiting_e2ee_password = false
                      ; failure = None
                      ; account_generation = 1
                      ; graph_generation = generation
                      ; presentation_generation = generation
                      }
                  ; last_error = None
                  ; local_deletion = None
                  }
                in
                !emit
                  (Service.Client_state_changed
                     { snapshot; diagnostics = { groups = [] } });
                pump handle)
            in
            let publish_graph generation =
              !emit
                (Service.Graph_state_changed
                   { generation
                   ; graph_id = Some graph_id
                   ; phase = Graph_open
                   ; error = None
                   });
              pump handle
            in
            publish_manager 1;
            publish_graph 1;
            require
              (Test.Handle.find
                 handle
                 (Test.Query.visible_text "Journal fixture read failed")
               <> None)
              "Initial feed failure was hidden by the startup presentation";
            require
              (Test.Handle.find handle (Test.Query.visible_text "Opening journal") = None)
              "Terminal feed failure still presented a loading spinner";
            let node =
              Test.Handle.find handle (Test.Query.test_id "logseq-graph-open-failed")
              |> Option.get
            in
            let module V = Bonsai_swiftui_ui.View in
            let (Av view) = V.Private.view node.widget in
            (match view.node with
             | V.Private.Content_unavailable -> ()
             | _ -> failwith "Graph failure is not a public ContentUnavailable view");
            press handle epoch 2L "graph-failure-details";
            pump handle;
            require
              (Test.Handle.find handle (Test.Query.test_id "journal-error-info-page")
               <> None)
              "Graph failure details action did not open the retained worker error";
            press handle epoch 3L "journal-error-info-close";
            pump handle;
            if managed
            then (
              client_commands := [];
              press handle epoch 4L "graph-failure-choose";
              pump handle;
              require
                (List.mem Service.Return_to_graph_picker !client_commands)
                "Graph recovery did not return to graph selection");
            initial_feed_failure := false;
            publish_manager 2;
            if managed
            then
              require
                (Test.Handle.find handle (Test.Query.test_id "logseq-graph-open-failed")
                 = None)
                "A new manager generation displayed the previous graph failure";
            publish_graph 2;
            require
              (Test.Handle.find handle (Test.Query.test_id "logseq-graph-open-failed")
               = None)
              "Recovered graph retained the unavailable presentation";
            require
              (Test.Handle.find handle (Test.Query.test_id "journal-timeline") <> None)
              "Recovered graph did not return to its journal"))
    [ true, false; true, true; false, false ];
  print_endline "NATIVE_GRAPH_FAILURE_RECOVERY_PASSED"
;;

(* The public Application reducer cannot admit status/delete actions. Exercise
   their production admission and rendered feedback through native events. *)
let () =
  List.iter
    (fun delete ->
       let epoch = ID.Runtime.Epoch.of_int64 (if delete then 8031L else 8030L) in
       deleted := false;
       mutation_failure := true;
       let handle =
         Test.Handle.create_app
           ~runtime_epoch:epoch
           ~time_source:(Bonsai.Time_source.create ~start:Core.Time_ns.epoch)
           (Application.For_testing.app_with_service service)
           ~application_payload
       in
       Fun.protect
         ~finally:(fun () ->
           mutation_failure := false;
           Test.Handle.shutdown handle)
         (fun () ->
            pump handle;
            let publish_graph generation =
              !emit
                (Service.Graph_state_changed
                   { generation
                   ; graph_id = Some graph_id
                   ; phase = Graph_open
                   ; error = None
                   });
              pump handle
            in
            publish_graph 1;
            let list_id () =
              (Test.Handle.find handle (Test.Query.test_id "journal-timeline")
               |> Option.get)
                .node_id
            in
            let initial_list_id = list_id () in
            let submit sequence =
              if delete
              then native_delete handle epoch sequence
              else (
                native_timeline_action handle epoch sequence "status";
                pump handle;
                select_picker handle epoch (Int64.succ sequence) 1L);
              pump handle
            in
            let initial_writes = !deletes + !status_writes in
            submit 2L;
            ignore (Test.Handle.pump handle ~monotonic_now_ns:6_000_000_000L ());
            pump handle;
            let summary = if delete then "Delete failed" else "Status not changed" in
            require
              (Test.Handle.find handle (Test.Query.visible_text summary) <> None)
              "Mutation failure has no persistent inline feedback";
            require
              (list_id () = initial_list_id)
              "Mutation feedback remounted the native journal list";
            require (not !deleted) "Failed deletion did not restore the block";
            let writes = !deletes + !status_writes in
            require
              (writes = initial_writes + 1)
              "Fixture did not execute the requested mutation failure";
            ignore (Test.Handle.pump handle ~monotonic_now_ns:60_000_000_000L ());
            pump handle;
            require
              (Test.Handle.find handle (Test.Query.visible_text summary) <> None)
              "Mutation recovery disappeared after the old notice timeout";
            native_timeline_action handle epoch 4L "open";
            pump handle;
            require
              (Test.Handle.find handle (Test.Query.test_id "detail-operation-details")
               <> None)
              "Opening Detail lost the mutation recovery actions";
            press handle epoch 5L "detail-operation-details";
            pump handle;
            require
              (Test.Handle.find handle (Test.Query.test_id "journal-error-info-page")
               <> None)
              "Mutation details did not open the native error sheet";
            require
              (Test.Handle.find
                 handle
                 (Test.Query.visible_text
                    (if delete
                     then
                       "The block has been restored. Review it before trying Delete \
                        again."
                     else
                       "The block keeps its current status. Open its Status menu to try \
                        again."))
               <> None)
              "Mutation details omitted contextual recovery guidance";
            press handle epoch 6L "journal-error-info-close";
            pump handle;
            native_back handle epoch 7L;
            pump handle;
            press handle epoch 8L "root-operation-dismiss";
            pump handle;
            require
              (Test.Handle.find handle (Test.Query.visible_text summary) = None)
              "Dismiss did not clear persistent feedback";
            require
              (!deletes + !status_writes = writes)
              "Reading or dismissing mutation feedback retried a write";
            submit 9L;
            ignore (Test.Handle.pump handle ~monotonic_now_ns:66_000_000_000L ());
            pump handle;
            require
              (Test.Handle.find handle (Test.Query.visible_text summary) <> None)
              "A later failed operation did not show feedback again";
            publish_graph 2;
            require
              (Test.Handle.find handle (Test.Query.visible_text summary) = None)
              "Graph replacement leaked the previous operation failure"))
    [ false; true ];
  print_endline "PERSISTENT_MUTATION_FEEDBACK_PASSED"
;;

(* Journal_startup.derive correctly reports Failed and online recovery. The
   public pure owners do not expose manager-page action construction. Exercise
   that production presentation and dispatch through the native event harness. *)
let test_startup_graph_selection_recovery () =
  List.iteri
    (fun index (failure, phase, selected, deletion, choose, retry) ->
       let epoch = ID.Runtime.Epoch.of_int64 (Int64.of_int (9100 + index)) in
       let handle =
         Test.Handle.create_app
           ~runtime_epoch:epoch
           ~time_source:(Bonsai.Time_source.create ~start:Core.Time_ns.epoch)
           (Application.For_testing.app_with_service service)
           ~application_payload
       in
       Fun.protect
         ~finally:(fun () -> Test.Handle.shutdown handle)
         (fun () ->
            pump handle;
            let selected_graph = if selected then Some graph_id else None in
            let snapshot : Service.snapshot =
              { sync_phase = Offline
              ; catalog = []
              ; selected_graph
              ; applied_server_t = None
              ; timeline_presentation_pending = false
              ; startup =
                  { authenticated = true
                  ; catalog_loading = false
                  ; awaiting_selection = false
                  ; restoring_local = false
                  ; bootstrapping = false
                  ; awaiting_e2ee_password = false
                  ; failure
                  ; account_generation = 1
                  ; graph_generation = 1
                  ; presentation_generation = 1
                  }
              ; last_error = Some "Local graph cannot open"
              ; local_deletion = deletion
              }
            in
            !emit
              (Service.Client_state_changed { snapshot; diagnostics = { groups = [] } });
            pump handle;
            !emit
              (Service.Graph_state_changed
                 { generation = 1; graph_id = selected_graph; phase; error = None });
            pump handle;
            require
              (Test.Handle.find handle (Test.Query.test_id "graph-picker-retry")
               <> None
               = retry)
              (Printf.sprintf
                 "Startup failure case %d changed its retry availability"
                 index);
            require
              (Test.Handle.find handle (Test.Query.test_id "graph-picker-choose")
               <> None
               = choose)
              (Printf.sprintf
                 "Startup failure case %d omitted graph selection, or exposed it during \
                  deletion"
                 index);
            if choose
            then (
              require
                (Test.Handle.find handle (Test.Query.visible_text "Choose another graph")
                 <> None)
                "Startup graph selection did not explain its destination";
              client_commands := [];
              press handle epoch 2L "graph-picker-choose";
              pump handle;
              require
                (!client_commands = [ Service.Return_to_graph_picker ])
                (Printf.sprintf
                   "Choosing another graph case %d dispatched %d commands (%d picker)"
                   index
                   (List.length !client_commands)
                   (List.length
                      (List.filter
                         (fun c -> c = Service.Return_to_graph_picker)
                         !client_commands))))))
    [ ( Some Service.During_local_restore
      , Logseq_db_worker.Graph_closed
      , true
      , None
      , true
      , true )
    ; Some Service.During_bootstrap, Graph_closed, true, None, true, true
    ; None, Graph_failed, true, None, true, true
    ; Some Service.During_local_restore, Graph_closed, false, None, false, true
    ; ( None
      , Graph_closed
      , true
      , Some (Service.Deletion_failed Service.Closing_graph)
      , false
      , false )
    ];
  print_endline "NATIVE_STARTUP_GRAPH_SELECTION_RECOVERY_PASSED"
;;

let () = test_startup_graph_selection_recovery ()

(* Startup derivation owns phases, but has no rendered-action interface. These
   valid pending snapshots reproduce the omission in the presentation owner. *)
let test_pending_startup_graph_selection () =
  List.iteri
    (fun index
      ( authenticated
      , selected
      , catalog_loading
      , bootstrapping
      , deletion
      , expected_phase
      , choose ) ->
       let epoch = ID.Runtime.Epoch.of_int64 (Int64.of_int (9200 + index)) in
       let handle =
         Test.Handle.create_app
           ~runtime_epoch:epoch
           ~time_source:(Bonsai.Time_source.create ~start:Core.Time_ns.epoch)
           (Application.For_testing.app_with_service service)
           ~application_payload
       in
       Fun.protect
         ~finally:(fun () -> Test.Handle.shutdown handle)
         (fun () ->
            pump handle;
            let selected_graph = if selected then Some graph_id else None in
            let snapshot : Service.snapshot =
              { sync_phase = Offline
              ; catalog = []
              ; selected_graph
              ; applied_server_t = None
              ; timeline_presentation_pending = false
              ; startup =
                  { authenticated
                  ; catalog_loading
                  ; awaiting_selection = false
                  ; restoring_local = (not catalog_loading) && not bootstrapping
                  ; bootstrapping
                  ; awaiting_e2ee_password = false
                  ; failure = None
                  ; account_generation = 1
                  ; graph_generation = 1
                  ; presentation_generation = 1
                  }
              ; last_error = None
              ; local_deletion = deletion
              }
            in
            let graph : Logseq_db_worker.graph_state =
              { generation = 1
              ; graph_id = selected_graph
              ; phase = Graph_closed
              ; error = None
              }
            in
            let startup = Journal_startup.derive ~snapshot ~graph in
            require
              (startup.phase = expected_phase && startup.error = None)
              "Public startup derivation did not identify the valid pending phase";
            !emit
              (Service.Client_state_changed { snapshot; diagnostics = { groups = [] } });
            pump handle;
            !emit (Service.Graph_state_changed graph);
            pump handle;
            require
              (Test.Handle.find handle (Test.Query.test_id "graph-picker-choose")
               <> None
               = choose)
              (Printf.sprintf
                 "Pending startup case %d lost graph selection or exposed an unsafe exit"
                 index);
            if choose
            then (
              client_commands := [];
              press handle epoch 2L "graph-picker-choose";
              pump handle;
              require
                (!client_commands = [ Service.Return_to_graph_picker ])
                "Leaving pending startup retried or mutated a graph")))
    [ true, true, true, false, None, Journal_startup.Loading_catalog, true
    ; true, true, false, false, None, Restoring_local, true
    ; true, true, false, true, None, Bootstrapping, true
    ; true, false, true, false, None, Loading_catalog, false
    ; false, true, false, false, None, Signed_out, false
    ; ( true
      , true
      , false
      , false
      , Some (Service.Deletion_in_progress Service.Closing_graph)
      , Deleting_local
      , false )
    ];
  print_endline "NATIVE_PENDING_STARTUP_GRAPH_SELECTION_PASSED"
;;

let () = test_pending_startup_graph_selection ()

let test_confirmation_token_ownership () =
  let epoch = ID.Runtime.Epoch.of_int64 8040L in
  let handle =
    Test.Handle.create_app
      ~runtime_epoch:epoch
      ~time_source:(Bonsai.Time_source.create ~start:Core.Time_ns.epoch)
      (Application.For_testing.app_with_service service)
      ~application_payload
  in
  Fun.protect
    ~finally:(fun () -> Test.Handle.shutdown handle)
    (fun () ->
       pump handle;
       !emit
         (Service.Client_state_changed
            { snapshot =
                { sync_phase = Current
                ; catalog = []
                ; selected_graph = Some graph_id
                ; applied_server_t = Some 0
                ; timeline_presentation_pending = false
                ; startup =
                    { authenticated = true
                    ; catalog_loading = false
                    ; awaiting_selection = false
                    ; restoring_local = false
                    ; bootstrapping = false
                    ; awaiting_e2ee_password = false
                    ; failure = None
                    ; account_generation = 1
                    ; graph_generation = 1
                    ; presentation_generation = 1
                    }
                ; last_error = None
                ; local_deletion = None
                }
            ; diagnostics = { groups = [] }
            });
       pump handle;
       !emit
         (Service.Graph_state_changed
            { generation = 1; graph_id = Some graph_id; phase = Graph_open; error = None });
       pump handle;
       let current () =
         let node =
           Test.Handle.find handle (Test.Query.test_id "local-cache-reset-confirmation")
           |> Option.get
         in
         let (Av view) = Bonsai_swiftui_ui.View.Private.view node.widget in
         match view.node with
         | Bonsai_swiftui_ui.View.Private.Confirmation { request_token; _ } ->
           node, request_token
         | _ -> failwith "cache deletion must use public Confirmation"
       in
       let respond ?owner sequence token action_key =
         let node = Option.value owner ~default:(fst (current ())) in
         let binding =
           Array.find_opt
             (fun binding ->
                Bonsai_swiftui_ui.Event.Tag.equal
                  binding.Bonsai_swiftui_runtime.Mounted_tree.Mounted_binding.event_tag
                  Bonsai_swiftui_ui.Event.Tag.Confirmation_response)
             node.event_bindings
           |> Option.get
         in
         let event : Wire.Inbound_event.t =
           { sequence = ID.Runtime.Event_sequence.of_int64 sequence
           ; displayed_revision = Test.Handle.revision handle
           ; node_id = node.node_id
           ; handler_id = binding.handler_id
           ; event_tag = Wire.Generated_protocol.Event_tag.confirmation_response
           ; payload = Confirmation_response { token; action_key }
           }
         in
         Test.Handle.pump_next
           handle
           ~events:{ runtime_epoch = epoch; events = [ event ] }
           ();
         pump handle
       in
       select_account handle epoch 2L 3L;
       pump handle;
       let _, first = current () in
       let first = Option.get first in
       client_commands := [];
       respond 3L first (Some "cancel");
       require
         (snd (current ()) = None && !client_commands = [])
         "cancel deleted local storage";
       select_account handle epoch 4L 3L;
       pump handle;
       let second = snd (current ()) |> Option.get in
       require (second > first) "reopening reused a confirmation token";
       respond 5L first (Some "delete");
       require
         (snd (current ()) = Some second && !client_commands = [])
         "stale confirmation accepted";
       respond 6L second None;
       require
         (snd (current ()) = None && !client_commands = [])
         "dismissal deleted local storage";
       select_account handle epoch 7L 3L;
       pump handle;
       let third = snd (current ()) |> Option.get in
       let owner = fst (current ()) in
       respond 8L third (Some "delete");
       respond ~owner 9L third (Some "delete");
       require
         (!client_commands = [ Service.Delete_local_cache graph_id ])
         "confirmation must emit exactly one cache reset";
       print_endline "CONFIRMATION_TOKEN_OWNERSHIP_PASSED")
;;

let () = test_confirmation_token_ownership ()

let () =
  let epoch = ID.Runtime.Epoch.of_int64 8900L in
  let now = ref 1_788_192_000. in
  journal_ranges := [];
  initial_feed_failure := false;
  let sampler =
    Journal_calendar.Sampler.create ~clock:(fun () -> !now) ~localtime:Unix.gmtime ()
  in
  let handle =
    Test.Handle.create_app
      ~runtime_epoch:epoch
      ~time_source:(Bonsai.Time_source.create ~start:Core.Time_ns.epoch)
      (Application.For_testing.app_with_service ~calendar_sampler:sampler service)
      ~application_payload
  in
  Fun.protect
    ~finally:(fun () -> Test.Handle.shutdown handle)
    (fun () ->
       export_frame handle;
       pump handle;
       !emit
         (Service.Graph_state_changed
            { generation = 1; graph_id = Some graph_id; phase = Graph_open; error = None });
       pump handle;
       Test.Handle.native_event
         handle
         (Test.Query.key (Bonsai_swiftui_ui.Key.string "asset-settings"))
         ~kind_id:(ID.Native_widget.Kind_id.of_int 2106)
         ~version:1
         ~event_id:(ID.Native_widget.Event_id.of_int 1)
         ~payload:(Bytes.of_string "days:2");
       pump handle;
       require
         (List.mem (20260830, 20260831) !journal_ranges)
         "saved preference did not scope asset enumeration";
       let before = !journal_ranges in
       require (before <> []) "calendar probe did not open a feed";
       now := !now +. 86400.;
       ignore (Test.Handle.pump handle ~monotonic_now_ns:61_000_000_000L ());
       pump handle;
       require (!journal_ranges <> before) "foreground midnight did not refresh the feed";
       require
         (List.mem (20260831, 20260901) !journal_ranges)
         "foreground midnight did not refresh the two-day asset interval";
       let after = !journal_ranges in
       ignore (Test.Handle.pump handle ~monotonic_now_ns:121_000_000_000L ());
       pump handle;
       require (!journal_ranges = after) "unchanged calendar restarted enumeration";
       print_endline "FOREGROUND_CALENDAR_REFRESH_PASSED")
;;

let () = print_endline "MACOS_APPLICATION_DISPATCH_TESTS_PASSED"
