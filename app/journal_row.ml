module Ui = Bonsai_swiftui_ui
module V = Ui.View

let view ~render_media ~show_timestamp (entry : Journal_graph_projection.timeline_entry) =
  let block = entry.block in
  let id = Journal_model.id block in
  let labels = [ render_media ~root:id (V.text (Journal_model.source block)) ] in
  let labels =
    labels
    @ List.map
        (fun (summary : Journal_graph_projection.child_summary) ->
           render_media ~root:summary.block_id (V.text summary.source))
        entry.child_summaries
  in
  let labels =
    labels
    @
    if Journal_model.task_state block = No_status
    then []
    else [ V.text (Journal_model.status_name (Journal_model.task_state block)) ]
  in
  let labels =
    if show_timestamp
    then V.text (Journal_time.format_hh_mm (Journal_model.creation_time block)) :: labels
    else labels
  in
  V.column ~alignment:Leading labels
  |> V.with_test_id (Ui.Test_id.string ("journal-row-label:" ^ id))
;;
