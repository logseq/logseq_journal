module ID = Bonsai_flutter_spec.Id
module Ui = Bonsai_flutter_ui

type phase =
  | Editing
  | Saving
  | Failed of string

module Editor = struct
  type t =
    { session_id : ID.Text_input.session_id
    ; document_revision : ID.Text_input.document_revision
    ; accepted_local_revision : ID.Text_input.local_revision
    ; update_mode : Ui.Text_editing.update_mode
    ; value : Ui.Text_editing.Value.t
    }

  let value_for_source source =
    let offset = Ui.Text_editing.Utf16.length source in
    let selection =
      Ui.Text_editing.Range.create ~text:source ~start_utf16:offset ~end_utf16:offset
    in
    Ui.Text_editing.Value.create ~text:source ~selection ()
  ;;

  let create ~session_number ~source =
    { session_id = ID.Text_input.Session_id.of_int64 session_number
    ; document_revision = ID.Text_input.Document_revision.zero
    ; accepted_local_revision = ID.Text_input.Local_revision.zero
    ; update_mode = Ui.Text_editing.Force_replace
    ; value = value_for_source source
    }
  ;;

  let session_id t = t.session_id
  let document_revision t = t.document_revision
  let accepted_local_revision t = t.accepted_local_revision
  let update_mode t = t.update_mode
  let value t = t.value
  let source t = Ui.Text_editing.Value.text t.value

  let replace t ~source =
    create
      ~session_number:
        (ID.Text_input.Session_id.to_int64 (ID.Text_input.Session_id.succ t.session_id))
      ~source
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

  let apply_text_edit editor (edit : Ui.Event.Payload.text_edit) =
    if
      (not (ID.Text_input.Session_id.equal editor.session_id edit.session_id))
      || ID.Text_input.Local_revision.compare
           edit.local_revision
           editor.accepted_local_revision
         <= 0
      || ID.Text_input.Document_revision.compare
           edit.base_document_revision
           editor.document_revision
         > 0
    then None
    else
      Some
        { editor with
          document_revision =
            ID.Text_input.Document_revision.succ editor.document_revision
        ; accepted_local_revision = edit.local_revision
        ; update_mode = Ui.Text_editing.Ack
        ; value = value_of_edit edit
        }
  ;;
end

type t =
  { editor : Editor.t
  ; task_state : Journal_model.task_state
  ; phase : phase
  ; pending : Journal_graph_request.t option
  }

let create ~session_number ~source =
  { editor = Editor.create ~session_number ~source
  ; task_state = Journal_model.No_status
  ; phase = Editing
  ; pending = None
  }
;;

let session_id t = Editor.session_id t.editor
let document_revision t = Editor.document_revision t.editor
let accepted_local_revision t = Editor.accepted_local_revision t.editor
let update_mode t = Editor.update_mode t.editor
let value t = Editor.value t.editor
let source t = Ui.Text_editing.Value.text (Editor.value t.editor)
let task_state t = t.task_state
let phase t = t.phase
let source_is_blank source = String.equal (String.trim source) ""
let can_save t = t.phase = Editing && not (source_is_blank (source t))

let replace_attempt t =
  match t.phase with
  | Failed _ -> { t with phase = Editing; pending = None }
  | Editing | Saving -> t
;;

let update_source t ~source:new_source =
  if t.phase = Saving || String.equal (source t) new_source
  then t
  else (
    let t = replace_attempt t in
    { t with editor = Editor.replace t.editor ~source:new_source })
;;

let toggle_task_intent t =
  match t.phase with
  | Saving -> t
  | Editing | Failed _ ->
    let t = replace_attempt t in
    let task_state =
      match t.task_state with
      | Journal_model.No_status -> Journal_model.Todo
      | Todo -> No_status
      | Doing | In_review | Now | Done | Canceled | Backlog | Waiting | Later ->
        invalid_arg "Capture task intent must be No_status or Todo"
    in
    { t with task_state }
;;

let apply_text_edit t edit =
  match Editor.apply_text_edit t.editor edit with
  | Some editor when t.phase <> Saving ->
    { t with editor; phase = Editing; pending = None }
  | Some _ -> t
  | None -> t
;;

let admit_save t ~mutation_id ~block_id ~sibling_order ~calendar_generation ~creation_time
  =
  if not (can_save t)
  then t, None
  else (
    let command : Journal_graph_projection.capture =
      { mutation_id
      ; block_id
      ; sibling_order
      ; source = source t
      ; task_state = t.task_state
      ; creation_time
      ; children = []
      }
    in
    let request = Journal_graph_request.Capture { calendar_generation; command } in
    { t with phase = Saving; pending = Some request }, Some request)
;;

let fail t ~message =
  match t.pending with
  | Some _ -> { t with phase = Failed message }
  | None -> t
;;

let retry t =
  match t.phase, t.pending with
  | Failed _, Some request -> { t with phase = Saving }, Some request
  | Failed _, None | Editing, _ | Saving, _ -> t, None
;;
