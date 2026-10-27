module Ui = Journal_view
module V = Ui.View

type kind = Capture | Append

type assets = { camera : bool }

type props =
  { kind : kind
  ; capture : Journal_capture.t
  ; saving : bool
  ; enabled : bool
  ; error : string option
  ; assets : assets option
  }

type action =
  | Edit of Ui.Event.Payload.text_edit
  | Toggle_task of bool
  | Save
  | Close
  | Discard
  | Attach of Journal_asset_import.source
  | Remove_attachment of string

let scope = function Capture -> "journal-capture" | Append -> "journal-append"
let placeholder = function Capture -> "New journal entry" | Append -> "Append a block"

let live_region_text value =
  V.text value
  |> V.semantics ~properties:(Ui.Semantics.create ~label:value ~live_region:true ())
;;

let can_submit ~capture ~saving ~enabled =
  enabled
  && (not saving)
  && (Journal_capture.can_save capture
      ||
      match Journal_capture.phase capture with
      | Failed _ -> true
      | _ -> false)
;;

let content { kind; capture; saving; enabled; error; assets } ~on_action =
  let scope = scope kind in
  let placeholder = placeholder kind in
  let ignored = Ui.Event.Handler.create (fun _ -> ()) in
  let can_submit = can_submit ~capture ~saving ~enabled in
  let task_selected = Journal_capture.task_state capture <> Journal_model.No_status in
  let task =
    (* Circular icon capsule matching the composer actions row — buttons has
       no disabled state, so the guard lives in the handler. *)
    V.buttons
      ~actions:
        [ V.buttons_action
            ~label:"Task"
            ~icon:(if task_selected then "checkmark.circle" else "circle")
            ~on_press:
              (Ui.Event.Handler.create (fun _ ->
                 if enabled && not saving
                 then
                   on_action (Toggle_task (not task_selected))))
            ()
        ]
      ()
    |> V.with_test_id (Ui.Test_id.string (scope ^ "-task"))
  in
  let attach =
    match assets with
    | None -> []
    | Some assets ->
      let disabled =
        not (enabled && (not saving) && Journal_capture.can_attach capture)
      in
      (* The shared buttons composite has no disabled state. Native leaf buttons
         retain the same glass capsule and 44-point hit areas. *)
      let action ~label ~icon source =
        Lui_elements.button
          ~label ~icon:(`app icon) ~variant:`ghost ~size:`icon
          ~foreground:"foreground" ~width:44 ~height:44 ~disabled
          ~on_press:(fun _ -> if not disabled then on_action (Attach source))
          []
      in
      [ V.of_lui
          (Lui_elements.button_group ~gap:0 ~height:44 ~background:"glass"
             ~corner_radius:999
             ([ action ~label:"Files" ~icon:"doc" Journal_asset_import.Files
              ; action ~label:"Photos" ~icon:"photo" Journal_asset_import.Photos ]
              @ if assets.camera then
                  [ action ~label:"Camera" ~icon:"camera" Journal_asset_import.Camera ]
                else []))
        |> V.with_test_id (Ui.Test_id.string (scope ^ "-attach"))
      ]
  in
  let pending = Journal_capture.pending_attachments capture in
  let attachments =
    match pending with
    | [] -> None
    | _ ->
      Some
        (V.of_lui
           (Lui_elements.row
              ~gap:8
              (List.map
                 (fun staged ->
                    Lui_element_combine.composer_attachment
                      ~disabled:((not enabled) || saving)
                      ~key:(Journal_asset_import.staged_token staged)
                      ~path:(Journal_asset_import.staged_path staged)
                      ~title:(Journal_asset_import.staged_title staged)
                      ~file_type:(Journal_asset_import.staged_type staged)
                      ~on_remove:(fun _ ->
                        match assets with
                        | None -> ()
                        | Some _ when enabled && not saving ->
                          on_action (Remove_attachment (Journal_asset_import.staged_token staged))
                        | Some _ -> ())
                      ())
                 pending)))
  in
  let discard =
    if
      kind = Capture && Journal_capture.phase capture = Journal_capture.Editing
    then
      [ V.buttons
          ~actions:
            [ V.buttons_action
                ~label:"Discard draft"
                ~icon:"trash"
                ~on_press:(Ui.Event.Handler.create ~name:"journal-action" (fun _ -> on_action Discard))
                ()
            ]
          ()
      ]
    else []
  in
  let composer =
    if Journal_capture.retry_identity_locked capture
    then
      V.column
        ~spacing:12.
        ([ V.text (Journal_capture.source capture)
         ; live_region_text
             "The entry may already be saved. Choose a status and retry to confirm it \
              before editing."
         ; V.row
             ~spacing:8.
             [ task
             ; V.button ~enabled:can_submit ~child:(V.text "Retry") ~on_press:(Ui.Event.Handler.create ~name:"journal-action" (fun _ -> on_action Save)) ()
             ]
         ]
         @ List.map live_region_text (Option.to_list error))
    else
    V.composer
      ~key:(Ui.Key.string (scope ^ "-composer"))
      ~accessibility_identifier:(scope ^ "-composer")
      ~autofocus:true
      ~label:"Draft"
      ~placeholder
      ~session_id:(Journal_capture.session_id capture)
      ~document_revision:(Journal_capture.document_revision capture)
      ~accepted_local_revision:(Journal_capture.accepted_local_revision capture)
      ~value:(Journal_capture.value capture)
      ~send_disabled:(not can_submit)
      ?attachments
      ?feedback:
        (let messages =
           Option.to_list error
           @ if List.length pending >= Journal_capture.attachment_limit then
               [ "9 attachments maximum. Remove one to add another." ]
             else []
         in
         match messages with
         | [] -> None
         | messages -> Some (V.column (List.map live_region_text messages)))
      ~actions:(attach @ [ task ] @ discard)
      ~on_edit:(Ui.Event.Handler.create ~name:"journal-dispatch" (function
        | Ui.Event.Payload.Text_edit edit -> on_action (Edit edit)
        | _ -> ()))
      ~on_submit:ignored
      ~on_send:(Ui.Event.Handler.create ~name:"journal-action" (fun _ -> on_action Save))
      ()
  in
  let content =
    V.column
      ~spacing:12.
      ([ composer ] @ if saving then [ V.loading ~message:"Saving…" () ] else [])
    |> V.padding ~insets:(Ui.Layout.Edge_insets.all 16.)
  in
  content
;;

let page ({ kind; capture; saving; enabled; _ } as props) ~on_action =
  let scope = scope kind in
  let can_submit = can_submit ~capture ~saving ~enabled in
  let close =
    V.button
      ~style:Plain
      ~on_press:(Ui.Event.Handler.create ~name:"journal-action" (fun _ -> on_action Close))
      ~child:(V.label ~title:(V.text "Cancel") ~icon:(V.symbol ~name:"xmark" ()) ())
      ()
    |> V.with_test_id (Ui.Test_id.string (scope ^ "-close"))
  in
  content props ~on_action
  |> V.Body.static
  |> V.Body.toolbar
       ~items:
         [ V.Toolbar.item
             ~key:(Ui.Key.string "composer-close")
             ~placement:Cancellation_action
             close
         ; V.Toolbar.item
             ~key:(Ui.Key.string "composer-submit")
             ~placement:Primary_action
             (V.button
                ~enabled:can_submit
                ~on_press:(Ui.Event.Handler.create ~name:"journal-action" (fun _ -> on_action Save))
                ~child:(V.text (if kind = Append then "Add" else "Send"))
                ())
         ]
;;
