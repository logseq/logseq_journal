module ID = Bonsai_flutter_spec.Id
module Ui = Bonsai_flutter_ui

type phase =
  | Editing
  | Confirm_discard
  | Saving
  | Failed of string
  | Committed
  | Recovery_only

type editor =
  { session_id : ID.Text_input.session_id
  ; document_revision : ID.Text_input.document_revision
  ; accepted_local_revision : ID.Text_input.local_revision
  ; update_mode : Ui.Text_editing.update_mode
  ; value : Ui.Text_editing.Value.t
  }

type t =
  { editor : editor
  ; task_state : Journal_model.task_state
  ; phase : phase
  ; pending : Journal_worker.request option
  ; confirm_return_phase : phase option
  }

type dismissal =
  | Close
  | Confirm of t
  | Block

let empty_value () =
  let text = "" in
  let selection = Ui.Text_editing.Range.create ~text ~start_utf16:0 ~end_utf16:0 in
  Ui.Text_editing.Value.create ~text ~selection ()
;;

let create ~session_number =
  { editor =
      { session_id = ID.Text_input.Session_id.of_int64 session_number
      ; document_revision = ID.Text_input.Document_revision.zero
      ; accepted_local_revision = ID.Text_input.Local_revision.zero
      ; update_mode = Ui.Text_editing.Force_replace
      ; value = empty_value ()
      }
  ; task_state = Journal_model.Not_a_task
  ; phase = Editing
  ; pending = None
  ; confirm_return_phase = None
  }
;;

let session_id t = t.editor.session_id
let document_revision t = t.editor.document_revision
let accepted_local_revision t = t.editor.accepted_local_revision
let update_mode t = t.editor.update_mode
let value t = t.editor.value
let source t = Ui.Text_editing.Value.text t.editor.value
let task_state t = t.task_state
let phase t = t.phase

let dirty t =
  (not (String.equal (source t) "")) || t.task_state <> Journal_model.Not_a_task
;;

let source_is_blank source = String.equal (String.trim source) ""
let can_save t = t.phase = Editing && not (source_is_blank (source t))

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
    (not (ID.Text_input.Session_id.equal t.editor.session_id edit.session_id))
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
    ; phase = Editing
    ; confirm_return_phase = None
    }
;;

let toggle_task t =
  if t.phase <> Editing
  then t
  else (
    let task_state =
      match t.task_state with
      | Journal_model.Not_a_task -> Journal_model.Todo
      | Todo -> Done
      | Done -> Not_a_task
    in
    { t with task_state })
;;

let request_dismiss t =
  match t.phase with
  | Saving | Committed | Confirm_discard -> Block
  | Editing | Failed _ | Recovery_only ->
    if not (dirty t)
    then Close
    else Confirm { t with phase = Confirm_discard; confirm_return_phase = Some t.phase }
;;

let can_pop t =
  match request_dismiss t with
  | Close -> true
  | Confirm _ | Block -> false
;;

let keep_editing t =
  match t.phase with
  | Confirm_discard ->
    { t with
      phase = Option.value t.confirm_return_phase ~default:Editing
    ; confirm_return_phase = None
    }
  | Editing | Saving | Failed _ | Committed | Recovery_only -> t
;;

let discard t =
  { editor =
      { t.editor with
        document_revision =
          ID.Text_input.Document_revision.succ t.editor.document_revision
      ; update_mode = Ui.Text_editing.Force_replace
      ; value = empty_value ()
      }
  ; task_state = Journal_model.Not_a_task
  ; phase = Editing
  ; pending = None
  ; confirm_return_phase = None
  }
;;

let admit_save t ~mutation_id ~block_id ~sibling_order ~calendar_generation ~creation_time
  =
  if not (can_save t)
  then t, None
  else (
    let command : Journal_repository.capture =
      { mutation_id
      ; block_id
      ; sibling_order
      ; source = source t
      ; task_state = t.task_state
      ; creation_time
      }
    in
    let request = Journal_worker.Capture { calendar_generation; command } in
    ( { t with phase = Saving; pending = Some request; confirm_return_phase = None }
    , Some request ))
;;

let fail t ~message =
  match t.pending with
  | Some _ -> { t with phase = Failed message; confirm_return_phase = None }
  | None -> t
;;

let recovery_only t = { t with phase = Recovery_only; confirm_return_phase = None }

let retry t =
  match t.phase, t.pending with
  | Failed _, Some request ->
    { t with phase = Saving; confirm_return_phase = None }, Some request
  | Failed _, None
  | Editing, _
  | Confirm_discard, _
  | Saving, _
  | Committed, _
  | Recovery_only, _ -> t, None
;;

let commit t _block =
  { t with phase = Committed; pending = None; confirm_return_phase = None }
;;
