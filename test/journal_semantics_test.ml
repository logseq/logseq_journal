module Graph_service = Logseq_db_worker_bonsai.Logseq_db_worker_bonsai_service
module ID = Bonsai_swiftui_spec.Id
module Protocol = Bonsai_swiftui_protocol
module Test = Bonsai_swiftui_test
module Ui = Bonsai_swiftui_ui
module Graph = Logseq_db_types.Graph_types

let fail format = Printf.ksprintf failwith format

let require condition format =
  Printf.ksprintf (fun message -> if not condition then failwith message) format
;;

let require_ok = function
  | Ok value -> value
  | Error error -> fail "unexpected fixture rejection: %s" error
;;

let block_id = "20000000-0000-4000-a000-000000000001"
let page_id = "20000000-0000-4000-b000-000000000001"
let mutation_id = "20000000-0000-4000-9000-000000000001"

let creation_time =
  Journal_time.create
    ~instant_unix_ms:1_786_237_500_000L
    ~local_day:20260809
    ~local_minute_of_day:545
  |> require_ok
;;

let block
      ?(source = "Literal #journal @person 👩🏽‍💻")
      ?(task_state = Journal_model.Done)
      ?(child_count = 3)
      ()
  =
  Journal_model.create
    ~id:block_id
    ~page_id
    ~journal_day:20260809
    ~parent_id:None
    ~sibling_order:"000000000001"
    ~source
    ~task_state
    ~child_count
    ~creation_time
    ~revision:"block-4"
    ~last_mutation_id:mutation_id
  |> require_ok
;;

module V = Ui.View

let with_handle handle run =
  Fun.protect
    ~finally:(fun () -> Test.Handle.shutdown handle)
    (fun () ->
       Test.Handle.present handle;
       run handle)
;;

let require_semantics handle label check =
  match Test.Handle.find_all handle (Test.Query.semantics_label label) with
  | [ node ] ->
    let (Av view) = V.Private.view node.widget in
    (match view.node with
     | V.Private.Semantics props -> check props
     | _ -> fail "expected semantics")
  | nodes -> fail "expected one semantic label %S, got %d" label (List.length nodes)
;;

let header_component sync_phase _handlers _graph =
  let handler = Ui.Event.Handler.create (fun _ -> ()) in
  Bonsai.Cont.return
    (Journal_header.view
       ~platform:"macos"
       ~key:(Ui.Key.string "test-header")
       ~context:Journal_header.Context.journals
       ~sync_phase
       ~sync_error:None
       ~on_error_info:None
       ~on_account_action:(Some handler)
       ~local_deletion_available:false
       ~on_journals:handler
       ~on_favorites:handler
       ~on_capture:handler
       ~capture_enabled:true
       ~body:(V.Body.static (V.empty ()))
     |> V.Body.Private.to_widget)
;;

let with_component component run =
  Test.Handle.create
    ~runtime_epoch:(ID.Runtime.Epoch.of_int64 7002L)
    ~time_source:(Bonsai.Time_source.create ~start:Core.Time_ns.epoch)
    component
  |> fun handle -> with_handle handle run
;;

let test_header_account_action_and_view_only_date_have_truthful_semantics () =
  with_component (header_component None) (fun handle ->
    require
      (Test.Handle.find handle (Test.Query.kind "toolbar") <> None)
      "journal controls must use the public Toolbar";
    require
      (Option.is_none
         (Test.Handle.find handle (Test.Query.test_id "journal-header-title")))
      "Journals must not retain a fixed toolbar date";
    require
      (Option.is_some
         (Test.Handle.find handle (Test.Query.test_id "journal-floating-chrome")))
      "Journals must place account controls in floating chrome";
    require
      (List.length (Test.Handle.find_all handle (Test.Query.kind "button")) = 3)
      "date context became actionable";
    require_semantics handle "Account menu" (fun props ->
      require (props.role = Button) "account role changed";
      require
        (props.hint = Some "Switch graphs, delete the local copy, or sign out")
        "account actions hint lost"))
;;

let test_header_sync_progress_tracks_every_sync_phase () =
  List.iter
    (fun phase ->
       with_component (header_component phase) (fun handle ->
         require
           (Option.is_some
              (Test.Handle.find
                 handle
                 (Test.Query.test_id "journal-header-sync-progress"))
            = (phase = Some Graph_service.Connecting))
           "progress visibility changed";
         require
           (Option.is_none
              (Test.Handle.find handle (Test.Query.test_id "journal-header-title")))
           "sync phase restored the fixed toolbar date"))
    [ None
    ; Some Graph_service.Connecting
    ; Some Offline
    ; Some Pulling
    ; Some Submitting
    ; Some Current
    ; Some Paused
    ; Some Failed
    ]
;;

let timeline_component
      ?source
      ?(child_summaries = [])
      ~task_state
      ~enabled
      _handlers
      _graph
  =
  let timeline =
    Journal_timeline_state.empty ~today:20260809
    |> fun state ->
    Journal_timeline_state.begin_request state ~generation:1L (Feed { before_day = None })
  in
  let timeline =
    Journal_timeline_state.apply_feed
      timeline
      ~generation:1L
      { Journal_graph_projection.days =
          [ { page = { id = page_id; day = 20260809; title = "Today" }
            ; entries = [ { block = block ?source ~task_state (); child_summaries } ]
            ; has_more_entries = false
            ; continuation = None
            }
          ]
      ; slot_count = 1
      ; has_more_days = false
      }
  in
  let ignored = Ui.Event.Handler.create (fun _ -> ()) in
  Bonsai.Cont.return
    (Journal_timeline.view
       ~render_media:(fun ~root:_ child -> child)
       ~state:timeline
       ~day_presentation:(fun _ -> None)
       ~on_visible_range:ignored
       ~on_scroll_completed:ignored
       ~on_retry_day:ignored
       ~on_open_block:ignored
       ~delete_enabled:enabled
       ~actions_enabled:enabled
       ~on_status:ignored
       ~on_delete:ignored
     |> V.Body.Private.to_widget)
;;

let test_swipe_exact_statuses_and_explicit_delete () =
  let check handle enabled =
    let node =
      Test.Handle.find handle (Test.Query.test_id "journal-timeline") |> Option.get
    in
    let (Av view) =
      V.Private.view node.Bonsai_swiftui_runtime.Mounted_tree.Snapshot.widget
    in
    match view.node with
    | V.Private.Native_list _ ->
      let actions = Test.Handle.find_all handle (Test.Query.kind "swipe_action") in
      require (List.length actions = 2) "journal row lost status/delete swipes";
      List.iter
        (fun node ->
           let (Av view) =
             V.Private.view node.Bonsai_swiftui_runtime.Mounted_tree.Snapshot.widget
           in
           match view.node with
           | V.Private.Swipe_action props ->
             require (props.enabled = enabled) "row action enabled state changed"
           | _ -> fail "expected swipe action")
        actions;
      require
        (List.length (Test.Handle.find_all handle (Test.Query.kind "navigation_link")) = 1)
        "journal row must activate through a public Navigation_link"
    | _ -> fail "timeline is not a public native List"
  in
  List.iter
    (fun task_state ->
       with_component (timeline_component ~task_state ~enabled:true) (fun handle ->
         check handle true;
         if task_state <> Journal_model.No_status
         then
           require
             (Test.Handle.find
                handle
                (Test.Query.visible_text (Journal_model.status_name task_state))
              <> None)
             "native row lost its readable task status"))
    [ Journal_model.No_status
    ; Todo
    ; Doing
    ; Done
    ; Backlog
    ; In_review
    ; Canceled
    ; Now
    ; Waiting
    ; Later
    ];
  with_component (timeline_component ~task_state:Done ~enabled:false) (fun handle ->
    check handle false)
;;

let warm_start_test_service () =
  Worker.Service.create
    ~push_topic_count:6
    ~concurrency:Worker.Service.Serial
    ~init:(fun _context (_config : Journal_startup.t) -> Ok ())
    ~handle:(fun _context () request ->
      match (request : Graph_service.request) with
      | Get_graph_state ->
        Ok
          (Graph_service.Graph_state
             { generation = 0; graph_id = None; phase = Graph_closed; error = None })
      | Import_asset _ -> Ok (Asset_imported (Error "Import unavailable in fixture"))
      | Asset_command _ | Release_asset_file _ -> Ok Client_command_completed
      | Acquire_asset_file _ | Acquire_imported_file _ -> Ok (Asset_file None)
      | Client_command _ -> Ok Client_command_completed
      | Graph_request request ->
        let error =
          Logseq_db_worker.Error.create
            ~code:Closed_session
            ~message:"The test graph is closed."
            ~details:[]
          |> Result.get_ok
        in
        Ok
          (Graph_response
             (Logseq_db_worker.Protocol.failed ~request_id:request.request_id error)))
    ~shutdown:(fun () -> ())
    ()
;;

let warm_start_application_payload () =
  Logseq_db_worker.Config.create
    ~application_support_directory:"/tmp/logseq-journal-warm-start-ordering"
    ~target:(Managed_sync { base_url = "https://api.logseq.io" })
    ~compatibility_profile:Logseq_65_33_or_newer
    ~response_budget_bytes:Logseq_db_worker.Protocol.maximum_response_bytes
    ~default_page_size:Logseq_db_worker.Protocol.default_page_size
  |> Result.get_ok
  |> Journal_startup.encode
  |> Result.fold ~ok:Fun.id ~error:(fun error ->
    fail "%s" (Journal_startup.Error.to_string error))
;;

let application_requests handle =
  match Test.Handle.last_frame handle with
  | None -> fail "warm-start application emitted no frame"
  | Some frame ->
    (match Bonsai_swiftui_protocol.Binary_codec.decode frame.bytes with
     | Error error -> fail "warm-start frame did not decode: %s" error.message
     | Ok wire ->
       List.filter_map
         (function
           | Bonsai_swiftui_protocol.Wire_frame.Application_request
               { request_id; payload } -> Some (request_id, payload)
           | _ -> None)
         wire.operations)
;;

let request_id_for_payload requests payload =
  List.find_map
    (fun (request_id, request_payload) ->
       if Bytes.equal request_payload payload then Some request_id else None)
    requests
;;

let network_lifecycle_packet ~kind ~generation =
  let payload = Bytes.make 16 '\000' in
  Bytes.blit_string "LJP1" 0 payload 0 4;
  Bytes.set_uint16_le payload 4 1;
  Bytes.set_uint16_le payload 6 kind;
  Bytes.set_int64_le payload 8 generation;
  let envelope = Bytes.make 48 '\000' in
  Bytes.blit_string "LJP2" 0 envelope 0 4;
  Bytes.set_uint16_le envelope 4 2;
  Bytes.set_uint16_le envelope 6 15;
  Bytes.set_int32_le envelope 24 16l;
  Bytes.blit payload 0 envelope 32 16;
  envelope
;;

let application_event_batch ~runtime_epoch ~revision ~sequence payload =
  Protocol.Inbound_event.
    { runtime_epoch
    ; events =
        [ { sequence = ID.Runtime.Event_sequence.of_int64 sequence
          ; displayed_revision = revision
          ; node_id = ID.Ui.Node_id.zero
          ; handler_id = ID.Ui.Handler_id.zero
          ; event_tag = Protocol.Generated_protocol.Event_tag.application_event
          ; payload = Application_event payload
          }
        ]
    }
;;

let with_warm_start_app ?calendar_sampler runtime_epoch run =
  let handle =
    Test.Handle.create_app
      ~runtime_epoch
      ~time_source:(Bonsai.Time_source.create ~start:Core.Time_ns.epoch)
      (Application.For_testing.app_with_service
         ?calendar_sampler
         (warm_start_test_service ()))
      ~application_payload:(warm_start_application_payload ())
  in
  Fun.protect ~finally:(fun () -> Test.Handle.shutdown handle) (fun () -> run handle)
;;

let test_warm_start_samples_calendar_before_requesting_local_binding () =
  let runtime_epoch = ID.Runtime.Epoch.of_int64 7_005L in
  let calendar_sampler =
    Journal_calendar.Sampler.create
      ~clock:(fun () -> 1_788_508_800.)
      ~localtime:(fun seconds -> Unix.gmtime (seconds +. 28_800.))
      ()
  in
  with_warm_start_app ~calendar_sampler runtime_epoch (fun handle ->
    let initial_requests = application_requests handle in
    require
      (Option.is_some
         (request_id_for_payload
            initial_requests
            Journal_platform.local_account_binding_request))
      "OCaml calendar sampling did not release managed warm startup synchronously";
    require
      (List.for_all
         (fun (_, payload) -> Bytes.get_uint16_le payload 6 <> 1)
         initial_requests)
      "warm startup emitted the deleted calendar platform request")
;;

let test_calendar_failure_does_not_start_graph_restoration () =
  let runtime_epoch = ID.Runtime.Epoch.of_int64 7_006L in
  let calendar_sampler =
    Journal_calendar.Sampler.create
      ~clock:(fun () -> raise (Failure "calendar unavailable"))
      ~localtime:Unix.localtime
      ()
  in
  with_warm_start_app ~calendar_sampler runtime_epoch (fun handle ->
    let initial_requests = application_requests handle in
    require
      (Option.is_none
         (request_id_for_payload
            initial_requests
            Journal_platform.local_account_binding_request))
      "failed calendar prerequisite still started graph restoration")
;;

let test_foreground_resume_resamples_calendar_in_ocaml () =
  let runtime_epoch = ID.Runtime.Epoch.of_int64 7_007L in
  let samples = ref 0 in
  let calendar_sampler =
    Journal_calendar.Sampler.create
      ~clock:(fun () ->
        incr samples;
        1_788_508_800. +. (Float.of_int !samples *. 60.))
      ~localtime:(fun seconds -> Unix.gmtime (seconds +. 28_800.))
      ()
  in
  with_warm_start_app ~calendar_sampler runtime_epoch (fun handle ->
    require (!samples = 1) "warm startup sampled the calendar more than once";
    Test.Handle.present handle;
    let events =
      network_lifecycle_packet ~kind:2 ~generation:1L
      |> application_event_batch
           ~runtime_epoch
           ~revision:(Test.Handle.revision handle)
           ~sequence:1L
    in
    Test.Handle.pump_next handle ~events ();
    require (!samples = 2) "foreground resume did not re-sample the OCaml calendar")
;;

let export_favorites_frames directory =
  let module P = Logseq_db_worker.Protocol in
  let uuid n =
    Graph.Uuid.of_string (Printf.sprintf "77000000-0000-4000-8000-%012d" n)
    |> Result.get_ok
  in
  let items =
    List.init 100 (fun n ->
      P.
        { membership_uuid = uuid n
        ; membership_order = string_of_int n
        ; membership_revision = "membership"
        ; target =
            (if n mod 2 = 0
             then
               V2_favorite_page
                 { uuid = uuid (100 + n)
                 ; title =
                     (if n = 0
                      then "Design notes"
                      else
                        "A favorite page with a longer title that wraps across several \
                         lines")
                 ; revision = "page"
                 }
             else
               V2_favorite_block
                 { uuid = uuid (100 + n)
                 ; title =
                     "Review navigation and keyboard layout in 中文 with a long task title"
                 ; task_status = Some V2_doing
                 ; revision = "block"
                 })
        })
  in
  let component _handlers _graph =
    Bonsai.Cont.return (Application.For_testing.favorites_page items)
  in
  let handle =
    Test.Handle.create
      ~runtime_epoch:(ID.Runtime.Epoch.of_int64 7010L)
      ~time_source:(Bonsai.Time_source.create ~start:Core.Time_ns.epoch)
      component
  in
  Fun.protect
    ~finally:(fun () -> Test.Handle.shutdown handle)
    (fun () ->
       Test.Handle.present handle;
       let channel = open_out_bin (Filename.concat directory "favorites.bin") in
       Fun.protect
         ~finally:(fun () -> close_out channel)
         (fun () ->
            output_bytes channel (Option.get (Test.Handle.last_frame handle)).bytes))
;;

let test_native_collection_delivers_range_and_scroll () =
  let observations = ref [] in
  let record value =
    Ui.Event.Handler.create (fun payload ->
      observations := (value, payload) :: !observations)
  in
  let row slot_index id section header block_id : Journal_native_collection.row =
    { id; section; header; slot_index = Some slot_index; block_id }
  in
  with_component
    (fun _handlers _graph ->
       Bonsai.Cont.return
         (Journal_native_collection.view
            ~key:(Ui.Key.string "collection")
            ~test_id:(Ui.Test_id.string "collection")
            ~rows:
              [ row 0 "empty" "empty" true None
              ; row 1 "today" "today" true None
              ; row 2 "target" "today" false (Some "target")
              ; row 3 "loading" "today" false None
              ]
            ~scroll_target:None
            ~on_scroll_completed:(record "scroll")
            ~actions_enabled:true
            ~on_visible_range:(record "range")
            ~on_open:(record "open")
            ~on_status:(record "status")
            ~on_delete:(record "delete")
            ~children:
              [ V.text "Empty date"; V.text "Today"; V.text "Target"; V.text "Loading" ]
          |> V.Body.Vertical.fill
          |> fun content -> V.Body.Vertical.create [ content ] |> V.Body.Private.to_widget
         ))
    (fun handle ->
       let visible first last =
         Test.Handle.visible_range
           handle
           (Test.Query.test_id "collection")
           ~first_index:first
           ~last_exclusive:last;
         Test.Handle.present handle
       in
       visible 0L 1L;
       require
         (!observations
          = [ ( "range"
              , Ui.Event.Payload.Visible_range { first_index = 0L; last_exclusive = 1L } )
            ])
         "empty-day row must map to its heading slot";
       observations := [];
       visible 1L 3L;
       require
         (!observations
          = [ ( "range"
              , Ui.Event.Payload.Visible_range { first_index = 2L; last_exclusive = 4L } )
            ])
         "row-only visibility must skip date headers and retain loading rows";
       observations := [];
       List.iter
         (fun key ->
            Test.Handle.click handle (Test.Query.key (Ui.Key.string key));
            Test.Handle.present handle)
         [ "open:target"; "status:target"; "delete:target" ];
       require
         (!observations
          = [ "delete", Ui.Event.Payload.Text "target"
            ; "status", Ui.Event.Payload.Text "target"
            ; "open", Ui.Event.Payload.Text "target"
            ])
         "public row actions lost their target identity")
;;

let test_native_rows_preserve_unbounded_literal_content () =
  List.iter
    (fun source ->
       let child_source = "Child summary\n第二行 👩🏽‍💻" in
       let child_summaries : Journal_graph_projection.child_summary list =
         [ { block_id = "child"; source = child_source } ]
       in
       with_component
         (timeline_component ~source ~child_summaries ~task_state:Todo ~enabled:true)
         (fun handle ->
            List.iter
              (fun value ->
                 let node = Test.Handle.find handle (Test.Query.visible_text value) in
                 require (Option.is_some node) "native row lost literal source or summary";
                 let (Av view) = V.Private.view (Option.get node).widget in
                 match view.node with
                 | V.Private.Text { line_limit; _ } ->
                   require (line_limit = None) "native content retained a legacy line cap"
                 | _ -> fail "native row did not render literal Text")
              [ source; child_source; "Todo"; "09:05" ]))
    [ "Literal **markdown** and [[page]]\nSecond line"
    ; String.make 65_536 'x'
    ; "中文 👩🏽‍💻\n\nFourth line\nFifth line"
    ]
;;

let test_diagnostics_use_public_form_and_preserve_actions () =
  let actions = ref [] in
  with_component
    (fun _handlers _graph ->
       let dispatch =
         Ui.Event.Handler.create (fun payload -> actions := payload :: !actions)
       in
       Bonsai.Cont.return
         (Application.For_testing.diagnostics_page dispatch |> V.Body.Private.to_widget))
    (fun handle ->
       require
         (List.length (Test.Handle.find_all handle (Test.Query.kind "form")) = 1)
         "diagnostics must use one public Form viewport";
       require
         (List.length (Test.Handle.find_all handle (Test.Query.kind "section")) = 2)
         "diagnostic groups must remain native sections";
       require
         (Option.is_some (Test.Handle.find handle (Test.Query.visible_text "Phases")))
         "phase section title disappeared";
       require
         (List.length (Test.Handle.find_all handle (Test.Query.kind "labeled_content"))
          = 7)
         "diagnostic values lost their native labeled presentation";
       Test.Handle.click handle (Test.Query.test_id "journal-diagnostics-close");
       Test.Handle.present handle;
       require
         (!actions = [ Ui.Event.Payload.Text "close-diagnostics" ])
         "diagnostics close lost its application command")
;;

(* Empty presentation is owned by the public collection adapter, not a reducer. *)
let test_empty_collection_preserves_list_owner () =
  with_component
    (fun _handlers _graph ->
       let ignored = Ui.Event.Handler.create (fun _ -> ()) in
       Bonsai.Cont.return
         (Journal_native_collection.view
            ~key:(Ui.Key.string "empty-collection")
            ~test_id:(Ui.Test_id.string "empty-collection")
            ~rows:[]
            ~children:[]
            ~scroll_target:None
            ~on_scroll_completed:ignored
            ~actions_enabled:true
            ~on_visible_range:ignored
            ~on_open:ignored
            ~on_status:ignored
            ~on_delete:ignored
          |> V.Body.Vertical.fill
          |> fun content -> V.Body.Vertical.create [ content ] |> V.Body.Private.to_widget
         ))
    (fun handle ->
       require
         (List.length (Test.Handle.find_all handle (Test.Query.kind "native_list")) = 1)
         "empty presentation replaced the list owner";
       require
         (List.length
            (Test.Handle.find_all handle (Test.Query.kind "content_unavailable"))
          = 1)
         "empty Journal needs a public unavailable presentation";
       require
         (Option.is_some
            (Test.Handle.find handle (Test.Query.visible_text "No journal entries yet")))
         "empty Journal message disappeared")
;;

(* Date headers are presentation-owned; pure timeline inputs construct the states. *)
let test_list_owned_dates_and_real_slot_visibility () =
  let module T = Journal_timeline_state in
  let loaded entries =
    T.empty ~today:20260809
    |> fun state ->
    T.begin_request state ~generation:1L (Feed { before_day = None })
    |> fun state ->
    T.apply_feed
      state
      ~generation:1L
      { Journal_graph_projection.days =
          [ { page = { id = page_id; day = 20260809; title = "Today" }
            ; entries
            ; has_more_entries = false
            ; continuation = None
            }
          ]
      ; slot_count = 1 + List.length entries
      ; has_more_days = false
      }
  in
  let entry = { Journal_graph_projection.block = block (); child_summaries = [] } in
  let populated = loaded [ entry ] in
  let empty = loaded [] in
  let hidden =
    loaded
      [ { entry with block = block ~source:"" ~child_count:0 ~task_state:No_status () } ]
  in
  let restored = T.replace_timeline_entry hidden entry in
  let replaced =
    T.replace_timeline_entry_page
      empty
      ~page:{ id = page_id; day = 20260809; title = "Today" }
      { entries = [ entry ]; continuation = None }
  in
  let captured = T.prepend_timeline_entry empty entry in
  let check ?(unmapped_first = false) state days expected_range =
    let observations = ref [] in
    with_component
      (fun _handlers _graph ->
         let ignored = Ui.Event.Handler.create (fun _ -> ()) in
         Bonsai.Cont.return
           (Journal_timeline.view
              ~render_media:(fun ~root:_ child -> child)
              ~state
              ~day_presentation:(fun day ->
                Journal_calendar.present_journal_day day |> Result.to_option)
              ~on_visible_range:
                (Ui.Event.Handler.create (fun value ->
                   observations := value :: !observations))
              ~on_scroll_completed:ignored
              ~on_retry_day:ignored
              ~on_open_block:ignored
              ~delete_enabled:true
              ~actions_enabled:true
              ~on_status:ignored
              ~on_delete:ignored
            |> V.Body.Private.to_widget))
      (fun handle ->
         require
           (List.length (Test.Handle.find_all handle (Test.Query.kind "native_list")) = 1)
           "dates must retain a single native list";
         List.iter
           (fun day ->
              let date = Journal_calendar.present_journal_day day |> Result.get_ok in
              let headers =
                Test.Handle.find_all
                  handle
                  (Test.Query.test_id ("journal-day-heading:" ^ string_of_int day))
              in
              require
                (List.length headers = 1)
                "day %d must have one native section header"
                day;
              let (Av view) = V.Private.view (List.hd headers).widget in
              match view.node with
              | V.Private.Native_widget { payload; _ } ->
                let fields = Yojson.Basic.from_string (Bytes.to_string payload) in
                require
                  (Yojson.Basic.Util.(fields |> member "title" |> to_string)
                   = date.date_text)
                  "section header lost its OCaml formatted title"
              | _ -> fail "date header must use native layout")
           days;
         require
           (List.length (Test.Handle.find_all handle (Test.Query.kind "list_section"))
            = List.length days)
           "hidden dates must not create extra sections";
         List.iter
           (fun node ->
              let (Av view) =
                V.Private.view node.Bonsai_swiftui_runtime.Mounted_tree.Snapshot.widget
              in
              match view.node with
              | V.Private.List_section { has_header; _ } ->
                require has_header "each day must own a native section header"
              | _ -> fail "expected native List section")
           (Test.Handle.find_all handle (Test.Query.kind "list_section"));
         if unmapped_first
         then (
           Test.Handle.visible_range
             handle
             (Test.Query.test_id "journal-timeline")
             ~first_index:0L
             ~last_exclusive:1L;
           Test.Handle.present handle;
           require (!observations = []) "empty Today alone must not request history");
         let row_count =
           List.length (Test.Handle.find_all handle (Test.Query.kind "list_row"))
         in
         require (row_count > 0) "empty Today must keep an explicit empty row";
         Test.Handle.visible_range
           handle
           (Test.Query.test_id "journal-timeline")
           ~first_index:0L
           ~last_exclusive:(Int64.of_int row_count);
         Test.Handle.present handle;
         require
           (!observations = expected_range)
           "presentation-only headers/empty rows must not invent pagination indices")
  in
  let row_range =
    [ Ui.Event.Payload.Visible_range { first_index = 0L; last_exclusive = 1L } ]
  in
  List.iter
    (fun state -> check state [ 20260809 ] [])
    [ T.empty ~today:20260809; empty; hidden ];
  List.iter
    (fun state -> check state [ 20260809 ] row_range)
    [ populated; restored; replaced; captured ];
  check
    ~unmapped_first:true
    (T.set_today populated ~today:20260810)
    [ 20260810; 20260809 ]
    row_range;
  check (T.set_today empty ~today:20260810) [ 20260810 ] [];
  let historical =
    T.empty ~today:20260810
    |> fun state ->
    T.begin_request state ~generation:1L (Feed { before_day = None })
    |> fun state ->
    T.apply_feed
      state
      ~generation:1L
      { days =
          [ { page = { id = page_id; day = 20260809; title = "Yesterday" }
            ; entries = [ entry ]
            ; has_more_entries = false
            ; continuation = None
            }
          ]
      ; slot_count = 2
      ; has_more_days = false
      }
  in
  check
    ~unmapped_first:true
    historical
    [ 20260810; 20260809 ]
    [ Ui.Event.Payload.Visible_range { first_index = 1L; last_exclusive = 2L } ]
;;

let test_timeline_media_targets () =
  let targets = ref [] in
  ignore
    (Journal_row.view
       ~show_timestamp:false
       ~render_media:(fun ~root child ->
         targets := root :: !targets;
         child)
       { Journal_graph_projection.block = block ()
       ; child_summaries = [ { block_id = "visible-child"; source = "Summary" } ]
       }
     : V.t);
  require
    (List.sort String.compare !targets
     = List.sort String.compare [ block_id; "visible-child" ])
    "media discovery must target each displayed source, including summaries"
;;

let tests =
  [ "timeline media targets", test_timeline_media_targets
  ; "list-owned dates", test_list_owned_dates_and_real_slot_visibility
  ; "empty Journal", test_empty_collection_preserves_list_owner
  ; "public diagnostics Form", test_diagnostics_use_public_form_and_preserve_actions
  ; "native collection event binding", test_native_collection_delivers_range_and_scroll
  ; ( "native literal content without geometry caps"
    , test_native_rows_preserve_unbounded_literal_content )
  ; ( "header semantics"
    , test_header_account_action_and_view_only_date_have_truthful_semantics )
  ; "header sync phases", test_header_sync_progress_tracks_every_sync_phase
  ; "native status and delete actions", test_swipe_exact_statuses_and_explicit_delete
  ; ( "calendar before local binding"
    , test_warm_start_samples_calendar_before_requesting_local_binding )
  ; ( "failed calendar prevents restoration"
    , test_calendar_failure_does_not_start_graph_restoration )
  ; "foreground calendar resampling", test_foreground_resume_resamples_calendar_in_ocaml
  ]
;;

let () =
  Option.iter export_favorites_frames (Sys.getenv_opt "JOURNAL_FAVORITES_FRAME_DIR");
  let failed =
    List.filter_map
      (fun (name, run) ->
         Printf.printf "running %s\n%!" name;
         try
           run ();
           None
         with
         | error ->
           Printf.eprintf "%s: %s\n%!" name (Printexc.to_string error);
           Some name)
      tests
  in
  if failed <> [] then fail "Failed: %s" (String.concat ", " failed)
;;
