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
      ?(task_state = Journal_model.Todo)
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

let test_native_composer_dismissal_and_edit_fences () =
  let module R = Application.Root_navigation in
  let initial = R.create ~graph_generation:3 in
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
  require (Journal_capture.task_state restored = Todo) "Close discarded task intent";
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
         {|{"operation":"%s","asset":"%s","localMutation":"%s","metadataMutation":"%s","path":"%s","title":"%s","type":"%s"}|}
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
    {|{"operation":"70000000-0000-4000-a000-00000000a010","asset":"70000000-0000-4000-a000-00000000a001","localMutation":"70000000-0000-4000-a000-00000000a002","metadataMutation":"70000000-0000-4000-a000-00000000a003","path":"/tmp/synthetic-attachment.png","title":"Existing picker selection","type":"png","request":{"id":4,"source":"files","staged":false}}|}
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
  let module R = Application.Root_navigation in
  let state = R.create ~graph_generation:3 |> fun s -> R.step s Capture_opened in
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

let test_child_refresh_replaces_cursor_and_fences_pending_read () =
  let module D = Journal_detail in
  let root = block ~child_count:3 () in
  let root_id = Journal_model.id root in
  let child = block ~id:(generated_block_id 551) ~parent_id:(Some root_id) () in
  let cursor token : Journal_graph_projection.block_cursor =
    { after_sibling_order = Journal_model.sibling_order child
    ; after_block_id = Journal_model.id child
    ; protocol_cursor =
        Some (Logseq_db_types.Graph_types.Cursor.of_string token |> Result.get_ok)
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
               (Logseq_db_types.Graph_types.Cursor.of_string "before-append"
                |> Result.get_ok)
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
                 (Logseq_db_types.Graph_types.Cursor.of_string "after-append"
                  |> Result.get_ok)
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
  require (List.exists (function D.More { parent_id; _ } -> parent_id = child_id | _ -> false) (D.rows initial))
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
          { parent_block_id; source; task_state = Todo; _ }) ->
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
  require (List.exists (function D.Block { block; _ } -> Journal_model.id block = Journal_model.id grandchild | _ -> false) (D.rows created)) "append discarded visible descendant";
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
  let removed_append, append_delete =
    D.stage_delete created ~block_id:(Journal_model.id new_child) |> Option.get
  in
  let restored_append = D.undo_delete removed_append append_delete in
  let restarted, _ =
    D.step restored_append (Load_failed (pending_generation, true, "Cursor changed"))
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
    "cursor restart lost an appended child restored by Undo";
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
  let deleted, staged = D.stage_delete created ~block_id:child_id |> Option.get in
  require
    (D.find_block deleted ~block_id:child_id = None)
    "staged subtree remained visible";
  require
    (D.find_block deleted ~block_id:(Journal_model.id grandchild) = None)
    "staged descendant remained visible";
  let restored = D.undo_delete deleted staged in
  require (List.exists (function D.Block { block; _ } -> Journal_model.id block = Journal_model.id grandchild | _ -> false) (D.rows restored)) "Undo lost visible descendant";
  require
    (Option.is_some (D.find_block restored ~block_id:(Journal_model.id new_child)))
    "Undo discarded unrelated appended child";
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

let test_favorites_state_isolates_requests_and_refreshes () =
  let module F = Journal_routes.Favorites in
  let module P = Logseq_db_worker.Protocol in
  let module G = Logseq_db_types.Graph_types in
  let uuid n =
    G.Uuid.of_string (Printf.sprintf "75000000-0000-4000-8000-%012d" n) |> Result.get_ok
  in
  let item n : P.v2_favorite_item =
    { membership_uuid = uuid n
    ; membership_order = string_of_int n
    ; membership_revision = "member"
    ; target =
        V2_favorite_page
          { uuid = uuid (n + 100); title = string_of_int n; revision = "page" }
    }
  in
  let result ?(cursor = None) items : P.v2_favorites_result =
    { favorites_page = Some (uuid 99)
    ; generation = "generation:v1:1"
    ; projection_revision = "projection:v1:1"
    ; items
    ; next_cursor = cursor
    }
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
  let cursor = G.Cursor.of_string "favorites-test:next" |> Result.get_ok in
  let selected, commands =
    F.step selected (Loaded (first, result ~cursor:(Some cursor) []))
  in
  let second = request commands in
  require (second.cursor = Some cursor) "empty filtered page did not continue";
  let loaded, commands =
    F.step selected (Loaded (second, result [ item 1; item 2; item 3 ]))
  in
  require
    (F.initialized loaded && List.length (F.items loaded) = 3 && commands = [])
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
    (F.error failed = Some "Read failed" && F.items failed <> [])
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
    (commands = [] && F.items replaced = [])
    "old graph completion contaminated replacement";
  let hidden, _ = F.step restarted (Select false) in
  let hidden, commands = F.step hidden (Loaded (restart, result [ item 1 ])) in
  require
    (commands = [] && List.length (F.items hidden) = 1)
    "inactive current completion was discarded"
;;

let test_favorite_target_origin_and_undo () =
  let module P = Logseq_db_worker.Protocol in
  let module G = Logseq_db_types.Graph_types in
  let module F = Journal_routes.Favorites in
  let uuid suffix =
    G.Uuid.of_string ("75000000-0000-4000-8000-" ^ suffix) |> Result.get_ok
  in
  let membership = uuid "000000000001"
  and target = uuid "000000000002" in
  let item : P.v2_favorite_item =
    { membership_uuid = membership
    ; membership_order = "a"
    ; membership_revision = "membership-1"
    ; target =
        V2_favorite_block
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
      target = V2_favorite_page { uuid = target; title = "Page"; revision = "page-1" }
    }
  in
  let untouched, request =
    Journal_routes.open_favorite origin ~request_generation:91L page_item
  in
  require (untouched = origin && request = None) "page favorite gained block navigation";
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
         , { favorites_page = Some membership
           ; generation = "generation-1"
           ; projection_revision = "projection-1"
           ; items = [ item; { page_item with membership_uuid = uuid "000000000003" } ]
           ; next_cursor = None
           } ))
  in
  let hidden, _ = F.step loaded (Hide_target (G.Uuid.to_string target)) in
  require
    (List.length (F.items hidden) = 1)
    "delete did not hide only the matching block favorite";
  let restored, _ = F.step hidden (Reveal_target (G.Uuid.to_string target)) in
  require (F.items restored = F.items loaded) "Undo did not restore favorite membership"
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
  require (Journal_capture.task_state capture = Todo) "parent return lost task intent";
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
  let module R = Application.Root_navigation in
  let graph id = Logseq_db_types.Graph_types.Uuid.of_string id |> Result.get_ok in
  let first = graph "70000000-0000-4000-b000-000000000001" in
  let second = graph "70000000-0000-4000-b000-000000000002" in
  let switch graph_id generation state =
    R.step state (Graph_replaced { graph_id; generation })
  in
  let start =
    R.create ~graph_generation:1
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
  require (Journal_capture.task_state restored = Todo) "graph return lost task intent";
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
  let restarted = R.create ~graph_generation:9 |> switch (Some first) 9 in
  require
    (R.capture restarted = None)
    "process-local drafts leaked into a new application owner"
;;

let test_graph_interruption_preserves_capture_attempt () =
  let module R = Application.Root_navigation in
  let graph_id =
    Logseq_db_types.Graph_types.Uuid.of_string "70000000-0000-4000-b000-000000000001"
    |> Result.get_ok
  in
  let start =
    R.create ~graph_generation:1
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
  let module R = Application.Root_navigation in
  let start =
    R.create ~graph_generation:1 |> fun state -> R.step state (Capture_edited "Original")
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
  let interrupted = Journal_capture.fail capture ~message:"Interrupted" in
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

let test_failed_append_edit_replaces_only_failed_attempt () =
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
  require_string
    "Original"
    (Journal_capture.source (Option.get (D.child_capture blocked)))
    "in-flight edit";
  let failed = D.fail owner ~message:"Offline" in
  let changed = D.apply_child_edit failed edited in
  require_string
    "Corrected"
    (Journal_capture.source (Option.get (D.child_capture changed)))
    "failed Append edit";
  require
    (D.mode changed = Reading && snd (D.retry changed) = None)
    "editing a failed attempt retained its obsolete retry";
  let child =
    block
      ~id:"70000000-0000-4000-a000-000000000012"
      ~parent_id:(Some (Journal_model.id root))
      ()
  in
  let late = D.apply_child_created changed ~child ~parent:root in
  require_string
    "Corrected"
    (Journal_capture.source (Option.get (D.child_capture late)))
    "late Append completion";
  let toggled = D.toggle_child_task failed in
  require
    (D.mode toggled = Reading && snd (D.retry toggled) = None)
    "task edit retained failed request";
  require
    (Journal_capture.task_state (Option.get (D.child_capture toggled)) = Todo)
    "failed Append task edit ignored";
  let text_changed = D.update_child_source failed "Replacement" in
  require_string
    "Replacement"
    (Journal_capture.source (Option.get (D.child_capture text_changed)))
    "failed Append source replacement"
;;

let test_capture_editor_sessions_are_not_reused () =
  let module R = Application.Root_navigation in
  let initial =
    R.create ~graph_generation:1 |> fun state -> R.step state Capture_opened
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
    if n = 128 then owner else
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
      finish owner (n + 1) in
  let owner = finish owner 0 in
  require (D.next_automatic_load owner = None) "automatic branch budget exceeded 128";
  let manual = Journal_model.id (List.nth children 128) in
  require (List.exists (function D.More { parent_id; loading = false; _ } -> parent_id = manual
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
  let item membership target : P.v2_favorite_item =
    { membership_uuid = uuid membership
    ; membership_order = string_of_int membership
    ; membership_revision = "member"
    ; target =
        V2_favorite_block
          { uuid = uuid (100 + target)
          ; title = "Target"
          ; task_status = None
          ; revision = "block"
          }
    }
  in
  let cursor n =
    G.Cursor.of_string ("favorites-test:" ^ string_of_int n) |> Result.get_ok
  in
  let result items next : P.v2_favorites_result =
    { favorites_page = Some (uuid 99)
    ; generation = "generation:v1:1"
    ; projection_revision = "projection:v1:1"
    ; items
    ; next_cursor = next
    }
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
  require (List.length (F.items hidden) = 2) "fixture did not hide target rows";
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
    (F.items empty = [] && requests <> [])
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
  let module R = Application.Root_navigation in
  let unchanged state event label =
    require (R.step state event == state) "%s published an unchanged root model" label
  in
  let initial = R.create ~graph_generation:3 in
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
    (Journal_capture.task_state (Option.get (R.capture selected)) = Todo)
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
      { Journal_graph_projection.root = a
      ; children = { blocks = [ child ]; continuation = None }
      }
  in
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

let test_typed_shared_data_delete_undo_and_drafts () =
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
  let latest = block ~task_state:Done () in
  let shared = R.map_details second ~f:(fun d -> Journal_detail.apply_block d latest) in
  List.iter
    (fun id ->
       require
         (Journal_model.task_state (Journal_detail.root (entry_detail shared id)) = Done)
         "shared graph data was not propagated to every matching live owner")
    [ first_id; second_id ];
  require_string
    "First retained"
    (Journal_capture.source
       (Option.get (Journal_detail.child_capture (entry_detail shared first_id))))
    "first independent draft after graph update";
  let staged, undo = R.stage_delete shared ~block_id:(Journal_model.id parent) in
  List.iter
    (fun id ->
       require
         (R.route (entry staged id) = Missing_detail)
         "delete left a matching live root visible")
    [ first_id; second_id ];
  let deleted_reopened = R.pop_to_root staged |> fun t -> load_parent t parent 925L in
  require_string
    "Second retained"
    (Journal_capture.source
       (Option.get
          (Journal_detail.child_capture (Option.get (R.detail deleted_reopened)))))
    "deleted root kept its independent retained composer";
  let restored = R.undo_delete staged (Option.get undo) in
  List.iter
    (fun id ->
       require
         (R.route (entry restored id) = Detail)
         "aggregate Undo did not restore a live owner")
    [ first_id; second_id ];
  require_string
    "Second retained"
    (Journal_capture.source
       (Option.get (Journal_detail.child_capture (entry_detail restored second_id))))
    "second independent draft after Undo";
  let popped = R.back staged |> fun t -> R.undo_delete t (Option.get undo) in
  require
    (R.at_entry popped ~entry_id:second_id = None && path_ids popped = [ first_id ])
    "Undo revived a popped owner";
  let detached = R.pop_to_root restored in
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
      (Yojson.Basic.to_string (multiselect_pick index path source_identity))
  with
  | Ok (Picked (staged, _)) -> staged
  | _ -> fail "valid legacy selection did not decode"
;;

let with_multiselect_files count f =
  let files = List.init count (fun _ -> Filename.temp_file "journal-import-" ".png") in
  Fun.protect
    ~finally:(fun () ->
      List.iter (fun path -> if Sys.file_exists path then Sys.remove path) files)
    (fun () -> f files)
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
  let module R = Application.Root_navigation in
  with_multiselect_files 4 (function
    | [ a; b; c; duplicate ] ->
      let picks =
        List.mapi
          (fun i path -> multiselect_staged i path ("files:" ^ string_of_int i))
          [ a; b; c ]
      in
      let start =
        R.create ~graph_generation:1
        |> fun s ->
        R.step s Capture_opened |> fun s -> R.step s (Capture_picker_requested Files)
      in
      let selected = R.step start (Capture_assets_picked (picks, Some 1, None)) in
      let current s = Journal_capture.pending_attachments (Option.get (R.capture s)) in
      require
        (List.map Journal_asset_import.staged_path (current selected) = [ a; b; c ])
        "selection order was lost";
      let duplicate_pick = multiselect_staged 4 duplicate "files:1" in
      let deduped = R.step selected (Capture_asset_picked (duplicate_pick, Some 1)) in
      require (current deduped = picks) "same source added a duplicate attachment";
      require (not (Sys.file_exists duplicate)) "duplicate staging copy was leaked";
      let repeated = R.step deduped (Capture_asset_picked (List.hd picks, Some 1)) in
      require
        (current repeated = picks && Sys.file_exists a)
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
  let module R = Application.Root_navigation in
  with_multiselect_files (Journal_capture.attachment_limit + 2) (fun files ->
    let picks =
      List.mapi
        (fun i path -> multiselect_staged i path ("files:" ^ string_of_int i))
        files
    in
    let start =
      R.create ~graph_generation:1
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
    let next = R.step full (Capture_asset_picked (overflow, Some 1)) in
    require
      (List.length (Journal_capture.pending_attachments (Option.get (R.capture next)))
       = Journal_capture.attachment_limit)
      "capacity changed";
    require
      (not (Sys.file_exists (Journal_asset_import.staged_path overflow)))
      "capacity rejection leaked its staging copy";
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
    let after =
      R.step
        (R.step start (Capture_admitted saving))
        (Capture_asset_picked (rejected, Some 1))
    in
    require (R.capture after = Some saving) "saving capture accepted an async attachment";
    require
      (not (Sys.file_exists (Journal_asset_import.staged_path rejected)))
      "saving rejection leaked its staging copy")
;;

let test_multiselect_graph_owner_and_cancel () =
  let module R = Application.Root_navigation in
  let graph index =
    Logseq_db_types.Graph_types.Uuid.of_string
      (Printf.sprintf "71000000-0000-4000-b000-%012d" index)
    |> Result.get_ok
  in
  with_multiselect_files 2 (function
    | [ kept; late ] ->
      let start =
        R.create ~graph_generation:1
        |> fun s ->
        R.step s (Graph_replaced { graph_id = Some (graph 1); generation = 1 })
        |> fun s ->
        R.step s Capture_opened |> fun s -> R.step s (Capture_picker_requested Photos)
      in
      let pick = multiselect_staged 1 kept "photos:kept" in
      let selected = R.step start (Capture_asset_picked (pick, Some 1)) in
      require
        (Journal_asset_import.is_dismissal {|{"action":"dismissed","request":1}|})
        "picker cancellation did not decode";
      let collapsed = R.step selected Capture_closed in
      require
        (R.capture collapsed = R.capture selected && Sys.file_exists kept)
        "cancellation/collapse erased owned attachments";
      let other =
        R.step collapsed (Graph_replaced { graph_id = Some (graph 2); generation = 2 })
        |> fun s -> R.step s Capture_opened
      in
      require
        (Sys.file_exists kept)
        "graph retention deleted a retained draft's attachment";
      let stale =
        R.step
          other
          (Capture_asset_picked (multiselect_staged 2 late "photos:late", Some 1))
      in
      require
        (Journal_capture.pending_attachments (Option.get (R.capture stale)) = [])
        "old graph completion acquired a new draft";
      require (not (Sys.file_exists late)) "old graph completion leaked its staging copy";
      let returned =
        R.step stale (Graph_replaced { graph_id = Some (graph 1); generation = 3 })
      in
      require
        (Journal_capture.pending_attachments (Option.get (R.capture returned)) = [ pick ]
         && Sys.file_exists kept)
        "returning graph lost staged ownership";
      let other =
        R.step returned (Graph_replaced { graph_id = Some (graph 2); generation = 4 })
      in
      ignore (R.step other Account_cleared);
      require (not (Sys.file_exists kept)) "sign-out leaked retained graph staging"
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
       let staged, undo = R.stage_delete reopened ~block_id:(Journal_model.id root) in
       require
         (List.length (R.pending_attachments staged) = 1)
         "Undo staging retired the attachment too early";
       let restored = R.undo_delete staged (Option.get undo) in
       require
         (List.length (R.pending_attachments restored) = 1)
         "Undo failed to restore the attachment";
       let committed, released =
         R.commit_delete staged ~block_id:(Journal_model.id root)
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
      { G.items = children; continuation = None }
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
  require (List.filter_map (function D.Block { depth; _ } -> Some depth | _ -> None)
      (D.rows owner) = [ 0; 1; 2 ]) "real projected descendants did not auto-expand";
  require (not (List.exists (function D.More _ -> true | _ -> false) (D.rows owner)))
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
  require (List.exists (function D.More { parent_id; _ } -> parent_id = id 1
      | _ -> false) (D.rows owner))
    "default expanded child must expose loading/Load more without disclosure";
  let rec load owner n =
    if n >= 9 then owner else
      let next, requests = D.step owner Load_next in
      let generation = match requests with
        | [ Journal_graph_request.Load_detail { request_generation; limit = 128; _ } ] -> request_generation
        | _ -> fail "visible descendant did not admit one bounded page" in
      let next, _ = D.step next (Loaded (generation, projection n)) in
      load next (n + 1) in
  let owner = load owner 1 in
  require (List.filter_map (function D.Block { depth; _ } -> Some depth | _ -> None)
      (D.rows owner) = List.init 10 Fun.id)
    "Detail must display ten data levels including the root";
  require (not (List.exists (function D.More { parent_id; _ } -> parent_id = id 9
      | _ -> false) (D.rows owner)))
    "depth ten must not expose a read for depth eleven";
  require (D.next_automatic_load owner = None) "automatic traversal crossed the depth limit";
  let _, requests = D.step owner (Load_more (id 9)) in
  require (requests = []) "depth limit admitted a hidden subtree read";
  let cycle = D.reconcile_children owner
      { root = List.nth chain 2; children = { blocks = [ List.nth chain 0 ]; continuation = None } } in
  require (List.filter_map (function D.Block { block; _ } -> Some (Journal_model.id block)
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
  require (not (List.exists (function D.More { parent_id; _ } -> parent_id = id 20
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
  require (List.exists (function D.More { parent_id; error = Some "offline"; loading = false; _ } ->
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
    ; protocol_cursor = Some (Logseq_db_types.Graph_types.Cursor.of_string
        (Printf.sprintf "detail-page-%d" ordinal) |> Result.get_ok) } in
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
    (List.filter_map (function D.Block { block; _ } -> Some (Journal_model.id block)
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
      ~task_state:Done
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
              && Journal_model.task_state block = Done
              && Journal_model.tag_titles block = [ "QA updated" ]
            | _ -> false)
          (D.rows owner))
    "block attributes did not invalidate rows";
  require (D.rows old_owner == rows) "derived outline overwrote retained snapshot cache";
  let rows = D.rows owner in
  let owner, staged =
    D.stage_delete owner ~block_id:(Journal_model.id child) |> Option.get
  in
  require
    (D.rows owner != rows && fst (followup_counts owner) = 1)
    "delete retained stale rows";
  let deleted = D.rows owner in
  let owner = D.undo_delete owner staged in
  require
    (D.rows owner != deleted && fst (followup_counts owner) = 2)
    "Undo retained deleted rows";
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

let tests =
  [ "PR63 public review regressions", test_followup_review_regressions
  ] @
  [ "projected unknown children are read once", test_projected_unknown_children_are_read_once
  ; "Detail default ten levels and cycle boundaries", test_detail_default_outline_depth_and_cycle_boundaries
  ; "Detail serialized reads and retry feedback", test_detail_serial_reads_and_retry_feedback
  ] @
  [ ( "retained picker and terminal delete"
    , test_retained_detail_picker_owner_and_terminal_delete )
  ; "typed path prefix and loading owners", test_typed_path_prefix_and_loading_owners
  ; "multiselect batch boundary", test_multiselect_batch_boundary
  ; "multiselect order duplicates and readd", test_multiselect_order_duplicates_and_readd
  ; ( "multiselect rejected resource ownership"
    , test_multiselect_rejected_resource_ownership )
  ; "multiselect graph owner and cancel", test_multiselect_graph_owner_and_cancel
  ; "typed covered failure and branch", test_typed_covered_failure_missing_and_branch
  ; "typed shared data and aggregate Undo", test_typed_shared_data_delete_undo_and_drafts
  ; "typed duplicate detached mutations", test_typed_detached_duplicate_pending_mutations
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
  ; "automatic outline reads are bounded and idempotent", test_automatic_outline_reads_are_bounded_and_idempotent
  ; "Detail 128-item pages preserve order", test_detail_128_item_pages_preserve_order_and_completion
  ; "Detail retry uses 128-item first page", test_detail_retry_uses_128_item_first_page
  ; "Append editor session after save", test_append_editor_session_after_save
  ; ( "Capture editor sessions are never reused"
    , test_capture_editor_sessions_are_not_reused )
  ; ( "failed Append editing and late completion"
    , test_failed_append_edit_replaces_only_failed_attempt )
  ; ( "late Capture completion preserves newer edit"
    , test_late_capture_completion_preserves_newer_edit )
  ; "retained graph Append owner", test_graph_retained_append_owner
  ; "graph draft retention and privacy", test_graph_draft_retention_and_privacy
  ; ( "graph interruption preserves Capture attempt"
    , test_graph_interruption_preserves_capture_attempt )
  ; "Append drafts follow parent navigation", test_append_drafts_follow_parent_navigation
  ; "detached Append completion and failure", test_detached_append_completion_and_failure
  ; "favorite target identity, origin and Undo", test_favorite_target_origin_and_undo
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

let () = test_native_composer_dismissal_and_edit_fences ()
let () = test_collapse_retains_complete_capture ()

let () =
  List.iter
    (fun (name, test) ->
       Printf.printf "running %s\n%!" name;
       test ())
    tests
;;
