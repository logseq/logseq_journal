module ID = Bonsai_flutter_spec.Id
module Ui = Bonsai_flutter_ui

type phase =
  | Editing
  | Confirm_discard
  | Saving
  | Failed of string
  | Committed

type editor =
  { session_id : ID.Text_input.session_id
  ; document_revision : ID.Text_input.document_revision
  ; accepted_local_revision : ID.Text_input.local_revision
  ; update_mode : Ui.Text_editing.update_mode
  ; value : Ui.Text_editing.Value.t
  }

type t =
  { editor : editor
  ; child_editors : editor list
  ; task_state : Journal_model.task_state
  ; phase : phase
  ; pending : Journal_graph_request.t option
  ; confirm_return_phase : phase option
  }

type dismissal =
  | Close
  | Confirm of t
  | Block

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
  { editor = create_editor ~session_number ~source
  ; child_editors = []
  ; task_state = Journal_model.No_status
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
let child_editors t = t.child_editors
let editor_session_id editor = editor.session_id
let editor_document_revision editor = editor.document_revision
let editor_accepted_local_revision editor = editor.accepted_local_revision
let editor_update_mode editor = editor.update_mode
let editor_value editor = editor.value

let dirty t =
  (not (String.equal (source t) ""))
  || t.task_state <> Journal_model.No_status
  || not (List.is_empty t.child_editors)
;;

let source_is_blank source = String.equal (String.trim source) ""

let can_save t =
  t.phase = Editing
  && (not (source_is_blank (source t)))
  && List.for_all
       (fun editor -> not (source_is_blank (Ui.Text_editing.Value.text editor.value)))
       t.child_editors
;;

let can_add_child t = t.phase = Editing && List.length t.child_editors < 64

let add_child t ~session_number =
  if not (can_add_child t)
  then t
  else (
    let child = create_editor ~session_number ~source:"" in
    { t with child_editors = t.child_editors @ [ child ] })
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
  | Some editor -> { t with editor; phase = Editing; confirm_return_phase = None }
  | None ->
    let rec apply_to_child = function
      | [] -> None
      | editor :: rest ->
        (match apply_editor_text_edit editor edit with
         | Some editor -> Some (editor :: rest)
         | None -> Option.map (fun rest -> editor :: rest) (apply_to_child rest))
    in
    (match apply_to_child t.child_editors with
     | None -> t
     | Some child_editors ->
       { t with child_editors; phase = Editing; confirm_return_phase = None })
;;

let toggle_task t =
  if t.phase <> Editing
  then t
  else (
    let task_state =
      match t.task_state with
      | Journal_model.No_status -> Journal_model.Todo
      | Todo -> Done
      | Done -> No_status
      | Doing | In_review | Now | Canceled | Backlog | Waiting | Later -> Done
    in
    { t with task_state })
;;

let request_dismiss t =
  match t.phase with
  | Saving | Committed | Confirm_discard -> Block
  | Editing | Failed _ ->
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
  | Editing | Saving | Failed _ | Committed -> t
;;

let discard t =
  { editor =
      { t.editor with
        document_revision =
          ID.Text_input.Document_revision.succ t.editor.document_revision
      ; update_mode = Ui.Text_editing.Force_replace
      ; value = value_for_source ""
      }
  ; child_editors = []
  ; task_state = Journal_model.No_status
  ; phase = Editing
  ; pending = None
  ; confirm_return_phase = None
  }
;;

let admit_save
      t
      ~mutation_id
      ~block_id
      ~sibling_order
      ~child_identities
      ~calendar_generation
      ~creation_time
  =
  if (not (can_save t)) || List.length child_identities <> List.length t.child_editors
  then t, None
  else (
    let children =
      List.map2
        (fun (mutation_id, block_id, sibling_order) editor ->
           { Journal_graph_projection.mutation_id
           ; block_id
           ; sibling_order
           ; source = Ui.Text_editing.Value.text editor.value
           ; task_state = Journal_model.No_status
           ; creation_time
           })
        child_identities
        t.child_editors
    in
    let command : Journal_graph_projection.capture =
      { mutation_id
      ; block_id
      ; sibling_order
      ; source = source t
      ; task_state = t.task_state
      ; creation_time
      ; children
      }
    in
    let request = Journal_graph_request.Capture { calendar_generation; command } in
    ( { t with phase = Saving; pending = Some request; confirm_return_phase = None }
    , Some request ))
;;

let fail t ~message =
  match t.pending with
  | Some _ -> { t with phase = Failed message; confirm_return_phase = None }
  | None -> t
;;

let retry t =
  match t.phase, t.pending with
  | Failed _, Some request ->
    { t with phase = Saving; confirm_return_phase = None }, Some request
  | Failed _, None | Editing, _ | Confirm_discard, _ | Saving, _ | Committed, _ -> t, None
;;

let commit t _block =
  { t with phase = Committed; pending = None; confirm_return_phase = None }
;;
