module ID = Bonsai_flutter_spec.Id
module Ui = Bonsai_flutter_ui

let fail format = Printf.ksprintf failwith format

let require condition format =
  Printf.ksprintf (fun message -> if not condition then failwith message) format
;;

let require_string expected actual label =
  require (String.equal expected actual) "%s expected %S, got %S" label expected actual
;;

let creation_time minute =
  Journal_time.create
    ~instant_unix_ms:Int64.(add 1_786_204_800_000L (of_int (minute * 60_000)))
    ~local_day:20260809
    ~local_minute_of_day:minute
    ~time_zone_id:"Asia/Shanghai"
    ~utc_offset_seconds:28_800
  |> function
  | Ok value -> value
  | Error error -> fail "creation time failed: %s" error
;;

let block
      ?(id = "70000000-0000-4000-a000-000000000001")
      ?(parent_id = None)
      ?(source = "Original #literal @source")
      ?(task_state = Journal_model.Todo)
      ?(child_count = 1)
      ?(revision = 1)
      ()
  =
  Journal_model.create
    ~id
    ~page_id:"70000000-0000-4000-b000-000020260809"
    ~journal_day:20260809
    ~parent_id
    ~sibling_order:"000000000001"
    ~source
    ~task_state
    ~child_count
    ~creation_time:(creation_time 540)
    ~revision
    ~last_mutation_id:"70000000-0000-4000-9000-000000000001"
  |> function
  | Ok value -> value
  | Error error -> fail "block fixture failed: %s" error
;;

let detail ?(root = block ()) () : Journal_graph_projection.detail =
  { root; children = { blocks = []; continuation = None } }
;;

let edit
      ~session_id
      ~local_revision
      ~base_document_revision
      ~text
      ~selection_start
      ~selection_end
      ?composing
      ()
  : Ui.Event.Payload.text_edit
  =
  { session_id
  ; local_revision = ID.Text_input.Local_revision.of_int64 local_revision
  ; base_document_revision =
      ID.Text_input.Document_revision.of_int64 base_document_revision
  ; text
  ; selection = { start_utf16 = selection_start; end_utf16 = selection_end }
  ; composing =
      Option.map
        (fun (start_utf16, end_utf16) -> { Ui.Event.Payload.start_utf16; end_utf16 })
        composing
  }
;;

let require_range range ~start_utf16 ~end_utf16 label =
  require
    (Ui.Text_editing.Range.start_utf16 range = start_utf16
     && Ui.Text_editing.Range.end_utf16 range = end_utf16)
    "%s range expected %d..%d"
    label
    start_utf16
    end_utf16
;;

let test_capture_plain_ime_dirty_cancel_and_retry () =
  let capture = Journal_capture.create ~session_number:11L ~source:"" in
  require (not (Journal_capture.can_save capture)) "blank Capture enabled Save";
  require (not (Journal_capture.dirty capture)) "new Capture started dirty";
  require
    (Journal_capture.request_dismiss capture = Journal_capture.Close)
    "clean dismiss did not close";
  require (Journal_capture.can_pop capture) "clean Capture did not allow platform pop";
  let session_id = Journal_capture.session_id capture in
  let composed = "中文 👩🏽‍💻 e\204\129 #literal @mention" in
  let capture =
    Journal_capture.apply_text_edit
      capture
      (edit
         ~session_id
         ~local_revision:1L
         ~base_document_revision:0L
         ~text:composed
         ~selection_start:3
         ~selection_end:10
         ~composing:(0, 2)
         ())
  in
  require_string composed (Journal_capture.source capture) "composed Capture source";
  require (Journal_capture.dirty capture) "IME edit did not dirty Capture";
  require (Journal_capture.can_save capture) "nonblank Capture did not enable Save";
  let value = Journal_capture.value capture in
  require_range
    (Ui.Text_editing.Value.selection value)
    ~start_utf16:3
    ~end_utf16:10
    "Capture selection";
  (match Ui.Text_editing.Value.composing value with
   | Some range -> require_range range ~start_utf16:0 ~end_utf16:2 "Capture composing"
   | None -> fail "Capture lost composing range");
  let pasted = composed ^ "\n貼り付け" in
  let capture =
    Journal_capture.apply_text_edit
      capture
      (edit
         ~session_id
         ~local_revision:2L
         ~base_document_revision:1L
         ~text:pasted
         ~selection_start:(Ui.Text_editing.Utf16.length pasted)
         ~selection_end:(Ui.Text_editing.Utf16.length pasted)
         ())
  in
  require_string pasted (Journal_capture.source capture) "pasted Capture source";
  let capture =
    Journal_capture.apply_text_edit
      capture
      (edit
         ~session_id
         ~local_revision:3L
         ~base_document_revision:2L
         ~text:composed
         ~selection_start:10
         ~selection_end:10
         ())
  in
  require_string composed (Journal_capture.source capture) "undo Capture source";
  let stale_session = ID.Text_input.Session_id.of_int64 12L in
  let ignored =
    Journal_capture.apply_text_edit
      capture
      (edit
         ~session_id:stale_session
         ~local_revision:4L
         ~base_document_revision:3L
         ~text:"stale runtime edit"
         ~selection_start:0
         ~selection_end:0
         ())
  in
  require_string composed (Journal_capture.source ignored) "stale-session Capture source";
  let confirming =
    match Journal_capture.request_dismiss capture with
    | Journal_capture.Confirm value -> value
    | Close -> fail "dirty dismiss closed without confirmation"
    | Block -> fail "dirty editable Capture blocked explicit dismissal"
  in
  require
    (Journal_capture.phase confirming = Journal_capture.Confirm_discard)
    "dirty dismiss did not enter confirmation";
  require (not (Journal_capture.can_pop confirming)) "confirmation allowed platform pop";
  let capture = Journal_capture.keep_editing confirming in
  require_string composed (Journal_capture.source capture) "kept Capture draft";
  let saving, request =
    Journal_capture.admit_save
      capture
      ~mutation_id:"70000000-0000-4000-9000-000000000011"
      ~block_id:"70000000-0000-4000-a000-000000000011"
      ~sibling_order:"000000000011"
      ~child_identities:[]
      ~calendar_generation:7L
      ~creation_time:(creation_time 541)
  in
  (match request with
   | Some
       (Journal_graph_request.Capture
          { calendar_generation = 7L
          ; command = { source; task_state = Journal_model.No_status; _ }
          }) -> require_string composed source "admitted Capture source"
   | _ -> fail "Capture did not admit the expected Worker request");
  let still_saving, repeated =
    Journal_capture.admit_save
      saving
      ~mutation_id:"70000000-0000-4000-9000-000000000012"
      ~block_id:"70000000-0000-4000-a000-000000000012"
      ~sibling_order:"000000000012"
      ~child_identities:[]
      ~calendar_generation:7L
      ~creation_time:(creation_time 542)
  in
  require (Option.is_none repeated) "rapid repeated Save admitted a second mutation";
  require
    (Journal_capture.phase still_saving = Journal_capture.Saving)
    "rapid repeated Save changed phase";
  require
    (Journal_capture.request_dismiss still_saving = Journal_capture.Block)
    "Saving Capture did not block dismissal";
  require (not (Journal_capture.can_pop still_saving)) "Saving Capture allowed pop";
  let failed = Journal_capture.fail saving ~message:"storage unavailable" in
  let retrying, retry = Journal_capture.retry failed in
  require (retry = request) "Capture retry did not reuse the admitted mutation identity";
  require
    (Journal_capture.phase retrying = Journal_capture.Saving)
    "Capture retry did not return to Saving"
;;

let test_capture_dismissal_policy_covers_task_failure () =
  let clean = Journal_capture.create ~session_number:31L ~source:"" in
  let task_dirty = Journal_capture.toggle_task clean in
  require
    (Journal_capture.task_state task_dirty = Journal_model.Todo)
    "task fixture did not become Todo";
  let task_confirming =
    match Journal_capture.request_dismiss task_dirty with
    | Journal_capture.Confirm capture -> capture
    | Close -> fail "task-only dirty Capture closed without confirmation"
    | Block -> fail "task-only dirty Capture blocked explicit dismissal"
  in
  require
    (Journal_capture.phase task_confirming = Journal_capture.Confirm_discard)
    "task-only dirty Capture did not enter confirmation";
  let kept = Journal_capture.keep_editing task_confirming in
  require
    (Journal_capture.task_state kept = Journal_model.Todo)
    "Keep Editing lost the task-only draft";
  let source = "保留 recovery draft 👩🏽‍💻" in
  let edited =
    Journal_capture.apply_text_edit
      clean
      (edit
         ~session_id:(Journal_capture.session_id clean)
         ~local_revision:1L
         ~base_document_revision:0L
         ~text:source
         ~selection_start:2
         ~selection_end:8
         ~composing:(0, 2)
         ())
    |> Journal_capture.toggle_task
  in
  let saving, _ =
    Journal_capture.admit_save
      edited
      ~mutation_id:"70000000-0000-4000-9000-000000000031"
      ~block_id:"70000000-0000-4000-a000-000000000031"
      ~sibling_order:"000000000031"
      ~child_identities:[]
      ~calendar_generation:7L
      ~creation_time:(creation_time 544)
  in
  let failed = Journal_capture.fail saving ~message:"storage unavailable" in
  let require_confirmable label capture =
    require (not (Journal_capture.can_pop capture)) "%s allowed platform pop" label;
    match Journal_capture.request_dismiss capture with
    | Journal_capture.Confirm confirming ->
      require
        (Journal_capture.phase confirming = Journal_capture.Confirm_discard)
        "%s did not enter confirmation"
        label;
      require_string source (Journal_capture.source confirming) (label ^ " source");
      require
        (Journal_capture.task_state confirming = Journal_model.Todo)
        "%s lost task state"
        label;
      let value = Journal_capture.value confirming in
      require_range
        (Ui.Text_editing.Value.selection value)
        ~start_utf16:2
        ~end_utf16:8
        (label ^ " selection");
      (match Ui.Text_editing.Value.composing value with
       | Some range ->
         require_range range ~start_utf16:0 ~end_utf16:2 (label ^ " composing")
       | None -> fail "%s lost composing state" label)
    | Close -> fail "%s closed without confirmation" label
    | Block -> fail "%s blocked explicit confirmed discard" label
  in
  require_confirmable "failed Capture" failed;
  let committed = Journal_capture.commit saving (block ()) in
  require
    (Journal_capture.request_dismiss committed = Journal_capture.Block)
    "Committed Capture exposed a dismissal path"
;;

let test_capture_route_admission_and_confirmed_dismissal () =
  let anchor : Journal_routes.anchor = { block_id = None; first_index = 0 } in
  let routes = Journal_routes.create ~anchor in
  let clean_opened = Journal_routes.open_capture routes ~session_number:40L ~source:"" in
  let clean_closed = Journal_routes.back clean_opened in
  require
    (Journal_routes.route clean_closed = Journal_routes.Timeline)
    "clean Capture did not close";
  let opened =
    Journal_routes.open_capture
      routes
      ~session_number:41L
      ~source:"Composer-seeded route draft"
  in
  let opened_again =
    Journal_routes.open_capture opened ~session_number:42L ~source:"replacement"
  in
  let capture =
    match Journal_routes.capture opened_again with
    | Some capture -> capture
    | None -> fail "Capture route disappeared after duplicate admission"
  in
  require
    (ID.Text_input.Session_id.equal
       (Journal_capture.session_id capture)
       (ID.Text_input.Session_id.of_int64 41L))
    "duplicate MessageComposer activation replaced the Capture session";
  require_string
    "Composer-seeded route draft"
    (Journal_capture.source capture)
    "Capture route seed";
  let capture =
    Journal_capture.apply_text_edit
      capture
      (edit
         ~session_id:(Journal_capture.session_id capture)
         ~local_revision:1L
         ~base_document_revision:0L
         ~text:"Dirty route draft"
         ~selection_start:17
         ~selection_end:17
         ())
  in
  let dirty_routes = Journal_routes.update_capture opened_again capture in
  let confirming_routes = Journal_routes.back dirty_routes in
  let confirming =
    match Journal_routes.capture confirming_routes with
    | Some capture -> capture
    | None -> fail "dirty explicit Close removed Capture"
  in
  require
    (Journal_capture.phase confirming = Journal_capture.Confirm_discard)
    "dirty explicit Close did not enter confirmation";
  let kept_routes = Journal_routes.keep_editing confirming_routes in
  let kept = Option.get (Journal_routes.capture kept_routes) in
  require_string "Dirty route draft" (Journal_capture.source kept) "kept route draft";
  let discarded = Journal_routes.discard confirming_routes in
  require
    (Journal_routes.route discarded = Journal_routes.Timeline)
    "confirmed Discard did not remove the sheet"
;;

let test_detail_task_child_conflict_and_back_order () =
  let original = block () in
  let detail_state =
    Journal_detail.create ~session_number:21L (detail ~root:original ())
  in
  let task_state, task_request =
    Journal_detail.admit_task_toggle
      detail_state
      ~mutation_id:"70000000-0000-4000-9000-000000000021"
  in
  (match task_request with
   | Some
       (Journal_graph_request.Set_task_state
          { block_id; expected_revision = 1; task_state = Journal_model.Done; _ }) ->
     require_string (Journal_model.id original) block_id "task block ID"
   | _ -> fail "Detail task toggle did not admit an atomic mutation");
  let _, repeated_task =
    Journal_detail.admit_task_toggle
      task_state
      ~mutation_id:"70000000-0000-4000-9000-000000000022"
  in
  require (Option.is_none repeated_task) "rapid repeated task action was admitted";
  let detail_state =
    Journal_detail.create ~session_number:22L (detail ~root:original ())
  in
  let child_state = Journal_detail.begin_child detail_state ~session_number:23L in
  let child_capture =
    match Journal_detail.child_capture child_state with
    | Some value -> value
    | None -> fail "Detail did not open direct-child Capture"
  in
  let child_state =
    Journal_detail.apply_child_text_edit
      child_state
      (edit
         ~session_id:(Journal_capture.session_id child_capture)
         ~local_revision:1L
         ~base_document_revision:0L
         ~text:"Direct child 👶"
         ~selection_start:15
         ~selection_end:15
         ())
  in
  let _, child_request =
    Journal_detail.admit_child
      child_state
      ~mutation_id:"70000000-0000-4000-9000-000000000023"
      ~block_id:"70000000-0000-4000-a000-000000000023"
      ~sibling_order:"000000000023"
      ~creation_time:(creation_time 543)
  in
  (match child_request with
   | Some
       (Journal_graph_request.Create_child
          { parent_block_id; expected_parent_revision = 1; source; _ }) ->
     require_string (Journal_model.id original) parent_block_id "child parent";
     require_string "Direct child 👶" source "child source"
   | _ -> fail "Detail did not admit a direct-child mutation");
  let detail_state =
    Journal_detail.create ~session_number:24L (detail ~root:original ())
  in
  let editing = Journal_detail.begin_edit detail_state in
  let editor =
    match Journal_detail.editor_value editing with
    | Some value -> value
    | None -> fail "Detail did not create a plain editor"
  in
  require_string
    (Journal_model.source original)
    (Ui.Text_editing.Value.text editor)
    "full Detail source";
  let editing =
    Journal_detail.apply_text_edit
      editing
      (edit
         ~session_id:(Journal_detail.session_id editing)
         ~local_revision:1L
         ~base_document_revision:0L
         ~text:"我的草稿 👩🏽‍💻 e\204\129"
         ~selection_start:2
         ~selection_end:9
         ~composing:(0, 2)
         ())
  in
  let saving, request =
    Journal_detail.admit_save editing ~mutation_id:"70000000-0000-4000-9000-000000000024"
  in
  require (Option.is_some request) "Detail edit was not admitted";
  let latest = block ~source:"Concurrent source" ~revision:2 () in
  let conflicted = Journal_detail.apply_conflict saving latest in
  require
    (Journal_detail.mode conflicted = Journal_detail.Conflict)
    "typed Worker conflict did not enter Conflict";
  (match Journal_detail.editor_value conflicted with
   | None -> fail "conflict discarded the local draft"
   | Some value ->
     require_string "我的草稿 👩🏽‍💻 e\204\129" (Ui.Text_editing.Value.text value) "conflict draft";
     (match Ui.Text_editing.Value.composing value with
      | Some range -> require_range range ~start_utf16:0 ~end_utf16:2 "conflict composing"
      | None -> fail "conflict discarded the composing range"));
  let retrying, retry =
    Journal_detail.retry conflicted ~mutation_id:"70000000-0000-4000-9000-000000000025"
  in
  (match retry with
   | Some
       (Journal_graph_request.Update_source
          { expected_revision = 2; source = "我的草稿 👩🏽‍💻 e\204\129"; _ }) -> ()
   | _ -> fail "conflict retry did not rebase the literal draft on the latest revision");
  require
    (Journal_detail.mode retrying = Journal_detail.Saving)
    "Detail retry did not return to Saving";
  let editing = Journal_detail.begin_edit detail_state in
  let editing =
    Journal_detail.apply_text_edit
      editing
      (edit
         ~session_id:(Journal_detail.session_id editing)
         ~local_revision:1L
         ~base_document_revision:0L
         ~text:"Dirty"
         ~selection_start:5
         ~selection_end:5
         ())
  in
  let confirming =
    match Journal_detail.request_back editing with
    | `State value -> value
    | `Close -> fail "Back skipped dirty-edit confirmation"
  in
  require
    (Journal_detail.mode confirming = Journal_detail.Confirm_discard)
    "first Back did not confirm discard";
  let reading = Journal_detail.discard_edit confirming in
  require
    (Journal_detail.mode reading = Journal_detail.Reading)
    "discard did not return to Detail reading";
  require
    (Journal_detail.request_back reading = `Close)
    "second Back did not close Detail"
;;

let test_route_generation_anchor_background_and_runtime_replacement () =
  let anchor : Journal_routes.anchor =
    { block_id = Some "70000000-0000-4000-a000-000000000001"; first_index = 37 }
  in
  let routes = Journal_routes.create ~anchor in
  require
    (Journal_routes.anchor_to_restore routes = Some anchor)
    "initial Timeline anchor changed";
  let loading =
    Journal_routes.open_detail
      routes
      ~block_id:"70000000-0000-4000-a000-000000000001"
      ~request_generation:40L
  in
  let stale =
    Journal_routes.apply_detail_response loading ~request_generation:39L (detail ())
  in
  require
    (Journal_routes.route stale = Journal_routes.Detail_loading)
    "stale Worker response replaced the active Detail request";
  let loaded =
    Journal_routes.apply_detail_response stale ~request_generation:40L (detail ())
  in
  require
    (Journal_routes.route loaded = Journal_routes.Detail)
    "Detail response did not route";
  let backgrounded = Journal_routes.background loaded in
  require
    (Journal_routes.route backgrounded = Journal_routes.Detail)
    "backgrounding discarded the Detail route";
  let replaced = Journal_routes.runtime_replaced backgrounded in
  require
    (Journal_routes.route replaced = Journal_routes.Detail_loading)
    "runtime replacement did not reload the active Detail";
  let missing =
    Journal_routes.apply_missing_detail
      replaced
      ~request_generation:(Journal_routes.detail_request_generation replaced)
  in
  require
    (Journal_routes.route missing = Journal_routes.Missing_detail)
    "missing block did not produce a truthful unavailable route";
  let routes = Journal_routes.back missing in
  require
    (Journal_routes.route routes = Journal_routes.Timeline)
    "Back did not return Timeline";
  require
    (Journal_routes.anchor_to_restore routes = Some anchor)
    "Detail Back did not restore its Timeline anchor"
;;

let tests =
  [ ( "Capture plain IME, dirty cancel, and retry"
    , test_capture_plain_ime_dirty_cancel_and_retry )
  ; ( "Capture dismissal covers task and failure"
    , test_capture_dismissal_policy_covers_task_failure )
  ; ( "Capture route admission and confirmed dismissal"
    , test_capture_route_admission_and_confirmed_dismissal )
  ; ( "Detail task, child, conflict, and Back order"
    , test_detail_task_child_conflict_and_back_order )
  ; ( "route generation, anchor, background, and runtime replacement"
    , test_route_generation_anchor_background_and_runtime_replacement )
  ]
;;

let () =
  List.iter
    (fun (name, test) ->
       Printf.printf "running %s\n%!" name;
       test ())
    tests
;;
