module Ui = Bonsai_flutter_ui

type request =
  | Feed of { before_day : int option }
  | Day of
      { day : int
      ; after : Journal_graph_projection.block_cursor option
      }
  | Children of
      { parent_id : string
      ; epoch : int64
      }

type slot =
  | Day_heading of Journal_graph_projection.page
  | Top_level of Journal_graph_projection.timeline_entry
  | Child_preview of
      { parent_id : string
      ; block : Journal_model.t
      }
  | Day_continuation of
      { day : int
      ; after : Journal_graph_projection.block_cursor option
      }
  | Children_loading of
      { parent_id : string
      ; epoch : int64
      }
  | Children_more of { parent_id : string }
  | Feed_continuation of { before_day : int }

type anchor_decision =
  | Preserve_visible_slot
  | Reset_to_top

type extent_strategy = Known_profile_extents

type capture_fab_presentation =
  | Extended
  | Compact

type capture_fab_scroll =
  { presentation : capture_fab_presentation
  ; accumulated_travel : float
  }

type recovery =
  { day : int
  ; target_count : int
  ; anchor_ids : string list
  ; entries : Journal_graph_projection.timeline_entry list
  ; next_cursor : Journal_graph_projection.block_cursor option
  ; reads : int
  }

type t =
  { today : int
  ; slots : slot list
  ; first_retained_index : int
  ; preceding_heading : bool
  ; total_count : int
  ; visible_first : int
  ; visible_last_exclusive : int
  ; visible_demand : request list option
  ; pending : (int64 * request) option
  ; recovery : recovery option
  ; day_failures : (int * string) list
  ; expanded_ids : string list
  ; anchor_decision : anchor_decision
  ; focus_restore_block_id : string option
  ; next_expansion_epoch : int64
  }

type staged_delete =
  { block : Journal_model.t
  ; before : t
  }

type window =
  { total_count : int
  ; first_index : int
  ; slots : slot list
  }

type synthetic_window =
  { first_index : int
  ; count : int
  }

type extent_geometry =
  { default_extent : float
  ; overrides : Ui.Widget.Sparse_extent_override.t list
  }

let maximum_slots = 512
let maximum_supplied_rows = 40
let overscan = 4
let extent_strategy = Known_profile_extents
let renderer_event_surface = [ `Visible_range ]
let initial_capture_fab_scroll = { presentation = Extended; accumulated_travel = 0. }
let capture_fab_presentation state = state.presentation
let capture_fab_accumulated_travel state = state.accumulated_travel

let update_capture_fab_scroll state ~pixels ~delta =
  if Float.compare pixels 0. <= 0
  then initial_capture_fab_scroll
  else if Float.equal delta 0.
  then state
  else (
    let same_direction =
      (Float.compare state.accumulated_travel 0. > 0 && Float.compare delta 0. > 0)
      || (Float.compare state.accumulated_travel 0. < 0 && Float.compare delta 0. < 0)
    in
    let accumulated_travel =
      if Float.equal state.accumulated_travel 0. || same_direction
      then state.accumulated_travel +. delta
      else delta
    in
    match state.presentation with
    | Extended when Float.compare accumulated_travel 24. >= 0 ->
      { presentation = Compact; accumulated_travel = 0. }
    | Compact when Float.compare accumulated_travel (-24.) <= 0 ->
      { presentation = Extended; accumulated_travel = 0. }
    | Extended | Compact -> { state with accumulated_travel })
;;

let empty ~today =
  { today
  ; slots = []
  ; first_retained_index = 0
  ; preceding_heading = false
  ; total_count = 0
  ; visible_first = 0
  ; visible_last_exclusive = 0
  ; visible_demand = None
  ; pending = None
  ; recovery = None
  ; day_failures = []
  ; expanded_ids = []
  ; anchor_decision = Reset_to_top
  ; focus_restore_block_id = None
  ; next_expansion_epoch = 1L
  }
;;

let compare_blocks left right =
  match
    String.compare (Journal_model.sibling_order left) (Journal_model.sibling_order right)
  with
  | 0 -> String.compare (Journal_model.id left) (Journal_model.id right)
  | comparison -> comparison
;;

let sort_blocks blocks = List.sort compare_blocks blocks

let slot_key = function
  | Day_heading page -> "day:" ^ string_of_int page.Journal_graph_projection.day
  | Top_level entry -> "block:" ^ Journal_model.id entry.block
  | Child_preview { block; _ } -> "block:" ^ Journal_model.id block
  | Day_continuation { day; _ } -> "day-continuation:" ^ string_of_int day
  | Children_loading { parent_id; epoch } ->
    Printf.sprintf "children-loading:%s:%Ld" parent_id epoch
  | Children_more { parent_id } -> "children-more:" ^ parent_id
  | Feed_continuation { before_day } -> "feed-continuation:" ^ string_of_int before_day
;;

let drop count values =
  let rec loop remaining values =
    if remaining <= 0
    then values
    else (
      match values with
      | [] -> []
      | _ :: tail -> loop (remaining - 1) tail)
  in
  loop count values
;;

let take count values =
  let rec loop remaining reversed = function
    | _ when remaining <= 0 -> List.rev reversed
    | [] -> List.rev reversed
    | head :: tail -> loop (remaining - 1) (head :: reversed) tail
  in
  loop count [] values
;;

let cap_retained (state : t) =
  let extra = List.length state.slots - maximum_slots in
  if extra <= 0
  then state
  else (
    let slots = drop extra state.slots in
    { state with
      slots
    ; day_failures =
        List.filter
          (fun (day, _) ->
             List.exists
               (function
                 | Day_continuation item -> item.day = day
                 | _ -> false)
               slots)
          state.day_failures
    ; first_retained_index = state.first_retained_index + extra
    ; preceding_heading =
        (match List.nth_opt state.slots (extra - 1) with
         | Some (Day_heading _) -> true
         | _ -> false)
    })
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
    List.filter_map
      (function
        | Top_level entry when Journal_model.journal_day entry.block = day -> Some entry
        | _ -> None)
      state.slots
  in
  let anchor_ids =
    let anchor_index = max 0 (state.visible_first - state.first_retained_index) in
    List.mapi (fun index slot -> index, slot) state.slots
    |> List.filter_map (fun (index, slot) ->
      match slot with
      | Top_level entry -> Some (index, Journal_model.id entry.block)
      | Child_preview { block; _ } -> Some (index, Journal_model.id block)
      | _ -> None)
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
  | Children_loading { parent_id; epoch } -> Some (Children { parent_id; epoch })
  | Day_continuation { day; after } -> Some (Day { day; after })
  | Feed_continuation { before_day } -> Some (Feed { before_day = Some before_day })
  | Day_heading _ | Top_level _ | Child_preview _ | Children_more _ -> None
;;

let request_is_retained (state : t) request =
  List.exists
    (fun slot ->
       match request_of_slot slot with
       | Some candidate -> candidate = request
       | None -> false)
    state.slots
;;

let visible_requests (state : t) ~first_index ~last_exclusive =
  let lower = max state.first_retained_index (first_index - overscan) in
  let upper = min state.total_count (last_exclusive + overscan) in
  let rec collect index pages = function
    | [] -> List.rev pages
    | _ when index >= upper -> List.rev pages
    | slot :: tail ->
      (match if index < lower then None else request_of_slot slot with
       | Some ((Day _ | Feed _) as request) -> collect (index + 1) (request :: pages) tail
       | Some (Children _) | None -> collect (index + 1) pages tail)
  in
  collect state.first_retained_index [] state.slots
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
  let rec loop index reversed = function
    | [] -> None
    | slot :: tail when predicate slot ->
      Some (index, List.rev_append reversed (replacement @ tail))
    | slot :: tail -> loop (index + 1) (slot :: reversed) tail
  in
  match loop state.first_retained_index [] state.slots with
  | None -> state
  | Some (_index, slots) ->
    let delta = List.length replacement - 1 in
    { state with
      slots
    ; total_count = state.total_count + delta
    ; pending = None
    ; anchor_decision = Preserve_visible_slot
    }
    |> cap_retained
;;

let apply_feed (state : t) ~generation feed =
  match state.pending with
  | Some (expected_generation, Feed { before_day })
    when Int64.equal expected_generation generation ->
    let projected = feed_slots ~today:state.today feed in
    (match before_day with
     | None when state.slots = [] ->
       { state with
         slots = projected
       ; first_retained_index = 0
       ; preceding_heading = false
       ; total_count = List.length projected
       ; visible_first = 0
       ; visible_last_exclusive = min maximum_supplied_rows (List.length projected)
       ; visible_demand = None
       ; pending = None
       ; expanded_ids = []
       ; anchor_decision = Reset_to_top
       }
       |> cap_retained
     | None ->
       let old_slots = state.slots in
       let owned_slots parent_id =
         let rec find = function
           | [] -> []
           | Top_level entry :: tail
             when String.equal (Journal_model.id entry.block) parent_id ->
             let rec take_owned reversed = function
               | (Child_preview preview as slot) :: tail
                 when String.equal preview.parent_id parent_id ->
                 take_owned (slot :: reversed) tail
               | (Children_loading loading as slot) :: tail
                 when String.equal loading.parent_id parent_id ->
                 take_owned (slot :: reversed) tail
               | (Children_more more as slot) :: tail
                 when String.equal more.parent_id parent_id ->
                 take_owned (slot :: reversed) tail
               | _ -> List.rev reversed
             in
             take_owned [] tail
           | _ :: tail -> find tail
         in
         find old_slots
       in
       let expanded_ids =
         List.filter
           (fun parent_id ->
              List.exists
                (function
                  | Top_level entry ->
                    String.equal (Journal_model.id entry.block) parent_id
                  | Day_heading _
                  | Child_preview _
                  | Day_continuation _
                  | Children_loading _
                  | Children_more _
                  | Feed_continuation _ -> false)
                projected)
           state.expanded_ids
       in
       let slots =
         List.concat_map
           (function
             | Top_level entry as slot
               when List.exists (String.equal (Journal_model.id entry.block)) expanded_ids
               -> slot :: owned_slots (Journal_model.id entry.block)
             | slot -> [ slot ])
           projected
       in
       let anchor_key =
         let offset = state.visible_first - state.first_retained_index in
         List.nth_opt old_slots offset |> Option.map slot_key
       in
       let rec find_index index key = function
         | [] -> None
         | slot :: _ when String.equal (slot_key slot) key -> Some index
         | _ :: tail -> find_index (index + 1) key tail
       in
       let visible_span = state.visible_last_exclusive - state.visible_first in
       let visible_first =
         Option.bind anchor_key (fun key -> find_index 0 key slots)
         |> Option.value ~default:(min state.visible_first (List.length slots))
       in
       let visible_last_exclusive =
         min (List.length slots) (visible_first + visible_span)
       in
       { state with
         slots
       ; first_retained_index = 0
       ; preceding_heading = false
       ; total_count = List.length slots
       ; visible_first
       ; visible_last_exclusive
       ; visible_demand = None
       ; pending = None
       ; expanded_ids
       ; anchor_decision = Preserve_visible_slot
       }
       |> cap_retained
     | Some expected_before_day ->
       let request = Feed { before_day = Some expected_before_day } in
       let state =
         replace_slot
           state
           ~predicate:(function
             | Feed_continuation { before_day } -> before_day = expected_before_day
             | _ -> false)
           projected
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
    let entries =
      List.sort
        (fun (left : Journal_graph_projection.timeline_entry)
          (right : Journal_graph_projection.timeline_entry) ->
           compare_blocks left.block right.block)
        page.entries
    in
    let replacement =
      List.map (fun entry -> Top_level entry) entries
      @
      match page.continuation with
      | None -> []
      | Some continuation -> [ Day_continuation { day; after = Some continuation } ]
    in
    let request = Day { day; after } in
    let state =
      replace_slot
        state
        ~predicate:(function
          | Day_continuation candidate -> candidate.day = day && candidate.after = after
          | _ -> false)
        replacement
    in
    let successor =
      Option.map (fun after -> Day { day; after = Some after }) page.continuation
    in
    if successor = Some request
    then stop_visible_drain state
    else complete_visible_request ?successor state request
  | Some _ | None -> state
;;

let replace_block (state : t) replacement =
  let state = invalidate_recovery_for_day state (Journal_model.journal_day replacement) in
  let replacement_id = Journal_model.id replacement in
  let slots =
    List.map
      (function
        | Top_level entry when String.equal (Journal_model.id entry.block) replacement_id
          -> Top_level { entry with block = replacement }
        | Child_preview preview
          when String.equal (Journal_model.id preview.block) replacement_id ->
          Child_preview { preview with block = replacement }
        | slot -> slot)
      state.slots
  in
  { state with slots; anchor_decision = Preserve_visible_slot }
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
  let slots =
    List.map
      (function
        | Top_level entry when String.equal (Journal_model.id entry.block) replacement_id
          -> Top_level replacement
        | slot -> slot)
      state.slots
  in
  { state with slots; anchor_decision = Preserve_visible_slot }
;;

let replace_timeline_entry_page
      (state : t)
      ~(page : Journal_graph_projection.page)
      (replacement : Journal_graph_projection.timeline_entry_page)
  =
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
  let old_parent_ids =
    List.filter_map
      (function
        | Top_level entry when Journal_model.journal_day entry.block = page.day ->
          Some (Journal_model.id entry.block)
        | _ -> None)
      state.slots
  in
  let replacement_slots =
    List.concat_map
      (fun (entry : Journal_graph_projection.timeline_entry) ->
         let parent_id = Journal_model.id entry.block in
         Top_level entry
         ::
         (if
            List.mem parent_id state.expanded_ids
            && Journal_model.child_count entry.block > 0
          then [ Children_loading { parent_id; epoch = state.next_expansion_epoch } ]
          else []))
      replacement.entries
    @
    match replacement.continuation with
    | None -> []
    | Some after -> [ Day_continuation { day = page.day; after = Some after } ]
  in
  let belongs_to_page = function
    | Top_level entry -> String.equal (Journal_model.page_id entry.block) page.id
    | Child_preview { block; _ } -> String.equal (Journal_model.page_id block) page.id
    | Day_continuation continuation -> continuation.day = page.day
    | Children_loading { parent_id; _ } | Children_more { parent_id } ->
      List.mem parent_id old_parent_ids
    | Day_heading _ | Feed_continuation _ -> false
  in
  let rec skip_page = function
    | slot :: rest when belongs_to_page slot -> skip_page rest
    | rest -> rest
  in
  let rec replace reversed = function
    | (Day_heading candidate as heading) :: rest when String.equal candidate.id page.id ->
      Some (List.rev_append reversed ((heading :: replacement_slots) @ skip_page rest))
    | Top_level entry :: _ as rest
      when String.equal (Journal_model.page_id entry.block) page.id ->
      Some (List.rev_append reversed (replacement_slots @ skip_page rest))
    | slot :: rest -> replace (slot :: reversed) rest
    | [] -> None
  in
  match replace [] state.slots with
  | None -> state
  | Some slots ->
    let delta = List.length slots - List.length state.slots in
    { state with
      slots
    ; pending
    ; next_expansion_epoch = Int64.succ state.next_expansion_epoch
    ; expanded_ids =
        List.filter
          (fun id ->
             (not (List.mem id old_parent_ids))
             || List.exists
                  (fun (entry : Journal_graph_projection.timeline_entry) ->
                     String.equal id (Journal_model.id entry.block)
                     && Journal_model.child_count entry.block > 0)
                  replacement.entries)
          state.expanded_ids
    ; total_count = max 0 (state.total_count + delta)
    ; anchor_decision = Preserve_visible_slot
    }
    |> cap_retained
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
        let anchor =
          List.find_map
            (function
              | Child_preview { parent_id; block }
                when String.equal (Journal_model.id block) anchor -> Some parent_id
              | _ -> None)
            state.slots
          |> Option.value ~default:anchor
        in
        List.mem anchor ids
        || List.exists
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
    if invalid || List.length entries > maximum_slots || ((not complete) && reads >= 16)
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
        List.find_map
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
               List.exists
                 (function
                   | Top_level entry -> String.equal id (Journal_model.id entry.block)
                   | Child_preview { block; _ } ->
                     String.equal id (Journal_model.id block)
                   | _ -> false)
                 updated.slots)
            recovery.anchor_ids
        in
        let anchor_key =
          match anchor_id with
          | Some id -> "block:" ^ id
          | None -> "day:" ^ string_of_int recovery.day
        in
        let rec index n = function
          | [] -> state.visible_first
          | slot :: _ when slot_key slot = anchor_key -> n
          | _ :: tail -> index (n + 1) tail
        in
        let visible_first = index updated.first_retained_index updated.slots in
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

let apply_detail (state : t) ~generation (detail : Journal_graph_projection.detail) =
  match state.pending with
  | Some (expected_generation, Children { parent_id; epoch })
    when Int64.equal expected_generation generation
         && String.equal parent_id (Journal_model.id detail.root) ->
    let owns_loading_slot =
      List.exists
        (function
          | Children_loading candidate ->
            String.equal candidate.parent_id parent_id
            && Int64.equal candidate.epoch epoch
          | _ -> false)
        state.slots
    in
    if not owns_loading_slot
    then
      { state with
        pending = None
      ; visible_demand = Option.map (fun _ -> []) state.visible_demand
      }
    else (
      let state = replace_block state detail.root in
      let all_blocks = sort_blocks detail.children.blocks in
      let blocks = take 3 all_blocks in
      let has_more =
        Option.is_some detail.children.continuation || List.length all_blocks > 3
      in
      let replacement =
        List.map (fun block -> Child_preview { parent_id; block }) blocks
        @ if has_more then [ Children_more { parent_id } ] else []
      in
      replace_slot
        state
        ~predicate:(function
          | Children_loading candidate ->
            String.equal candidate.parent_id parent_id
            && Int64.equal candidate.epoch epoch
          | _ -> false)
        replacement)
  | Some _ | None -> state
;;

let reconcile_detail (state : t) (detail : Journal_graph_projection.detail) =
  let parent_id = Journal_model.id detail.root in
  let state = replace_block state detail.root in
  if not (List.exists (String.equal parent_id) state.expanded_ids)
  then state
  else (
    let all_blocks = sort_blocks detail.children.blocks in
    let blocks = take 3 all_blocks in
    let has_more =
      Option.is_some detail.children.continuation || List.length all_blocks > 3
    in
    let replacement =
      List.map (fun block -> Child_preview { parent_id; block }) blocks
      @ if has_more then [ Children_more { parent_id } ] else []
    in
    let rec remove_owned = function
      | Child_preview preview :: rest when String.equal preview.parent_id parent_id ->
        remove_owned rest
      | Children_loading loading :: rest when String.equal loading.parent_id parent_id ->
        remove_owned rest
      | Children_more more :: rest when String.equal more.parent_id parent_id ->
        remove_owned rest
      | rest -> rest
    in
    let rec replace reversed = function
      | (Top_level entry as slot) :: rest
        when String.equal (Journal_model.id entry.block) parent_id ->
        Some (List.rev_append reversed ((slot :: replacement) @ remove_owned rest))
      | (Child_preview preview as slot) :: rest
        when String.equal (Journal_model.id preview.block) parent_id ->
        Some (List.rev_append reversed ((slot :: replacement) @ remove_owned rest))
      | slot :: rest -> replace (slot :: reversed) rest
      | [] -> None
    in
    match replace [] state.slots with
    | None -> state
    | Some slots ->
      let delta = List.length slots - List.length state.slots in
      { state with
        slots
      ; total_count = max 0 (state.total_count + delta)
      ; anchor_decision = Preserve_visible_slot
      }
      |> cap_retained)
;;

let next_request (state : t) =
  if Option.is_some state.pending
  then None
  else (
    let rec find_children = function
      | [] -> None
      | Children_loading { parent_id; epoch } :: _ -> Some (Children { parent_id; epoch })
      | _ :: tail -> find_children tail
    in
    match state.recovery with
    | Some recovery -> Some (Day { day = recovery.day; after = recovery.next_cursor })
    | None ->
      (match find_children state.slots with
       | Some _ as request -> request
       | None -> Option.bind state.visible_demand (next_visible_request state)))
;;

let pending_request (state : t) = state.pending

let expand (state : t) ~parent_id =
  if List.exists (String.equal parent_id) state.expanded_ids
  then state
  else (
    let rec insert reversed = function
      | [] -> None
      | (Top_level entry as parent) :: tail
        when String.equal (Journal_model.id entry.block) parent_id ->
        Some
          (List.rev_append
             reversed
             (parent
              :: Children_loading { parent_id; epoch = state.next_expansion_epoch }
              :: tail))
      | slot :: tail -> insert (slot :: reversed) tail
    in
    match insert [] state.slots with
    | None -> state
    | Some slots ->
      { state with
        slots
      ; total_count = state.total_count + 1
      ; expanded_ids = parent_id :: state.expanded_ids
      ; anchor_decision = Preserve_visible_slot
      ; next_expansion_epoch = Int64.succ state.next_expansion_epoch
      }
      |> cap_retained)
;;

let collapse (state : t) ~parent_id =
  if not (List.exists (String.equal parent_id) state.expanded_ids)
  then state
  else (
    let rec loop index reversed = function
      | [] -> state.slots, 0, state.total_count
      | (Top_level entry as parent) :: tail
        when String.equal (Journal_model.id entry.block) parent_id ->
        let rec remove removed = function
          | Child_preview candidate :: rest
            when String.equal candidate.parent_id parent_id -> remove (removed + 1) rest
          | Children_loading candidate :: rest
            when String.equal candidate.parent_id parent_id -> remove (removed + 1) rest
          | Children_more candidate :: rest
            when String.equal candidate.parent_id parent_id -> remove (removed + 1) rest
          | rest -> List.rev_append reversed (parent :: rest), removed, index
        in
        remove 0 tail
      | slot :: tail -> loop (index + 1) (slot :: reversed) tail
    in
    let slots, removed, _parent_index = loop state.first_retained_index [] state.slots in
    if removed = 0
    then
      { state with
        expanded_ids =
          List.filter
            (fun candidate -> not (String.equal parent_id candidate))
            state.expanded_ids
      ; anchor_decision = Preserve_visible_slot
      }
    else
      { state with
        slots
      ; total_count = state.total_count - removed
      ; expanded_ids =
          List.filter
            (fun candidate -> not (String.equal parent_id candidate))
            state.expanded_ids
      ; anchor_decision = Preserve_visible_slot
      })
;;

let prepend_timeline_entry (state : t) (entry : Journal_graph_projection.timeline_entry) =
  let block = entry.Journal_graph_projection.block in
  let state = invalidate_recovery_for_day state (Journal_model.journal_day block) in
  if
    List.exists
      (function
        | Top_level candidate ->
          String.equal (Journal_model.id candidate.block) (Journal_model.id block)
        | _ -> false)
      state.slots
  then { (replace_timeline_entry state entry) with anchor_decision = Reset_to_top }
  else (
    let rec insert reversed = function
      | [] -> List.rev (Top_level entry :: reversed), state.total_count
      | (Top_level candidate as slot) :: tail
        when Journal_model.journal_day candidate.block = Journal_model.journal_day block
             && compare_blocks block candidate.block <= 0 ->
        ( List.rev_append reversed (Top_level entry :: slot :: tail)
        , state.first_retained_index + List.length reversed )
      | (Day_heading page as slot) :: tail when Journal_model.journal_day block > page.day
        ->
        ( List.rev_append reversed (Top_level entry :: slot :: tail)
        , state.first_retained_index + List.length reversed )
      | (Feed_continuation _ as slot) :: tail ->
        ( List.rev_append reversed (Top_level entry :: slot :: tail)
        , state.first_retained_index + List.length reversed )
      | slot :: tail -> insert (slot :: reversed) tail
    in
    let slots, _inserted_index = insert [] state.slots in
    { state with
      slots
    ; total_count = state.total_count + 1
    ; anchor_decision = Reset_to_top
    }
    |> cap_retained)
;;

let remove_orphan_day_headings ~today slots =
  let rec has_day_content day = function
    | [] | Day_heading _ :: _ | Feed_continuation _ :: _ -> false
    | Top_level entry :: _ -> Journal_model.journal_day entry.block = day
    | Day_continuation continuation :: _ -> continuation.day = day
    | Child_preview _ :: tail | Children_loading _ :: tail | Children_more _ :: tail ->
      has_day_content day tail
  in
  let rec loop reversed = function
    | Day_heading page :: tail
      when page.Journal_graph_projection.day <> today
           && not (has_day_content page.day tail) -> loop reversed tail
    | slot :: tail -> loop (slot :: reversed) tail
    | [] -> List.rev reversed
  in
  loop [] slots
;;

let stage_delete (state : t) ~block_id =
  let rec find reversed = function
    | [] -> None
    | (Top_level entry as slot) :: tail
      when String.equal (Journal_model.id entry.block) block_id ->
      Some (List.rev reversed, slot, entry.block, tail)
    | Child_preview { block; _ } :: _ when String.equal (Journal_model.id block) block_id
      -> None
    | slot :: tail -> find (slot :: reversed) tail
  in
  match find [] state.slots with
  | None -> None
  | Some (prefix, _, block, tail) ->
    let state = invalidate_recovery_for_day state (Journal_model.journal_day block) in
    let rec remove_owned = function
      | Child_preview preview :: rest when String.equal preview.parent_id block_id ->
        remove_owned rest
      | Children_loading continuation :: rest
        when String.equal continuation.parent_id block_id -> remove_owned rest
      | Children_more continuation :: rest
        when String.equal continuation.parent_id block_id -> remove_owned rest
      | rest -> rest
    in
    let slots =
      prefix @ remove_owned tail |> remove_orphan_day_headings ~today:state.today
    in
    let removed = List.length state.slots - List.length slots in
    let total_count = max 0 (state.total_count - removed) in
    let before = { state with pending = None } in
    let retained_ids =
      List.filter_map
        (function
          | Top_level entry -> Some (Journal_model.id entry.block)
          | Child_preview { block; _ } -> Some (Journal_model.id block)
          | Day_heading _
          | Day_continuation _
          | Children_loading _
          | Children_more _
          | Feed_continuation _ -> None)
        slots
    in
    Some
      ( { state with
          slots
        ; total_count
        ; visible_first = min state.visible_first total_count
        ; visible_last_exclusive = min state.visible_last_exclusive total_count
        ; pending = None
        ; expanded_ids =
            List.filter
              (fun id -> List.exists (String.equal id) retained_ids)
              state.expanded_ids
        ; anchor_decision = Preserve_visible_slot
        ; focus_restore_block_id = None
        }
      , { block; before } )
;;

let remove_block (state : t) ~block_id =
  let state =
    List.fold_left
      (fun state -> function
         | Child_preview { block; _ } when String.equal (Journal_model.id block) block_id
           -> invalidate_recovery_for_day state (Journal_model.journal_day block)
         | _ -> state)
      state
      state.slots
  in
  match stage_delete state ~block_id with
  | Some (state, _) -> state
  | None ->
    let slots =
      List.filter
        (function
          | Child_preview { block; _ } ->
            not (String.equal (Journal_model.id block) block_id)
          | Day_heading _
          | Top_level _
          | Day_continuation _
          | Children_loading _
          | Children_more _
          | Feed_continuation _ -> true)
        state.slots
    in
    let removed = List.length state.slots - List.length slots in
    { state with
      slots
    ; total_count = max 0 (state.total_count - removed)
    ; expanded_ids =
        List.filter (fun id -> not (String.equal id block_id)) state.expanded_ids
    ; anchor_decision = Preserve_visible_slot
    }
;;

let undo_delete (state : t) staged =
  let target_key = "block:" ^ Journal_model.id staged.block in
  if List.exists (fun slot -> String.equal (slot_key slot) target_key) state.slots
  then state
  else (
    match stage_delete staged.before ~block_id:(Journal_model.id staged.block) with
    | None -> state
    | Some (without_target, _) ->
      let retained_keys = List.map slot_key without_target.slots in
      let removed slot = not (List.mem (slot_key slot) retained_keys) in
      let rec insert_before anchor slot = function
        | [] -> [ slot ]
        | head :: _ as slots when Some (slot_key head) = anchor -> slot :: slots
        | head :: tail -> head :: insert_before anchor slot tail
      in
      let slots, _, inserted =
        List.fold_right
          (fun slot (slots, anchor, inserted) ->
             let key = slot_key slot in
             if List.exists (fun current -> String.equal (slot_key current) key) slots
             then slots, Some key, inserted
             else if removed slot
             then insert_before anchor slot slots, Some key, inserted + 1
             else slots, anchor, inserted)
          staged.before.slots
          (state.slots, None, 0)
      in
      let id = Journal_model.id staged.block in
      let expanded_ids =
        if List.mem id staged.before.expanded_ids
        then id :: state.expanded_ids
        else state.expanded_ids
      in
      { state with
        slots
      ; total_count = state.total_count + inserted
      ; expanded_ids
      ; pending = None
      ; anchor_decision = staged.before.anchor_decision
      ; next_expansion_epoch =
          Int64.max state.next_expansion_epoch staged.before.next_expansion_epoch
      }
      |> cap_retained)
;;

let return_from_detail (state : t) ~block_id =
  let exists =
    List.exists
      (function
        | Top_level entry -> String.equal (Journal_model.id entry.block) block_id
        | Child_preview { block; _ } -> String.equal (Journal_model.id block) block_id
        | _ -> false)
      state.slots
  in
  if exists
  then
    { state with
      anchor_decision = Preserve_visible_slot
    ; focus_restore_block_id = Some block_id
    }
  else state
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

let synthetic_window ~total_count ~first_visible ~last_exclusive =
  let total_count = max 0 total_count in
  let first_visible = max 0 (min total_count first_visible) in
  let last_exclusive = max first_visible (min total_count last_exclusive) in
  let first_index = max 0 (first_visible - overscan) in
  let desired_last =
    min total_count (max last_exclusive (first_index + maximum_supplied_rows))
  in
  { first_index; count = min maximum_supplied_rows (desired_last - first_index) }
;;

let current_window (state : t) =
  if state.total_count = 0 || state.slots = []
  then { total_count = state.total_count; first_index = 0; slots = [] }
  else (
    let desired =
      synthetic_window
        ~total_count:state.total_count
        ~first_visible:state.visible_first
        ~last_exclusive:state.visible_last_exclusive
    in
    let first_index = max state.first_retained_index desired.first_index in
    let offset = first_index - state.first_retained_index in
    let available = state.total_count - first_index in
    let slots =
      state.slots |> drop offset |> take (min maximum_supplied_rows available)
    in
    { total_count = state.total_count; first_index; slots })
;;

let retained_slots (state : t) = state.slots
let retained_slot_count (state : t) = List.length state.slots
let first_retained_index (state : t) = state.first_retained_index
let total_count (state : t) = state.total_count
let today (state : t) = state.today
let set_today (state : t) ~today = { state with today }
let anchor_decision (state : t) = state.anchor_decision
let focus_restore_block_id (state : t) = state.focus_restore_block_id

let is_expanded (state : t) ~block_id =
  List.exists (String.equal block_id) state.expanded_ids
;;

let heading_spacing (state : t) ~day =
  let rec find preceding = function
    | Day_heading page :: rest when page.Journal_graph_projection.day = day ->
      let before =
        if preceding then 22. else Journal_visual_tokens.row_geometry.day_heading_before
      in
      let after =
        match rest with
        | Day_heading _ :: _ -> 0.
        | _ -> Journal_visual_tokens.row_geometry.day_heading_after
      in
      before, after
    | Day_heading _ :: rest -> find true rest
    | _ :: rest -> find false rest
    | [] ->
      ( Journal_visual_tokens.row_geometry.day_heading_before
      , Journal_visual_tokens.row_geometry.day_heading_after )
  in
  find state.preceding_heading state.slots
;;

let extent_geometry (state : t) ~profile =
  let default_extent = Journal_visual_tokens.block_extent ~profile ~visible_lines:1 in
  let extent = function
    | Top_level entry ->
      let item = Journal_row.Item.of_timeline_entry entry in
      Journal_row.Item.visible_extent
        item
        ~profile
        ~expanded:(is_expanded state ~block_id:(Journal_model.id entry.block))
    | Child_preview { block; _ } ->
      Journal_row.Item.visible_extent
        (Journal_row.Item.of_block block)
        ~profile
        ~expanded:true
    | Children_loading _ ->
      Journal_visual_tokens.fixed_extent ~profile Journal_visual_tokens.Children_loading
    | Children_more _ ->
      Journal_visual_tokens.fixed_extent ~profile Journal_visual_tokens.Children_more
    | Day_heading page ->
      let before, after = heading_spacing state ~day:page.day in
      Float.ceil
        (before +. (24. *. profile.Journal_visual_tokens.date_text_scale) +. after)
    | Day_continuation _ ->
      Journal_visual_tokens.fixed_extent ~profile Journal_visual_tokens.Day_continuation
    | Feed_continuation _ ->
      Journal_visual_tokens.fixed_extent ~profile Journal_visual_tokens.Feed_continuation
  in
  let overrides =
    List.mapi
      (fun offset slot ->
         let index = state.first_retained_index + offset in
         let extent = extent slot in
         if Float.equal extent default_extent
         then None
         else Some { Ui.Widget.Sparse_extent_override.index; extent })
      state.slots
    |> List.filter_map Fun.id
  in
  { default_extent; overrides }
;;
