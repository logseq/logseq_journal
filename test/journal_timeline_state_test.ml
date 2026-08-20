module Timeline = Journal_timeline_state
module Ui = Bonsai_flutter_ui
module ID = Bonsai_flutter_spec.Id

let fail format = Printf.ksprintf failwith format

let require condition format =
  Printf.ksprintf (fun message -> if not condition then failwith message) format
;;

let require_equal_string_list actual expected label =
  if actual <> expected
  then
    fail
      "%s\nexpected: [%s]\nactual:   [%s]"
      label
      (String.concat "; " expected)
      (String.concat "; " actual)
;;

let id prefix index =
  let kind =
    match prefix with
    | "block" -> 1
    | "page" -> 2
    | "mutation" -> 3
    | _ -> 9
  in
  Printf.sprintf "%08d-0000-4000-8000-%012d" kind index
;;

let creation_time ?(day = 20260809) ?(minute = 540) () =
  let midnight =
    match day with
    | 20260807 -> 1_786_032_000_000L
    | 20260808 -> 1_786_118_400_000L
    | 20260809 -> 1_786_204_800_000L
    | _ -> fail "unsupported creation-time fixture day: %d" day
  in
  Journal_time.create
    ~instant_unix_ms:Int64.(add midnight (of_int (minute * 60_000)))
    ~local_day:day
    ~local_minute_of_day:minute
    ~time_zone_id:"Asia/Shanghai"
    ~utc_offset_seconds:28_800
  |> function
  | Ok value -> value
  | Error error -> fail "creation-time fixture failed: %s" error
;;

let block
      ?(day = 20260809)
      ?parent_id
      ?(order = "000000000001")
      ?(source = "Journal entry")
      ?(task_state = Journal_model.Not_a_task)
      ?(child_count = 0)
      ?(revision = 1)
      index
  =
  Journal_model.create
    ~id:(id "block" index)
    ~page_id:(id "page" day)
    ~journal_day:day
    ~parent_id
    ~sibling_order:order
    ~source
    ~task_state
    ~child_count
    ~creation_time:(creation_time ~day ())
    ~revision
    ~last_mutation_id:(id "mutation" index)
  |> function
  | Ok value -> value
  | Error error -> fail "block fixture failed: %s" error
;;

let page day title : Journal_graph_projection.page = { id = id "page" day; day; title }

let entry ?(child_summaries = []) block : Journal_graph_projection.timeline_entry =
  { block; child_summaries }
;;

let feed ?(more = false) days : Journal_graph_projection.feed =
  let slot_count =
    List.fold_left
      (fun count (day : Journal_graph_projection.day_feed) ->
         count + 1 + List.length day.entries + if day.has_more_entries then 1 else 0)
      0
      days
  in
  { days; slot_count; has_more_days = more }
;;

let continuation_of_entries ~more entries =
  if not more
  then None
  else
    match List.rev entries with
    | [] -> fail "a continued day fixture must contain at least one entry"
    | (entry : Journal_graph_projection.timeline_entry) :: _ ->
      Some
        { Journal_graph_projection.after_sibling_order =
            Journal_model.sibling_order entry.block
        ; after_block_id = Journal_model.id entry.block
        ; protocol_cursor = None
        }
;;

let day_feed ?(more = false) day title blocks : Journal_graph_projection.day_feed =
  let entries = List.map (fun block -> entry block) blocks in
  { page = page day title
  ; entries
  ; has_more_entries = more
  ; continuation = continuation_of_entries ~more entries
  }
;;

let day_feed_entries ?(more = false) day title entries : Journal_graph_projection.day_feed =
  { page = page day title
  ; entries
  ; has_more_entries = more
  ; continuation = continuation_of_entries ~more entries
  }
;;

let timeline_page ?(continuation = None) blocks : Journal_graph_projection.timeline_entry_page =
  { entries = List.map (fun block -> entry block) blocks; continuation }
;;

let begin_and_apply_feed ~generation ~before_day value state =
  let state = Timeline.begin_request state ~generation (Timeline.Feed { before_day }) in
  Timeline.apply_feed state ~generation value
;;

let slot_keys state = Timeline.retained_slots state |> List.map Timeline.slot_key

let test_projection_order_today_suppression_and_continuations () =
  let today_late = block ~order:"b" ~source:"Today B" 3 in
  let today_tie_b = block ~order:"a" ~source:"Today tie B" 2 in
  let today_tie_a = block ~order:"a" ~source:"Today tie A" 1 in
  let older_late = block ~day:20260808 ~order:"z" ~source:"Older Z" 5 in
  let older_early = block ~day:20260808 ~order:"a" ~source:"Older A" 4 in
  let value =
    feed
      ~more:true
      [ day_feed 20260808 "Saturday, August 8" [ older_late; older_early ]
      ; day_feed ~more:true 20260809 "Today" [ today_late; today_tie_b; today_tie_a ]
      ]
  in
  let state =
    Timeline.empty ~today:20260809
    |> begin_and_apply_feed ~generation:1L ~before_day:None value
  in
  require_equal_string_list
    (slot_keys state)
    [ "block:" ^ Journal_model.id today_tie_a
    ; "block:" ^ Journal_model.id today_tie_b
    ; "block:" ^ Journal_model.id today_late
    ; "day-continuation:20260809"
    ; "day:20260808"
    ; "block:" ^ Journal_model.id older_early
    ; "block:" ^ Journal_model.id older_late
    ; "feed-continuation:20260808"
    ; "bottom-clearance"
    ]
    "timeline ordering or continuation projection changed";
  require
    (List.for_all
       (function
         | Timeline.Day_heading page -> page.day <> 20260809
         | Timeline.Top_level _
         | Timeline.Child_preview _
         | Timeline.Day_continuation _
         | Timeline.Children_loading _
         | Timeline.Children_more _
         | Timeline.Feed_continuation _
         | Timeline.Bottom_clearance -> true)
       (Timeline.retained_slots state))
    "Today must not render a duplicate day heading"
;;

let test_direct_children_insert_after_parent_and_collapse () =
  let parent = block ~source:"Parent line one\nParent line two" ~child_count:3 10 in
  let sibling = block ~order:"b" ~source:"Sibling" 11 in
  let initial =
    Timeline.empty ~today:20260809
    |> begin_and_apply_feed
         ~generation:1L
         ~before_day:None
         (feed [ day_feed 20260809 "Today" [ sibling; parent ] ])
  in
  let expanded = Timeline.expand initial ~parent_id:(Journal_model.id parent) in
  let child_request =
    match Timeline.next_request expanded with
    | Some (Timeline.Children { parent_id; epoch } as request) ->
     require
       (String.equal parent_id (Journal_model.id parent))
       "child request targeted the wrong parent";
     require (Int64.compare epoch 0L > 0) "child request omitted its expansion epoch";
     request
    | _ -> fail "expansion did not expose a bounded child request"
  in
  let child_b =
    block ~parent_id:(Journal_model.id parent) ~order:"b" ~source:"Child B" 13
  in
  let child_a2 =
    block ~parent_id:(Journal_model.id parent) ~order:"a" ~source:"Child A2" 12
  in
  let child_a1 =
    block ~parent_id:(Journal_model.id parent) ~order:"a" ~source:"Child A1" 14
  in
  let detail : Journal_graph_projection.detail =
    { root = parent
    ; children =
        { blocks = [ child_b; child_a2; child_a1 ]
        ; continuation =
            Some
              { after_sibling_order = "b"
              ; after_block_id = Journal_model.id child_b
              ; protocol_cursor = None
              }
        }
    }
  in
  let loaded =
    Timeline.begin_request
      expanded
      ~generation:2L
      child_request
  in
  let loaded = Timeline.apply_detail loaded ~generation:2L detail in
  require_equal_string_list
    (slot_keys loaded)
    [ "block:" ^ Journal_model.id parent
    ; "block:" ^ Journal_model.id child_a2
    ; "block:" ^ Journal_model.id child_a1
    ; "block:" ^ Journal_model.id child_b
    ; "children-more:" ^ Journal_model.id parent
    ; "block:" ^ Journal_model.id sibling
    ; "bottom-clearance"
    ]
    "direct children were not inserted immediately after their parent";
  (match Timeline.retained_slots loaded with
   | Timeline.Top_level _
     :: Timeline.Child_preview _
     :: Timeline.Child_preview _
     :: Timeline.Child_preview _
     :: Timeline.Children_more _
     :: _ -> ()
   | _ -> fail "explicit top-level and child-preview roles changed");
  let require_role_extents ~width ~scale ~expected_parent ~expected_child =
    let profile =
      Journal_visual_tokens.select_row_profile ~viewport_width:width ~text_scale:scale
    in
    let geometry = Timeline.extent_geometry loaded ~profile ~safe_bottom:0. in
    let expected =
      [ 0, expected_parent
      ; 1, expected_child
      ; 2, expected_child
      ; 3, expected_child
      ; 4, expected_child
      ; 6, 68.
      ]
    in
    List.iter
      (fun (index, extent) ->
         require
           (List.exists
              (fun (override : Ui.Widget.Sparse_extent_override.t) ->
                 override.index = index && Float.equal override.extent extent)
              geometry.overrides)
           "role override %d did not use exact extent %.1f"
           index
           extent)
      expected
  in
  require_role_extents
    ~width:390.
    ~scale:1.
    ~expected_parent:56.
    ~expected_child:36.;
  require_role_extents
    ~width:320.
    ~scale:3.2
    ~expected_parent:144.
    ~expected_child:80.;
  let collapsed = Timeline.collapse loaded ~parent_id:(Journal_model.id parent) in
  require_equal_string_list
    (slot_keys collapsed)
    [ "block:" ^ Journal_model.id parent
    ; "block:" ^ Journal_model.id sibling
    ; "bottom-clearance"
    ]
    "collapse retained child slots";
  require
    (Timeline.anchor_decision collapsed = Timeline.Preserve_visible_slot)
    "collapse must preserve the current stable sparse-list anchor"
;;

let test_collapsed_child_response_releases_the_matching_request () =
  let parent = block ~source:"Parent" ~child_count:1 15 in
  let initial =
    Timeline.empty ~today:20260809
    |> begin_and_apply_feed
         ~generation:1L
         ~before_day:None
         (feed [ day_feed 20260809 "Today" [ parent ] ])
  in
  let expanded = Timeline.expand initial ~parent_id:(Journal_model.id parent) in
  let request =
    match Timeline.next_request expanded with
    | Some (Timeline.Children _ as request) -> request
    | _ -> fail "expansion omitted its epoch-fenced request"
  in
  let loading = Timeline.begin_request expanded ~generation:2L request in
  let collapsed = Timeline.collapse loading ~parent_id:(Journal_model.id parent) in
  let child = block ~parent_id:(Journal_model.id parent) ~source:"Persisted child" 16 in
  let detail : Journal_graph_projection.detail =
    { root = parent; children = { blocks = [ child ]; continuation = None } }
  in
  let settled = Timeline.apply_detail collapsed ~generation:2L detail in
  require
    (Timeline.pending_request settled = None)
    "a matching child response retained its request after the disclosure collapsed";
  require
    (not (Timeline.is_expanded settled ~block_id:(Journal_model.id parent)))
    "a child response reopened a disclosure that the user collapsed";
  require_equal_string_list
    (slot_keys settled)
    [ "block:" ^ Journal_model.id parent; "bottom-clearance" ]
    "a collapsed disclosure inserted child rows from its completed request";
  let retry = Timeline.expand settled ~parent_id:(Journal_model.id parent) in
  let retry_request =
    match Timeline.next_request retry with
    | Some (Timeline.Children { parent_id; epoch } as retry_request) ->
     require
       (String.equal parent_id (Journal_model.id parent))
       "re-expansion retried the wrong parent";
     let old_epoch =
       match request with Timeline.Children { epoch; _ } -> epoch | _ -> assert false
     in
     require
       (Int64.compare epoch old_epoch > 0)
       "re-expansion reused the stale child epoch";
     retry_request
    | _ -> fail "re-expansion did not retry after the collapsed request completed"
  in
  let newer = Timeline.begin_request retry ~generation:4L retry_request in
  let newer_collapsed = Timeline.collapse newer ~parent_id:(Journal_model.id parent) in
  let after_stale = Timeline.apply_detail newer_collapsed ~generation:3L detail in
  require
    (Timeline.pending_request after_stale = Some (4L, retry_request))
    "a stale child response cleared the newer pending request"
;;

let test_multiple_parent_expansions_drain_without_reusing_epochs () =
  let first_parent = block ~source:"First parent" ~child_count:1 17 in
  let second_parent = block ~order:"b" ~source:"Second parent" ~child_count:1 18 in
  let initial =
    Timeline.empty ~today:20260809
    |> begin_and_apply_feed
         ~generation:1L
         ~before_day:None
         (feed [ day_feed 20260809 "Today" [ second_parent; first_parent ] ])
  in
  let first_expanded =
    Timeline.expand initial ~parent_id:(Journal_model.id first_parent)
  in
  let first_request =
    match Timeline.next_request first_expanded with
    | Some (Timeline.Children _ as request) -> request
    | _ -> fail "first parent omitted its loading request"
  in
  let first_pending =
    Timeline.begin_request first_expanded ~generation:2L first_request
  in
  let both_expanded =
    Timeline.expand first_pending ~parent_id:(Journal_model.id second_parent)
  in
  require
    (Timeline.next_request both_expanded = None)
    "second parent bypassed the single in-flight request";
  let first_child =
    block ~parent_id:(Journal_model.id first_parent) ~source:"First child" 19
  in
  let after_first =
    Timeline.apply_detail
      both_expanded
      ~generation:2L
      { Journal_graph_projection.root = first_parent
      ; children = { blocks = [ first_child ]; continuation = None }
      }
  in
  let second_request =
    match Timeline.next_request after_first with
    | Some (Timeline.Children { parent_id; epoch } as request) ->
      require
        (String.equal parent_id (Journal_model.id second_parent))
        "completed first response did not expose the second parent";
      let first_epoch =
        match first_request with
        | Timeline.Children { epoch; _ } -> epoch
        | _ -> assert false
      in
      require
        (Int64.compare epoch first_epoch > 0)
        "multiple parents reused one expansion epoch";
      request
    | _ -> fail "second parent loading slot was stranded"
  in
  let second_child =
    block ~parent_id:(Journal_model.id second_parent) ~source:"Second child" 20
  in
  let settled =
    Timeline.begin_request after_first ~generation:3L second_request
    |> fun state ->
    Timeline.apply_detail
      state
      ~generation:3L
      { Journal_graph_projection.root = second_parent
      ; children = { blocks = [ second_child ]; continuation = None }
      }
  in
  require
    (Timeline.pending_request settled = None && Timeline.next_request settled = None)
    "multiple parent expansion did not settle"
;;

let test_stale_generations_and_page_append () =
  let first = block ~source:"First" 20 in
  let second = block ~order:"b" ~source:"Second" 21 in
  let base =
    Timeline.empty ~today:20260809
    |> begin_and_apply_feed
         ~generation:10L
         ~before_day:None
         (feed [ day_feed ~more:true 20260809 "Today" [ first ] ])
  in
  let cursor =
    match Timeline.next_request base with
    | Some (Timeline.Day { after = Some cursor; _ }) -> cursor
    | _ -> fail "initial day continuation is missing its compound cursor"
  in
  let waiting =
    Timeline.begin_request
      base
      ~generation:11L
      (Timeline.Day { day = 20260809; after = Some cursor })
  in
  let stale =
    Timeline.apply_timeline_entry_page
      waiting
      ~generation:9L
      (timeline_page [ second ])
  in
  require
    (slot_keys stale = slot_keys waiting)
    "stale page response mutated timeline state";
  let appended =
    Timeline.apply_timeline_entry_page
      waiting
      ~generation:11L
      (timeline_page [ second ])
  in
  require_equal_string_list
    (slot_keys appended)
    [ "block:" ^ Journal_model.id first
    ; "block:" ^ Journal_model.id second
    ; "bottom-clearance"
    ]
    "day page did not replace its continuation";
  require
    (Timeline.anchor_decision appended = Timeline.Preserve_visible_slot)
    "page append must preserve the visible stable slot"
;;

let test_authoritative_timeline_entry_replaces_summary_by_stable_parent_id () =
  let parent = block ~source:"Summary parent" ~child_count:1 22 in
  let first_summary : Journal_graph_projection.child_summary =
    { block_id = id "block" 23; source = "Original summary" }
  in
  let initial_entry = entry ~child_summaries:[ first_summary ] parent in
  let state =
    Timeline.empty ~today:20260809
    |> begin_and_apply_feed
         ~generation:1L
         ~before_day:None
         (feed
            [ day_feed_entries 20260809 "Today" [ initial_entry ] ])
  in
  let refreshed_summary : Journal_graph_projection.child_summary =
    { block_id = id "block" 24; source = "Promoted summary" }
  in
  let refreshed =
    Timeline.replace_timeline_entry
      state
      (entry ~child_summaries:[ refreshed_summary ] parent)
  in
  (match Timeline.retained_slots refreshed with
   | Timeline.Top_level { child_summaries = [ summary ]; _ } :: _ ->
     require
       (String.equal summary.block_id refreshed_summary.block_id
        && String.equal summary.source refreshed_summary.source)
       "authoritative parent entry did not replace the summary"
   | _ -> fail "authoritative entry replacement changed the top-level slot role");
  require
    (slot_keys refreshed = slot_keys state)
    "authoritative entry replacement changed stable slot identity"
;;

let make_page start count =
  List.init count (fun offset ->
    let index = start + offset in
    block
      ~order:(Printf.sprintf "%012d" index)
      ~source:(Printf.sprintf "Durable record %05d" index)
      index)
;;

let test_ten_thousand_record_rolling_projection_is_bounded () =
  let initial_blocks = make_page 0 64 in
  let state =
    ref
      (Timeline.empty ~today:20260809
       |> begin_and_apply_feed
            ~generation:1L
            ~before_day:None
            (feed ~more:false [ day_feed ~more:true 20260809 "Today" initial_blocks ]))
  in
  let generation = ref 2L in
  let next_index = ref 64 in
  while !next_index < 10_000 do
    let count = min 64 (10_000 - !next_index) in
    let blocks = make_page !next_index count in
    let last = List.hd (List.rev blocks) in
    let continuation =
      if !next_index + count < 10_000
      then
        Some
          { Journal_graph_projection.after_sibling_order = Journal_model.sibling_order last
          ; after_block_id = Journal_model.id last
          ; protocol_cursor = None
          }
      else None
    in
    let after =
      match Timeline.next_request !state with
      | Some (Timeline.Day { after; _ }) -> after
      | _ -> fail "durable catch-up lost its day continuation at %d" !next_index
    in
    state
    := Timeline.begin_request
         !state
         ~generation:!generation
         (Timeline.Day { day = 20260809; after });
    state
    := Timeline.apply_timeline_entry_page
         !state
         ~generation:!generation
         (timeline_page ~continuation blocks);
    state
    := Timeline.observe_visible_range
         !state
         ~first_index:(Timeline.total_count !state - 1)
         ~last_exclusive:(Timeline.total_count !state);
    require
      (Timeline.retained_slot_count !state <= Timeline.maximum_slots)
      "10,000-record catch-up retained %d slots"
      (Timeline.retained_slot_count !state);
    require
      (List.length (Timeline.current_window !state).slots
       <= Timeline.maximum_supplied_rows)
      "10,000-record catch-up supplied too many rows";
    next_index := !next_index + count;
    generation := Int64.succ !generation
  done;
  require (Timeline.total_count !state = 10_001) "logical count lost records";
  require
    (Timeline.first_retained_index !state > 9_000)
    "rolling cache did not discard old slots";
  require
    (Timeline.retained_slot_count !state = Timeline.maximum_slots)
    "rolling cache did not settle at its exact bound"
;;

let test_fifty_thousand_synthetic_windows_are_bounded () =
  List.iter
    (fun (first, last_exclusive) ->
       let window =
         Timeline.synthetic_window
           ~total_count:50_000
           ~first_visible:first
           ~last_exclusive
       in
       require (window.first_index >= 0) "synthetic window starts before zero";
       require
         (window.first_index + window.count <= 50_000)
         "synthetic window ends beyond the corpus";
       require
         (window.count <= Timeline.maximum_supplied_rows)
         "50,000-row stress supplied %d rows"
         window.count)
    [ 0, 10; 1, 39; 10_000, 10_020; 25_000, 25_032; 49_980, 50_000 ]
;;

let test_exact_profile_extents_and_final_clearance () =
  let older = block ~day:20260808 30 in
  let state =
    Timeline.empty ~today:20260809
    |> begin_and_apply_feed
         ~generation:1L
         ~before_day:None
         (feed [ day_feed 20260808 "Saturday, August 8" [ older ] ])
  in
  let check ~width ~scale ~top_level_extent ~day_extent =
    let profile =
      Journal_visual_tokens.select_row_profile ~viewport_width:width ~text_scale:scale
    in
    let geometry = Timeline.extent_geometry state ~profile ~safe_bottom:34. in
    require
      (Float.equal geometry.default_extent top_level_extent)
      "profile default extent %.1f, expected %.1f"
      geometry.default_extent
      top_level_extent;
    require
      (geometry.overrides
       = [ { Ui.Widget.Sparse_extent_override.index = 0; extent = day_extent }
         ; { Ui.Widget.Sparse_extent_override.index = 2; extent = 102. }
         ])
      "profile extent overrides changed";
    require
      (Float.equal geometry.final_clearance_extent 102.)
      "final row does not clear 48pt FAB, 20pt spacing, and 34pt safe bottom"
  in
  check ~width:320. ~scale:1. ~top_level_extent:84. ~day_extent:48.;
  check ~width:390. ~scale:1. ~top_level_extent:76. ~day_extent:36.;
  check ~width:390. ~scale:2. ~top_level_extent:140. ~day_extent:72.;
  check ~width:1_200. ~scale:3.2 ~top_level_extent:210. ~day_extent:101.
;;

let test_anchor_decisions_replacements_and_route_return () =
  let original = block ~task_state:Journal_model.Todo 40 in
  let state =
    Timeline.empty ~today:20260809
    |> begin_and_apply_feed
         ~generation:1L
         ~before_day:None
         (feed [ day_feed 20260809 "Today" [ original ] ])
  in
  require
    (Timeline.anchor_decision state = Timeline.Reset_to_top)
    "initial load must explicitly reset to a safe top anchor";
  let updated = block ~task_state:Journal_model.Done ~revision:2 40 in
  let replaced = Timeline.replace_block state updated in
  require
    (Timeline.anchor_decision replaced = Timeline.Preserve_visible_slot)
    "task replacement must preserve the stable row";
  require
    (List.exists
       (function
         | Timeline.Top_level entry ->
           Journal_model.task_state entry.block = Journal_model.Done
         | _ -> false)
       (Timeline.retained_slots replaced))
    "task replacement did not update the projected block";
  let prepended =
    Timeline.prepend_timeline_entry replaced (entry (block ~order:"0" 41))
  in
  require
    (Timeline.anchor_decision prepended = Timeline.Reset_to_top)
    "unsupported top insertion must use an explicit safe reset";
  let returned =
    Timeline.return_from_detail prepended ~block_id:(Journal_model.id updated)
  in
  require
    (Timeline.anchor_decision returned = Timeline.Preserve_visible_slot)
    "return from Detail must preserve the current sparse-list slot";
  let before = Timeline.current_window returned in
  let _compact =
    Timeline.extent_geometry
      returned
      ~profile:
        (Journal_visual_tokens.select_row_profile ~viewport_width:320. ~text_scale:1.)
      ~safe_bottom:0.
  in
  let _adaptive =
    Timeline.extent_geometry
      returned
      ~profile:
        (Journal_visual_tokens.select_row_profile ~viewport_width:390. ~text_scale:3.2)
      ~safe_bottom:0.
  in
  require
    (Timeline.current_window returned = before)
    "profile changes must not mutate timeline projection or anchor state"
;;

let test_prepend_first_today_entry_before_older_days () =
  let state =
    Timeline.empty ~today:20260809
    |> begin_and_apply_feed
         ~generation:1L
         ~before_day:None
         (feed [ day_feed 20260808 "Older" [ block ~day:20260808 42 ] ])
  in
  let today = entry (block ~day:20260809 ~order:"0" 43) in
  let prepended = Timeline.prepend_timeline_entry state today in
  match Timeline.retained_slots prepended with
  | Timeline.Top_level actual :: Timeline.Day_heading older :: _ ->
    require
      (String.equal (Journal_model.id actual.block) (Journal_model.id today.block))
      "first today Capture did not become the first Timeline entry";
    require (older.day = 20260808) "older day heading moved ahead of today's Capture"
  | _ -> fail "first today Capture was inserted outside the visible day ordering"
;;

let test_no_measurement_or_renderer_extension_surface_exists () =
  require
    (Timeline.extent_strategy = Timeline.Known_profile_extents)
    "timeline introduced a variable-height estimate or measurement cache";
  require
    (Timeline.renderer_event_surface = [ `Visible_range ])
    "timeline introduced image remeasurement or a renderer extension event"
;;

let require_staged state block_id =
  match Timeline.stage_delete state ~block_id with
  | Some value -> value
  | None -> fail "expected %s to stage" block_id
;;

let test_stage_delete_collapsed_expanded_and_exact_undo () =
  let parent = block ~child_count:3 500 in
  let sibling = block ~order:"z" 501 in
  let initial =
    Timeline.empty ~today:20260809
    |> begin_and_apply_feed
         ~generation:1L
         ~before_day:None
         (feed [ day_feed 20260809 "Today" [ sibling; parent ] ])
  in
  let staged_collapsed, collapsed_backup =
    require_staged initial (Journal_model.id parent)
  in
  require_equal_string_list
    (slot_keys staged_collapsed)
    [ "block:" ^ Journal_model.id sibling; "bottom-clearance" ]
    "collapsed delete removed unrelated slots";
  require
    (Timeline.total_count staged_collapsed = Timeline.total_count initial - 1)
    "collapsed delete did not repair total count";
  require_equal_string_list
    (slot_keys (Timeline.undo_delete collapsed_backup))
    (slot_keys initial)
    "collapsed Undo did not restore exact slots";
  let expanded = Timeline.expand initial ~parent_id:(Journal_model.id parent) in
  let child_a = block ~parent_id:(Journal_model.id parent) 502 in
  let child_b = block ~parent_id:(Journal_model.id parent) ~order:"b" 503 in
  let child_request =
    match Timeline.next_request expanded with
    | Some (Timeline.Children _ as request) -> request
    | _ -> fail "expanded delete fixture omitted a child request"
  in
  let waiting =
    Timeline.begin_request expanded ~generation:2L child_request
  in
  let loaded =
    Timeline.apply_detail
      waiting
      ~generation:2L
      { Journal_graph_projection.root = parent
      ; children =
          { blocks = [ child_a; child_b ]
          ; continuation =
              Some
                { after_sibling_order = Journal_model.sibling_order child_b
                ; after_block_id = Journal_model.id child_b
                ; protocol_cursor = None
                }
          }
      }
  in
  let loaded = Timeline.observe_visible_range loaded ~first_index:0 ~last_exclusive:3 in
  require
    (Timeline.next_request loaded = None)
    "static More exposed an automatic paging request";
  let staged, backup = require_staged loaded (Journal_model.id parent) in
  require_equal_string_list
    (slot_keys staged)
    [ "block:" ^ Journal_model.id sibling; "bottom-clearance" ]
    "expanded delete retained projected descendants or removed a sibling";
  require (Timeline.pending_request staged = None) "staging did not fence pending paging";
  require
    (not (Timeline.is_expanded staged ~block_id:(Journal_model.id parent)))
    "staging retained expanded identity";
  let restored = Timeline.undo_delete backup in
  require_equal_string_list
    (slot_keys restored)
    (slot_keys loaded)
    "Undo changed slot keys";
  require (Timeline.pending_request restored = None) "Undo restored a stale request";
  require
    (Timeline.total_count restored = Timeline.total_count loaded)
    "Undo changed total count";
  require
    (Timeline.is_expanded restored ~block_id:(Journal_model.id parent))
    "Undo lost expansion state";
  require
    (Timeline.anchor_decision restored = Timeline.anchor_decision loaded)
    "Undo changed anchor policy";
  let before_geometry =
    Timeline.extent_geometry
      loaded
      ~profile:
        (Journal_visual_tokens.select_row_profile ~viewport_width:390. ~text_scale:1.)
      ~safe_bottom:34.
  in
  let after_geometry =
    Timeline.extent_geometry
      restored
      ~profile:
        (Journal_visual_tokens.select_row_profile ~viewport_width:390. ~text_scale:1.)
      ~safe_bottom:34.
  in
  require (before_geometry = after_geometry) "Undo changed sparse extent geometry";
  let stale =
    Timeline.apply_detail
      staged
      ~generation:3L
      { root = parent; children = { blocks = [ child_a ]; continuation = None } }
  in
  require
    (slot_keys stale = slot_keys staged)
    "stale fenced response restored deleted rows"
;;

let test_static_child_cannot_stage_delete_and_parent_delete_repairs_heading () =
  let parent = block ~day:20260808 ~child_count:1 510 in
  let state =
    Timeline.empty ~today:20260809
    |> begin_and_apply_feed
         ~generation:1L
         ~before_day:None
         (feed [ day_feed 20260808 "Older" [ parent ] ])
    |> fun state -> Timeline.expand state ~parent_id:(Journal_model.id parent)
  in
  let child =
    block ~day:20260808 ~parent_id:(Journal_model.id parent) ~source:"Visible child" 511
  in
  let child_request =
    match Timeline.next_request state with
    | Some (Timeline.Children _ as request) -> request
    | _ -> fail "child delete fixture omitted a child request"
  in
  let state =
    Timeline.begin_request state ~generation:2L child_request
    |> fun state ->
    Timeline.apply_detail
      state
      ~generation:2L
      { Journal_graph_projection.root = parent
      ; children = { blocks = [ child ]; continuation = None }
      }
  in
  require
    (Timeline.stage_delete state ~block_id:(Journal_model.id child) = None)
    "static child preview exposed a stage-delete path";
  (match Timeline.retained_slots state with
   | Timeline.Day_heading _ :: Timeline.Top_level entry :: _ ->
     require
       (Journal_model.child_count entry.block = 1)
       "rejected child delete mutated the retained parent"
   | _ -> fail "static child delete changed parent projection shape");
  let root_only =
    Timeline.empty ~today:20260809
    |> begin_and_apply_feed
         ~generation:3L
         ~before_day:None
         (feed [ day_feed 20260808 "Older" [ parent ] ])
  in
  let deleted, _ = require_staged root_only (Journal_model.id parent) in
  require_equal_string_list
    (slot_keys deleted)
    [ "bottom-clearance" ]
    "last dated row left an orphan heading";
  require
    (Timeline.stage_delete deleted ~block_id:"forged" = None)
    "forged delete ID was staged"
;;

let () =
  test_projection_order_today_suppression_and_continuations ();
  test_direct_children_insert_after_parent_and_collapse ();
  test_collapsed_child_response_releases_the_matching_request ();
  test_multiple_parent_expansions_drain_without_reusing_epochs ();
  test_stale_generations_and_page_append ();
  test_authoritative_timeline_entry_replaces_summary_by_stable_parent_id ();
  test_ten_thousand_record_rolling_projection_is_bounded ();
  test_fifty_thousand_synthetic_windows_are_bounded ();
  test_exact_profile_extents_and_final_clearance ();
  test_anchor_decisions_replacements_and_route_return ();
  test_prepend_first_today_entry_before_older_days ();
  test_no_measurement_or_renderer_extension_surface_exists ();
  test_stage_delete_collapsed_expanded_and_exact_undo ();
  test_static_child_cannot_stage_delete_and_parent_delete_repairs_heading ()
;;
