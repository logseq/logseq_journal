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
  | Bottom_clearance

type anchor_decision =
  | Preserve_visible_slot
  | Reset_to_top

type extent_strategy = Known_profile_extents

type special_extent =
  | Day_extent
  | Bottom_extent

type t =
  { today : int
  ; slots : slot list
  ; first_retained_index : int
  ; total_count : int
  ; visible_first : int
  ; visible_last_exclusive : int
  ; pending : (int64 * request) option
  ; expanded_ids : string list
  ; special_extents : (int * special_extent) list
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
  ; overrides : Ui.Native_widget.Sparse_extent_list.extent_override list
  ; final_clearance_extent : float
  }

let maximum_slots = 512
let maximum_supplied_rows = 40
let overscan = 4
let extent_strategy = Known_profile_extents
let renderer_event_surface = [ `Visible_range ]

let empty ~today =
  { today
  ; slots = []
  ; first_retained_index = 0
  ; total_count = 0
  ; visible_first = 0
  ; visible_last_exclusive = 0
  ; pending = None
  ; expanded_ids = []
  ; special_extents = []
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
  | Bottom_clearance -> "bottom-clearance"
;;

let indexed_specials slots =
  List.mapi
    (fun index -> function
       | Day_heading _ -> Some (index, Day_extent)
       | Bottom_clearance -> Some (index, Bottom_extent)
       | Top_level _
       | Child_preview _
       | Day_continuation _
       | Children_loading _
       | Children_more _
       | Feed_continuation _ ->
         None)
    slots
  |> List.filter_map Fun.id
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
  else
    { state with
      slots = drop extra state.slots
    ; first_retained_index = state.first_retained_index + extra
    }
;;

let begin_request (state : t) ~generation request =
  match state.pending with
  | Some _ -> state
  | None -> { state with pending = Some (generation, request) }
;;

let day_slots ~today (day : Journal_graph_projection.day_feed) =
  let entries =
    List.sort
      (fun
        (left : Journal_graph_projection.timeline_entry)
        (right : Journal_graph_projection.timeline_entry)
        -> compare_blocks left.block right.block)
      day.entries
  in
  let heading = if day.page.day = today then [] else [ Day_heading day.page ] in
  let rows = List.map (fun entry -> Top_level entry) entries in
  let continuation =
    if day.has_more_entries
    then
      [ Day_continuation
          { day = day.page.day
          ; after = day.continuation
          }
      ]
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

let shift_specials specials ~after_index ~delta =
  List.map
    (fun (index, kind) ->
       if index > after_index then index + delta, kind else index, kind)
    specials
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
  | Some (index, slots) ->
    let delta = List.length replacement - 1 in
    let special_extents =
      shift_specials state.special_extents ~after_index:index ~delta
    in
    let inserted_specials =
      indexed_specials replacement
      |> List.map (fun (offset, kind) -> index + offset, kind)
    in
    let special_extents =
      special_extents
      |> List.filter (fun (special_index, _) -> special_index <> index)
      |> List.rev_append inserted_specials
      |> List.sort (fun (left, _) (right, _) -> Int.compare left right)
    in
    { state with
      slots
    ; total_count = state.total_count + delta
    ; pending = None
    ; special_extents
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
     | None ->
       let slots =
         match projected with
         | [] -> []
         | _ -> projected @ [ Bottom_clearance ]
       in
       { state with
         slots
       ; first_retained_index = 0
       ; total_count = List.length slots
       ; visible_first = 0
       ; visible_last_exclusive = min maximum_supplied_rows (List.length slots)
       ; pending = None
       ; expanded_ids = []
       ; special_extents = indexed_specials slots
       ; anchor_decision = Reset_to_top
       }
       |> cap_retained
     | Some expected_before_day ->
       replace_slot
         state
         ~predicate:(function
           | Feed_continuation { before_day } -> before_day = expected_before_day
           | _ -> false)
         projected)
  | Some _ | None -> state
;;

let apply_timeline_entry_page
      (state : t)
      ~generation
      (page : Journal_graph_projection.timeline_entry_page)
  =
  match state.pending with
  | Some (expected_generation, Day { day; after })
    when Int64.equal expected_generation generation ->
    let entries =
      List.sort
        (fun
          (left : Journal_graph_projection.timeline_entry)
          (right : Journal_graph_projection.timeline_entry)
          -> compare_blocks left.block right.block)
        page.entries
    in
    let replacement =
      List.map (fun entry -> Top_level entry) entries
      @
      match page.continuation with
      | None -> []
      | Some continuation -> [ Day_continuation { day; after = Some continuation } ]
    in
    replace_slot
      state
      ~predicate:(function
        | Day_continuation candidate -> candidate.day = day && candidate.after = after
        | _ -> false)
      replacement
  | Some _ | None -> state
;;

let replace_block (state : t) replacement =
  let replacement_id = Journal_model.id replacement in
  let slots =
    List.map
      (function
        | Top_level entry
          when String.equal (Journal_model.id entry.block) replacement_id ->
          Top_level { entry with block = replacement }
        | Child_preview preview
          when String.equal (Journal_model.id preview.block) replacement_id ->
          Child_preview { preview with block = replacement }
        | slot -> slot)
      state.slots
  in
  { state with slots; anchor_decision = Preserve_visible_slot }
;;

let replace_timeline_entry (state : t) replacement =
  let replacement_id =
    Journal_model.id replacement.Journal_graph_projection.block
  in
  let slots =
    List.map
      (function
        | Top_level entry
          when String.equal (Journal_model.id entry.block) replacement_id ->
          Top_level replacement
        | slot -> slot)
      state.slots
  in
  { state with slots; anchor_decision = Preserve_visible_slot }
;;

let apply_detail
      (state : t)
      ~generation
      (detail : Journal_graph_projection.detail)
  =
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
    then { state with pending = None }
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

let next_request (state : t) =
  if Option.is_some state.pending
  then None
  else (
    let rec find_children = function
      | [] -> None
      | Children_loading { parent_id; epoch } :: _ ->
        Some (Children { parent_id; epoch })
      | _ :: tail -> find_children tail
    in
    match find_children state.slots with
    | Some _ as request -> request
    | None ->
      let rec find_page = function
        | [] -> None
        | Day_continuation { day; after } :: _ -> Some (Day { day; after })
        | Feed_continuation { before_day } :: _ ->
          Some (Feed { before_day = Some before_day })
        | _ :: tail -> find_page tail
      in
      find_page state.slots)
;;

let request_for_visible_range (state : t) ~first_index ~last_exclusive =
  if Option.is_some state.pending
  then None
  else (
    let lower = max state.first_retained_index (first_index - overscan) in
    let upper = min state.total_count (last_exclusive + overscan) in
    let rec find index fallback = function
      | [] -> fallback
      | _ when index >= upper -> fallback
      | slot :: tail ->
        let request =
          if index < lower
          then None
          else (
            match slot with
            | Children_loading { parent_id; epoch } ->
              Some (Children { parent_id; epoch })
            | Day_continuation { day; after } -> Some (Day { day; after })
            | Feed_continuation { before_day } ->
              Some (Feed { before_day = Some before_day })
            | Day_heading _
            | Top_level _
            | Child_preview _
            | Children_more _
            | Bottom_clearance -> None)
        in
        (match request with
         | Some (Children _) as child -> child
         | Some _ as request -> find (index + 1) request tail
         | None -> find (index + 1) fallback tail)
    in
    find state.first_retained_index None state.slots)
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
      let parent_index =
        let rec find index = function
          | Top_level entry :: _
            when String.equal (Journal_model.id entry.block) parent_id -> index
          | _ :: tail -> find (index + 1) tail
          | [] -> state.total_count
        in
        find state.first_retained_index state.slots
      in
      { state with
        slots
      ; total_count = state.total_count + 1
      ; expanded_ids = parent_id :: state.expanded_ids
      ; special_extents =
          shift_specials state.special_extents ~after_index:parent_index ~delta:1
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
    let slots, removed, parent_index = loop state.first_retained_index [] state.slots in
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
      ; special_extents =
          shift_specials state.special_extents ~after_index:parent_index ~delta:(-removed)
      ; anchor_decision = Preserve_visible_slot
      })
;;

let prepend_timeline_entry (state : t) entry =
  let block = entry.Journal_graph_projection.block in
  let rec insert reversed = function
    | [] -> List.rev (Top_level entry :: reversed), state.total_count
    | (Top_level candidate as slot) :: tail
      when Journal_model.journal_day candidate.block = Journal_model.journal_day block
           && compare_blocks block candidate.block <= 0 ->
      ( List.rev_append reversed (Top_level entry :: slot :: tail)
      , state.first_retained_index + List.length reversed )
    | (Day_heading page as slot) :: tail
      when Journal_model.journal_day block > page.day ->
      ( List.rev_append reversed (Top_level entry :: slot :: tail)
      , state.first_retained_index + List.length reversed )
    | ((Feed_continuation _ | Bottom_clearance) as slot) :: tail ->
      ( List.rev_append reversed (Top_level entry :: slot :: tail)
      , state.first_retained_index + List.length reversed )
    | slot :: tail -> insert (slot :: reversed) tail
  in
  let slots, inserted_index = insert [] state.slots in
  { state with
    slots
  ; total_count = state.total_count + 1
  ; special_extents =
      shift_specials state.special_extents ~after_index:(inserted_index - 1) ~delta:1
  ; anchor_decision = Reset_to_top
  }
  |> cap_retained
;;

let remove_orphan_day_headings ~today slots =
  let rec has_day_content day = function
    | [] | Day_heading _ :: _ | Feed_continuation _ :: _ | Bottom_clearance :: _ -> false
    | Top_level entry :: _ -> Journal_model.journal_day entry.block = day
    | Day_continuation continuation :: _ -> continuation.day = day
    | Child_preview _ :: tail
    | Children_loading _ :: tail
    | Children_more _ :: tail ->
      has_day_content day tail
  in
  let rec loop reversed = function
    | Day_heading page :: tail
      when page.Journal_graph_projection.day <> today
           && not (has_day_content page.day tail) ->
      loop reversed tail
    | slot :: tail -> loop (slot :: reversed) tail
    | [] -> List.rev reversed
  in
  loop [] slots
;;

let indexed_specials_from first_retained_index slots =
  indexed_specials slots
  |> List.map (fun (index, kind) -> first_retained_index + index, kind)
;;

let stage_delete (state : t) ~block_id =
  let rec find reversed = function
    | [] -> None
    | (Top_level entry as slot) :: tail
      when String.equal (Journal_model.id entry.block) block_id ->
      Some (List.rev reversed, slot, entry.block, tail)
    | Child_preview { block; _ } :: _
      when String.equal (Journal_model.id block) block_id -> None
    | slot :: tail -> find (slot :: reversed) tail
  in
  match find [] state.slots with
  | None -> None
  | Some (prefix, _, block, tail) ->
    let rec remove_owned = function
      | Child_preview preview :: rest
        when String.equal preview.parent_id block_id -> remove_owned rest
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
          | Feed_continuation _
          | Bottom_clearance -> None)
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
        ; special_extents = indexed_specials_from state.first_retained_index slots
        ; anchor_decision = Preserve_visible_slot
        ; focus_restore_block_id = None
        }
      , { block; before } )
;;

let undo_delete staged = { staged.before with pending = None }

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
  { state with visible_first = first_index; visible_last_exclusive = last_exclusive }
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
let anchor_decision (state : t) = state.anchor_decision
let focus_restore_block_id (state : t) = state.focus_restore_block_id

let is_expanded (state : t) ~block_id =
  List.exists (String.equal block_id) state.expanded_ids
;;

let extent_geometry (state : t) ~profile ~safe_bottom =
  let safe_bottom = max 0. safe_bottom in
  let final_clearance_extent =
    Journal_visual_tokens.composer_geometry.reserved_extent
    +. safe_bottom
  in
  let overrides =
    List.mapi
      (fun offset slot ->
         let index = state.first_retained_index + offset in
         match slot with
         | Top_level entry
           when is_expanded state ~block_id:(Journal_model.id entry.block) ->
           Some
             { Ui.Native_widget.Sparse_extent_list.index = index
             ; extent =
                 Journal_visual_tokens.expanded_parent_extent
                   ~profile
                   ~source:(Journal_model.source entry.block)
             }
         | Top_level _ -> None
         | Child_preview _
         | Children_loading _
         | Children_more _
         | Day_heading _
         | Day_continuation _
         | Feed_continuation _
         | Bottom_clearance ->
           let role =
             match slot with
             | Child_preview _ -> Journal_visual_tokens.Child_preview
             | Children_loading _ -> Journal_visual_tokens.Children_loading
             | Children_more _ -> Journal_visual_tokens.Children_more
             | Day_heading _ -> Journal_visual_tokens.Day_heading
             | Day_continuation _ -> Journal_visual_tokens.Day_continuation
             | Feed_continuation _ -> Journal_visual_tokens.Feed_continuation
             | Bottom_clearance -> Journal_visual_tokens.Bottom_clearance
             | Top_level _ -> assert false
           in
           Some
             { Ui.Native_widget.Sparse_extent_list.index = index
             ; extent = Journal_visual_tokens.extent_for_role ~profile ~safe_bottom role
             })
      state.slots
    |> List.filter_map Fun.id
  in
  { default_extent = profile.top_level_extent; overrides; final_clearance_extent }
;;
