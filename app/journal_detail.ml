module ID = Journal_ids
module Ui = Journal_view
module Blocks = Map.Make (String)

type mode =
  | Reading
  | Saving_child
  | Failed of string

type branch =
  { children : string list
  ; appended : string list
  ; continuation : Journal_graph_projection.block_cursor option
  ; loaded : bool
  ; pending : (int64 * Journal_graph_projection.block_cursor option) option
  ; error : string option
  }

type row =
  | Block of
      { block : Journal_model.t
      ; depth : int
      }
  | More of
      { parent_id : string
      ; depth : int
      ; loading : bool
      ; enabled : bool
      ; error : string option
      }

type row_snapshot =
  { snapshot_blocks : Journal_model.t Blocks.t
  ; snapshot_branches : branch Blocks.t
  ; snapshot_session : int64
  ; values : row list
  ; indexed : row array
  ; reading : bool
  }

type t =
  { root_id : string
  ; blocks : Journal_model.t Blocks.t
  ; branches : branch Blocks.t
  ; session_number : int64
  ; next_request : int64
  ; automatic_reads : int
  ; materialized_blocks : int
  ; visible_range : (int64 * int64) option
  ; row_snapshot : row_snapshot option ref
  ; mode : mode
  ; pending : Journal_graph_request.t option
  ; child_capture : Journal_capture.t option
  ; composer_revision : int64
  ; reveal_id : string option
  ; reveal_outcome : Ui.View.Native_list.outcome option
  }

type staged_delete =
  { root_id : string
  ; blocks : Journal_model.t Blocks.t
  ; branches : branch Blocks.t
  ; parent_id : string option
  ; was_appended : bool
  }

type event =
  | Observe_visible_range of int64 * int64
  | Load_next
  | Load_more of string
  | Loaded of int64 * Journal_graph_projection.detail
  | Load_failed of int64 * bool * string
  | Append_failed of string * string

type retained_composer =
  { draft_parent : string
  ; draft_capture : Journal_capture.t
  ; draft_mode : mode
  ; draft_pending : Journal_graph_request.t option
  }

let invalidate_rows (t : t) = { t with row_snapshot = ref None }

let equal_presentation (left : t) (right : t) =
  left == right
  || (left.root_id = right.root_id
      && left.blocks == right.blocks
      && left.branches == right.branches
      && left.session_number = right.session_number
      && left.mode = right.mode
      && left.composer_revision = right.composer_revision
      && left.reveal_id = right.reveal_id)
;;

let pending_child pending block_id =
  match pending with
  | Some (Journal_graph_request.Create_child command) -> command.block_id = block_id
  | _ -> false
;;

let matching_child pending ~root_id ~child ~parent =
  match pending with
  | Some (Journal_graph_request.Create_child command) ->
    command.block_id = Journal_model.id child
    && command.parent_block_id = Journal_model.id parent
    && command.parent_block_id = root_id
    && Journal_model.parent_id child = Some root_id
  | _ -> false
;;

let retain_composer (t : t) =
  Option.map
    (fun capture ->
       { draft_parent = t.root_id
       ; draft_capture = capture
       ; draft_mode = t.mode
       ; draft_pending = t.pending
       })
    t.child_capture
;;

let restore_composer (t : t) draft =
  if draft.draft_parent <> t.root_id
  then t
  else (
    let capture =
      Journal_capture.rebind draft.draft_capture ~session_number:t.session_number
    in
    invalidate_rows
      { t with
        child_capture = Some capture
      ; session_number =
          ID.Text_input.Session_id.to_int64 (Journal_capture.session_id capture)
      ; mode = draft.draft_mode
      ; pending = draft.draft_pending
      })
;;

let complete_retained_composer draft ~child ~parent =
  if matching_child draft.draft_pending ~root_id:draft.draft_parent ~child ~parent
  then None
  else Some draft
;;

let fail_retained_composer draft ~block_id ~message =
  if pending_child draft.draft_pending block_id
  then { draft with draft_mode = Failed message }
  else draft
;;

let interrupt_retained_composer draft =
  match draft.draft_mode with
  | Saving_child ->
    { draft with
      draft_mode = Failed "Save was interrupted. Retry to confirm the original attempt."
    }
  | Reading | Failed _ -> draft
;;

let empty_branch =
  { children = []
  ; appended = []
  ; continuation = None
  ; loaded = false
  ; pending = None
  ; error = None
  }
;;

let branch (t : t) id = Option.value (Blocks.find_opt id t.branches) ~default:empty_branch

let add_blocks blocks values =
  List.fold_left
    (fun blocks value -> Blocks.add (Journal_model.id value) value blocks)
    blocks
    values
;;

let create ~session_number (detail : Journal_graph_projection.detail) =
  let root_id = Journal_model.id detail.root in
  { root_id
  ; blocks = add_blocks Blocks.empty (detail.root :: detail.children.blocks)
  ; branches =
      Blocks.singleton
        root_id
        { empty_branch with
          children = List.map Journal_model.id detail.children.blocks
        ; continuation = detail.children.continuation
        ; loaded = true
        }
  ; session_number
  ; next_request = Int64.mul session_number 1_000_000L
  ; automatic_reads = 0
  ; materialized_blocks = 1 + List.length detail.children.blocks
  ; visible_range = None
  ; row_snapshot = ref None
  ; mode = Reading
  ; pending = None
  ; child_capture = None
  ; composer_revision = 0L
  ; reveal_id = None
  ; reveal_outcome = None
  }
;;

let root (t : t) = Blocks.find t.root_id t.blocks
let find_block (t : t) ~block_id = Blocks.find_opt block_id t.blocks

let children_of (t : t) ~parent_id =
  List.filter_map (fun id -> Blocks.find_opt id t.blocks) (branch t parent_id).children
;;

let children (t : t) = children_of t ~parent_id:t.root_id
let mode (t : t) = t.mode
let session_id (t : t) = ID.Text_input.Session_id.of_int64 t.session_number
let composer_revision (t : t) = t.composer_revision
let reveal_id (t : t) = t.reveal_id
let child_capture (t : t) = t.child_capture

let map_child_capture (t : t) ~f =
  match t.mode, t.child_capture with
  | Saving_child, _ | _, None -> t
  | (Reading | Failed _), Some capture ->
    let next = f capture in
    if next == capture
    then t
    else { t with child_capture = Some next; mode = Reading; pending = None }
;;

let matching_attachment_imports pending capture ~root_id ~child ~parent =
  if matching_child pending ~root_id ~child ~parent
  then
    Option.bind capture (fun capture ->
      match Journal_capture.pending_attachments capture with
      | [] -> None
      | items -> Some (Journal_model.id child, items))
  else None
;;

let child_attachment_imports (t : t) ~child ~parent =
  matching_attachment_imports t.pending t.child_capture ~root_id:t.root_id ~child ~parent
;;

let retained_attachment_imports draft ~child ~parent =
  matching_attachment_imports
    draft.draft_pending
    (Some draft.draft_capture)
    ~root_id:draft.draft_parent
    ~child
    ~parent
;;

let retained_attachments draft = Journal_capture.pending_attachments draft.draft_capture
let retained_capture draft = draft.draft_capture
let retained_saving draft = draft.draft_mode = Saving_child

let map_retained_capture draft ~f =
  if retained_saving draft
  then draft
  else (
    let capture = f draft.draft_capture in
    if capture == draft.draft_capture
    then draft
    else
      { draft with draft_capture = capture; draft_mode = Reading; draft_pending = None })
;;

let continuation (t : t) ~parent_id = (branch t parent_id).continuation
let request_back _ = `Close

(* Root is level one; typography independently caps at three levels. *)
let maximum_depth = 9
let maximum_automatic_reads = 128
let page_limit = 128
let maximum_materialized_blocks = 384

(* Zero descendant count is unknown until a branch returns its own page. *)
let needs_children current = not current.loaded

(* The snapshot belongs to this outline owner. Structural transitions allocate
   a fresh cell; draft/range/budget changes share the existing pure snapshot. *)
let snapshot (t : t) =
  match !(t.row_snapshot) with
  | Some cached
    when cached.snapshot_blocks == t.blocks
         && cached.snapshot_branches == t.branches
         && cached.snapshot_session = t.session_number -> cached
  | _ ->
    let reading =
      Blocks.exists (fun _ (branch : branch) -> branch.pending <> None) t.branches
    in
    let rec visit ancestors depth id rows =
      if depth > maximum_depth || List.mem id ancestors
      then rows
      else (
        match Blocks.find_opt id t.blocks with
        | None -> rows
        | Some block ->
          let current = branch t id in
          let rows = Block { block; depth } :: rows in
          if depth = maximum_depth
          then rows
          else (
            let rows =
              List.fold_left
                (fun rows child -> visit (id :: ancestors) (depth + 1) child rows)
                rows
                current.children
            in
            if
              needs_children current
              || current.error <> None
              || current.continuation <> None
            then
              More
                { parent_id = id
                ; depth = depth + 1
                ; loading = current.pending <> None
                ; enabled = not reading
                ; error = current.error
                }
              :: rows
            else rows))
    in
    let values = List.rev (visit [] 0 t.root_id []) in
    let cached =
      { snapshot_blocks = t.blocks
      ; snapshot_branches = t.branches
      ; snapshot_session = t.session_number
      ; values
      ; indexed = Array.of_list values
      ; reading
      }
    in
    t.row_snapshot := Some cached;
    cached
;;

let rows (t : t) = (snapshot t).values
let read_pending (t : t) = (snapshot t).reading

let next_automatic_load (t : t) =
  if
    t.automatic_reads >= maximum_automatic_reads
    || t.materialized_blocks + page_limit > maximum_materialized_blocks
  then None
  else (
    match t.visible_range with
    | None -> None
    | Some (first, last) ->
      let current_rows = snapshot t in
      if current_rows.reading
      then None
      else (
        let bounded index =
          Int64.to_int
            (Int64.min (Int64.of_int (Array.length current_rows.indexed)) index)
        in
        let last = bounded last in
        let rec find index =
          if index >= last
          then None
          else (
            let id, depth =
              match current_rows.indexed.(index) with
              | Block { block; depth } -> Journal_model.id block, depth
              | More { parent_id; depth; _ } -> parent_id, depth - 1
            in
            let current = branch t id in
            if depth < maximum_depth && needs_children current && current.error = None
            then Some id
            else find (index + 1))
        in
        find (bounded first)))
;;

let load ?(automatic = false) (t : t) id =
  if
    read_pending t
    || ((not automatic)
        && not
             (List.exists
                (function
                  | More { parent_id; _ } -> parent_id = id
                  | Block _ -> false)
                (rows t)))
  then t, []
  else (
    let current = branch t id in
    let generation = t.next_request in
    let request =
      Journal_graph_request.Load_detail
        { block_id = id
        ; after = current.continuation
        ; limit = page_limit
        ; request_generation = generation
        }
    in
    ( invalidate_rows
        { t with
          next_request = Int64.succ generation
        ; branches =
            Blocks.add
              id
              { current with
                pending = Some (generation, current.continuation)
              ; error = None
              }
              t.branches
        }
    , [ request ] ))
;;

let step (t : t) = function
  | Observe_visible_range (first, last) ->
    let first = Int64.max 0L first in
    let range = Some (first, Int64.max first last) in
    (if range = t.visible_range then t else { t with visible_range = range }), []
  | Append_failed (block_id, message) ->
    (if pending_child t.pending block_id then { t with mode = Failed message } else t), []
  | Load_next ->
    (match next_automatic_load t with
     | None -> t, []
     | Some id ->
       load ~automatic:true { t with automatic_reads = t.automatic_reads + 1 } id)
  | Load_more id ->
    let next, requests = load t id in
    ( (if requests = []
       then next
       else { next with automatic_reads = 0; materialized_blocks = 0 })
    , requests )
  | Loaded (generation, detail) ->
    let id = Journal_model.id detail.Journal_graph_projection.root in
    let current = branch t id in
    (match current.pending with
     | Some (expected, after) when generation = expected ->
       let blocks = add_blocks t.blocks (detail.root :: detail.children.blocks) in
       let previous = if after = None then current.appended else current.children in
       let children =
         List.fold_left
           (fun ids block ->
              let id = Journal_model.id block in
              if List.mem id ids then ids else id :: ids)
           previous
           detail.children.blocks
         |> List.sort_uniq (fun a b ->
           match Blocks.find_opt a blocks, Blocks.find_opt b blocks with
           | Some a_block, Some b_block ->
             let order =
               String.compare
                 (Journal_model.sibling_order a_block)
                 (Journal_model.sibling_order b_block)
             in
             if order = 0 then String.compare a b else order
           | _ -> String.compare a b)
       in
       let next =
         { current with
           children
         ; continuation = detail.children.continuation
         ; loaded = true
         ; pending = None
         ; error = None
         }
       in
       let root =
         Journal_model.with_child_count
           detail.root
           ~child_count:
             (max (List.length children) (Journal_model.child_count detail.root))
         |> Result.get_ok
       in
       ( invalidate_rows
           { t with
             materialized_blocks =
               t.materialized_blocks + List.length detail.children.blocks
           ; blocks = Blocks.add id root blocks
           ; branches = Blocks.add id next t.branches
           }
       , [] )
     | _ -> t, [])
  | Load_failed (generation, stale_cursor, message) ->
    let matches =
      Blocks.exists
        (fun _ (current : branch) ->
           match current.pending with
           | Some (expected, _) -> expected = generation
           | None -> false)
        t.branches
    in
    if not matches
    then t, []
    else (
      let branches =
        Blocks.map
          (fun (current : branch) ->
             match current.pending with
             | Some (expected, _) when generation = expected ->
               { current with
                 pending = None
               ; error = Some message
               ; continuation = (if stale_cursor then None else current.continuation)
               ; loaded = current.loaded && not stale_cursor
               }
             | _ -> current)
          t.branches
      in
      invalidate_rows { t with branches }, [])
;;

let row_key = function
  | Block { block; _ } -> "block:" ^ Journal_model.id block
  | More { parent_id; _ } -> "more:" ^ parent_id
;;

let update_child_source (t : t) source =
  if t.mode = Saving_child
  then t
  else (
    let capture =
      match t.child_capture with
      | None -> Journal_capture.create ~session_number:t.session_number ~source
      | Some capture -> Journal_capture.update_source capture ~source
    in
    { t with child_capture = Some capture; mode = Reading; pending = None })
;;

let apply_child_edit t edit =
  if t.mode = Saving_child
  then t
  else (
    let initial =
      Option.value
        t.child_capture
        ~default:(Journal_capture.create ~session_number:t.session_number ~source:"")
    in
    let capture = Journal_capture.apply_text_edit initial edit in
    if capture = initial
    then t
    else { t with child_capture = Some capture; mode = Reading; pending = None })
;;

let toggle_child_task (t : t) =
  if t.mode = Saving_child
  then t
  else (
    let t = if t.child_capture = None then update_child_source t "" else t in
    { t with
      child_capture = Option.map Journal_capture.toggle_task_intent t.child_capture
    ; mode = Reading
    ; pending = None
    })
;;

let admit_child
      (t : t)
      ~mutation_id
      ~calendar_generation
      ~block_id
      ~sibling_order
      ~creation_time
  =
  match t.mode, t.child_capture with
  | Reading, Some capture when Journal_capture.can_save capture ->
    let request =
      Journal_graph_request.Create_child
        { mutation_id
        ; calendar_generation
        ; block_id
        ; sibling_order
        ; creation_time
        ; parent_block_id = t.root_id
        ; expected_parent_revision = Journal_model.revision (root t)
        ; source = Journal_capture.submission_source capture
        ; task_state = Journal_capture.task_state capture
        }
    in
    { t with mode = Saving_child; pending = Some request }, Some request
  | _ -> t, None
;;

let fail (t : t) ~message =
  if t.pending = None then t else { t with mode = Failed message }
;;

let retry (t : t) =
  match t.mode, t.pending with
  | Failed _, Some request -> { t with mode = Saving_child }, Some request
  | _ -> t, None
;;

let apply_block (t : t) block =
  let id = Journal_model.id block in
  if Blocks.mem id t.blocks
  then invalidate_rows { t with blocks = Blocks.add id block t.blocks }
  else t
;;

let reconcile_children (t : t) (detail : Journal_graph_projection.detail) =
  let id = Journal_model.id detail.root in
  if not (Blocks.mem id t.blocks)
  then t
  else (
    let current = branch t id in
    (* Replace the authoritative prefix while retaining later loaded siblings. *)
    let ids = List.map Journal_model.id detail.children.blocks in
    let last = List.rev detail.children.blocks |> fun blocks -> List.nth_opt blocks 0 in
    let children =
      if detail.children.continuation = None
      then ids
      else
        ids
        @ List.filter
            (fun id ->
               (not (List.mem id ids))
               &&
               match last, Blocks.find_opt id t.blocks with
               | Some last, Some block ->
                 let order =
                   String.compare
                     (Journal_model.sibling_order block)
                     (Journal_model.sibling_order last)
                 in
                 order > 0 || (order = 0 && String.compare id (Journal_model.id last) > 0)
               | None, _ -> true
               | _ -> false)
            current.children
    in
    invalidate_rows
      { t with
        blocks = add_blocks t.blocks (detail.root :: detail.children.blocks)
      ; branches =
          Blocks.add
            id
            { current with
              children
            ; loaded = true
            ; continuation = detail.children.continuation
            ; pending = None
            ; error = None
            }
            t.branches
      })
;;

let apply_child_created (t : t) ~child ~parent =
  if matching_child t.pending ~root_id:t.root_id ~child ~parent
  then (
    let current = branch t t.root_id in
    let id = Journal_model.id child in
    invalidate_rows
      { t with
        blocks = add_blocks t.blocks [ child; parent ]
      ; branches =
          Blocks.add
            t.root_id
            { appended = id :: current.appended
            ; children = List.filter (( <> ) id) current.children @ [ id ]
            ; loaded =
                current.loaded && current.continuation = None && current.pending = None
            ; continuation = None
            ; pending = None
            ; error = None
            }
            t.branches
      ; mode = Reading
      ; pending = None
      ; automatic_reads = 0
      ; materialized_blocks = 0
      ; session_number =
          Int64.succ
            (Option.fold
               ~none:t.session_number
               ~some:(fun capture ->
                 ID.Text_input.Session_id.to_int64 (Journal_capture.session_id capture))
               t.child_capture)
      ; child_capture = None
      ; composer_revision = Int64.succ t.composer_revision
      ; reveal_id = Some id
      ; reveal_outcome = None
      })
  else t
;;

let stage_delete (t : t) ~block_id =
  match Blocks.find_opt block_id t.blocks with
  | None -> None
  | Some block ->
    let rec descendant seen id =
      if id = block_id
      then true
      else if List.mem id seen
      then false
      else (
        match Blocks.find_opt id t.blocks with
        | Some value ->
          Option.fold
            ~none:false
            ~some:(descendant (id :: seen))
            (Journal_model.parent_id value)
        | None -> false)
    in
    let removed = Blocks.filter (fun id _ -> descendant [] id) t.blocks in
    let removed_branches = Blocks.filter (fun id _ -> Blocks.mem id removed) t.branches in
    let branches =
      Blocks.filter_map
        (fun id (branch : branch) ->
           if Blocks.mem id removed
           then None
           else
             Some
               { branch with
                 children =
                   List.filter (fun id -> not (Blocks.mem id removed)) branch.children
               ; appended =
                   List.filter (fun id -> not (Blocks.mem id removed)) branch.appended
               })
        t.branches
    in
    let blocks = Blocks.filter (fun id _ -> not (Blocks.mem id removed)) t.blocks in
    let blocks =
      match Journal_model.parent_id block with
      | Some id ->
        Blocks.update
          id
          (Option.map (fun parent ->
             Journal_model.with_child_count
               parent
               ~child_count:(max 0 (Journal_model.child_count parent - 1))
             |> Result.get_ok))
          blocks
      | None -> blocks
    in
    Some
      ( invalidate_rows { t with blocks; branches }
      , { root_id = block_id
        ; blocks = removed
        ; branches = removed_branches
        ; parent_id = Journal_model.parent_id block
        ; was_appended =
            Option.fold
              ~none:false
              ~some:(fun parent -> List.mem block_id (branch t parent).appended)
              (Journal_model.parent_id block)
        } )
;;

let undo_delete (t : t) (staged : staged_delete) =
  let blocks = Blocks.union (fun _ current _ -> Some current) t.blocks staged.blocks in
  let branches =
    Blocks.union (fun _ current _ -> Some current) t.branches staged.branches
  in
  let branches, blocks =
    match staged.parent_id with
    | None -> branches, blocks
    | Some id ->
      let current = Option.value (Blocks.find_opt id branches) ~default:empty_branch in
      if List.mem staged.root_id current.children
      then branches, blocks
      else (
        let children =
          staged.root_id :: current.children
          |> List.sort (fun a b ->
            match Blocks.find_opt a blocks, Blocks.find_opt b blocks with
            | Some a, Some b ->
              String.compare
                (Journal_model.sibling_order a)
                (Journal_model.sibling_order b)
            | _ -> String.compare a b)
        in
        ( Blocks.add
            id
            { current with
              children
            ; appended =
                (if staged.was_appended
                 then staged.root_id :: current.appended
                 else current.appended)
            }
            branches
        , Blocks.update
            id
            (Option.map (fun parent ->
               Journal_model.with_child_count
                 parent
                 ~child_count:(Journal_model.child_count parent + 1)
               |> Result.get_ok))
            blocks ))
  in
  invalidate_rows { t with blocks; branches }
;;

let reveal_outcome t = t.reveal_outcome

let complete_reveal t ~token ~outcome =
  if t.reveal_id <> None && token = t.composer_revision
  then { t with reveal_id = None; reveal_outcome = Some outcome }
  else t
;;
