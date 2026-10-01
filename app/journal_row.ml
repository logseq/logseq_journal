module Ui = Journal_view
module V = Ui.View
module L = Lui_elements

let expanded_slot = Signal.state_slot "journal-body-expanded"

let body block =
  let source = Journal_model.source block in
  let long =
    String.length source > 240 || List.length (String.split_on_char '\n' source) > 3
  in
  if not long
  then V.of_lui (L.text ~value:source [])
  else
    V.of_lui (fun context parent ->
      let context =
        Lui_ui.child_context context ("journal-body:" ^ Journal_model.id block)
      in
      let expanded =
        Signal.state_at context.ui_scheduler context.ui_state_scope expanded_slot false
      in
      let label =
        Signal.map
          (fun full -> if full then "Show less" else "Show more")
          (Signal.value expanded)
      in
      Signal.on_dispose context.ui_scope (fun () -> Signal.dispose_signal label);
      L.column
        ~gap:4
        ~cross:`start
        [ L.dyn
            ~equal:Bool.equal
            (fun full ->
               L.text ~value:source ~style_class:(if full then "" else "line-clamp-3") [])
            (Signal.value expanded)
        ; L.text
            ~key:"body-toggle"
            ~value_signal:label
            ~style_class:"caption"
            ~foreground:"secondary"
            ~on_press:(fun _ -> Signal.update expanded not)
            []
        ]
        context
        parent)
;;

let metadata block =
  let status = Journal_model.task_state block in
  let titles = Journal_model.tag_titles block in
  let state =
    if status = No_status
    then []
    else
      [ L.column
          ~cross:`start
          ~padding_horizontal:6
          ~padding_vertical:2
          ~background:"#839B7F16"
          ~corner_radius:5
          [ L.text
              ~value:(Journal_model.status_name status)
              ~style_class:"caption"
              ~foreground:"secondary"
              []
          ]
      ]
  in
  let tags =
    if titles = []
    then []
    else
      [ L.text
          ~value:(String.concat "  " (List.map (fun title -> "#" ^ title) titles))
          ~style_class:"caption"
          ~foreground:"secondary"
          []
      ]
  in
  match state @ tags with
  | [] -> []
  | children -> [ V.of_lui (L.row ~gap:8 ~cross:`start children) ]
;;

let view ~render_media ~show_timestamp (entry : Journal_graph_projection.timeline_entry) =
  let block = entry.block in
  let id = Journal_model.id block in
  let labels = [ render_media ~root:id (body block) ] in
  let labels =
    labels
    @ List.map
        (fun (summary : Journal_graph_projection.child_summary) ->
           render_media ~root:summary.block_id (V.text summary.source))
        entry.child_summaries
  in
  let labels = labels @ metadata block in
  let labels =
    if show_timestamp
    then
      V.of_lui
        (L.text
           ~value:(Journal_time.format_hh_mm (Journal_model.creation_time block))
           ~style_class:"caption"
           ~foreground:"secondary"
           [])
      :: labels
    else labels
  in
  V.column ~spacing:12. ~alignment:Leading labels
  |> V.with_test_id (Ui.Test_id.string ("journal-row-label:" ^ id))
;;
