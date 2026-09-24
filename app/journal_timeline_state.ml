type request =
  | Feed of { before_day : int option }
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
  | Feed_continuation of { before_day : int }

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
  ; first_retained_index : int
  ; days : day_knowledge Days.t
  ; total_count : int
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

type staged_delete =
  { block : Journal_model.t
  ; before : t
  }

let maximum_hidden_days = 512
let maximum_recovery_entries = 512
let initial_visible_count = 40
let prefetch_margin = 4

let empty ~today =
  { today
  ; slots = Rrbvec.empty
  ; first_retained_index = 0
  ; days = Days.empty
  ; total_count = 0
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
  | Feed_continuation { before_day } -> "feed-continuation:" ^ string_of_int before_day
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

let span_end predicate slots start =
  find_slot_index
    (fun slot -> not (predicate slot))
    (slice slots start (Rrbvec.length slots))
  |> Option.fold ~none:(Rrbvec.length slots) ~some:(fun offset -> start + offset)
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

let empty_placeholder (entry : Journal_graph_projection.timeline_entry) =
  String.equal (String.trim (Journal_model.source entry.block)) ""
  && Journal_model.child_count entry.block = 0
  && Journal_model.task_state entry.block = Journal_model.No_status
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
  let offset = before.visible_first - before.first_retained_index in
  let anchor = Rrbvec.nth_opt before.slots offset |> Option.map slot_key in
  let visible_first =
    Option.bind anchor (fun key ->
      find_slot_index (fun slot -> String.equal (slot_key slot) key) state.slots)
    |> Option.fold ~none:(min before.visible_first state.total_count) ~some:(fun index ->
      state.first_retained_index + index)
  in
  { state with
    visible_first
  ; visible_last_exclusive =
      min
        state.total_count
        (visible_first + max 0 (before.visible_last_exclusive - before.visible_first))
  }
;;

let normalize_days (state : t) =
  let slots = ref state.slots in
  let days =
    Days.mapi
      (fun day knowledge ->
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
                     && Option.fold ~none:false ~some:empty_placeholder entry))
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
  let delta = Rrbvec.length !slots - Rrbvec.length state.slots in
  { state with slots = !slots; days; total_count = max 0 (state.total_count + delta) }
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
  | Some (pending_generation, _), Feed { before_day = None }
    when Int64.compare generation pending_generation > 0 ->
    { state with
      pending = Some (generation, request)
    ; recovery = None
    ; day_failures = []
    }
  | Some _, _ -> state
  | None, Feed { before_day = None } ->
    { state with
      pending = Some (generation, request)
    ; recovery = None
    ; day_failures = []
    }
  | None, _ -> { state with pending = Some (generation, request) }
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
    let anchor_index = max 0 (state.visible_first - state.first_retained_index) in
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
        ; target_count = List.length day_entries + 64
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
  let continuation =
    match feed.has_more_days, List.rev days with
    | true, last :: _ -> [ Feed_continuation { before_day = last.page.day } ]
    | false, _ | true, [] -> []
  in
  rows @ continuation
;;

let request_of_slot = function
  | Day_continuation { day; after } -> Some (Day { day; after })
  | Feed_continuation { before_day } -> Some (Feed { before_day = Some before_day })
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
  let lower = max state.first_retained_index (first_index - prefetch_margin) in
  let upper = min state.total_count (last_exclusive + prefetch_margin) in
  let length = Rrbvec.length state.slots in
  let start = min length (max 0 (lower - state.first_retained_index)) in
  let stop = min length (max start (upper - state.first_retained_index)) in
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

let replace_slot (state : t) ~predicate replacement =
  match find_slot_index predicate state.slots with
  | None -> state
  | Some index ->
    let slots = splice state.slots index (index + 1) (Rrbvec.of_list replacement) in
    let delta = List.length replacement - 1 in
    { state with slots; total_count = state.total_count + delta; pending = None }
;;

let apply_feed (state : t) ~generation feed =
  match state.pending with
  | Some (expected_generation, Feed { before_day })
    when Int64.equal expected_generation generation ->
    let before = state in
    let days =
      List.fold_left
        (fun days day ->
           Days.add day.Journal_graph_projection.page.day (knowledge_of_feed day) days)
        (match before_day with
         | None -> Days.empty
         | Some _ -> state.days)
        feed.Journal_graph_projection.days
    in
    let state = { state with days } in
    let projected = feed_slots ~today:state.today feed in
    (match before_day with
     | None when Rrbvec.is_empty state.slots ->
       { state with
         slots = Rrbvec.of_list projected
       ; first_retained_index = 0
       ; total_count = List.length projected
       ; visible_first = 0
       ; visible_last_exclusive = min initial_visible_count (List.length projected)
       ; visible_demand = None
       ; pending = None
       }
       |> normalize_days
       |> prune_days
     | None ->
       let slots = Rrbvec.of_list projected in
       { state with
         slots
       ; first_retained_index = 0
       ; total_count = Rrbvec.length slots
       ; visible_demand = None
       ; pending = None
       }
       |> finish_change before
     | Some expected_before_day ->
       let request = Feed { before_day = Some expected_before_day } in
       let state =
         replace_slot
           state
           ~predicate:(function
             | Feed_continuation { before_day } -> before_day = expected_before_day
             | _ -> false)
           projected
         |> finish_change before
       in
       let successor =
         List.find_map
           (function
             | Feed_continuation { before_day } ->
               Some (Feed { before_day = Some before_day })
             | _ -> None)
           projected
       in
       if successor = Some request
       then stop_visible_drain state
       else complete_visible_request ?successor state request)
  | Some _ | None -> state
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
       let state =
         { state with
           slots
         ; total_count =
             state.total_count + Rrbvec.length slots - Rrbvec.length state.slots
         ; pending = None
         }
         |> finish_change before
       in
       let request = Day { day; after } in
       let successor =
         Option.map (fun after -> Day { day; after = Some after }) page.continuation
       in
       if successor = Some request
       then stop_visible_drain state
       else complete_visible_request ?successor state request)
  | Some _ | None -> state
;;

let replace_block (state : t) replacement =
  let state = invalidate_recovery_for_day state (Journal_model.journal_day replacement) in
  let replacement_id = Journal_model.id replacement in
  let before = state in
  let state =
    update_day state (Journal_model.journal_day replacement) (fun knowledge ->
      match knowledge.hidden_entry with
      | Some entry when String.equal (Journal_model.id entry.block) replacement_id ->
        { knowledge with hidden_entry = Some { entry with block = replacement } }
      | _ -> knowledge)
  in
  let slots =
    update_slots
      (function
        | Top_level entry when String.equal (Journal_model.id entry.block) replacement_id
          -> Some (Top_level { entry with block = replacement })
        | _ -> None)
      state.slots
  in
  { state with slots } |> finish_change before
;;

let replace_timeline_entry
      (state : t)
      (replacement : Journal_graph_projection.timeline_entry)
  =
  let state =
    invalidate_recovery_for_day
      state
      (Journal_model.journal_day replacement.Journal_graph_projection.block)
  in
  let replacement_id = Journal_model.id replacement.Journal_graph_projection.block in
  let before = state in
  let state =
    update_day state (Journal_model.journal_day replacement.block) (fun knowledge ->
      match knowledge.hidden_entry with
      | Some entry when String.equal (Journal_model.id entry.block) replacement_id ->
        { knowledge with hidden_entry = Some replacement }
      | _ -> knowledge)
  in
  let slots =
    update_slots
      (function
        | Top_level entry when String.equal (Journal_model.id entry.block) replacement_id
          -> Some (Top_level replacement)
        | _ -> None)
      state.slots
  in
  { state with slots } |> finish_change before
;;

let replace_timeline_entry_page
      (state : t)
      ~(page : Journal_graph_projection.page)
      (replacement : Journal_graph_projection.timeline_entry_page)
  =
  let before = state in
  let state =
    match Days.find_opt page.day state.days with
    | Some knowledge when knowledge.hidden ->
      let slots =
        insert_day_slots
          state.slots
          page.day
          ((if page.day = state.today then [] else [ Day_heading page ])
           @ Option.to_list
               (Option.map (fun entry -> Top_level entry) knowledge.hidden_entry))
      in
      { state with
        slots
      ; total_count = state.total_count + Rrbvec.length slots - Rrbvec.length state.slots
      }
    | _ -> state
  in
  let state =
    { state with
      days =
        Days.add
          page.day
          { page
          ; block_count = List.length replacement.entries
          ; complete = Option.is_none replacement.continuation
          ; hidden = false
          ; hidden_entry = None
          }
          state.days
    }
  in
  let pending =
    match state.pending with
    | Some (_, Day { day; _ }) when day = page.day -> None
    | pending -> pending
  in
  let state =
    { state with
      pending
    ; recovery =
        (match state.recovery with
         | Some recovery when recovery.day = page.day -> None
         | value -> value)
    ; day_failures = List.remove_assoc page.day state.day_failures
    }
  in
  let replacement_slots =
    List.map (fun entry -> Top_level entry) replacement.entries
    @
    match replacement.continuation with
    | None -> []
    | Some after -> [ Day_continuation { day = page.day; after = Some after } ]
  in
  let belongs_to_page = function
    | Top_level entry -> String.equal (Journal_model.page_id entry.block) page.id
    | Day_continuation continuation -> continuation.day = page.day
    | Day_heading _ | Feed_continuation _ -> false
  in
  let position =
    find_slot_index
      (function
        | Day_heading candidate -> String.equal candidate.id page.id
        | Top_level entry -> String.equal (Journal_model.page_id entry.block) page.id
        | _ -> false)
      state.slots
  in
  let position =
    match position with
    | Some index -> Some index
    | None ->
      if Days.mem page.day before.days
      then
        Some
          (Option.value
             ~default:(Rrbvec.length state.slots)
             (find_slot_index
                (fun slot ->
                   match slot_day slot with
                   | Some day -> day < page.day
                   | None ->
                     (match slot with
                      | Feed_continuation _ -> true
                      | _ -> false))
                state.slots))
      else None
  in
  match position with
  | None -> before
  | Some index ->
    let start =
      match Rrbvec.nth_opt state.slots index with
      | Some (Day_heading _) -> index + 1
      | _ -> index
    in
    let stop = span_end belongs_to_page state.slots start in
    let slots = splice state.slots start stop (Rrbvec.of_list replacement_slots) in
    let delta = Rrbvec.length slots - Rrbvec.length state.slots in
    { state with slots; pending; total_count = max 0 (state.total_count + delta) }
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
          |> Option.fold ~none:state.visible_first ~some:(fun offset ->
            updated.first_retained_index + offset)
        in
        { updated with
          visible_first
        ; visible_last_exclusive =
            min
              updated.total_count
              (visible_first + max 1 (state.visible_last_exclusive - state.visible_first))
        ; visible_demand = Option.map (fun _ -> []) state.visible_demand
        })
  | _, Some _ -> state
  | _, None -> append_timeline_entry_page state ~generation page
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
      { state with slots; total_count = state.total_count + 1 } |> finish_change before)
  in
  { next with
    visible_first = 0
  ; visible_last_exclusive =
      min next.total_count (max 0 (before.visible_last_exclusive - before.visible_first))
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

let stage_delete (state : t) ~block_id =
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
    let removed = Rrbvec.length state.slots - Rrbvec.length slots in
    let total_count = max 0 (state.total_count - removed) in
    let before = { state with pending = None } in
    Some
      ( finish_change
          state
          { state with
            days =
              Days.update
                (Journal_model.journal_day block)
                (Option.map (fun knowledge ->
                   { knowledge with block_count = max 0 (knowledge.block_count - 1) }))
                state.days
          ; slots
          ; total_count
          ; visible_first = min state.visible_first total_count
          ; visible_last_exclusive = min state.visible_last_exclusive total_count
          ; pending = None
          }
      , { block; before } )
  | None | Some (_, (Day_heading _ | Day_continuation _ | Feed_continuation _)) -> None
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
  match stage_delete state ~block_id with
  | Some (state, _) -> state
  | None -> state
;;

let undo_delete (state : t) staged =
  let before = state in
  let target_key = "block:" ^ Journal_model.id staged.block in
  if Rrbvec.exists (fun slot -> String.equal (slot_key slot) target_key) state.slots
  then state
  else (
    match stage_delete staged.before ~block_id:(Journal_model.id staged.block) with
    | None -> state
    | Some (without_target, _) ->
      let day = Journal_model.journal_day staged.block in
      let state =
        match Days.find_opt day state.days, Days.find_opt day staged.before.days with
        | Some knowledge, _ ->
          update_day state day (fun _ ->
            { knowledge with block_count = knowledge.block_count + 1 })
          |> normalize_days
        | None, Some knowledge -> { state with days = Days.add day knowledge state.days }
        | None, None -> state
      in
      let retained_keys = Rrbvec.map slot_key without_target.slots in
      let removed slot = not (Rrbvec.mem (slot_key slot) retained_keys) in
      let insert_before anchor slot slots =
        let index =
          find_slot_index (fun head -> Some (slot_key head) = anchor) slots
          |> Option.value ~default:(Rrbvec.length slots)
        in
        splice slots index index (Rrbvec.singleton slot)
      in
      let slots, _, inserted =
        Rrbvec.fold_right
          (fun slot (slots, anchor, inserted) ->
             let key = slot_key slot in
             if Rrbvec.exists (fun current -> String.equal (slot_key current) key) slots
             then slots, Some key, inserted
             else if removed slot
             then insert_before anchor slot slots, Some key, inserted + 1
             else slots, anchor, inserted)
          staged.before.slots
          (state.slots, None, 0)
      in
      { state with slots; total_count = state.total_count + inserted; pending = None }
      |> finish_change before)
;;

let observe_visible_range (state : t) ~first_index ~last_exclusive =
  let first_index = max 0 (min state.total_count first_index) in
  let last_exclusive = max first_index (min state.total_count last_exclusive) in
  { state with
    visible_first = first_index
  ; visible_last_exclusive = last_exclusive
  ; visible_demand = Some (visible_requests state ~first_index ~last_exclusive)
  }
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
let first_retained_index (state : t) = state.first_retained_index
let total_count (state : t) = state.total_count
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
