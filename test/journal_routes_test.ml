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
      ?(revision = "block-1")
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

let generated_block_id minute =
  Logseq_db_types.Squuid.next
    Logseq_db_types.Squuid.empty
    ~timestamp_ms:(Journal_time.instant_unix_ms (creation_time minute))
    ~random_bytes:(Bytes.make 16 '\000')
  |> Result.get_ok
  |> snd
  |> Logseq_db_types.Graph_types.Uuid.to_string
;;

let test_direct_capture_preserves_source_and_mutation_identity () =
  let source = "  中文 👩🏽‍💻 e\204\129 #literal @mention  " in
  let capture = Journal_capture.create ~session_number:11L ~source in
  require (Journal_capture.can_save capture) "nonblank direct Capture disabled Save";
  let saving, request =
    Journal_capture.admit_save
      capture
      ~mutation_id:"70000000-0000-4000-9000-000000000011"
      ~block_id:(generated_block_id 541)
      ~sibling_order:"000000000011"
      ~calendar_generation:7L
      ~creation_time:(creation_time 541)
  in
  (match request with
   | Some
       (Journal_graph_request.Capture
          { calendar_generation = 7L
          ; command =
              { mutation_id = "70000000-0000-4000-9000-000000000011"
              ; block_id
              ; sibling_order = "000000000011"
              ; source = actual_source
              ; task_state = Journal_model.No_status
              ; children = []
              ; _
              }
          }) ->
     require_string (generated_block_id 541) block_id "generated direct Capture ID";
     require_string source actual_source "admitted direct Capture source"
   | _ -> fail "direct Capture did not admit one plain top-level Worker request");
  let still_saving, repeated =
    Journal_capture.admit_save
      saving
      ~mutation_id:"70000000-0000-4000-9000-000000000012"
      ~block_id:"70000000-0000-4000-a000-000000000012"
      ~sibling_order:"000000000012"
      ~calendar_generation:7L
      ~creation_time:(creation_time 542)
  in
  require (Option.is_none repeated) "rapid repeated Save admitted a second mutation";
  require
    (Journal_capture.phase still_saving = Journal_capture.Saving)
    "rapid repeated Save changed phase";
  let failed = Journal_capture.fail saving ~message:"storage unavailable" in
  require_string source (Journal_capture.source failed) "failed direct Capture draft";
  let retrying, retry = Journal_capture.retry failed in
  require
    (retry = request)
    "unchanged direct Capture retry did not reuse its admitted mutation identity";
  require
    (Journal_capture.phase retrying = Journal_capture.Saving)
    "direct Capture retry did not return to Saving"
;;

let test_direct_capture_task_intent_survives_edit_failure_and_retry () =
  let source = "  Todo 中文 👩🏽‍💻 exact  " in
  let capture = Journal_capture.create ~session_number:12L ~source in
  let task_capture = Journal_capture.toggle_task_intent capture in
  require
    (Journal_capture.task_state task_capture = Journal_model.Todo)
    "Capture task intent did not toggle to Todo";
  require_string
    source
    (Journal_capture.source task_capture)
    "Capture task toggle changed the exact draft";
  let edited_source = source ^ "!" in
  let edited =
    Journal_capture.apply_text_edit
      task_capture
      (edit
         ~session_id:(Journal_capture.session_id task_capture)
         ~local_revision:1L
         ~base_document_revision:0L
         ~text:edited_source
         ~selection_start:(Ui.Text_editing.Utf16.length edited_source)
         ~selection_end:(Ui.Text_editing.Utf16.length edited_source)
         ())
  in
  require
    (Journal_capture.task_state edited = Journal_model.Todo)
    "text edit cleared Capture task intent";
  let saving, request =
    Journal_capture.admit_save
      edited
      ~mutation_id:"70000000-0000-4000-9000-000000000012"
      ~block_id:"70000000-0000-4000-a000-000000000012"
      ~sibling_order:"000000000012"
      ~calendar_generation:7L
      ~creation_time:(creation_time 542)
  in
  (match request with
   | Some
       (Journal_graph_request.Capture
          { command = { source; task_state = Journal_model.Todo; _ }; _ }) ->
     require_string edited_source source "Todo Capture admitted source"
   | _ -> fail "checked Capture did not admit one Todo request");
  let gated = Journal_capture.toggle_task_intent saving in
  require
    (Journal_capture.task_state gated = Journal_model.Todo)
    "Saving Capture accepted a contradictory task toggle";
  let failed = Journal_capture.fail saving ~message:"storage unavailable" in
  require
    (Journal_capture.task_state failed = Journal_model.Todo)
    "failed Capture lost task intent";
  let retrying, retry = Journal_capture.retry failed in
  require (retry = request) "Todo retry did not reuse the admitted request";
  require
    (Journal_capture.task_state retrying = Journal_model.Todo)
    "Todo retry lost task intent";
  let replacement = Journal_capture.toggle_task_intent failed in
  require
    (Journal_capture.task_state replacement = Journal_model.No_status
     && Journal_capture.phase replacement = Journal_capture.Editing)
    "task change after terminal failure did not replace the failed attempt";
  let _, replacement_request =
    Journal_capture.admit_save
      replacement
      ~mutation_id:"70000000-0000-4000-9000-000000000013"
      ~block_id:"70000000-0000-4000-a000-000000000013"
      ~sibling_order:"000000000013"
      ~calendar_generation:7L
      ~creation_time:(creation_time 543)
  in
  match replacement_request with
  | Some
      (Journal_graph_request.Capture
         { command = { task_state = Journal_model.No_status; _ }; _ }) -> ()
  | _ -> fail "replacement Capture reused stale Todo intent"
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
          { block_id; expected_revision = "block-1"; task_state = Journal_model.Done; _ })
     -> require_string (Journal_model.id original) block_id "task block ID"
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
  let saving_child, child_request =
    Journal_detail.admit_child
      child_state
      ~mutation_id:"70000000-0000-4000-9000-000000000023"
      ~calendar_generation:7L
      ~block_id:(generated_block_id 543)
      ~sibling_order:"000000000023"
      ~creation_time:(creation_time 543)
  in
  (match child_request with
   | Some
       (Journal_graph_request.Create_child
          { parent_block_id; expected_parent_revision = "block-1"; source; _ }) ->
     require_string (Journal_model.id original) parent_block_id "child parent";
     require_string "Direct child 👶" source "child source"
   | _ -> fail "Detail did not admit a direct-child mutation");
  let failed_child = Journal_detail.fail saving_child ~message:"storage unavailable" in
  require_string
    "Direct child 👶"
    (Journal_capture.source (Journal_detail.child_capture failed_child |> Option.get))
    "failed child draft";
  let retrying_child, retry =
    Journal_detail.retry failed_child ~mutation_id:"70000000-0000-4000-9000-000000000099"
  in
  require
    (retry = child_request)
    "child retry changed its admitted command or generated ID";
  require
    (Journal_detail.mode retrying_child = Journal_detail.Saving_child)
    "child retry did not return to Saving_child";
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
  let latest = block ~source:"Concurrent source" ~revision:"block-2" () in
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
          { expected_revision = "block-2"; source = "我的草稿 👩🏽‍💻 e\204\129"; _ }) -> ()
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
  [ ( "direct Capture source and mutation identity"
    , test_direct_capture_preserves_source_and_mutation_identity )
  ; ( "direct Capture task intent lifecycle"
    , test_direct_capture_task_intent_survives_edit_failure_and_retry )
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
