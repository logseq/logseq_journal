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

let page day title : Journal_repository.page = { id = id "page" day; day; title }

let feed ?(more = false) days : Journal_repository.feed =
  let slot_count =
    List.fold_left
      (fun count (day : Journal_repository.day_feed) ->
         count + 1 + List.length day.blocks + if day.has_more_blocks then 1 else 0)
      0
      days
  in
  { days; slot_count; has_more_days = more }
;;

let day_feed ?(more = false) day title blocks : Journal_repository.day_feed =
  { page = page day title; blocks; has_more_blocks = more }
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
         | Timeline.Block _
         | Timeline.Day_continuation _
         | Timeline.Children_continuation _
         | Timeline.Feed_continuation _
         | Timeline.Bottom_clearance -> true)
       (Timeline.retained_slots state))
    "Today must not render a duplicate day heading"
;;

let test_direct_children_insert_after_parent_and_collapse () =
  let parent = block ~source:"Parent" ~child_count:3 10 in
  let sibling = block ~order:"b" ~source:"Sibling" 11 in
  let initial =
    Timeline.empty ~today:20260809
    |> begin_and_apply_feed
         ~generation:1L
         ~before_day:None
         (feed [ day_feed 20260809 "Today" [ sibling; parent ] ])
  in
  let expanded = Timeline.expand initial ~parent_id:(Journal_model.id parent) in
  (match Timeline.next_request expanded with
   | Some (Timeline.Children { parent_id; after = None }) ->
     require
       (String.equal parent_id (Journal_model.id parent))
       "child request targeted the wrong parent"
   | _ -> fail "expansion did not expose a bounded child request");
  let child_b =
    block ~parent_id:(Journal_model.id parent) ~order:"b" ~source:"Child B" 13
  in
  let child_a2 =
    block ~parent_id:(Journal_model.id parent) ~order:"a" ~source:"Child A2" 12
  in
  let child_a1 =
    block ~parent_id:(Journal_model.id parent) ~order:"a" ~source:"Child A1" 14
  in
  let detail : Journal_repository.detail =
    { root = parent
    ; children =
        { blocks = [ child_b; child_a2; child_a1 ]
        ; continuation =
            Some { after_sibling_order = "b"; after_block_id = Journal_model.id child_b }
        }
    }
  in
  let loaded =
    Timeline.begin_request
      expanded
      ~generation:2L
      (Timeline.Children { parent_id = Journal_model.id parent; after = None })
  in
  let loaded = Timeline.apply_detail loaded ~generation:2L detail in
  require_equal_string_list
    (slot_keys loaded)
    [ "block:" ^ Journal_model.id parent
    ; "block:" ^ Journal_model.id child_a2
    ; "block:" ^ Journal_model.id child_a1
    ; "block:" ^ Journal_model.id child_b
    ; "children-continuation:" ^ Journal_model.id parent
    ; "block:" ^ Journal_model.id sibling
    ; "bottom-clearance"
    ]
    "direct children were not inserted immediately after their parent";
  (match Timeline.retained_slots loaded with
   | Timeline.Block { depth = 0; _ }
     :: Timeline.Block { depth = 1; _ }
     :: Timeline.Block { depth = 1; _ }
     :: Timeline.Block { depth = 1; _ }
     :: _ -> ()
   | _ -> fail "direct child depth projection changed");
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
  let request = Timeline.Children { parent_id = Journal_model.id parent; after = None } in
  let loading =
    Timeline.expand initial ~parent_id:(Journal_model.id parent)
    |> fun state -> Timeline.begin_request state ~generation:2L request
  in
  let collapsed = Timeline.collapse loading ~parent_id:(Journal_model.id parent) in
  let child = block ~parent_id:(Journal_model.id parent) ~source:"Persisted child" 16 in
  let detail : Journal_repository.detail =
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
  (match Timeline.next_request retry with
   | Some (Timeline.Children { parent_id; after = None }) ->
     require
       (String.equal parent_id (Journal_model.id parent))
       "re-expansion retried the wrong parent"
   | _ -> fail "re-expansion did not retry after the collapsed request completed");
  let newer = Timeline.begin_request retry ~generation:4L request in
  let newer_collapsed = Timeline.collapse newer ~parent_id:(Journal_model.id parent) in
  let after_stale = Timeline.apply_detail newer_collapsed ~generation:3L detail in
  require
    (Timeline.pending_request after_stale = Some (4L, request))
    "a stale child response cleared the newer pending request"
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
    Timeline.apply_block_page
      waiting
      ~generation:9L
      { blocks = [ second ]; continuation = None }
  in
  require
    (slot_keys stale = slot_keys waiting)
    "stale page response mutated timeline state";
  let appended =
    Timeline.apply_block_page
      waiting
      ~generation:11L
      { blocks = [ second ]; continuation = None }
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
          { Journal_repository.after_sibling_order = Journal_model.sibling_order last
          ; after_block_id = Journal_model.id last
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
    := Timeline.apply_block_page !state ~generation:!generation { blocks; continuation };
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

let rec remove_tree path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Sys.readdir path |> Array.iter (fun name -> remove_tree (Filename.concat path name));
    Unix.rmdir path
  | _ -> Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
;;

let require_storage_ok = function
  | Ok value -> value
  | Error error ->
    fail "storage fixture failed: %s" (Journal_storage.Error.to_string error)
;;

let durable_corpus_transaction count =
  let open Datascript in
  let page_id = "82000000-0000-4000-8000-000000000001" in
  let page = Temp_id "timeline-durable-page" in
  let initial =
    [ Add (page, Journal_schema.Attr.page_id, Uuid page_id)
    ; Add (page, Journal_schema.Attr.page_day, Int 20260809)
    ; Add (page, Journal_schema.Attr.page_title, String "2026-08-09")
    ]
  in
  let rec build index reversed =
    if index = count
    then List.rev_append reversed initial
    else (
      let reference = Temp_id (Printf.sprintf "timeline-durable-block:%d" index) in
      let block_id = Printf.sprintf "83000000-0000-4000-a000-%012d" index in
      let mutation_id = Printf.sprintf "84000000-0000-4000-9000-%012d" index in
      let minute = index mod 1_440 in
      let instant = Int64.add 1_786_204_800_000L (Int64.of_int (minute * 60_000)) in
      let operations =
        [ Add (reference, Journal_schema.Attr.block_id, Uuid block_id)
        ; Add (reference, Journal_schema.Attr.block_page, Ref_to page)
        ; Add (reference, Journal_schema.Attr.block_parent, Ref_to page)
        ; Add
            ( reference
            , Journal_schema.Attr.block_order
            , String (Printf.sprintf "%012d" index) )
        ; Add
            ( reference
            , Journal_schema.Attr.block_source
            , String (Printf.sprintf "Durable timeline record %05d" index) )
        ; Add (reference, Journal_schema.Attr.block_task_state, Keyword "not-a-task")
        ; Add
            ( reference
            , Journal_schema.Attr.block_created_instant_unix_ms
            , Int (Int64.to_int instant) )
        ; Add (reference, Journal_schema.Attr.block_created_local_day, Int 20260809)
        ; Add (reference, Journal_schema.Attr.block_created_local_minute, Int minute)
        ; Add
            ( reference
            , Journal_schema.Attr.block_created_time_zone_id
            , String "Asia/Shanghai" )
        ; Add (reference, Journal_schema.Attr.block_created_utc_offset_seconds, Int 28_800)
        ; Add (reference, Journal_schema.Attr.block_revision, Int 1)
        ; Add (reference, Journal_schema.Attr.block_last_mutation_id, Uuid mutation_id)
        ]
      in
      build (index + 1) (List.rev_append operations reversed))
  in
  build 0 []
;;

let test_ten_thousand_record_durable_catch_up_is_bounded () =
  let root = Filename.temp_file "journal-timeline-durable-" "" in
  Sys.remove root;
  Unix.mkdir root 0o700;
  let root = Unix.realpath root in
  Fun.protect
    ~finally:(fun () -> remove_tree root)
    (fun () ->
       let path =
         Journal_storage_path.resolve
           ~support_root:root
           ~relative_path:Journal_startup.database_relative_path
         |> function
         | Ok value -> value
         | Error error ->
           fail "durable path failed: %s" (Journal_storage_path.Error.to_string error)
       in
       let store, _ =
         Journal_storage.open_store ~canonical_path:path |> require_storage_ok
       in
       ignore
         (Journal_storage.transact store (durable_corpus_transaction 10_000)
          |> require_storage_ok);
       Journal_storage.close store |> require_storage_ok;
       let restored, disposition =
         Journal_storage.open_store ~canonical_path:path |> require_storage_ok
       in
       Fun.protect
         ~finally:(fun () -> Journal_storage.close restored |> require_storage_ok)
         (fun () ->
            require
              (disposition = Journal_storage.Restored)
              "10,000-record corpus did not cross a durable restore boundary";
            let database = Journal_storage.current_db restored in
            let initial_feed =
              Journal_repository.load_feed
                database
                ~before_day:None
                ~day_limit:1
                ~blocks_per_day:64
                ~slot_limit:128
              |> function
              | Ok value -> value
              | Error error ->
                fail "durable feed failed: %s" (Journal_repository.Error.to_string error)
            in
            let state =
              ref
                (Timeline.empty ~today:20260809
                 |> begin_and_apply_feed ~generation:1L ~before_day:None initial_feed)
            in
            let generation = ref 2L in
            let has_more = ref true in
            while !has_more do
              match Timeline.next_request !state with
              | Some (Timeline.Day { day; after }) ->
                let page =
                  Journal_repository.load_day_blocks database ~day ~after ~limit:64
                  |> function
                  | Ok value -> value
                  | Error error ->
                    fail
                      "durable page failed: %s"
                      (Journal_repository.Error.to_string error)
                in
                state
                := Timeline.begin_request
                     !state
                     ~generation:!generation
                     (Timeline.Day { day; after });
                state := Timeline.apply_block_page !state ~generation:!generation page;
                state
                := Timeline.observe_visible_range
                     !state
                     ~first_index:(Timeline.total_count !state - 1)
                     ~last_exclusive:(Timeline.total_count !state);
                require
                  (Timeline.retained_slot_count !state <= Timeline.maximum_slots)
                  "durable catch-up exceeded the 512-slot cache";
                require
                  (List.length (Timeline.current_window !state).slots
                   <= Timeline.maximum_supplied_rows)
                  "durable catch-up exceeded the 40-row renderer window";
                generation := Int64.succ !generation;
                has_more := Option.is_some page.continuation
              | Some (Timeline.Feed _ | Timeline.Children _) | None ->
                fail "durable catch-up lost its day cursor"
            done;
            require
              (Timeline.total_count !state = 10_001)
              "durable catch-up projected %d logical slots"
              (Timeline.total_count !state)))
;;

let worker_accepted = function
  | Worker.Accepted request_id -> request_id
  | Full -> fail "release corpus Worker hit backpressure"
  | Not_ready -> fail "release corpus Worker was not ready"
  | Stopping -> fail "release corpus Worker stopped unexpectedly"
;;

let rec worker_drain_until client predicate events =
  let events = events @ Worker.For_testing.drain_events client ~max_events:64 in
  match List.find_opt predicate events with
  | Some event -> event
  | None ->
    Worker.For_testing.await_output client;
    worker_drain_until client predicate events
;;

let worker_ready client =
  Worker.For_testing.await_output client;
  match
    worker_drain_until
      client
      (function
        | Worker.Push { payload = Journal_worker.Ready _; _ } -> true
        | Response _ | Terminal _ -> false)
      []
  with
  | Worker.Push { payload = Ready response; _ } -> response
  | Response _ | Terminal _ -> assert false
;;

let worker_response client request =
  let request_id = worker_accepted (Worker.send client request) in
  match
    worker_drain_until
      client
      (function
        | Worker.Response { request_id = actual; _ } ->
          ID.Worker.Request_id.equal request_id actual
        | Push _ | Terminal _ -> false)
      []
  with
  | Worker.Response { outcome = Completed response; _ } -> response
  | Worker.Response { outcome = Failed error; _ } ->
    fail "release corpus Worker failed: %s" error
  | Worker.Response { outcome = Cancelled; _ } ->
    fail "release corpus Worker request was cancelled"
  | Worker.Response { outcome = Shutdown; _ } ->
    fail "release corpus Worker request was shut down"
  | Push _ | Terminal _ -> assert false
;;

let release_corpus_startup root : Journal_startup.t =
  { application_support_root = root
  ; expected_schema_version = Journal_schema.version
  ; initial_calendar =
      { instant_unix_ms = 1_786_032_000_000L
      ; local_day = 20260807
      ; local_minute_of_day = 0
      ; locale = "en_US"
      ; time_zone_id = "Asia/Shanghai"
      ; utc_offset_seconds = 28_800
      ; generation = 7L
      ; lifecycle_generation = 0L
      }
  ; access_mode = Read_write
  ; diagnostic_mode = Operational_only
  }
;;

let release_corpus_transaction () =
  let open Datascript in
  let page day = Temp_id (Printf.sprintf "release-page:%d" day) in
  let page_id day = Printf.sprintf "85000000-0000-4000-8000-%012d" day in
  let page_operations day =
    let reference = page day in
    [ Add (reference, Journal_schema.Attr.page_id, Uuid (page_id day))
    ; Add (reference, Journal_schema.Attr.page_day, Int day)
    ; Add
        ( reference
        , Journal_schema.Attr.page_title
        , String
            (Printf.sprintf
               "%04d-%02d-%02d"
               (day / 10_000)
               (day / 100 mod 100)
               (day mod 100)) )
    ]
  in
  let block_reference index = Temp_id (Printf.sprintf "release-block:%d" index) in
  let rec build index reversed =
    if index = 10_000
    then
      List.rev_append
        reversed
        (page_operations 20260807 @ page_operations 20260808 @ page_operations 20260809)
    else (
      let child = index >= 9_900 in
      let parent_index = if child then index - 9_900 else index in
      let day =
        if parent_index < 3_300
        then 20260807
        else if parent_index < 6_600
        then 20260808
        else 20260809
      in
      let reference = block_reference index in
      let parent_reference = if child then block_reference parent_index else page day in
      let source =
        if child
        then Printf.sprintf "Bounded direct child %03d" (index - 9_900)
        else if index mod 1_000 = 0
        then Printf.sprintf "Long release record %05d %s" index (String.make 4_096 'x')
        else Printf.sprintf "Release record %05d" index
      in
      let minute = index mod 1_440 in
      let day_offset = day - 20260807 in
      let instant =
        Int64.add
          1_786_032_000_000L
          (Int64.of_int ((day_offset * 86_400_000) + (minute * 60_000)))
      in
      let operations =
        [ Add
            (reference, Journal_schema.Attr.block_id, Uuid (id "block" (100_000 + index)))
        ; Add (reference, Journal_schema.Attr.block_page, Ref_to (page day))
        ; Add (reference, Journal_schema.Attr.block_parent, Ref_to parent_reference)
        ; Add
            ( reference
            , Journal_schema.Attr.block_order
            , String (Printf.sprintf "%012d" (if child then index - 9_900 else index / 2))
            )
        ; Add (reference, Journal_schema.Attr.block_source, String source)
        ; Add
            ( reference
            , Journal_schema.Attr.block_task_state
            , Keyword (if (not child) && index mod 10 = 0 then "todo" else "not-a-task")
            )
        ; Add
            ( reference
            , Journal_schema.Attr.block_created_instant_unix_ms
            , Int (Int64.to_int instant) )
        ; Add (reference, Journal_schema.Attr.block_created_local_day, Int day)
        ; Add (reference, Journal_schema.Attr.block_created_local_minute, Int minute)
        ; Add
            ( reference
            , Journal_schema.Attr.block_created_time_zone_id
            , String "Asia/Shanghai" )
        ; Add (reference, Journal_schema.Attr.block_created_utc_offset_seconds, Int 28_800)
        ; Add (reference, Journal_schema.Attr.block_revision, Int 1)
        ; Add
            ( reference
            , Journal_schema.Attr.block_last_mutation_id
            , Uuid (id "mutation" (100_000 + index)) )
        ]
      in
      build (index + 1) (List.rev_append operations reversed))
  in
  build 0 []
;;

let test_ten_thousand_record_worker_release_corpus_is_bounded () =
  let root = Filename.temp_file "journal-timeline-worker-release-" "" in
  Sys.remove root;
  Unix.mkdir root 0o700;
  Unix.mkdir (Filename.concat root "logseq_journal") 0o700;
  let root = Unix.realpath root in
  Fun.protect
    ~finally:(fun () -> remove_tree root)
    (fun () ->
       let startup = release_corpus_startup root in
       let seed_started = Unix.gettimeofday () in
       let path =
         Journal_storage_path.resolve
           ~support_root:root
           ~relative_path:Journal_startup.database_relative_path
         |> function
         | Ok value -> value
         | Error error ->
           fail
             "release corpus path failed: %s"
             (Journal_storage_path.Error.to_string error)
       in
       let seed_store, _ =
         Journal_storage.open_store ~canonical_path:path |> require_storage_ok
       in
       ignore
         (Journal_storage.transact seed_store (release_corpus_transaction ())
          |> require_storage_ok);
       Journal_storage.close seed_store |> require_storage_ok;
       let seed_seconds = Unix.gettimeofday () -. seed_started in
       let client =
         match
           Worker_runtime.start
             ~runtime_epoch:(ID.Runtime.Epoch.of_int64 9_001L)
             Journal_worker.service
             startup
         with
         | Ok client -> client
         | Error error -> fail "release corpus Worker startup failed: %s" error
       in
       let maximum_payload_bytes = ref 0 in
       let record response =
         maximum_payload_bytes
         := max !maximum_payload_bytes (Journal_worker.estimated_payload_bytes response);
         response
       in
       ignore (worker_ready client |> record);
       let query_started = Unix.gettimeofday () in
       let response =
         worker_response
           client
           (Journal_worker.Load_feed
              { before_day = None
              ; day_limit = 3
              ; blocks_per_day = 64
              ; slot_limit = 128
              ; request_generation = 91L
              })
         |> record
       in
       let query_seconds = Unix.gettimeofday () -. query_started in
       let feed =
         match response.payload with
         | Feed_loaded { request_generation = 91L; feed } -> feed
         | Feed_loaded { request_generation; _ } ->
           fail "release corpus cold feed returned generation %Ld" request_generation
         | Rejected (Invalid_request message) ->
           fail "release corpus cold feed was invalid: %s" message
         | Rejected Recovery_only ->
           fail "release corpus cold feed entered recovery-only mode"
         | Rejected Editing_locked -> fail "release corpus cold feed hit the editing lock"
         | Rejected Stale_calendar_generation ->
           fail "release corpus cold feed used a stale calendar"
         | Rejected Invalid_calendar_snapshot ->
           fail "release corpus cold feed used an invalid calendar"
         | Rejected Storage_unavailable -> fail "release corpus cold feed lost storage"
         | _ -> fail "release corpus cold feed returned an unexpected payload"
       in
       let state =
         Timeline.empty ~today:20260809
         |> begin_and_apply_feed ~generation:91L ~before_day:None feed
       in
       let supplied_rows = List.length (Timeline.current_window state).slots in
       require
         (query_seconds <= 2.)
         "release corpus cold query exceeded 2s budget: %.3fs"
         query_seconds;
       require
         (!maximum_payload_bytes <= 256 * 1_024)
         "release corpus Worker payload exceeded 256KiB: %d bytes"
         !maximum_payload_bytes;
       require
         (Timeline.retained_slot_count state <= Timeline.maximum_slots)
         "release corpus exceeded the 512-slot rolling bound";
       require
         (supplied_rows <= Timeline.maximum_supplied_rows)
         "release corpus supplied %d renderer rows"
         supplied_rows;
       Printf.eprintf
         "release-corpus records=10000 seed_s=%.3f query_s=%.3f payload_bytes=%d \
          slots=%d supplied=%d\n\
          %!"
         seed_seconds
         query_seconds
         !maximum_payload_bytes
         (Timeline.retained_slot_count state)
         supplied_rows;
       Worker_runtime.stop client)
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
  let check ~width ~scale ~block_extent ~day_extent =
    let profile =
      Journal_visual_tokens.select_row_profile ~viewport_width:width ~text_scale:scale
    in
    let geometry = Timeline.extent_geometry state ~profile ~safe_bottom:34. in
    require
      (Float.equal geometry.default_extent block_extent)
      "profile default extent %.1f, expected %.1f"
      geometry.default_extent
      block_extent;
    require
      (geometry.overrides
       = [ { Ui.Native_widget.Sparse_extent_list.index = 0; extent = day_extent }
         ; { Ui.Native_widget.Sparse_extent_list.index = 2; extent = 114. }
         ])
      "profile extent overrides changed";
    require
      (Float.equal geometry.final_clearance_extent 114.)
      "final row does not clear 56pt FAB, 24pt spacing, and 34pt safe bottom"
  in
  check ~width:320. ~scale:1. ~block_extent:80. ~day_extent:48.;
  check ~width:390. ~scale:1. ~block_extent:48. ~day_extent:36.;
  check ~width:390. ~scale:2. ~block_extent:128. ~day_extent:72.;
  check ~width:1_200. ~scale:3.2 ~block_extent:186. ~day_extent:101.
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
         | Timeline.Block { block; _ } ->
           Journal_model.task_state block = Journal_model.Done
         | _ -> false)
       (Timeline.retained_slots replaced))
    "task replacement did not update the projected block";
  let prepended = Timeline.prepend_block replaced (block ~order:"0" 41) in
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
  let waiting =
    Timeline.begin_request
      expanded
      ~generation:2L
      (Timeline.Children { parent_id = Journal_model.id parent; after = None })
  in
  let loaded =
    Timeline.apply_detail
      waiting
      ~generation:2L
      { Journal_repository.root = parent
      ; children =
          { blocks = [ child_a; child_b ]
          ; continuation =
              Some
                { after_sibling_order = Journal_model.sibling_order child_b
                ; after_block_id = Journal_model.id child_b
                }
          }
      }
  in
  let loaded = Timeline.observe_visible_range loaded ~first_index:0 ~last_exclusive:3 in
  let loaded_with_pending =
    Timeline.begin_request
      loaded
      ~generation:3L
      (Timeline.Children
         { parent_id = Journal_model.id parent
         ; after =
             Some
               { after_sibling_order = Journal_model.sibling_order child_b
               ; after_block_id = Journal_model.id child_b
               }
         })
  in
  let staged, backup = require_staged loaded_with_pending (Journal_model.id parent) in
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

let test_stage_visible_child_repairs_parent_and_orphan_heading () =
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
  let state =
    Timeline.begin_request
      state
      ~generation:2L
      (Timeline.Children { parent_id = Journal_model.id parent; after = None })
    |> fun state ->
    Timeline.apply_detail
      state
      ~generation:2L
      { Journal_repository.root = parent
      ; children = { blocks = [ child ]; continuation = None }
      }
  in
  let staged, backup = require_staged state (Journal_model.id child) in
  (match Timeline.retained_slots staged with
   | Timeline.Day_heading _ :: Timeline.Block { block = retained_parent; depth = 0 } :: _
     ->
     require
       (Journal_model.child_count retained_parent = 0)
       "visible child delete did not decrement retained parent"
   | _ -> fail "visible child delete changed parent projection shape");
  require
    (Timeline.undo_delete backup |> slot_keys = slot_keys state)
    "child Undo changed slots";
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
  test_stale_generations_and_page_append ();
  test_ten_thousand_record_rolling_projection_is_bounded ();
  test_ten_thousand_record_durable_catch_up_is_bounded ();
  test_ten_thousand_record_worker_release_corpus_is_bounded ();
  test_fifty_thousand_synthetic_windows_are_bounded ();
  test_exact_profile_extents_and_final_clearance ();
  test_anchor_decisions_replacements_and_route_return ();
  test_no_measurement_or_renderer_extension_surface_exists ();
  test_stage_delete_collapsed_expanded_and_exact_undo ();
  test_stage_visible_child_repairs_parent_and_orphan_heading ()
;;
