module Ui = Bonsai_flutter_ui

type request =
  | Feed of { before_day : int option }
  | Day of
      { day : int
      ; after : Journal_repository.block_cursor option
      }
  | Children of
      { parent_id : string
      ; after : Journal_repository.block_cursor option
      }

type slot =
  | Day_heading of Journal_repository.page
  | Block of
      { block : Journal_model.t
      ; depth : int
      }
  | Day_continuation of
      { day : int
      ; after : Journal_repository.block_cursor option
      }
  | Children_continuation of
      { parent_id : string
      ; after : Journal_repository.block_cursor option
      }
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

let cursor_after blocks =
  match List.rev blocks with
  | [] -> None
  | block :: _ ->
    Some
      { Journal_repository.after_sibling_order = Journal_model.sibling_order block
      ; after_block_id = Journal_model.id block
      }
;;

let slot_key = function
  | Day_heading page -> "day:" ^ string_of_int page.Journal_repository.day
  | Block { block; _ } -> "block:" ^ Journal_model.id block
  | Day_continuation { day; _ } -> "day-continuation:" ^ string_of_int day
  | Children_continuation { parent_id; _ } -> "children-continuation:" ^ parent_id
  | Feed_continuation { before_day } -> "feed-continuation:" ^ string_of_int before_day
  | Bottom_clearance -> "bottom-clearance"
;;

let indexed_specials slots =
  List.mapi
    (fun index -> function
       | Day_heading _ -> Some (index, Day_extent)
       | Bottom_clearance -> Some (index, Bottom_extent)
       | Block _ | Day_continuation _ | Children_continuation _ | Feed_continuation _ ->
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

let day_slots ~today (day : Journal_repository.day_feed) =
  let blocks = sort_blocks day.blocks in
  let heading = if day.page.day = today then [] else [ Day_heading day.page ] in
  let rows = List.map (fun block -> Block { block; depth = 0 }) blocks in
  let continuation =
    if day.has_more_blocks
    then [ Day_continuation { day = day.page.day; after = cursor_after blocks } ]
    else []
  in
  heading @ rows @ continuation
;;

let feed_slots ~today (feed : Journal_repository.feed) =
  let days =
    List.sort
      (fun left right -> Int.compare right.Journal_repository.page.day left.page.day)
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

let apply_block_page (state : t) ~generation (page : Journal_repository.block_page) =
  match state.pending with
  | Some (expected_generation, Day { day; after })
    when Int64.equal expected_generation generation ->
    let blocks = sort_blocks page.blocks in
    let replacement =
      List.map (fun block -> Block { block; depth = 0 }) blocks
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
        | Block { block; depth } when String.equal (Journal_model.id block) replacement_id
          -> Block { block = replacement; depth }
        | slot -> slot)
      state.slots
  in
  { state with slots; anchor_decision = Preserve_visible_slot }
;;

let apply_detail (state : t) ~generation (detail : Journal_repository.detail) =
  match state.pending with
  | Some (expected_generation, Children { parent_id; after })
    when Int64.equal expected_generation generation
         && String.equal parent_id (Journal_model.id detail.root) ->
    let state = replace_block state detail.root in
    let blocks = sort_blocks detail.children.blocks in
    let replacement =
      List.map (fun block -> Block { block; depth = 1 }) blocks
      @
      match detail.children.continuation with
      | None -> []
      | Some continuation ->
        [ Children_continuation { parent_id; after = Some continuation } ]
    in
    let state =
      replace_slot
        state
        ~predicate:(function
          | Children_continuation candidate ->
            String.equal candidate.parent_id parent_id && candidate.after = after
          | _ -> false)
        replacement
    in
    { state with pending = None }
  | Some _ | None -> state
;;

let next_request (state : t) =
  if Option.is_some state.pending
  then None
  else (
    let rec find_children = function
      | [] -> None
      | Children_continuation { parent_id; after } :: _ ->
        Some (Children { parent_id; after })
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
            | Children_continuation { parent_id; after } ->
              Some (Children { parent_id; after })
            | Day_continuation { day; after } -> Some (Day { day; after })
            | Feed_continuation { before_day } ->
              Some (Feed { before_day = Some before_day })
            | Day_heading _ | Block _ | Bottom_clearance -> None)
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
      | (Block { block; depth = 0 } as parent) :: tail
        when String.equal (Journal_model.id block) parent_id ->
        Some
          (List.rev_append
             reversed
             (parent :: Children_continuation { parent_id; after = None } :: tail))
      | slot :: tail -> insert (slot :: reversed) tail
    in
    match insert [] state.slots with
    | None -> state
    | Some slots ->
      let parent_index =
        let rec find index = function
          | Block { block; depth = 0 } :: _
            when String.equal (Journal_model.id block) parent_id -> index
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
      }
      |> cap_retained)
;;

let collapse (state : t) ~parent_id =
  if not (List.exists (String.equal parent_id) state.expanded_ids)
  then state
  else (
    let rec loop index reversed = function
      | [] -> state.slots, 0, state.total_count
      | (Block { block; depth = 0 } as parent) :: tail
        when String.equal (Journal_model.id block) parent_id ->
        let rec remove removed = function
          | (Block { depth = 1; _ } | Children_continuation _) :: rest ->
            remove (removed + 1) rest
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

let prepend_block (state : t) block =
  let rec insert reversed = function
    | [] -> List.rev (Block { block; depth = 0 } :: reversed), state.total_count
    | (Block { block = candidate; depth = 0 } as slot) :: tail
      when Journal_model.journal_day candidate = Journal_model.journal_day block
           && compare_blocks block candidate <= 0 ->
      ( List.rev_append reversed (Block { block; depth = 0 } :: slot :: tail)
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
    | Block { block; depth = 0 } :: _ -> Journal_model.journal_day block = day
    | Day_continuation continuation :: _ -> continuation.day = day
    | Block { depth = _; _ } :: tail | Children_continuation _ :: tail ->
      has_day_content day tail
  in
  let rec loop reversed = function
    | Day_heading page :: tail
      when page.Journal_repository.day <> today && not (has_day_content page.day tail) ->
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
    | (Block { block; depth } as slot) :: tail
      when String.equal (Journal_model.id block) block_id ->
      Some (List.rev reversed, slot, block, depth, tail)
    | slot :: tail -> find (slot :: reversed) tail
  in
  match find [] state.slots with
  | None -> None
  | Some (prefix, _, block, 0, tail) ->
    let rec remove_owned = function
      | Block { depth = 1; _ } :: rest -> remove_owned rest
      | Children_continuation continuation :: rest
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
          | Block { block; _ } -> Some (Journal_model.id block)
          | Day_heading _
          | Day_continuation _
          | Children_continuation _
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
  | Some (prefix, _, block, 1, tail) ->
    (match Journal_model.parent_id block with
     | None -> None
     | Some parent_id ->
       let replacement = ref None in
       let prefix =
         List.map
           (function
             | Block { block = parent; depth = 0 }
               when String.equal (Journal_model.id parent) parent_id ->
               (match
                  Journal_model.with_child_count
                    parent
                    ~child_count:(Journal_model.child_count parent - 1)
                with
                | Ok parent ->
                  replacement := Some ();
                  Block { block = parent; depth = 0 }
                | Error _ as error ->
                  ignore error;
                  Block { block = parent; depth = 0 })
             | slot -> slot)
           prefix
       in
       (match !replacement with
        | None -> None
        | Some () ->
          let slots = prefix @ tail |> remove_orphan_day_headings ~today:state.today in
          let removed = List.length state.slots - List.length slots in
          let total_count = max 0 (state.total_count - removed) in
          let before = { state with pending = None } in
          Some
            ( { state with
                slots
              ; total_count
              ; visible_first = min state.visible_first total_count
              ; visible_last_exclusive = min state.visible_last_exclusive total_count
              ; pending = None
              ; special_extents = indexed_specials_from state.first_retained_index slots
              ; anchor_decision = Preserve_visible_slot
              ; focus_restore_block_id = None
              }
            , { block; before } )))
  | Some (_, _, _, _, _) -> None
;;

let undo_delete staged = { staged.before with pending = None }

let return_from_detail (state : t) ~block_id =
  let exists =
    List.exists
      (function
        | Block { block; _ } -> String.equal (Journal_model.id block) block_id
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
let anchor_decision (state : t) = state.anchor_decision
let focus_restore_block_id (state : t) = state.focus_restore_block_id

let is_expanded (state : t) ~block_id =
  List.exists (String.equal block_id) state.expanded_ids
;;

let extent_geometry (state : t) ~profile ~safe_bottom =
  let safe_bottom = max 0. safe_bottom in
  let final_clearance_extent =
    Journal_visual_tokens.hit_regions.fab_target
    +. Journal_visual_tokens.spacing.x6
    +. safe_bottom
  in
  let overrides =
    List.map
      (fun (index, kind) ->
         let extent =
           match kind with
           | Day_extent -> profile.Journal_visual_tokens.day_header_extent
           | Bottom_extent -> final_clearance_extent
         in
         { Ui.Native_widget.Sparse_extent_list.index; extent })
      state.special_extents
  in
  { default_extent = profile.block_extent; overrides; final_clearance_extent }
;;
