module Ui = Journal_view
module V = Ui.View
module L = Lui_elements

let body ?(child = false) title =
  if String.trim (Journal_model.Title.plain title) = "" then V.column []
  else Journal_header.bounded_text ~child title
;;

let status_badge ?(status_name = fun status -> Journal_model.status_name status) block =
  let status = Journal_model.task_state block in
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
;;

let metadata_row = function
  | [] -> []
  | children -> [ V.of_lui (L.row ~gap:8 ~cross:`start children) ]
;;

let metadata ?status_name block =
  let tags =
    match Journal_model.tag_titles block with
    | [] -> []
    | titles ->
      [ L.text
          ~value:(String.concat "  " (List.map (fun title -> "#" ^ title) titles))
          ~grow:1.
          ~style_class:"caption"
          ~foreground:"secondary"
          []
      ]
  in
  metadata_row (status_badge ?status_name block @ tags)
;;

let view
      ?status_name
      ?(creator_name = fun _ _ -> None)
      ?(render_source = Fun.id)
      ?render_title
      ~render_media
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
      (body source :: metadata_row (status_badge ?status_name block))
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
  let creator_id =
    Journal_model.creator_id (Journal_model.properties block)
    |> Option.map Logseq_db_types.Graph_types.Uuid.to_string
  in
  let fields =
    [ "mode", `String "timeline-row"; "text", `String time
    ; "tags", `List (List.map (fun tag -> `String tag) (Journal_model.tag_titles block)) ]
  in
  let content = Ui.mount (V.column ~spacing:12. ~alignment:Leading preview_labels) in
  let details (context : Lui_ui.ui_context) parent =
    let creator =
      Option.bind creator_id (fun id ->
        Option.map (fun name -> id, name) (creator_name context id))
    in
    let payload, payload_signal =
      match creator with
      | None -> Yojson.Safe.to_string (`Assoc fields), None
      | Some (id, name) ->
        let encode name =
          Yojson.Safe.to_string
            (`Assoc (("creator", `Assoc [ "id", `String id; "name", `String name ]) :: fields))
        in
        let payload_signal = Signal.map encode name in
        Signal.on_dispose context.ui_scope (fun () -> Signal.dispose_signal payload_signal);
        encode (Signal.sample name), Some payload_signal
    in
    Journal_lui_native.mount
      ~payload ?payload_signal ~children:[ content ] Journal_lui_native.chrome_identifier
      context parent
  in
  V.column ~spacing:12. ~alignment:Leading [ V.of_lui details ]
  |> V.with_test_id (Ui.Test_id.string ("journal-row-label:" ^ id))
;;
