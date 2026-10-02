module Ui = Journal_view
module L = Lui_elements

let preview_slot = Signal.state_slot "journal-media-preview"

let is_image_type = function
  | "png"
  | "jpg"
  | "jpeg"
  | "gif"
  | "webp"
  | "heic"
  | "heif"
  | "tif"
  | "tiff"
  | "bmp"
  | "avif" -> true
  | _ -> false
;;

let size_text size =
  if size < 1000L
  then Printf.sprintf "%Ld B" size
  else if size < 1_000_000L
  then Printf.sprintf "%.1f KB" (Int64.to_float size /. 1000.)
  else if size < 1_000_000_000L
  then Printf.sprintf "%.1f MB" (Int64.to_float size /. 1_000_000.)
  else Printf.sprintf "%.1f GB" (Int64.to_float size /. 1_000_000_000.)
;;

let view ~scope ~root ~media ~editable ~on_event child =
  let emit ?(asset = "") ?(visible = true) action =
    on_event
      (Yojson.Basic.to_string
         (`Assoc
             [ "action", `String action
             ; "root", `String root
             ; "asset", `String asset
             ; "visible", `Bool visible
             ]))
  in
  let items, more, error, picker =
    match media with
    | None -> [], false, None, None
    | Some view -> view.Journal_media_runtime.items, view.more, view.error, view.picker
  in
  Ui.View.of_lui (fun context parent ->
    let context = Lui_ui.child_context context ("media:" ^ scope ^ ":" ^ root) in
    let preview =
      Signal.state_at context.ui_scheduler context.ui_state_scope preview_slot None
    in
    let preview_file path = Signal.set preview (Some path) in
    let render_item ~gallery (item : Journal_media_runtime.item) =
      let visible _ = emit ~asset:item.token "asset" in
      let id = "journal-media:" ^ item.token in
      match item.presentation with
      | Journal_media.File path when is_image_type item.file_type ->
        L.file_image
          ~key:item.token
          ~path
          ~max_pixel_size:1024
          ~width:(if gallery then 190 else 102)
          ~height:(if gallery then 90 else 102)
          ~fit:`fill
          ~corner_radius:10
          ~accessibility_identifier:id
          ~on_appear:visible
          ~on_press:(fun _ -> preview_file path)
          []
      | File path ->
        let typ =
          if item.file_type = "" then "File" else String.uppercase_ascii item.file_type
        in
        let detail =
          match item.asset.size with
          | None -> typ
          | Some size -> typ ^ " · " ^ size_text size
        in
        L.column
          ~key:item.token
          ~padding:10
          ~background:"#839B7F0B"
          ~corner_radius:10
          ~on_appear:visible
          [ L.row
              ~gap:10
              ~cross:`start
              [ L.icon
                  ~name:(`app (if item.file_type = "pdf" then "doc-text" else "doc"))
                  ~point_size:24
                  ~foreground:"secondary"
                  []
              ; L.column
                  ~gap:3
                  ~cross:`start
                  ~grow:1.
                  [ L.text
                      ~value:(typ ^ " attachment")
                      ~style_class:"footnote"
                      ~accessibility_identifier:id
                      ~on_press:(fun _ -> preview_file path)
                      []
                  ; L.text ~value:detail ~style_class:"caption" ~foreground:"secondary" []
                  ]
              ]
          ]
      | External url ->
        L.link
          ~key:item.token
          ~url
          ~text:"Open external attachment"
          ~accessibility_identifier:id
          ~on_appear:visible
          []
      | Placeholder message ->
        L.column
          ~key:item.token
          ~gap:6
          ~padding:10
          ~cross:`start
          ~background:"#839B7F0B"
          ~corner_radius:10
          ~on_appear:visible
          [ L.text ~value:message ~style_class:"caption" ~foreground:"secondary" []
          ; L.text
              ~value:"Retry"
              ~style_class:"caption"
              ~on_press:(fun _ -> emit ~asset:item.token "retry")
              []
          ]
      | Hidden ->
        L.text
          ~key:item.token
          ~value:"Waiting for file"
          ~style_class:"caption"
          ~foreground:"secondary"
          ~on_appear:visible
          []
    in
    let images, files =
      List.partition
        (fun (i : Journal_media_runtime.item) -> is_image_type i.file_type)
        items
    in
    let gallery =
      match images with
      | [] -> []
      | [ _ ] -> []
      | items ->
        [ L.scroll
            ~orientation:`horizontal
            [ L.row ~gap:8 (List.map (render_item ~gallery:true) items) ]
        ]
    in
    let body =
      match images with
      | [ item ] ->
        L.row
          ~gap:15
          ~cross:`start
          [ L.column ~grow:1. ~cross:`start [ Ui.mount child ]
          ; L.column ~width:102 ~cross:`start [ render_item ~gallery:false item ]
          ]
      | [] | _ :: _ :: _ -> Ui.mount child
    in
    let file_rows = List.map (render_item ~gallery:false) files in
    let actions =
      if editable
      then
        [ L.row
            ~gap:10
            [ L.text
                ~value:"Replace file…"
                ~style_class:"caption"
                ~on_press:(fun _ -> emit "replace")
                []
            ; L.text
                ~value:"Reuse existing…"
                ~style_class:"caption"
                ~on_press:(fun _ -> emit "reuse")
                []
            ]
        ]
      else []
    in
    let picker_rows =
      match picker with
      | None -> []
      | Some picker ->
        (if picker.busy && picker.candidates = []
         then [ L.text ~value:"Loading attachments" [] ]
         else [])
        @ List.map
            (fun (i : Journal_media_runtime.item) ->
               L.text
                 ~value:(String.uppercase_ascii i.file_type ^ " attachment")
                 ~on_press:(fun _ ->
                   if not picker.busy then emit ~asset:i.token "reuse-select")
                 [])
            picker.candidates
        @ (if picker.candidates_more
           then
             [ L.text ~value:"More attachments" ~on_press:(fun _ -> emit "reuse-next") []
             ]
           else [])
        @ [ L.text ~value:"Cancel" ~on_press:(fun _ -> emit "reuse-cancel") [] ]
    in
    let errors =
      match error with
      | None -> []
      | Some message ->
        [ L.text ~value:message ~style_class:"caption" ~foreground:"secondary" []
        ; L.text ~value:"Retry attachments" ~on_press:(fun _ -> emit "retry") []
        ]
    in
    let more_rows =
      if more
      then [ L.text ~value:"Next attachments" ~on_press:(fun _ -> emit "next") [] ]
      else []
    in
    L.column
      ~key:("media:" ^ scope ^ ":" ^ root)
      ~gap:12
      ~cross:`start
      ~on_appear:(fun _ -> emit "root")
      ([ body ]
       @ gallery
       @ file_rows
       @ actions
       @ picker_rows
       @ errors
       @ more_rows
       @
       if items = []
       then []
       else
         [ L.dyn
             ~equal:( = )
             (function
               | None -> L.column []
               | Some path ->
                 L.file_preview ~path ~on_dismiss:(fun _ -> Signal.set preview None) [])
             (Signal.value preview)
         ])
      context
      parent)
;;
