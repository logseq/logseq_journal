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
  ; pending_blocks : Journal_model.t Blocks.t option
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
  ; child_error : string option
  ; composer_revision : int64
  ; reveal_id : string option
  ; reveal_outcome : Ui.View.Native_list.outcome option
  }

type event =
  | Observe_visible_range of int64 * int64
  | Load_next
  | Load_initial_next
  | Load_more of string
  | Loaded of int64 * Journal_graph_projection.detail
  | Load_failed of int64 * bool * string
  | Append_failed of string * string

type retained_composer =
  { draft_parent : string
  ; draft_capture : Journal_capture.t
  ; draft_mode : mode
  ; draft_pending : Journal_graph_request.t option
  ; draft_projection : (Journal_model.t * Journal_model.t) option
  ; draft_error : string option
  }

let invalidate_rows (t : t) = { t with row_snapshot = ref None }

let equal_presentation (left : t) (right : t) =
  left == right
  || (left.root_id = right.root_id
      && left.blocks == right.blocks
      && left.branches == right.branches
      && left.session_number = right.session_number
      && left.mode = right.mode
      && left.child_error = right.child_error
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
    && Journal_model.page_id child = Journal_model.page_id parent
    && (Journal_model.parent_id child = Some root_id
        || (Journal_model.id parent = Journal_model.page_id parent
            && Journal_model.page_id child = root_id
            && Journal_model.parent_id child = None))
  | _ -> false
;;

let retain_composer (t : t) =
  Option.map
    (fun capture ->
       { draft_parent = t.root_id
       ; draft_capture = capture
       ; draft_mode = t.mode
       ; draft_pending = t.pending
       ; draft_projection = None
       ; draft_error = t.child_error
       })
    t.child_capture
;;


let complete_retained_composer draft ~child ~parent =
  if matching_child draft.draft_pending ~root_id:draft.draft_parent ~child ~parent
  then None
  else Some draft
;;

let lock_retained_attempt draft =
  match draft.draft_pending with
  | Some (Journal_graph_request.Create_child _) ->
    { draft with draft_capture = Journal_capture.lock_for_retry draft.draft_capture }
  | _ -> draft
;;

let fail_retained_composer draft ~block_id ~message =
  if pending_child draft.draft_pending block_id
  then { (lock_retained_attempt draft) with draft_mode = Failed message }
  else draft
;;

let interrupt_retained_composer draft =
  match draft.draft_mode with
  | Saving_child ->
    { (lock_retained_attempt draft) with
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
  ; pending_blocks = None
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
  ; child_error = None
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
let child_error (t : t) = t.child_error
let has_child_request (t:t) command = t.pending=Some(Journal_graph_request.Create_child command)
let retained_has_child_request draft command = draft.draft_pending=Some(Journal_graph_request.Create_child command)

let pending_with_child_status pending task_state =
  Option.map
    (function
      | Journal_graph_request.Create_child command when command.task_state <> task_state ->
        Journal_graph_request.Create_child
          { command with
            task_state
          ; status_confirmation = true
          ; status_intent_revision = Int64.succ command.status_intent_revision
          }
      | request -> request)
    pending
;;

let map_child_capture (t : t) ~f =
  match t.mode, t.child_capture with
  | Saving_child, _ | _, None -> t
  | (Reading | Failed _), Some capture ->
    let next = f capture in
    if next == capture
    then t
    else if Journal_capture.retry_identity_locked capture
    then
      { t with
        child_capture = Some next
      ; pending = pending_with_child_status t.pending (Journal_capture.task_state next)
      }
    else { t with child_capture = Some next; mode = Reading; pending = None;child_error=None }
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
    else if Journal_capture.retry_identity_locked draft.draft_capture
    then
      { draft with
        draft_capture = capture
      ; draft_pending =
          pending_with_child_status draft.draft_pending (Journal_capture.task_state capture)
      }
    else
      { draft with draft_capture = capture; draft_mode = Reading; draft_pending = None;
        draft_error=None;draft_projection=None })
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

let automatic_budget_available (t : t) =
  t.automatic_reads < maximum_automatic_reads
  && t.materialized_blocks + page_limit <= maximum_materialized_blocks
;;

let next_unloaded_in t current_rows first last =
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
  find first
;;

let initial_staging (t : t) =
  let current_rows = snapshot t in
  if current_rows.reading
  then `Waiting
  else if not (automatic_budget_available t)
  then `Ready
  else (
    match next_unloaded_in t current_rows 0 (Array.length current_rows.indexed) with
    | None -> `Ready
    | Some id -> `Load id)
;;

let next_automatic_load (t : t) =
  if not (automatic_budget_available t)
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
        next_unloaded_in t current_rows (bounded first) (bounded last)))
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
              ; pending_blocks = Some t.blocks
              ; error = None
              }
              t.branches
        }
    , [ request ] ))
;;

let fail_child_attempt (t : t) message =
  let lock =
    match t.pending with
    | Some (Journal_graph_request.Create_child _) -> true
    | _ -> false
  in
  { t with
    mode = Failed message
  ; child_capture =
      (if lock
       then Option.map Journal_capture.lock_for_retry t.child_capture
       else t.child_capture)
  }
;;

let step (t : t) = function
  | Observe_visible_range (first, last) ->
    let first = Int64.max 0L first in
    let range = Some (first, Int64.max first last) in
    (if range = t.visible_range then t else { t with visible_range = range }), []
  | Append_failed (block_id, message) ->
    (if pending_child t.pending block_id then fail_child_attempt t message else t), []
  | Load_next ->
    (match next_automatic_load t with
     | None -> t, []
     | Some id ->
       load ~automatic:true { t with automatic_reads = t.automatic_reads + 1 } id)
  | Load_initial_next ->
    (match initial_staging t with
     | `Waiting | `Ready -> t, []
     | `Load id ->
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
       (* The page owns membership/continuation, while point updates received
          since dispatch own their newer content. Revisions are opaque; compare
          with the immutable dispatch snapshot, never order revision strings. *)
       let preserve value =
         let id=Journal_model.id value in
         let before=Option.bind current.pending_blocks(Blocks.find_opt id) in
         match Blocks.find_opt id t.blocks with
         | Some now when before<>Some now->now
         | _->value in
       let page_root=preserve detail.root in
       let blocks=add_blocks t.blocks (page_root::List.map preserve detail.children.blocks) in
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
         ; pending_blocks = None
         ; error = None
         }
       in
       let root =
         Journal_model.with_child_count
           page_root
           ~child_count:
             (max (List.length children) (Journal_model.child_count page_root))
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
               ; pending_blocks = None
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
  if
    t.mode = Saving_child
    || Option.fold ~none:false ~some:Journal_capture.retry_identity_locked t.child_capture
  then t
  else (
    let capture =
      match t.child_capture with
      | None -> Journal_capture.create ~session_number:t.session_number ~source
      | Some capture -> Journal_capture.update_source capture ~source
    in
    { t with child_capture = Some capture; mode = Reading; pending = None;child_error=None })
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
    else { t with child_capture = Some capture; mode = Reading; pending = None;child_error=None })
;;

let set_child_task (t : t) task_state =
  if t.mode = Saving_child
  then t
  else (
    let t = if t.child_capture = None then update_child_source t "" else t in
    let child_capture =
      Option.map
        (fun capture -> Journal_capture.with_task_state capture task_state)
        t.child_capture
    in
    if Option.fold ~none:false ~some:Journal_capture.retry_identity_locked child_capture
    then (
      let pending = pending_with_child_status t.pending task_state in
      { t with child_capture; pending })
    else { t with child_capture; mode = Reading; pending = None;child_error=None })
;;

let toggle_child_task (t : t) =
  let current =
    Option.map Journal_capture.task_state t.child_capture
    |> Option.value ~default:Journal_model.No_status
  in
  set_child_task
    t
    (match current with
     | Journal_model.No_status -> Journal_model.Default_status
     | Status _ | Default_status | Invalid_status _ -> No_status)
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
  | Reading, Some capture when Journal_capture.can_save capture && Journal_capture.admission_error capture<>None ->
    {t with child_error=Journal_capture.admission_error capture},None
  | Reading, Some capture when Journal_capture.can_save capture ->
    let request =
      Journal_graph_request.Create_child
        { mutation_id
        ; calendar_generation
        ; block_id
        ; sibling_order
        ; creation_time
        ; parent_block_id = t.root_id
        ; status_intent_revision = 0L
        ; expected_parent_revision = Journal_model.revision (root t)
        ; source = Journal_capture.submission_source capture
        ; status_confirmation =
            Journal_capture.task_state capture <> Journal_model.No_status
        ; task_state = Journal_capture.task_state capture
        }
    in
    { t with mode = Saving_child; pending = Some request;child_error=None }, Some request
  | _ -> t, None
;;

let fail (t : t) ~message = if t.pending = None then t else fail_child_attempt t message

let retry (t : t) =
  match t.mode, t.pending with
  | Failed _, Some request -> { t with mode = Saving_child;child_error=None }, Some request
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
            ; pending_blocks = None
            ; error = None
            }
            t.branches
      })
;;

let cancel_initial_reads (t : t) =
  if not (Blocks.exists (fun _ (branch : branch) -> branch.pending <> None) t.branches)
  then t
  else
    invalidate_rows
      { t with
        branches =
          Blocks.map (fun (branch : branch) -> { branch with pending = None;pending_blocks=None }) t.branches
      }
;;

let account_initial_update ~(previous : t) (t : t) =
  let added =
    if previous.blocks == t.blocks
    then 0
    else
      Blocks.fold
        (fun id _ count -> if Blocks.mem id previous.blocks then count else count + 1)
        t.blocks
        0
  in
  let materialized_blocks =
    max t.materialized_blocks (previous.materialized_blocks + added)
  in
  let automatic_reads = max t.automatic_reads previous.automatic_reads in
  let t =
    if materialized_blocks = t.materialized_blocks && automatic_reads = t.automatic_reads
    then t
    else { t with materialized_blocks; automatic_reads }
  in
  (* A shared update can consume a page already reserved by another branch.
     Keep the spent attempt and expose explicit continuation instead. *)
  if t.materialized_blocks + page_limit > maximum_materialized_blocks
  then cancel_initial_reads t
  else t
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
            { appended = id :: List.filter ((<>)id) current.appended
            ; children = List.filter (( <> ) id) current.children @ [ id ]
            ; loaded =
                current.loaded && current.continuation = None && current.pending = None
            ; continuation = None
            ; pending = None
            ; pending_blocks = None
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
      ; child_error = None
      ; composer_revision = Int64.succ t.composer_revision
      ; reveal_id = Some id
      ; reveal_outcome = None
      })
  else t
;;

let preview_child_created (t:t) ~command ~child ~parent ~error =
  if not(has_child_request t command) || not(matching_child t.pending ~root_id:t.root_id ~child ~parent)
  then t
  else
    let next=apply_child_created t ~child ~parent in
    {next with mode=Saving_child;pending=t.pending;child_capture=t.child_capture;
      child_error=error;session_number=t.session_number;composer_revision=t.composer_revision;
      automatic_reads=t.automatic_reads;materialized_blocks=t.materialized_blocks;
      reveal_id=t.reveal_id;reveal_outcome=t.reveal_outcome}
;;
let preview_child_failure (t:t) ~command ~message =
  if has_child_request t command then {t with mode=Saving_child;child_error=Some message} else t
;;
let preview_retained_child draft ~command ~child ~parent ~error =
  if retained_has_child_request draft command
     && matching_child draft.draft_pending ~root_id:draft.draft_parent ~child ~parent
  then {draft with draft_projection=Some(child,parent);draft_error=error;draft_mode=Saving_child}
  else draft
;;
let preview_retained_failure draft ~command ~message =
  if retained_has_child_request draft command then
    {draft with draft_error=Some message;draft_mode=Saving_child} else draft
;;
let child_projection_applied (t:t) ~command ~child ~parent ~error =
  has_child_request t command && t.child_error=error
  && Blocks.find_opt (Journal_model.id child) t.blocks=Some child
  && Blocks.find_opt (Journal_model.id parent) t.blocks=Some parent
;;
let retained_projection_applied draft ~command ~child ~parent ~error =
  retained_has_child_request draft command && draft.draft_projection=Some(child,parent) && draft.draft_error=error
;;
let child_failure_applied (t:t) ~command ~message = has_child_request t command && t.child_error=Some message
let retained_failure_applied draft ~command ~message = retained_has_child_request draft command && draft.draft_error=Some message
let release_rejected_child (t:t) ~command ~message =
  if has_child_request t command then {t with pending=None;mode=Failed message;child_error=Some message;
    child_capture=Option.map Journal_capture.release_rejected_attempt t.child_capture} else t
;;
let release_rejected_retained draft ~command ~message =
  if retained_has_child_request draft command then {draft with draft_pending=None;draft_mode=Failed message;
    draft_error=Some message;draft_capture=Journal_capture.release_rejected_attempt draft.draft_capture} else draft
;;

let restore_composer (t : t) draft =
  if draft.draft_parent <> t.root_id
  then t
  else (
    let capture =
      Journal_capture.rebind draft.draft_capture ~session_number:t.session_number
    in
    let restored=invalidate_rows
      { t with
        child_capture = Some capture
      ; session_number =
          ID.Text_input.Session_id.to_int64 (Journal_capture.session_id capture)
      ; mode = draft.draft_mode
      ; pending = draft.draft_pending
      ; child_error = draft.draft_error
      } in
    match draft.draft_projection,draft.draft_pending with
    | Some(child,parent),Some(Journal_graph_request.Create_child command)->
      let next=preview_child_created restored ~command ~child ~parent ~error:draft.draft_error in
      {next with mode=draft.draft_mode}
    | _->restored)
;;

let remove_block (t : t) ~block_id =
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
    Some (invalidate_rows { t with blocks; branches })
;;

let reveal_outcome t = t.reveal_outcome

let complete_reveal t ~token ~outcome =
  if t.reveal_id <> None && token = t.composer_revision
  then { t with reveal_id = None; reveal_outcome = Some outcome }
  else t
;;

let child_chain (t:t) ~command =
  if has_child_request t command then Option.bind t.child_capture Journal_capture.retained_chain else None
let retained_child_chain draft ~command =
  if retained_has_child_request draft command then Journal_capture.retained_chain draft.draft_capture else None
let retain_child_chain (t:t) ~command chain =
  if not(has_child_request t command) then t else match t.child_capture with
  | None->t
  | Some capture->let next=Journal_capture.retain_child_chain capture ~command chain in
    if next==capture then t else {t with child_capture=Some next}
let retain_retained_child_chain draft ~command chain =
  if not(retained_has_child_request draft command) then draft else
  let next=Journal_capture.retain_child_chain draft.draft_capture ~command chain in
  if next==draft.draft_capture then draft else {draft with draft_capture=next}
;;

module Pure_observation = struct
  module Worker = Journal_worker_coordination.Worker_api
  module Core = Journal_worker_coordination.Worker_pure_coordinator
  module Protocol = Logseq_db_worker.Protocol
  module Entries = Map.Make (String)

  type context =
    { entry_id : string
    ; request_generation : int64
    ; root : Worker.Uuid.t
    ; owner : Logseq_db_worker_lui.Logseq_db_worker_lui_service.timeline_scope
    ; original : Protocol.request
    ; maximum_children : int
    }

  type ticket = Protocol.v2_block_lookup Worker.observed Core.ticket

  type instruction =
    | Cancel_initial of ticket
    | Forget_initial of ticket
    | Release of Protocol.v2_block_lookup Worker.observation
    | Initial of context * Protocol.v2_block_lookup Worker.observed
    | Updated of context * Protocol.v2_block_lookup Worker.observed
    | Failed of context * Worker.error
    | Rejected of context * Worker.error

  type entry =
    { context : context
    ; ticket : ticket
    ; handle : Protocol.v2_block_lookup Worker.observation option
    ; forwarded_epoch : Worker.observation_epoch option
    ; reported : bool
    ; forgotten : bool
    ; error : Worker.error option
    }

  type t = entry Entries.t

  let empty = Entries.empty
  let context_count = Entries.cardinal

  let retire entry =
    let cleanup = match entry.handle with
      | Some handle -> Rrbvec.singleton (Release handle)
      | None -> Rrbvec.singleton (Cancel_initial entry.ticket)
    in
    if entry.forgotten then cleanup
    else Rrbvec.push_back cleanup (Forget_initial entry.ticket)
  ;;

  let planned t context ticket =
    let claimed=Entries.exists(fun _ old->old.ticket=ticket && old.context<>context)t in
    if claimed then t,Rrbvec.singleton(Rejected(context,Worker.Invalid_input
      "This observation ticket already belongs to another Detail context.")) else
    match context.original.command with
    | Protocol.V2_get_outline_block { block; _ }
      when block=context.root && context.original.api_version=Protocol.api_version
        && context.request_generation>=0L && context.maximum_children>0
        && context.maximum_children<=Protocol.maximum_page_size ->
      (match Entries.find_opt context.entry_id t with
       | Some old when old.context = context && Core.ticket_id old.ticket = Core.ticket_id ticket ->
         t, Rrbvec.empty
       | previous ->
         let effects = Option.fold ~none:Rrbvec.empty ~some:retire previous in
         let entry = { context; ticket; handle=None; forwarded_epoch=None;
           reported=false; forgotten=false; error=None } in
         Entries.add context.entry_id entry t, effects)
    | _ ->
      t, Rrbvec.of_list [Cancel_initial ticket; Forget_initial ticket;
        Rejected (context, Worker.Invalid_input "Detail observation does not match its root request.")]
  ;;

  let retain t wanted =
    let wanted=Rrbvec.fold_left(fun wanted(id,generation,root)->Entries.add id(generation,root)wanted)
      Entries.empty wanted in
    let retained, effects = Entries.fold (fun id entry (retained,effects) ->
      let current=Entries.find_opt id wanted=Some(entry.context.request_generation,entry.context.root) in
      if current then retained,effects
      else Entries.remove id retained,Rrbvec.append effects (retire entry)) t (t,Rrbvec.empty) in
    retained,effects
  ;;

  let admission_error = function
    | Worker.Not_admitted Worker.Full -> Some (Worker.Service_failed "Worker request queue is full.")
    | Not_admitted Not_ready -> Some (Worker.Service_failed "Worker is not ready.")
    | Not_admitted Stopping -> Some (Worker.Service_failed "Worker is stopping.")
    | Not_admitted (Unsupported_request message) -> Some (Worker.Unsupported_operation message)
    | Answered (Error error) -> Some error
    | Interrupted _ -> Some Worker.Revoked_session
    | Answered (Ok _) -> None
  ;;

  let inspect_entry view entry =
    let handle = match entry.handle with
      | Some _ as handle -> handle
      | None -> Core.observation_handle view entry.ticket
    in
    let reply = Core.reply view entry.ticket in
    let forgotten,effects =
      if entry.forgotten || (handle=None && reply=None) then entry.forgotten,Rrbvec.empty
      else true,Rrbvec.singleton (Forget_initial entry.ticket)
    in
    let entry = {entry with handle;forgotten} in
    let result = Option.map (fun handle ->
      let session = Worker.observation_session handle in
      let Worker.Outline_block {uuid;revision}=Worker.observation_query handle in
      let query_matches=uuid=entry.context.root && entry.context.original.command=
        Protocol.V2_get_outline_block{block=uuid;revision} in
      if not query_matches then Error (Worker.Protocol_mismatch "Detail observation root changed.")
      else if Core.observation_handle view entry.ticket=None
           || not(Worker.matches_scope session entry.context.owner) then Error Worker.Revoked_session
      else Ok handle) handle in
    match result with
    | Some (Error error) ->
      None,Rrbvec.append effects
        (Rrbvec.push_back (retire entry) (Failed(entry.context,error)))
    | None | Some (Ok _) ->
      let sample = Option.bind handle (Core.observed view) in
      let error = match handle with
        | Some handle -> Core.observation_error view handle
        | None -> Option.bind reply admission_error
      in
      (match sample,error with
       | Some sample,None ->
         let newer = Option.fold ~none:true ~some:(fun previous ->
           Worker.compare_observation_epoch sample.epoch previous > 0) entry.forwarded_epoch in
         if not newer then Some entry,effects
         else
           let delivery = if entry.reported then Updated(entry.context,sample) else Initial(entry.context,sample) in
           Some {entry with forwarded_epoch=Some sample.epoch;reported=true;error=None},
             Rrbvec.push_back effects delivery
       | _,Some error when entry.error<>Some error ->
         Some {entry with reported=true;error=Some error},Rrbvec.push_back effects (Failed(entry.context,error))
       | _ -> Some entry,effects)
  ;;

  let inspect t view =
    Entries.fold (fun id entry (next,effects) ->
      let updated,produced = inspect_entry view entry in
      let next = match updated with
        | None -> Entries.remove id next
        | Some updated when updated=entry -> next
        | Some updated -> Entries.add id updated next
      in
      next,Rrbvec.append effects produced) t (t,Rrbvec.empty)
  ;;
  let handle t ~entry_id ~request_generation ~root =
    Option.bind(Entries.find_opt entry_id t)(fun entry->
      if entry.context.request_generation=request_generation && entry.context.root=root then entry.handle else None)

end
