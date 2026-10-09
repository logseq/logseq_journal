module Ui = Journal_view
module V = Ui.View
module L = Lui_elements

let expanded_slot = Signal.state_slot "journal-body-expanded"

let body ~render_source block =
  let source = render_source (Journal_model.source block) in
  let long =
    String.length source > 240 || List.length (String.split_on_char '\n' source) > 3
  in
  if String.trim source = ""
  then V.column []
  else if not long
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
          ~grow:1.
          ~style_class:"caption"
          ~foreground:"secondary"
          []
      ]
  in
  match state @ tags with
  | [] -> []
  | children -> [ V.of_lui (L.row ~gap:8 ~cross:`start children) ]
;;

let view
      ?(render_source = Fun.id)
      ~render_media
      ~show_timestamp
      (entry : Journal_graph_projection.timeline_entry)
  =
  let block = entry.block in
  let id = Journal_model.id block in
  let is_image_asset file_type =
    Option.fold ~none:false ~some:Journal_media_view.is_image_type file_type
  in
  let image_children, text_children =
    List.partition
      (fun (summary : Journal_graph_projection.child_summary) ->
         is_image_asset summary.asset_file_type)
      entry.child_summaries
  in
  let image_children =
    List.map
      (fun (summary : Journal_graph_projection.child_summary) ->
         summary.block_id, Option.get summary.asset_file_type)
      image_children
  in
  let image_children =
    match Journal_model.asset_file_type block with
    | Some file_type when is_image_asset (Some file_type) ->
      (id, file_type) :: image_children
    | _ -> image_children
  in
  let body =
    if is_image_asset (Journal_model.asset_file_type block)
    then V.column []
    else body ~render_source block
  in
  let content = V.column ~spacing:8. ~alignment:Leading (body :: metadata block) in
  let labels =
    [ render_media ~title:(Journal_model.source block) ~root:id ~image_children content ]
  in
  let labels =
    labels
    @ List.map
        (fun (summary : Journal_graph_projection.child_summary) ->
           render_media
             ~title:summary.source
             ~root:summary.block_id
             ~image_children:[]
             (V.text (render_source summary.source)))
        text_children
  in
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
