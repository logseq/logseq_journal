module ID = Bonsai_flutter_spec.Id
module Ui = Bonsai_flutter_ui

type mode =
  | Reading
  | Editing
  | Confirm_discard
  | Saving
  | Conflict
  | Failed of string
  | Adding_child
  | Saving_child
  | Committed

type pending =
  | Source of Journal_graph_request.t
  | Task of Journal_graph_request.t
  | Child of Journal_graph_request.t

type t =
  { root : Journal_model.t
  ; children : Journal_model.t list
  ; editor : Journal_capture.Editor.t
  ; mode : mode
  ; pending : pending option
  ; child_capture : Journal_capture.t option
  ; conflict_revision : string option
  }

let create ~session_number (detail : Journal_graph_projection.detail) =
  { root = detail.root
  ; children = detail.children.blocks
  ; editor =
      Journal_capture.Editor.create
        ~session_number
        ~source:(Journal_model.source detail.root)
  ; mode = Reading
  ; pending = None
  ; child_capture = None
  ; conflict_revision = None
  }
;;

let root t = t.root
let children t = t.children
let mode t = t.mode
let session_id t = Journal_capture.Editor.session_id t.editor
let document_revision t = Journal_capture.Editor.document_revision t.editor
let accepted_local_revision t = Journal_capture.Editor.accepted_local_revision t.editor
let update_mode t = Journal_capture.Editor.update_mode t.editor

let editor_value t =
  match t.mode with
  | Reading -> None
  | Editing
  | Confirm_discard
  | Saving
  | Conflict
  | Failed _
  | Adding_child
  | Saving_child
  | Committed -> Some (Journal_capture.Editor.value t.editor)
;;

let editor_source t = Ui.Text_editing.Value.text (Journal_capture.Editor.value t.editor)
let dirty t = not (String.equal (editor_source t) (Journal_model.source t.root))

let can_save t =
  (t.mode = Editing || t.mode = Conflict)
  && dirty t
  && not (String.equal (String.trim (editor_source t)) "")
;;

let begin_edit t =
  match t.mode with
  | Reading | Committed -> { t with mode = Editing }
  | Editing | Confirm_discard | Saving | Conflict | Failed _ | Adding_child | Saving_child
    -> t
;;

let apply_text_edit t edit =
  if t.mode <> Editing
  then t
  else (
    match Journal_capture.Editor.apply_text_edit t.editor edit with
    | None -> t
    | Some editor -> { t with editor })
;;

let request_back t =
  match t.mode with
  | Reading | Committed -> `Close
  | (Editing | Failed _) when dirty t -> `State { t with mode = Confirm_discard }
  | Editing | Failed _ -> `Close
  | Confirm_discard | Saving | Conflict | Adding_child | Saving_child -> `State t
;;

let keep_editing t =
  match t.mode with
  | Confirm_discard -> { t with mode = Editing }
  | Reading
  | Editing
  | Saving
  | Conflict
  | Failed _
  | Adding_child
  | Saving_child
  | Committed -> t
;;

let discard_edit t =
  { t with
    editor = Journal_capture.Editor.replace t.editor ~source:(Journal_model.source t.root)
  ; mode = Reading
  ; pending = None
  ; conflict_revision = None
  }
;;

let update_request t ~mutation_id ~expected_revision =
  Journal_graph_request.Update_source
    { mutation_id
    ; block_id = Journal_model.id t.root
    ; expected_revision
    ; source = editor_source t
    }
;;

let admit_save t ~mutation_id =
  if not (can_save t)
  then t, None
  else (
    let expected_revision =
      Option.value t.conflict_revision ~default:(Journal_model.revision t.root)
    in
    let request = update_request t ~mutation_id ~expected_revision in
    { t with mode = Saving; pending = Some (Source request) }, Some request)
;;

let apply_conflict t latest =
  match t.pending with
  | Some (Source _) ->
    { t with
      root = latest
    ; mode = Conflict
    ; pending = None
    ; conflict_revision = Some (Journal_model.revision latest)
    }
  | Some (Task _) | Some (Child _) | None -> t
;;

let fail t ~message =
  match t.pending with
  | Some _ -> { t with mode = Failed message }
  | None -> t
;;

let retry t ~mutation_id =
  match t.mode with
  | Conflict ->
    let expected_revision =
      Option.value t.conflict_revision ~default:(Journal_model.revision t.root)
    in
    let request = update_request t ~mutation_id ~expected_revision in
    { t with mode = Saving; pending = Some (Source request) }, Some request
  | Failed _ ->
    (match t.pending with
     | Some (Source request) -> { t with mode = Saving }, Some request
     | Some (Task request) -> { t with mode = Saving }, Some request
     | Some (Child request) -> { t with mode = Saving_child }, Some request
     | None -> t, None)
  | Reading | Editing | Confirm_discard | Saving | Adding_child | Saving_child | Committed
    -> t, None
;;

let admit_task_toggle t ~mutation_id =
  if Option.is_some t.pending
  then t, None
  else (
    let task_state =
      match Journal_model.task_state t.root with
      | Journal_model.No_status -> Journal_model.Todo
      | Done | Canceled -> Todo
      | Todo | Doing | In_review | Now | Backlog | Waiting | Later -> Done
    in
    let request =
      Journal_graph_request.Set_task_state
        { mutation_id
        ; block_id = Journal_model.id t.root
        ; expected_revision = Journal_model.revision t.root
        ; task_state
        }
    in
    { t with mode = Saving; pending = Some (Task request) }, Some request)
;;

let begin_child t ~session_number =
  if Option.is_some t.pending
  then t
  else
    { t with
      mode = Adding_child
    ; child_capture = Some (Journal_capture.create ~session_number ~source:"")
    }
;;

let child_capture t = t.child_capture

let apply_child_text_edit t edit =
  match t.child_capture with
  | None -> t
  | Some capture ->
    { t with child_capture = Some (Journal_capture.apply_text_edit capture edit) }
;;

let admit_child
      t
      ~mutation_id
      ~calendar_generation
      ~block_id
      ~sibling_order
      ~creation_time
  =
  match t.mode, t.child_capture with
  | Adding_child, Some capture when Journal_capture.can_save capture ->
    let request =
      Journal_graph_request.Create_child
        { mutation_id
        ; calendar_generation
        ; block_id
        ; parent_block_id = Journal_model.id t.root
        ; expected_parent_revision = Journal_model.revision t.root
        ; sibling_order
        ; source = Journal_capture.source capture
        ; task_state = Journal_capture.task_state capture
        ; creation_time
        }
    in
    { t with mode = Saving_child; pending = Some (Child request) }, Some request
  | Reading, _
  | Editing, _
  | Confirm_discard, _
  | Saving, _
  | Conflict, _
  | Failed _, _
  | Adding_child, _
  | Saving_child, _
  | Committed, _ -> t, None
;;

let apply_block t block =
  let mode =
    match t.pending with
    | Some (Task _) -> Reading
    | Some (Source _) -> Committed
    | Some (Child _) | None -> t.mode
  in
  let editor =
    match t.pending with
    | Some (Source _) ->
      Journal_capture.Editor.replace t.editor ~source:(Journal_model.source block)
    | Some (Task _) | Some (Child _) | None -> t.editor
  in
  { t with root = block; editor; mode; pending = None; conflict_revision = None }
;;

let reconcile_children t (detail : Journal_graph_projection.detail) =
  if String.equal (Journal_model.id t.root) (Journal_model.id detail.root)
  then { t with children = detail.children.blocks }
  else t
;;

let apply_child_created t ~child ~parent =
  match t.pending with
  | Some (Child _) ->
    { t with
      root = parent
    ; children = t.children @ [ child ]
    ; mode = Reading
    ; pending = None
    ; child_capture = None
    }
  | Some (Source _) | Some (Task _) | None -> t
;;
