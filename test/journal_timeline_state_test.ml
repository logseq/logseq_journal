module Timeline = Journal_timeline_state

let retained_slots state =
  Timeline.fold_slots (fun slots slot -> slot :: slots) [] state |> List.rev
;;

module Ui = Journal_view
module ID = Journal_ids

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
  |> function
  | Ok value -> value
  | Error error -> fail "creation-time fixture failed: %s" error
;;

let block
      ?(day = 20260809)
      ?parent_id
      ?(order = "000000000001")
      ?(source = "Journal entry")
      ?(task_state = Journal_model.No_status)
      ?(child_count = 0)
      ?(revision = "block-1")
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
  else (
    match List.rev entries with
    | [] -> fail "a continued day fixture must contain at least one entry"
    | (entry : Journal_graph_projection.timeline_entry) :: _ ->
      Some
        { Journal_graph_projection.after_sibling_order =
            Journal_model.sibling_order entry.block
        ; after_block_id = Journal_model.id entry.block
        ; protocol_cursor = None
        })
;;

let day_feed ?(more = false) day title blocks : Journal_graph_projection.day_feed =
  let entries = List.map (fun block -> entry block) blocks in
  { page = page day title
  ; entries
  ; has_more_entries = more
  ; continuation = continuation_of_entries ~more entries
  }
;;

let day_feed_entries ?(more = false) day title entries : Journal_graph_projection.day_feed
  =
  { page = page day title
  ; entries
  ; has_more_entries = more
  ; continuation = continuation_of_entries ~more entries
  }
;;

let timeline_page ?(continuation = None) blocks
  : Journal_graph_projection.timeline_entry_page
  =
  { entries = List.map (fun block -> entry block) blocks; continuation }
;;

let begin_and_apply_feed ~generation ~before_day value state =
  let state = Timeline.begin_request state ~generation (Timeline.Feed { before_day }) in
  Timeline.apply_feed state ~generation value
;;

let slot_keys state = retained_slots state |> List.map Timeline.slot_key

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
    ]
    "timeline ordering or continuation projection changed";
  require
    (List.for_all
       (function
         | Timeline.Day_heading page -> page.day <> 20260809
         | Timeline.Top_level _
         | Timeline.Day_continuation _
         | Timeline.Feed_continuation _ -> true)
       (retained_slots state))
    "Today must not render a duplicate day heading"
;;

let require_day_request request ~day label =
  match request with
  | Some (Timeline.Day candidate) ->
    require
      (candidate.day = day)
      "%s targeted day %d instead of %d"
      label
      candidate.day
      day;
    Timeline.Day candidate
  | Some (Timeline.Feed _) | None -> fail "%s did not produce a day request" label
;;

let test_visible_range_demand_drains_in_order_without_another_event () =
  let today_first = block ~source:"Today first" 6 in
  let older_first = block ~day:20260808 ~source:"Older first" 7 in
  let observed =
    Timeline.empty ~today:20260809
    |> begin_and_apply_feed
         ~generation:1L
         ~before_day:None
         (feed
            [ day_feed ~more:true 20260809 "Today" [ today_first ]
            ; day_feed ~more:true 20260808 "Older" [ older_first ]
            ])
    |> Timeline.observe_visible_range ~first_index:0 ~last_exclusive:6
  in
  let first_request =
    require_day_request
      (Timeline.next_request observed)
      ~day:20260809
      "initial visible demand"
  in
  let today_page =
    [ block ~order:"b" ~source:"Today second" 8
    ; block ~order:"c" ~source:"Today third" 9
    ; block ~order:"d" ~source:"Today fourth" 15
    ]
  in
  let after_first =
    Timeline.begin_request observed ~generation:2L first_request
    |> fun state ->
    Timeline.apply_timeline_entry_page state ~generation:2L (timeline_page today_page)
  in
  let second_request =
    require_day_request
      (Timeline.next_request after_first)
      ~day:20260808
      "remaining visible demand"
  in
  let settled =
    Timeline.begin_request after_first ~generation:3L second_request
    |> fun state ->
    Timeline.apply_timeline_entry_page
      state
      ~generation:3L
      (timeline_page [ block ~day:20260808 ~order:"b" ~source:"Older second" 16 ])
  in
  require
    (Timeline.next_request settled = None)
    "completed visible demand required another range event"
;;

let test_visible_range_demand_stops_on_stale_or_nonadvancing_page () =
  let first = block ~source:"Cursor guard first" 17 in
  let observed =
    Timeline.empty ~today:20260809
    |> begin_and_apply_feed
         ~generation:10L
         ~before_day:None
         (feed [ day_feed ~more:true 20260809 "Today" [ first ] ])
    |> Timeline.observe_visible_range ~first_index:0 ~last_exclusive:2
  in
  let request =
    require_day_request
      (Timeline.next_request observed)
      ~day:20260809
      "cursor guard demand"
  in
  let waiting = Timeline.begin_request observed ~generation:11L request in
  let stale =
    Timeline.apply_timeline_entry_page
      waiting
      ~generation:9L
      (timeline_page [ block ~order:"b" ~source:"Stale" 18 ])
  in
  require
    (Timeline.next_request stale = None)
    "a stale page response scheduled follow-up demand";
  let repeated_cursor =
    match request with
    | Timeline.Day { after; _ } -> after
    | Feed _ -> assert false
  in
  let nonadvancing =
    Timeline.apply_timeline_entry_page
      waiting
      ~generation:11L
      (timeline_page ~continuation:repeated_cursor [])
  in
  require
    (Timeline.next_request nonadvancing = None)
    "a non-advancing page cursor created an automatic request loop"
;;

let test_static_parent_never_requests_inline_children () =
  let parent = block ~child_count:400 30 in
  let state =
    Timeline.empty ~today:20260809
    |> begin_and_apply_feed
         ~generation:1L
         ~before_day:None
         (feed [ day_feed 20260809 "Today" [ parent ] ])
    |> Timeline.observe_visible_range ~first_index:0 ~last_exclusive:1
  in
  require (Timeline.next_request state = None) "static parent requested inline children";
  require_equal_string_list
    (slot_keys state)
    [ "block:" ^ Journal_model.id parent ]
    "static parent materialized inline child slots"
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
    |> Timeline.observe_visible_range ~first_index:0 ~last_exclusive:2
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
    Timeline.apply_timeline_entry_page waiting ~generation:9L (timeline_page [ second ])
  in
  require
    (slot_keys stale = slot_keys waiting)
    "stale page response mutated timeline state";
  let appended =
    Timeline.apply_timeline_entry_page waiting ~generation:11L (timeline_page [ second ])
  in
  require_equal_string_list
    (slot_keys appended)
    [ "block:" ^ Journal_model.id first; "block:" ^ Journal_model.id second ]
    "day page did not replace its continuation"
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
         (feed [ day_feed_entries 20260809 "Today" [ initial_entry ] ])
  in
  let refreshed_summary : Journal_graph_projection.child_summary =
    { block_id = id "block" 24; source = "Promoted summary" }
  in
  let refreshed =
    Timeline.replace_timeline_entry
      state
      (entry ~child_summaries:[ refreshed_summary ] parent)
  in
  (match retained_slots refreshed with
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

let test_ten_thousand_record_projection_preserves_loaded_history () =
  let initial_blocks = make_page 0 64 in
  let state =
    ref
      (Timeline.empty ~today:20260809
       |> begin_and_apply_feed
            ~generation:1L
            ~before_day:None
            (feed ~more:false [ day_feed ~more:true 20260809 "Today" initial_blocks ])
       |> Timeline.observe_visible_range ~first_index:63 ~last_exclusive:65)
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
          { Journal_graph_projection.after_sibling_order =
              Journal_model.sibling_order last
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
      (Timeline.retained_slot_count !state = Timeline.total_count !state)
      "10,000-record catch-up discarded loaded history; retained %d slots"
      (Timeline.retained_slot_count !state);
    next_index := !next_index + count;
    generation := Int64.succ !generation
  done;
  require (Timeline.total_count !state = 10_000) "logical count lost records";
  require
    (Timeline.first_retained_index !state = 0)
    "loaded prefix no longer starts at its first row";
  let retained = !state in
  require
    (Timeline.find_block retained ~block_id:(id "block" 0) <> None)
    "loaded history lost the earliest block";
  let top = Timeline.observe_visible_range retained ~first_index:0 ~last_exclusive:12 in
  require
    (Option.get (Timeline.retained_slot top 0)
     |> Timeline.slot_key
     = "block:" ^ id "block" 0)
    "scrolling back could not render the earliest loaded row"
;;

let test_block_replacement () =
  let original = block ~task_state:Journal_model.Todo 40 in
  let state =
    Timeline.empty ~today:20260809
    |> begin_and_apply_feed
         ~generation:1L
         ~before_day:None
         (feed [ day_feed 20260809 "Today" [ original ] ])
  in
  let updated = block ~task_state:Journal_model.Done ~revision:"block-2" 40 in
  let replaced = Timeline.replace_block state updated in
  require
    (List.exists
       (function
         | Timeline.Top_level entry ->
           Journal_model.task_state entry.block = Journal_model.Done
         | _ -> false)
       (retained_slots replaced))
    "task replacement did not update the projected block"
;;

let test_populated_feed_refresh_preserves_position () =
  let parent = block ~child_count:1 ~order:"m" 42 in
  let leading =
    List.init 10 (fun index ->
      block ~order:(String.make 1 (Char.chr (Char.code 'a' + index))) (43 + index))
  in
  let trailing = block ~order:"z" 54 in
  let initial =
    Timeline.empty ~today:20260809
    |> begin_and_apply_feed
         ~generation:1L
         ~before_day:None
         (feed [ day_feed 20260809 "Today" (leading @ [ parent; trailing ]) ])
  in
  let populated =
    initial |> Timeline.observe_visible_range ~first_index:8 ~last_exclusive:12
  in
  let populated_anchor = Timeline.first_visible_index populated in
  let refreshed_parent = block ~child_count:1 ~order:"m" ~revision:"block-2" 42 in
  let refreshed =
    Timeline.begin_request populated ~generation:3L (Timeline.Feed { before_day = None })
    |> fun state ->
    Timeline.apply_feed
      state
      ~generation:3L
      (feed [ day_feed 20260809 "Today" (leading @ [ refreshed_parent; trailing ]) ])
  in
  require
    (Timeline.first_visible_index refreshed = populated_anchor && populated_anchor > 0)
    "calendar refresh moved the visible anchor"
;;

let test_initial_feed_refresh_supersedes_pending_pagination () =
  let first = block 46 in
  let paging =
    Timeline.empty ~today:20260809
    |> begin_and_apply_feed
         ~generation:1L
         ~before_day:None
         (feed [ day_feed ~more:true 20260809 "Today" [ first ] ])
    |> Timeline.observe_visible_range ~first_index:0 ~last_exclusive:2
  in
  let day_request =
    match Timeline.next_request paging with
    | Some (Timeline.Day _ as request) -> request
    | Some (Timeline.Feed _) | None ->
      fail "refresh supersession fixture omitted pagination"
  in
  let refreshing =
    Timeline.begin_request paging ~generation:2L day_request
    |> fun state ->
    Timeline.begin_request state ~generation:3L (Timeline.Feed { before_day = None })
  in
  require
    (Timeline.pending_request refreshing = Some (3L, Timeline.Feed { before_day = None }))
    "a foreground refresh did not supersede obsolete pagination"
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
  match retained_slots prepended with
  | Timeline.Top_level actual :: Timeline.Day_heading older :: _ ->
    require
      (String.equal (Journal_model.id actual.block) (Journal_model.id today.block))
      "first today Capture did not become the first Timeline entry";
    require (older.day = 20260808) "older day heading moved ahead of today's Capture"
  | _ -> fail "first today Capture was inserted outside the visible day ordering"
;;

let require_staged state block_id =
  match Timeline.stage_delete state ~block_id with
  | Some value -> value
  | None -> fail "expected %s to stage" block_id
;;

let test_stage_delete_and_exact_undo () =
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
    [ "block:" ^ Journal_model.id sibling ]
    "collapsed delete removed unrelated slots";
  require
    (Timeline.total_count staged_collapsed = Timeline.total_count initial - 1)
    "collapsed delete did not repair total count";
  require_equal_string_list
    (slot_keys (Timeline.undo_delete staged_collapsed collapsed_backup))
    (slot_keys initial)
    "collapsed Undo did not restore exact slots";
  let loaded = initial in
  let loaded = Timeline.observe_visible_range loaded ~first_index:0 ~last_exclusive:3 in
  require
    (Timeline.next_request loaded = None)
    "static More exposed an automatic paging request";
  let staged, backup = require_staged loaded (Journal_model.id parent) in
  require_equal_string_list
    (slot_keys staged)
    [ "block:" ^ Journal_model.id sibling ]
    "expanded delete retained projected descendants or removed a sibling";
  require (Timeline.pending_request staged = None) "staging did not fence pending paging";
  let restored = Timeline.undo_delete staged backup in
  require_equal_string_list
    (slot_keys restored)
    (slot_keys loaded)
    "Undo changed slot keys";
  require (Timeline.pending_request restored = None) "Undo restored a stale request";
  require
    (Timeline.total_count restored = Timeline.total_count loaded)
    "Undo changed total count"
;;

let test_static_child_cannot_stage_delete_and_parent_delete_repairs_heading () =
  let parent = block ~day:20260808 ~child_count:1 510 in
  let state =
    Timeline.empty ~today:20260809
    |> begin_and_apply_feed
         ~generation:1L
         ~before_day:None
         (feed [ day_feed 20260808 "Older" [ parent ] ])
  in
  let child =
    block ~day:20260808 ~parent_id:(Journal_model.id parent) ~source:"Visible child" 511
  in
  require
    (Timeline.stage_delete state ~block_id:(Journal_model.id child) = None)
    "static child preview exposed a stage-delete path";
  (match retained_slots state with
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
  require_equal_string_list (slot_keys deleted) [] "last dated row left an orphan heading";
  require
    (Timeline.stage_delete deleted ~block_id:"forged" = None)
    "forged delete ID was staged"
;;

let paginating_day () =
  let initial = block ~order:"b" 1 in
  let state =
    Timeline.empty ~today:20260809
    |> begin_and_apply_feed
         ~generation:1L
         ~before_day:None
         (feed ~more:true [ day_feed ~more:true 20260809 "Today" [ initial ] ])
  in
  let after = continuation_of_entries ~more:true [ entry initial ] in
  Timeline.begin_request state ~generation:2L (Day { day = 20260809; after })
;;

let stale_day state generation =
  Timeline.fail_day_request
    state
    ~generation
    ~day:20260809
    ~stale_cursor:true
    ~message:"Changed"
;;

let begin_next state generation =
  match Timeline.next_request state with
  | None -> fail "missing next recovery request"
  | Some request -> Timeline.begin_request state ~generation request
;;

let test_stale_day_rebuild_is_atomic_and_generation_owned () =
  let pending = paginating_day () in
  let ignored = stale_day pending 99L in
  require
    (Timeline.pending_request ignored = Timeline.pending_request pending)
    "obsolete failure cleared a request";
  let recovering = stale_day pending 2L in
  require
    (Timeline.pending_request recovering = None)
    "stale request retained pending ownership";
  require
    (Timeline.next_request recovering = Some (Day { day = 20260809; after = None }))
    "recovery reused the stale cursor";
  let recovering = begin_next recovering 3L in
  let continuation = continuation_of_entries ~more:true [ entry (block ~order:"a" 2) ] in
  let staged =
    Timeline.apply_timeline_entry_page
      recovering
      ~generation:3L
      (timeline_page ~continuation [ block ~order:"a" 2 ])
  in
  require_equal_string_list
    (slot_keys staged)
    (slot_keys pending)
    "partial recovery changed visible rows";
  let staged = begin_next staged 4L in
  let late =
    Timeline.apply_timeline_entry_page staged ~generation:3L (timeline_page [ block 9 ])
  in
  require
    (Timeline.pending_request late = Timeline.pending_request staged)
    "late chunk stole recovery ownership";
  let complete =
    Timeline.apply_timeline_entry_page
      late
      ~generation:4L
      (timeline_page [ block ~order:"c" 3 ])
  in
  require_equal_string_list
    (slot_keys complete)
    [ "block:" ^ id "block" 2; "block:" ^ id "block" 3; "feed-continuation:20260809" ]
    "recovery did not replace deleted rows in sibling order";
  require (Timeline.pending_request complete = None) "recovery did not complete";
  require
    (Timeline.day_error complete ~day:20260809 = None)
    "successful recovery retained error"
;;

let test_repeated_staleness_stops_until_retry_and_does_not_block_feed () =
  let state =
    paginating_day ()
    |> fun state -> stale_day state 2L |> fun state -> begin_next state 3L
  in
  let failed = stale_day state 3L in
  require
    (Timeline.pending_request failed = None)
    "repeated stale result retained Loading";
  require
    (Option.is_some (Timeline.day_error failed ~day:20260809))
    "repeated stale result has no retry state";
  let failed =
    Timeline.observe_visible_range
      failed
      ~first_index:0
      ~last_exclusive:(Timeline.total_count failed)
  in
  require
    (Timeline.next_request failed = Some (Feed { before_day = Some 20260809 }))
    "failed day blocked older days or automatically retried";
  let retried = Timeline.retry_day failed ~day:20260809 in
  require
    (Timeline.next_request retried = Some (Day { day = 20260809; after = None }))
    "explicit Retry did not reset recovery";
  let retried = begin_next retried 4L in
  let ignored = stale_day retried 3L in
  require
    (Timeline.pending_request ignored = Timeline.pending_request retried)
    "older Retry failure cleared newer request";
  let complete =
    Timeline.apply_timeline_entry_page ignored ~generation:4L (timeline_page [ block 4 ])
  in
  require (Timeline.day_error complete ~day:20260809 = None) "Retry did not recover"
;;

let test_terminal_day_failure_and_listener_supersession () =
  let state = paginating_day () in
  let failed =
    Timeline.fail_day_request
      state
      ~generation:2L
      ~day:20260809
      ~stale_cursor:false
      ~message:"Unavailable"
  in
  require
    (Timeline.pending_request failed = None)
    "ordinary read failure retained pending ownership";
  require
    (Timeline.next_request failed = None)
    "ordinary failure automatically started recovery";
  let recovering = stale_day state 2L |> fun state -> begin_next state 3L in
  let changed = Timeline.replace_block recovering (block ~source:"Live update" 1) in
  require
    (Timeline.pending_request changed = None)
    "live update did not invalidate staging";
  let late =
    Timeline.apply_timeline_entry_page changed ~generation:3L (timeline_page [ block 2 ])
  in
  require_equal_string_list
    (slot_keys late)
    (slot_keys changed)
    "late recovery overwrote a listener update";
  let fresh_graph = Timeline.empty ~today:20260809 in
  let late_graph =
    Timeline.apply_timeline_entry_page
      fresh_graph
      ~generation:3L
      (timeline_page [ block 2 ])
  in
  require
    (Timeline.retained_slot_count late_graph = 0)
    "old graph completion populated a new graph"
;;

let test_feed_refresh_supersedes_recovery_between_chunks () =
  let state =
    paginating_day ()
    |> fun state -> stale_day state 2L |> fun state -> begin_next state 3L
  in
  let continuation = continuation_of_entries ~more:true [ entry (block 2) ] in
  let staged =
    Timeline.apply_timeline_entry_page
      state
      ~generation:3L
      (timeline_page ~continuation [ block 2 ])
  in
  let refreshed =
    begin_and_apply_feed
      ~generation:4L
      ~before_day:None
      (feed [ day_feed 20260809 "Today" [ block 5 ] ])
      staged
  in
  require
    (Timeline.next_request refreshed = None)
    "feed refresh revived superseded staging";
  require_equal_string_list
    (slot_keys refreshed)
    [ "block:" ^ id "block" 5 ]
    "feed refresh lost its authoritative rows"
;;

let test_recovery_work_budget_and_empty_heading_context () =
  let state = paginating_day () |> fun state -> stale_day state 2L in
  let rec chunks generation count state =
    if count = 16
    then state
    else (
      let state = begin_next state generation in
      let value = block ~order:(Printf.sprintf "%04d" count) (count + 10) in
      let continuation = continuation_of_entries ~more:true [ entry value ] in
      chunks
        (Int64.succ generation)
        (count + 1)
        (Timeline.apply_timeline_entry_page
           state
           ~generation
           (timeline_page ~continuation [ value ])))
  in
  let bounded = chunks 3L 0 state in
  require (Timeline.pending_request bounded = None) "work limit retained Loading";
  require
    (Option.is_some (Timeline.day_error bounded ~day:20260809))
    "work exhaustion claimed success";
  require_equal_string_list
    (slot_keys bounded)
    (slot_keys state)
    "work exhaustion published incomplete staging";
  let empty_days =
    Timeline.empty ~today:20260809
    |> begin_and_apply_feed
         ~generation:1L
         ~before_day:None
         (feed [ day_feed 20260808 "Saturday" []; day_feed 20260807 "Friday" [] ])
  in
  require_equal_string_list (slot_keys empty_days) [] "empty days left heading spacing"
;;

let test_empty_days_remain_absent_after_history_paging () =
  let day_at index =
    ((2026 - (index / 336)) * 10000)
    + ((12 - (index mod 336 / 28)) * 100)
    + 28
    - (index mod 28)
  in
  let rec append batch before state =
    if batch = 180
    then state
    else (
      let days =
        List.init 3 (fun offset ->
          day_feed (day_at ((batch * 3) + offset)) "Empty journal" [])
      in
      let state =
        begin_and_apply_feed
          ~generation:(Int64.of_int (batch + 1))
          ~before_day:before
          (feed ~more:true days)
          state
      in
      append (batch + 1) (Some (day_at ((batch * 3) + 2))) state)
  in
  let state = append 0 None (Timeline.empty ~today:20990101) in
  require_equal_string_list
    (slot_keys state)
    [ "feed-continuation:" ^ string_of_int (day_at 539) ]
    "rolling empty batches reserved retained headings";
  require (Timeline.total_count state = 1) "empty batches accumulated virtual extents"
;;

let test_page_replacement_invalidates_pending_continuation () =
  let initial = block 1 in
  let state =
    Timeline.empty ~today:20260809
    |> begin_and_apply_feed
         ~generation:1L
         ~before_day:None
         (feed [ day_feed ~more:true 20260809 "Today" [ initial ] ])
  in
  let after = continuation_of_entries ~more:true [ entry initial ] in
  let state =
    Timeline.begin_request state ~generation:2L (Day { day = 20260809; after })
  in
  let replacement = timeline_page [ block ~source:"Authoritative replacement" 2 ] in
  let replaced =
    Timeline.replace_timeline_entry_page state ~page:(page 20260809 "Today") replacement
  in
  require
    (Timeline.pending_request replaced = None)
    "authoritative replacement retained the obsolete pagination request";
  let late =
    Timeline.apply_timeline_entry_page replaced ~generation:2L (timeline_page [ block 3 ])
  in
  require_equal_string_list
    (slot_keys late)
    (slot_keys replaced)
    "late continuation changed the replacement"
;;

let test_capture_identity_converges_with_reconciliation () =
  let captured = block ~task_state:Journal_model.Todo ~child_count:1 901 in
  let updated =
    block ~source:"Completed capture" ~task_state:Journal_model.Todo ~child_count:1 901
  in
  let initial =
    Timeline.empty ~today:20260809
    |> begin_and_apply_feed
         ~generation:1L
         ~before_day:None
         (feed ~more:true [ day_feed ~more:true 20260809 "Today" [ captured ] ])
  in
  let initial_keys = slot_keys initial in
  let completed = Timeline.prepend_timeline_entry initial (entry updated) in
  let repeated = Timeline.prepend_timeline_entry completed (entry updated) in
  require_equal_string_list
    (slot_keys repeated)
    initial_keys
    "Capture completion duplicated a reconciled identity or lost child/paging slots";
  require
    (Timeline.total_count repeated = Timeline.total_count initial)
    "duplicate completion increased the virtualized count";
  require
    (List.exists
       (function
         | Timeline.Top_level e ->
           Journal_model.source e.block = Journal_model.source updated
         | _ -> false)
       (retained_slots repeated))
    "completion did not update the existing entry";
  let absent = Timeline.empty ~today:20260809 in
  let completed_first = Timeline.prepend_timeline_entry absent (entry captured) in
  let reconciled =
    Timeline.replace_timeline_entry_page
      completed_first
      ~page:(page 20260809 "Today")
      (timeline_page [ updated ])
  in
  let repeated = Timeline.prepend_timeline_entry reconciled (entry updated) in
  require_equal_string_list
    (slot_keys repeated)
    [ "block:" ^ Journal_model.id captured ]
    "completion-before-reconciliation did not converge";
  require
    (Timeline.total_count repeated = 1)
    "completion-before-reconciliation count changed"
;;

let test_capture_converges_with_later_pagination () =
  let failures = ref [] in
  let check condition message = if not condition then failures := message :: !failures in
  List.iter
    (fun day ->
       let first = block ~day ~order:"a0" 910 in
       let middle = block ~day ~order:"a1" 911 in
       let captured = block ~day ~order:"a2" ~source:"Captured" 912 in
       let authoritative =
         block ~day ~order:"a2" ~source:"Authoritative capture" ~revision:"block-2" 912
       in
       let neighbor = block ~day:20260807 ~order:"a0" 913 in
       let first_cursor = continuation_of_entries ~more:true [ entry first ] in
       let next_cursor = continuation_of_entries ~more:true [ entry middle ] in
       let initial =
         Timeline.empty ~today:20260809
         |> begin_and_apply_feed
              ~generation:1L
              ~before_day:None
              (feed
                 [ day_feed ~more:true day "Capture day" [ first ]
                 ; day_feed 20260807 "Earlier day" [ neighbor ]
                 ])
       in
       let captured_state = Timeline.prepend_timeline_entry initial (entry captured) in
       let apply state generation after value =
         let state =
           Timeline.begin_request state ~generation (Timeline.Day { day; after })
         in
         Timeline.apply_timeline_entry_page state ~generation value
       in
       let middle_state =
         apply
           captured_state
           2L
           first_cursor
           (timeline_page ~continuation:next_cursor [ middle ])
       in
       let day_entries state =
         retained_slots state
         |> List.filter_map (function
           | Timeline.Top_level value when Journal_model.journal_day value.block = day ->
             Some value.block
           | _ -> None)
       in
       check
         (List.map Journal_model.id (day_entries middle_state)
          = List.map Journal_model.id [ first; middle; captured ])
         "pagination placed an earlier sibling after Capture";
       let completed =
         apply middle_state 3L next_cursor (timeline_page [ authoritative ])
       in
       check
         (List.map Journal_model.source (day_entries completed)
          = List.map Journal_model.source [ first; middle; authoritative ])
         "final pagination duplicated Capture or retained its stale projection";
       let expected_count = if day = 20260809 then 5 else 6 in
       check
         (Timeline.total_count completed = expected_count)
         "pagination counted a captured identity twice";
       check
         (Timeline.retained_slot_count completed = expected_count)
         "pagination retained duplicate row slots";
       check
         (Timeline.find_block completed ~block_id:(Journal_model.id neighbor)
          = Some neighbor)
         "pagination modified a neighboring day";
       check
         (Timeline.pending_request completed = None
          && Timeline.next_request completed = None)
         "completed pagination retained a request";
       check
         (slot_keys
            (Timeline.apply_timeline_entry_page
               completed
               ~generation:3L
               (timeline_page [ authoritative ]))
          = slot_keys completed)
         "a repeated completion changed the timeline")
    [ 20260809; 20260808 ];
  require (!failures = []) "%s" (String.concat "\n" (List.rev !failures))
;;

let test_persistent_point_updates_and_undo () =
  let blocks = List.init 512 (fun n -> block ~order:(Printf.sprintf "%012d" n) n) in
  let initial =
    Timeline.empty ~today:20260809
    |> begin_and_apply_feed
         ~generation:1L
         ~before_day:None
         (feed [ day_feed 20260809 "Today" blocks ])
  in
  let replacement = block ~order:"000000000511" ~source:"Updated sibling" 511 in
  Gc.full_major ();
  let live_before = (Gc.stat ()).live_words in
  let updated = Timeline.replace_block initial replacement in
  Gc.full_major ();
  let retained_words = (Gc.stat ()).live_words - live_before in
  require (slot_keys initial = slot_keys updated) "point update changed slot ordering";
  let staged, backup = require_staged initial (id "block" 256) in
  let changed = Timeline.replace_block staged replacement in
  let inserted = block ~order:"000000000600" 600 |> entry in
  let restored =
    Timeline.undo_delete (Timeline.prepend_timeline_entry changed inserted) backup
  in
  let find_source state block_id =
    retained_slots state
    |> List.find_map (function
      | Timeline.Top_level entry when Journal_model.id entry.block = block_id ->
        Some (Journal_model.source entry.block)
      | _ -> None)
  in
  require
    (find_source initial (id "block" 511) = Some "Journal entry")
    "persistent update mutated the retained old state";
  require
    (find_source restored (id "block" 511) = Some "Updated sibling")
    "undo discarded an intervening point update";
  require
    (find_source restored (id "block" 600) = Some "Journal entry")
    "undo discarded an intervening insertion";
  require
    (find_source restored (id "block" 256) = Some "Journal entry")
    "undo did not restore the deleted target";
  require
    (Timeline.retained_slot_count restored = 513)
    "Undo discarded a loaded sibling to enforce an obsolete retention cap";
  require
    (retained_words < 600)
    "one point update retained %d new words; expected less than 600 with structural \
     sharing"
    retained_words
;;

let test_empty_day_visibility_boundaries () =
  let load blocks =
    Timeline.empty ~today:20260809
    |> begin_and_apply_feed
         ~generation:1L
         ~before_day:None
         (feed [ day_feed 20260808 "Saturday" blocks ])
  in
  require_equal_string_list (slot_keys (load [])) [] "zero-block day must disappear";
  List.iter
    (fun blocks ->
       let state = load blocks in
       require_equal_string_list (slot_keys state) [] "complete empty day must disappear";
       require (Timeline.total_count state = 0) "hidden day reserved slots")
    [ []
    ; [ block ~day:20260808 ~source:"" 1 ]
    ; [ block ~day:20260808 ~source:" \t\r\n " 1 ]
    ];
  let visible =
    [ [ block ~day:20260808 ~source:"** **" 1 ]
    ; [ block ~day:20260808 ~source:"" ~child_count:1 1 ]
    ; [ block ~day:20260808 ~source:"" 1; block ~day:20260808 ~source:" " 2 ]
    ]
    @ List.map
        (fun task_state -> [ block ~day:20260808 ~source:"" ~task_state 1 ])
        Journal_model.
          [ Todo; Doing; In_review; Now; Done; Canceled; Backlog; Waiting; Later ]
  in
  List.iter
    (fun blocks ->
       require
         (Timeline.total_count (load blocks) = 1 + List.length blocks)
         "qualifying day was hidden")
    visible
;;

let test_empty_day_mutations_and_undo () =
  let placeholder = block ~day:20260808 ~source:" " 1 in
  let sibling = block ~day:20260808 ~order:"b" 2 in
  let older = block ~day:20260807 3 in
  let initial =
    Timeline.empty ~today:20260809
    |> begin_and_apply_feed
         ~generation:1L
         ~before_day:None
         (feed
            [ day_feed 20260808 "Saturday" [ placeholder ]
            ; day_feed 20260807 "Friday" [ older ]
            ])
  in
  let older_keys = [ "day:20260807"; "block:" ^ Journal_model.id older ] in
  require_equal_string_list
    (slot_keys initial)
    older_keys
    "initial placeholder visibility";
  require
    (Option.is_some
       (Timeline.find_block initial ~block_id:(Journal_model.id placeholder)))
    "hidden placeholder lost its graph identity";
  let content = block ~day:20260808 ~source:"Written later" 1 in
  let visible = Timeline.replace_block initial content in
  require
    (Timeline.total_count visible = 4)
    "editing hidden block did not restore its heading";
  let hidden = Timeline.replace_timeline_entry visible (entry placeholder) in
  require_equal_string_list (slot_keys hidden) older_keys "clearing content left a gap";
  let task =
    Timeline.replace_block hidden (block ~day:20260808 ~source:"" ~task_state:Todo 1)
  in
  require (Timeline.total_count task = 4) "task change did not restore day";
  let child =
    Timeline.replace_block hidden (block ~day:20260808 ~source:"" ~child_count:1 1)
  in
  require (Timeline.total_count child = 4) "child count did not restore day";
  let hidden = Timeline.replace_block child placeholder in
  let two = Timeline.prepend_timeline_entry hidden (entry sibling) in
  require (Timeline.total_count two = 5) "creation lost the hidden sibling";
  let deleted, backup =
    Option.get (Timeline.stage_delete two ~block_id:(Journal_model.id sibling))
  in
  require_equal_string_list
    (slot_keys deleted)
    older_keys
    "delete failed to hide remaining placeholder";
  let changed = Timeline.replace_block deleted content in
  let undone = Timeline.undo_delete changed backup in
  require (Timeline.total_count undone = 5) "undo did not restore complete section";
  require
    (Journal_model.source
       (Option.get (Timeline.find_block undone ~block_id:(Journal_model.id placeholder)))
     = "Written later")
    "undo overwrote a later edit to a hidden sibling";
  let removed = Timeline.remove_block hidden ~block_id:(Journal_model.id placeholder) in
  require
    (Timeline.find_block removed ~block_id:(Journal_model.id placeholder) = None)
    "removing hidden block retained its identity";
  let recreated = Timeline.prepend_timeline_entry removed (entry sibling) in
  require
    (Timeline.total_count recreated = 4)
    "creation in an empty historical day lost heading";
  let refreshed =
    begin_and_apply_feed
      ~generation:2L
      ~before_day:None
      (feed [ day_feed 20260808 "Saturday" [] ])
      recreated
  in
  require_equal_string_list
    (slot_keys refreshed)
    []
    "refresh did not hide newly empty day";
  let replaced =
    Timeline.replace_timeline_entry_page
      refreshed
      ~page:(page 20260808 "Saturday")
      (timeline_page [ content ])
  in
  require
    (Timeline.total_count replaced = 2)
    "page completion could not restore a hidden day";
  let today =
    Timeline.empty ~today:20260809
    |> begin_and_apply_feed
         ~generation:1L
         ~before_day:None
         (feed [ day_feed 20260809 "Today" [] ])
    |> fun state -> Timeline.prepend_timeline_entry state (entry (block 5))
  in
  require_equal_string_list
    (slot_keys today)
    [ "block:" ^ id "block" 5 ]
    "today acquired a duplicate heading"
;;

let test_hidden_day_restoration_orders_siblings () =
  let placeholder = block ~day:20260808 ~order:"z" ~source:"" 1 in
  let state =
    Timeline.empty ~today:20260809
    |> begin_and_apply_feed
         ~generation:1L
         ~before_day:None
         (feed [ day_feed 20260808 "Saturday" [ placeholder ] ])
  in
  let earlier = block ~day:20260808 ~order:"a" 2 in
  let restored = Timeline.prepend_timeline_entry state (entry earlier) in
  require_equal_string_list
    (slot_keys restored)
    [ "day:20260808"
    ; "block:" ^ Journal_model.id earlier
    ; "block:" ^ Journal_model.id placeholder
    ]
    "restoring a hidden sibling broke its source order";
  let parent = block ~day:20260808 ~order:"z" ~source:"" ~child_count:1 1 in
  let visible = Timeline.replace_block state parent in
  let hidden = Timeline.replace_block visible placeholder in
  require_equal_string_list
    (slot_keys hidden)
    []
    "removing last child left its empty parent";
  require
    (Timeline.pending_request hidden = None)
    "hidden parent held pending child ownership"
;;

let test_empty_day_pagination_and_failure () =
  let placeholder = block ~day:20260808 ~source:"" 1 in
  let initial =
    Timeline.empty ~today:20260809
    |> begin_and_apply_feed
         ~generation:1L
         ~before_day:None
         (feed ~more:true [ day_feed ~more:true 20260808 "Saturday" [ placeholder ] ])
    |> fun state -> Timeline.observe_visible_range state ~first_index:0 ~last_exclusive:4
  in
  let request = Option.get (Timeline.next_request initial) in
  let pending = Timeline.begin_request initial ~generation:2L request in
  let failed =
    Timeline.fail_day_request
      pending
      ~generation:2L
      ~day:20260808
      ~stale_cursor:false
      ~message:"Offline"
  in
  require
    (List.mem "day-continuation:20260808" (slot_keys failed))
    "failed partial day lost retry affordance";
  let completed =
    Timeline.apply_timeline_entry_page pending ~generation:2L (timeline_page [])
  in
  require_equal_string_list
    (slot_keys completed)
    [ "feed-continuation:20260808" ]
    "complete placeholder day was not removed";
  require
    (Timeline.next_request completed = Some (Feed { before_day = Some 20260808 }))
    "hidden day stopped visible feed demand";
  let empty_batch =
    begin_and_apply_feed
      ~generation:3L
      ~before_day:(Some 20260808)
      (feed ~more:true [ day_feed 20260807 "Friday" [] ])
      completed
  in
  require
    (Timeline.next_request empty_batch = Some (Feed { before_day = Some 20260807 }))
    "empty batch did not advance by fetched boundary";
  let populated =
    begin_and_apply_feed
      ~generation:4L
      ~before_day:(Some 20260807)
      (feed [ day_feed 20260807 "Friday" [ block ~day:20260807 3 ] ])
      empty_batch
  in
  require (Timeline.total_count populated = 2) "older populated date became unreachable";
  let unknown = { (day_feed 20260808 "Saturday" []) with has_more_entries = true } in
  let state =
    Timeline.empty ~today:20260809
    |> begin_and_apply_feed ~generation:1L ~before_day:None (feed [ unknown ])
  in
  require_equal_string_list
    (slot_keys state)
    [ "day:20260808"; "day-continuation:20260808" ]
    "unknown day was mistaken for empty"
;;

let test_empty_day_retained_fragment_and_anchor () =
  let blocks =
    List.init 520 (fun index ->
      block
        ~day:20260808
        ~order:(Printf.sprintf "%04d" index)
        ~source:(if index = 519 then "" else "Content")
        (index + 1))
  in
  let state =
    Timeline.empty ~today:20260809
    |> begin_and_apply_feed
         ~generation:1L
         ~before_day:None
         (feed [ day_feed 20260808 "Saturday" blocks ])
  in
  let fragment =
    List.fold_left
      (fun state index -> Timeline.remove_block state ~block_id:(id "block" index))
      state
      (List.init 511 (fun i -> i + 9))
  in
  require
    (List.mem ("block:" ^ id "block" 520) (slot_keys fragment))
    "one retained placeholder was mistaken for the full day";
  let placeholder = block ~day:20260808 ~source:"" 701 in
  let state =
    Timeline.empty ~today:20260809
    |> begin_and_apply_feed
         ~generation:1L
         ~before_day:None
         (feed
            [ day_feed 20260808 "Saturday" [ block ~day:20260808 701 ]
            ; day_feed
                20260807
                "Friday"
                (List.init 60 (fun i -> block ~day:20260807 (i + 800)))
            ])
    |> fun state ->
    Timeline.observe_visible_range state ~first_index:30 ~last_exclusive:35
  in
  let visible_anchor state =
    Timeline.retained_slot
      state
      (Timeline.first_visible_index state - Timeline.first_retained_index state)
    |> Option.get
    |> Timeline.slot_key
  in
  let anchor = visible_anchor state in
  let hidden = Timeline.replace_block state placeholder in
  require
    (Timeline.total_count hidden = Timeline.total_count state - 2)
    "hidden section count was stale";
  require
    (visible_anchor hidden = anchor)
    "hiding a preceding day moved the visible anchor";
  let restored = Timeline.replace_block hidden (block ~day:20260808 701) in
  require
    (visible_anchor restored = anchor)
    "restoring a preceding day moved the visible anchor"
;;

let test_parent_insertion_preserves_all_loaded_rows () =
  let parent = block ~order:"z" ~child_count:4 520 in
  let state =
    Timeline.empty ~today:20260809
    |> begin_and_apply_feed
         ~generation:1L
         ~before_day:None
         (feed
            [ day_feed
                20260809
                "Today"
                (List.init 519 (fun index ->
                   block ~order:(Printf.sprintf "%04d" index) (index + 1)))
            ])
  in
  let state = Timeline.prepend_timeline_entry state (entry parent) in
  let loaded = state in
  require
    (Timeline.retained_slot_count loaded = 520)
    "parent insertion discarded loaded rows"
;;

let test_capture_scroll_commands_are_explicit () =
  let initial =
    Timeline.empty ~today:20260809
    |> begin_and_apply_feed
         ~generation:1L
         ~before_day:None
         (feed [ day_feed 20260809 "Today" (make_page 0 20) ])
  in
  let scrolled =
    Timeline.observe_visible_range initial ~first_index:10 ~last_exclusive:20
  in
  let captured =
    Timeline.prepend_timeline_entry scrolled (entry (block ~order:"new" 30001))
  in
  require
    (Timeline.scroll_generation captured > Timeline.scroll_generation scrolled)
    "Capture did not request a new native scroll command";
  require
    (Timeline.first_visible_index captured = 0)
    "Capture did not reset pagination visibility to the top";
  require
    (Timeline.scroll_target captured
     = Some (Timeline.scroll_generation captured, 20260809, "block:" ^ id "block" 0))
    "Capture must target the first Journal row, not its chronologically later insertion";
  let observed =
    Timeline.observe_visible_range captured ~first_index:0 ~last_exclusive:10
  in
  require
    (Timeline.scroll_generation observed = Timeline.scroll_generation captured)
    "native visibility repeated the Capture scroll command";
  let updated =
    Timeline.replace_block observed (block ~order:"new" ~source:"Updated" 30001)
  in
  require
    (Timeline.scroll_generation updated = Timeline.scroll_generation captured)
    "background content update requested a scroll reset";
  let second =
    Timeline.prepend_timeline_entry updated (entry (block ~order:"newer" 30002))
  in
  require
    (Timeline.scroll_generation second > Timeline.scroll_generation captured)
    "second Capture reused the previous native scroll command"
;;

let test_capture_scroll_terminal_ownership () =
  let first =
    Timeline.prepend_timeline_entry
      (Timeline.empty ~today:20260809)
      (entry (block ~order:"first" 40001))
  in
  let token = Timeline.scroll_generation first in
  let request = Timeline.scroll_target first in
  require (Option.is_some request) "Capture must freeze a row target";
  let refreshed =
    Timeline.reset first ~today:20260809
    |> begin_and_apply_feed
         ~generation:2L
         ~before_day:None
         (feed [ day_feed 20260809 "Today" [ block ~order:"first" 40001 ] ])
  in
  require
    (Timeline.scroll_target refreshed = request)
    "same-graph feed refresh cancelled an uncompleted Capture scroll";
  let observed = Timeline.observe_visible_range first ~first_index:0 ~last_exclusive:1 in
  require
    (Timeline.scroll_target observed = request)
    "visibility must not complete scrolling";
  let second =
    Timeline.prepend_timeline_entry observed (entry (block ~order:"second" 40002))
  in
  let latest = Timeline.scroll_target second in
  List.iter
    (fun outcome ->
       let stale = Timeline.complete_scroll second ~token ~outcome in
       require
         (Timeline.scroll_target stale = latest)
         "stale completion consumed a replacement scroll";
       let completed =
         Timeline.complete_scroll
           stale
           ~token:(Timeline.scroll_generation second)
           ~outcome
       in
       require
         (Timeline.scroll_target completed = None)
         "terminal outcome did not release scroll request";
       require
         (Timeline.scroll_outcome completed = Some outcome)
         "terminal outcome was lost";
       let duplicate = Timeline.complete_scroll completed ~token ~outcome in
       require
         (Timeline.scroll_outcome duplicate = Some outcome)
         "duplicate completion changed state")
    Ui.Event.Payload.
      [ Succeeded; Missing_target; Cancelled; Superseded; Positioning_failed ]
;;

let () =
  test_capture_converges_with_later_pagination ();
  test_capture_scroll_commands_are_explicit ();
  test_capture_scroll_terminal_ownership ();
  test_static_parent_never_requests_inline_children ();
  test_parent_insertion_preserves_all_loaded_rows ();
  test_hidden_day_restoration_orders_siblings ();
  test_empty_day_visibility_boundaries ();
  test_empty_day_mutations_and_undo ();
  test_empty_day_pagination_and_failure ();
  test_empty_day_retained_fragment_and_anchor ();
  test_persistent_point_updates_and_undo ();
  test_capture_identity_converges_with_reconciliation ();
  test_stale_day_rebuild_is_atomic_and_generation_owned ();
  test_repeated_staleness_stops_until_retry_and_does_not_block_feed ();
  test_terminal_day_failure_and_listener_supersession ();
  test_feed_refresh_supersedes_recovery_between_chunks ();
  test_recovery_work_budget_and_empty_heading_context ();
  test_empty_days_remain_absent_after_history_paging ();
  test_page_replacement_invalidates_pending_continuation ();
  test_projection_order_today_suppression_and_continuations ();
  test_visible_range_demand_drains_in_order_without_another_event ();
  test_visible_range_demand_stops_on_stale_or_nonadvancing_page ();
  test_stale_generations_and_page_append ();
  test_authoritative_timeline_entry_replaces_summary_by_stable_parent_id ();
  test_ten_thousand_record_projection_preserves_loaded_history ();
  test_block_replacement ();
  test_populated_feed_refresh_preserves_position ();
  test_initial_feed_refresh_supersedes_pending_pagination ();
  test_prepend_first_today_entry_before_older_days ();
  test_stage_delete_and_exact_undo ();
  test_static_child_cannot_stage_delete_and_parent_delete_repairs_heading ()
;;
