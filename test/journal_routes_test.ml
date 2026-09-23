module ID = Journal_ids
module Ui = Journal_view

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
              | D.More _ -> true
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
  require (not (D.expanded initial ~block_id:child_id)) "deeper branch expanded eagerly";
  let opened, requests = D.step initial (Set_branch_expanded (child_id, true)) in
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
  require (D.expanded created ~block_id:child_id) "append discarded expanded branch";
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
  require (D.expanded restored ~block_id:child_id) "Undo lost expansion";
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
   | Some (Journal_graph_request.Load_detail { block_id; _ }) ->
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
  let routes = load_parent routes second 40L in
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

let test_native_disclosure_state_is_idempotent () =
  let module D = Journal_detail in
  let root = block () in
  let child =
    block
      ~id:"70000000-0000-4000-a000-000000000002"
      ~parent_id:(Some (Journal_model.id root))
      ()
  in
  let initial =
    D.create
      ~session_number:91L
      { root; children = { blocks = [ child ]; continuation = None } }
  in
  let same, requests =
    D.step initial (Set_branch_expanded (Journal_model.id root, true))
  in
  require
    (D.expanded same ~block_id:(Journal_model.id root) && requests = [])
    "repeated native expanded=true collapsed the branch";
  let child_id = Journal_model.id child in
  let opened, requests = D.step same (Set_branch_expanded (child_id, true)) in
  let generation =
    match requests with
    | [ Journal_graph_request.Load_detail { request_generation; limit = 64; _ } ] ->
      request_generation
    | _ -> fail "native disclosure did not admit a single bounded child request"
  in
  let duplicated, requests = D.step opened (Set_branch_expanded (child_id, true)) in
  require
    (D.expanded duplicated ~block_id:child_id && requests = [])
    "duplicate expansion toggled state or restarted loading";
  let closed, _ = D.step duplicated (Set_branch_expanded (child_id, false)) in
  let still_closed, requests = D.step closed (Set_branch_expanded (child_id, false)) in
  require
    ((not (D.expanded still_closed ~block_id:child_id)) && requests = [])
    "repeated collapse reopened the branch";
  let reopening, requests = D.step still_closed (Set_branch_expanded (child_id, true)) in
  require
    (D.expanded reopening ~block_id:child_id && requests = [])
    "reopening an in-flight branch stayed collapsed or duplicated the read";
  let still_closed, _ = D.step reopening (Set_branch_expanded (child_id, false)) in
  let loaded, _ =
    D.step
      still_closed
      (Loaded
         (generation, { root = child; children = { blocks = []; continuation = None } }))
  in
  require
    (not (D.expanded loaded ~block_id:child_id))
    "child completion reopened collapsed disclosure";
  let reopened, requests = D.step loaded (Set_branch_expanded (child_id, true)) in
  require
    (D.expanded reopened ~block_id:child_id && requests = [])
    "reopening a loaded branch performed an unnecessary read"
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

let tests =
  [ ( "Append restarts partial children"
    , test_append_restarts_partial_children_without_reusing_cursor )
  ; ( "child refresh replaces opaque cursor"
    , test_child_refresh_replaces_cursor_and_fences_pending_read )
  ; "hidden favorites pagination", test_favorites_hidden_rows_do_not_block_pagination
  ; "native disclosure state is idempotent", test_native_disclosure_state_is_idempotent
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
  ; ( "direct Capture task intent lifecycle"
    , test_direct_capture_task_intent_survives_edit_failure_and_retry )
  ; "outline branches, append and subtree Undo", test_outline_branches_append_and_delete
  ; ( "route generation, background, and runtime replacement"
    , test_route_generation_background_and_runtime_replacement )
  ]
;;

let () = test_native_composer_dismissal_and_edit_fences ()

let () =
  List.iter
    (fun (name, test) ->
       Printf.printf "running %s\n%!" name;
       test ())
    tests
;;
