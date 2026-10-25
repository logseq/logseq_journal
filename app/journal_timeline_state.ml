type request =
  | Feed of { cursor : Journal_graph_projection.feed_cursor option }
  | Day of
      { day : int
      ; after : Journal_graph_projection.block_cursor option
      }

type slot =
  | Day_heading of Journal_graph_projection.page
  | Top_level of Journal_graph_projection.timeline_entry
  | Day_continuation of
      { day : int
      ; after : Journal_graph_projection.block_cursor option
      }
  | Feed_continuation of { cursor : Journal_graph_projection.feed_cursor }

type recovery =
  { day : int
  ; target_count : int
  ; anchor_ids : string list
  ; entries : Journal_graph_projection.timeline_entry list
  ; next_cursor : Journal_graph_projection.block_cursor option
  ; reads : int
  }

module Days = Map.Make (Int)
module Entries = Map.Make (String)

(* Loaded rows remain addressable for native List navigation.
   Hidden placeholders remain available for updates without visible rows. *)
type day_knowledge =
  { page : Journal_graph_projection.page
  ; block_count : int
  ; complete : bool
  ; hidden : bool
  ; hidden_entry : Journal_graph_projection.timeline_entry option
  }

type t =
  { today : int
  ; slots : slot Rrbvec.t
  ; days : day_knowledge Days.t
  ; visible_first : int
  ; visible_last_exclusive : int
  ; scroll_generation : int64
  ; scroll_target : (int64 * int * string) option
  ; scroll_outcome : Journal_view.View.Native_list.outcome option
  ; visible_demand : request list option
  ; pending : (int64 * request) option
  ; recovery : recovery option
  ; day_failures : (int * string) list
  }

let maximum_hidden_days = 512
let maximum_recovery_entries = 512
let initial_visible_count = 40
let prefetch_margin = 4

let empty ~today =
  { today
  ; slots = Rrbvec.empty
  ; days = Days.empty
  ; visible_first = 0
  ; visible_last_exclusive = 0
  ; scroll_generation = 0L
  ; scroll_target = None
  ; scroll_outcome = None
  ; visible_demand = None
  ; pending = None
  ; recovery = None
  ; day_failures = []
  }
;;

let reset (state : t) ~today =
  { (empty ~today) with
    scroll_generation = state.scroll_generation
  ; scroll_target = state.scroll_target
  ; scroll_outcome = state.scroll_outcome
  }
;;

let compare_blocks left right =
  match
    String.compare (Journal_model.sibling_order left) (Journal_model.sibling_order right)
  with
  | 0 -> String.compare (Journal_model.id left) (Journal_model.id right)
  | comparison -> comparison
;;

let slot_key = function
  | Day_heading page -> "day:" ^ string_of_int page.Journal_graph_projection.day
  | Top_level entry -> "block:" ^ Journal_model.id entry.block
  | Day_continuation { day; _ } -> "day-continuation:" ^ string_of_int day
  | Feed_continuation { cursor } ->
    "feed-continuation:"
    ^ Option.fold ~none:"latest" ~some:string_of_int cursor.before_day
    ^ Option.fold
        ~none:""
        ~some:(fun day -> ":skip:" ^ string_of_int day)
        cursor.skipped_day
;;
let slice slots start stop = Rrbvec.subvec slots start stop |> Option.get

let splice slots start stop replacement =
  Rrbvec.append
    (Rrbvec.append (slice slots 0 start) replacement)
    (slice slots stop (Rrbvec.length slots))
;;

let find_slot_index predicate slots =
  let index = ref (-1) in
  Rrbvec.find_map
    (fun slot ->
       incr index;
       if predicate slot then Some !index else None)
    slots
;;

let slot_block = function
  | Top_level entry -> Some entry.Journal_graph_projection.block
  | Day_heading _ | Day_continuation _ | Feed_continuation _ -> None
;;

let filter_map_slots f slots =
  Rrbvec.fold_right
    (fun slot rest ->
       match f slot with
       | None -> rest
       | Some value -> value :: rest)
    slots
    []
;;

let update_slots replacement slots =
  let updated = ref slots in
  Rrbvec.iteri
    (fun index slot ->
       match replacement slot with
       | None -> ()
       | Some replacement -> updated := Rrbvec.set !updated index replacement)
    slots;
  !updated
;;

let filter_slots keep slots =
  let result = ref Rrbvec.empty in
  let start = ref 0 in
  Rrbvec.iteri
    (fun index slot ->
       if not (keep slot)
       then (
         result := Rrbvec.append !result (slice slots !start index);
         start := index + 1))
    slots;
  if !start = 0
  then slots
  else Rrbvec.append !result (slice slots !start (Rrbvec.length slots))
;;

let slot_day = function
  | Day_heading page -> Some page.Journal_graph_projection.day
  | Top_level entry -> Some (Journal_model.journal_day entry.block)
  | Day_continuation { day; _ } -> Some day
  | Feed_continuation _ -> None
;;

let empty_parent (entry : Journal_graph_projection.timeline_entry) =
  String.equal (String.trim (Journal_model.source entry.block)) ""
  && not (Journal_model.has_tags entry.block)
  && not (Journal_model.has_attachments entry.block)
;;

let insert_day_slots slots day replacement =
  let index =
    find_slot_index
      (fun slot ->
         match slot_day slot with
         | Some candidate -> candidate <= day
         | None ->
           (match slot with
            | Feed_continuation _ -> true
            | _ -> false))
      slots
    |> Option.value ~default:(Rrbvec.length slots)
  in
  splice slots index index (Rrbvec.of_list replacement)
;;

let insert_entry slots (entry : Journal_graph_projection.timeline_entry) =
  let block = entry.block in
  let day = Journal_model.journal_day block in
  let index =
    find_slot_index
      (function
        | Top_level candidate ->
          let candidate_day = Journal_model.journal_day candidate.block in
          day > candidate_day
          || (day = candidate_day && compare_blocks block candidate.block <= 0)
        | Day_heading page -> day > page.day
        | Day_continuation candidate -> day >= candidate.day
        | Feed_continuation _ -> true)
      slots
    |> Option.value ~default:(Rrbvec.length slots)
  in
  splice slots index index (Rrbvec.singleton (Top_level entry))
;;

let preserve_anchor (before : t) (state : t) =
  let anchor = Rrbvec.nth_opt before.slots before.visible_first |> Option.map slot_key in
  let visible_first =
    Option.bind anchor (fun key ->
      find_slot_index (fun slot -> String.equal (slot_key slot) key) state.slots)
    |> Option.fold
         ~none:(min before.visible_first (Rrbvec.length state.slots))
         ~some:(fun index -> index)
  in
  { state with
    visible_first
  ; visible_last_exclusive =
      min
        (Rrbvec.length state.slots)
        (visible_first + max 0 (before.visible_last_exclusive - before.visible_first))
  }
;;

let normalize_days (state : t) =
  (* Apply parent visibility to point updates as well as projected pages.
     Child count and status are deliberately not qualifying content. *)
  let removed = Hashtbl.create 8 in
  let candidates = Hashtbl.create 8 in
  let slots =
    ref
      (filter_slots
         (function
           | Top_level entry when empty_parent entry ->
             let day = Journal_model.journal_day entry.block in
             Hashtbl.replace
               removed
               day
               (1 + Option.value (Hashtbl.find_opt removed day) ~default:0);
             if not (Hashtbl.mem candidates day) then Hashtbl.add candidates day entry;
             false
           | _ -> true)
         state.slots)
  in
  let days =
    Days.mapi
      (fun day knowledge ->
         let block_count =
           max
             0
             (knowledge.block_count
              - Option.value (Hashtbl.find_opt removed day) ~default:0)
         in
         let hidden_entry =
           if block_count = 0
           then (
             match Hashtbl.find_opt candidates day with
             | Some entry -> Some entry
             | None -> knowledge.hidden_entry)
           else (
             match knowledge.hidden_entry with
             | Some entry when empty_parent entry -> None
             | entry -> entry)
         in
         let knowledge = { knowledge with block_count; hidden_entry } in
         if
           (not knowledge.hidden)
           && ((not knowledge.complete) || knowledge.block_count > 1)
         then knowledge
         else (
           let entry =
             match knowledge.hidden_entry with
             | Some _ as entry -> entry
             | None ->
               Rrbvec.find_map
                 (function
                   | Top_level entry when Journal_model.journal_day entry.block = day ->
                     Some entry
                   | _ -> None)
                 !slots
           in
           let hidden =
             knowledge.complete
             && (knowledge.block_count = 0
                 || (knowledge.block_count = 1
                     && Option.fold ~none:false ~some:empty_parent entry))
           in
           if hidden
           then (
             slots := filter_slots (fun slot -> slot_day slot <> Some day) !slots;
             { knowledge with hidden = true; hidden_entry = entry })
           else if knowledge.hidden
           then (
             Option.iter
               (fun entry -> slots := insert_entry !slots entry)
               knowledge.hidden_entry;
             if day <> state.today
             then slots := insert_day_slots !slots day [ Day_heading knowledge.page ];
             { knowledge with hidden = false; hidden_entry = None })
           else knowledge))
      state.days
  in
  { state with slots = !slots; days }
;;

let prune_days (state : t) =
  let retained_days =
    Rrbvec.fold_left
      (fun days slot ->
         match slot_day slot with
         | None -> days
         | Some day -> Days.add day () days)
      Days.empty
      state.slots
  in
  let hidden_budget = ref (max 0 (maximum_hidden_days - Days.cardinal retained_days)) in
  let days =
    Days.filter
      (fun day knowledge ->
         if Days.mem day retained_days
         then true
         else if knowledge.hidden && !hidden_budget > 0
         then (
           decr hidden_budget;
           true)
         else false)
      state.days
  in
  { state with days }
;;

let update_day state day f =
  { state with days = Days.update day (Option.map f) state.days }
;;

let knowledge_of_feed (day : Journal_graph_projection.day_feed) =
  { page = day.page
  ; block_count = List.length day.entries
  ; complete = not day.has_more_entries
  ; hidden = false
  ; hidden_entry = None
  }
;;

let finish_change before state =
  normalize_days state |> preserve_anchor before |> prune_days
;;

let begin_request (state : t) ~generation request =
  match state.pending, request with
  | Some (pending_generation, _), Feed { cursor = None }
    when Int64.compare generation pending_generation > 0 ->
    { state with
      pending = Some (generation, request)
    ; recovery = None
    ; day_failures = []
    }
  | Some _, _ -> state
  | None, Feed { cursor = None } ->
    { state with
      pending = Some (generation, request)
    ; recovery = None
    ; day_failures = []
    }
  | None, _ -> { state with pending = Some (generation, request) }
;;

let fail_feed_request state ~generation =
  match state.pending with
  | Some (expected, Feed _) when generation = expected ->
    {state with pending=None;visible_demand=Some []}
  | _ -> state
;;

let day_error (state : t) ~day = List.assoc_opt day state.day_failures

let terminal_day_failure (state : t) ~day message =
  { state with
    pending = None
  ; recovery = None
  ; day_failures = (day, message) :: List.remove_assoc day state.day_failures
  }
;;

let start_recovery (state : t) ~day =
  let day_entries =
    filter_map_slots
      (function
        | Top_level entry when Journal_model.journal_day entry.block = day -> Some entry
        | _ -> None)
      state.slots
  in
  let anchor_ids =
    let anchor_index = max 0 state.visible_first in
    let indexed = ref [] in
    Rrbvec.iteri
      (fun index slot ->
         match slot_block slot with
         | Some block -> indexed := (index, Journal_model.id block) :: !indexed
         | None -> ())
      state.slots;
    !indexed
    |> List.sort (fun (left, _) (right, _) ->
      match Int.compare (abs (left - anchor_index)) (abs (right - anchor_index)) with
      | 0 -> Int.compare right left
      | order -> order)
    |> List.map snd
  in
  { state with
    pending = None
  ; day_failures = List.remove_assoc day state.day_failures
  ; recovery =
      Some
        { day
        ; target_count = List.length day_entries + 30
        ; anchor_ids
        ; entries = []
        ; next_cursor = None
        ; reads = 0
        }
  }
;;

let fail_day_request (state : t) ~generation ~day ~stale_cursor ~message =
  match state.pending with
  | Some (expected, Day request) when Int64.equal expected generation && request.day = day
    ->
    if stale_cursor && Option.is_none state.recovery && Option.is_some request.after
    then start_recovery state ~day
    else terminal_day_failure state ~day message
  | _ -> state
;;

let retry_day (state : t) ~day =
  if Option.is_some state.pending || Option.is_none (day_error state ~day)
  then state
  else start_recovery state ~day
;;

let invalidate_recovery_for_day (state : t) day =
  match state.recovery with
  | Some recovery when recovery.day = day ->
    terminal_day_failure
      state
      ~day
      "Journal entries changed while reloading. Retry to continue."
  | _ -> state
;;

let day_slots ~today (day : Journal_graph_projection.day_feed) =
  let entries =
    List.sort
      (fun (left : Journal_graph_projection.timeline_entry)
        (right : Journal_graph_projection.timeline_entry) ->
         compare_blocks left.block right.block)
      day.entries
  in
  let heading = if day.page.day = today then [] else [ Day_heading day.page ] in
  let rows = List.map (fun entry -> Top_level entry) entries in
  let continuation =
    if day.has_more_entries
    then [ Day_continuation { day = day.page.day; after = day.continuation } ]
    else []
  in
  heading @ rows @ continuation
;;

let feed_slots ~today (feed : Journal_graph_projection.feed) =
  let days =
    List.sort
      (fun left right ->
         Int.compare right.Journal_graph_projection.page.day left.page.day)
      feed.days
  in
  let rows = List.concat_map (day_slots ~today) days in
  let continuation = Option.fold ~none:[] ~some:(fun cursor -> [Feed_continuation {cursor}]) feed.continuation in
  rows @ continuation
;;

let request_of_slot = function
  | Day_continuation { day; after } -> Some (Day { day; after })
  | Feed_continuation { cursor } -> Some (Feed { cursor = Some cursor })
  | Day_heading _ | Top_level _ -> None
;;

let request_is_retained (state : t) request =
  Rrbvec.exists
    (fun slot ->
       match request_of_slot slot with
       | Some candidate -> candidate = request
       | None -> false)
    state.slots
;;

let visible_requests (state : t) ~first_index ~last_exclusive =
  let lower = max 0 (first_index - prefetch_margin) in
  let upper = min (Rrbvec.length state.slots) (last_exclusive + prefetch_margin) in
  let length = Rrbvec.length state.slots in
  let start = min length (max 0 lower) in
  let stop = min length (max start upper) in
  slice state.slots start stop
  |> filter_map_slots (fun slot ->
    match request_of_slot slot with
    | Some ((Day _ | Feed _) as request) -> Some request
    | None -> None)
;;

let next_visible_request (state : t) requests =
  List.find_opt
    (fun request ->
       request_is_retained state request
       &&
       match request with
       | Day { day; _ } -> Option.is_none (day_error state ~day)
       | _ -> true)
    requests
;;

let complete_visible_request ?successor state request =
  if Option.is_some state.pending
  then state
  else (
    let successor =
      match successor with
      | Some candidate
        when List.mem
               candidate
               (visible_requests
                  state
                  ~first_index:state.visible_first
                  ~last_exclusive:state.visible_last_exclusive) -> Some candidate
      | None | Some _ -> None
    in
    { state with
      visible_demand =
        Option.map
          (List.concat_map (fun candidate ->
             if candidate = request then Option.to_list successor else [ candidate ]))
          state.visible_demand
    })
;;

let stop_visible_drain state =
  if Option.is_some state.pending
  then state
  else { state with visible_demand = Option.map (fun _ -> []) state.visible_demand }
;;

let merge_feed_days (state : t) incoming =
  List.fold_left
    (fun state (d : Journal_graph_projection.day_feed) ->
       let old_last =
         Rrbvec.fold_left
           (fun last -> function
              | Top_level e when Journal_model.journal_day e.block = d.page.day ->
                Some e.block
              | _ -> last)
           None
           state.slots
       in
       let old_cursor =
         Rrbvec.find_map
           (function
             | Day_continuation c when c.day = d.page.day -> Some c.after
             | _ -> None)
           state.slots
         |> Option.join
       in
       let fresh_last =
         List.find_opt (fun _ -> true) (List.rev d.entries)
         |> Option.map (fun (e : Journal_graph_projection.timeline_entry) -> e.block)
       in
       let continuation =
         match old_last, fresh_last with
         | Some old, Some fresh when compare_blocks old fresh > 0 -> old_cursor
         | _ -> d.continuation
       in
       let fresh_ids =
         List.fold_left
           (fun ids (e : Journal_graph_projection.timeline_entry) ->
              Entries.add (Journal_model.id e.block) () ids)
           Entries.empty
           d.entries
       in
       let removed = ref Days.empty in
       let slots =
         filter_slots
           (function
             | Top_level e when Entries.mem (Journal_model.id e.block) fresh_ids ->
               let day = Journal_model.journal_day e.block in
               removed
               := Days.update day (fun n -> Some (1 + Option.value n ~default:0)) !removed;
               false
             | Day_continuation c when c.day = d.page.day -> false
             | _ -> true)
           state.slots
       in
       let slots = List.fold_left insert_entry slots d.entries in
       let slots =
         if
           d.page.day <> state.today
           && not
                (Rrbvec.exists
                   (function
                     | Day_heading p -> p.day = d.page.day
                     | _ -> false)
                   slots)
         then insert_day_slots slots d.page.day [ Day_heading d.page ]
         else slots
       in
       let slots =
         match continuation with
         | None -> slots
         | Some _ ->
           let index =
             find_slot_index
               (fun slot ->
                  Option.fold
                    ~none:true
                    ~some:(fun day -> day < d.page.day)
                    (slot_day slot))
               slots
             |> Option.value ~default:(Rrbvec.length slots)
           in
           splice
             slots
             index
             index
             (Rrbvec.singleton
                (Day_continuation { day = d.page.day; after = continuation }))
       in
       let days =
         Days.fold
           (fun day n ->
              Days.update
                day
                (Option.map (fun k -> { k with block_count = max 0 (k.block_count - n) })))
           !removed
           state.days
       in
       let retained =
         Option.fold
           ~none:0
           ~some:(fun k -> k.block_count)
           (Days.find_opt d.page.day days)
       in
       let knowledge =
         { (knowledge_of_feed d) with
           block_count = retained + List.length d.entries
         ; complete = Option.is_none continuation
         }
       in
       { state with slots; days = Days.add d.page.day knowledge days })
    state
    incoming
;;
let apply_feed_dates (state : t) ~generation feed =
  match state.pending with
  | Some (expected_generation, Feed { cursor })
    when Int64.equal expected_generation generation ->
    let before = state in
    let days =
      List.fold_left
        (fun days day ->
           Days.add day.Journal_graph_projection.page.day (knowledge_of_feed day) days)
        (match cursor with
         | None -> Days.empty
         | Some _ -> state.days)
        feed.Journal_graph_projection.days
    in
    let state = { state with days } in
    let projected = feed_slots ~today:state.today feed in
    (match cursor with
     | None when Rrbvec.is_empty state.slots ->
       { state with
         slots = Rrbvec.of_list projected
       ; visible_first = 0
       ; visible_last_exclusive = min initial_visible_count (List.length projected)
       ; visible_demand = None
       ; pending = None
       }
       |> normalize_days
       |> prune_days
     | None ->
       let slots = Rrbvec.of_list projected in
       { state with slots; visible_demand = None; pending = None } |> finish_change before
     | Some expected_cursor ->
       let request = Feed { cursor = Some expected_cursor } in
       let state =
         if not (request_is_retained before request)
         then before
         else (
           let state = merge_feed_days before feed.days in
           let slots =
             filter_slots
               (function
                 | Feed_continuation _ -> false
                 | _ -> true)
               state.slots
           in
           let slots =
             match feed.continuation with
             | None -> slots
             | Some cursor -> Rrbvec.push_back slots (Feed_continuation { cursor })
           in
           { state with slots; pending = None } |> finish_change before)
       in
       let successor =
         List.find_map
           (function
             | Feed_continuation { cursor } -> Some (Feed { cursor = Some cursor })
             | _ -> None)
           projected
       in
       if successor = Some request
       then stop_visible_drain state
       else complete_visible_request ?successor state request)
  | Some _ | None -> state
;;
let refresh_chronological_feed (state : t) ~generation ~complete (feed : Journal_graph_projection.feed) =
  match state.pending with
  | Some (expected, Feed { cursor = None }) when expected = generation ->
    let exhausted =
      complete
      && (Option.is_none feed.continuation)
      && List.for_all
           (fun (d : Journal_graph_projection.day_feed) -> not d.has_more_entries)
           feed.days
    in
    let cutoff =
      List.fold_left
        (fun last (d : Journal_graph_projection.day_feed) ->
           List.fold_left
             (fun _ (e : Journal_graph_projection.timeline_entry) -> Some e.block)
             last
             d.entries)
        None
        feed.days
    in
    (match cutoff with
     | None ->
       if exhausted
       then apply_feed_dates state ~generation feed
       else { state with pending = None }
     | Some _ when exhausted -> apply_feed_dates state ~generation feed
     | Some cutoff ->
       let day = Journal_model.journal_day cutoff in
       let start =
         find_slot_index
           (function
             | Top_level e ->
               let candidate = Journal_model.journal_day e.block in
               candidate < day || (candidate = day && compare_blocks e.block cutoff > 0)
             | Day_heading p -> p.day < day
             | Day_continuation d -> d.day < day
             | Feed_continuation _ -> false)
           state.slots
       in
       (match start with
        | None -> apply_feed_dates state ~generation feed
        | Some start ->
          let same_day_tail =
            match Rrbvec.nth state.slots start with
            | Top_level e -> Journal_model.journal_day e.block = day
            | _ -> false
          in
          let prefix =
            feed_slots ~today:state.today feed
            |> List.filter (function
              | Feed_continuation _ -> false
              | Day_continuation d when d.day = day && same_day_tail -> false
              | _ -> true)
            |> Rrbvec.of_list
          in
          let prefix_ids =
            Rrbvec.fold_left
              (fun ids -> function
                 | Top_level e -> Entries.add (Journal_model.id e.block) () ids
                 | _ -> ids)
              Entries.empty
              prefix
          in
          let moved_from = ref Days.empty in
          let suffix =
            slice state.slots start (Rrbvec.length state.slots)
            |> filter_slots (function
              | Top_level e when Entries.mem (Journal_model.id e.block) prefix_ids ->
                let day = Journal_model.journal_day e.block in
                moved_from := Days.update day
                    (fun count -> Some (1 + Option.value count ~default:0)) !moved_from;
                false
              | _ -> true)
          in
          let days =
            List.fold_left
              (fun days (d : Journal_graph_projection.day_feed) ->
                 Days.add d.page.day (knowledge_of_feed d) days)
              state.days
              feed.days
          in
          let days =
            if not same_day_tail
            then days
            else (
              let removed =
                Rrbvec.fold_left
                  (fun n -> function
                     | Top_level e when Journal_model.journal_day e.block = day -> n + 1
                     | _ -> n)
                  0
                  (slice state.slots 0 start)
              in
              let old = Days.find day state.days in
              Days.update
                day
                (Option.map (fun fresh ->
                   { fresh with
                     block_count = fresh.block_count + max 0 (old.block_count - removed)
                   ; complete = old.complete
                   }))
                days)
          in
          let days =
            Days.fold
              (fun day count days ->
                 Days.update day
                   (Option.map (fun knowledge ->
                      { knowledge with block_count = max 0 (knowledge.block_count - count) }))
                   days)
              !moved_from
              days
          in
          { state with
            slots = Rrbvec.append prefix suffix
          ; days
          ; pending = None
          ; visible_demand = None
          }
          |> finish_change state))
  | _ -> state
;;

(* Today and the chronological prefix cover separate ranges. Refresh each
   against its retained rows, then restore date order and the original UUID anchor. *)
let refresh_feed (state : t) ~generation ~complete (feed : Journal_graph_projection.feed) =
  match state.pending, feed.prioritized_day with
  | Some (expected, Feed { cursor = None }), Some today when expected = generation ->
    let fresh_ids =
      List.fold_left
        (fun ids (d : Journal_graph_projection.day_feed) ->
           List.fold_left
             (fun ids (e : Journal_graph_projection.timeline_entry) ->
                Entries.add
                  (Journal_model.id e.block)
                  (Journal_model.journal_day e.block)
                  ids)
             ids
             d.entries)
        Entries.empty
        feed.days
    in
    let removed = ref Days.empty in
    let slots =
      filter_slots
        (function
          | Top_level e ->
            let day = Journal_model.journal_day e.block in
            (match Entries.find_opt (Journal_model.id e.block) fresh_ids with
             | Some target when target <> day ->
               removed
               := Days.update day (fun n -> Some (1 + Option.value n ~default:0)) !removed;
               false
             | _ -> true)
          | _ -> true)
        state.slots
    in
    let days =
      Days.fold
        (fun day n ->
           Days.update
             day
             (Option.map (fun k -> { k with block_count = max 0 (k.block_count - n) })))
        !removed
        state.days
    in
    let cleaned = { state with slots; days } in
    let today_slots =
      filter_slots (fun slot -> slot_day slot = Some today) cleaned.slots
    in
    let today_state =
      { cleaned with
        slots = today_slots
      ; days = Days.filter (fun day _ -> day = today) days
      }
    in
    let today_feed =
      List.find_opt
        (fun (d : Journal_graph_projection.day_feed) -> d.page.day = today)
        feed.days
    in
    let today_value =
      { feed with
        days = Option.to_list today_feed
      ; continuation = None
      ; prioritized_day = None
      }
    in
    let today_state =
      match today_feed with
      | Some d when d.has_more_entries ->
        refresh_chronological_feed today_state ~generation ~complete today_value
      | _ -> apply_feed_dates today_state ~generation today_value
    in
    let chronological =
      { cleaned with
        slots = filter_slots (fun slot -> slot_day slot <> Some today) cleaned.slots
      ; days = Days.remove today days
      }
    in
    let chronological_days =
      List.filter
        (fun (d : Journal_graph_projection.day_feed) -> d.page.day <> today)
        feed.days
    in
    let chronological_value =
      { feed with days = chronological_days; prioritized_day = None }
    in
    let chronological =
      if chronological_days = []
      then { chronological with pending = None }
      else
        refresh_chronological_feed chronological ~generation ~complete chronological_value
    in
    let chronological =
      if chronological_days <> []
      then chronological
      else (
        let slots =
          filter_slots
            (function
              | Feed_continuation _ -> false
              | _ -> true)
            chronological.slots
        in
        let slots =
          match feed.continuation with
          | None -> slots
          | Some cursor -> Rrbvec.push_back slots (Feed_continuation { cursor })
        in
        { chronological with slots })
    in
    let index =
      find_slot_index
        (fun slot ->
           Option.fold ~none:true ~some:(fun day -> day < today) (slot_day slot))
        chronological.slots
      |> Option.value ~default:(Rrbvec.length chronological.slots)
    in
    let slots = splice chronological.slots index index today_state.slots in
    let days =
      Days.union (fun _ _ today -> Some today) chronological.days today_state.days
    in
    { chronological with slots; days } |> finish_change state
  | _ -> refresh_chronological_feed state ~generation ~complete feed
;;
let append_timeline_entry_page
      (state : t)
      ~generation
      (page : Journal_graph_projection.timeline_entry_page)
  =
  match state.pending with
  | Some (expected_generation, Day { day; after })
    when Int64.equal expected_generation generation ->
    (match
       find_slot_index
         (function
           | Day_continuation candidate -> candidate.day = day && candidate.after = after
           | _ -> false)
         state.slots
     with
     | None -> state
     | Some continuation_index ->
       let before = state in
       let start =
         find_slot_index
           (function
             | Top_level entry when Journal_model.journal_day entry.block = day ->
               (match after with
                | None -> true
                | Some cursor ->
                  let order =
                    String.compare
                      (Journal_model.sibling_order entry.block)
                      cursor.Journal_graph_projection.after_sibling_order
                  in
                  order > 0
                  || (order = 0
                      && String.compare
                           (Journal_model.id entry.block)
                           cursor.after_block_id
                         > 0))
             | _ -> false)
           (slice state.slots 0 continuation_index)
         |> Option.value ~default:continuation_index
       in
       let retained = slice state.slots start continuation_index in
       let add_entry entries (entry : Journal_graph_projection.timeline_entry) =
         Entries.add (Journal_model.id entry.block) entry entries
       in
       let entries =
         Rrbvec.fold_left
           (fun entries -> function
              | Top_level entry -> add_entry entries entry
              | _ -> entries)
           Entries.empty
           retained
       in
       let entries =
         List.fold_left add_entry entries page.entries
         |> Entries.bindings
         |> List.map snd
         |> List.sort
              (fun
                  (left : Journal_graph_projection.timeline_entry)
                   (right : Journal_graph_projection.timeline_entry)
                 -> compare_blocks left.block right.block)
       in
       let state =
         update_day state day (fun knowledge ->
           { knowledge with
             block_count =
               knowledge.block_count + List.length entries - Rrbvec.length retained
           ; complete = Option.is_none page.continuation
           })
       in
       let replacement =
         List.map (fun entry -> Top_level entry) entries
         @
         match page.continuation with
         | None -> []
         | Some continuation -> [ Day_continuation { day; after = Some continuation } ]
       in
       let slots =
         splice state.slots start (continuation_index + 1) (Rrbvec.of_list replacement)
       in
       let state = { state with slots; pending = None } |> finish_change before in
       let request = Day { day; after } in
       let successor =
         Option.map (fun after -> Day { day; after = Some after }) page.continuation
       in
       if successor = Some request
       then stop_visible_drain state
       else complete_visible_request ?successor state request)
  | Some _ | None -> state
;;

let point_entry (state : t) block_id =
  match
    Rrbvec.find_map
      (function
        | Top_level e when Journal_model.id e.block = block_id -> Some e
        | _ -> None)
      state.slots
  with
  | Some _ as entry -> entry
  | None ->
    Days.fold
      (fun _ k found ->
         match found, k.hidden_entry with
         | None, Some e when Journal_model.id e.block = block_id -> Some e
         | _ -> found)
      state.days
      None
;;

let point_in_loaded_range (state : t) block =
  match Journal_model.journal_day_opt block with
  | None -> false
  | Some day ->
    (match Days.find_opt day state.days with
     | Some k
       when k.page.id = Journal_model.page_id block
            && Journal_model.parent_id block = None ->
       k.complete
       ||
       let key = Journal_model.sibling_order block, Journal_model.id block in
       Rrbvec.exists
         (function
           | Top_level e when Journal_model.page_id e.block = k.page.id ->
             compare key (Journal_model.sibling_order e.block, Journal_model.id e.block)
             <= 0
           | Day_continuation { day = candidate; after = Some cursor }
             when candidate = day ->
             compare key (cursor.after_sibling_order, cursor.after_block_id) <= 0
           | _ -> false)
         state.slots
     | _ -> false)
;;

let location_changed old fresh =
  Journal_model.page_id old <> Journal_model.page_id fresh
  || Journal_model.journal_day_opt old <> Journal_model.journal_day_opt fresh
  || Journal_model.parent_id old <> Journal_model.parent_id fresh
  || Journal_model.sibling_order old <> Journal_model.sibling_order fresh
;;

let relocate_point (before : t) (entry : Journal_graph_projection.timeline_entry) =
  let id = Journal_model.id entry.block in
  let fits = point_in_loaded_range before entry.block && not (empty_parent entry) in
  let removed = ref Days.empty in
  let slots =
    filter_slots
      (function
        | Top_level e when Journal_model.id e.block = id ->
          let day = Journal_model.journal_day e.block in
          removed
          := Days.update day (fun n -> Some (1 + Option.value n ~default:0)) !removed;
          false
        | _ -> true)
      before.slots
  in
  let days =
    Days.mapi
      (fun day k ->
         let hidden =
           Option.fold
             ~none:false
             ~some:(fun (e : Journal_graph_projection.timeline_entry) ->
               Journal_model.id e.block = id)
             k.hidden_entry
         in
         { k with
           block_count =
             max
               0
               (k.block_count
                - Option.value (Days.find_opt day !removed) ~default:0
                - if hidden && k.hidden then 1 else 0)
         ; hidden_entry = (if hidden then None else k.hidden_entry)
         ; hidden = k.hidden && not hidden
         })
      before.days
  in
  let state = { before with slots; days } in
  let state =
    Days.fold (fun day _ state -> invalidate_recovery_for_day state day) !removed state
    |> fun state ->
    invalidate_recovery_for_day state (Journal_model.journal_day entry.block)
  in
  let state =
    if not fits
    then state
    else (
      let day = Journal_model.journal_day entry.block in
      let slots = insert_entry state.slots entry in
      let slots =
        if
          day <> state.today
          && not
               (Rrbvec.exists
                  (function
                    | Day_heading p -> p.day = day
                    | _ -> false)
                  slots)
        then insert_day_slots slots day [ Day_heading (Days.find day state.days).page ]
        else slots
      in
      { state with
        slots
      ; days =
          Days.update
            day
            (Option.map (fun k ->
               { k with
                 block_count = k.block_count + 1
               ; hidden = false
               ; hidden_entry = None
               }))
            state.days
      })
  in
  finish_change before state
;;

let replace_block (state : t) replacement =
  match point_entry state (Journal_model.id replacement) with
  | Some old when location_changed old.block replacement ->
    relocate_point state { old with block = replacement }
  | _ ->
    let state =
      invalidate_recovery_for_day state (Journal_model.journal_day replacement)
    in
    let replacement_id = Journal_model.id replacement in
    let before = state in
    let retained = ref false in
    let hidden_match = ref false in
    let restore_in_place = ref false in
    let state =
      update_day state (Journal_model.journal_day replacement) (fun knowledge ->
        match knowledge.hidden_entry with
        | Some entry when String.equal (Journal_model.id entry.block) replacement_id ->
          hidden_match := true;
          restore_in_place := not knowledge.hidden;
          let entry = { entry with block = replacement } in
          { knowledge with
            hidden_entry = Some entry
          ; block_count =
              (if empty_parent entry
               then knowledge.block_count
               else max 1 knowledge.block_count)
          }
        | _ -> knowledge)
    in
    let slots =
      update_slots
        (function
          | Top_level entry
            when String.equal (Journal_model.id entry.block) replacement_id ->
            retained := true;
            Some (Top_level { entry with block = replacement })
          | _ -> None)
        state.slots
    in
    let state = { state with slots } in
    let entry =
      match
        Option.bind
          (Days.find_opt (Journal_model.journal_day replacement) state.days)
          (fun knowledge -> knowledge.hidden_entry)
      with
      | Some entry when Journal_model.id entry.block = replacement_id -> entry
      | _ -> { Journal_graph_projection.block = replacement; child_summaries = [] }
    in
    let state =
      if
        (not !retained)
        && ((not !hidden_match) || !restore_in_place)
        && Journal_model.parent_id replacement = None
        && (not (empty_parent entry))
        && point_in_loaded_range state replacement
      then
        { state with slots = insert_entry state.slots entry }
        |> fun state ->
        update_day state (Journal_model.journal_day replacement) (fun k ->
          { k with
            block_count = (k.block_count + if !hidden_match then 0 else 1)
          ; hidden_entry = (if !hidden_match then None else k.hidden_entry)
          })
      else state
    in
    finish_change before state
;;

let replace_timeline_entry
      (state : t)
      (replacement : Journal_graph_projection.timeline_entry)
  =
  match point_entry state (Journal_model.id replacement.block) with
  | Some old when location_changed old.block replacement.block ->
    relocate_point state replacement
  | _ ->
    let state =
      invalidate_recovery_for_day
        state
        (Journal_model.journal_day replacement.Journal_graph_projection.block)
    in
    let replacement_id = Journal_model.id replacement.Journal_graph_projection.block in
    let before = state in
    let retained = ref false in
    let hidden_match = ref false in
    let restore_in_place = ref false in
    let state =
      update_day state (Journal_model.journal_day replacement.block) (fun knowledge ->
        match knowledge.hidden_entry with
        | Some entry when String.equal (Journal_model.id entry.block) replacement_id ->
          hidden_match := true;
          restore_in_place := not knowledge.hidden;
          { knowledge with
            hidden_entry = Some replacement
          ; block_count =
              (if empty_parent replacement
               then knowledge.block_count
               else max 1 knowledge.block_count)
          }
        | _ -> knowledge)
    in
    let slots =
      update_slots
        (function
          | Top_level entry
            when String.equal (Journal_model.id entry.block) replacement_id ->
            retained := true;
            Some (Top_level replacement)
          | _ -> None)
        state.slots
    in
    let state = { state with slots } in
    let day = Journal_model.journal_day replacement.block in
    let state =
      if
        (not !retained)
        && ((not !hidden_match) || !restore_in_place)
        && (not (empty_parent replacement))
        && Journal_model.parent_id replacement.block = None
        && point_in_loaded_range state replacement.block
      then
        { state with slots = insert_entry state.slots replacement }
        |> fun state ->
        update_day state day (fun k ->
          { k with
            block_count = (k.block_count + if !hidden_match then 0 else 1)
          ; hidden_entry = (if !hidden_match then None else k.hidden_entry)
          })
      else state
    in
    finish_change before state
;;

let replace_timeline_entry_page
      (state : t)
      ~(page : Journal_graph_projection.page)
      (replacement : Journal_graph_projection.timeline_entry_page)
  =
  let before = state in
  let ids, body, count =
    List.fold_left
      (fun (ids, slots, count) (entry : Journal_graph_projection.timeline_entry) ->
         ( Entries.add (Journal_model.id entry.block) () ids
         , Rrbvec.push_back slots (Top_level entry)
         , count + 1 ))
      (Entries.empty, Rrbvec.empty, 0)
      replacement.entries
  in
  let removed = ref Days.empty in
  let slots =
    filter_slots
      (function
        | Top_level e ->
          let day = Journal_model.journal_day e.block in
          if
            Journal_model.page_id e.block = page.id
            || day = page.day
            || Entries.mem (Journal_model.id e.block) ids
          then (
            removed
            := Days.update day (fun n -> Some (1 + Option.value n ~default:0)) !removed;
            false)
          else true
        | Day_heading p -> p.id <> page.id && p.day <> page.day
        | Day_continuation c -> c.day <> page.day
        | Feed_continuation _ -> true)
      state.slots
  in
  let days =
    Days.mapi
      (fun day k ->
         let hidden =
           Option.fold
             ~none:false
             ~some:(fun (e : Journal_graph_projection.timeline_entry) ->
               Entries.mem (Journal_model.id e.block) ids)
             k.hidden_entry
         in
         { k with
           block_count =
             max
               0
               (k.block_count
                - Option.value (Days.find_opt day !removed) ~default:0
                - if hidden && k.hidden then 1 else 0)
         ; hidden_entry = (if hidden then None else k.hidden_entry)
         ; hidden = k.hidden && not hidden
         })
      state.days
  in
  let days =
    Days.add
      page.day
      { page
      ; block_count = count
      ; complete = Option.is_none replacement.continuation
      ; hidden = false
      ; hidden_entry = None
      }
      days
  in
  let body =
    if page.day = state.today
    then body
    else Rrbvec.append (Rrbvec.singleton (Day_heading page)) body
  in
  let body =
    match replacement.continuation with
    | None -> body
    | Some after ->
      Rrbvec.push_back body (Day_continuation { day = page.day; after = Some after })
  in
  let index =
    find_slot_index
      (fun slot ->
         Option.fold ~none:true ~some:(fun day -> day < page.day) (slot_day slot))
      slots
    |> Option.value ~default:(Rrbvec.length slots)
  in
  let slots = splice slots index index body in
  let pending =
    match state.pending with
    | Some (_, Day { day; _ }) when day = page.day -> None
    | value -> value
  in
  let recovery =
    match state.recovery with
    | Some r when r.day = page.day -> None
    | value -> value
  in
  { state with
    slots
  ; days
  ; pending
  ; recovery
  ; day_failures = List.remove_assoc page.day state.day_failures
  }
  |> finish_change before
;;

let apply_timeline_entry_page
      (state : t)
      ~generation
      (page : Journal_graph_projection.timeline_entry_page)
  =
  match state.pending, state.recovery with
  | Some (expected, Day request), Some recovery
    when Int64.equal generation expected && request.day = recovery.day ->
    let entries = recovery.entries @ page.entries in
    let ids =
      List.map
        (fun (entry : Journal_graph_projection.timeline_entry) ->
           Journal_model.id entry.block)
        entries
    in
    let reads = recovery.reads + 1 in
    let invalid =
      List.length ids <> List.length (List.sort_uniq String.compare ids)
      || (Option.is_some page.continuation
          && (page.entries = [] || page.continuation = request.after))
    in
    let anchor_present =
      match recovery.anchor_ids with
      | [] -> true
      | anchor :: _ ->
        List.mem anchor ids
        || Rrbvec.exists
             (function
               | Top_level entry ->
                 Journal_model.journal_day entry.block <> recovery.day
                 && String.equal (Journal_model.id entry.block) anchor
               | _ -> false)
             state.slots
    in
    let complete =
      Option.is_none page.continuation
      || (List.length entries >= recovery.target_count && anchor_present)
    in
    if
      invalid
      || List.length entries > maximum_recovery_entries
      || ((not complete) && reads >= 16)
    then
      terminal_day_failure
        state
        ~day:recovery.day
        "Unable to reload this journal within the loading limit. Retry to continue."
    else if not complete
    then
      { state with
        pending = None
      ; recovery = Some { recovery with entries; reads; next_cursor = page.continuation }
      }
    else (
      let owner_page =
        Rrbvec.find_map
          (function
            | Day_heading page when page.Journal_graph_projection.day = recovery.day ->
              Some page
            | Top_level entry when Journal_model.journal_day entry.block = recovery.day ->
              Some
                { Journal_graph_projection.id = Journal_model.page_id entry.block
                ; day = recovery.day
                ; title = ""
                }
            | _ -> None)
          state.slots
      in
      match owner_page with
      | None ->
        terminal_day_failure
          state
          ~day:recovery.day
          "This journal is no longer available."
      | Some owner_page ->
        let updated =
          replace_timeline_entry_page
            state
            ~page:owner_page
            { entries; continuation = page.continuation }
        in
        let anchor_id =
          List.find_opt
            (fun id ->
               Rrbvec.exists
                 (function
                   | Top_level entry -> String.equal id (Journal_model.id entry.block)
                   | _ -> false)
                 updated.slots)
            recovery.anchor_ids
        in
        let anchor_key =
          match anchor_id with
          | Some id -> "block:" ^ id
          | None -> "day:" ^ string_of_int recovery.day
        in
        let visible_first =
          find_slot_index (fun slot -> slot_key slot = anchor_key) updated.slots
          |> Option.fold ~none:state.visible_first ~some:(fun offset -> offset)
        in
        { updated with
          visible_first
        ; visible_last_exclusive =
            min
              (Rrbvec.length updated.slots)
              (visible_first + max 1 (state.visible_last_exclusive - state.visible_first))
        ; visible_demand = Option.map (fun _ -> []) state.visible_demand
        })
  | _, Some _ -> state
  | _, None -> append_timeline_entry_page state ~generation page
;;

let apply_feed (state : t) ~generation (feed : Journal_graph_projection.feed) =
  match state.pending with
  | Some (expected, Day { day; after }) when generation = expected ->
    let first, older =
      match feed.days with
      | first :: rest when first.page.day = day -> Some first, rest
      | days -> None, days
    in
    let page : Journal_graph_projection.timeline_entry_page =
      match first with
      | None -> { entries = []; continuation = None }
      | Some first -> { entries = first.entries; continuation = first.continuation }
    in
    let updated = apply_timeline_entry_page state ~generation page in
    if updated == state || updated.recovery <> None
    then updated
    else (
      let merged = merge_feed_days updated older in
      let slots =
        filter_slots
          (function
            | Feed_continuation _ -> false
            | _ -> true)
          merged.slots
      in
      let slots =
        match feed.continuation with
        | Some cursor -> Rrbvec.push_back slots (Feed_continuation { cursor })
        | None -> slots
      in
      let merged = { merged with slots } |> finish_change state in
      let request = Day { day; after } in
      let successor =
        Rrbvec.fold_left
          (fun next slot ->
             match request_of_slot slot with
             | Some r -> Some r
             | None -> next)
          None
          slots
      in
      complete_visible_request ?successor merged request)
  | _ -> apply_feed_dates state ~generation feed
;;
let next_request (state : t) =
  if Option.is_some state.pending
  then None
  else (
    match state.recovery with
    | Some recovery -> Some (Day { day = recovery.day; after = recovery.next_cursor })
    | None -> Option.bind state.visible_demand (next_visible_request state))
;;

let pending_request (state : t) = state.pending

let request_top (state : t) =
  match state.scroll_target with
  | Some _ -> state
  | None ->
    let token = Int64.succ state.scroll_generation in
    { state with
      scroll_generation = token
    ; scroll_target = Some (token, state.today, "day:" ^ string_of_int state.today)
    ; scroll_outcome = None
    }
;;

let cancel_scroll (state : t) =
  match state.scroll_target with
  | None -> state
  | Some _ ->
    { state with scroll_target = None; scroll_outcome = Some Cancelled }
;;

let prepend_timeline_entry (state : t) (entry : Journal_graph_projection.timeline_entry) =
  let before = state in
  let block = entry.Journal_graph_projection.block in
  let token = Int64.succ state.scroll_generation in
  let state =
    { state with scroll_generation = token; scroll_target = None; scroll_outcome = None }
  in
  let state = invalidate_recovery_for_day state (Journal_model.journal_day block) in
  let next =
    if
      Option.fold
        ~none:false
        ~some:(fun knowledge ->
          Option.fold
            ~none:false
            ~some:(fun (entry : Journal_graph_projection.timeline_entry) ->
              String.equal
                (Journal_model.id entry.Journal_graph_projection.block)
                (Journal_model.id block))
            knowledge.hidden_entry)
        (Days.find_opt (Journal_model.journal_day block) state.days)
      || Rrbvec.exists
           (function
             | Top_level candidate ->
               String.equal (Journal_model.id candidate.block) (Journal_model.id block)
             | _ -> false)
           state.slots
    then replace_timeline_entry state entry
    else (
      let day = Journal_model.journal_day block in
      let state =
        { state with
          days =
            Days.update
              day
              (function
                | Some knowledge ->
                  Some { knowledge with block_count = knowledge.block_count + 1 }
                | None ->
                  Some
                    { page =
                        { id = Journal_model.page_id block
                        ; day
                        ; title = string_of_int day
                        }
                    ; block_count = 1
                    ; complete = false
                    ; hidden = true
                    ; hidden_entry = None
                    })
              state.days
        }
      in
      let slots = insert_entry state.slots entry in
      { state with slots } |> finish_change before)
  in
  { next with
    visible_first = 0
  ; visible_last_exclusive =
      min
        (Rrbvec.length next.slots)
        (max 0 (before.visible_last_exclusive - before.visible_first))
  ; scroll_target =
      Rrbvec.find_map
        (function
          | Top_level entry as slot ->
            Some (token, Journal_model.journal_day entry.block, slot_key slot)
          | Day_continuation { day; _ } as slot -> Some (token, day, slot_key slot)
          | Day_heading _ | Feed_continuation _ -> None)
        next.slots
  }
;;

let remove_block (state : t) ~block_id =
  let state =
    { state with
      days =
        Days.map
          (fun knowledge ->
             match knowledge.hidden_entry with
             | Some entry when String.equal (Journal_model.id entry.block) block_id ->
               { knowledge with
                 hidden_entry = None
               ; block_count = max 0 (knowledge.block_count - 1)
               }
             | _ -> knowledge)
          state.days
    }
  in
  let position =
    find_slot_index
      (fun slot ->
         match slot_block slot with
         | Some block -> String.equal (Journal_model.id block) block_id
         | None -> false)
      state.slots
  in
  match Option.map (fun index -> index, Rrbvec.nth state.slots index) position with
  | Some (index, Top_level entry) ->
    let block = entry.block in
    let state = invalidate_recovery_for_day state (Journal_model.journal_day block) in
    let stop = index + 1 in
    let slots = splice state.slots index stop Rrbvec.empty in
    let total_count = Rrbvec.length slots in
    let deleted =
      normalize_days
        { state with
          days =
            Days.update
              (Journal_model.journal_day block)
              (Option.map (fun knowledge ->
                 { knowledge with block_count = max 0 (knowledge.block_count - 1) }))
              state.days
        ; slots
        ; visible_first = min state.visible_first total_count
        ; visible_last_exclusive = min state.visible_last_exclusive total_count
        ; pending = None
        }
      |> preserve_anchor state
    in
    prune_days deleted
  | None | Some (_, (Day_heading _ | Day_continuation _ | Feed_continuation _)) -> state
;;

let observe_visible_range (state : t) ~first_index ~last_exclusive =
  let first_index = max 0 (min (Rrbvec.length state.slots) first_index) in
  let last_exclusive = max first_index (min (Rrbvec.length state.slots) last_exclusive) in
  { state with
    visible_first = first_index
  ; visible_last_exclusive = last_exclusive
  ; visible_demand = Some (visible_requests state ~first_index ~last_exclusive)
  }
;;

(* Content rendering consumes slots/date/errors. Scroll commands have an
   independent mounted subscription; demand and recovery do not rebuild rows. *)
let equal_presentation (left : t) (right : t) =
  left == right
  || (left.slots == right.slots
      && left.today = right.today
      && left.day_failures == right.day_failures
      && (left.day_failures = []
          || Option.is_some left.pending = Option.is_some right.pending))
;;

let retained_slot (state : t) index = Rrbvec.nth_opt state.slots index
let fold_slots f initial (state : t) = Rrbvec.fold_left f initial state.slots

let find_block (state : t) ~block_id =
  let visible =
    Rrbvec.find_map
      (fun slot ->
         match slot_block slot with
         | Some block when String.equal (Journal_model.id block) block_id -> Some block
         | _ -> None)
      state.slots
  in
  match visible with
  | Some _ -> visible
  | None ->
    Days.fold
      (fun _ knowledge found ->
         match found, knowledge.hidden_entry with
         | None, Some entry when String.equal (Journal_model.id entry.block) block_id ->
           Some entry.block
         | _ -> found)
      state.days
      None
;;

let retained_slot_count (state : t) = Rrbvec.length state.slots
let total_count (state : t) = Rrbvec.length state.slots
let today (state : t) = state.today
let set_today (state : t) ~today = { state with today }
let first_visible_index (state : t) = state.visible_first
let scroll_generation (state : t) = state.scroll_generation
let scroll_target (state : t) = state.scroll_target
let scroll_outcome (state : t) = state.scroll_outcome

let complete_scroll state ~token ~outcome =
  match state.scroll_target with
  | Some (current, _, _) when current = token ->
    { state with scroll_target = None; scroll_outcome = Some outcome }
  | None | Some _ -> state
;;
