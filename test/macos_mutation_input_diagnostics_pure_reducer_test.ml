module ID = Bonsai_flutter_spec.Id
module Ui = Bonsai_flutter_ui

let require condition message = if not condition then failwith message
let equal expected actual label = require (expected = actual) label

let creation_time =
  Journal_time.create
    ~instant_unix_ms:1_788_192_000_000L
    ~local_day:20260901
    ~local_minute_of_day:0
  |> Result.get_ok
;;

let block
      ?(id = "70000000-0000-4000-a000-000000000001")
      ?(source = "Original")
      ?(revision = "block-1")
      ()
  =
  Journal_model.create
    ~id
    ~page_id:"70000000-0000-4000-b000-000000000001"
    ~journal_day:20260901
    ~parent_id:None
    ~sibling_order:"a"
    ~source
    ~task_state:Journal_model.Todo
    ~child_count:0
    ~creation_time
    ~revision
    ~last_mutation_id:"70000000-0000-4000-9000-000000000001"
  |> Result.get_ok
;;

let detail () =
  Journal_detail.create
    ~session_number:11L
    { root = block (); children = { blocks = []; continuation = None } }
;;

let edit session_id local_revision base_document_revision text =
  let length = Ui.Text_editing.Utf16.length text in
  Ui.Event.Payload.
    { session_id
    ; local_revision = ID.Text_input.Local_revision.of_int64 local_revision
    ; base_document_revision =
        ID.Text_input.Document_revision.of_int64 base_document_revision
    ; text
    ; selection = { start_utf16 = length; end_utf16 = length }
    ; composing = None
    }
;;

let pasted = "Prefix\n\228\184\173\230\150\135 \240\159\152\128"
let final_source = pasted ^ "!"

let paste session =
  { (edit session 2L 0L pasted) with
    selection = { start_utf16 = 7; end_utf16 = 9 }
  ; composing = Some { start_utf16 = 7; end_utf16 = 9 }
  }
;;

let check_paste value =
  equal pasted (Ui.Text_editing.Value.text value) "complete Unicode paste retained";
  let selection = Ui.Text_editing.Value.selection value in
  equal 7 (Ui.Text_editing.Range.start_utf16 selection) "UTF-16 selection start";
  equal 9 (Ui.Text_editing.Range.end_utf16 selection) "UTF-16 selection end";
  match Ui.Text_editing.Value.composing value with
  | None -> failwith "composition was discarded"
  | Some composing ->
    equal 7 (Ui.Text_editing.Range.start_utf16 composing) "UTF-16 composition start";
    equal 9 (Ui.Text_editing.Range.end_utf16 composing) "UTF-16 composition end"
;;

let save_capture capture =
  Journal_capture.admit_save
    capture
    ~mutation_id:"70000000-0000-4000-9000-000000000002"
    ~block_id:"70000000-0000-4000-a000-000000000002"
    ~sibling_order:"b"
    ~calendar_generation:1L
    ~creation_time
;;

let test_capture_pipeline () =
  let initial = Journal_capture.create ~session_number:10L ~source:"" in
  let session = Journal_capture.session_id initial in
  let prefix = Journal_capture.apply_text_edit initial (edit session 1L 0L "Prefix") in
  let capture = Journal_capture.apply_text_edit prefix (paste session) in
  check_paste (Journal_capture.value capture);
  equal session (Journal_capture.session_id capture) "ordinary ack retains session";
  equal Ui.Text_editing.Ack (Journal_capture.update_mode capture) "paste acknowledged";
  equal
    (ID.Text_input.Document_revision.of_int64 2L)
    (Journal_capture.document_revision capture)
    "each accepted edit advances document revision";
  equal
    (ID.Text_input.Local_revision.of_int64 2L)
    (Journal_capture.accepted_local_revision capture)
    "paste local revision acknowledged";
  let capture =
    Journal_capture.apply_text_edit capture (edit session 3L 0L final_source)
  in
  let saving, request = save_capture capture in
  (match request with
   | Some (Journal_graph_request.Capture { command; _ }) ->
     equal final_source command.source "save uses last complete editing value"
   | _ -> failwith "capture did not emit save");
  let ignored = Journal_capture.apply_text_edit saving (edit session 4L 0L "late") in
  equal final_source (Journal_capture.source ignored) "saving rejects text edits"
;;

let detail_source detail =
  Journal_detail.editor_value detail |> Option.get |> Ui.Text_editing.Value.text
;;

let test_detail_pipeline () =
  let initial = detail () |> Journal_detail.begin_edit in
  let session = Journal_detail.session_id initial in
  let prefix = Journal_detail.apply_text_edit initial (edit session 1L 0L "Prefix") in
  let detail = Journal_detail.apply_text_edit prefix (paste session) in
  check_paste (Journal_detail.editor_value detail |> Option.get);
  equal session (Journal_detail.session_id detail) "detail ack retains session";
  equal Ui.Text_editing.Ack (Journal_detail.update_mode detail) "detail paste ack";
  equal
    (ID.Text_input.Document_revision.of_int64 2L)
    (Journal_detail.document_revision detail)
    "detail ack document revision";
  equal
    (ID.Text_input.Local_revision.of_int64 2L)
    (Journal_detail.accepted_local_revision detail)
    "detail ack local revision";
  let detail = Journal_detail.apply_text_edit detail (edit session 3L 0L final_source) in
  let saving, request = Journal_detail.admit_save detail ~mutation_id:"save-detail" in
  (match request with
   | Some (Journal_graph_request.Update_source command) ->
     equal final_source command.source "detail save uses last complete value";
     equal "block-1" command.expected_revision "source save retains target precondition"
   | _ -> failwith "detail did not emit save");
  equal
    final_source
    (detail_source (Journal_detail.apply_text_edit saving (edit session 4L 0L "late")))
    "saving detail rejects edits"
;;

let test_invalid_edits () =
  let capture = Journal_capture.create ~session_number:10L ~source:"" in
  let session = Journal_capture.session_id capture in
  let capture = Journal_capture.apply_text_edit capture (edit session 2L 0L "kept") in
  let invalid =
    [ edit session 2L 0L "duplicate"
    ; edit session 1L 0L "out of order"
    ; edit session 3L 2L "future base"
    ; edit (ID.Text_input.Session_id.of_int64 99L) 3L 0L "wrong session"
    ]
  in
  List.iter
    (fun edit ->
       equal capture (Journal_capture.apply_text_edit capture edit) "invalid capture edit")
    invalid;
  let initial = detail () in
  let session = Journal_detail.session_id initial in
  equal
    initial
    (Journal_detail.apply_text_edit initial (edit session 1L 0L "reading"))
    "reading guard";
  let detail = Journal_detail.begin_edit initial in
  let detail = Journal_detail.apply_text_edit detail (edit session 2L 0L "kept") in
  List.iter
    (fun invalid ->
       let invalid = { invalid with Ui.Event.Payload.session_id = session } in
       equal detail (Journal_detail.apply_text_edit detail invalid) "invalid detail edit")
    (List.filteri (fun i _ -> i < 3) invalid);
  let _, conflict_request = Journal_detail.admit_save detail ~mutation_id:"conflict" in
  require (Option.is_some conflict_request) "conflict fixture save";
  let saving, _ = Journal_detail.admit_save detail ~mutation_id:"conflict" in
  let conflict =
    Journal_detail.apply_conflict saving (block ~source:"Remote" ~revision:"block-2" ())
  in
  equal
    conflict
    (Journal_detail.apply_text_edit conflict (edit session 3L 0L "late"))
    "conflict guard";
  let _, retry = Journal_detail.retry conflict ~mutation_id:"retry" in
  match retry with
  | Some (Journal_graph_request.Update_source command) ->
    equal "kept" command.source "conflict retry preserves local source";
    equal "block-2" command.expected_revision "conflict retry uses observed remote token"
  | _ -> failwith "conflict retry missing"
;;

let test_capture_replacement_fence () =
  let capture = Journal_capture.create ~session_number:10L ~source:"" in
  let session = Journal_capture.session_id capture in
  let capture = Journal_capture.apply_text_edit capture (edit session 1L 0L "Prefix") in
  let replaced = Journal_capture.update_source capture ~source:"Replacement" in
  require
    (not (ID.Text_input.Session_id.equal session (Journal_capture.session_id replaced)))
    "programmatic capture replacement must change session";
  equal
    Ui.Text_editing.Force_replace
    (Journal_capture.update_mode replaced)
    "replacement mode";
  equal
    replaced
    (Journal_capture.apply_text_edit replaced (paste session))
    "queued paste cannot undo replacement";
  equal
    replaced
    (Journal_capture.update_source replaced ~source:"Replacement")
    "identical source keeps session";
  let edit = edit (Journal_capture.session_id replaced) 1L 0L "new session" in
  equal
    "new session"
    (Journal_capture.source (Journal_capture.apply_text_edit replaced edit))
    "new session accepts first edit"
;;

let test_detail_discard_fence () =
  let detail = detail () |> Journal_detail.begin_edit in
  let session = Journal_detail.session_id detail in
  let detail = Journal_detail.apply_text_edit detail (edit session 1L 0L "Prefix") in
  let replaced = Journal_detail.discard_edit detail |> Journal_detail.begin_edit in
  require
    (not (ID.Text_input.Session_id.equal session (Journal_detail.session_id replaced)))
    "discard must replace session before editing resumes";
  equal "Original" (detail_source replaced) "discard restores root";
  equal
    replaced
    (Journal_detail.apply_text_edit replaced (paste session))
    "discard rejects queued paste";
  let edited =
    Journal_detail.apply_text_edit
      replaced
      (edit (Journal_detail.session_id replaced) 1L 0L "fresh")
  in
  equal "fresh" (detail_source edited) "new detail session accepts edit"
;;

let test_detail_commit_fence () =
  let detail = detail () |> Journal_detail.begin_edit in
  let session = Journal_detail.session_id detail in
  let detail = Journal_detail.apply_text_edit detail (edit session 1L 0L "Saved") in
  let saving, _ = Journal_detail.admit_save detail ~mutation_id:"save" in
  let committed =
    Journal_detail.apply_block saving (block ~source:"Saved" ~revision:"block-2" ())
    |> Journal_detail.begin_edit
  in
  require
    (not (ID.Text_input.Session_id.equal session (Journal_detail.session_id committed)))
    "committed replacement must fence edits queued while saving";
  equal
    committed
    (Journal_detail.apply_text_edit committed (edit session 2L 0L "queued"))
    "committed source survives old session"
;;

let test_admission_reopen_fence () =
  let open Application.Admission_refresh in
  let inspection : Logseq_db_worker.Protocol.v2_admission_inspection =
    { active_records = 9
    ; active_bytes = 99
    ; protected_wire_bytes = 3
    ; retained_origin_evidence_bytes = 1
    ; maximum_records = 200
    ; maximum_bytes = 4096
    }
  in
  let first, directive = open_ closed ~graph_generation:1 ~graph_open:true in
  let request =
    match directive with
    | Request request -> request
    | No_request -> failwith "missing request"
  in
  let second, _ = open_ (close first) ~graph_generation:1 ~graph_open:true in
  let second, directive = complete second ~request ~result:(Inspected inspection) in
  equal
    Loading
    (observation second)
    "completion from closed inspection must not replace reopened request";
  equal No_request directive "stale completion emits no follow-up"
;;

let test_detail_reload_after_session_replacement () =
  let projection : Journal_graph_projection.detail =
    { root = block (); children = { blocks = []; continuation = None } }
  in
  let routes =
    Journal_routes.create ~anchor:{ block_id = None; first_index = 0 }
    |> fun routes ->
    Journal_routes.open_detail
      routes
      ~block_id:(Journal_model.id projection.root)
      ~request_generation:10L
    |> fun routes ->
    Journal_routes.apply_detail_response routes ~request_generation:10L projection
  in
  let edited =
    Journal_routes.detail routes
    |> Option.get
    |> Journal_detail.discard_edit
    |> Journal_detail.begin_edit
  in
  let old_session = Journal_detail.session_id edited in
  let routes =
    Journal_routes.update_detail routes edited |> Journal_routes.runtime_replaced
  in
  let routes =
    Journal_routes.apply_detail_response
      routes
      ~request_generation:(Journal_routes.detail_request_generation routes)
      projection
  in
  let reloaded =
    Journal_routes.detail routes |> Option.get |> Journal_detail.begin_edit
  in
  require
    (not
       (ID.Text_input.Session_id.equal old_session (Journal_detail.session_id reloaded)))
    "reload reused the already-replaced editor session";
  equal
    reloaded
    (Journal_detail.apply_text_edit
       reloaded
       (edit old_session 1L 0L "queued before reload"))
    "reload admitted stale-session text"
;;

let test_undo_keeps_reconciled_sibling () =
  let module Timeline = Journal_timeline_state in
  let target = block () in
  let sibling_id = "70000000-0000-4000-a000-000000000002" in
  let sibling = block ~id:sibling_id () in
  let entry block : Journal_graph_projection.timeline_entry =
    { block; child_summaries = [] }
  in
  let initial =
    Timeline.empty ~today:20260901
    |> fun state ->
    Timeline.prepend_timeline_entry state (entry sibling)
    |> fun state -> Timeline.prepend_timeline_entry state (entry target)
  in
  let staged, backup =
    Timeline.stage_delete initial ~block_id:(Journal_model.id target) |> Option.get
  in
  let latest =
    block ~id:sibling_id ~source:"Reconciled sibling" ~revision:"sibling-2" ()
  in
  let current = Timeline.replace_block staged latest in
  let restored = Timeline.undo_delete current backup in
  let blocks =
    Timeline.retained_slots restored
    |> List.filter_map (function
      | Timeline.Top_level entry -> Some entry.block
      | _ -> None)
  in
  equal 2 (List.length blocks) "Undo restores only the deleted target";
  let actual = List.find (fun block -> Journal_model.id block = sibling_id) blocks in
  equal
    "sibling-2"
    (Journal_model.revision actual)
    "Undo restored an obsolete sibling revision";
  equal
    "Reconciled sibling"
    (Journal_model.source actual)
    "Undo discarded reconciled sibling text"
;;

let cases =
  [ "M03 Undo keeps reconciled sibling", test_undo_keeps_reconciled_sibling
  ; "M05 reload after replacement session", test_detail_reload_after_session_replacement
  ; "M06 reopened request correlation", test_admission_reopen_fence
  ; "M05 Capture full-value pipeline", test_capture_pipeline
  ; "M05 Detail full-value pipeline", test_detail_pipeline
  ; "M05 invalid revisions and mode guards", test_invalid_edits
  ; "M05 Capture replacement session", test_capture_replacement_fence
  ; "M05 Detail discard session", test_detail_discard_fence
  ; "M05 Detail commit session", test_detail_commit_fence
  ]
;;

let () =
  let failures = ref [] in
  List.iter
    (fun (name, run) ->
       try
         run ();
         Printf.printf "PASS %s\n%!" name
       with
       | exn ->
         failures := name :: !failures;
         Printf.printf "FAIL %s: %s\n%!" name (Printexc.to_string exn))
    cases;
  if !failures <> [] then failwith "macOS pure reducer regressions failed";
  print_endline "MACOS_PURE_REDUCER_TESTS_PASSED"
;;
