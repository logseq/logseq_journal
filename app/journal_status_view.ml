module Ui = Journal_view
module V = Ui.View

type props =
  { catalog : Logseq_db_types.Graph_types.task_status_definition Rrbvec.t
  ; page : int
  ; error : string option
  ; complete : bool
  ; lookup_status : string -> Logseq_db_types.Graph_types.task_status_definition option
  ; current : Journal_model.task_state
  ; id : string
  ; tokens : Journal_visual_tokens.t
  }

type action =
  | Select of string
  | Page of int
  | Retry
  | Close

let status_name ~lookup =
  Journal_model.status_name ~lookup:(fun id ->
    Option.map
      (fun (d : Logseq_db_types.Graph_types.task_status_definition) -> d.title)
      (lookup id))
;;

let options ~catalog ~page =
  Rrbvec.to_seq catalog
  |> Seq.drop
       (min page (max 0 ((Rrbvec.length catalog - 1) / 100))
        * 100)
  |> Seq.take 100
  |> Seq.map (fun (definition : Logseq_db_types.Graph_types.task_status_definition) ->
    let uuid = Logseq_db_types.Graph_types.Uuid.to_string definition.uuid in
    uuid, Journal_model.Status uuid)
  |> List.of_seq
  |> fun choices -> choices @ [ "clear", Journal_model.No_status ]
;;

let view
      { catalog; page = requested_page; error; complete; lookup_status; current; id; tokens }
      ~on_action
  =
  let status_icon state =
    let palette = Journal_visual_tokens.status_colors tokens state in
    Journal_symbols.create
      ~color:(if state = Journal_model.No_status then palette.foreground else palette.background)
      (match state with
       | Journal_model.Status uuid ->
         (match lookup_status uuid with
          | Some { checkbox_state = Some true; _ } -> Journal_symbols.Done
          | _ -> Journal_symbols.for_task_state state)
       | _ -> Journal_symbols.for_task_state state)
    |> Ui.mount
  in
  let option (tag, state) =
    let selected = state = current in
    let title =
      if state = Journal_model.No_status then "Clear" else status_name ~lookup:lookup_status state
    in
    let label =
      if selected then title ^ ", current status"
      else if state = Journal_model.No_status then "Clear status"
      else "Set status to " ^ title
    in
    V.of_lui
      (Lui_elements.list_item
         ~key:("status:" ^ tag)
         ~selected
         ~min_height:44
         ~padding_horizontal:12
         ~padding_vertical:4
         ~corner_radius:12
         ~separator:`hidden
         ~on_press:(fun _ -> on_action (Select tag))
         [ Lui_elements.row ~grow:1.0 ~gap:12
             ([ status_icon state; Lui_elements.text ~value:title ~grow:1.0 ~text_alignment:`start [] ]
              @ if selected then [ Lui_elements.icon ~name:`check ~foreground:"primary" [] ] else []) ])
    |> V.with_test_id (Ui.Test_id.string ("journal-status-sheet-option:" ^ tag))
    |> V.semantics ~properties:(Ui.Semantics.create ~label ())
    |> Ui.mount
  in
  let choices =
    List.map (fun ((_, state) as choice) ->
      if state = Journal_model.No_status then
        Lui_elements.column ~cross:`stretch ~gap:6
          [ Lui_elements.separator ~orientation:`horizontal ~margin_horizontal:10 []
          ; option choice ]
         else option choice)
      (options ~catalog ~page:requested_page)
  in
  let page =
    min
      requested_page
      (max 0 ((Rrbvec.length catalog - 1) / 100))
  in
  let page_control id label command =
    Lui_elements.button
      ~key:id
      ~accessibility_identifier:id
      ~on_press:(fun _ -> on_action command)
      [ Lui_elements.text ~value:label [] ]
  in
  let pagination =
    (if page > 0
     then
       [ page_control
           "journal-status-previous"
           "Previous statuses"
           (Page (page - 1))
       ]
     else [])
    @ (if (page + 1) * 100 < Rrbvec.length catalog
       then
         [ page_control
             "journal-status-next"
             "More statuses"
             (Page (page + 1))
         ]
       else [])
    @
    if error <> None
    then [ page_control "journal-status-retry" "Retry statuses" Retry ]
    else []
  in
  V.of_lui
    (Lui_elements.scroll ~orientation:`vertical ~padding:20
       [ Lui_elements.column ~cross:`stretch ~gap:18
           [ Lui_elements.column ~cross:`start ~gap:7
               [ Lui_elements.text ~value:"TASK STATUS" ~style_class:"caption" ~foreground:"secondary" []
               ; Lui_elements.text ~value:"Choose a status" ~style_class:"title2 semibold" []
               ; Lui_elements.text ~value:"Tap a different status to apply." ~foreground:"secondary" [] ]
           ; Lui_elements.row ~gap:10 ~padding:12 ~background:"secondary" ~corner_radius:12
               [ status_icon current
               ; Lui_elements.text
                   ~value:("Current · " ^ status_name ~lookup:lookup_status current)
                   []
               ]
           ; Lui_elements.text
               ~value:
                 (match error with
                  | Some error -> error
                  | None when not complete -> "Loading statuses…"
                  | None when Rrbvec.is_empty catalog ->
                    "This graph has no available task statuses."
                  | None -> "")
               ~foreground:"secondary"
               []
           ; Lui_elements.card
               ~padding:6
               ~corner_radius:18
               ~border_width:0
               ~background:"secondary"
               [ Lui_elements.column ~cross:`stretch ~gap:0 choices ]
           ; Lui_elements.row ~gap:12 pagination
           ; Lui_elements.text ~value:"Clear removes the status from this block."
               ~style_class:"caption" ~foreground:"secondary" [] ] ])
  |> Journal_page_layout.dismiss_toolbar ~test_id:"journal-status-close"
       ~on_close:(Ui.Event.Handler.create ~name:"journal-action" (fun _ -> on_action Close))
  |> V.Body.with_test_id (Ui.Test_id.string ("journal-status-sheet-page:" ^ id))
;;
