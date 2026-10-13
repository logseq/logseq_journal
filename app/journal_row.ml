module Ui = Journal_view
module V = Ui.View
module L = Lui_elements

(* OCaml owns the preview policy; native Text owns visual wrapping at the
   available width and Dynamic Type size. Keep the full source for Detail. *)
let preview_text source =
  V.of_lui
    (Journal_lui_native.mount
       Journal_lui_native.chrome_identifier
       ~payload:
         (Yojson.Basic.to_string
            (`Assoc
                [ "mode", `String "bounded-text"
                ; "text", `String source
                ; "maxLines", `Int 4
                ]))
       ~children:[])
;;

let body source = if String.trim source = "" then V.column [] else preview_text source

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
      (* Guard the public renderer before any partition/source/media work. *)
      (List.take 3 entry.child_summaries)
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
  let source =
    if is_image_asset (Journal_model.asset_file_type block)
    then ""
    else render_source (Journal_model.source block)
  in
  let text_children =
    List.map
      (fun (summary : Journal_graph_projection.child_summary) ->
         summary, render_source summary.source)
      text_children
  in
  let metadata = metadata block in
  let empty_preview =
    String.trim source = ""
    && metadata = []
    && image_children = []
    && Option.is_none (Journal_model.asset_file_type block)
    && List.for_all
         (fun ((summary : Journal_graph_projection.child_summary), source) ->
            String.trim source = "" && Option.is_none summary.asset_file_type)
         text_children
  in
  let root_body =
    (* A retained parent may have content only beyond the preview budget.
       Keep its existing whole-row Detail action identifiable without looking
       past the selected summaries or manufacturing persisted content. *)
    if empty_preview then preview_text "Open block" else body source
  in
  let content = V.column ~spacing:8. ~alignment:Leading (root_body :: metadata) in
  let labels =
    [ render_media ~title:(Journal_model.source block) ~root:id ~image_children content ]
  in
  let labels =
    labels
    @ List.map
        (fun ((summary : Journal_graph_projection.child_summary), source) ->
           render_media
             ~title:summary.source
             ~root:summary.block_id
             ~image_children:[]
             (body source))
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
