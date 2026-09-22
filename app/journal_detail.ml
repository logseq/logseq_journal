module ID = Bonsai_swiftui_spec.Id
module Ui = Bonsai_swiftui_ui
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
  ; expanded : bool
  ; pending : (int64 * Journal_graph_projection.block_cursor option) option
  ; error : string option
  }

type t =
  { root_id : string
  ; blocks : Journal_model.t Blocks.t
  ; branches : branch Blocks.t
  ; session_number : int64
  ; next_request : int64
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

type row =
  | Block of
      { block : Journal_model.t
      ; depth : int
      ; expanded : bool
      ; leaf : bool
      }
  | More of
      { parent_id : string
      ; depth : int
      ; loading : bool
      ; error : string option
      }

type event =
  | Set_branch_expanded of string * bool
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
  ; expanded = false
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
        ; expanded = true
        }
  ; session_number
  ; next_request = Int64.mul session_number 1_000_000L
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
let expanded (t : t) ~block_id = (branch t block_id).expanded
let continuation (t : t) ~parent_id = (branch t parent_id).continuation
let request_back _ = `Close

let load (t : t) id =
  match Blocks.find_opt id t.blocks with
  | None -> t, []
  | Some _ ->
    let current = branch t id in
    if
      Option.is_some current.pending
      || (current.loaded && current.continuation = None && current.error = None)
    then t, []
    else (
      let generation = t.next_request in
      let request =
        Journal_graph_request.Load_detail
          { block_id = id
          ; after = current.continuation
          ; limit = 64
          ; request_generation = generation
          }
      in
      ( { t with
          next_request = Int64.succ generation
        ; branches =
            Blocks.add
              id
              { current with
                expanded = true
              ; pending = Some (generation, current.continuation)
              ; error = None
              }
              t.branches
        }
      , [ request ] ))
;;

let step (t : t) = function
  | Append_failed (block_id, message) ->
    (if pending_child t.pending block_id then { t with mode = Failed message } else t), []
  | Set_branch_expanded (id, expanded) ->
    if not (Blocks.mem id t.blocks)
    then t, []
    else (
      let current = branch t id in
      if current.expanded = expanded
      then t, []
      else if (not expanded) || current.loaded || current.pending <> None
      then { t with branches = Blocks.add id { current with expanded } t.branches }, []
      else load t id)
  | Load_more id -> load t id
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
       ( { t with
           blocks = Blocks.add id root blocks
         ; branches = Blocks.add id next t.branches
         }
       , [] )
     | _ -> t, [])
  | Load_failed (generation, stale_cursor, message) ->
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
    { t with branches }, []
;;

let rows (t : t) =
  let rec visit seen depth id =
    if List.mem id seen
    then []
    else (
      match Blocks.find_opt id t.blocks with
      | None -> []
      | Some block ->
        let current = branch t id in
        let leaf =
          current.loaded && current.children = [] && current.continuation = None
        in
        let row = Block { block; depth; expanded = current.expanded; leaf } in
        if not current.expanded
        then [ row ]
        else (
          let children =
            List.concat_map (visit (id :: seen) (depth + 1)) current.children
          in
          let more =
            if
              (not current.loaded)
              || current.pending <> None
              || current.error <> None
              || current.continuation <> None
            then
              [ More
                  { parent_id = id
                  ; depth = depth + 1
                  ; loading = current.pending <> None
                  ; error = current.error
                  }
              ]
            else []
          in
          row :: (children @ more)))
  in
  visit [] 0 t.root_id
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
        ; source = Journal_capture.source capture
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
  if Blocks.mem id t.blocks then { t with blocks = Blocks.add id block t.blocks } else t
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
    { t with
      blocks = add_blocks t.blocks [ child; parent ]
    ; branches =
        Blocks.add
          t.root_id
          { expanded = true
          ; appended = id :: current.appended
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
      ( { t with blocks; branches }
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
  { t with blocks; branches }
;;

let reveal_outcome t = t.reveal_outcome

let complete_reveal t ~token ~outcome =
  if t.reveal_id <> None && token = t.composer_revision
  then { t with reveal_id = None; reveal_outcome = Some outcome }
  else t
;;
