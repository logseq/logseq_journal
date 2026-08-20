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

type editor =
  { session_id : ID.Text_input.session_id
  ; document_revision : ID.Text_input.document_revision
  ; accepted_local_revision : ID.Text_input.local_revision
  ; update_mode : Ui.Text_editing.update_mode
  ; value : Ui.Text_editing.Value.t
  }

type t =
  { root : Journal_model.t
  ; children : Journal_model.t list
  ; editor : editor
  ; mode : mode
  ; pending : pending option
  ; child_capture : Journal_capture.t option
  ; conflict_revision : int option
  }

let value_for_source source =
  let offset = Ui.Text_editing.Utf16.length source in
  let selection =
    Ui.Text_editing.Range.create ~text:source ~start_utf16:offset ~end_utf16:offset
  in
  Ui.Text_editing.Value.create ~text:source ~selection ()
;;

let create ~session_number (detail : Journal_graph_projection.detail) =
  { root = detail.root
  ; children = detail.children.blocks
  ; editor =
      { session_id = ID.Text_input.Session_id.of_int64 session_number
      ; document_revision = ID.Text_input.Document_revision.zero
      ; accepted_local_revision = ID.Text_input.Local_revision.zero
      ; update_mode = Ui.Text_editing.Force_replace
      ; value = value_for_source (Journal_model.source detail.root)
      }
  ; mode = Reading
  ; pending = None
  ; child_capture = None
  ; conflict_revision = None
  }
;;

let root t = t.root
let children t = t.children
let mode t = t.mode
let session_id t = t.editor.session_id
let document_revision t = t.editor.document_revision
let accepted_local_revision t = t.editor.accepted_local_revision
let update_mode t = t.editor.update_mode

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
  | Committed -> Some t.editor.value
;;

let editor_source t = Ui.Text_editing.Value.text t.editor.value
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

let value_of_edit (edit : Ui.Event.Payload.text_edit) =
  let selection =
    Ui.Text_editing.Range.create
      ~text:edit.text
      ~start_utf16:edit.selection.start_utf16
      ~end_utf16:edit.selection.end_utf16
  in
  let composing =
    Option.map
      (fun (range : Ui.Event.Payload.text_selection) ->
         Ui.Text_editing.Range.create
           ~text:edit.text
           ~start_utf16:range.start_utf16
           ~end_utf16:range.end_utf16)
      edit.composing
  in
  Ui.Text_editing.Value.create ~text:edit.text ~selection ?composing ()
;;

let apply_text_edit t (edit : Ui.Event.Payload.text_edit) =
  if
    t.mode <> Editing
    || (not (ID.Text_input.Session_id.equal t.editor.session_id edit.session_id))
    || ID.Text_input.Local_revision.compare
         edit.local_revision
         t.editor.accepted_local_revision
       <= 0
    || not
         (ID.Text_input.Document_revision.equal
            edit.base_document_revision
            t.editor.document_revision)
  then t
  else
    { t with
      editor =
        { t.editor with
          document_revision =
            ID.Text_input.Document_revision.succ t.editor.document_revision
        ; accepted_local_revision = edit.local_revision
        ; update_mode = Ui.Text_editing.Ack
        ; value = value_of_edit edit
        }
    }
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
    editor =
      { t.editor with
        document_revision =
          ID.Text_input.Document_revision.succ t.editor.document_revision
      ; update_mode = Ui.Text_editing.Force_replace
      ; value = value_for_source (Journal_model.source t.root)
      }
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

let admit_child t ~mutation_id ~block_id ~sibling_order ~creation_time =
  match t.mode, t.child_capture with
  | Adding_child, Some capture when Journal_capture.can_save capture ->
    let request =
      Journal_graph_request.Create_child
        { mutation_id
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
      { t.editor with
        document_revision =
          ID.Text_input.Document_revision.succ t.editor.document_revision
      ; update_mode = Ui.Text_editing.Ack
      ; value = value_for_source (Journal_model.source block)
      }
    | Some (Task _) | Some (Child _) | None -> t.editor
  in
  { t with root = block; editor; mode; pending = None; conflict_revision = None }
;;

let root_with_child t ~parent_revision =
  Journal_model.create
    ~id:(Journal_model.id t.root)
    ~page_id:(Journal_model.page_id t.root)
    ~journal_day:(Journal_model.journal_day t.root)
    ~parent_id:(Journal_model.parent_id t.root)
    ~sibling_order:(Journal_model.sibling_order t.root)
    ~source:(Journal_model.source t.root)
    ~task_state:(Journal_model.task_state t.root)
    ~child_count:(Journal_model.child_count t.root + 1)
    ~creation_time:(Journal_model.creation_time t.root)
    ~revision:parent_revision
    ~last_mutation_id:(Journal_model.last_mutation_id t.root)
  |> Result.value ~default:t.root
;;

let apply_child_created t ~child ~parent_revision =
  match t.pending with
  | Some (Child _) ->
    { t with
      root = root_with_child t ~parent_revision
    ; children = t.children @ [ child ]
    ; mode = Reading
    ; pending = None
    ; child_capture = None
    }
  | Some (Source _) | Some (Task _) | None -> t
;;
