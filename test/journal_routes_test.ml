(* These existing cases assert state transitions; cleanup cases below use the
   complete public result and assert its plan separately. *)
module Root_state = struct
  include Application.Root_navigation
  let step state event = fst (Application.Root_navigation.step state event)
end

let cleanup_paths plan =
  Rrbvec.to_seq plan
  |> Seq.map (function
    | Application.Discard_staged_file staged -> Journal_asset_import.staged_path staged)
  |> List.of_seq
;;

module ID = Journal_ids
module Ui = Journal_view

let observe_outline owner =
  fst (Journal_detail.step owner (Observe_visible_range (0L, 10000L)))
;;

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
      ?(task_state = Journal_model.Status "00000002-1615-5853-7700-000000000000")
      ?(child_count = 1)
      ?(revision = "block-1")
      ?(order = "000000000001")
      ()
  =
  Journal_model.create
    ~id
    ~page_id:"70000000-0000-4000-b000-000020260809"
    ~journal_day:20260809
    ~parent_id
    ~sibling_order:order
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

let with_status_catalog state =
  let module Graph = Logseq_db_types.Graph_types in
  let uuid =
    Graph.Uuid.of_string "00000002-1615-5853-7700-000000000000" |> Result.get_ok
  in
  let definition : Graph.task_status_definition =
    { uuid; title = "Todo"; ident = None; order = "b01"; checkbox_state = Some false }
  in
  Root_state.step
    state
    (Completed
       { payload =
           Task_statuses_changed
             { items = Rrbvec.singleton definition
             ; default_status = Some uuid
             ; complete = true
             ; error = None
             }
       })
;;

let root_navigation ~graph_generation =
  Root_state.create ~graph_generation |> with_status_catalog
;;

let test_native_composer_dismissal_and_edit_fences () =
  let module R = Root_state in
  let initial = root_navigation ~graph_generation:3 in
  let opened = R.step initial Capture_opened in
  require (R.capture_presented opened) "Capture opener must present a native sheet";
  let capture = Option.get (R.capture opened) in
  let text_edit =
    edit
      ~session_id:(Journal_capture.session_id capture)
      ~local_revision:1L
      ~base_document_revision:0L
      ~text:"Draft 中文"
      ~selection_start:7
      ~selection_end:8
      ~composing:(6, 8)
      ()
  in
  let drafted =
    R.step opened (Capture_native_edit text_edit)
    |> fun state -> R.step state (Capture_task_intent true)
  in
  let closed = R.step drafted Capture_closed in
  require (not (R.capture_presented closed)) "Close must dismiss Capture";
  let reopened = R.step closed Capture_opened in
  let restored = Option.get (R.capture reopened) in
  require_string "Draft 中文" (Journal_capture.source restored) "retained source";
  require
    (Journal_capture.task_state restored
     = Journal_model.Status "00000002-1615-5853-7700-000000000000")
    "Close discarded task intent";
  require
    (Ui.Text_editing.Value.composing (Journal_capture.value restored) <> None)
    "sheet lifetime discarded editing state";
  let stale =
    R.step
      reopened
      (Capture_native_edit { text_edit with text = "Outdated"; composing = None })
  in
  require_string
    "Draft 中文"
    (Journal_capture.source (Option.get (R.capture stale)))
    "stale edit";
  let next_graph =
    R.step stale (Graph_replaced { generation = 4; graph_id = None })
    |> fun state -> R.step state Capture_opened
  in
  let fenced = R.step next_graph (Capture_native_edit text_edit) in
  require_string
    ""
    (Journal_capture.source (Option.get (R.capture fenced)))
    "old graph edit";
  let detail = Journal_detail.create ~session_number:91L (detail ()) in
  let changed =
    Journal_detail.apply_child_edit
      detail
      (edit
         ~session_id:(Journal_detail.session_id detail)
         ~local_revision:1L
         ~base_document_revision:0L
         ~text:"Append 中文"
         ~selection_start:8
         ~selection_end:9
         ~composing:(7, 9)
         ())
  in
  let capture = Option.get (Journal_detail.child_capture changed) in
  require_string "Append 中文" (Journal_capture.source capture) "append editor";
  require (Journal_capture.update_mode capture = Ack) "Append must acknowledge editing";
  require
    (Ui.Text_editing.Value.composing (Journal_capture.value capture) <> None)
    "Append lost IME composition"
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
  let wrong =
    Journal_capture.fail_attempt
      saving
      ~mutation_id:"70000000-0000-4000-9000-000000000012"
      ~block_id:(generated_block_id 541)
      ~message:"another attempt failed"
  in
  require (wrong == saving) "another admitted attempt failed the current Capture";
  let failed =
    Journal_capture.fail_attempt
      saving
      ~mutation_id:"70000000-0000-4000-9000-000000000011"
      ~block_id:(generated_block_id 541)
      ~message:"storage unavailable"
  in
  require_string source (Journal_capture.source failed) "failed direct Capture draft";
  let changed = Journal_capture.update_source failed ~source:"replacement source" in
  require_string "replacement source" (Journal_capture.source changed)
    "unknown plain Capture did not retain a separate editable buffer";
  require(Journal_capture.pending_command changed=Journal_capture.pending_command failed)
    "editing changed the admitted original source";
  require (Journal_capture.retry_identity_locked failed)
    "unknown plain Capture did not retain its original identity";
  let changed_choice = Journal_capture.toggle_task_intent failed in
  let _, changed_retry = Journal_capture.retry changed_choice in
  (match request, changed_retry with
   | Some (Journal_graph_request.Capture original), Some (Capture latest) ->
     require (latest.command.mutation_id = original.command.mutation_id
       && latest.command.block_id = original.command.block_id
       && latest.command.source = original.command.source
       && latest.command.status_intent_revision = 1L)
       "unknown plain Capture status retry replaced its original insertion"
   | _ -> fail "unknown plain Capture lost its retry");
  let retrying, retry = Journal_capture.retry failed in
  require
    (retry = request)
    "unchanged direct Capture retry did not reuse its admitted mutation identity";
  require
    (Journal_capture.phase retrying = Journal_capture.Saving)
    "direct Capture retry did not return to Saving"
;;

let staged_pick ~operation ~path ~title ~file_type =
  match
    Journal_asset_import.decode_event
      (Printf.sprintf
         {|{"action":"picked","selection":{"operation":"%s","asset":"%s","localMutation":"%s","metadataMutation":"%s","path":"%s","title":"%s","type":"%s"}}|}
         operation
         "70000000-0000-4000-a000-00000000a001"
         "70000000-0000-4000-a000-00000000a002"
         "70000000-0000-4000-a000-00000000a003"
         path
         title
         file_type)
  with
  | Ok (Journal_asset_import.Picked (staged, _)) -> staged
  | _ -> fail "staged pick did not decode"
;;

let test_normal_attachment_pick_needs_no_replacement_metadata () =
  let target =
    Logseq_db_types.Graph_types.Uuid.of_string "70000000-0000-4000-a000-00000000a011"
    |> Result.get_ok
  in
  let payload =
    {|{"action":"picked","selection":{"operation":"70000000-0000-4000-a000-00000000a010","asset":"70000000-0000-4000-a000-00000000a001","localMutation":"70000000-0000-4000-a000-00000000a002","metadataMutation":"70000000-0000-4000-a000-00000000a003","path":"/tmp/synthetic-attachment.png","title":"Existing picker selection","type":"png"},"request":{"id":4,"source":"files","staged":false}}|}
  in
  let imported =
    match Journal_asset_import.decode ~target payload with
    | Ok imported -> imported
    | Error message -> fail "normal picker selection rejected: %s" message
  in
  require
    (imported.target = target && imported.replace_reference = None)
    "normal picker selection changed attachment destination or replaced an existing \
     reference";
  require_string "Existing picker selection" imported.title "normal picker title";
  match Journal_asset_import.decode_event payload with
  | Ok (Picked (staged, Some 4)) ->
    let imported = Journal_asset_import.to_import staged ~target in
    require
      (imported.replace_reference = None)
      "Capture pick replaced an existing reference";
    require_string
      "/tmp/synthetic-attachment.png"
      (Journal_asset_import.staged_path staged)
      "staged path"
  | _ -> fail "normal picker selection did not preserve staged event and request identity"
;;

let test_direct_capture_pending_attachments () =
  let capture = Journal_capture.create ~session_number:13L ~source:"" in
  require (not (Journal_capture.can_save capture)) "blank Capture admitted Save";
  let pick =
    staged_pick
      ~operation:"70000000-0000-4000-a000-00000000a010"
      ~path:"/tmp/a.png"
      ~title:"a.png"
      ~file_type:"png"
  in
  let attached = Journal_capture.add_attachment capture pick in
  require
    (Journal_capture.can_save attached)
    "blank Capture with a pending attachment kept Save disabled";
  let token = Journal_asset_import.staged_token pick in
  let removed = Journal_capture.remove_attachment attached ~token in
  require
    (Journal_capture.pending_attachments removed = [])
    "remove_attachment kept the picked asset";
  require
    (not (Journal_capture.can_save removed))
    "removing the only attachment left a blank Capture saveable";
  let attached = Journal_capture.add_attachment removed pick in
  let over_limit =
    List.init Journal_capture.attachment_limit (fun ordinal ->
      staged_pick
        ~operation:(Printf.sprintf "70000000-0000-4000-a000-%012x" (ordinal + 1))
        ~path:"/tmp/x.png"
        ~title:"x.png"
        ~file_type:"png")
    |> List.fold_left Journal_capture.add_attachment attached
  in
  require
    (List.length (Journal_capture.pending_attachments over_limit)
     = Journal_capture.attachment_limit)
    "pending attachments exceeded the limit";
  require
    (not (Journal_capture.can_attach over_limit))
    "Capture at the attachment limit still accepted picks";
  let saving, request =
    Journal_capture.admit_save
      attached
      ~mutation_id:"70000000-0000-4000-9000-000000000013"
      ~block_id:"70000000-0000-4000-a000-000000000013"
      ~sibling_order:"000000000013"
      ~calendar_generation:7L
      ~creation_time:(creation_time 543)
  in
  require (Option.is_some request) "attachment-only Capture did not admit Save";
  (match request with
   | Some (Journal_graph_request.Capture { command; _ }) ->
     require_string
       "a.png"
       command.source
       "attachment-only Capture did not name the block after its pick"
   | _ -> fail "attachment-only Capture admitted a non-Capture request");
  require(Journal_capture.remove_attachment saving ~token==saving)
    "pending submission allowed removal of its original staged input";
  (match Journal_capture.attachment_imports saving with
   | Some (block_id, [ staged ]) ->
     require_string
       "70000000-0000-4000-a000-000000000013"
       block_id
       "attachment imports lost the captured block";
     require_string
       "/tmp/a.png"
       (Journal_asset_import.staged_path staged)
       "attachment imports lost the staged path"
   | _ -> fail "attachment imports did not expose the pending pick");
  require
    (Journal_capture.clear_attachments attached
     |> Journal_capture.pending_attachments
     |> List.is_empty)
    "clear_attachments kept pending picks"
;;

let test_collapse_retains_complete_capture () =
  let module R = Root_state in
  let state = root_navigation ~graph_generation:3 |> fun s -> R.step s Capture_opened in
  let original = Option.get (R.capture state) in
  let edited =
    Journal_capture.apply_text_edit
      original
      (edit
         ~session_id:(Journal_capture.session_id original)
         ~local_revision:1L
         ~base_document_revision:0L
         ~text:"Draft 中文"
         ~selection_start:7
         ~selection_end:8
         ~composing:(6, 8)
         ())
  in
  let picks =
    List.init 2 (fun index ->
      staged_pick
        ~operation:(Printf.sprintf "70000000-0000-4000-a000-%012d" (100 + index))
        ~path:(if index = 0 then "/tmp/synthetic.png" else "/tmp/synthetic.pdf")
        ~title:(if index = 0 then "synthetic.png" else "synthetic.pdf")
        ~file_type:(if index = 0 then "png" else "pdf"))
  in
  let editing =
    List.fold_left
      Journal_capture.add_attachment
      (Journal_capture.toggle_task_intent edited)
      picks
  in
  let saving, request =
    Journal_capture.admit_save
      editing
      ~mutation_id:"70000000-0000-4000-9000-000000000099"
      ~block_id:"70000000-0000-4000-a000-000000000099"
      ~sibling_order:"z"
      ~calendar_generation:1L
      ~creation_time:(creation_time 550)
  in
  require (Option.is_some request) "fixture save admission failed";
  List.iter
    (fun expected ->
       let start = R.step state (Capture_admitted expected) in
       let final =
         List.fold_left
           (fun s _ ->
              let hidden = R.step s Capture_closed in
              require (not (R.capture_presented hidden)) "collapse remained visible";
              require
                (R.capture hidden = Some expected)
                "collapse changed owned draft state";
              R.step hidden Capture_opened)
           start
           [ 1; 2; 3 ]
       in
       let actual = Option.get (R.capture final) in
       require
         (actual = expected)
         "repeated expansion changed draft, phase, selection or staging";
       require
         (Journal_capture.pending_attachments actual = picks)
         "collapse lost ordered staged attachments")
    [ editing
    ; saving
    ; Journal_capture.fail saving ~message:"synthetic admission failure"
    ];
  let discarded = R.step (R.step state (Capture_admitted editing)) Capture_discarded in
  require
    (R.capture discarded = None && not (R.capture_presented discarded))
    "explicit discard retained draft state";
  let fresh = R.step discarded Capture_opened |> R.capture |> Option.get in
  require
    (Journal_capture.source fresh = ""
     && Journal_capture.task_state fresh = No_status
     && Journal_capture.pending_attachments fresh = [])
    "discard did not reset complete draft";
  let admitted = R.step state (Capture_admitted saving) in
  require
    (R.capture (R.step admitted Capture_discarded) = Some saving)
    "discard cancelled an admitted save";
  let picking = R.step state (Capture_picker_requested Journal_asset_import.Files) in
  let staged = List.hd picks in
  let hidden_completion =
    R.step (R.step picking Capture_closed) (Capture_asset_picked (staged, Some 1))
  in
  require
    (Journal_capture.pending_attachments (Option.get (R.capture hidden_completion))
     = [ staged ])
    "collapse rejected its existing picker completion";
  let replacement =
    R.step (R.step picking Capture_discarded) Capture_opened
    |> fun next -> R.step next (Capture_asset_picked (staged, Some 1))
  in
  require
    (Journal_capture.pending_attachments (Option.get (R.capture replacement)) = [])
    "discard allowed a late picker completion into the next draft"
;;

let test_direct_capture_task_intent_survives_edit_failure_and_retry () =
  let source = "  Todo 中文 👩🏽‍💻 exact  " in
  let capture = Journal_capture.create ~session_number:12L ~source in
  let task_capture = Journal_capture.toggle_task_intent capture in
  require
    (Journal_capture.task_state task_capture = Journal_model.Default_status)
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
    (Journal_capture.task_state edited = Journal_model.Default_status)
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
          { command = { source; task_state = Journal_model.Default_status; _ }; _ }) ->
     require_string edited_source source "Todo Capture admitted source"
   | _ -> fail "checked Capture did not admit one Todo request");
  let gated = Journal_capture.toggle_task_intent saving in
  require
    (Journal_capture.task_state gated = Journal_model.Default_status)
    "Saving Capture accepted a contradictory task toggle";
  let failed = Journal_capture.fail saving ~message:"storage unavailable" in
  require
    (Journal_capture.task_state failed = Journal_model.Default_status)
    "failed Capture lost task intent";
  let retrying, retry = Journal_capture.retry failed in
  require (retry = request) "Todo retry did not reuse the admitted request";
  require
    (Journal_capture.task_state retrying = Journal_model.Default_status)
    "Todo retry lost task intent";
  let replacement = Journal_capture.toggle_task_intent failed in
  require
    (Journal_capture.task_state replacement = Journal_model.No_status)
    "failed task recovery did not clear intent";
  let edited=Journal_capture.update_source replacement ~source:"Another draft" in
  require_string "Another draft" (Journal_capture.source edited) "failed task draft remains editable";
  require(Journal_capture.pending_command edited=Journal_capture.pending_command replacement)
    "task draft edit changed its admitted payload";
  let _, replacement_request = Journal_capture.retry replacement in
  match replacement_request with
  | Some
      (Journal_graph_request.Capture
         { command = { task_state = Journal_model.No_status; mutation_id; block_id; _ }
         ; _
         }) ->
    require_string "70000000-0000-4000-9000-000000000012" mutation_id "retry mutation";
    require_string "70000000-0000-4000-a000-000000000012" block_id "retry block"
  | _ -> fail "status recovery did not retain original Capture identity"
;;

let test_detail_page_keeps_newer_point_content () =
  let module D=Journal_detail in
  let root=block ~source:"root A" ~revision:"opaque-A" ~child_count:3 () in
  let root_id=Journal_model.id root in
  let child=block ~id:(generated_block_id 550) ~parent_id:(Some root_id)
    ~source:"child A" ~revision:"child-A" () in
  let cursor:Journal_graph_projection.block_cursor={after_sibling_order="one";
    after_block_id=Journal_model.id child;protocol_cursor=Some(Journal_graph_projection.Child_cursor
      {after=Coordination_test_fixture.child_continuation "point-race";maximum_items=128})} in
  let initial:Journal_graph_projection.detail={root;children={blocks=[child];continuation=Some cursor}} in
  let state,requests=D.step(D.create ~session_number:69L initial)(Load_more root_id) in
  let generation=match requests with [Journal_graph_request.Load_detail{request_generation;_}]->request_generation|_->assert false in
  let root_b=block ~source:"root B" ~revision:"opaque-B" ~child_count:3 () in
  let child_b=block ~id:(Journal_model.id child) ~parent_id:(Some root_id)
    ~source:"child B" ~revision:"child-B" () in
  let state=D.apply_block(D.apply_block state root_b)child_b in
  let new_child=block ~id:(generated_block_id 552) ~parent_id:(Some root_id) ~source:"new page" () in
  let loaded={initial with children={blocks=[child;new_child];continuation=None}} in
  let next,_=D.step state(Loaded(generation,loaded)) in
  require_string "root B" (Journal_model.source(D.root next)) "late page root";
  require_string "child B" (Journal_model.source(Option.get(D.find_block next ~block_id:(Journal_model.id child)))) "late page child";
  require(List.exists(fun value->Journal_model.id value=Journal_model.id new_child)(D.children next))
    "preserving point content discarded a valid paginated child";
  require(D.continuation next ~parent_id:root_id=None) "preserving point content discarded the page continuation";
  let run actions=
    let state,requests=D.step(D.create ~session_number:69L initial)(Load_more root_id) in
    let generation=match requests with [Journal_graph_request.Load_detail{request_generation;_}]->request_generation|_->assert false in
    let state=ref state and expected_root=ref "root A" and expected_child=ref "child A" in
    List.iteri(fun index action->
      (match action mod 5 with
       | 0->let source=Printf.sprintf "root update %d" index in expected_root:=source;
         state:=D.apply_block !state(block ~source ~revision:source ~child_count:3 ())
       | 1->let source=Printf.sprintf "child update %d" index in expected_child:=source;
         state:=D.apply_block !state(block ~id:(Journal_model.id child) ~parent_id:(Some root_id) ~source ~revision:source ())
       | 2|3->state:=fst(D.step !state(Loaded(generation,loaded)))
       | _->state:=fst(D.step !state(Load_failed(Int64.pred generation,false,"stale failure"))));
      require_string !expected_root(Journal_model.source(D.root !state)) "generated page/point root";
      require_string !expected_child(Journal_model.source(Option.get(D.find_block !state ~block_id:(Journal_model.id child))))
        "generated page/point child") actions in
  let fails actions=try run actions;false with _->true in
  let rec shrink actions=
    let rec remove prefix=function
      | []->actions
      | _::rest when fails(List.rev_append prefix rest)->shrink(List.rev_append prefix rest)
      | item::rest->remove(item::prefix)rest in remove [] actions in
  for seed=0 to 99 do
    let random=Random.State.make[|0x0A6E;seed|] in
    let actions=List.init 40(fun _->Random.State.int random 50) in
    if fails actions then fail "page/point seed=%d minimized=[%s]" seed
      (String.concat ";" (List.map string_of_int(shrink actions)))
  done
;;

let test_child_refresh_replaces_cursor_and_fences_pending_read () =
  let module D = Journal_detail in
  let root = block ~child_count:3 () in
  let root_id = Journal_model.id root in
  let child = block ~id:(generated_block_id 551) ~parent_id:(Some root_id) () in
  let cursor token : Journal_graph_projection.block_cursor =
    { after_sibling_order = Journal_model.sibling_order child
    ; after_block_id = Journal_model.id child
    ; protocol_cursor =
        Some (Journal_graph_projection.Child_cursor {after=Coordination_test_fixture.child_continuation token;maximum_items=128})
    }
  in
  let projection token : Journal_graph_projection.detail =
    { root; children = { blocks = [ child ]; continuation = Some (cursor token) } }
  in
  let initial = D.create ~session_number:70L (projection "before-write") in
  let loading, requests = D.step initial (Load_more root_id) in
  let old_generation =
    match requests with
    | [ Journal_graph_request.Load_detail { request_generation; _ } ] ->
      request_generation
    | _ -> fail "initial pagination was not admitted"
  in
  let refreshed = D.reconcile_children loading (projection "after-write") in
  require
    (D.continuation refreshed ~parent_id:root_id = Some (cursor "after-write"))
    "authoritative prefix retained an obsolete opaque continuation";
  let loading, requests = D.step refreshed (Load_more root_id) in
  require
    (match requests with
     | [ Journal_graph_request.Load_detail { after; request_generation; _ } ] ->
       after = Some (cursor "after-write") && request_generation <> old_generation
     | _ -> false)
    "prefix refresh did not admit its fresh continuation";
  let late, _ = D.step loading (Loaded (old_generation, projection "before-write")) in
  let late, _ = D.step late (Load_failed (old_generation, true, "Old failure")) in
  require
    (D.continuation late ~parent_id:root_id = Some (cursor "after-write"))
    "superseded pagination completion replaced the fresh continuation";
  require
    (List.exists
       (function
         | D.More { loading = true; error = None; _ } -> true
         | _ -> false)
       (D.rows late))
    "late failure canceled the fresh pending read"
;;

let test_append_restarts_partial_children_without_reusing_cursor () =
  let module D = Journal_detail in
  List.iter
    (fun (partial, pending_read) ->
       let root = block ~child_count:(if partial then 2 else 1) () in
       let root_id = Journal_model.id root in
       let child =
         block ~id:(generated_block_id 551) ~parent_id:(Some root_id) ~order:"a" ()
       in
       let cursor : Journal_graph_projection.block_cursor =
         { after_sibling_order = "a"
         ; after_block_id = Journal_model.id child
         ; protocol_cursor =
             Some
               (Journal_graph_projection.Child_cursor {after=Coordination_test_fixture.child_continuation "before-append";maximum_items=128})
         }
       in
       let initial =
         D.create
           ~session_number:70L
           { root
           ; children =
               { blocks = [ child ]
               ; continuation = (if partial then Some cursor else None)
               }
           }
       in
       let initial, old_requests =
         if pending_read then D.step initial (Load_more root_id) else initial, []
       in
       let saving, _ =
         D.admit_child
           (D.update_child_source initial "Appended")
           ~mutation_id:(generated_block_id 553)
           ~calendar_generation:7L
           ~block_id:(generated_block_id 554)
           ~sibling_order:"z"
           ~creation_time:(creation_time 550)
       in
       let appended =
         block
           ~id:(generated_block_id 554)
           ~parent_id:(Some root_id)
           ~source:"Appended"
           ~order:"z"
           ()
       in
       let parent =
         block ~revision:"after-append" ~child_count:(if partial then 3 else 2) ()
       in
       let created = D.apply_child_created saving ~child:appended ~parent in
       let token = D.composer_revision created in
       let stale =
         D.complete_reveal created ~token:(Int64.pred token) ~outcome:Succeeded
       in
       require
         (D.reveal_id stale = D.reveal_id created)
         "stale reveal completion consumed the append target";
       List.iter
         (fun outcome ->
            let completed = D.complete_reveal created ~token ~outcome in
            require
              (D.reveal_id completed = None)
              "terminal reveal outcome retained the target";
            require
              (D.reveal_outcome completed = Some outcome)
              "reveal outcome disappeared")
         Ui.Event.Payload.
           [ Succeeded; Missing_target; Cancelled; Superseded; Positioning_failed ];
       require
         (D.continuation created ~parent_id:root_id = None)
         "Append retained a pre-write continuation";
       require (List.length (D.children created) = 2) "Append lost visible children";
       let created =
         match old_requests with
         | [ Journal_graph_request.Load_detail { request_generation; _ } ] ->
           let late, _ =
             D.step
               created
               (Loaded
                  ( request_generation
                  , { root; children = { blocks = []; continuation = Some cursor } } ))
           in
           require
             (D.continuation late ~parent_id:root_id = None)
             "pre-Append completion revived the obsolete cursor";
           late
         | _ -> created
       in
       require
         (List.exists
            (function
              | D.More { parent_id; _ } -> parent_id = root_id
              | _ -> false)
            (D.rows created)
          = partial)
         "Append exposed the wrong pagination affordance";
       let restarting, requests = D.step created (Load_more root_id) in
       if not partial
       then require (requests = []) "complete branch reloaded after Append"
       else (
         let generation =
           match requests with
           | [ Journal_graph_request.Load_detail { after = None; request_generation; _ } ]
             -> request_generation
           | _ -> fail "partial Append did not restart from the first page"
         in
         let fresh_cursor =
           { cursor with
             protocol_cursor =
               Some
                 (Journal_graph_projection.Child_cursor {after=Coordination_test_fixture.child_continuation "after-append";maximum_items=128})
           }
         in
         let first, _ =
           D.step
             restarting
             (Loaded
                ( generation
                , { root = parent
                  ; children = { blocks = [ child ]; continuation = Some fresh_cursor }
                  } ))
         in
         require (List.length (D.children first) = 2) "restart lost the appended child";
         let next, requests = D.step first (Load_more root_id) in
         let generation =
           match requests with
           | [ Journal_graph_request.Load_detail
                 { after = Some actual; request_generation; _ }
             ]
             when actual = fresh_cursor -> request_generation
           | _ -> fail "restart did not use the fresh cursor"
         in
         let middle =
           block ~id:(generated_block_id 552) ~parent_id:(Some root_id) ~order:"m" ()
         in
         let finished, _ =
           D.step
             next
             (Loaded
                ( generation
                , { root = parent
                  ; children = { blocks = [ middle; appended ]; continuation = None }
                  } ))
         in
         require
           (List.map Journal_model.id (D.children finished)
            = List.map Journal_model.id [ child; middle; appended ])
           "Append pagination lost ordering or duplicated an identity"))
    [ true, false; true, true; false, false ]
;;

let test_outline_branches_append_and_delete () =
  let module D = Journal_detail in
  let root = block ~child_count:2 () in
  let root_id = Journal_model.id root in
  let child =
    block
      ~id:"70000000-0000-4000-a000-000000000002"
      ~parent_id:(Some root_id)
      ~source:"Child\nFull content"
      ~order:"a"
      ~child_count:1
      ()
  in
  let child_id = Journal_model.id child in
  let grandchild =
    block
      ~id:"70000000-0000-4000-a000-000000000003"
      ~parent_id:(Some child_id)
      ~source:"Grandchild"
      ~child_count:0
      ()
  in
  let cursor : Journal_graph_projection.block_cursor =
    { after_sibling_order = "m"; after_block_id = child_id; protocol_cursor = None }
  in
  let initial =
    D.create
      ~session_number:70L
      { root; children = { blocks = [ child ]; continuation = Some cursor } }
  in
  require (D.mode initial = Reading) "detail did not enter reading mode";
  require
    (D.continuation initial ~parent_id:root_id = Some cursor)
    "root lost continuation";
  require
    (List.exists
       (function
         | D.More { parent_id; _ } -> parent_id = child_id
         | _ -> false)
       (D.rows initial))
    "default outline has no child loading action";
  let opened, requests = D.step initial (Load_more child_id) in
  let generation =
    match requests with
    | [ Journal_graph_request.Load_detail
          { block_id; request_generation; after = None; _ }
      ]
      when block_id = child_id -> request_generation
    | _ -> fail "disclosure did not load its own direct children"
  in
  let repeated, requests = D.step opened (Load_more child_id) in
  require (requests = []) "branch admitted duplicate load";
  let branch : Journal_graph_projection.detail =
    { root = child; children = { blocks = [ grandchild ]; continuation = None } }
  in
  let stale, _ = D.step repeated (Loaded (Int64.pred generation, branch)) in
  require (D.children_of stale ~parent_id:child_id = []) "stale branch result accepted";
  let loaded, _ = D.step stale (Loaded (generation, branch)) in
  require
    (List.length (D.children_of loaded ~parent_id:child_id) = 1)
    "branch result missing";
  let loading_more, requests = D.step loaded (Load_more root_id) in
  let more_generation =
    match requests with
    | [ Journal_graph_request.Load_detail { after = Some actual; request_generation; _ } ]
      when actual = cursor -> request_generation
    | _ -> fail "Load more lost root cursor"
  in
  let failed, _ =
    D.step loading_more (Load_failed (more_generation, false, "Read failed"))
  in
  require
    (List.length (D.children_of failed ~parent_id:child_id) = 1)
    "branch error erased another branch";
  let retrying, requests = D.step failed (Load_more root_id) in
  require (List.length requests = 1) "failed branch was not retryable";
  let draft =
    D.update_child_source retrying "One block\nTwo lines" |> D.toggle_child_task
  in
  let saving, request =
    D.admit_child
      draft
      ~mutation_id:"70000000-0000-4000-9000-000000000070"
      ~calendar_generation:7L
      ~block_id:(generated_block_id 550)
      ~sibling_order:"unused-by-public-order-allocation"
      ~creation_time:(creation_time 550)
  in
  (match request with
   | Some
       (Journal_graph_request.Create_child
          { parent_block_id; source; task_state = Journal_model.Default_status; _ }) ->
     require_string root_id parent_block_id "append parent";
     require_string "One block\nTwo lines" source "append multiline source"
   | _ -> fail "append lost root target or task intent");
  let _, duplicate =
    D.admit_child
      saving
      ~mutation_id:"ignored"
      ~calendar_generation:7L
      ~block_id:"ignored"
      ~sibling_order:"ignored"
      ~creation_time:(creation_time 550)
  in
  require (duplicate = None) "append admitted duplicate submission";
  let failed = D.fail saving ~message:"Write failed" in
  let late, _ = D.step failed (Append_failed ("another-child", "Unrelated failure")) in
  require (D.mode late = D.mode failed) "late append failure changed another mutation";
  let correlated, _ =
    D.step saving (Append_failed (generated_block_id 550, "Append rejected"))
  in
  require
    (D.mode correlated = Failed "Append rejected")
    "matching append failure remained Saving";
  let _, retried = D.retry failed in
  require (retried = request) "append retry changed identity or parent";
  let wrong_child = D.apply_child_created saving ~child:grandchild ~parent:root in
  require (D.mode wrong_child = Saving_child) "unrelated completion committed append";
  let new_child =
    block
      ~id:(generated_block_id 550)
      ~parent_id:(Some root_id)
      ~source:"One block\nTwo lines"
      ~order:"z"
      ~child_count:0
      ()
  in
  let created = D.apply_child_created saving ~child:new_child ~parent:root in
  require
    (D.mode created = Reading && D.child_capture created = None)
    "append did not reset composer";
  require
    (List.exists
       (function
         | D.Block { block; _ } -> Journal_model.id block = Journal_model.id grandchild
         | _ -> false)
       (D.rows created))
    "append discarded visible descendant";
  let second =
    block
      ~id:"70000000-0000-4000-a000-000000000004"
      ~parent_id:(Some root_id)
      ~source:"Previously unloaded sibling"
      ~order:"m"
      ()
  in
  let pending_generation =
    match requests with
    | [ Journal_graph_request.Load_detail { request_generation; _ } ] ->
      request_generation
    | _ -> assert false
  in

  let restarted, _ =
    D.step created (Load_failed (pending_generation, true, "Cursor changed"))
  in
  let restarted, requests = D.step restarted (Load_more root_id) in
  let restart_generation =
    match requests with
    | [ Journal_graph_request.Load_detail { request_generation; after = None; _ } ] ->
      request_generation
    | _ -> fail "stale branch did not restart"
  in
  let restarted, _ =
    D.step
      restarted
      (Loaded
         ( restart_generation
         , { root; children = { blocks = [ child ]; continuation = Some cursor } } ))
  in
  require
    (List.mem
       (Journal_model.id new_child)
       (List.map Journal_model.id (D.children restarted)))
    "cursor restart lost an appended child after creation";
  let paging, requests = D.step restarted (Load_more root_id) in
  let paging_generation =
    match requests with
    | [ Journal_graph_request.Load_detail { request_generation; _ } ] ->
      request_generation
    | _ -> fail "restarted branch did not admit its next page"
  in
  let paged, _ =
    D.step
      paging
      (Loaded
         ( paging_generation
         , { root; children = { blocks = [ second; new_child ]; continuation = None } } ))
  in
  require
    (List.map Journal_model.id (D.children paged)
     = [ child_id; Journal_model.id second; Journal_model.id new_child ])
    "continuation placed the appended child before unloaded siblings";
  let refreshed =
    D.reconcile_children
      paged
      { root; children = { blocks = [ second ]; continuation = Some cursor } }
  in
  require
    (List.map Journal_model.id (D.children refreshed)
     = [ Journal_model.id second; Journal_model.id new_child ])
    "prefix refresh retained a deleted sibling before its cursor";
  let row_keys = List.map D.row_key (D.rows paged) in
  require
    (List.length row_keys = List.length (List.sort_uniq String.compare row_keys))
    "native outline received duplicate row identities";
  let deleted = D.remove_block created ~block_id:child_id |> Option.get in
  require
    (D.find_block deleted ~block_id:child_id = None)
    "committed subtree remained visible";
  require
    (D.find_block deleted ~block_id:(Journal_model.id grandchild) = None)
    "committed descendant remained visible";
  require
    (Option.is_some (D.find_block deleted ~block_id:(Journal_model.id new_child)))
    "delete discarded unrelated appended child";
  require (D.request_back created = `Close) "reading Back was blocked"
;;

let test_route_generation_background_and_runtime_replacement () =
  let routes = Journal_routes.create () in
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
    "Back did not return Timeline"
;;

let favorites_cursor_factory ?(graph_generation = 7) () =
  fun after n ->
    let wire_next = Some (Logseq_db_types.Graph_types.Cursor.of_string
      ("favorites-fixture:" ^ string_of_int n) |> Result.get_ok) in
    (Coordination_test_fixture.favorites ~graph_generation ~after ~wire_next []).next
    |> Option.get
;;

let test_favorites_state_isolates_requests_and_refreshes () =
  let module F = Journal_routes.Favorites in
  let module P = Logseq_db_worker.Protocol in
  let module G = Logseq_db_types.Graph_types in
  let uuid n =
    G.Uuid.of_string (Printf.sprintf "75000000-0000-4000-8000-%012d" n) |> Result.get_ok
  in
  let item n : Worker_pure_data.favorite_item =
    { membership_uuid = uuid n
    ; membership_order = string_of_int n
    ; membership_revision = "member"
    ; target =
        Worker_pure_data.V2_favorite_page
          { uuid = uuid (n + 100); title = string_of_int n; revision = "page" }
    }
  in
  let result ?(cursor = None) items =
    Coordination_test_fixture.favorites ~graph_generation:7
      ~favorites_page:(Some (uuid 99)) ~generation:"generation:v1:1"
      ~projection_revision:"projection:v1:1" ~next:cursor items
  in
  let request = function
    | [ r ] -> r
    | _ -> fail "expected exactly one favorites request"
  in
  let original = F.create ~graph_generation:7 in
  let inactive, commands = F.step original F.Invalidate in
  require (commands = []) "inactive favorites read eagerly";
  let selected, commands = F.step inactive (Select true) in
  let first = request commands in
  require
    (first.graph_generation = 7 && first.cursor = None)
    "first request lost graph identity";
  let selected, commands = F.step selected (Select true) in
  require (commands = []) "reselection duplicated a request";
  let cursor = favorites_cursor_factory () None 0 in
  let selected, commands =
    F.step selected (Loaded (first, result ~cursor:(Some cursor) []))
  in
  let second = request commands in
  require (second.cursor = Some cursor) "empty filtered page did not continue";
  let loaded, commands =
    F.step selected (Loaded (second, result [ item 1; item 2; item 3 ]))
  in
  require
    (F.initialized loaded && Rrbvec.length (F.items loaded) = 3 && commands = [])
    "loaded favorites missing";
  let loaded, _ = F.step loaded (Visible { first_index = 1; last_exclusive = 3 }) in
  let hidden, _ = F.step loaded (Select false) in
  let dirty, commands = F.step hidden Invalidate in
  require
    (commands = [] && F.items dirty = F.items loaded)
    "inactive invalidation lost cache";
  let refreshing, commands = F.step dirty (Select true) in
  let refresh = request commands in
  require (F.items refreshing = F.items loaded) "refresh cleared visible rows";
  let refreshed, _ = F.step refreshing (Loaded (refresh, result [ item 3; item 1 ])) in
  let refreshed, commands = F.step refreshed Invalidate in
  let refresh = request commands in
  let coalesced, commands = F.step refreshed Invalidate in
  require (commands = []) "in-flight refresh was not coalesced";
  let coalesced, commands = F.step coalesced (Loaded (refresh, result [ item 1 ])) in
  let followup = request commands in
  let failed, _ = F.step coalesced (Failed (followup, false, "Read failed")) in
  require
    (F.error failed = Some "Read failed" && not (Rrbvec.is_empty (F.items failed)))
    "refresh failure erased cache";
  let retrying, commands = F.step failed Retry in
  let retry = request commands in
  let restarted, commands = F.step retrying (Failed (retry, true, "Stale cursor")) in
  let restart = request commands in
  require
    (restart.cursor = None && F.error restarted = None)
    "stale cursor was not restarted";
  let replaced = F.create ~graph_generation:8 in
  let replaced, commands = F.step replaced (Loaded (restart, result [ item 1 ])) in
  require
    (commands = [] && Rrbvec.is_empty (F.items replaced))
    "old graph completion contaminated replacement";
  let hidden, _ = F.step restarted (Select false) in
  let hidden, commands = F.step hidden (Loaded (restart, result [ item 1 ])) in
  require
    (commands = [] && Rrbvec.length (F.items hidden) = 1)
    "inactive current completion was discarded"
;;

let test_favorites_retains_large_typed_pages () =
  let module F = Journal_routes.Favorites in
  let module P = Logseq_db_worker.Protocol in
  let module U = Logseq_db_types.Graph_types.Uuid in
  let uuid n =
    U.of_string (Printf.sprintf "76000000-0000-4000-8000-%012d" n) |> Result.get_ok
  in
  let state, requests = F.step (F.create ~graph_generation:7) (Select true) in
  let state = ref state
  and request = ref (List.hd requests) in
  let next_cursor = favorites_cursor_factory () in
  for page = 0 to 199 do
    let after = if page = 199 then None else Some (next_cursor !request.cursor page) in
    let items =
      Rrbvec.init 50 (fun index ->
        let n = (page * 50) + index + 1 in
        Worker_pure_data.{ membership_uuid = uuid n
          ; membership_order = string_of_int n
          ; membership_revision = "m"
          ; target =
              Worker_pure_data.V2_favorite_page
                { uuid = uuid (20000 + n); title = string_of_int n; revision = "p" }
          })
    in
    let result = Coordination_test_fixture.favorites ~graph_generation:7
      ~favorites_page:(Some (uuid 99999)) ~next:after (Rrbvec.to_list items)
    in
    let loaded, commands = F.step !state (Loaded (!request, result)) in
    require (commands = []) "nonempty page unexpectedly restarted the scan";
    state := loaded;
    require
      (Rrbvec.length (F.items !state) = (page + 1) * 50)
      "typed pages lost accumulated rows";
    if page < 199
    then (
      let pending, commands =
        F.step
          !state
          (Visible { first_index = page * 50; last_exclusive = (page + 1) * 50 })
      in
      state := pending;
      request := List.hd commands;
      require (!request.cursor = after) "visible paging changed its sealed continuation")
  done;
  require
    (Rrbvec.length (F.items !state) = 10000 && not (F.has_more !state))
    "large paginated state inferred completeness before the final page";
  let last = Rrbvec.nth (F.items !state) 9999 in
  require
    (U.equal last.membership_uuid (uuid 10000))
    "Rrbvec append changed Favorites order"
;;

let test_favorite_target_origin_and_delete () =
  let module P = Logseq_db_worker.Protocol in
  let module G = Logseq_db_types.Graph_types in
  let module F = Journal_routes.Favorites in
  let uuid suffix =
    G.Uuid.of_string ("75000000-0000-4000-8000-" ^ suffix) |> Result.get_ok
  in
  let membership = uuid "000000000001"
  and target = uuid "000000000002" in
  let item : Worker_pure_data.favorite_item =
    { membership_uuid = membership
    ; membership_order = "a"
    ; membership_revision = "membership-1"
    ; target =
        Worker_pure_data.V2_favorite_block
          { uuid = target; title = "Target"; task_status = None; revision = "block-1" }
    }
  in
  let origin =
    Journal_routes.create () |> fun t -> Journal_routes.select_destination t Favorites
  in
  let routes, request =
    Journal_routes.open_favorite origin ~request_generation:90L item
  in
  require
    (Journal_routes.destination (Journal_routes.back routes) = Favorites)
    "favorite Back lost its destination";
  (match request with
   | Some (Journal_graph_request.Load_detail { block_id; limit; _ }) ->
     require (limit = 128) "favorite Detail must request at most 128 children";
     require
       (block_id = G.Uuid.to_string target)
       "favorite loaded membership instead of target"
   | _ -> fail "block favorite did not load detail");
  let page_item =
    { item with
      target = Worker_pure_data.V2_favorite_page { uuid = target; title = "Page"; revision = "page-1" }
    }
  in
  let untouched, request =
    Journal_routes.open_favorite origin ~request_generation:91L page_item
  in
  require (Journal_routes.route untouched = Detail_loading && Option.is_some request)
    "page favorite did not enter shared detail";
  require (Journal_routes.destination (Journal_routes.back untouched) = Favorites)
    "page favorite Back lost origin";
  let selected, requests = F.step (F.create ~graph_generation:1) (Select true) in
  let request =
    match requests with
    | [ request ] -> request
    | _ -> fail "missing favorites read"
  in
  let loaded, _ =
    F.step
      selected
      (Loaded
         ( request
         , Coordination_test_fixture.favorites ~favorites_page:(Some membership)
             ~generation:"generation-1" ~projection_revision:"projection-1"
             [ item; { page_item with membership_uuid = uuid "000000000003" } ] ))
  in
  let hidden, _ = F.step loaded (Hide_target (G.Uuid.to_string target)) in
  require
    (Rrbvec.length (F.items hidden) = 1)
    "delete did not hide only the matching block favorite"
;;

let load_parent routes parent generation =
  Journal_routes.open_detail
    routes
    ~block_id:(Journal_model.id parent)
    ~request_generation:generation
  |> fun routes ->
  Journal_routes.apply_detail_response
    routes
    ~request_generation:generation
    (detail ~root:parent ())
;;

let test_append_drafts_follow_parent_navigation () =
  let module R = Journal_routes in
  let first = block () in
  let second = block ~id:"70000000-0000-4000-a000-000000000002" () in
  let routes = R.create () |> fun routes -> load_parent routes first 10L in
  let owner = Option.get (R.detail routes) in
  let edit =
    edit
      ~session_id:(Journal_detail.session_id owner)
      ~local_revision:1L
      ~base_document_revision:0L
      ~text:"Append 中文"
      ~selection_start:7
      ~selection_end:9
      ~composing:(7, 9)
      ()
  in
  let owner =
    Journal_detail.apply_child_edit owner edit |> Journal_detail.toggle_child_task
  in
  let routes = R.update_detail routes owner |> R.back in
  let routes = load_parent routes second 20L in
  require
    (Journal_detail.child_capture (Option.get (R.detail routes)) = None)
    "Append leaked into another parent";
  let routes =
    R.update_detail
      routes
      (Journal_detail.update_child_source (Option.get (R.detail routes)) "Second")
  in
  let routes = load_parent routes first 30L in
  let restored = Option.get (R.detail routes) in
  require
    (Journal_detail.child_capture restored <> None)
    "returning to parent lost Append draft";
  let capture = Option.get (Journal_detail.child_capture restored) in
  require_string "Append 中文" (Journal_capture.source capture) "returned parent draft";
  require
    (Journal_capture.task_state capture = Journal_model.Default_status)
    "parent return lost task intent";
  let value = Journal_capture.value capture in
  require
    (Ui.Text_editing.Range.start_utf16 (Ui.Text_editing.Value.selection value) = 7)
    "parent return lost selection";
  require (Ui.Text_editing.Value.composing value <> None) "parent return lost composition";
  require
    (not
       (ID.Text_input.Session_id.equal
          edit.session_id
          (Journal_capture.session_id capture)))
    "parent return reused a detached editor session";
  let ignored =
    Journal_detail.apply_child_edit
      restored
      { edit with
        text = "Old parent callback"
      ; local_revision = ID.Text_input.Local_revision.of_int64 2L
      ; composing = None
      }
  in
  require_string
    "Append 中文"
    (Journal_capture.source (Option.get (Journal_detail.child_capture ignored)))
    "detached edit";
  let routes = R.back routes in
  require_string
    "Second"
    (Journal_capture.source
       (Option.get (Journal_detail.child_capture (Option.get (R.detail routes)))))
    "second parent draft"
;;

let test_detached_append_completion_and_failure () =
  let module R = Journal_routes in
  let first = block () in
  let second = block ~id:"70000000-0000-4000-a000-000000000002" () in
  let child_id = "70000000-0000-4000-a000-000000000009" in
  let routes = R.create () |> fun routes -> load_parent routes first 10L in
  let saving, request =
    Journal_detail.update_child_source (Option.get (R.detail routes)) "Saved off screen"
    |> fun owner ->
    Journal_detail.admit_child
      owner
      ~mutation_id:"70000000-0000-4000-9000-000000000009"
      ~calendar_generation:1L
      ~block_id:child_id
      ~sibling_order:"z"
      ~creation_time:(creation_time 550)
  in
  require (request <> None) "Append admission failed";
  let routes =
    R.update_detail routes saving |> R.back |> fun routes -> load_parent routes second 20L
  in
  let routes =
    R.update_detail
      routes
      (Journal_detail.update_child_source (Option.get (R.detail routes)) "Keep second")
  in
  let failed = R.apply_child_failure routes ~block_id:child_id ~message:"Offline" in
  let returned = load_parent failed first 30L in
  let owner = Option.get (R.detail returned) in
  require (Journal_detail.mode owner = Failed "Offline") "off-screen failure was lost";
  let _, retry = Journal_detail.retry owner in
  require (retry = request) "off-screen retry changed mutation identity";
  let child =
    block
      ~id:child_id
      ~parent_id:(Some (Journal_model.id first))
      ~source:"Saved off screen"
      ~child_count:0
      ()
  in
  let completed = R.apply_child_created routes ~child ~parent:first in
  require_string
    "Keep second"
    (Journal_capture.source
       (Option.get (Journal_detail.child_capture (Option.get (R.detail completed)))))
    "completion erased another parent's draft";
  let returned = load_parent completed first 40L in
  require
    (Journal_detail.child_capture (Option.get (R.detail returned)) = None)
    "completed off-screen draft was resurrected";
  let wrong =
    block
      ~id:"70000000-0000-4000-a000-000000000099"
      ~parent_id:(Some (Journal_model.id first))
      ()
  in
  let retained =
    R.apply_child_created routes ~child:wrong ~parent:first
    |> fun routes -> load_parent routes first 50L
  in
  require
    (Journal_detail.mode (Option.get (R.detail retained)) = Saving_child)
    "unrelated child completion cleared the admitted draft"
;;

let test_graph_draft_retention_and_privacy () =
  let module R = Root_state in
  let graph id = Logseq_db_types.Graph_types.Uuid.of_string id |> Result.get_ok in
  let first = graph "70000000-0000-4000-b000-000000000001" in
  let second = graph "70000000-0000-4000-b000-000000000002" in
  let switch graph_id generation state =
    R.step state (Graph_replaced { graph_id; generation }) |> with_status_catalog
  in
  let start =
    root_navigation ~graph_generation:1
    |> switch (Some first) 1
    |> fun state -> R.step state Capture_opened
  in
  let capture = Option.get (R.capture start) in
  let edit =
    edit
      ~session_id:(Journal_capture.session_id capture)
      ~local_revision:1L
      ~base_document_revision:0L
      ~text:"Graph 中文"
      ~selection_start:6
      ~selection_end:8
      ~composing:(6, 8)
      ()
  in
  let drafted =
    R.step start (Capture_native_edit edit)
    |> fun state -> R.step state (Capture_task_intent true)
  in
  let other =
    drafted
    |> switch None 2
    |> switch (Some second) 3
    |> fun state -> R.step state (Capture_edited "Second graph")
  in
  let returned =
    other |> switch (Some first) 4 |> fun state -> R.step state Capture_opened
  in
  require (R.capture returned <> None) "graph return lost Capture";
  let restored = Option.get (R.capture returned) in
  require_string "Graph 中文" (Journal_capture.source restored) "graph-scoped draft";
  require
    (Journal_capture.task_state restored
     = Journal_model.Status "00000002-1615-5853-7700-000000000000")
    "graph return lost task intent";
  require
    (Ui.Text_editing.Range.start_utf16
       (Ui.Text_editing.Value.selection (Journal_capture.value restored))
     = 6)
    "graph return lost selection";
  require
    (Ui.Text_editing.Value.composing (Journal_capture.value restored) <> None)
    "graph return lost composition";
  let stale =
    R.step
      returned
      (Capture_native_edit
         { edit with
           text = "Detached graph"
         ; local_revision = ID.Text_input.Local_revision.of_int64 2L
         ; composing = None
         })
  in
  require_string
    "Graph 中文"
    (Journal_capture.source (Option.get (R.capture stale)))
    "old graph session";
  let deleted = R.step returned Local_copy_deleted |> switch (Some first) 5 in
  require (R.capture deleted = None) "deleting local copy restored its discarded draft";
  let other = deleted |> switch (Some second) 6 in
  require_string
    "Second graph"
    (Journal_capture.source (Option.get (R.capture other)))
    "deleting one graph erased another graph's draft";
  let signed_out =
    R.step other Account_cleared |> switch (Some first) 7 |> switch (Some second) 8
  in
  require (R.capture signed_out = None) "account change retained private drafts";
  let restarted = root_navigation ~graph_generation:9 |> switch (Some first) 9 in
  require
    (R.capture restarted = None)
    "process-local drafts leaked into a new application owner"
;;

let test_graph_interruption_preserves_capture_attempt () =
  let module R = Root_state in
  let graph_id =
    Logseq_db_types.Graph_types.Uuid.of_string "70000000-0000-4000-b000-000000000001"
    |> Result.get_ok
  in
  let start =
    root_navigation ~graph_generation:1
    |> fun state ->
    R.step state (Graph_replaced { generation = 1; graph_id = Some graph_id })
    |> fun state -> R.step state (Capture_edited "Retain admitted attempt")
  in
  let capture, request =
    Journal_capture.admit_save
      (Option.get (R.capture start))
      ~mutation_id:"70000000-0000-4000-9000-000000000011"
      ~block_id:"70000000-0000-4000-a000-000000000011"
      ~sibling_order:"z"
      ~calendar_generation:1L
      ~creation_time:(creation_time 550)
  in
  require (request <> None) "Capture admission failed";
  let returned =
    R.step start (Capture_admitted capture)
    |> fun state ->
    R.step state (Graph_replaced { generation = 2; graph_id = None })
    |> fun state ->
    R.step state (Graph_replaced { generation = 3; graph_id = Some graph_id })
  in
  require (R.capture returned <> None) "interruption lost admitted Capture";
  let retained = Option.get (R.capture returned) in
  require
    (match Journal_capture.phase retained with
     | Failed _ -> true
     | _ -> false)
    "interrupted save remained indefinitely busy or silently became a new attempt";
  let _, retry = Journal_capture.retry retained in
  require (retry = request) "graph return changed admitted mutation identity"
;;

let test_graph_retained_append_owner () =
  let module R = Journal_routes in
  let root = block () in
  let initial () = R.create () in
  let routes = load_parent (initial ()) root 10L in
  let owner, admitted =
    Journal_detail.update_child_source
      (Option.get (R.detail routes))
      "Pending across graph"
    |> fun owner ->
    Journal_detail.admit_child
      owner
      ~mutation_id:"70000000-0000-4000-9000-000000000011"
      ~calendar_generation:1L
      ~block_id:"70000000-0000-4000-a000-000000000011"
      ~sibling_order:"z"
      ~creation_time:(creation_time 550)
  in
  require (admitted <> None) "Append admission failed";
  let routes = R.update_detail routes owner in
  let saved = R.retain_drafts ~interrupted:true routes in
  let returned =
    R.restore_drafts (initial ()) saved |> fun routes -> load_parent routes root 20L
  in
  let owner = Option.get (R.detail returned) in
  require
    (match Journal_detail.mode owner with
     | Failed _ -> true
     | _ -> false)
    "graph interruption left Append indefinitely busy";
  let _, retry = Journal_detail.retry owner in
  require (retry = admitted) "graph restoration changed Append request identity";
  require_string
    "Pending across graph"
    (Journal_capture.source (Option.get (Journal_detail.child_capture owner)))
    "retained graph Append text"
;;

let test_late_capture_completion_preserves_newer_edit () =
  let module R = Root_state in
  let start =
    root_navigation ~graph_generation:1
    |> fun state -> R.step state (Capture_edited "Original")
  in
  let capture, request =
    Journal_capture.admit_save
      (Option.get (R.capture start))
      ~mutation_id:"70000000-0000-4000-9000-000000000001"
      ~block_id:"70000000-0000-4000-a000-000000000011"
      ~sibling_order:"z"
      ~calendar_generation:1L
      ~creation_time:(creation_time 550)
  in
  require (request <> None) "Capture admission failed";
  let interrupted = Journal_capture.fail capture ~message:"Known rejection acknowledged"
    |> Journal_capture.release_rejected_attempt in
  let state =
    R.step start (Capture_admitted interrupted)
    |> fun state -> R.step state (Capture_edited "Newer text")
  in
  let completed =
    R.step
      state
      (Completed
         { payload =
             Block_captured
               { block =
                   block ~id:"70000000-0000-4000-a000-000000000011" ~source:"Original" ()
               ; timeline_entry_update = None
               }
         })
  in
  require (R.capture completed <> None) "old completion cleared newer Capture draft";
  require_string
    "Newer text"
    (Journal_capture.source (Option.get (R.capture completed)))
    "late capture completion"
;;

let test_uncertain_append_keeps_original_attempt () =
  let module D = Journal_detail in
  let root = block () in
  let owner, request =
    D.create ~session_number:11L (detail ~root ())
    |> fun owner ->
    D.update_child_source owner "Original"
    |> fun owner ->
    D.admit_child
      owner
      ~mutation_id:"70000000-0000-4000-9000-000000000012"
      ~calendar_generation:1L
      ~block_id:"70000000-0000-4000-a000-000000000012"
      ~sibling_order:"z"
      ~creation_time:(creation_time 550)
  in
  require (request <> None) "Append admission failed";
  let capture = Option.get (D.child_capture owner) in
  let edited =
    edit
      ~session_id:(Journal_capture.session_id capture)
      ~local_revision:1L
      ~base_document_revision:0L
      ~text:"Corrected"
      ~selection_start:9
      ~selection_end:9
      ()
  in
  let blocked = D.apply_child_edit owner edited in
  require_string "Corrected" (Journal_capture.source(Option.get(D.child_capture blocked)))
    "in-flight editor buffer";
  let failed = D.fail owner ~message:"Offline" in
  let changed = D.apply_child_edit failed edited in
  require_string "Corrected" (Journal_capture.source(Option.get(D.child_capture changed)))
    "failed Append editor buffer";
  require
    (D.mode changed = Failed "Offline" && snd (D.retry changed) = request)
    "uncertain insertion lost its original retry";
  let child =
    block
      ~id:"70000000-0000-4000-a000-000000000012"
      ~parent_id:(Some (Journal_model.id root))
      ()
  in
  let late = D.apply_child_created changed ~child ~parent:root in
  require_string "Corrected" (Journal_capture.source(Option.get(D.child_capture late)))
    "matching late insertion erased the newer child draft";
  require(Journal_capture.can_save(Option.get(D.child_capture late))) "settled child kept the newer draft blocked";
  let toggled = D.toggle_child_task failed in
  require
    (D.mode toggled = Failed "Offline" && snd (D.retry toggled) <> None)
    "task edit discarded uncertain insertion";
  require
    (Journal_capture.task_state (Option.get (D.child_capture toggled))
     = Journal_model.Default_status)
    "failed Append task edit ignored";
  let text_changed = D.update_child_source failed "Replacement" in
  require_string "Replacement" (Journal_capture.source(Option.get(D.child_capture text_changed)))
    "uncertain Append editor buffer";
  require(snd(D.retry text_changed)=request) "editor buffer replaced the original child request"
;;

let test_failed_task_append_retains_identity () =
  let module D = Journal_detail in
  let root = block () in
  let saving, request =
    D.create ~session_number:12L (detail ~root ())
    |> fun t ->
    D.update_child_source t "Original task"
    |> D.toggle_child_task
    |> fun t ->
    D.admit_child
      t
      ~mutation_id:"70000000-0000-4000-9000-000000000012"
      ~calendar_generation:1L
      ~block_id:"70000000-0000-4000-a000-000000000012"
      ~sibling_order:"z"
      ~creation_time:(creation_time 550)
  in
  require (request <> None) "task Append admission failed";
  let failed = D.fail saving ~message:"Status deleted after insertion" in
  let cleared = D.set_child_task failed Journal_model.No_status in
  let edited = D.update_child_source cleared "Another draft" in
  require_string "Another draft" (Journal_capture.source(Option.get(D.child_capture edited)))
    "task Append editor buffer";
  match snd (D.retry edited) with
  | Some (Journal_graph_request.Create_child command) ->
    require_string
      "70000000-0000-4000-a000-000000000012"
      command.block_id
      "task Append retry block";
    require_string
      "70000000-0000-4000-9000-000000000012"
      command.mutation_id
      "task Append retry mutation";
    require
      (command.task_state = Journal_model.No_status)
      "task Append retry did not clear status"
  | _ -> fail "task Append lost failed identity"
;;

let test_retained_task_append_keeps_recovery_identity () =
  let module D = Journal_detail in
  List.iter
    (fun interrupted ->
       let root = block () in
       let saving, _ =
         D.create ~session_number:12L (detail ~root ())
         |> fun t ->
         D.update_child_source t "Retained task"
         |> D.toggle_child_task
         |> fun t ->
         D.admit_child
           t
           ~mutation_id:"70000000-0000-4000-9000-000000000012"
           ~calendar_generation:1L
           ~block_id:"70000000-0000-4000-a000-000000000012"
           ~sibling_order:"z"
           ~creation_time:(creation_time 550)
       in
       let retained = Option.get (D.retain_composer saving) in
       let retained =
         if interrupted
         then D.interrupt_retained_composer retained
         else
           D.fail_retained_composer
             retained
             ~block_id:"70000000-0000-4000-a000-000000000012"
             ~message:"Lost status response"
       in
       let restored =
         D.restore_composer (D.create ~session_number:13L (detail ~root ())) retained
         |> fun t ->
         D.set_child_task t Journal_model.No_status
         |> fun t -> D.update_child_source t "Another draft"
       in
       require_string "Another draft" (Journal_capture.source(Option.get(D.child_capture restored)))
         "retained task editor buffer";
       match snd (D.retry restored) with
       | Some (Journal_graph_request.Create_child command) ->
         require
           (command.status_confirmation && command.task_state = Journal_model.No_status)
           "retained task recovery lost explicit status confirmation";
         require_string
           "70000000-0000-4000-a000-000000000012"
           command.block_id
           "retained task retry block"
       | _ -> fail "retained task recovery lost pending request")
    [ false; true ]
;;

let test_capture_editor_sessions_are_not_reused () =
  let module R = Root_state in
  let initial =
    root_navigation ~graph_generation:1 |> fun state -> R.step state Capture_opened
  in
  let edited, old_edits =
    List.fold_left
      (fun (state, edits) index ->
         let state = R.step state (Capture_edited ("Draft " ^ string_of_int index)) in
         let capture = Option.get (R.capture state) in
         let obsolete =
           edit
             ~session_id:(Journal_capture.session_id capture)
             ~local_revision:1L
             ~base_document_revision:0L
             ~text:"Obsolete callback"
             ~selection_start:0
             ~selection_end:0
             ()
         in
         state, obsolete :: edits)
      (initial, [])
      (List.init 20 Fun.id)
  in
  let capture, request =
    Journal_capture.admit_save
      (Option.get (R.capture edited))
      ~mutation_id:"70000000-0000-4000-9000-000000000013"
      ~block_id:"70000000-0000-4000-a000-000000000013"
      ~sibling_order:"z"
      ~calendar_generation:1L
      ~creation_time:(creation_time 550)
  in
  require (request <> None) "Capture admission failed";
  let reopened =
    R.step edited (Capture_admitted capture)
    |> fun state ->
    R.step
      state
      (Completed
         { payload =
             Block_captured
               { block = block ~id:"70000000-0000-4000-a000-000000000013" ()
               ; timeline_entry_update = None
               }
         })
    |> fun state -> R.step state Capture_opened
  in
  let stale =
    List.fold_left
      (fun state edit -> R.step state (Capture_native_edit edit))
      reopened
      old_edits
  in
  require_string
    ""
    (Journal_capture.source (Option.get (R.capture stale)))
    "a previously issued Capture editor session was reused"
;;

let test_append_editor_session_after_save () =
  let module D = Journal_detail in
  let root = block () in
  let drafted =
    D.create ~session_number:11L (detail ~root ())
    |> fun owner ->
    D.update_child_source owner "Original"
    |> fun owner -> D.update_child_source owner "Updated"
  in
  let old = Option.get (D.child_capture drafted) in
  let saving, request =
    D.admit_child
      drafted
      ~mutation_id:"70000000-0000-4000-9000-000000000014"
      ~calendar_generation:1L
      ~block_id:"70000000-0000-4000-a000-000000000014"
      ~sibling_order:"z"
      ~creation_time:(creation_time 550)
  in
  require (request <> None) "Append admission failed";
  let child =
    block
      ~id:"70000000-0000-4000-a000-000000000014"
      ~parent_id:(Some (Journal_model.id root))
      ()
  in
  let reopened =
    D.apply_child_created saving ~child ~parent:root
    |> fun owner -> D.update_child_source owner ""
  in
  let obsolete =
    edit
      ~session_id:(Journal_capture.session_id old)
      ~local_revision:1L
      ~base_document_revision:0L
      ~text:"Old Append callback"
      ~selection_start:0
      ~selection_end:0
      ()
  in
  let changed = D.apply_child_edit reopened obsolete in
  require_string
    ""
    (Journal_capture.source (Option.get (D.child_capture changed)))
    "completed Append editor session was reused";
  let routes =
    Journal_routes.create ()
    |> fun routes ->
    load_parent routes root 10L
    |> fun routes ->
    Journal_routes.update_detail routes saving
    |> fun routes ->
    Journal_routes.apply_child_created routes ~child ~parent:root
    |> Journal_routes.back
    |> fun routes -> load_parent routes root 11L
  in
  let owner =
    Option.get (Journal_routes.detail routes)
    |> fun owner ->
    D.update_child_source owner "" |> fun owner -> D.apply_child_edit owner obsolete
  in
  require_string
    ""
    (Journal_capture.source (Option.get (D.child_capture owner)))
    "parent navigation reused a completed editor session"
;;

let test_automatic_outline_reads_are_bounded_and_idempotent () =
  let module D = Journal_detail in
  let root = block ~child_count:130 () in
  let children = List.init 130 (fun n ->
    block ~id:(generated_block_id (1000 + n)) ~parent_id:(Some (Journal_model.id root))
      ~order:(Printf.sprintf "%06d" n) ~child_count:1 ()) in
  let cursor : Journal_graph_projection.block_cursor =
    { after_sibling_order = "000127"; after_block_id = Journal_model.id (List.nth children 127)
    ; protocol_cursor = None } in
  let owner = D.create ~session_number:91L
      { root; children = { blocks = List.filteri (fun n _ -> n < 128) children
        ; continuation = Some cursor } } |> observe_outline in
  let owner, requests = D.step owner (Load_more (Journal_model.id root)) in
  let generation = match requests with
    | [ Journal_graph_request.Load_detail { request_generation; _ } ] -> request_generation
    | _ -> fail "root continuation must remain explicit" in
  let owner, _ = D.step owner (Loaded (generation,
      { root; children = { blocks = List.filteri (fun n _ -> n >= 128) children; continuation = None } })) in
  let rec finish owner n =
    if n = 128
    then owner
    else (
      let expected = Journal_model.id (List.nth children n) in
      require (D.next_automatic_load owner = Some expected) "automatic order changed";
      let owner, requests = D.step owner Load_next in
      let generation = match requests with
        | [ Journal_graph_request.Load_detail { block_id; after = None; limit = 128; request_generation } ]
          when block_id = expected -> request_generation
        | _ -> fail "automatic branch did not issue its single bounded first page" in
      let duplicate, requests = D.step owner Load_next in
      require (requests = [] && D.next_automatic_load duplicate = None)
        "automatic loading admitted a duplicate/concurrent read";
      let owner, _ = D.step duplicate (Loaded (generation,
          { root = List.nth children n; children = { blocks = []; continuation = None } })) in
      finish owner (n + 1))
  in
  let owner = finish owner 0 in
  require (D.next_automatic_load owner = None) "automatic branch budget exceeded 128";
  let manual = Journal_model.id (List.nth children 128) in
  require
    (List.exists
       (function
         | D.More { parent_id; loading = false; _ } -> parent_id = manual
      | _ -> false) (D.rows owner)) "budget exhaustion removed Load more";
  let owner, requests = D.step owner (Load_more manual) in
  let generation = match requests with
    | [ Journal_graph_request.Load_detail { request_generation; _ } ] -> request_generation
    | _ -> fail "manual Load more did not continue after automatic budget" in
  let failed, _ = D.step owner (Load_failed (generation, false, "offline")) in
  require (D.next_automatic_load failed = Some (Journal_model.id (List.nth children 129)))
    "failed branch blocked another eligible branch or retried automatically";
  let retried, requests = D.step failed (Load_more manual) in
  require (List.length requests = 1 && D.next_automatic_load retried = None)
    "explicit retry must retain single-read admission"
;;

let test_favorites_hidden_rows_do_not_block_pagination () =
  let module F = Journal_routes.Favorites in
  let module P = Logseq_db_worker.Protocol in
  let module G = Logseq_db_types.Graph_types in
  let uuid n =
    G.Uuid.of_string (Printf.sprintf "76000000-0000-4000-8000-%012d" n) |> Result.get_ok
  in
  let item membership target : Worker_pure_data.favorite_item =
    { membership_uuid = uuid membership
    ; membership_order = string_of_int membership
    ; membership_revision = "member"
    ; target =
        Worker_pure_data.V2_favorite_block
          { uuid = uuid (100 + target)
          ; title = "Target"
          ; task_status = None
          ; revision = "block"
          }
    }
  in
  let make_cursor=favorites_cursor_factory ~graph_generation:1 () in
  let cursor n = make_cursor None n in
  let result items next =
    Coordination_test_fixture.favorites ~favorites_page:(Some (uuid 99))
      ~generation:"generation:v1:1" ~projection_revision:"projection:v1:1" ~next items
  in
  let one = function
    | [ request ] -> request
    | _ -> fail "expected one continuation request"
  in
  let loaded count =
    let selected, requests = F.step (F.create ~graph_generation:1) (Select true) in
    let state, _ =
      F.step
        selected
        (Loaded
           ( one requests
           , result (List.init count (fun i -> item (i + 1) (i + 1))) (Some (cursor 1)) ))
    in
    state
  in
  let hide state n = F.step state (Hide_target (G.Uuid.to_string (uuid (100 + n)))) in
  let hidden =
    List.fold_left
      (fun state n -> fst (hide state n))
      (loaded 16)
      (List.init 14 (( + ) 1))
  in
  require (Rrbvec.length (F.items hidden) = 2) "fixture did not hide target rows";
  let paging, requests =
    F.step hidden (Visible { first_index = 0; last_exclusive = 2 })
  in
  require (requests <> []) "hidden favorites prevented pagination at the visible List end";
  let request = one requests in
  require (request.cursor = Some (cursor 1)) "visible List end lost its continuation";
  let _, requests = F.step paging (Visible { first_index = 0; last_exclusive = 2 }) in
  require (requests = []) "repeated native visibility duplicated pagination";
  let failed, _ = F.step paging (Failed (request, false, "Unavailable")) in
  let _, requests = F.step failed (Visible { first_index = 0; last_exclusive = 2 }) in
  require (requests = []) "visibility retried a failed read without user action";
  let inactive, _ = F.step (loaded 2) (Select false) in
  let inactive, _ = hide inactive 1 in
  let inactive, requests = hide inactive 2 in
  require (requests = []) "inactive Favorites paginated after hiding its final row";
  let _, requests = F.step inactive (Select true) in
  require (requests <> []) "reselecting empty cached Favorites stranded its continuation";
  let hidden, _ = hide (loaded 2) 1 in
  let empty, requests = hide hidden 2 in
  require
    (Rrbvec.is_empty(F.items empty) && requests <> [])
    "hiding the final row stranded the continuation";
  let request = one requests in
  let _, requests =
    F.step empty (Loaded (request, result [ item 17 1; item 18 2 ] (Some (cursor 2))))
  in
  require
    ((one requests).cursor = Some (cursor 2))
    "a fully hidden page stopped the continuation chain"
;;

let test_root_noops_preserve_observable_owner () =
  let module R = Root_state in
  let unchanged state event label =
    require (R.step state event == state) "%s published an unchanged root model" label
  in
  let initial = root_navigation ~graph_generation:3 in
  unchanged initial Capture_closed "already closed capture";
  unchanged initial (Capture_task_intent false) "task intent without a draft";
  let opened = R.step initial Capture_opened in
  unchanged opened Capture_opened "already open capture";
  unchanged opened (Select Journals) "selected destination with retained draft";
  unchanged opened (Capture_task_intent false) "unchanged task intent";
  unchanged opened (Capture_edited "") "unchanged source";
  let capture = Option.get (R.capture opened) in
  let valid =
    edit
      ~session_id:(Journal_capture.session_id capture)
      ~local_revision:1L
      ~base_document_revision:0L
      ~text:"Retained draft"
      ~selection_start:14
      ~selection_end:14
      ()
  in
  let edited = R.step opened (Capture_native_edit valid) in
  require (edited != opened) "valid edit did not publish its changed state";
  unchanged edited (Capture_native_edit valid) "duplicate native edit";
  let wrong_session =
    edit
      ~session_id:
        (Journal_capture.session_id
           (Journal_capture.create ~session_number:99L ~source:""))
      ~local_revision:2L
      ~base_document_revision:0L
      ~text:"Wrong draft"
      ~selection_start:0
      ~selection_end:0
      ()
  in
  unchanged edited (Capture_native_edit wrong_session) "foreign-session native edit";
  unchanged
    edited
    (Completed
       { payload = Admission_unavailable { graph_generation = 3; request_generation = 1L }
       })
    "unobserved admission completion";
  unchanged
    edited
    (Completed { payload = Reference_sources_changed [] })
    "empty reference update";
  let stale_request : Journal_graph_request.favorites_request =
    { graph_generation = 2; request_generation = 1L; limit = 50; cursor = None }
  in
  unchanged
    edited
    (Completed { payload = Favorites_failed (stale_request, true, "stale") })
    "foreign-graph Favorites completion";
  let selected = R.step edited (Capture_task_intent true) in
  require (selected != edited) "changed task intent was suppressed";
  require
    (Journal_capture.task_state (Option.get (R.capture selected))
     = Journal_model.Status "00000002-1615-5853-7700-000000000000")
    "changed task intent was not retained";
  let closed = R.step selected Capture_closed in
  require (not (R.capture_presented closed)) "closing was suppressed";
  unchanged closed Capture_closed "duplicate close with retained draft";
  require_string
    "Retained draft"
    (Journal_capture.source (Option.get (R.capture closed)))
    "no-op draft retention"
;;

let test_detail_noop_completion_retains_route_owner () =
  let routes =
    Journal_routes.create ()
    |> fun routes ->
    Journal_routes.open_detail
      routes
      ~block_id:(Journal_model.id (block ()))
      ~request_generation:30L
    |> fun routes ->
    Journal_routes.apply_detail_response routes ~request_generation:30L (detail ())
  in
  let retained = Option.get (Journal_routes.detail routes) in
  require
    (Journal_routes.update_detail routes retained == routes)
    "unchanged Detail republishes its route owner";
  let stale = Journal_detail.complete_reveal retained ~token:0L ~outcome:Succeeded in
  require (stale == retained) "stale reveal completion changed its detail owner";
  require
    (Journal_routes.update_detail routes stale == routes)
    "stale reveal completion republishes its route owner";
  let foreign =
    edit
      ~session_id:
        (Journal_capture.session_id
           (Journal_capture.create ~session_number:999L ~source:""))
      ~local_revision:1L
      ~base_document_revision:0L
      ~text:"Foreign Append"
      ~selection_start:0
      ~selection_end:0
      ()
  in
  let ignored = Journal_detail.apply_child_edit retained foreign in
  require (ignored == retained) "foreign Append editor event changed its detail owner";
  require
    (Journal_routes.update_detail routes ignored == routes)
    "foreign Append editor event republishes its route owner";
  let changed = Journal_detail.update_child_source retained "Changed Append" in
  let updated = Journal_routes.update_detail routes changed in
  require (updated != routes) "changed Append did not publish its route owner";
  require_string
    "Changed Append"
    (Journal_capture.source
       (Option.get
          (Journal_detail.child_capture (Option.get (Journal_routes.detail updated)))))
    "changed Append source"
;;

let test_public_nested_detail_owners () =
  let module R = Journal_routes in
  let parent = block () in
  let other = block ~id:"70000000-0000-4000-a000-000000000002" () in
  let errors = ref [] in
  let check label run =
    try run () with
    | error ->
      Printf.eprintf "PUBLIC_OWNER_RED %s: %s\n%!" label (Printexc.to_string error);
      errors := label :: !errors
  in
  check "A -> B -> Back preserves A" (fun () ->
    let first = load_parent (R.create ()) parent 100L in
    let original = Option.get (R.detail first) in
    let covered = load_parent first other 200L in
    let returned = R.back covered in
    require
      (R.detail_block_id returned = Some (Journal_model.id parent))
      "Back discarded the covered parent";
    require (R.detail returned = Some original) "Back recreated the covered detail state");
  check "same block presentations own independent composers" (fun () ->
    let first = load_parent (R.create ()) parent 300L in
    let first =
      R.update_detail
        first
        (Journal_detail.update_child_source
           (Option.get (R.detail first))
           "First entry draft")
    in
    let second = load_parent first parent 400L in
    require
      (Journal_detail.child_capture (Option.get (R.detail second)) = None)
      "new same-block entry cloned a live entry's composer";
    let returned = R.back second in
    require_string
      "First entry draft"
      (Journal_capture.source
         (Option.get (Journal_detail.child_capture (Option.get (R.detail returned)))))
      "covered same-block composer");
  require
    (!errors = [])
    "public nested detail owners failed: %s"
    (String.concat ", " (List.rev !errors))
;;

let entry_id routes = Option.get (Journal_routes.active_entry_id routes)
let entry routes id = Option.get (Journal_routes.at_entry routes ~entry_id:id)
let entry_detail routes id = Option.get (Journal_routes.detail (entry routes id))

let path_ids routes =
  Lui_navigation.Path.entries (Journal_routes.path routes)
  |> List.map (fun (entry : string Lui_navigation.entry) -> entry.id)
;;

let test_typed_path_prefix_and_loading_owners () =
  let module R = Journal_routes in
  let a = block ()
  and b = block ~id:"70000000-0000-4000-a000-000000000002" () in
  let loading_a =
    R.open_detail (R.create ()) ~block_id:(Journal_model.id a) ~request_generation:500L
  in
  let a_id = entry_id loading_a in
  let loading_b =
    R.open_detail loading_a ~block_id:(Journal_model.id b) ~request_generation:600L
  in
  let b_id = entry_id loading_b in
  let loaded_a =
    R.apply_detail_response loading_b ~request_generation:500L (detail ~root:a ())
  in
  require (R.route loaded_a = Detail_loading) "covered success replaced top loading owner";
  require (R.route (entry loaded_a a_id) = Detail) "covered initial success was discarded";
  let failed_b =
    R.apply_detail_failure
      ~block_id:(Journal_model.id b)
      loaded_a
      ~request_generation:600L
      ~missing:false
      ~message:"Blocked"
  in
  require
    (R.route failed_b = Failed_detail "Blocked")
    "matching top failure was discarded";
  let retry, request = R.retry_detail failed_b ~request_generation:700L in
  require
    (path_ids retry = [ a_id; b_id ] && entry_id retry = b_id)
    "Retry changed presentation identity or path depth";
  require (Option.is_some request) "Retry did not request the same entry";
  let stale =
    R.apply_detail_response retry ~request_generation:600L (detail ~root:b ())
  in
  require (stale == retry) "Retry accepted its obsolete initial response";
  let retry =
    R.apply_detail_response retry ~request_generation:700L (detail ~root:b ())
  in
  let foreign =
    R.open_detail (R.create ()) ~block_id:(Journal_model.id a) ~request_generation:800L
  in
  require
    (R.accept_path retry (R.path foreign) == retry)
    "native path accepted foreign entries";
  require
    (R.accept_path retry (R.path retry) == retry)
    "identical native path republished owner";
  let shortened = R.accept_path retry (R.path loading_a) in
  require
    (path_ids shortened = [ a_id ]
     && R.detail_block_id shortened = Some (Journal_model.id a))
    "prefix pop lost covered presentation";
  require (R.at_entry shortened ~entry_id:b_id = None) "popped entry remained live";
  let late =
    R.apply_detail_response shortened ~request_generation:700L (detail ~root:b ())
  in
  require (late == shortened) "popped initial response recreated an entry";
  let root = R.pop_to_root shortened in
  require
    (path_ids root = [] && R.route root = Timeline && R.active_entry_id root = None)
    "pop_to_root retained a presentation";
  require (R.back root == root) "empty back republished owner"
;;

let test_typed_covered_failure_missing_and_branch () =
  let module R = Journal_routes in
  let a = block ()
  and b = block ~id:"70000000-0000-4000-a000-000000000002" () in
  let child =
    block
      ~id:"70000000-0000-4000-a000-000000000003"
      ~parent_id:(Some (Journal_model.id a))
      ~child_count:2
      ()
  in
  let initial =
    R.open_detail (R.create ()) ~block_id:(Journal_model.id a) ~request_generation:810L
  in
  let a_id = entry_id initial in
  let covered = load_parent initial b 820L in
  let b_id = entry_id covered in
  let b_owner = entry_detail covered b_id in
  let wrong =
    R.apply_detail_failure
      ~block_id:(Journal_model.id b)
      covered
      ~request_generation:810L
      ~missing:true
      ~message:"wrong target"
  in
  require (wrong == covered) "failure for another block changed the loading owner";
  let failed =
    R.apply_detail_failure
      ~block_id:(Journal_model.id a)
      covered
      ~request_generation:810L
      ~missing:false
      ~message:"covered failure"
  in
  require
    (R.route (entry failed a_id) = Failed_detail "covered failure"
     && entry_detail failed b_id == b_owner)
    "covered failure changed the top owner";
  let retry, _ = R.retry_detail_at failed ~entry_id:a_id ~request_generation:830L in
  require (entry_id retry = b_id) "covered Retry changed the top owner";
  let ready =
    R.apply_detail_response
      retry
      ~request_generation:830L
      (detail ~root:a ())
  in
  (* This regression concerns a later branch read on an already published
     owner. Reconcile the newly observed child through the public outline API. *)
  let ready = R.update_detail_at ready ~entry_id:a_id
      (Journal_detail.reconcile_children (entry_detail ready a_id)
         { Journal_graph_projection.root = a
         ; children = { blocks = [ child ]; continuation = None }
         }) in
  let owner = entry_detail ready a_id in
  let owner, requests =
    Journal_detail.step owner (Load_more (Journal_model.id child))
  in
  let generation =
    match requests with
    | [ Journal_graph_request.Load_detail { request_generation; _ } ] ->
      request_generation
    | _ -> fail "branch event did not produce one owned request"
  in
  let loading = R.update_detail_at ready ~entry_id:a_id owner in
  let failed =
    R.apply_detail_failure
      ~block_id:(Journal_model.id child)
      ~stale_cursor:true
      loading
      ~request_generation:generation
      ~missing:false
      ~message:"stale branch"
  in
  require
    (entry_detail failed b_id == b_owner)
    "covered branch failure changed sibling owner";
  let owner, requests =
    Journal_detail.step (entry_detail failed a_id) (Load_more (Journal_model.id child))
  in
  let fresh =
    match requests with
    | [ Journal_graph_request.Load_detail { after = None; request_generation; _ } ] ->
      request_generation
    | _ -> fail "stale branch retry reused its old cursor"
  in
  let loading = R.update_detail_at failed ~entry_id:a_id owner in
  let grandchild =
    block
      ~id:"70000000-0000-4000-a000-000000000004"
      ~parent_id:(Some (Journal_model.id child))
      ()
  in
  let projection =
    { Journal_graph_projection.root = child
    ; children = { blocks = [ grandchild ]; continuation = None }
    }
  in
  require
    (R.apply_detail_response loading ~request_generation:generation projection == loading)
    "covered branch accepted obsolete generation";
  let completed = R.apply_detail_response loading ~request_generation:fresh projection in
  require
    (Journal_detail.find_block
       (entry_detail completed a_id)
       ~block_id:(Journal_model.id grandchild)
     <> None)
    "covered branch success was discarded";
  require
    (entry_detail completed b_id == b_owner)
    "covered branch success rebuilt the sibling owner";
  let cleared = R.graph_unavailable completed in
  require
    (path_ids cleared = [] && R.at_entry cleared ~entry_id:a_id = None)
    "graph replacement retained the path or live map";
  require
    (R.apply_detail_response cleared ~request_generation:fresh projection == cleared)
    "old graph branch completion revived an owner";
  let missing =
    R.open_detail (R.create ()) ~block_id:(Journal_model.id a) ~request_generation:840L
  in
  let a_id = entry_id missing in
  let missing =
    load_parent missing b 850L
    |> fun t -> R.apply_missing_detail t ~request_generation:840L
  in
  require
    (R.route (entry missing a_id) = Missing_detail && R.route missing = Detail)
    "covered missing result changed the top entry"
;;

let test_typed_shared_data_delete_and_drafts () =
  let module R = Journal_routes in
  let parent = block () in
  let first = load_parent (R.create ()) parent 900L in
  let first_id = entry_id first in
  let first =
    R.update_detail
      first
      (Journal_detail.update_child_source (Option.get (R.detail first)) "First retained")
  in
  let second = load_parent first parent 910L in
  let second_id = entry_id second in
  let second =
    R.update_detail
      second
      (Journal_detail.update_child_source
         (Option.get (R.detail second))
         "Second retained")
  in
  require
    (not
       (ID.Text_input.Session_id.equal
          (Journal_detail.session_id (entry_detail second first_id))
          (Journal_detail.session_id (entry_detail second second_id))))
    "duplicate entry reused editor session";
  let latest =
    block ~task_state:(Journal_model.Status "00000002-1827-5820-8200-000000000000") ()
  in
  let shared = R.map_details second ~f:(fun d -> Journal_detail.apply_block d latest) in
  List.iter
    (fun id ->
       require
         (Journal_model.task_state (Journal_detail.root (entry_detail shared id))
          = Journal_model.Status "00000002-1827-5820-8200-000000000000")
         "shared graph data was not propagated to every matching live owner")
    [ first_id; second_id ];
  require_string
    "First retained"
    (Journal_capture.source
       (Option.get (Journal_detail.child_capture (entry_detail shared first_id))))
    "first independent draft after graph update";
  let deleted, _ = R.commit_delete shared ~block_id:(Journal_model.id parent) in
  List.iter
    (fun id -> require (R.route (entry deleted id) = Missing_detail)
        "delete left a matching live root visible")
    [ first_id; second_id ];
  let deleted_reopened = R.pop_to_root deleted |> fun t -> load_parent t parent 925L in
  require (Journal_detail.child_capture (Option.get (R.detail deleted_reopened)) = None)
    "committed deletion retained a root draft";
  let detached = R.pop_to_root shared in
  let reopened = load_parent detached parent 920L in
  require_string
    "Second retained"
    (Journal_capture.source
       (Option.get (Journal_detail.child_capture (Option.get (R.detail reopened)))))
    "most recently detached same-parent draft";
  let next = R.back reopened |> fun t -> load_parent t parent 930L in
  require_string
    "Second retained"
    (Journal_capture.source
       (Option.get (Journal_detail.child_capture (Option.get (R.detail next)))))
    "repeated reopen draft contract"
;;

let test_typed_detached_duplicate_pending_mutations () =
  let module R = Journal_routes in
  let parent = block () in
  let save routes child_id text =
    let detail, request =
      Journal_detail.update_child_source (Option.get (R.detail routes)) text
      |> fun owner ->
      Journal_detail.admit_child
        owner
        ~mutation_id:child_id
        ~calendar_generation:1L
        ~block_id:child_id
        ~sibling_order:"z"
        ~creation_time:(creation_time 550)
    in
    require
      (Option.is_some request)
      "duplicate owner did not admit an independent mutation";
    R.update_detail routes detail
  in
  let child1 = "70000000-0000-4000-a000-000000000031" in
  let child2 = "70000000-0000-4000-a000-000000000032" in
  let first =
    load_parent (R.create ()) parent 950L |> fun t -> save t child1 "First pending"
  in
  let second = load_parent first parent 960L |> fun t -> save t child2 "Second pending" in
  let detached = R.pop_to_root second in
  let child id source =
    block ~id ~parent_id:(Some (Journal_model.id parent)) ~source ()
  in
  let completed =
    R.apply_child_created detached ~child:(child child1 "First pending") ~parent
  in
  let reopened = load_parent completed parent 970L in
  require
    (Journal_detail.mode (Option.get (R.detail reopened)) = Saving_child)
    "completion for first owner erased second pending mutation";
  require_string
    "Second pending"
    (Journal_capture.source
       (Option.get (Journal_detail.child_capture (Option.get (R.detail reopened)))))
    "independent detached pending mutation";
  let failed = R.apply_child_failure reopened ~block_id:child2 ~message:"offline" in
  require
    (Journal_detail.mode (Option.get (R.detail failed)) = Failed "offline")
    "matching owner lost its pending failure";
  let old_epoch = R.runtime_replaced failed in
  require
    (path_ids old_epoch = path_ids failed && R.route old_epoch = Detail_loading)
    "runtime reload changed entry identity";
  let reloaded =
    R.apply_detail_response
      old_epoch
      ~request_generation:(R.detail_request_generation old_epoch)
      (detail ~root:parent ())
  in
  require
    (Journal_detail.child_capture (Option.get (R.detail reloaded)) <> None)
    "runtime reload lost the retained independent attempt"
;;

let multiselect_pick index path source_identity =
  let identity offset =
    Printf.sprintf "71000000-0000-4000-a000-%012d" ((index * 4) + offset)
  in
  `Assoc
    [ "operation", `String (identity 0)
    ; "asset", `String (identity 1)
    ; "localMutation", `String (identity 2)
    ; "metadataMutation", `String (identity 3)
    ; "path", `String path
    ; "title", `String (Filename.basename path)
    ; "type", `String "png"
    ; "sourceIdentity", `String source_identity
    ]
;;

let multiselect_staged index path source_identity =
  match
    Journal_asset_import.decode_event
      (Yojson.Basic.to_string (`Assoc ["action", `String "picked"; "selection", multiselect_pick index path source_identity]))
  with
  | Ok (Picked (staged, _)) -> staged
  | _ -> fail "valid generated selection did not decode"
;;

let with_multiselect_paths count f =
  f (List.init count (fun index -> Printf.sprintf "/pure-fixture/selection-%02d.png" index))
;;

let test_multiselect_batch_boundary () =
  List.iter
    (fun (items, error) ->
       let payload =
         Yojson.Basic.to_string
           (`Assoc
               [ "action", `String "picked-batch"
               ; "items", `List items
               ; "request", `Assoc [ "id", `Int 1 ]
               ; ( "error"
                 , match error with
                   | None -> `Null
                   | Some message -> `String message )
               ])
       in
       match Journal_asset_import.decode_event payload with
       | Ok (Picked_batch (decoded, Some 1, actual_error)) ->
         require
           (List.map Journal_asset_import.staged_path decoded
            = List.map
                (fun item ->
                   Yojson.Basic.Util.member "path" item |> Yojson.Basic.Util.to_string)
                items)
           "batch reordered valid siblings";
         require (actual_error = error) "batch lost its partial failure feedback"
       | _ -> fail "ordered/empty/partial-failure native batch was rejected")
    [ ( [ multiselect_pick 0 "/tmp/a.png" "files:a"
        ; multiselect_pick 1 "/tmp/b.png" "files:b"
        ]
      , None )
    ; [], None
    ; [ multiselect_pick 1 "/tmp/b.png" "photos:b" ], Some "One photo could not be read."
    ; [], Some "Unable to read the selected photos."
    ];
  require
    (Result.is_error
       (Journal_asset_import.decode_event
          {|{"action":"picked-batch","items":[{}],"request":{"id":1}}|}))
    "malformed batch item acquired ownership"
;;

let test_multiselect_order_duplicates_and_readd () =
  let module R = Root_state in
  with_multiselect_paths 4 (function
    | [ a; b; c; duplicate ] ->
      let picks =
        List.mapi
          (fun i path -> multiselect_staged i path ("files:" ^ string_of_int i))
          [ a; b; c ]
      in
      let start =
        root_navigation ~graph_generation:1
        |> fun s ->
        R.step s Capture_opened |> fun s -> R.step s (Capture_picker_requested Files)
      in
      let selected = R.step start (Capture_assets_picked (picks, Some 1, None)) in
      let current s = Journal_capture.pending_attachments (Option.get (R.capture s)) in
      require
        (List.map Journal_asset_import.staged_path (current selected) = [ a; b; c ])
        "selection order was lost";
      let duplicate_pick = multiselect_staged 4 duplicate "files:1" in
      let deduped, plan = Application.Root_navigation.step selected (Capture_asset_picked (duplicate_pick, Some 1)) in
      require (current deduped = picks) "same source added a duplicate attachment";
      require (cleanup_paths plan = [duplicate]) "duplicate copy was not retired";
      let repeated, plan = Application.Root_navigation.step deduped (Capture_asset_picked (List.hd picks, Some 1)) in
      require
        (current repeated = picks && Rrbvec.length plan = 0)
        "replayed event removed an owned source or added a duplicate";
      let removed =
        Journal_capture.remove_attachment
          (Option.get (R.capture repeated))
          ~token:(Journal_asset_import.staged_token (List.nth picks 1))
      in
      let readded = Journal_capture.add_attachment removed (List.nth picks 1) in
      require
        (List.map
           Journal_asset_import.staged_path
           (Journal_capture.pending_attachments readded)
         = [ a; c; b ])
        "removed source could not be readded at selection tail"
    | _ -> assert false)
;;

let test_multiselect_rejected_resource_ownership () =
  let module R = Root_state in
  with_multiselect_paths (Journal_capture.attachment_limit + 2) (fun files ->
    let picks =
      List.mapi
        (fun i path -> multiselect_staged i path ("files:" ^ string_of_int i))
        files
    in
    let start =
      root_navigation ~graph_generation:1
      |> fun s ->
      R.step s Capture_opened |> fun s -> R.step s (Capture_picker_requested Files)
    in
    let full =
      List.fold_left
        (fun s p -> R.step s (Capture_asset_picked (p, Some 1)))
        start
        (List.filteri (fun i _ -> i < Journal_capture.attachment_limit) picks)
    in
    let overflow = List.nth picks Journal_capture.attachment_limit in
    let next, plan = Application.Root_navigation.step full (Capture_asset_picked (overflow, Some 1)) in
    require
      (List.length (Journal_capture.pending_attachments (Option.get (R.capture next)))
       = Journal_capture.attachment_limit)
      "capacity changed";
    require
      (cleanup_paths plan = [Journal_asset_import.staged_path overflow])
      "capacity rejection did not retire its staging copy";
    let saving =
      Journal_capture.update_source (Option.get (R.capture start)) ~source:"Saving owner"
      |> fun capture ->
      fst
        (Journal_capture.admit_save
           capture
           ~mutation_id:"71000000-0000-4000-9000-000000000090"
           ~block_id:"71000000-0000-4000-a000-000000000090"
           ~sibling_order:"z"
           ~calendar_generation:1L
           ~creation_time:(creation_time 1))
    in
    let rejected = List.nth picks (Journal_capture.attachment_limit + 1) in
    let after, plan =
      Application.Root_navigation.step
        (R.step start (Capture_admitted saving))
        (Capture_asset_picked (rejected, Some 1))
    in
    require (R.capture after = Some saving) "saving capture accepted an async attachment";
    require
      (cleanup_paths plan = [Journal_asset_import.staged_path rejected])
      "saving rejection did not retire its staging copy")
;;

let test_multiselect_graph_owner_and_cancel () =
  let module R = Root_state in
  let graph index =
    Logseq_db_types.Graph_types.Uuid.of_string
      (Printf.sprintf "71000000-0000-4000-b000-%012d" index)
    |> Result.get_ok
  in
  with_multiselect_paths 2 (function
    | [ kept; late ] ->
      let start =
        root_navigation ~graph_generation:1
        |> fun s ->
        R.step s (Graph_replaced { graph_id = Some (graph 1); generation = 1 })
        |> fun s ->
        R.step s Capture_opened |> fun s -> R.step s (Capture_picker_requested Photos)
      in
      let pick = multiselect_staged 1 kept "photos:kept" in
      let selected = R.step start (Capture_asset_picked (pick, Some 1)) in
      require
        (Journal_asset_import.is_dismissal {|{"action":"dismissed","request":{"id":1}}|})
        "picker cancellation did not decode";
      let collapsed, plan = Application.Root_navigation.step selected Capture_closed in
      require
        (R.capture collapsed = R.capture selected && Rrbvec.length plan = 0)
        "cancellation/collapse erased owned attachments";
      let switched, plan = Application.Root_navigation.step collapsed
        (Graph_replaced { graph_id = Some (graph 2); generation = 2 }) in
      let other = R.step switched Capture_opened in
      require (Rrbvec.length plan = 0) "graph retention retired owned attachment";
      let stale, plan =
        Application.Root_navigation.step
          other
          (Capture_asset_picked (multiselect_staged 2 late "photos:late", Some 1))
      in
      require
        (Journal_capture.pending_attachments (Option.get (R.capture stale)) = [])
        "old graph completion acquired a new draft";
      require (cleanup_paths plan = [late]) "old graph completion did not retire orphan";
      let returned, plan =
        Application.Root_navigation.step stale (Graph_replaced { graph_id = Some (graph 1); generation = 3 })
      in
      require
        (Journal_capture.pending_attachments (Option.get (R.capture returned)) = [ pick ]
         && Rrbvec.length plan = 0)
        "returning graph lost staged ownership";
      let other =
        R.step returned (Graph_replaced { graph_id = Some (graph 2); generation = 4 })
      in
      let _, plan = Application.Root_navigation.step other Account_cleared in
      require (cleanup_paths plan = [kept]) "sign-out did not retire retained graph staging"
    | _ -> assert false)
;;

let test_retained_detail_picker_owner_and_terminal_delete () =
  let module R = Journal_routes in
  let root = block () in
  let live = load_parent (R.create ()) root 980L in
  let owner = entry_id live in
  let live =
    R.update_detail
      live
      (Journal_detail.update_child_source (Option.get (R.detail live)) "Owned draft")
  in
  let path = Filename.temp_file "journal-import-" ".txt" in
  Fun.protect
    ~finally:(fun () -> if Sys.file_exists path then Sys.remove path)
    (fun () ->
       let pick =
         staged_pick
           ~operation:"70000000-0000-4000-a000-00000000a090"
           ~path
           ~title:"Retained selection"
           ~file_type:"txt"
       in
       let detached = R.pop_to_root live in
       let updated =
         R.map_child_capture_at
           detached
           ~entry_id:owner
           ~request_generation:980L
           ~f:(fun capture -> Journal_capture.add_attachment capture pick)
       in
       require
         (List.length
            (Journal_capture.pending_attachments
               (Option.get
                  (R.child_capture_at updated ~entry_id:owner ~request_generation:980L)))
          = 1)
         "late picker lost the detached draft owner";
       require
         (R.map_child_capture_at
            updated
            ~entry_id:owner
            ~request_generation:979L
            ~f:(fun capture ->
              Journal_capture.remove_attachment
                capture
                ~token:(Journal_asset_import.staged_token pick))
          == updated)
         "stale picker generation modified a retained draft";
       let reopened = load_parent updated root 990L in
       let committed, released =
         R.commit_delete reopened ~block_id:(Journal_model.id root)
       in
       require
         (List.length released = 1 && R.pending_attachments committed = [])
         "committed root deletion retained a draft or lost cleanup ownership";
       let fresh = R.pop_to_root committed |> fun t -> load_parent t root 1000L in
       require
         (Journal_detail.child_capture (Option.get (R.detail fresh)) = None)
         "committed deletion revived its retired draft")
;;

(* Detail owns traversal and paging; all regressions exercise its public state,
   admitted reads and completions, without injecting incorrect state. *)
let test_projected_unknown_children_are_read_once () =
  let module G = Logseq_db_types.Graph_types in
  let module P = Journal_graph_projection in
  let uuid n = G.Uuid.of_string (Printf.sprintf "78000000-0000-4000-a000-%012d" n) |> Result.get_ok in
  let page : G.page =
    { uuid = uuid 100; name = "20260809"; title = "2026-08-09"
    ; kind = G.Journal_page { journal_day = 20260809 }
    ; created_at_ms = 1_786_204_800_000L; updated_at_ms = 1_786_204_800_000L
    ; recycled = false; tags = []; properties = [] } in
  let member n parent : P.block_member =
    { block =
        { uuid = uuid n; title = Printf.sprintf "Level %d" n; parent; page = page.uuid
        ; order = "a"; created_at_ms = page.created_at_ms; updated_at_ms = page.updated_at_ms
        ; refs = []; tags = []; properties = [] }
    ; revision = "fixture-1" } in
  let root = member 1 page.uuid in
  let child = member 2 (uuid 1) in
  let grandchild = member 3 (uuid 2) in
  let project root children =
    P.detail_on_page ~page ~time_context:{ localtime = Unix.gmtime } ~root
      { Journal_graph_projection.items = children; continuation = None }
    |> Result.get_ok in
  let projection = project root [ child ] in
  require (Journal_model.child_count (List.hd projection.children.blocks) = 0)
    "public projection fixture must retain unknown child count";
  let module D = Journal_detail in
  let owner = D.create ~session_number:134L projection |> observe_outline in
  let child_id = G.Uuid.to_string child.block.uuid in
  require (D.next_automatic_load owner = Some child_id)
    "projected zero child count is unknown and must admit discovery";
  let load owner (parent : P.block_member) children =
    let owner, requests = D.step owner Load_next in
    let generation = match requests with
      | [ Journal_graph_request.Load_detail { block_id; limit = 128; after = None; request_generation } ]
        when block_id = G.Uuid.to_string parent.P.block.uuid -> request_generation
      | _ -> fail "projected unknown branch must admit one bounded first page" in
    fst (D.step owner (Loaded (generation, project parent children))) in
  let owner = load owner child [ grandchild ] in
  let owner = load owner grandchild [] in
  require (D.next_automatic_load owner = None) "confirmed empty leaf was read twice";
  require
    (List.filter_map
       (function
         | D.Block { depth; _ } -> Some depth
         | _ -> None)
      (D.rows owner) = [ 0; 1; 2 ]) "real projected descendants did not auto-expand";
  require
    (not
       (List.exists
          (function
            | D.More _ -> true
            | _ -> false)
          (D.rows owner)))
    "confirmed leaves retained a spurious Load more"
;;

let test_detail_default_outline_depth_and_cycle_boundaries () =
  let module D = Journal_detail in
  let id n = generated_block_id (1300 + n) in
  let chain = List.init 12 (fun n ->
    block ~id:(id n) ~parent_id:(if n = 0 then None else Some (id (n - 1)))
      ~child_count:(if n = 11 then 0 else 1) ()) in
  let projection n : Journal_graph_projection.detail =
    { root = List.nth chain n; children =
        { blocks = [ List.nth chain (n + 1) ]; continuation = None } } in
  let owner = D.create ~session_number:131L (projection 0) |> observe_outline in
  require
    (List.exists
       (function
         | D.More { parent_id; _ } -> parent_id = id 1
      | _ -> false) (D.rows owner))
    "default expanded child must expose loading/Load more without disclosure";
  let rec load owner n =
    if n >= 9
    then owner
    else (
      let next, requests = D.step owner Load_next in
      let generation = match requests with
        | [ Journal_graph_request.Load_detail { request_generation; limit = 128; _ } ] -> request_generation
        | _ -> fail "visible descendant did not admit one bounded page" in
      let next, _ = D.step next (Loaded (generation, projection n)) in
      load next (n + 1))
  in
  let owner = load owner 1 in
  require
    (List.filter_map
       (function
         | D.Block { depth; _ } -> Some depth
         | _ -> None)
      (D.rows owner) = List.init 10 Fun.id)
    "Detail must display ten data levels including the root";
  require
    (not
       (List.exists
          (function
            | D.More { parent_id; _ } -> parent_id = id 9
      | _ -> false) (D.rows owner)))
    "depth ten must not expose a read for depth eleven";
  require (D.next_automatic_load owner = None) "automatic traversal crossed the depth limit";
  let _, requests = D.step owner (Load_more (id 9)) in
  require (requests = []) "depth limit admitted a hidden subtree read";
  let cycle = D.reconcile_children owner
      { root = List.nth chain 2; children = { blocks = [ List.nth chain 0 ]; continuation = None } } in
  require
    (List.filter_map
       (function
         | D.Block { block; _ } -> Some (Journal_model.id block)
      | _ -> None) (D.rows cycle) = [ id 0; id 1; id 2 ])
    "ancestor cycle must terminate without hiding valid ancestors";
  let leaf = block ~id:(id 20) ~parent_id:(Some (id 0)) ~child_count:0 () in
  let leaf_owner = D.create ~session_number:132L
      { root = List.hd chain; children = { blocks = [ leaf ]; continuation = None } } |> observe_outline in
  let leaf_owner, requests = D.step leaf_owner Load_next in
  let generation = match requests with
    | [ Journal_graph_request.Load_detail { request_generation; _ } ] -> request_generation
    | _ -> fail "unknown zero count must be read once" in
  let leaf_owner, _ = D.step leaf_owner (Loaded (generation,
      { root = leaf; children = { blocks = []; continuation = None } })) in
  require
    (not
       (List.exists
          (function
            | D.More { parent_id; _ } -> parent_id = id 20
      | _ -> false) (D.rows leaf_owner)))
    "confirmed empty leaf must not offer another empty-page read";
  let _, requests = D.step leaf_owner (Load_more (id 20)) in
  require (requests = []) "confirmed leaf admitted an unnecessary read"
;;

let test_detail_serial_reads_and_retry_feedback () =
  let module D = Journal_detail in
  let root = block ~child_count:2 () in
  let child n = block ~id:(generated_block_id (1400 + n))
      ~parent_id:(Some (Journal_model.id root)) () in
  let a, b = child 1, child 2 in
  let owner = D.create ~session_number:140L
      { root; children = { blocks = [ a; b ]; continuation = None } } in
  let owner, requests = D.step owner (Load_more (Journal_model.id a)) in
  let generation = match requests with
    | [ Journal_graph_request.Load_detail { request_generation; _ } ] -> request_generation
    | _ -> fail "first branch must admit its bounded read" in
  let same, requests = D.step owner (Load_more (Journal_model.id b)) in
  require (requests = []) "Detail admitted concurrent automatic branch reads";
  let failed, _ = D.step same (Load_failed (generation, false, "offline")) in
  require
    (List.exists
       (function
         | D.More { parent_id; error = Some "offline"; loading = false; _ } ->
      parent_id = Journal_model.id a | _ -> false) (D.rows failed))
    "failed read must remain visible and retryable";
  let _, requests = D.step failed (Load_more (Journal_model.id a)) in
  require (List.length requests = 1) "visible failure cannot retry"
;;

let test_detail_128_item_pages_preserve_order_and_completion () =
  let module D = Journal_detail in
  let root = block () in
  let parent = block ~id:(generated_block_id 1099)
      ~parent_id:(Some (Journal_model.id root)) ~child_count:260 () in
  let parent_id = Journal_model.id parent in
  let children = List.init 260 (fun index ->
    let ordinal = index + 1 in
    block ~id:(generated_block_id (1100 + ordinal)) ~parent_id:(Some parent_id)
      ~order:(Printf.sprintf "%06d" ordinal) ~child_count:0 ()) in
  let page start count continuation : Journal_graph_projection.detail =
    { root = parent; children =
        { blocks = List.filteri (fun i _ -> i >= start && i < start + count) children
        ; continuation } } in
  let cursor ordinal : Journal_graph_projection.block_cursor =
    { after_sibling_order = Printf.sprintf "%06d" ordinal
    ; after_block_id = Journal_model.id (List.nth children (ordinal - 1))
    ; protocol_cursor = Some (Journal_graph_projection.Child_cursor {after=Coordination_test_fixture.child_continuation (Printf.sprintf "detail-page-%d" ordinal);maximum_items=128}) } in
  let request after = function
    | [ Journal_graph_request.Load_detail
          { block_id; limit; after = actual; request_generation } ] ->
      require (block_id = parent_id && actual = after)
        "128-item paging lost parent or opaque cursor";
      require (limit = 128) "Detail page budget expected 128, got %d" limit;
      request_generation
    | _ -> fail "Detail paging must issue exactly one bounded read" in
  let initial = D.create ~session_number:128L
      { root; children = { blocks = [ parent ]; continuation = None } } in
  let first, requests = D.step initial (Load_more parent_id) in
  let generation = request None requests in
  let first, _ = D.step first (Loaded (generation, page 0 128 (Some (cursor 128)))) in
  require (List.length (D.children_of first ~parent_id) = 128)
    "initial 128-item page was truncated";
  let second, requests = D.step first (Load_more parent_id) in
  let generation = request (Some (cursor 128)) requests in
  let second, duplicate = D.step second (Load_more parent_id) in
  require (duplicate = []) "pending 128-item page admitted a duplicate read";
  let second, _ = D.step second (Loaded (generation, page 128 128 (Some (cursor 256)))) in
  require (List.length (D.children_of second ~parent_id) = 256)
    "second 128-item page lost previously loaded children";
  let last, requests = D.step second (Load_more parent_id) in
  let generation = request (Some (cursor 256)) requests in
  let completion = D.Loaded (generation, page 256 4 None) in
  let last, _ = D.step last completion in
  let replayed, _ = D.step last completion in
  require
    (List.map Journal_model.id (D.children_of replayed ~parent_id)
     = List.map Journal_model.id children)
    "128/128/4 pages duplicated, omitted or reordered children";
  require (D.continuation replayed ~parent_id = None) "final page retained a cursor";
  let _, requests = D.step replayed (Load_more parent_id) in
  require (requests = []) "completed 128-item paging kept requesting";
  require
    (List.filter_map
       (function
         | D.Block { block; _ } -> Some (Journal_model.id block)
      | D.More _ -> None) (D.rows replayed)
     = List.map Journal_model.id (root :: parent :: children))
    "flat Detail traversal lost the complete 260-child order"
;;

let test_detail_retry_uses_128_item_first_page () =
  let module R = Journal_routes in
  let root = block () in
  let routes = R.create () |> fun t ->
      R.open_detail t ~block_id:(Journal_model.id root) ~request_generation:127L in
  let routes = R.apply_detail_response routes ~request_generation:127L (detail ~root ()) in
  let _, request = R.retry_detail routes ~request_generation:128L in
  match request with
  | Some (Journal_graph_request.Load_detail { block_id; after = None; limit; request_generation = 128L }) ->
    require (block_id = Journal_model.id root && limit = 128)
      "Detail retry must restart its root with a 128-item first page"
  | _ -> fail "Detail retry lost its first-page owner"
;;

(* Capture owns admission, source preservation and attachment-only naming;
   reproduce Unicode blank input through its public reducer boundary. *)
let test_unicode_blank_capture_admission () =
  let whitespace = List.init 5 (fun i -> Uchar.of_int (i + 9))
    @ List.map Uchar.of_int [0x20;0x85;0xa0;0x1680]
    @ List.init 11 (fun i -> Uchar.of_int (i + 0x2000))
    @ List.map Uchar.of_int [0x2028;0x2029;0x202f;0x205f;0x3000] in
  let encoded chars =
    let b = Buffer.create 64 in
    List.iter (Buffer.add_utf_8_uchar b) chars; Buffer.contents b in
  let blank_sources = "" :: "　　\n　" :: encoded whitespace :: List.map (fun c -> encoded [c]) whitespace in
  let admit capture = Journal_capture.admit_save capture
    ~mutation_id:"70000000-0000-4000-9000-000000000014"
    ~block_id:"70000000-0000-4000-a000-000000000014"
    ~sibling_order:"000000000014" ~calendar_generation:7L
    ~creation_time:(creation_time 543) in
  let pick = staged_pick ~operation:"70000000-0000-4000-a000-00000000a014"
    ~path:"/tmp/blank-title.txt" ~title:"blank-title.txt" ~file_type:"txt" in
  List.iter (fun source ->
    let capture = Journal_capture.create ~session_number:14L ~source in
    require (not (Journal_capture.can_save capture)) "Unicode blank %S enabled Send" source;
    require (Option.is_none (snd (admit capture))) "Unicode blank %S admitted Save" source;
    let attached = Journal_capture.add_attachment capture pick in
    require (Journal_capture.can_save attached) "Unicode blank attachment-only disabled Save";
    match snd (admit attached) with
    | Some (Journal_graph_request.Capture {command;_}) ->
      require_string "blank-title.txt" command.source "blank attachment-only title"
    | _ -> fail "Unicode blank attachment-only did not admit Save") blank_sources;
  List.iter (fun source ->
    let capture = Journal_capture.create ~session_number:15L ~source:"" in
    let capture = Journal_capture.update_source capture ~source in
    require (Journal_capture.can_save capture) "Meaningful text %S disabled Send" source;
    match snd (admit capture) with
    | Some (Journal_graph_request.Capture {command;_}) ->
      require_string source command.source "meaningful source must remain exact"
    | _ -> fail "Meaningful text %S did not admit Save" source)
    ["　中文\n　second line　";" 🌱 ";"​";"﻿"]
;;

(* These regressions reproduce the review findings through Detail's public
   owner, including native visibility observations and admitted completions. *)
let followup_block number parent =
  block
    ~id:(Printf.sprintf "79000000-0000-4000-a000-%012d" number)
    ~parent_id:parent
    ~order:(Printf.sprintf "%06d" number)
    ~child_count:0
    ()
;;

let followup_page root children continuation : Journal_graph_projection.detail =
  { root; children = { blocks = children; continuation } }
;;

let followup_read owner event =
  let owner, requests = Journal_detail.step owner event in
  match requests with
  | [ Journal_graph_request.Load_detail
        { block_id; limit = 128; request_generation; after }
    ] -> owner, block_id, request_generation, after
  | _ -> fail "followup expected exactly one 128-item public read"
;;

let followup_visible owner first last =
  fst
    (Journal_detail.step
       owner
       (Observe_visible_range (Int64.of_int first, Int64.of_int last)))
;;

let followup_counts owner =
  let rows = Journal_detail.rows owner in
  ( List.length
      (List.filter
         (function
           | Journal_detail.Block _ -> true
           | _ -> false)
         rows)
  , List.length rows )
;;

let test_followup_branch_loading_preserves_unrelated_errors () =
  let module D = Journal_detail in
  let root = followup_block 1 None in
  let a, b, c =
    ( followup_block 2 (Some (Journal_model.id root))
    , followup_block 3 (Some (Journal_model.id root))
    , followup_block 4 (Some (Journal_model.id root)) )
  in
  let owner = D.create ~session_number:151L (followup_page root [ a; b; c ] None) in
  let owner, _, generation, _ = followup_read owner (Load_more (Journal_model.id a)) in
  let owner, _ = D.step owner (Load_failed (generation, false, "A offline")) in
  let owner, _, generation, _ = followup_read owner (Load_more (Journal_model.id b)) in
  let more id state =
    List.find
      (function
        | D.More { parent_id; _ } -> parent_id = id
        | _ -> false)
      (D.rows state)
  in
  (match more (Journal_model.id a) owner with
   | D.More { loading = false; enabled = false; error = Some "A offline"; _ } -> ()
   | _ -> fail "unrelated pending branch replaced A's error/Retry with loading");
  (match more (Journal_model.id b) owner with
   | D.More { loading = true; enabled = false; error = None; _ } -> ()
   | _ -> fail "pending B must own its loading feedback");
  (match more (Journal_model.id c) owner with
   | D.More { loading = false; enabled = false; error = None; _ } -> ()
   | _ -> fail "idle C must be waiting, not loading");
  let refused, requests = D.step owner (Load_more (Journal_model.id a)) in
  require
    (refused == owner && requests = [])
    "busy Retry reset state or admitted another read";
  let owner, _ = D.step owner (Loaded (generation, followup_page b [] None)) in
  (match more (Journal_model.id a) owner with
   | D.More { loading = false; enabled = true; error = Some "A offline"; _ } -> ()
   | _ -> fail "serialized completion did not restore A's Retry");
  ignore (followup_read owner (Load_more (Journal_model.id a)))
;;

let test_followup_materialized_rows_are_bounded () =
  let module D = Journal_detail in
  List.iteri
    (fun scenario (initial_count, pages) ->
       let root = followup_block (10000 + (scenario * 1000)) None in
       let children =
         List.init initial_count (fun n ->
           followup_block (10001 + (scenario * 1000) + n) (Some (Journal_model.id root)))
       in
       let owner =
         D.create
           ~session_number:(Int64.of_int (152 + scenario))
           (followup_page root children None)
         |> fun owner -> followup_visible owner 0 10000
       in
       let returned = ref 0
       and reads = ref 0 in
       let owner =
         List.fold_left
           (fun owner width ->
              require
                (D.next_automatic_load owner <> None)
                "bounded sparse page stopped too soon";
              let next, parent_id, generation, after = followup_read owner Load_next in
              require (after = None) "auto read consumed a continuation";
              let refused, requests = D.step next (Load_more parent_id) in
              require
                (refused == next && requests = [])
                "rejected manual read reset row budget";
              let parent = D.find_block next ~block_id:parent_id |> Option.get in
              incr reads;
              let blocks =
                List.init width (fun n ->
                  followup_block
                    (20000 + (scenario * 1000) + (!reads * 128) + n)
                    (Some parent_id))
              in
              returned := !returned + width;
              fst (D.step next (Loaded (generation, followup_page parent blocks None))))
           owner
           pages
       in
       let block_count, total_rows = followup_counts owner in
       require
         (block_count <= 384 && total_rows <= 768)
         "auto expansion exceeds materialized/flat row bound: blocks=%d rows=%d"
         block_count
         total_rows;
       require
         (D.next_automatic_load owner = None)
         "auto read has no full 128-row reservation";
       let same, requests = D.step owner Load_next in
       require (same == owner && requests = []) "exhausted auto round kept reading";
       require
         (List.exists
            (function
              | D.More { loading = false; enabled = true; _ } -> true
              | _ -> false)
            (D.rows owner))
         "row budget exhaustion removed explicit Load more";
       Printf.printf
         "FOLLOWUP_METRIC bounded-%d initial=%d reads=%d limit=128 returned=%d blocks=%d \
          rows=%d\n\
          %!"
         scenario
         (initial_count + 1)
         !reads
         !returned
         block_count
         total_rows;
       let parent_id =
         List.find_map
           (function
             | D.More { parent_id; _ } -> Some parent_id
             | _ -> None)
           (D.rows owner)
         |> Option.get
       in
       let next, _, generation, _ = followup_read owner (Load_more parent_id) in
       let parent = D.find_block next ~block_id:parent_id |> Option.get in
       let blocks =
         List.init 128 (fun n ->
           followup_block (40000 + (scenario * 1000) + n) (Some parent_id))
       in
       let next, _ =
         D.step next (Loaded (generation, followup_page parent blocks None))
       in
       require
         (D.next_automatic_load next <> None)
         "successful explicit read did not reopen a bounded round")
    [ 128, [ 128 ]; 127, [ 128; 127 ]; 1, [ 127; 1; 128 ] ]
;;

let test_followup_visible_discovery_and_presentation_reuse () =
  let module D = Journal_detail in
  let root = followup_block 50000 None in
  let children =
    List.init 128 (fun n -> followup_block (50001 + n) (Some (Journal_model.id root)))
  in
  let owner = D.create ~session_number:156L (followup_page root children None) in
  require
    (D.next_automatic_load owner = None)
    "Detail read offscreen before its first native range";
  let initial_rows = D.rows owner in
  require
    (D.rows owner == initial_rows)
    "unchanged outline repeatedly rebuilt row snapshots";
  let owner = followup_visible owner 2 3 in
  require
    (D.rows owner == initial_rows
     && D.equal_presentation owner (followup_visible owner 2 3))
    "range-only changes rebuilt presentation";
  let owner, target, generation, _ = followup_read owner Load_next in
  require
    (target = Journal_model.id (List.hd children))
    "visible More did not discover its off-window parent";
  let owner, _ =
    D.step owner (Loaded (generation, followup_page (List.hd children) [] None))
  in
  require
    (D.next_automatic_load owner = Some (Journal_model.id (List.nth children 1)))
    "completion did not remap the saved indexes when More disappeared";
  let owner, _, generation, _ = followup_read owner Load_next in
  let owner, _ =
    D.step owner (Loaded (generation, followup_page (List.nth children 1) [] None))
  in
  require
    (D.next_automatic_load owner = None)
    "visible empty-leaf discovery cascaded to offscreen siblings";
  let rows = D.rows owner in
  for _ = 1 to 25 do
    let same = followup_visible owner 2 3 in
    require
      (same == owner && D.rows same == rows)
      "repeated native range rebuilt state/rows";
    let same, requests = D.step same Load_next in
    require
      (same == owner && requests = [] && D.rows same == rows)
      "repeated pump performed work"
  done;
  let draft = D.update_child_source owner "Unrelated draft edit" in
  require (D.rows draft == rows) "composer edit rebuilt unchanged outline rows";
  let stale, _ = D.step draft (Loaded (0L, followup_page root [] None)) in
  require (stale == draft && D.rows stale == rows) "stale completion rebuilt rows";
  let offscreen = followup_visible owner 5000 6000 in
  require
    (D.next_automatic_load offscreen = None && D.rows offscreen == rows)
    "out-of-range viewport caused hidden reads";
  let blocks, flat = followup_counts owner in
  Printf.printf
    "FOLLOWUP_METRIC wide-empty initial=129 reads=2 limit=128 returned=0 blocks=%d \
     rows=%d repeat_range=25 duplicate_reads=0\n\
     %!"
    blocks
    flat
;;

let test_followup_snapshot_invalidation_and_owner_isolation () =
  let module D = Journal_detail in
  let root = followup_block 60000 None in
  let child = followup_block 60001 (Some (Journal_model.id root)) in
  let owner = D.create ~session_number:157L (followup_page root [ child ] None) in
  let rows = D.rows owner in
  require (D.rows owner == rows) "same owner rebuilt rows";
  let other = D.create ~session_number:158L (followup_page root [ child ] None) in
  require (D.rows other != rows) "row snapshot crossed Detail sessions";
  let changed =
    block
      ~id:(Journal_model.id child)
      ~parent_id:(Some (Journal_model.id root))
      ~source:"Updated task/media source"
      ~revision:"changed"
      ~task_state:(Journal_model.Status "00000002-1827-5820-8200-000000000000")
      ~child_count:0
      ()
    |> fun block -> Journal_model.with_tag_titles block ~tag_titles:[ "QA updated" ]
  in
  let old_owner = owner in
  let owner = D.apply_block owner changed in
  require
    (D.rows owner != rows
     && List.exists
          (function
            | D.Block { block; _ } ->
              Journal_model.source block = "Updated task/media source"
              && Journal_model.task_state block
                 = Journal_model.Status "00000002-1827-5820-8200-000000000000"
              && Journal_model.tag_titles block = [ "QA updated" ]
            | _ -> false)
          (D.rows owner))
    "block attributes did not invalidate rows";
  require (D.rows old_owner == rows) "derived outline overwrote retained snapshot cache";
  let rows = D.rows owner in
  let owner = D.remove_block owner ~block_id:(Journal_model.id child) |> Option.get in
  require
    (D.rows owner != rows && fst (followup_counts owner) = 1)
    "delete retained stale rows";
  let owner = D.reconcile_children owner (followup_page root [] None) in
  require (fst (followup_counts owner) = 1) "authoritative refresh retained removed rows";
  let owner = D.update_child_source owner "Appended QA block" in
  let owner, request =
    D.admit_child
      owner
      ~mutation_id:"79000000-0000-4000-9000-000000060001"
      ~calendar_generation:1L
      ~block_id:(Journal_model.id child)
      ~sibling_order:"999"
      ~creation_time:(creation_time 600)
  in
  require (request <> None) "append admission missing";
  let rows = D.rows owner in
  let owner = D.apply_child_created owner ~child ~parent:root in
  require
    (D.rows owner != rows && fst (followup_counts owner) = 2)
    "append retained stale rows";
  let owner = followup_visible owner 0 10 in
  let owner, id, generation, _ = followup_read owner Load_next in
  require (id = Journal_model.id child) "new append not discoverable";
  let owner, _ = D.step owner (Loaded (generation, followup_page child [] None)) in
  require (D.next_automatic_load owner = None) "append leaf read repeated";
  Printf.printf
    "FOLLOWUP_METRIC root-only reads=0 rows=1 append reads=1 returned=0 rows=%d\n%!"
    (snd (followup_counts owner))
;;

let test_followup_review_regressions () =
  let failures = ref [] in
  List.iter
    (fun (name, run) ->
       try run () with
       | error ->
         Printf.eprintf "FOLLOWUP_RED %s: %s\n%!" name (Printexc.to_string error);
         failures := name :: !failures)
    [ "branch-specific loading", test_followup_branch_loading_preserves_unrelated_errors
    ; "materialized row cap", test_followup_materialized_rows_are_bounded
    ; ( "visible discovery and snapshot reuse"
      , test_followup_visible_discovery_and_presentation_reuse )
    ; ( "snapshot invalidation and isolation"
      , test_followup_snapshot_invalidation_and_owner_isolation )
    ];
  require
    (!failures = [])
    "Review regressions failed: %s"
    (String.concat ", " (List.rev !failures))
;;


(* Initial Detail publication owns the complete bounded page, while the delayed
   indicator belongs to its route/request identity rather than asset work. *)
let test_detail_initial_loading_delay_and_ownership () =
  let module R = Journal_routes in
  let cases =
    [ ( "fast completion"
      , fun () ->
      let t = R.open_detail (R.create ()) ~block_id:(Journal_model.id (block ())) ~request_generation:9000L in
      require (not (R.loading_indicator t)) "initial Detail shows loading before 100ms";
      let t = R.observe_loading_delay t ~entry_id:(entry_id t) ~request_generation:9000L ~elapsed:0.099 in
      require (not (R.loading_indicator t)) "99ms exposes the indicator";
      let root = block () in
      let child = block ~id:"70000000-0000-4000-a000-000000000099" ~parent_id:(Some (Journal_model.id root)) () in
      let staged = R.apply_detail_response t ~request_generation:9000L { root; children={blocks=[child];continuation=None} } in
      let pending, requests = R.load_initial staged in
      let generation = match requests with
        | [Journal_graph_request.Load_detail {request_generation;_}] -> request_generation
        | _ -> fail "fast initial child discovery was not admitted" in
      let ready = R.apply_detail_response pending ~request_generation:generation (detail ~root:child ()) in
      require (R.route ready = Detail && not (R.loading_indicator ready)) "fast body is artificially delayed";
          require
            (List.length
               (List.filter
                  (function
                    | Journal_detail.Block _ -> true
                    | More _ -> false)
                  (Journal_detail.rows (Option.get (R.detail ready))))
             = 2)
            "root published without its bounded children page";
          require
            (R.observe_loading_delay
               ready
               ~entry_id:(entry_id ready)
               ~request_generation:9000L
               ~elapsed:1.
             == ready)
            "late timer changes ready body" )
    ; ( "slow delay boundary"
      , fun () ->
      let t = R.open_detail (R.create ()) ~block_id:(Journal_model.id (block ())) ~request_generation:9001L in
      let id = entry_id t in
      require (not (R.loading_indicator t)) "slow route starts with a spinner";
      require (R.observe_loading_delay t ~entry_id:id ~request_generation:9001L ~elapsed:(-1.) == t) "negative elapsed time changes owner";
      require (R.observe_loading_delay t ~entry_id:id ~request_generation:9001L ~elapsed:nan == t) "NaN elapsed time changes owner";
      require (R.observe_loading_delay t ~entry_id:id ~request_generation:9001L ~elapsed:0.099 == t) "early callback changes owner";
      require (R.observe_loading_delay t ~entry_id:id ~request_generation:9001L ~elapsed:0.099999999 == t) "one nanosecond before 100ms shows loading";
      let slow = R.observe_loading_delay t ~entry_id:id ~request_generation:9001L ~elapsed:0.1 in
      require (R.loading_indicator slow) "100ms pending route has no indicator";
      require (R.loading_indicator (R.observe_loading_delay t ~entry_id:id ~request_generation:9001L ~elapsed:3600.)) "suspended pending route loses its elapsed loading delay";
      require (R.detail slow = None) "pending route exposes a partial root";
          require
            (R.observe_loading_delay
               slow
               ~entry_id:id
               ~request_generation:9001L
               ~elapsed:0.2
             == slow)
            "duplicate delay republishes owner" )
    ; ( "failure and retry"
      , fun () ->
      let t = R.open_detail (R.create ()) ~block_id:(Journal_model.id (block ())) ~request_generation:9002L in
      let id = entry_id t in
      let failed = R.apply_detail_failure t ~request_generation:9002L ~missing:false ~message:"read failed" in
      require (not (R.loading_indicator failed)) "failure retains spinner";
      require (R.observe_loading_delay failed ~entry_id:id ~request_generation:9002L ~elapsed:1. == failed) "late timer overwrites failure";
      let retry, request = R.retry_detail failed ~request_generation:9003L in
      require (Option.is_some request && not (R.loading_indicator retry)) "retry skips its fresh grace period";
      require (R.observe_loading_delay retry ~entry_id:id ~request_generation:9002L ~elapsed:1. == retry) "old timer activates retry";
      require (R.apply_detail_response retry ~request_generation:9002L (detail ()) == retry) "old completion activates retry";
      let missing = R.apply_missing_detail retry ~request_generation:9003L in
          require
            (R.route missing = Missing_detail && not (R.loading_indicator missing))
            "missing route retains progress" )
    ; ( "back and new route"
      , fun () ->
      let t = R.open_detail (R.create ()) ~block_id:(Journal_model.id (block ())) ~request_generation:9004L in
      let old = entry_id t in
      let back = R.back t in
      require (R.observe_loading_delay back ~entry_id:old ~request_generation:9004L ~elapsed:1. == back) "cancelled timer recreates route";
      require (R.apply_detail_response back ~request_generation:9004L (detail ()) == back) "cancelled completion recreates route";
      let fresh = R.open_detail back ~block_id:(Journal_model.id (block ())) ~request_generation:9005L in
      require (entry_id fresh <> old && not (R.loading_indicator fresh)) "reentry inherits progress";
      require (R.observe_loading_delay fresh ~entry_id:old ~request_generation:9004L ~elapsed:1. == fresh) "retired timer affects reentry";
      let reset = R.graph_unavailable fresh in
          require
            (R.observe_loading_delay
               reset
               ~entry_id:(entry_id fresh)
               ~request_generation:9005L
               ~elapsed:1.
             == reset)
            "graph reset accepts timer" )
    ; ( "rapid nested routes"
      , fun () ->
      let a = block () and b = block ~id:"70000000-0000-4000-a000-000000000002" () in
      let t = R.open_detail (R.create ()) ~block_id:(Journal_model.id a) ~request_generation:9006L in
      let a_id = entry_id t in
      let t = R.open_detail t ~block_id:(Journal_model.id b) ~request_generation:9007L in
      let b_id = entry_id t in
      let t = R.observe_loading_delay t ~entry_id:a_id ~request_generation:9006L ~elapsed:0.2 in
          require
            ((not (R.loading_indicator t)) && R.loading_indicator (entry t a_id))
            "covered timer leaks into top route";
      require (R.observe_loading_delay t ~entry_id:b_id ~request_generation:9006L ~elapsed:0.2 == t) "timer accepts wrong generation";
      let t = R.apply_detail_response t ~request_generation:9006L (detail ~root:a ()) in
      require (R.route t = Detail_loading && not (R.loading_indicator t)) "covered completion reveals top body";
      let t = R.apply_detail_response t ~request_generation:9007L (detail ~root:b ()) in
          require (R.route t = Detail) "current completion does not reveal body" )
  ] in
  let failures = ref [] in
  List.iter
    (fun (name, test) ->
       try test () with
       | exn ->
    Printf.eprintf "DETAIL_LOADING_RED %s: %s\n%!" name (Printexc.to_string exn);
    failures := name :: !failures) cases;
  require (!failures = []) "Detail loading cases failed: %s" (String.concat ", " !failures)
;;


(* The route owns unpublished initial text. Only public queries, admitted
   requests and matching completions are used to verify publication. *)
let test_detail_initial_nested_body_staging () =
  let module R = Journal_routes in
  let module D = Journal_detail in
  let id n = Printf.sprintf "70000000-0000-4000-a000-%012d" (6000+n) in
  let node ?parent ?(order="a") ?(source="Initial text") n =
    block ~id:(id n) ~parent_id:parent ~order ~source ~child_count:0 ()
  in
  let projection ?continuation root blocks : Journal_graph_projection.detail =
    {root;children={blocks;continuation}}
  in
  let start ?(generation=9500L) projection =
    R.open_detail (R.create ()) ~block_id:(Journal_model.id projection.Journal_graph_projection.root) ~request_generation:generation
    |> fun t -> R.apply_detail_response t ~request_generation:generation projection
  in
  let text_ids t =
    D.rows (Option.get (R.detail t))
    |> List.filter_map (function
      | D.Block { block; _ } -> Some (Journal_model.id block)
      | More _ -> None)
  in
  let admit t =
    let _, parent = Option.get (R.initial_load t) in
    let pending, commands = R.load_initial t in
    match commands with
    | [Journal_graph_request.Load_detail {block_id;after=None;limit=128;request_generation}] ->
      require_string parent block_id "initial read parent";
      require (R.route pending = Detail_loading && R.detail pending = None) "admitted read exposes partial text";
      require (R.initial_load pending = None && R.load_initial pending = (pending, [])) "initial read is duplicated while pending";
      pending, parent, request_generation
    | _ -> fail "initial staging must admit one bounded first page"
  in
  let finish t projections =
    let rec drain t calls =
      match R.initial_load t with
      | None -> require (R.route t = Detail) "initial text never publishes"; t, List.rev calls
      | Some _ ->
        require (R.detail t = None) "initial partial text is visible";
        let pending, parent, generation = admit t in
        let value = List.find (fun p -> Journal_model.id p.Journal_graph_projection.root = parent) projections in
        let next = R.apply_detail_response pending ~request_generation:generation value in
        require (R.apply_detail_response next ~request_generation:generation value == next) "duplicate completion changes initial owner";
        drain next (parent::calls)
    in
    drain t []
  in
  let root=node 0 and child=node ~parent:(id 0) 1 and tail=node ~parent:(id 0) ~order:"z" 2 in
  let grandchild=node ~parent:(id 1) 3 and extra=node ~parent:(id 1) ~order:"b" 4 in
  let small=projection root [child;tail] in
  let small_pages=[projection child [grandchild;extra];projection grandchild [];projection extra [];projection tail []] in
  let cases =
    [ ( "three levels publish all text once"
      , fun () ->
      let t=start small in
      require (R.route t = Detail_loading && R.detail t = None) "first direct page publishes ahead of deeper text";
      let ready,calls=finish t small_pages in
      require (text_ids ready = List.map id [0;1;3;4;2]) "three-level first body is incomplete or unordered";
      require (List.length calls=4) "small tree has unexpected discovery reads";
      let visible=observe_outline (Option.get (R.detail ready)) in
          require
            (D.next_automatic_load visible = None)
            "small body inserts more text after publication" )
    ; ( "ten levels and following sibling publish together"
      , fun () ->
      let chain=List.init 11 (fun depth -> node ?parent:(if depth=0 then None else Some (id (depth-1))) depth) in
      let tail=node ~parent:(id 0) ~order:"z" 20 in
      let pages=List.init 8 (fun i -> projection (List.nth chain (i+1)) [List.nth chain (i+2)]) @ [projection tail []] in
      let t=start (projection (List.hd chain) [List.nth chain 1;tail]) in
      require (R.detail t=None) "ten-level direct page is published early";
      let ready,calls=finish t pages in
      require (text_ids ready = List.init 10 id @ [id 20]) "ten-level first body is incomplete";
      require (List.length calls=9 && not (List.mem (id 9) calls)) "staging exceeds ten levels or repeats a branch";
          require
            (D.next_automatic_load (observe_outline (Option.get (R.detail ready))) = None)
            "ten-level body continues inserting after publication" )
    ; ( "wide tree stops at material budget and retains continuation"
      , fun () ->
      let branches=List.init 128 (fun i -> node ~parent:(id 0) ~order:(Printf.sprintf "%04d" i) (100+i)) in
      let children=List.init 128 (fun i -> node ~parent:(id 100) ~order:(Printf.sprintf "%04d" i) (300+i)) in
      let t=start (projection root branches) in
      require (R.detail t=None) "wide direct page publishes before bounded staging";
      let ready,calls=finish t [projection (List.hd branches) children] in
      require (calls=[id 100] && List.length (text_ids ready)=257) "wide staging exceeds conservative 384-block reservation";
      let outline=observe_outline (Option.get (R.detail ready)) in
      require (D.next_automatic_load outline=None) "publication resets material budget";
      let _,commands=D.step outline (Load_more (id 101)) in
          require (List.length commands = 1) "budget stop loses explicit continuation" )
    ; ( "128 attempts bound unknown zero-count discovery"
      , fun () ->
      let branches=List.init 128 (fun i -> node ~parent:(id 0) ~order:(Printf.sprintf "%04d" i) (100+i)) in
      let leaf=node ~parent:(id 100) 500 in
      let pages=projection (List.hd branches) [leaf] :: projection leaf [] :: List.map (fun b -> projection b []) (List.tl branches) in
      let t=start (projection root branches) in
      require (R.detail t=None) "zero count is assumed to be a leaf before its own read";
      let ready,calls=finish t pages in
      require (List.length calls=128 && List.length (List.sort_uniq String.compare calls)=128) "unknown branches exceed attempt budget or repeat";
      require (List.length (text_ids ready)=130) "bounded attempt result loses discovered text";
      let outline=observe_outline (Option.get (R.detail ready)) in
      require (D.next_automatic_load outline=None) "attempt cap resets at publication";
          require
            (List.exists
               (function
                 | D.More { enabled = true; _ } -> true
                 | _ -> false)
               (D.rows outline))
            "attempt cap loses explicit continue action" )
    ; ( "initial descendant failure and explicit fresh Retry"
      , fun () ->
      let t=start small in
      require (R.detail t=None) "partial body visible before failure";
      let pending,parent,generation=admit t in
      let failed=R.apply_detail_failure ~block_id:parent pending ~request_generation:generation ~missing:true ~message:"descendant unavailable" in
      require (R.route failed=Failed_detail "descendant unavailable" && R.detail failed=None && not (R.loading_indicator failed)) "descendant failure exposes partial body or wrong missing-root state";
      let retry,request=R.retry_detail failed ~request_generation:9600L in
      require (Option.is_some request && not (R.loading_indicator retry)) "explicit Retry has no fresh initial grace period";
      require (R.apply_detail_response retry ~request_generation:generation (projection child [grandchild]) == retry) "late staging completion contaminates Retry";
      let ready,_=finish (R.apply_detail_response retry ~request_generation:9600L small) small_pages in
      require (List.length (text_ids ready)=5) "Retry never publishes complete small tree";
      let prior = start (projection root []) in
      let edited = D.update_child_source (Option.get (R.detail prior)) "Retained initial draft" in
      let detached = R.back (R.update_detail prior edited) in
      let reopened = R.open_detail detached ~block_id:(id 0) ~request_generation:9650L
        |> fun t -> R.apply_detail_response t ~request_generation:9650L small in
      let pending,parent,generation = admit reopened in
      let failed = R.apply_detail_failure ~block_id:parent pending
        ~request_generation:generation ~missing:false ~message:"initial branch failed" in
      let retry,_ = R.retry_detail failed ~request_generation:9651L in
      let restored,_ = finish (R.apply_detail_response retry ~request_generation:9651L small) small_pages in
      require_string "Retained initial draft"
        (Option.fold ~none:"" ~some:Journal_capture.source
           (D.child_capture (Option.get (R.detail restored))))
            "initial staged failure retains the exact detached composer" )
    ; ( "Back graph replacement and covered route fence staged reads"
      , fun () ->
      let t=start (projection root [child]) in
      require (R.detail t=None) "staging owner prematurely visible";
      let pending,_,generation=admit t in
      let response=projection child [] in
      let back=R.back pending in
      require (R.apply_detail_response back ~request_generation:generation response==back) "Back accepts retired staging completion";
      let reset=R.graph_unavailable pending in
      require (R.apply_detail_response reset ~request_generation:generation response==reset) "graph replacement accepts old staging completion";
      let b=node 90 in
      let nested=R.open_detail pending ~block_id:(id 90) ~request_generation:9700L
        |> fun t -> R.apply_detail_response t ~request_generation:9700L (projection b []) in
      let ready=R.apply_detail_response nested ~request_generation:generation response in
      require (text_ids ready=[id 90]) "covered completion replaces current target";
      require (text_ids (R.back ready)=[id 0;id 1]) "covered completed owner loses staged text";
      let replaced=R.runtime_replaced pending in
          require
            (R.apply_detail_response replaced ~request_generation:generation response
             == replaced)
            "runtime replacement accepts old staged read" )
    ; ( "asset-bearing text never waits for asset availability"
      , fun () ->
      let asset=node ~parent:(id 0) ~source:"![local attachment](../assets/image.png)" 70 in
      let t=start (projection root [asset]) in
      require (R.detail t=None) "asset-bearing direct text publishes before initial staging";
      let ready,calls=finish t [projection asset []] in
          require
            (calls = [ id 70 ] && text_ids ready = [ id 0; id 70 ])
            "asset state gates non-asset body completion" )
    ; ( "first-page continuation remains an explicit action"
      , fun () ->
      let cursor : Journal_graph_projection.block_cursor = {after_sibling_order="a";after_block_id=id 1;protocol_cursor=None} in
      let t=start (projection ~continuation:cursor root [child]) in
      require (R.detail t=None) "continuation direct page publishes early";
      let ready,calls=finish t [projection child []] in
      require (calls=[id 1]) "initial staging automatically follows a continuation";
      let outline=Option.get (R.detail ready) in
      require (D.continuation outline ~parent_id:(id 0)=Some cursor) "staging discards pagination cursor";
      let _,commands=D.step outline (Load_more (id 0)) in
          require
            (match commands with
             | [ Journal_graph_request.Load_detail { after = Some value; limit = 128; _ }
               ] -> value = cursor
             | _ -> false)
            "explicit continuation cannot load next page" )
    ; ( "100ms belongs to the whole initial body without a minimum delay"
      , fun () ->
      let t=start (projection root [child]) in
      require (R.route t=Detail_loading && not (R.loading_indicator t)) "root response ends the grace period with partial body";
      let identity=entry_id t in
      let early=R.observe_loading_delay t ~entry_id:identity ~request_generation:9500L ~elapsed:0.099 in
      require (early==t) "root response restarts or changes grace period";
      let slow=R.observe_loading_delay t ~entry_id:identity ~request_generation:9500L ~elapsed:0.1 in
      require (R.loading_indicator slow) "staging at 100ms lacks initial indicator";
      let ready,_=finish slow [projection child []] in
      require (not (R.loading_indicator ready)) "completed body retains indicator";
      let fast,_=finish t [projection child []] in
      require (R.route fast=Detail && not (R.loading_indicator fast)) "completed small tree has a minimum artificial delay")
  ] in
  let failures=ref [] in
  List.iter
    (fun (name, test) ->
       try test () with
       | error ->
         Printf.eprintf "INITIAL_STAGING_RED %s: %s\n%!" name (Printexc.to_string error);
         failures := name :: !failures)
    cases;
  require
    (!failures = [])
    "Initial staging regressions: %s"
    (String.concat ", " (List.rev !failures))
;;

let test_initial_staging_refresh_and_delete () =
  let module R = Journal_routes in
  let module D = Journal_detail in
  let id n = Printf.sprintf "98000000-0000-4000-8000-%012d" n in
  let node ?parent n =
    block ~id:(id n) ~parent_id:parent ~order:(Printf.sprintf "%08d" n) ~child_count:0 ()
  in
  let page root blocks : Journal_graph_projection.detail =
    { root; children = { blocks; continuation = None } }
  in
  let root = node 0
  and child = node ~parent:(id 0) 1 in
  let start ?(routes = R.create ()) ?(generation = 500L) children =
    R.open_detail routes ~block_id:(id 0) ~request_generation:generation
    |> fun t ->
    R.apply_detail_response t ~request_generation:generation (page root children)
  in
  let admit t =
    match R.load_initial t with
    | ( pending
      , [ Journal_graph_request.Load_detail
            { block_id; request_generation; limit = 128; after = None }
        ] ) -> pending, block_id, request_generation
    | _ -> fail "expected public initial admission"
  in
  let refresh t root blocks =
    R.map_details t ~f:(fun d -> D.reconcile_children d (page root blocks))
  in
  let ids t =
    D.rows (Option.get (R.detail t))
    |> List.filter_map (function
      | D.Block { block; _ } -> Some (Journal_model.id block)
      | More _ -> None)
  in
  let children count parent first = List.init count (fun i -> node ~parent (first + i)) in
  let finish t =
    let rec drain t =
      match R.initial_load t with
      | None ->
        require (R.route t = Detail) "staged body never published";
        t
      | Some (_, parent) ->
        let pending, _, generation = admit t in
        let parent_node = node ~parent:(id 0) (int_of_string (String.sub parent 24 12)) in
        drain
          (R.apply_detail_response
             pending
             ~request_generation:generation
             (page parent_node []))
    in
    drain t
  in
  let cases =
    [ ( "refresh counts root and blocks before another complete page"
      , fun () ->
          let branches = children 128 (id 0) 100 in
          let descendants = children 128 (id 100) 300 in
          let pending, parent, generation = admit (start branches) in
          require_string (id 100) parent "first branch";
          let ready = refresh pending (List.hd branches) descendants in
          require
            (R.route ready = Detail && List.length (ids ready) = 257)
            "refresh bypasses root-inclusive 384-block reservation";
          require
            (R.initial_load ready = None && snd (R.load_initial ready) = [])
            "refresh allows 385th initial block";
          require
            (R.apply_detail_response
               ready
               ~request_generation:generation
               (page (List.hd branches) descendants)
             == ready)
            "late refreshed read is accepted";
          require
            (D.next_automatic_load (observe_outline (Option.get (R.detail ready))) = None)
            "publication resets refresh budget";
          require
            (List.length (snd (D.step (Option.get (R.detail ready)) (Load_more (id 300))))
             = 1)
            "budget stop loses explicit continuation" )
    ; ( "unrelated refresh cannot consume a pending page reservation"
      , fun () ->
          let branches = children 128 (id 0) 100 in
          let pending, _, generation = admit (start branches) in
          let refreshed =
            refresh pending (List.nth branches 1) (children 128 (id 101) 600)
          in
          let late =
            R.apply_detail_response
              refreshed
              ~request_generation:generation
              (page (List.hd branches) (children 128 (id 100) 300))
          in
          require
            (late == refreshed && R.route late = Detail && List.length (ids late) = 257)
            "unrelated refresh leaves an admitted page able to publish %d blocks"
            (List.length (ids late));
          require
            (List.length (snd (D.step (Option.get (R.detail late)) (Load_more (id 100))))
             = 1)
            "cancelled page loses explicit continuation" )
    ; ( "multiple refreshes accumulate without duplicate charge or attempt reset"
      , fun () ->
          let first = children 32 (id 0) 100 in
          let current = ref (start first)
          and expected = ref (List.hd first) in
          for depth = 1 to 7 do
            let pending, parent, generation = admit !current in
            require_string (Journal_model.id !expected) parent "cumulative first branch";
            let values = children 32 parent (1000 * depth) in
            let next = refresh pending !expected values in
            let duplicate = refresh next !expected values in
            require
              (R.apply_detail_response
                 duplicate
                 ~request_generation:generation
                 (page !expected values)
               == duplicate)
              "refresh late completion changed owner";
            current := duplicate;
            expected := List.hd values;
            if depth < 7
            then
              require
                (R.route !current = Detail_loading)
                "duplicate refresh is charged as another materialization"
          done;
          require
            (R.route !current = Detail
             && List.length (ids !current) = 257
             && R.initial_load !current = None)
            "multi-refresh initial budget permits 385/1153 blocks" )
    ; ( "empty refreshes preserve consumed automatic attempts"
      , fun () ->
          let first = children 128 (id 0) 100 in
          let current = ref (start first) in
          for i = 0 to 127 do
            let pending, parent, _ = admit !current in
            require_string (id (100 + i)) parent "empty refresh attempt";
            current := refresh pending (List.nth first i) []
          done;
          require
            (R.route !current = Detail
             && R.initial_load !current = None
             && List.length (ids !current) = 129)
            "refresh resets attempts or charges unchanged root" )
    ; ( "root deletion fences pending completion"
      , fun () ->
          let pending, _, old = admit (start [ child ]) in
          let missing, _ = R.commit_delete pending ~block_id:(id 0) in
          require
            (R.route missing = Missing_detail && not (R.loading_indicator missing))
            "committed root deletion is ignored";
          require
            (R.apply_detail_response missing ~request_generation:old (page child [])
             == missing)
            "deleted root is republished by late completion" )
    ; ( "sibling deletion preserves an unaffected pending initial read"
      , fun () ->
          let tail = node ~parent:(id 0) 2 in
          let pending, _, generation = admit (start [ child; tail ]) in
          let hidden, _ = R.commit_delete pending ~block_id:(id 2) in
          require
            (R.initial_load hidden = None && R.detail hidden = None)
            "sibling deletion cancels and repeats an unrelated read";
          let ready =
            R.apply_detail_response hidden ~request_generation:generation (page child [])
          in
          require
            (ids ready = [ id 0; id 1 ])
            "unaffected completion cannot publish the surviving body" )
    ; ( "descendant deletion removes subtree and fences its old read"
      , fun () ->
          let tail = node ~parent:(id 0) 2
          and grandchild = node ~parent:(id 1) 3 in
          let pending, _, generation = admit (start [ child; tail ]) in
          let staged =
            R.apply_detail_response
              pending
              ~request_generation:generation
              (page child [ grandchild ])
          in
          let pending, parent, old = admit staged in
          require_string (id 3) parent "grandchild read";
          let hidden, _ = R.commit_delete pending ~block_id:(id 1) in
          require
            (Option.map snd (R.initial_load hidden) = Some (id 2))
            "deletion leaves subtree read pending";
          require
            (R.apply_detail_response hidden ~request_generation:old (page grandchild [])
             == hidden)
            "removed subtree is revived";
          let ready = finish hidden in
          require (ids ready = [ id 0; id 2 ]) "deleted subtree remains in published text"
      )
    ]
  in
  let failures = ref [] in
  List.iter
    (fun (name, test) ->
       try test () with
       | error ->
         Printf.eprintf "STAGING_REVIEW_RED %s: %s\n%!" name (Printexc.to_string error);
         failures := name :: !failures)
    cases;
  require
    (!failures = [])
    "Staging review regressions: %s"
    (String.concat ", " (List.rev !failures))
;;

let test_page_detail_append_matches_exact_page () =
  let page_id = "75000000-0000-4000-8000-000000000002" in
  let make id page_id source =
    Journal_model.create_on_page ~id ~page_id ~journal_day:None ~parent_id:None
      ~sibling_order:"a" ~source ~task_state:No_status ~child_count:0
      ~creation_time:(creation_time 540) ~revision:"page-1"
      ~last_mutation_id:"00000000-0000-0000-0000-000000000000" |> Result.get_ok in
  let root = make page_id page_id "Empty page" in
  let child_id = "75000000-0000-4000-8000-000000000004" in
  let owner = Journal_detail.create ~session_number:80L (detail ~root ())
    |> fun t -> Journal_detail.update_child_source t "New page child" in
  let saving, request = Journal_detail.admit_child owner ~mutation_id:"mutation"
    ~calendar_generation:1L ~block_id:child_id ~sibling_order:"z"
    ~creation_time:(creation_time 550) in
  require (Option.is_some request) "page cannot admit child";
  let child = make child_id page_id "New page child" in
  let wrong = make child_id "75000000-0000-4000-8000-000000000099" "Wrong page" in
  require (Journal_detail.apply_child_created saving ~child:wrong ~parent:root == saving)
    "append completion accepted another page";
  let completed = Journal_detail.apply_child_created saving ~child ~parent:root in
  require (Journal_detail.mode completed = Reading && Journal_detail.child_capture completed = None)
    "page append did not complete its exact owner";
  require (List.map Journal_model.id (Journal_detail.children completed) = [child_id])
    "page append went to another root";
  let drafted = Journal_detail.update_child_source completed "Surviving page draft" in
  let deleted = Journal_detail.remove_block drafted ~block_id:child_id |> Option.get in
  require (Journal_model.id (Journal_detail.root deleted) = page_id
           && Journal_detail.children deleted = [])
    "deleting an outline child removed its enclosing page detail";
  require (Journal_capture.source (Option.get (Journal_detail.child_capture deleted))
           = "Surviving page draft")
    "child deletion retired the enclosing page composer";
  let routes = load_parent (Journal_routes.create ()) root 8080L
    |> fun routes -> Journal_routes.update_detail routes drafted in
  let deleted, released = Journal_routes.commit_delete routes ~block_id:child_id in
  require (Journal_routes.route deleted = Detail && released = []
           && Journal_detail.children (Option.get (Journal_routes.detail deleted)) = [])
    "route deletion confused a page owner with the deleted outline child"
;;

let test_root_cleanup_plan_contract () =
  let module R = Application.Root_navigation in
  let failures = ref [] in
  let check name f =
    try f () with error ->
      Printf.eprintf "CLEANUP_PLAN_RED %s: %s\n%!" name (Printexc.to_string error);
      failures := name :: !failures
  in
  let pick index source =
    multiselect_staged index (Printf.sprintf "/pure-fixture/cleanup-%02d.png" index) source
  in
  let a = pick 0 "files:a" in
  let b = pick 1 "files:b" in
  let c = pick 2 "files:c" in
  let paths items = List.map Journal_asset_import.staged_path items in
  let expect expected plan =
    require (cleanup_paths plan = paths expected) "expected cleanup [%s], got [%s]"
      (String.concat ";" (paths expected)) (String.concat ";" (cleanup_paths plan))
  in
  let step state event =
    let next, plan = R.step state event in
    expect [] plan;
    next
  in
  let fresh () = R.create ~graph_generation:1 |> fun s -> step s Capture_opened in
  let select state items =
    step state (Capture_picker_requested Files)
    |> fun state -> step state (Capture_assets_picked (items, Some 1, None))
  in
  let owned state = Journal_capture.pending_attachments (Option.get (R.capture state)) in
  let own state items =
    let capture = List.fold_left Journal_capture.add_attachment (Option.get (R.capture state)) items in
    step state (Capture_admitted capture)
  in
  let graph index = Logseq_db_types.Graph_types.Uuid.of_string
    (Printf.sprintf "71000000-0000-4000-b000-%012d" index) |> Result.get_ok in
  let switch state index generation =
    step state (Graph_replaced {graph_id=Some (graph index); generation}) in
  check "close retains; discard emits attachment order" (fun () ->
    let selected = select (fresh ()) [a;b] in
    let old_session = Journal_capture.session_id (Option.get (R.capture selected)) in
    let closed = step selected Capture_closed in
    require (owned closed = [a;b]) "Close changed owned attachments";
    let opened = step closed Capture_opened in
    let next, plan = R.step opened Capture_discarded in
    expect [a;b] plan;
    require (R.capture next = None) "Discard kept Capture";
    let reopened = step next Capture_opened in
    require (Journal_capture.session_id (Option.get (R.capture reopened)) <> old_session)
      "Discard reused old input session");
  check "stale completion same-state carries cleanup without dedup" (fun () ->
    let state = fresh () in
    let next, plan = R.step state (Capture_assets_picked ([c;c],Some 99,None)) in
    require (next == state) "stale completion changed model identity";
    expect [c;c] plan);
  check "same path replay owns by path rather than token" (fun () ->
    let selected = select (fresh ()) [a] in
    let replay = multiselect_staged 9 (Journal_asset_import.staged_path a) "different-source" in
    let next, plan = R.step selected (Capture_asset_picked (replay,Some 99)) in
    require (next == selected && owned next = [a]) "replay changed current owner";
    expect [] plan);
  check "duplicate source independent copy retires only copy" (fun () ->
    let selected = select (fresh ()) [a] in
    let armed = step selected (Capture_picker_requested Files) in
    let duplicate = pick 3 "files:a" in
    let next, plan = R.step armed (Capture_asset_picked (duplicate,Some 2)) in
    require (owned next = [a]) "duplicate replaced original";
    expect [duplicate] plan);
  check "batch ownership updates before subsequent replay" (fun () ->
    let state = step (fresh ()) (Capture_picker_requested Files) in
    let duplicate = pick 3 "files:a" in
    let next, plan = R.step state (Capture_assets_picked ([a;a;duplicate;b],Some 1,None)) in
    require (owned next = [a;b]) "ordered accepted siblings changed";
    expect [duplicate] plan);
  check "capacity emits ordered overflow only" (fun () ->
    let state = step (fresh ()) (Capture_picker_requested Files) in
    let items = List.init (Journal_capture.attachment_limit+2)
      (fun i -> pick i ("files:" ^ string_of_int i)) in
    let next, plan = R.step state (Capture_assets_picked (items,Some 1,None)) in
    require (List.length (owned next) = Journal_capture.attachment_limit) "capacity changed";
    expect (List.filteri (fun i _ -> i >= Journal_capture.attachment_limit) items) plan);
  check "Saving rejects orphan but keeps current path" (fun () ->
    let selected = select (fresh ()) [a] in
    let capture = Journal_capture.update_source (Option.get (R.capture selected)) ~source:"Saving" in
    let saving, request = Journal_capture.admit_save capture
      ~mutation_id:"71000000-0000-4000-9000-000000000090"
      ~block_id:"71000000-0000-4000-a000-000000000090" ~sibling_order:"z"
      ~calendar_generation:1L ~creation_time:(creation_time 1) in
    require (Option.is_some request) "saving fixture not admitted";
    let admitted = step selected (Capture_admitted saving) in
    let next, plan = R.step admitted (Capture_assets_picked ([a;c],Some 1,None)) in
    require (next == admitted && R.capture next = Some saving) "Saving accepted async pick";
    expect [c] plan;
    let unchanged = step admitted Capture_discarded in
    require (unchanged == admitted) "Discard cancelled Saving";
    let failed = step admitted (Capture_admitted (Journal_capture.fail saving ~message:"interrupted")) in
    require (step failed Capture_discarded == failed) "Discard cancelled Failed attempt");
  check "named graphs retain and account clears in graph then active order" (fun () ->
    let one = switch (R.create ~graph_generation:1) 1 1
      |> fun s -> own (step s Capture_opened) [a] in
    let two = switch one 2 2 |> fun s -> own (step s Capture_opened) [b] in
    let three = switch two 3 3 |> fun s -> own (step s Capture_opened) [c] in
    let next, plan = R.step three Account_cleared in
    expect [a;b;c] plan;
    require (R.capture next = None) "account retained active draft";
    let returned = switch next 1 4 in
    require (R.capture returned = None) "account retained prior graph draft");
  check "unnamed graph replacement retires active draft" (fun () ->
    let selected = select (fresh ()) [a;b] in
    let next, plan = R.step selected (Graph_replaced {graph_id=Some (graph 1);generation=2}) in
    expect [a;b] plan;
    require (R.capture next = None) "anonymous draft gained named ownership");
  check "local delete keeps other retained graph owner" (fun () ->
    let one = switch (R.create ~graph_generation:1) 1 1
      |> fun s -> own (step s Capture_opened) [a] in
    let two = switch one 2 2 |> fun s -> own (step s Capture_opened) [b] in
    let deleted, plan = R.step two Local_copy_deleted in
    expect [b] plan;
    let returned = switch deleted 1 3 in
    require (owned returned = [a]) "local deletion erased another graph owner";
    let _, plan = R.step returned Account_cleared in expect [a] plan);
  check "public reducer defers actual unlink until adapter" (fun () ->
    let path = Filename.temp_file "journal-import-cleanup-" ".png" in
    Fun.protect ~finally:(fun () -> if Sys.file_exists path then Sys.remove path)
      (fun () ->
        let staged = multiselect_staged 50 path "files:purity-boundary" in
        let state = select (fresh ()) [staged] in
        let next, plan = R.step state Capture_discarded in
        require (R.capture next = None) "Discard did not change state";
        require (Sys.file_exists path) "public reducer performed unlink before adapter";
        expect [staged] plan;
        Rrbvec.iter (function Application.Discard_staged_file item ->
          Journal_asset_import.discard_staged_file item) plan;
        require (not (Sys.file_exists path)) "adapter did not apply returned plan"));
  check "ordinary no-op has empty plan and stable identity" (fun () ->
    let state = R.create ~graph_generation:1 in
    let next, plan = R.step state Capture_closed in
    require (next == state) "closed no-op changed state";
    expect [] plan);
  require (!failures = []) "%d cleanup contract cases failed" (List.length !failures)
;;

let test_staged_file_adapter_guard_and_failures () =
  let dir = Filename.temp_file "journal-cleanup-adapter-" "" in
  Sys.remove dir; Unix.mkdir dir 0o700;
  let owned = Filename.concat dir "journal-import-owned.png" in
  let kept = Filename.concat dir "keep.png" in
  let blocked = Filename.concat dir "journal-import-directory" in
  let descriptor index path = multiselect_staged index path ("adapter:" ^ string_of_int index) in
  Fun.protect ~finally:(fun () ->
    List.iter (fun path -> if Sys.file_exists path then Sys.remove path) [owned;kept];
    if Sys.file_exists blocked then Unix.rmdir blocked;
    Unix.rmdir dir)
    (fun () ->
      List.iter (fun path -> let out = open_out_bin path in output_string out "synthetic";close_out out)
        [owned;kept];
      Unix.mkdir blocked 0o700;
      Journal_asset_import.discard_staged_file (descriptor 0 kept);
      require (Sys.file_exists kept) "non-import file removed";
      Journal_asset_import.discard_staged_file (descriptor 1 blocked);
      Journal_asset_import.discard_staged_file (descriptor 2 owned);
      require (not (Sys.file_exists owned)) "matched file not removed after previous failure";
      Journal_asset_import.discard_staged_file (descriptor 2 owned);
      Journal_asset_import.discard_staged_file (descriptor 3 (Filename.concat dir "journal-import-missing"));
      require (Sys.file_exists kept && Sys.is_directory blocked) "adapter crossed guarded resource scope")
;;

let child_equal expected actual label = if expected<>actual then failwith label
let child_identity_detail () =
  Journal_detail.create ~session_number:11L
    {root=block();children={blocks=[];continuation=None}}
;;
let child_identity_append detail =
  Journal_detail.admit_child detail ~mutation_id:"70000000-0000-4000-9000-000000000071"
    ~calendar_generation:1L ~block_id:"70000000-0000-4000-a000-000000000071"
    ~sibling_order:"a" ~creation_time:(creation_time 550)
;;
let test_child_oversize_is_editable_before_admission () =
  let source=String.make(Worker_pure_data.maximum_title_bytes+1)'x' in
  let detail=child_identity_detail() |> fun detail->Journal_detail.update_child_source detail source in
  let next,request=child_identity_append detail in
  require(request<>None) "refactor changed the existing Child submission boundary";
  let command=match request with Some(Journal_graph_request.Create_child command)->command
    |_->fail "Child submission lost its command" in
  let next=Journal_detail.release_rejected_child next ~command ~message:"Known not admitted" in
  let next=Journal_detail.update_child_source next "Shortened child" in
  require(Option.map Journal_capture.source(Journal_detail.child_capture next)=Some "Shortened child")
    "unadmitted oversized Child could not be corrected"
;;
let child_status_a=Journal_model.Status "00000002-1615-5853-7700-000000000000"
let child_status_b=Journal_model.Status "00000002-1827-5820-8200-000000000000"
let failed_child_choice_from task_state =
  let draft=child_identity_detail() |> fun t->Journal_detail.update_child_source t "Frozen child source"
    |> fun t->Journal_detail.set_child_task t task_state in
  let saving,request=child_identity_append draft in
  Journal_detail.fail saving ~message:"Accepted response unknown",Option.get request
;;
let failed_child_choice () = failed_child_choice_from child_status_a
let child_command = function
  | Journal_graph_request.Create_child command->command
  | _->failwith "Child owner lost its pending request"
;;
let test_child_reselected_status_intent () =
  let failed,first=failed_child_choice() in
  let duplicate=Journal_detail.set_child_task failed child_status_a in
  child_equal (Some first)(snd(Journal_detail.retry duplicate)) "duplicate choice keeps its intent";
  let second=Journal_detail.set_child_task failed child_status_b in
  let second,request_b=Journal_detail.retry second in
  let second=Journal_detail.fail second ~message:"Second response unknown" in
  let third=Journal_detail.set_child_task second child_status_a in
  let _,request_a2=Journal_detail.retry third in
  require(Option.get request_a2<>first) "A to B to A reused the first child status intent";
  let original=child_command first and actual=child_command(Option.get request_a2) in
  child_equal original.mutation_id actual.mutation_id "new status choice replaced original insertion";
  child_equal original.block_id actual.block_id "new status choice replaced child identity";
  child_equal original.source actual.source "new status choice changed frozen source";
  child_equal original.expected_parent_revision actual.expected_parent_revision "new choice changed parent precondition";
  require(request_b<>Some first) "new status choice was not distinct"
;;
let test_retained_child_status_keeps_frozen_attempt () =
  let failed,first=failed_child_choice() in
  let retained=Journal_detail.retain_composer failed |> Option.get in
  let retained=Journal_detail.map_retained_capture retained
    ~f:(fun capture->Journal_capture.with_task_state capture child_status_b) in
  let restored=Journal_detail.restore_composer(child_identity_detail())retained in
  let _,request=Journal_detail.retry restored in
  let current=Option.get request |> child_command and original=child_command first in
  child_equal original.mutation_id current.mutation_id "retained choice lost insertion owner";
  child_equal original.source current.source "retained choice lost frozen source";
  child_equal child_status_b current.task_state "retained status choice was ignored"
;;

let test_uncertain_plain_child_keeps_identity () =
  let saving, request = child_identity_detail ()
    |> fun t -> Journal_detail.update_child_source t "Frozen plain child"
    |> child_identity_append in
  let original = Option.get request |> child_command in
  let failed = Journal_detail.fail saving ~message:"Accepted insertion response unknown" in
  List.iter (fun owner ->
    let owner = Journal_detail.set_child_task owner child_status_a in
    let owner = Journal_detail.update_child_source owner "Unsafe replacement" in
    let _, request = Journal_detail.retry owner in
    require (request <> None) "uncertain plain insertion lost its retry owner";
    let actual = Option.get request |> child_command in
    child_equal original.mutation_id actual.mutation_id "plain insertion ID replaced";
    child_equal original.block_id actual.block_id "plain child ID replaced";
    child_equal original.source actual.source "uncertain plain child source replaced";
    require actual.status_confirmation "new status choice was not retained as a sub-operation";
    let cleared = Journal_detail.set_child_task owner Journal_model.No_status in
    let command = snd (Journal_detail.retry cleared) |> Option.get |> child_command in
    require command.status_confirmation "returning to No status silently skipped Clear";
    child_equal 2L command.status_intent_revision "plain child lost A to Clear choice history")
    [failed; Journal_detail.restore_composer (child_identity_detail ())
       (Journal_detail.retain_composer saving |> Option.get
        |> Journal_detail.interrupt_retained_composer)]
;;

(* Public pure business owner: generated traces start with a legally admitted,
   uncertain insertion, then interleave edits, retries and retained composers.
   Choice history is independent of the implementation's revision counter. *)
let test_child_choice_traces () =
  let choices = [| child_status_a; child_status_b; Journal_model.No_status |] in
  let run initial_choice actions =
    let initial, request = failed_child_choice_from initial_choice in
    let original = child_command request in
    let current = ref initial and selected = ref initial_choice and revision = ref 0L in
    List.iteri (fun index action ->
      let before = !current in
      let _, before_request = Journal_detail.retry before in
      let pick = choices.(action mod Array.length choices) in
      let choose () =
        if pick <> !selected then revision := Int64.succ !revision;
        selected := pick
      in
      current := (match action / 3 with
        | 0 -> choose (); Journal_detail.set_child_task before pick
        | 1 -> choose (); Journal_detail.map_child_capture before
            ~f:(fun capture -> Journal_capture.with_task_state capture pick)
        | 2 ->
          choose ();
          let draft = Journal_detail.retain_composer before |> Option.get in
          let draft = Journal_detail.map_retained_capture draft
            ~f:(fun capture -> Journal_capture.with_task_state capture pick) in
          Journal_detail.restore_composer (child_identity_detail ()) draft
        | 3 -> Journal_detail.update_child_source before "Do not replace frozen source"
        | 4 ->
          let saving, admitted = Journal_detail.retry before in
          child_equal before_request admitted "retry replaced the frozen request";
          let ignored = Journal_detail.set_child_task saving pick in
          child_equal admitted (snd (Journal_detail.retry
            (Journal_detail.fail ignored ~message:"Still uncertain")))
            "in-flight status edit changed an admitted operation";
          Journal_detail.fail ignored ~message:"Still uncertain"
        | _ ->
          let draft = Journal_detail.retain_composer before |> Option.get in
          let other = Journal_detail.create ~session_number:99L
            { root=block ~id:"70000000-0000-4000-a000-000000000099" ();
              children={blocks=[];continuation=None} } in
          require (Journal_detail.child_capture (Journal_detail.restore_composer other draft)=None)
            "foreign root adopted a retained child";
          before);
      child_equal before_request (snd (Journal_detail.retry before))
        "later pure transition mutated an earlier state";
      let _, pending = Journal_detail.retry !current in
      let actual = Option.get pending |> child_command in
      child_equal !selected actual.task_state "selected status lost";
      child_equal !revision actual.status_intent_revision "choice history reused a status identity";
      require (actual.status_confirmation =
        (original.status_confirmation || !revision > 0L)) "status sub-operation was lost";
      child_equal original {actual with task_state=original.task_state;
        status_confirmation=original.status_confirmation;
        status_intent_revision=original.status_intent_revision}
        (Printf.sprintf "frozen insertion changed at action %d" index)) actions
  in
  let fails initial actions = try run initial actions; false with _ -> true in
  let rec shrink initial actions =
    let rec remove prefix = function
      | [] -> actions
      | _ :: rest when fails initial (List.rev_append prefix rest) ->
        shrink initial (List.rev_append prefix rest)
      | item :: rest -> remove (item :: prefix) rest
    in
    remove [] actions
  in
  for seed = 0 to 199 do
    let random = Random.State.make [|0xC11D; seed|] in
    let initial = if seed mod 2 = 0 then child_status_a else Journal_model.No_status in
    let actions = List.init 80 (fun _ -> Random.State.int random 18) in
    if fails initial actions then (
      let minimal = shrink initial actions in
      fail "Child choice trace seed=%d minimized=[%s]" seed
        (String.concat ";" (List.map string_of_int minimal)))
  done
;;

module Detail_observation_fixture = struct
  module M=Journal_detail.Pure_observation
  module W=Journal_worker_coordination.Worker_api
  module C=Journal_worker_coordination.Worker_pure_coordinator
  module Read=Worker_pure_read
  module S=Logseq_db_worker_lui.Logseq_db_worker_lui_service
  module Id=Journal_worker_ids
  let root=W.Uuid.of_string "70000000-0000-4000-a000-000000005540" |> Result.get_ok
  let make ?(failed=false) () =
    let issuer,raw,projection,session=Coordination_test_fixture.fixture 5540L in
    let module I=(val issuer:Worker_effect_authority.ISSUER) in
    let ready=(C.step(C.initial ~client_id:root)(C.Worker_bound I.binding)).next
      |> fun state->(C.step state(C.Bootstrap_received(I.binding,W.Ready projection))).next in
    let budget=W.read_budget session ~maximum_items:1 ~maximum_bytes:65536 |> Result.get_ok in
    let operation=W.Observe(budget,W.Outline_block{uuid=root;revision=None}) in
    let ticket,planned=C.request ready session operation |> Result.get_ok in
    let wire=I.request session ~request_id:(C.ticket_id ticket) operation |> Result.get_ok in
    let registration,owner,observation_id,request_id,read=match wire with S.Coordination_observe value->
      value.registration,value.owner,value.observation_id,value.request_id,value.read|_->assert false in
    let Read.Read_query(source_budget,source_query)=read in
    let answer=match source_query with
      |Read.Outline_block _->Read.For_worker.answer source_budget source_query
        (Ok(Worker_pure_data.V2_missing_block{uuid=root;revision="missing-0"}))
      |_->assert false in
    let response=S.Coordination_observed{registration;owner;observation_id;request_id;epoch=0L;answer} in
    let handle,epoch=I.observation_registration session ~request_id:(C.ticket_id ticket) operation response |> Result.get_ok in
    let admitted=(C.step planned.next(C.Admitted(ticket,Id.Worker.Request_id.one))).next in
    let registered=(C.step admitted(C.Observation_registered(ticket,handle,epoch))).next in
    let reply=if failed then W.Answered(Error W.Response_budget_exceeded) else I.reply session
      ~request_id:(C.ticket_id ticket) operation response |> Result.get_ok in
    let completed=(C.step registered(C.Completed(ticket,reply))).next in
    let context:M.context={entry_id="detail-observation-fixture";request_generation=1L;root;owner;original=request_id;maximum_children=128} in
    context,ticket,handle,planned.next,completed,issuer,session,raw
  let refresh issuer session handle state =
    let module I=(val issuer:Worker_effect_authority.ISSUER) in
    let operation=W.Refresh handle in
    let ticket,planned=C.request state session operation |> Result.get_ok in
    let registration,owner,observation_id,request_id=match I.request session ~request_id:(C.ticket_id ticket) operation |> Result.get_ok with
      | S.Coordination_refresh_observation value->value.registration,value.owner,value.observation_id,value.request_id
      | _->assert false in
    let query=W.observation_query handle in
    let answer=match query with
      |W.Outline_block _->Read.For_worker.answer (W.observation_budget handle) query
        (Ok(Worker_pure_data.V2_missing_block{uuid=root;revision="missing-1"}))
      |_-> . in
    let response=S.Coordination_observed{registration;owner;observation_id;request_id;epoch=1L;answer} in
    let value=match I.reply session ~request_id:(C.ticket_id ticket) operation response |> Result.get_ok with
      | W.Answered(Ok value)->value|_->assert false in
    let admitted=(C.step planned.next(C.Admitted(ticket,Id.Worker.Request_id.of_int64 2L))).next in
    let registered=(C.step admitted(C.Observation_registered(ticket,handle,value.epoch))).next in
    (C.step registered(C.Completed(ticket,W.Answered(Ok value)))).next

end

let test_detail_observation_context_retains_empty_and_releases () =
  let module F=Detail_observation_fixture in let module M=F.M in let module C=F.C in
  let context,ticket,handle,pending,ready,_,_,_=F.make() in
  let model,effects=M.planned M.empty context ticket in
  require(Rrbvec.is_empty effects) "new Detail observation cancelled an unrelated owner";
  let waiting,effects=M.inspect model(C.view pending) in
  require(Rrbvec.is_empty effects && M.context_count waiting=1) "pending Observe fabricated a sample";
  let current,effects=M.inspect waiting(C.view ready) in
  require(Rrbvec.exists(function M.Initial(_,sample)->(match sample.value with Worker_pure_data.V2_missing_block _->true|_->false)|_->false)effects)
    "missing/empty Detail observation was discarded";
  require(not(Rrbvec.exists(function M.Release _->true|_->false)effects)) "empty Detail observation was released";
  let current,again=M.inspect current(C.view ready) in
  require(Rrbvec.is_empty again) "one observation epoch was forwarded twice";
  let previous=current in
  let retired,effects=M.retain current Rrbvec.empty in
  require(M.context_count previous=1 && M.context_count retired=0) "retirement mutated an earlier pure state";
  require(Rrbvec.exists(function M.Release actual->F.W.same_observation actual handle<>None|_->false)effects)
    "native Back did not release the exact registered observation";
  let retired,effects=M.inspect retired(C.view ready) in
  require(M.context_count retired=0 && Rrbvec.is_empty effects) "late observed DTO revived a retired Detail"
;;

let test_detail_observation_failure_recovers_same_handle () =
  let module F=Detail_observation_fixture in let module M=F.M in let module C=F.C in
  let context,ticket,handle,_,failed,issuer,session,_=F.make ~failed:true () in
  let model,_=M.planned M.empty context ticket in
  let model,_=M.inspect model(C.view failed) in
  let refreshed=F.refresh issuer session handle (C.step failed(C.Forget ticket)).next in
  let model,effects=M.inspect model(C.view refreshed) in
  require(M.context_count model=1) "failed observation lost its presentation context";
  require(Rrbvec.exists(function M.Updated(_,sample)->F.W.same_observation sample.observation handle<>None|_->false)effects)
    "recovery replaced the original observation or initial read owner";
  require(not(Rrbvec.exists(function M.Release _|Cancel_initial _->true|_->false)effects))
    "read recovery retired its live registration"
;;

(* This business projection owner exposes a synchronous Runtime facade rather
   than a pure reducer. Exercise that facade; do not duplicate database IO. *)
let test_observed_absence_does_not_commit_user_deletion () =
  let module F=Detail_observation_fixture in
  let runtime=Journal_graph_runtime.create() in
  let request=Journal_graph_runtime.plan_observed_block runtime ~root:F.root in
  let output=Journal_graph_runtime.receive_worker_read runtime ~request_id:request
    (Journal_graph_runtime.Query_result(F.W.Outline_block{uuid=F.root;revision=None},
      Worker_pure_data.V2_missing_block{uuid=F.root;revision="missing-observed"})) in
  require(not(List.exists(fun response->match response.Journal_graph_runtime.payload with
    | Block_removed _|Subtree_deleted _->true|_->false)output.responses))
    "an observed absence committed deletion of retained Detail drafts";
  require(not(Journal_graph_runtime.owns_read runtime request)) "observed absence kept a consumed DTO owner"
;;

let test_detail_observation_binding_revocation_is_visible () =
  let module F=Detail_observation_fixture in let module M=F.M in let module C=F.C in
  let context,ticket,_,_,ready,issuer,_,_=F.make() in
  let module I=(val issuer:Worker_effect_authority.ISSUER) in
  let model,_=M.planned M.empty context ticket in
  let model,_=M.inspect model(C.view ready) in
  let forgotten=(C.step ready(C.Forget ticket)).next in
  let revoked=(C.step forgotten(C.Binding_invalidated I.binding)).next in
  let retired,effects=M.inspect model(C.view revoked) in
  require(M.context_count retired=0) "binding revocation silently retained a dead Detail observation";
  require(Rrbvec.exists(function M.Failed(actual,F.W.Revoked_session)->actual=context|_->false)effects)
    "binding revocation left Detail without an explicit resubscription path";
  let _,again=M.inspect retired(C.view revoked) in
  require(Rrbvec.is_empty again) "retired binding emitted repeated presentation failures"
;;

let test_detail_observation_generated_lifetimes () =
  let module F=Detail_observation_fixture in let module M=F.M in let module C=F.C in
  let run actions =
    let context,ticket,handle,pending,ready,issuer,session,_=F.make() in
    let refreshed=F.refresh issuer session handle (C.step ready(C.Forget ticket)).next in
    let current=ref(fst(M.planned M.empty context ticket)) and retired=ref false
      and cleanup_count=ref 0 and last_epoch=ref None and latest_view=ref 0 in
    List.iter(fun action->
      let before= !current in let snapshot=Marshal.to_string before [] in
      (* Core views are authoritative snapshots. Packet reordering is reduced by
         Core before this boundary; a caller never republishes an older view. *)
      if action mod 7<=2 then latest_view:=max !latest_view (action mod 7);
      let current_view=C.view(match !latest_view with 0->pending|1->ready|_->refreshed) in
      let transition model=match action mod 7 with
        | 0|1|2->M.inspect model current_view
        | 3->M.retain model(Rrbvec.singleton(context.entry_id,context.request_generation,context.root))
        | 4->M.retain model Rrbvec.empty
        | 5 when not !retired->M.planned model context ticket
        | 6 when not !retired->M.planned model {context with entry_id="foreign-context"} ticket
        | _->M.inspect model current_view in
      let next,effects=transition before and again,repeated=transition before in
      require(next=again && effects=repeated && snapshot=Marshal.to_string before [])
        "Detail observation transition mutated its input or was nondeterministic";
      require(M.context_count next<=1) "one observation acquired two native owners";
      Rrbvec.iter(function
        | M.Initial(actual,sample)|Updated(actual,sample)->
          require(not !retired && actual=context) "late DTO crossed native context ownership";
          require(Option.fold ~none:true ~some:(fun previous->F.W.compare_observation_epoch sample.epoch previous>0)!last_epoch)
            "observation epoch was duplicated or moved backwards";
          last_epoch:=Some sample.epoch
        | Cancel_initial _|Release _->incr cleanup_count
        | _->())effects;
      current:=next;
      if M.context_count next=0 then retired:=true;
      require(!cleanup_count<=1) "retired UI context issued cleanup twice";
      if !retired then require(M.context_count next=0) "stale input revived a retired Detail")actions in
  let fails actions=try run actions;false with _->true in
  let rec shrink actions=
    let rec remove prefix=function
      | []->actions
      | _::rest when fails(List.rev_append prefix rest)->shrink(List.rev_append prefix rest)
      | item::rest->remove(item::prefix)rest in remove [] actions in
  for seed=0 to 99 do
    let random=Random.State.make[|0x0B5E;seed|] in
    let actions=List.init 60(fun _->Random.State.int random 70) in
    if fails actions then fail "Detail observation seed=%d minimized=[%s]" seed
      (String.concat ";" (List.map string_of_int(shrink actions)))
  done
;;

let test_detail_observation_ticket_has_one_context_owner () =
  let module F=Detail_observation_fixture in let module M=F.M in
  let context,ticket,_,_,_,_,_,_=F.make() in
  let model,_=M.planned M.empty context ticket in
  let other={context with entry_id="foreign-native-entry"} in
  let attempted,effects=M.planned model other ticket in
  require(M.context_count attempted=1) "one Observe ticket acquired two context owners";
  require(not(Rrbvec.exists(function M.Cancel_initial _|Forget_initial _|Release _->true|_->false)effects))
    "a foreign context retired the legitimate Observe ticket";
  let wrong_root=F.W.Uuid.of_string "70000000-0000-4000-a000-000000005541" |> Result.get_ok in
  let attempted,effects=M.planned model {other with root=wrong_root} ticket in
  require(M.context_count attempted=1 && not(Rrbvec.exists(function M.Cancel_initial _|Release _->true|_->false)effects))
    "malformed reattachment cancelled another context's observation"
;;

let test_detail_observation_failure_and_pending_cancel () =
  let module F=Detail_observation_fixture in let module M=F.M in let module C=F.C in
  let context,ticket,handle,_,failed,_,_,_=F.make ~failed:true () in
  let model,_=M.planned M.empty context ticket in
  let model,effects=M.inspect model(C.view failed) in
  require(M.context_count model=1) "read failure erased a registered Detail observation";
  require(Rrbvec.exists(function M.Failed(_,F.W.Response_budget_exceeded)->true|_->false)effects)
    "failed initial sample lost its owned error";
  require(not(Rrbvec.exists(function M.Release _->true|_->false)effects)) "read failure pretended to release a resource";
  let _,effects=M.retain model(Rrbvec.singleton(context.entry_id,2L,context.root)) in
  require(Rrbvec.exists(function M.Release actual->F.W.same_observation actual handle<>None|_->false)effects)
    "new route generation retained an old observation";
  let pending,_=M.planned M.empty context ticket in
  let _,effects=M.retain pending Rrbvec.empty in
  require(Rrbvec.exists(function M.Cancel_initial actual->C.ticket_id actual=C.ticket_id ticket|_->false)effects)
    "pop racing registration did not cancel the exact initial ticket";
  require(Rrbvec.exists(function M.Forget_initial _->true|_->false)effects)
    "cancelled initial ticket leaked its presentation slot"
;;

module Child_chain_fixture = struct
  module C = Journal_graph_mutation_confirmation.Pure_insertion
  module W = Journal_worker_coordination.Worker_api
  module P = Logseq_db_worker.Protocol
  module G = Logseq_db_types.Graph_types
  type t =
    { initial : C.t
    ; action : C.action
    ; command : Journal_graph_projection.create_child
    ; session : W.session
    ; presentation : W.presentation
    ; projection : W.projection
    ; binding : W.binding
    ; confirm : int -> W.durable_intent -> W.presentation -> W.mutation_progress
    }
  let make ?(append=false) ?(task_state=Journal_model.No_status) () =
    let issuer,_,projection,session=Coordination_test_fixture.fixture
      ~limits:{Coordination_test_fixture.limits with response_budget_bytes=Worker_pure_data.maximum_response_bytes} 5514L in
    let module I=(val issuer:Worker_effect_authority.ISSUER) in
    let presentation=Option.get(W.selected projection) in
    let uuid s=G.Uuid.of_string s |> Result.get_ok in
    let _,request=child_identity_detail() |> fun t->Journal_detail.update_child_source t "Frozen child source"
      |> fun t->Journal_detail.set_child_task t task_state |> child_identity_append in
    let command=Option.get request |> child_command in
    let page:G.page={uuid=uuid "70000000-0000-4000-b000-000020260809";name="Child fixture";title="Child fixture";
      kind=(if append then Journal_page{journal_day=20260809} else Ordinary_page);created_at_ms=1L;updated_at_ms=1L;tags=[];properties=[];recycled=false} in
    let parent=(if append then page.uuid else uuid command.parent_block_id) and child=uuid command.block_id in
    let insert=W.Insert_blocks {parent;
      roots=[{uuid=child;title=command.source;children=[]}];
      preconditions={blocks=[parent,command.expected_parent_revision];pages=[];
        scopes=[Worker_pure_data.V2_children_scope parent,"children-state:v1:frozen"]}} in
    let resolved_status=match task_state with Journal_model.Status id->Some(uuid id)|_->None in
    let initial,action=if not append then C.start ~command ~page ~resolved_status ~insert |> Result.get_ok
      else let capture:Journal_graph_projection.capture={mutation_id=command.mutation_id;block_id=command.block_id;
        source=command.source;sibling_order=command.sibling_order;creation_time=command.creation_time;children=[];
        task_state=command.task_state;status_confirmation=command.status_confirmation;status_intent_revision=command.status_intent_revision} in
      C.start_capture ~command:capture ~resolved_status
        ~root:Worker_pure_data.{block_id=child;title=command.source;task_status=resolved_status;children=Rrbvec.empty}
      |> Result.get_ok in
    let confirm index intent presentation =
      let id=W.durable_intent_id intent in
      let request_id=W.request_id id in
      let after=Printf.sprintf "projection:v1:%d" (index+1) in
      let receipt=(let (P.V2_response receipt_packet as packet) = (P.V2_response
        {api_version=P.api_version;request_id=id;outcome=V2_mutation_committed
          {mutation_id=id;status=Worker_pure_data.V2_applied;generation="generation:v1:1:1";
           before_projection_revision=Printf.sprintf "projection:v1:%d" index;after_projection_revision=after}}) in
        match I.reply session ~request_id (match intent with W.Append_intent intent->W.Append intent|Mutation_intent intent->W.Mutate intent)
          (Logseq_db_worker_lui.Logseq_db_worker_lui_service.Coordination_mutation_result
            {request_id=receipt_packet.request_id;
             outcome=Logseq_db_worker_contract.Mutation_pure_wire.Committed packet}) with
        | Ok(W.Answered(Ok(W.Committed_pending_presentation proof))) -> proof
        | _ -> failwith "Production mutation receipt was rejected") in
      let block:G.block={uuid=child;title=command.source;parent;page=page.uuid;order="a";
        created_at_ms=1L;updated_at_ms=1L;refs=[];tags=[];properties=[]} in
      (* Equal visible status is deliberately insufficient to prove a status sub-operation. *)
      let value:Worker_pure_data.block_record={block;task_status=resolved_status;rendered_page_title=page.title;tag_titles=[]} in
      let confirmation=Coordination_test_fixture.confirmed_summary issuer session presentation receipt (W.request_id id)
        ~lookup:(Worker_pure_data.V2_present_block{value;revision=Printf.sprintf "child-state:v1:%d" index})
        ~page:(Some(Worker_pure_data.V2_present_page{page;revision="page-state:v1:1"})) ~items:[]
        ~scope_revision:"children-state:v1:1" ~generation:"generation:v1:1:1" ~projection_revision:after in
      W.Confirmed confirmation in
    {initial;action;command;session;presentation;projection;binding=I.binding;confirm}
  let write fixture state = function
    | C.Write(index,round)->index,round,W.encode_durable_intent(C.stage_intent fixture.session(C.stage state index) |> Result.get_ok)
    | _->fail "expected a child write"
  let bind fixture state action =
    let index,round,_=write fixture state action in
    let stage=C.stage state index in
    let intent=C.stage_intent fixture.session stage |> Result.get_ok in
    let state=C.bind state ~index ~round ~intent ~presentation:fixture.presentation |> Option.get in
    state,index,round,intent
  let confirm fixture state action =
    let state,index,round,intent=bind fixture state action in
    C.receive state ~index ~round (fixture.confirm index intent fixture.presentation)
  let applied fixture state action =
    let round=match action with C.Read_parent(round,_)->round|_->fail "expected canonical parent read" in
    let ready,action=C.projection_ready state ~round in
    require (action=C.Present round) "parent projection cannot be presented";
    let ignored,action=C.applied ready ~round:Int64.(succ round) fixture.presentation in
    require(ignored==ready && action=C.Ignore) "foreign UI application advanced cleanup";
    C.applied ready ~round fixture.presentation
  let rec flush_prefix fixture state action = match action with
    | C.Write _ | Complete -> state,action
    | Read_parent _ -> let state,action=applied fixture state action in flush_prefix fixture state action
    | Present round -> let state,action=C.applied state ~round fixture.presentation in flush_prefix fixture state action
    | Acknowledge(index,round,_,_) ->
      let state,action=C.acknowledged state ~index ~round(Ok()) in flush_prefix fixture state action
    | Read_child round ->
      let state,action=C.read_child state ~round(Option.get(C.canonical state)) in flush_prefix fixture state action
    | Wait message ->fail "prefix settlement failed: %s" message
    | Ignore ->fail "prefix settlement ignored its current operation"
end

let test_capture_oversize_is_editable_before_admission () =
  let source=String.make (Worker_pure_data.maximum_title_bytes+1) 'x' in
  let original=Journal_capture.create ~session_number:5518L ~source in
  let next,request=Journal_capture.admit_save original
    ~mutation_id:"70000000-0000-4000-9000-000000005518"
    ~block_id:"70000000-0000-4000-a000-000000005518" ~sibling_order:"a1"
    ~calendar_generation:1L ~creation_time:(creation_time 551) in
  require(request<>None) "refactor changed the existing Capture submission boundary";
  require(Journal_capture.phase next=Journal_capture.Saving)
    "Capture did not preserve its existing saving transition";
  let rejected=Journal_capture.release_rejected_attempt next in
  let shortened=Journal_capture.update_source rejected ~source:"Shortened draft" in
  require_string "Shortened draft" (Journal_capture.source shortened)
    "known non-admission could not be corrected"
;;

let test_capture_retained_attempt_survives_runtime_reset () =
  let module F=Child_chain_fixture in let module C=F.C in let module R=Journal_graph_runtime in
  let fixture=F.make ~append:true () in
  let sampler=Journal_calendar.Sampler.create
    ~clock:(fun()->Int64.to_float(Journal_time.instant_unix_ms fixture.command.creation_time)/.1000.)
    ~localtime:Unix.gmtime () in
  let calendar=Journal_calendar.Sampler.sample sampler |> Result.get_ok in
  let runtime=R.create ~localtime:Unix.gmtime () in R.set_calendar runtime calendar;
  let capture,request=Journal_capture.admit_save
    (Journal_capture.create ~session_number:5519L ~source:fixture.command.source)
    ~mutation_id:fixture.command.mutation_id ~block_id:fixture.command.block_id
    ~sibling_order:fixture.command.sibling_order ~calendar_generation:(Journal_calendar.generation calendar)
    ~creation_time:fixture.command.creation_time in
  let boundary=ref 0 in
  let only output=incr boundary;match output.R.requests with [request]->request|_->
    fail "Capture continuation %d emitted %d requests and %d responses: %s" !boundary
      (List.length output.requests)(List.length output.responses)
      (List.map(fun response->match response.R.payload with
        | Capture_waiting{message;_}->message|_->"other")output.responses |> String.concat ";") in
  let initial=R.submit runtime (Option.get request) |> only in
  let intent=R.worker_intent runtime initial fixture.session |> Result.get_ok in
  let wire=F.W.encode_durable_intent intent in
  require(R.bind_mutation runtime initial ~presentation:fixture.presentation ~intent) "Capture did not bind original Append";
  ignore(R.receive_mutation runtime initial F.W.Outcome_unknown);
  let command=Journal_capture.pending_command capture |> Option.get in
  let chain=R.capture_chain runtime ~command |> Option.get in
  let capture=Journal_capture.retain_chain capture chain |> fun capture->Journal_capture.fail capture ~message:"Unknown original Append" in
  let capture=Journal_capture.with_task_state capture child_status_a in
  R.reset runtime;R.set_calendar runtime calendar;
  let capture,request=Journal_capture.retry capture in
  let resumed=R.submit ?capture_chain:(Journal_capture.retained_chain capture) runtime (Option.get request) |> only in
  let resumed_wire=R.worker_intent runtime resumed fixture.session |> Result.get_ok |> F.W.encode_durable_intent in
  require(resumed_wire=wire) "Runtime reset reconstructed the accepted Append with a new status payload";
  require(Journal_capture.source capture=fixture.command.source) "Runtime reset lost frozen source";
  require(R.bind_mutation runtime resumed ~presentation:fixture.presentation ~intent) "restored Append did not bind";
  let progress=fixture.confirm 0 intent fixture.presentation in
  let output=R.receive_mutation runtime resumed progress in
  let root,round=List.find_map(fun response->match response.R.payload with
    | Capture_projection_ready{root;round;_}->Some(root,round)|_->None)output.responses |> Option.get in
  let ack=R.child_projection_applied runtime ~root ~round ~presentation:fixture.presentation |> only in
  let canonical=R.receive_child_ack runtime ack (Ok()) |> only in
  let summary=match progress with F.W.Confirmed proof->(match F.W.confirmation_primary proof with
    | Confirmed_block summary->summary|_->assert false)|_->assert false in
  let status=R.receive_worker_read runtime ~request_id:canonical (R.Query_result(F.W.Block_summary{block=root;after=None},summary)) |> only in
  let status_intent=R.worker_intent runtime status fixture.session |> Result.get_ok in
  require(R.bind_mutation runtime status ~presentation:fixture.presentation ~intent:status_intent)
    "status continuation did not bind";
  ignore(R.receive_mutation runtime status F.W.Outcome_unknown);
  let command=Journal_capture.pending_command capture |> Option.get in
  let chain=R.capture_chain runtime ~command |> Option.get in
  let capture=Journal_capture.retain_chain capture chain |> fun capture->Journal_capture.fail capture ~message:"Unknown original status" in
  R.reset runtime;R.set_calendar runtime calendar;
  let capture,request=Journal_capture.retry capture in
  let resumed=R.submit ?capture_chain:(Journal_capture.retained_chain capture) runtime (Option.get request) |> only in
  require(F.W.encode_durable_intent(R.worker_intent runtime resumed fixture.session |> Result.get_ok)=F.W.encode_durable_intent status_intent) "Runtime reset rebuilt an accepted status with new preconditions";
  let _,_,projection,session=Coordination_test_fixture.fixture 5520L in
  let presentation=Option.get(F.W.selected projection) in
  let intent=R.worker_intent runtime resumed session |> Result.get_ok in
  require(R.bind_mutation runtime resumed ~presentation ~intent)
    "fresh execution did not adopt its original logical operation"
;;

let test_capture_chain_freezes_complete_payload () =
  let module F=Child_chain_fixture in let module C=F.C in let module P=F.P in
  let fixture=F.make() in
  let uuid value=F.G.Uuid.of_string value |> Result.get_ok in
  let child:Journal_graph_projection.capture_child={
    mutation_id="70000000-0000-4000-9000-000000005519";
    block_id="70000000-0000-4000-a000-000000005519";sibling_order="a0";
    source="Frozen child 中文";task_state=child_status_a;creation_time=fixture.command.creation_time} in
  let command:Journal_graph_projection.capture={mutation_id=fixture.command.mutation_id;
    block_id=fixture.command.block_id;sibling_order=fixture.command.sibling_order;
    source=fixture.command.source;task_state=Journal_model.No_status;
    status_confirmation=false;status_intent_revision=0L;creation_time=fixture.command.creation_time;
    children=[child]} in
  let root:Worker_pure_data.append_node={block_id=uuid command.block_id;title=command.source;task_status=None;
    children=Rrbvec.singleton Worker_pure_data.{block_id=uuid child.block_id;title=child.source;
      task_status=(match child_status_a with Status id->Some(uuid id)|_->assert false);children=Rrbvec.empty}} in
  let state,_=C.start_capture ~command ~resolved_status:None ~root |> Result.get_ok in
  let original=F.W.encode_durable_intent(C.stage_intent fixture.session(C.stage state 0) |> Result.get_ok) in
  require(Result.is_error(C.retarget_capture state ~command:{command with source="Changed"} ~resolved_status:None))
    "Capture retry changed its root source";
  require(Result.is_error(C.retarget_capture state ~command:{command with children=[{child with source="Changed"}]} ~resolved_status:None))
    "Capture retry changed its original child payload";
  require(Result.is_error(C.start_capture ~command:{command with children=[]} ~resolved_status:None ~root))
    "Capture admitted children different from the atomic wire";
  let selected={command with task_state=child_status_a;status_intent_revision=1L;status_confirmation=true} in
  let state=C.retarget_capture state ~command:selected
    ~resolved_status:(match child_status_a with Status id->Some(uuid id)|_->assert false) |> Result.get_ok in
  let state,action=C.retry state in
  let _,_,wire=F.write fixture state action in
  require(wire=original) "Capture changed an unknown Append when a later status was selected"
;;

let test_append_chain_uses_canonical_journal_owner () =
  let module F=Child_chain_fixture in let module C=F.C in
  let fixture=F.make ~append:true () in
  let state=fixture.initial in
  let _,_,original=F.write fixture state fixture.action in
  let state,action=C.retry state in
  let _,_,actual=F.write fixture state action in
  require(actual=original) "atomic Append retry changed its frozen intent";
  let state,index,round,intent=F.bind fixture state action in
  let state,action=C.receive state ~index ~round (fixture.confirm index intent fixture.presentation) in
  require(match action with C.Present _->true|_->false) "atomic Append lost its canonical journal owner";
  require((C.page state).kind=F.G.Journal_page{journal_day=20260809}) "atomic Append adopted a different day"
;;

let child_unknown_stages fixture =
  let module F=Child_chain_fixture in let module C=F.C in
  let bound,index,round,_=F.bind fixture fixture.initial fixture.action in
  let initial,_=C.receive bound ~index ~round F.W.Outcome_unknown in
  let inserted,action=F.confirm fixture fixture.initial fixture.action in
  let inserted,status=F.flush_prefix fixture inserted action in
  let bound,index,round,_=F.bind fixture inserted status in
  let unknown_status,_=C.receive bound ~index ~round F.W.Outcome_unknown in
  [initial,0;unknown_status,1]
;;
let test_child_retained_chain_survives_projection_reopen () =
  let module F=Child_chain_fixture in let module C=F.C in let module D=Journal_detail in
  let fixture=F.make ~task_state:child_status_a () in
  List.iter(fun(chain,index)->
    let expected=F.W.encode_durable_intent(C.stage_intent fixture.session(C.stage chain index) |> Result.get_ok) in
    let saving,_=child_identity_detail() |> fun detail->D.update_child_source detail fixture.command.source
      |> fun detail->D.set_child_task detail child_status_a |> child_identity_append in
    let saving=D.retain_child_chain saving ~command:fixture.command chain in
    require(Option.exists(fun retained->retained==chain)(D.child_chain saving ~command:fixture.command))
      "Saving Child did not retain its bound pure chain";
    let retained=D.retain_composer saving |> Option.get |> D.interrupt_retained_composer in
    require(Option.exists(fun retained->retained==chain)(D.retained_child_chain retained ~command:fixture.command))
      "interruption discarded the original Child stage";
    let reopened=D.restore_composer(child_identity_detail())retained |> fun detail->D.set_child_task detail child_status_b in
    let _,request=D.retry reopened in
    let command=Option.get request |> child_command in
    let chain=D.child_chain reopened ~command |> Option.get in
    let chain=C.retarget chain ~command
      ~resolved_status:(match child_status_b with Status value->Some(F.G.Uuid.of_string value |> Result.get_ok)|_->assert false)
      |> Result.get_ok in
    let chain,action=C.retry chain in
    let _,_,wire=F.write fixture chain action in
    require(wire=expected)
      "Child reopening replaced an accepted wire/precondition before reconciling it")
    (child_unknown_stages fixture)
;;

let test_child_retained_chain_generated_roundtrips () =
  let module F=Child_chain_fixture in let module C=F.C in let module D=Journal_detail in
  let run stage actions =
    let fixture=F.make ~task_state:child_status_a () in
    let chain,index=List.nth(child_unknown_stages fixture)stage in
    let expected=(F.W.encode_durable_intent(C.stage_intent fixture.session(C.stage chain index) |> Result.get_ok)) in
    let saving,_=child_identity_detail() |> fun detail->D.update_child_source detail fixture.command.source
      |> fun detail->D.set_child_task detail child_status_a |> child_identity_append in
    let current=ref(D.retain_child_chain saving ~command:fixture.command chain
      |> fun detail->D.fail detail ~message:"Unknown original Child") in
    List.iter(fun action->
      let before= !current in
      current:=(match action mod 6 with
        | 0->let draft=D.retain_composer before |> Option.get |> D.interrupt_retained_composer in
          D.restore_composer(child_identity_detail())draft
        | 1->D.set_child_task before (if (action/6) mod 3=0 then Journal_model.No_status
            else if (action/6) mod 3=1 then child_status_a else child_status_b)
        | 2->D.update_child_source before "Do not replace accepted source"
        | 3->let saving,_=D.retry before in D.fail saving ~message:"Still unknown"
        | 4->let draft=D.retain_composer before |> Option.get in
          let foreign=D.create ~session_number:5531L
            {root=block ~id:"70000000-0000-4000-a000-000000005531" ();children={blocks=[];continuation=None}} in
          require(D.child_capture(D.restore_composer foreign draft)=None) "foreign Detail adopted the original chain";
          before
        | _->D.fail before ~message:"Duplicate interruption");
      let _,request=D.retry(D.fail !current ~message:"Read pending") in
      let command=Option.get request |> child_command in
      let retained=D.child_chain !current ~command |> Option.get in
      require((F.W.encode_durable_intent(C.stage_intent fixture.session(C.stage retained index) |> Result.get_ok))=expected) "retained Child acquired a new payload";
      require(command.source=fixture.command.source) "retained Child admitted source changed";
      require(command.mutation_id=fixture.command.mutation_id && command.block_id=fixture.command.block_id)
        "retained Child replaced an original identity";
      let _,previous_request=D.retry(D.fail before ~message:"Old snapshot") in
      require(previous_request<>None) "later transition mutated an old pending owner")actions in
  let fails stage actions=try run stage actions;false with _->true in
  let rec shrink stage actions=
    let rec remove prefix=function
      | []->actions
      | _::rest when fails stage(List.rev_append prefix rest)->shrink stage(List.rev_append prefix rest)
      | item::rest->remove(item::prefix)rest in remove [] actions in
  for seed=0 to 99 do
    let random=Random.State.make[|0xC105E;seed|] in
    let actions=List.init 60(fun _->Random.State.int random 60) in
    let stage=seed mod 2 in
    if fails stage actions then fail "Child retained wire seed=%d stage=%d minimized=[%s]" seed stage
      (String.concat ";" (List.map string_of_int(shrink stage actions)))
  done
;;

let test_child_chain_frozen_unknown_choice () =
  let module F=Child_chain_fixture in let module C=F.C in
  let fixture=F.make ~task_state:child_status_a () in
  let insertion,insert_index,insert_round,_=F.bind fixture fixture.initial fixture.action in
  let unknown,action=C.receive insertion ~index:insert_index ~round:insert_round F.W.Outcome_unknown in
  require(match action with C.Write(0,_)->F.W.encode_durable_intent(C.stage_intent fixture.session(C.stage unknown 0) |> Result.get_ok)=F.W.encode_durable_intent(C.stage_intent fixture.session(C.stage insertion 0) |> Result.get_ok)|_->false) "unknown insertion did not recover its original wire";
  let retried,retry=C.retry unknown in
  child_equal (let _,_,wire=F.write fixture fixture.initial fixture.action in wire) (let _,_,wire=F.write fixture retried retry in wire)
    "unknown retry rebuilt frozen parent/scope preconditions";
  let old,action=C.receive retried ~index:insert_index ~round:insert_round F.W.Outcome_unknown in
  require(old==retried && action=C.Ignore) "old insertion callback changed the retried phase";
  let inserted,parent=F.confirm fixture retried retry in
  let inserted,status_a=F.flush_prefix fixture inserted parent in
  require(match status_a with C.Write(1,_)->true|_->false)
    "equal status skipped its own mutation proof";
  let active,index,round,_=F.bind fixture inserted status_a in
  let active,_=C.receive active ~index ~round F.W.Outcome_unknown in
  let command_b={fixture.command with task_state=child_status_b;status_intent_revision=1L} in
  let status_b=match child_status_b with Journal_model.Status id->Some(F.G.Uuid.of_string id |> Result.get_ok)|_->None in
  let selected=C.retarget active ~command:command_b ~resolved_status:status_b |> Result.get_ok in
  let selected,retry_a=C.retry selected in
  child_equal (let _,_,wire=F.write fixture inserted status_a in wire) (let _,_,wire=F.write fixture selected retry_a in wire)
    "new choice replaced an unresolved status payload";
  let after_a,parent=F.confirm fixture selected retry_a in
  let after_a,write_b=F.flush_prefix fixture after_a parent in
  require(match write_b with C.Write(1,_)->true|_->false) "old status did not settle before the new choice";
  let active,index,round,_=F.bind fixture after_a write_b in
  let active,_=C.receive active ~index ~round F.W.Outcome_unknown in
  let command_a2={fixture.command with status_intent_revision=2L} in
  let status_a_uuid=match child_status_a with Journal_model.Status id->Some(F.G.Uuid.of_string id |> Result.get_ok)|_->None in
  let selected=C.retarget active ~command:command_a2 ~resolved_status:status_a_uuid |> Result.get_ok in
  let selected,retry_b=C.retry selected in
  let after_b,parent=F.confirm fixture selected retry_b in
  let after_b,write_a2=F.flush_prefix fixture after_b parent in
  let _,_,first_wire=F.write fixture inserted status_a and _,_,second_wire=F.write fixture after_b write_a2 in
  require(first_wire<>second_wire) "A to B to A reused the original status intent";
  require(Result.is_error(C.retarget after_b ~command:{command_a2 with source="Replace accepted body"}
    ~resolved_status:status_a_uuid)) "child retarget replaced the frozen insertion body"
;;

let test_child_chain_ack_failure_keeps_proofs () =
  let module F=Child_chain_fixture in let module C=F.C in
  let fixture=F.make ~task_state:child_status_a () in
  let inserted,parent=F.confirm fixture fixture.initial fixture.action in
  let inserted,status=F.flush_prefix fixture inserted parent in
  let confirmed,parent=F.confirm fixture inserted status in
  let applied,ack=F.applied fixture confirmed parent in
  let index,round=match ack with C.Acknowledge(index,round,_,_)->index,round|_->fail "UI applied chain did not ACK" in
  child_equal 1 index "a successful insertion ACK was sent again";
  let failed,_=C.acknowledged applied ~index ~round (Error "Synthetic release/ACK failure") in
  let retried,write=C.retry failed in
  child_equal (let _,_,wire=F.write fixture inserted status in wire) (let _,_,wire=F.write fixture retried write in wire)
    "ACK failure replay changed the original status preconditions";
  let stale,action=C.acknowledged retried ~index ~round (Ok()) in
  require(stale==retried && action=C.Ignore) "old ACK completed a new retry round";
  let confirmed,parent=F.confirm fixture retried write in
  let applied,ack=F.applied fixture confirmed parent in
  let index,round=match ack with C.Acknowledge(index,round,_,_)->index,round|_->fail "remaining cleanup missing" in
  child_equal 1 index "a successful insertion ACK was sent again";
  let completed,action=C.acknowledged applied ~index ~round (Ok()) in
  require(action=C.Complete) "all child stages did not settle";
  let same,action=C.retry completed in
  require(same==completed && action=C.Ignore) "completed child was replayed"
;;

(* Capacity belongs to the public SDK coordinator, so this regression composes
   the two pure owners rather than injecting a synthetic refusal into business. *)
let test_child_chain_sdk_capacity_progress () =
  let module F=Child_chain_fixture in let module B=F.C in
  let module K=Journal_worker_coordination.Worker_pure_coordinator in
  let module Id=Journal_worker_ids in
  let fixture=F.make() in
  let client=F.G.Uuid.of_string "98000000-0000-4000-8000-000000005515" |> Result.get_ok in
  let boot=K.step(K.initial ~client_id:client)(Worker_bound fixture.binding) in
  let core=ref(K.step boot.next(Bootstrap_received(fixture.binding,F.W.Ready fixture.projection))).next in
  let serial=ref 0L and acknowledgements=ref 0 in
  let run : type a. a F.W.request -> a -> unit = fun operation value ->
    match K.request !core fixture.session operation with
    | Error error->fail "Child stalled at actual SDK capacity after %Ld attempts: %s" !serial
        (match error with F.W.Invalid_input message->message|_->"other refusal")
    | Ok(ticket,transition)->
      serial:=Int64.succ !serial;
      core:=transition.next;
      core:=(K.step !core(Admitted(ticket,Id.Worker.Request_id.of_int64 !serial))).next;
      core:=(K.step !core(Completed(ticket,F.W.Answered(Ok value)))).next;
      core:=(K.step !core(Forget ticket)).next in
  let state=ref fixture.initial and action=ref fixture.action in
  for n=1 to 70 do
    let bound,index,round,intent=F.bind fixture !state !action in
    run(match intent with F.W.Append_intent intent->F.W.Append intent|Mutation_intent intent->F.W.Mutate intent)F.W.Outcome_unknown;
    let unknown,_=B.receive bound ~index ~round F.W.Outcome_unknown in
    let selected=if n mod 2=0 then child_status_a else child_status_b in
    let resolved=match selected with Journal_model.Status id->Some(F.G.Uuid.of_string id |> Result.get_ok)|_->None in
    let command={(B.command unknown) with task_state=selected;status_confirmation=true;
      status_intent_revision=Int64.of_int n} in
    let selected=B.retarget unknown ~command ~resolved_status:resolved |> Result.get_ok in
    let selected,retry=B.retry selected in
    let bound,index,round,intent=F.bind fixture selected retry in
    let progress=fixture.confirm index intent fixture.presentation in
    let confirmation=match progress with F.W.Confirmed value->value|_->assert false in
    let receipt=F.W.confirmation_receipt confirmation in
    run(match intent with F.W.Append_intent intent->F.W.Append intent|Mutation_intent intent->F.W.Mutate intent)(F.W.Committed_pending_presentation receipt);
    run(F.W.Confirm(fixture.presentation,receipt))progress;
    let next,out=B.receive bound ~index ~round progress in
    let rec drain fuel state action =
      require(fuel>0) "child prefix settlement did not terminate";
      match action with
      | B.Write _->state,action
      | Read_parent(round,_)->
        let next,action=B.projection_ready state ~round in drain(fuel-1)next action
      | Present round->
        let next,action=B.applied state ~round fixture.presentation in drain(fuel-1)next action
      | Acknowledge(index,round,intent,_)->
        run(F.W.Acknowledge_intent intent)();incr acknowledgements;
        let next,action=B.acknowledged state ~index ~round(Ok()) in drain(fuel-1)next action
      | Read_child round->
        let summary=match F.W.confirmation_primary confirmation with
          | Confirmed_block value->value|_->assert false in
        let next,action=B.read_child state ~round summary in drain(fuel-1)next action
      | Wait message->fail "child prefix stopped instead of settling: %s" message
      | Ignore|Complete->fail "pending newer child choice was discarded" in
    let next,out=drain 16 next out in
    state:=next;action:=out
  done;
  require(!acknowledgements>=70) "child kept unconsumed prefixes until exhausting the SDK ledger"
;;

let test_child_rejected_status_rebound_canonical () =
  let module F=Child_chain_fixture in let module C=F.C in
  let fixture=F.make ~task_state:child_status_a () in
  let inserted,parent=F.confirm fixture fixture.initial fixture.action in
  let inserted,status=F.flush_prefix fixture inserted parent in
  let bound,index,round,_=F.bind fixture inserted status in
  let rejected,read=C.receive bound ~index ~round (F.W.Rejected(Service_failed "Known status rejection")) in
  let read_round=match read with C.Read_child round->round|_->fail "status rejection lost canonical read" in
  let parent,action=C.read_child rejected ~round:read_round(Option.get(C.canonical rejected)) in
  let applied,ack=F.applied fixture parent action in
  let index,round,intent=match ack with C.Acknowledge(i,r,intent,_)->i,r,intent|_->fail "status rejection lost ACK" in
  let rebound=C.rebind_ack applied ~index ~round ~intent ~presentation:fixture.presentation |> Option.get in
  let rejected,action=C.receive rebound ~index ~round(F.W.Rejected(Service_failed "Known status rejection")) in
  let round=match action with C.Read_child round->round|_->fail "rebound rejection lost canonical read" in
  let parent,action=C.read_child rejected ~round(Option.get(C.canonical rejected)) in
  let applied,action=F.applied fixture parent action in
  let index,round=match action with C.Acknowledge(i,r,_,_)->i,r|_->fail "rebound canonical never reached ACK" in
  let settled,done_=C.acknowledged applied ~index ~round(Ok())in
  require(done_=C.Complete) "rebound status rejection remained stuck";
  let _,again=C.retry settled in
  require(again=C.Ignore) "acknowledged rejected status retained a creating/retry obligation"
;;

let test_child_chain_generated_traces ?(append=false) () =
  let module F=Child_chain_fixture in let module C=F.C in
  let run actions =
    let fixture=F.make ~append ~task_state:child_status_a () in
    let foreign=Coordination_test_fixture.fixture ~graph:(F.G.Uuid.of_string "98000000-0000-4000-8000-000000008891" |> Result.get_ok) 8891L |> fun (_,_,p,_)->Option.get(F.W.selected p) in
    let state=ref fixture.initial and action=ref fixture.action in
    let revision=ref 0 and frozen=Hashtbl.create 8 in
    let take transition =
      let before= !state in
      let snapshot=Marshal.to_string before [] in
      let next,out=transition before and again,out2=transition before in
      require(next=again && out=out2) "child transition is nondeterministic";
      require(snapshot=Marshal.to_string before []) "child transition mutated its input";
      state:=next;action:=out in
    List.iter(fun n ->
      match n mod 8 with
      | 0 ->
        incr revision;
        let task_state=if !revision mod 2=0 then child_status_a else child_status_b in
        let resolved_status=match task_state with Journal_model.Status id->Some(F.G.Uuid.of_string id |> Result.get_ok)|_->None in
        let command={(C.command !state) with task_state;status_confirmation=true;status_intent_revision=Int64.of_int !revision} in
        (match C.retarget !state ~command ~resolved_status with Ok next->state:=next|Error _->())
      | 1 -> take C.retry
      | 2 ->
        let before= !state in
        let same,out=C.applied before ~round:0L fixture.presentation in
        require(same==before && out=C.Ignore) "obsolete UI application changed lifecycle"
      | _ -> match !action with
        | C.Write(index,round) ->
          let wire=F.W.encode_durable_intent(C.stage_intent fixture.session(C.stage !state index) |> Result.get_ok) in
          let id=C.stage_id(C.stage !state index) |> F.G.Uuid.to_string in
          (match Hashtbl.find_opt frozen id with None->Hashtbl.add frozen id wire
           |Some previous->require(previous=wire) "one child intent acquired a different payload");
          let intent=C.stage_intent fixture.session (C.stage !state index) |> Result.get_ok in
          state:=C.bind !state ~index ~round ~intent ~presentation:fixture.presentation |> Option.get;
          require(C.bind !state ~index ~round ~intent ~presentation:foreign=None)
            "foreign logical graph bound a child stage";
          state:=C.bind !state ~index ~round ~intent ~presentation:fixture.presentation |> Option.get;
          let progress=if n mod 5=0 then F.W.Outcome_unknown
            else if n mod 7=0 then F.W.Rejected(Service_failed "Generated noncommit")
            else fixture.confirm index intent fixture.presentation in
          take(fun state->C.receive state ~index ~round progress)
        | Read_parent(round,_) ->take(fun state->C.projection_ready state ~round)
        | Read_child round ->take(fun state->C.read_child state ~round(Option.get(C.canonical state)))
        | Present round ->take(fun state->C.applied state ~round fixture.presentation)
        | Acknowledge(index,round,_,_) ->
          take(fun state->C.acknowledged state ~index ~round
            (if n mod 5=0 then Error "Generated ACK interruption" else Ok()))
        | Wait _ | Ignore ->take C.retry
        | Complete ->
          let same,out=C.retry !state in
          require(same== !state && out=C.Ignore) "terminal child resurrected") actions in
  let fails actions=try run actions;false with _->true in
  let rec shrink actions =
    let rec remove prefix=function
      | []->actions
      | _::rest when fails(List.rev_append prefix rest)->shrink(List.rev_append prefix rest)
      | x::rest->remove(x::prefix)rest in remove [] actions in
  for seed=0 to 199 do
    let random=Random.State.make[|0xC111;seed|] in
    let actions=List.init 80(fun _->Random.State.int random 80) in
    if fails actions then (
      let minimal=shrink actions in
      let cause=try run minimal;"unknown" with error->Printexc.to_string error in
      fail "Child lifecycle seed=%d minimized=[%s]: %s" seed
        (minimal |> List.map string_of_int |> String.concat ";") cause)
  done
;;

let test_child_known_rejection_is_terminal () =
  let module F=Child_chain_fixture in let module C=F.C in
  let fixture=F.make() in
  let bound,index,round,_=F.bind fixture fixture.initial fixture.action in
  let rejected,action=C.receive bound ~index ~round (F.W.Rejected(Service_failed "Known not applied")) in
  require(action=C.Present round) "known rejection must reach its UI consumer";
  let applied,ack=C.applied rejected ~round fixture.presentation in
  let index,round=match ack with C.Acknowledge(index,round,_,_)->index,round|_->fail "known rejection did not ACK" in
  let completed,action=C.acknowledged applied ~index ~round (Ok()) in
  require(action=C.Complete) "known rejection did not settle";
  let same,action=C.retry completed in
  require(same==completed && action=C.Ignore) "settled non-insertion was replayed as the same logical action";
  require(Result.is_error(C.retarget completed ~command:{fixture.command with
    task_state=child_status_a;status_confirmation=true;status_intent_revision=1L}
    ~resolved_status:(match child_status_a with Journal_model.Status id->Some(F.G.Uuid.of_string id |> Result.get_ok)|_->None)))
    "settled non-insertion adopted a new child choice"
;;


let tests =
  [ "Child generated lifecycle traces",(fun ()->test_child_chain_generated_traces ())
  ; "Rejected child status rebind reaches canonical ACK",test_child_rejected_status_rebound_canonical
  ; "Child prefixes progress through actual SDK capacity",test_child_chain_sdk_capacity_progress
  ; "Known child non-insertion is terminal",test_child_known_rejection_is_terminal
  ; "Child chain freezes unknown writes and status choices",test_child_chain_frozen_unknown_choice
  ; "Child chain ACK failure retains original proofs",test_child_chain_ack_failure_keeps_proofs
  ; "Uncertain plain child preserves insertion identity",test_uncertain_plain_child_keeps_identity
  ; "Child reselected status is a distinct sub-operation",test_child_reselected_status_intent
  ; "Retained child status preserves its admitted owner",test_retained_child_status_keeps_frozen_attempt
  ; "Child choice retained/retry pure generated traces",test_child_choice_traces
  ; "pure Root cleanup plan contract", test_root_cleanup_plan_contract
  ; "staging adapter guard and failures", test_staged_file_adapter_guard_and_failures
  ; "Page append exact page ownership", test_page_detail_append_matches_exact_page
  ; ( "Initial staging refresh and delete review regressions"
    , test_initial_staging_refresh_and_delete )
  ]
  @ [ ( "Detail bounded initial nested body staging"
      , test_detail_initial_nested_body_staging )
    ]
  @ [ ( "Detail initial loading delay and ownership"
      , test_detail_initial_loading_delay_and_ownership )
    ]
  @ [ "Unicode blank Capture admission", test_unicode_blank_capture_admission ]
  @ [ "PR63 public review regressions", test_followup_review_regressions ]
  @ [ ( "projected unknown children are read once"
      , test_projected_unknown_children_are_read_once )
    ; ( "Detail default ten levels and cycle boundaries"
      , test_detail_default_outline_depth_and_cycle_boundaries )
    ; ( "Detail serialized reads and retry feedback"
      , test_detail_serial_reads_and_retry_feedback )
  ] @
  [ ( "retained picker and terminal delete"
    , test_retained_detail_picker_owner_and_terminal_delete )
  ; "typed path prefix and loading owners", test_typed_path_prefix_and_loading_owners
  ; "multiselect batch boundary", test_multiselect_batch_boundary
    ; ( "multiselect order duplicates and readd"
      , test_multiselect_order_duplicates_and_readd )
  ; ( "multiselect rejected resource ownership"
    , test_multiselect_rejected_resource_ownership )
  ; "multiselect graph owner and cancel", test_multiselect_graph_owner_and_cancel
  ; "typed covered failure and branch", test_typed_covered_failure_missing_and_branch
  ; "typed shared data and committed deletion", test_typed_shared_data_delete_and_drafts
    ; ( "typed duplicate detached mutations"
      , test_typed_detached_duplicate_pending_mutations )
  ; "public nested detail owners", test_public_nested_detail_owners
  ; ( "normal attachment pick without replacement metadata"
    , test_normal_attachment_pick_needs_no_replacement_metadata )
  ; "detail no-op route owner", test_detail_noop_completion_retains_route_owner
  ; "root no-op observable owner", test_root_noops_preserve_observable_owner
  ; ( "Append restarts partial children"
    , test_append_restarts_partial_children_without_reusing_cursor )
  ; ( "child refresh replaces opaque cursor"
    , test_child_refresh_replaces_cursor_and_fences_pending_read )
  ; "hidden favorites pagination", test_favorites_hidden_rows_do_not_block_pagination
    ; ( "automatic outline reads are bounded and idempotent"
      , test_automatic_outline_reads_are_bounded_and_idempotent )
    ; ( "Detail 128-item pages preserve order"
      , test_detail_128_item_pages_preserve_order_and_completion )
  ; "Detail retry uses 128-item first page", test_detail_retry_uses_128_item_first_page
  ; "Append editor session after save", test_append_editor_session_after_save
  ; ( "Capture editor sessions are never reused"
    , test_capture_editor_sessions_are_not_reused )
    ; "retained task Append recovery", test_retained_task_append_keeps_recovery_identity
    ; ( "task Append failure retains insertion identity"
      , test_failed_task_append_retains_identity )
    ; ( "failed Append editing and late completion"
    , test_uncertain_append_keeps_original_attempt )
  ; ( "late Capture completion preserves newer edit"
    , test_late_capture_completion_preserves_newer_edit )
  ; "retained graph Append owner", test_graph_retained_append_owner
  ; "graph draft retention and privacy", test_graph_draft_retention_and_privacy
  ; ( "graph interruption preserves Capture attempt"
    , test_graph_interruption_preserves_capture_attempt )
    ; ( "Append drafts follow parent navigation"
      , test_append_drafts_follow_parent_navigation )
    ; ( "detached Append completion and failure"
      , test_detached_append_completion_and_failure )
    ; ( "favorite target identity, origin and deletion"
      , test_favorite_target_origin_and_delete )
  ; ( "detail rejects another root even with matching generation"
    , fun () ->
        let routes =
          Journal_routes.create ()
          |> fun routes ->
          Journal_routes.select_destination routes Favorites
          |> fun routes ->
          Journal_routes.open_detail
            routes
            ~block_id:"70000000-0000-4000-a000-000000000001"
            ~request_generation:40L
        in
        let wrong =
          detail ~root:(block ~id:"70000000-0000-4000-a000-000000000002" ()) ()
        in
        let routes =
          Journal_routes.apply_detail_response routes ~request_generation:40L wrong
        in
        require
          (Journal_routes.route routes = Detail_loading)
          "completion for another root replaced the requested block";
        let returned = Journal_routes.back routes in
        require
          (Journal_routes.destination returned = Favorites)
          "loading Back lost Favorites origin" )
  ; ( "favorites isolated cache and refresh reducer"
    , test_favorites_state_isolates_requests_and_refreshes )
  ; ( "Favorites retains large typed pages", test_favorites_retains_large_typed_pages )
  ; ( "direct Capture source and mutation identity"
    , test_direct_capture_preserves_source_and_mutation_identity )
  ; "direct Capture pending attachments", test_direct_capture_pending_attachments
  ; ( "direct Capture task intent lifecycle"
    , test_direct_capture_task_intent_survives_edit_failure_and_retry )
  ; "outline branches, append and subtree Undo", test_outline_branches_append_and_delete
  ; ( "route generation, background, and runtime replacement"
    , test_route_generation_background_and_runtime_replacement )
  ]
;;


let test_resident_focus_preserves_graph_drafts_and_saving () =
  let module R=Root_state in
  let id n=Logseq_db_types.Graph_types.Uuid.of_string (Printf.sprintf "77777777-7777-4777-8777-%012d" n) |> Result.get_ok in
  require (R.next_graph ~current:(id 1) [id 1]=None) "one graph intercepted cycle";
  require (R.next_graph ~current:(id 2) [id 1;id 2]=Some(id 1)) "two graph wrap failed";
  require (R.next_graph ~current:(id 3) [id 1;id 2;id 3]=Some(id 1)) "three to one wrap failed";
  let focus state n=R.step state (Graph_focused {generation=n;graph_id=id n}) in
  let one=focus (R.create ~graph_generation:1) 1 |> fun s->R.step s Capture_opened
    |> fun s->R.step s (Capture_edited "draft one") in
  let two=focus one 2 |> fun s->R.step s Capture_opened |> fun s->R.step s (Capture_edited "draft two") in
  let three=focus two 3 |> fun s->R.step s Capture_opened |> fun s->R.step s (Capture_edited "draft three") in
  List.iter (fun (n,text)->
    let restored=focus three n in
    require (Option.map Journal_capture.source (R.capture restored)=Some text) "resident draft crossed or disappeared")
    [1,"draft one";2,"draft two";3,"draft three"];
  let capture=Option.get (R.capture one) in
  let saving,request=Journal_capture.admit_save capture
    ~mutation_id:"77777777-7777-4777-9777-000000000001"
    ~block_id:"77777777-7777-4777-a777-000000000001" ~sibling_order:"z"
    ~calendar_generation:1L ~creation_time:(creation_time 1) in
  require (Option.is_some request) "saving fixture did not admit";
  let saving=R.step one (Capture_admitted saving) in
  let returned=focus (focus saving 2) 1 in
  require (Option.map Journal_capture.phase (R.capture returned)=Some Journal_capture.Saving)
    "visible focus interrupted in-flight Capture";
  let cleared=R.step three Account_cleared in
  require (R.capture (focus cleared 1)=None) "logout retained resident draft"
let tests=tests @ ["resident focus keeps per-graph drafts and pending Capture",test_resident_focus_preserves_graph_drafts_and_saving]
;;
let () = test_detail_page_keeps_newer_point_content ()
let () = test_observed_absence_does_not_commit_user_deletion ()
let () = test_detail_observation_binding_revocation_is_visible ()
let () = test_detail_observation_generated_lifetimes ()
let () = test_detail_observation_failure_recovers_same_handle ()
let () = test_detail_observation_ticket_has_one_context_owner ()
let () = test_detail_observation_context_retains_empty_and_releases ()
let () = test_detail_observation_failure_and_pending_cancel ()
let () = test_child_retained_chain_generated_roundtrips ()
let () = test_child_retained_chain_survives_projection_reopen ()
let () = test_child_oversize_is_editable_before_admission ()
let () = test_capture_retained_attempt_survives_runtime_reset ()
let () = test_capture_chain_freezes_complete_payload ()
let () = test_capture_oversize_is_editable_before_admission ()
let () = test_child_chain_generated_traces ~append:true ()
let () = test_append_chain_uses_canonical_journal_owner ()
let () = test_native_composer_dismissal_and_edit_fences ()
let () = test_collapse_retains_complete_capture ()

let () =
  List.iter
    (fun (name, test) ->
       Printf.printf "running %s\n%!" name;
       test ())
    tests
;;

(* The pure insertion reducer receives an already resolved choice. A catalog
   update between Runtime planning and binding is owned by this public Runtime
   boundary, and cannot be reproduced by giving the pure reducer bad input. *)
let () =
  let module R=Journal_graph_runtime in let module F=Child_chain_fixture in
  let fixture=F.make ~append:true () in
  let runtime=R.create ~localtime:Unix.gmtime () in
  let sampler=Journal_calendar.Sampler.create
    ~clock:(fun()->Int64.to_float(Journal_time.instant_unix_ms fixture.command.creation_time)/.1000.)
    ~localtime:Unix.gmtime () in
  let calendar=Journal_calendar.Sampler.sample sampler |> Result.get_ok in
  R.set_calendar runtime calendar;
  let only output=match output.R.requests with [request]->request|_->fail "expected one Runtime request" in
  let status_a=F.G.Uuid.of_string "00000002-1615-5853-7700-000000000000" |> Result.get_ok in
  let status_b=F.G.Uuid.of_string "00000002-1827-5820-8200-000000000000" |> Result.get_ok in
  let issuer,_,_,catalog_session=Coordination_test_fixture.fixture 9901L in
  let module I=(val issuer:Worker_effect_authority.ISSUER) in
  let catalog status=
    let request=R.submit runtime Journal_graph_request.Load_task_statuses |> only in
    let item uuid:F.G.task_status_definition={uuid;title=F.G.Uuid.to_string uuid;ident=None;order="a";checkbox_state=None} in
    match R.worker_read runtime request with
    |Some(R.Read read)->
      let budget=F.W.read_budget catalog_session ~maximum_items:read.maximum_items ~maximum_bytes:65536 |> Result.get_ok in
      let operation=F.W.Query(budget,read.query) in
      let response=match I.request catalog_session ~request_id:(F.W.request_id request) operation |> Result.get_ok with
        |Logseq_db_worker_lui.Logseq_db_worker_lui_service.Coordination_query source->
          let answer=match read.query with
            |F.W.Task_statuses _->Worker_pure_read.For_worker.answer budget read.query
              (Ok(Worker_pure_read.For_worker.task_status_catalog ~property_uuid:None ~default_status:(Some status)
                ~items:[item status_a;item status_b] ~next:None))
            |_->failwith "catalog fixture changed query"in
          Logseq_db_worker_lui.Logseq_db_worker_lui_service.Coordination_queried{registration=source.registration;
            owner=source.owner;request_id=source.request_id;answer}
        |_->failwith "catalog fixture changed request"in
      (match I.reply catalog_session ~request_id:(F.W.request_id request) operation response with
       |Ok(F.W.Answered(Ok value))->ignore(R.receive_worker_read runtime ~request_id:request (R.Query_result(read.query,value)))
       |_->failwith "catalog fixture rejected its typed value")
    |_->failwith "catalog fixture lost its typed query" in
  catalog status_a;
  let command:Journal_graph_projection.capture={mutation_id=fixture.command.mutation_id;
    block_id=fixture.command.block_id;sibling_order=fixture.command.sibling_order;
    source=fixture.command.source;task_state=Journal_model.Default_status;creation_time=fixture.command.creation_time;
    children=[];status_confirmation=false;status_intent_revision=0L} in
  let request=R.submit runtime(Capture{calendar_generation=Journal_calendar.generation calendar;command}) |> only in
  let intent=R.worker_intent runtime request fixture.session |> Result.get_ok in
  let wire=F.W.encode_durable_intent intent in
  let expected=F.W.append_intent fixture.session ~mutation_id:(F.G.Uuid.of_string command.mutation_id |> Result.get_ok)
    ~block_id:(F.G.Uuid.of_string command.block_id |> Result.get_ok)
    ~day:(F.W.journal_day(Journal_time.local_day command.creation_time) |> Result.get_ok)
    ~title:command.source ~task_status:(Some status_a) ~children:Rrbvec.empty |> Result.get_ok in
  require(wire=F.W.encode_durable_intent(F.W.Append_intent expected)) "initial Append did not freeze the resolved default";
  catalog status_b;
  require(F.W.encode_durable_intent(R.worker_intent runtime request fixture.session |> Result.get_ok)=wire) "catalog update replaced the planned atomic payload";
  require(R.bind_mutation runtime request ~presentation:fixture.presentation ~intent)
    "catalog update re-resolved and rejected the already frozen default"
;;

let () =
  let module F=Child_chain_fixture in let module C=F.C in
  let fixture=F.make ~task_state:child_status_a () in
  let inserted,index,round,_=F.bind fixture fixture.initial fixture.action in
  let unknown,_=C.receive inserted ~index ~round F.W.Outcome_unknown in
  let command={fixture.command with task_state=Journal_model.No_status;
    status_confirmation=true;status_intent_revision=1L} in
  let selected=C.retarget unknown ~command ~resolved_status:None |> Result.get_ok in
  let selected,retry=C.retry selected in
  require(let _,_,wire=F.write fixture selected retry and _,_,original=F.write fixture fixture.initial fixture.action in wire=original)
    "explicit Clear replaced the unknown original insertion";
  let confirmed,parent=F.confirm fixture selected retry in
  let cleared,action=F.flush_prefix fixture confirmed parent in
  let _,_,wire=F.write fixture cleared action in
  let block=F.G.Uuid.of_string command.block_id |> Result.get_ok in
  let expected=F.W.mutation_intent fixture.session ~mutation_id:(C.stage_id(C.stage cleared 1))
    (F.W.Clear_task_status{block;preconditions={blocks=[block,"child-state:v1:0"];pages=[];scopes=[]}}) |> Result.get_ok in
  require(wire=F.W.encode_durable_intent(F.W.Mutation_intent expected))
    "No status after an uncertain insert skipped the real explicit Clear stage";
  let bound,index,round,_=F.bind fixture cleared action in
  let unknown,_=C.receive bound ~index ~round F.W.Outcome_unknown in
  let unknown,retry=C.retry unknown in
  require(let _,_,actual=F.write fixture unknown retry in actual=wire)
    "unknown Clear retry replaced its original immutable payload"
;;


(* The insertion reducer owns bounded recovery; UI callbacks do not decide retries. *)
let test_insertion_recovers_without_user_retry () =
  let module F=Child_chain_fixture in let module C=F.C in
  List.iter(fun interrupted ->
    let fixture=F.make () in
    let state,index,round,intent=F.bind fixture fixture.initial fixture.action in
    let snapshot=Marshal.to_string state [] in
    let next,action=if interrupted then C.interrupted state ~index ~round "Local reply unavailable"
      else C.receive state ~index ~round F.W.Outcome_unknown in
    let i,r,wire=F.write fixture next action in
    require(wire=(F.W.encode_durable_intent(C.stage_intent fixture.session(C.stage state index) |> Result.get_ok)) && i=index && r>round)
      "background recovery changed the original insertion";
    require(snapshot=Marshal.to_string state []) "background recovery mutated its input";
    let same,late=C.receive next ~index ~round F.W.Outcome_unknown in
    require(same==next && late=C.Ignore) "late original completion restarted recovery";
    let next=C.bind next ~index:i ~round:r ~intent ~presentation:fixture.presentation |> Option.get in
    let _,again=C.receive next ~index:i ~round:r F.W.Outcome_unknown in
    require(match again with C.Wait _->true|_->false) "persistent local error entered an automatic loop";
    let confirmed,parent=F.confirm fixture next action in
    let _,done_=F.flush_prefix fixture confirmed parent in
    require(done_=C.Complete) "same intent did not settle after background recovery") [false;true]
;;
let () = test_insertion_recovers_without_user_retry ()

let test_insertion_recovery_budgets_follow_stages () =
  let module F=Child_chain_fixture in let module C=F.C in
  let fixture=F.make ~task_state:child_status_a () in
  let bound,index,round,_=F.bind fixture fixture.initial fixture.action in
  let recovering,wire=C.receive bound ~index ~round F.W.Outcome_unknown in
  let confirmed,parent=F.confirm fixture recovering wire in
  let applied,ack=F.applied fixture confirmed parent in
  let index,round=match ack with C.Acknowledge(index,round,_,_)->index,round|_->fail "missing insertion ACK" in
  let recovering,wire=C.acknowledged applied ~index ~round (Error "Transient local ACK failure") in
  ignore(F.write fixture recovering wire);
  let confirmed,parent=F.confirm fixture recovering wire in
  let progressed,status=F.flush_prefix fixture confirmed parent in
  let bound,index,round,_=F.bind fixture progressed status in
  let _,wire=C.receive bound ~index ~round F.W.Outcome_unknown in
  require(match wire with C.Write(1,_)->true|_->false) "prior insertion recovery exhausted a distinct status stage"
;;
let () = test_insertion_recovery_budgets_follow_stages ()

let source_recovery_fixture () =
  let module W=Journal_worker_coordination.Worker_api in
  let module C=Journal_worker_coordination.Worker_pure_coordinator in
  let fixture=Child_chain_fixture.make()in
  let ready=(C.step (C.step(C.initial ~client_id:(W.Uuid.of_string "70000000-0000-4000-9000-000000005590" |> Result.get_ok))
    (C.Worker_bound fixture.binding)).next (C.Bootstrap_received(fixture.binding,W.Ready fixture.projection))).next in
  let source:Logseq_db_types.Asset_import.t={operation=W.Uuid.of_string "70000000-0000-4000-9000-000000005591" |> Result.get_ok;
    asset=W.Uuid.of_string "70000000-0000-4000-9000-000000005592" |> Result.get_ok;
    target=W.Uuid.of_string fixture.command.block_id |> Result.get_ok;replace_reference=None;
    local_mutation=W.Uuid.of_string "70000000-0000-4000-9000-000000005593" |> Result.get_ok;
    metadata_mutation=W.Uuid.of_string "70000000-0000-4000-9000-000000005594" |> Result.get_ok;
    source_file="/isolated/synthetic-source.png";title="Synthetic source";file_type="png"}in
  let intent=W.asset_import_intent fixture.session source |> Result.get_ok in
  ready,intent
;;
let test_source_lookup_completion_after_owner_retirement () =
  let module M=Journal_worker_coordination_host.Pure_source_recovery in
  let ready,intent=source_recovery_fixture()in
  let state,reads=M.plan M.empty ready(Rrbvec.singleton intent)in
  require(Rrbvec.length reads=1) "pending source did not plan one read";
  let read=Rrbvec.nth reads 0 in
  let state,retired=M.plan state ready Rrbvec.empty in
  require(Rrbvec.is_empty retired) "retired source created another request";
  let _,completion=M.completed state read ~retryable:true in
  require(match completion with M.Ignored->true|_->false) "late source error must not notify a retired owner"
;;
let () = test_source_lookup_completion_after_owner_retirement ()

let test_source_recovery_generated_lifetimes () =
  let module M=Journal_worker_coordination_host.Pure_source_recovery in
  let module W=Journal_worker_coordination.Worker_api in
  let ready,intent=source_recovery_fixture()in
  let encoded=W.encode_asset_import_intent intent in
  let run actions =
    let state=ref M.empty and active=ref true and current=ref None and old=ref [] and sent=ref 0 in
    let observe read =
      incr sent;
      require(!sent<=2) "one pending source exceeded its bounded read attempts";
      require(W.encode_asset_import_intent read.M.intent=encoded) "recovery changed the frozen input";
      current:=Some read in
    List.iter(fun action->
      let before= !state and snapshot=Marshal.to_string !state [] in
      (match action mod 5 with
       |0|1->let intents=if !active then Rrbvec.singleton intent else Rrbvec.empty in
         let next,reads=M.plan before ready intents and again,duplicates=M.plan before ready intents in
         require(Marshal.to_string next []=Marshal.to_string again []
           && Marshal.to_string reads []=Marshal.to_string duplicates []) "source planning is nondeterministic";
         state:=next;Rrbvec.iter observe reads
       |2->Option.iter(fun read->
         let next,result=M.completed before read ~retryable:(action land 8<>0)in
         state:=next;old:=read::!old;
         (match result with M.Retry read->observe read|Ignored|Settled->current:=None))!current
       |3->(match !old with []->()|read::_->
         let next,result=M.completed before read ~retryable:true in
         require(match result with M.Ignored->true|_->false) "duplicate source completion notified or retried";
         state:=next)
       |_->active:=false;state:=fst(M.plan before ready Rrbvec.empty));
      require(snapshot=Marshal.to_string before []) "source transition mutated a shared prior snapshot")actions in
  let fails actions=try run actions;false with _->true in
  let rec shrink actions =
    let rec drop prefix=function
      |[]->actions
      |_::rest when fails(List.rev_append prefix rest)->shrink(List.rev_append prefix rest)
      |action::rest->drop(action::prefix)rest in drop []actions in
  for seed=0 to 99 do
    let random=Random.State.make[|0x5011CE;seed|]in
    let actions=List.init 60(fun _->Random.State.int random 80)in
    if fails actions then fail "source recovery seed=%d minimized=[%s]" seed
      (String.concat ";"(List.map string_of_int(shrink actions)))
  done
;;
let () = test_source_recovery_generated_lifetimes ()

(* Root owns the editable buffer; its admitted submission remains immutable
   until the real settled completion supplied by Runtime. *)
let test_pending_capture_edits_keep_original_submission () =
  let module R=Root_state in
  let original="Original submission" in
  let state=root_navigation ~graph_generation:1 |> fun state->R.step state(Capture_edited original) in
  let capture,request=Journal_capture.admit_save(Option.get(R.capture state))
    ~mutation_id:"70000000-0000-4000-9000-000000005601"
    ~block_id:"70000000-0000-4000-a000-000000005601" ~sibling_order:"z"
    ~calendar_generation:1L ~creation_time:(creation_time 550)in
  let command=match Option.get request with Journal_graph_request.Capture{command;_}->command|_->assert false in
  let waiting=R.step (R.step state(Capture_admitted capture))
    (Completed{payload=Capture_waiting{command;message="Original local result is not available"}})in
  require(Journal_capture.phase(Option.get(R.capture waiting))=Journal_capture.Saving)
    "unknown creation became a separate failed/readonly UI state";
  let edited=R.step waiting(Capture_edited "Newer draft")in
  let draft=Option.get(R.capture edited)in
  require_string "Newer draft" (Journal_capture.source draft) "pending editor buffer";
  require(Journal_capture.pending_command draft=Some command) "editing rewrote the original submission";
  require(not(Journal_capture.can_save draft)) "unknown original admitted another creation";
  let completed=R.step edited(Completed{payload=Block_captured{
    block=block ~id:command.block_id ~source:original();timeline_entry_update=None}})in
  let draft=Option.get(R.capture completed)in
  require_string "Newer draft" (Journal_capture.source draft) "late submission erased the current editor";
  require(Journal_capture.pending_command draft=None && Journal_capture.can_save draft)
    "settled original did not release the edited draft";
  let duplicate=R.step completed(Completed{payload=Block_captured{
    block=block ~id:command.block_id ~source:original();timeline_entry_update=None}})in
  require(R.capture duplicate=R.capture completed) "duplicate original completion changed the new draft"
;;
let ()=test_pending_capture_edits_keep_original_submission()

let test_insertion_delayed_recovery_tokens () =
  let module F=Child_chain_fixture in let module C=F.C in
  let fixture=F.make()in
  let state,index,round,_=F.bind fixture fixture.initial fixture.action in
  let state,action=C.receive state ~index ~round F.W.Outcome_unknown in
  let state,index,round,_=F.bind fixture state action in
  let state,wait=C.receive state ~index ~round F.W.Outcome_unknown in
  require(match wait with C.Wait _->true|_->false) "exhausted immediate recovery replayed without a timer";
  let current=ref state and previous=ref None and last_delay=ref 0. in
  for _=0 to 10 do
    let snapshot=Marshal.to_string !current []in
    let armed,recovery=C.take_recovery !current in
    require(snapshot=Marshal.to_string !current []) "arming recovery mutated its old snapshot";
    let recovery=Option.get recovery in
    require(recovery.delay>= !last_delay && recovery.delay<=30.) "recovery backoff is unbounded or decreasing";
    last_delay:=recovery.delay;
    let duplicate,twice=C.take_recovery armed in
    require(twice=None && duplicate==armed) "duplicate publish created a second recovery timer";
    Option.iter(fun old->let same,ignored=C.resume_recovery armed old in
      require(same==armed && ignored=C.Ignore) "obsolete timer restarted a later attempt")!previous;
    let retrying,action=C.resume_recovery armed recovery in
    let _,_,wire=F.write fixture retrying action in
    require(wire=(F.W.encode_durable_intent(C.stage_intent fixture.session(C.stage state 0) |> Result.get_ok))) "timer replaced the original durable payload";
    let duplicate,ignored=C.resume_recovery retrying recovery in
    require(duplicate==retrying && ignored=C.Ignore) "timer fired the same attempt twice";
    let bound,index,round,_=F.bind fixture retrying action in
    let failed,wait=C.receive bound ~index ~round F.W.Outcome_unknown in
    require(match wait with C.Wait _->true|_->false) "persistent error caused an immediate retry loop";
    previous:=Some recovery;current:=failed
  done;
  require(!last_delay=30.) "background recovery never reached its capped interval"
;;
let ()=test_insertion_delayed_recovery_tokens()

let test_pending_capture_buffer_traces () =
  let module R=Root_state in
  let run actions =
    let original="Original source 中文"in
    let initial=root_navigation ~graph_generation:1 |> fun state->R.step state(Capture_edited original)in
    let capture,request=Journal_capture.admit_save(Option.get(R.capture initial))
      ~mutation_id:"70000000-0000-4000-9000-000000005602"
      ~block_id:"70000000-0000-4000-a000-000000005602" ~sibling_order:"z"
      ~calendar_generation:1L ~creation_time:(creation_time 550)in
    let command=match Option.get request with Journal_graph_request.Capture{command;_}->command|_->assert false in
    let state=ref(R.step initial(Capture_admitted capture))and expected=ref original in
    List.iteri(fun index action->
      let before= !state and snapshot=Marshal.to_string !state []in
      let current=Option.get(R.capture before)in
      let event:R.event=match action mod 5 with
        |0|1->let text=if action land 8=0 then original else Printf.sprintf "Buffer 中文 %d"index in
          expected:=text;
          let offset=Ui.Text_editing.Utf16.length text in
          Capture_native_edit(edit ~session_id:(Journal_capture.session_id current)
            ~local_revision:(Int64.succ(Journal_ids.Text_input.Local_revision.to_int64(Journal_capture.accepted_local_revision current)))
            ~base_document_revision:(Journal_ids.Text_input.Document_revision.to_int64(Journal_capture.document_revision current))
            ~text ~selection_start:offset ~selection_end:offset())
        |2->Completed{payload=Capture_waiting{command;message="Local confirmation unavailable"}}
        |3->Completed{payload=Block_captured{block=block ~id:"70000000-0000-4000-a000-000000005603"();timeline_entry_update=None}}
        |_->Capture_native_edit(edit ~session_id:(Journal_ids.Text_input.Session_id.of_int64 99999L)
          ~local_revision:1L ~base_document_revision:0L ~text:"Obsolete editor" ~selection_start:0 ~selection_end:0())in
      let next=R.step before event and again=R.step before event in
      require(Marshal.to_string next []=Marshal.to_string again []) "pending buffer transition is nondeterministic";
      state:=next;
      let current=Option.get(R.capture next)in
      require_string !expected(Journal_capture.source current) "pending buffer trace";
      require(Journal_capture.pending_command current=Some command && not(Journal_capture.can_save current))
        "pending buffer trace changed an immutable submission or admitted a new one";
      require(snapshot=Marshal.to_string before []) "pending buffer trace mutated a prior snapshot")actions;
    let completed=R.step !state(Completed{payload=Block_captured{
      block=block ~id:command.block_id ~source:original();timeline_entry_update=None}})in
    if !expected=original then require(R.capture completed=None) "unchanged submitted buffer did not finish"
    else let draft=Option.get(R.capture completed)in
      require_string !expected(Journal_capture.source draft) "settled buffer trace";
      require(Journal_capture.pending_command draft=None && Journal_capture.can_save draft)
        "settled original kept the new draft owned"in
  let fails actions=try run actions;false with _->true in
  let rec shrink actions =
    let rec remove prefix=function []->actions
      |_::rest when fails(List.rev_append prefix rest)->shrink(List.rev_append prefix rest)
      |event::rest->remove(event::prefix)rest in remove []actions in
  for seed=0 to 99 do
    let random=Random.State.make[|0xB0FF;seed|]in
    let actions=List.init 60(fun _->Random.State.int random 80)in
    if fails actions then fail "pending buffer seed=%d minimized=[%s]"seed
      (String.concat ";"(List.map string_of_int(shrink actions)))
  done
;;
let ()=test_pending_capture_buffer_traces()

let test_delayed_recovery_cannot_borrow_another_submission () =
  let module F=Child_chain_fixture in let module C=F.C in
  let fixture=F.make()in
  let arm state action =
    let state,index,round,_=F.bind fixture state action in
    let state,action=C.receive state ~index ~round F.W.Outcome_unknown in
    let state,index,round,_=F.bind fixture state action in
    let state,_=C.receive state ~index ~round F.W.Outcome_unknown in
    let state,token=C.take_recovery state in state,Option.get token in
  let _,old=arm fixture.initial fixture.action in
  let command={fixture.command with mutation_id="70000000-0000-4000-9000-000000005604";
    block_id="70000000-0000-4000-a000-000000005604"}in
  let parent=F.G.Uuid.of_string command.parent_block_id |> Result.get_ok in
  let insert=F.W.Insert_blocks{parent;roots=[{uuid=F.G.Uuid.of_string command.block_id |> Result.get_ok;title=command.source;children=[]}];
    preconditions={blocks=[parent,command.expected_parent_revision];pages=[];
      scopes=[Worker_pure_data.V2_children_scope parent,"children-state:v1:frozen"]}} in
  let initial,action=C.start ~command ~page:(C.page fixture.initial) ~resolved_status:None ~insert |> Result.get_ok in
  let wire=F.W.encode_durable_intent(C.stage_intent fixture.session(C.stage initial 0) |> Result.get_ok) in
  let current,token=arm initial action in
  require(old.round=token.round && old.delay=token.delay) "foreign timer test did not reproduce reused local counters";
  let same,out=C.resume_recovery current old in
  require(same==current && out=C.Ignore) "old submission timer borrowed a different immutable intent";
  let current,out=C.resume_recovery current token in
  let _,_,actual=F.write fixture current out in
  require(actual=wire) "current submission timer did not retain its own payload"
;;
let ()=test_delayed_recovery_cannot_borrow_another_submission()
