module ID = Bonsai_flutter_spec.Id
module Ui = Bonsai_flutter_ui

type phase =
  | Editing
  | Saving
  | Failed of string

type editor =
  { session_id : ID.Text_input.session_id
  ; document_revision : ID.Text_input.document_revision
  ; accepted_local_revision : ID.Text_input.local_revision
  ; update_mode : Ui.Text_editing.update_mode
  ; value : Ui.Text_editing.Value.t
  }

type t =
  { editor : editor
  ; phase : phase
  ; pending : Journal_graph_request.t option
  }

let value_for_source source =
  let offset = Ui.Text_editing.Utf16.length source in
  let selection =
    Ui.Text_editing.Range.create ~text:source ~start_utf16:offset ~end_utf16:offset
  in
  Ui.Text_editing.Value.create ~text:source ~selection ()
;;

let create_editor ~session_number ~source =
  { session_id = ID.Text_input.Session_id.of_int64 session_number
  ; document_revision = ID.Text_input.Document_revision.zero
  ; accepted_local_revision = ID.Text_input.Local_revision.zero
  ; update_mode = Ui.Text_editing.Force_replace
  ; value = value_for_source source
  }
;;

let create ~session_number ~source =
  { editor = create_editor ~session_number ~source; phase = Editing; pending = None }
;;

let session_id t = t.editor.session_id
let document_revision t = t.editor.document_revision
let accepted_local_revision t = t.editor.accepted_local_revision
let update_mode t = t.editor.update_mode
let value t = t.editor.value
let source t = Ui.Text_editing.Value.text t.editor.value
let task_state _ = Journal_model.No_status
let phase t = t.phase
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

let apply_editor_text_edit editor (edit : Ui.Event.Payload.text_edit) =
  if
    (not (ID.Text_input.Session_id.equal editor.session_id edit.session_id))
    || ID.Text_input.Local_revision.compare
         edit.local_revision
         editor.accepted_local_revision
       <= 0
    || not
         (ID.Text_input.Document_revision.equal
            edit.base_document_revision
            editor.document_revision)
  then None
  else
    Some
      { editor with
        document_revision = ID.Text_input.Document_revision.succ editor.document_revision
      ; accepted_local_revision = edit.local_revision
      ; update_mode = Ui.Text_editing.Ack
      ; value = value_of_edit edit
      }
;;

let apply_text_edit t edit =
  match apply_editor_text_edit t.editor edit with
  | Some editor -> { editor; phase = Editing; pending = None }
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
      ; task_state = Journal_model.No_status
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
