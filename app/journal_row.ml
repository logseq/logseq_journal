module Ui = Journal_view
module V = Ui.View
module L = Lui_elements

let chrome fields child =
  Journal_lui_native.mount
    ~payload:(Yojson.Safe.to_string (`Assoc fields))
    ~children:[ child ]
    Journal_lui_native.chrome_identifier
;;

let compact_only child = chrome [ "mode", `String "timeline-compact-only" ] child

let body ?(child = false) title =
  if String.trim (Journal_model.Title.plain title) = "" then V.column []
  else Journal_header.bounded_text ~child title
;;

let metadata_view
      ?(status_name = fun status -> Journal_model.status_name status)
      ~timeline
      block
  =
  let status = Journal_model.task_state block in
  let titles = Journal_model.tag_titles block in
  let visible_titles, remaining =
    if timeline then List.take 3 titles, max 0 (List.length titles - 3) else titles, 0
  in
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
              ~value:(status_name status)
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
      let text = L.text
          ~value:
            (String.concat
               "  "
               (List.map (fun title -> "#" ^ title) visible_titles
                @ if remaining = 0 then [] else [ "+" ^ string_of_int remaining ]))
          ?text_alignment:(if timeline then Some `end_ else None)
          ?grow:(if timeline then None else Some 1.)
          ~style_class:"caption"
          ~foreground:"secondary"
          []
      in
      if timeline
      then [ L.column ~grow:1. ~cross:`stretch [ compact_only text ] ]
      else [ text ]
  in
  match state @ tags with
  | [] -> []
  | children -> [ V.of_lui (L.row ~gap:8 ~cross:`start children) ]
;;

let metadata ?status_name block = metadata_view ?status_name ~timeline:false block

let view
      ?status_name
      ?(creator_name = fun _ -> None)
      ?(render_source = Fun.id)
      ?render_title
      ~render_media
      ~show_timestamp
      (entry : Journal_graph_projection.timeline_entry)
  =
  let block = entry.block in
  let id = Journal_model.id block in
  let time = Journal_time.format_hh_mm (Journal_model.creation_time block) in
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
  let render source = match render_title with
    | Some render -> render source
    | None -> Journal_model.Title.render (render_source source) in
  let source =
    if is_image_asset (Journal_model.asset_file_type block)
    then []
    else render (Journal_model.source block)
  in
  let content =
    V.column
      ~spacing:8.
      ~alignment:Leading
      (body source :: metadata_view ?status_name ~timeline:true block)
  in
  let preview_labels =
    [ render_media ~title:(Journal_model.source block) ~root:id ~image_children content ]
  in
  let preview_labels =
    preview_labels
    @ List.map
        (fun (summary : Journal_graph_projection.child_summary) ->
           render_media
             ~title:summary.source
             ~root:summary.block_id
             ~image_children:[]
             (body ~child:true (render summary.source)))
        text_children
  in
  let creator =
    Option.bind (Journal_model.creator_id (Journal_model.properties block)) (fun id ->
      let id = Logseq_db_types.Graph_types.Uuid.to_string id in
      Option.map (fun name -> `Assoc [ "id", `String id; "name", `String name ]) (creator_name id))
  in
  let details =
    chrome
      ([ "mode", `String "timeline-row"; "text", `String time
       ; "tags", `List (List.map (fun tag -> `String tag) (Journal_model.tag_titles block)) ]
       @ Option.to_list (Option.map (fun creator -> "creator", creator) creator))
      (Ui.mount (V.column ~spacing:12. ~alignment:Leading preview_labels))
    |> V.of_lui
  in
  let row_children =
    if show_timestamp
    then
      V.of_lui
        (compact_only (L.text
           ~value:time
           ~style_class:"caption"
           ~foreground:"secondary"
           []))
      :: [ details ]
    else [ details ]
  in
  V.column ~spacing:12. ~alignment:Leading row_children
  |> V.with_test_id (Ui.Test_id.string ("journal-row-label:" ^ id))
;;
