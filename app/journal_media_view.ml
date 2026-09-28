module Ui = Journal_view
module V = Ui.View

(* The media action channel is unchanged: events keep arriving as
   "media-session:<scope>:media:<json>" Text payloads. *)
let emit ~root ~on_event action ?asset () =
  on_event
    (Yojson.Basic.to_string
       (`Assoc
           [ "action", `String action
           ; "root", `String root
           ; "asset", `String (Option.value ~default:"" asset)
           ; "visible", `Bool true
           ]))
;;

let emit_handler ~root ~on_event action ?asset () : Ui.Event.handler =
  Ui.Event.Handler.create (fun _ -> emit ~root ~on_event action ?asset ())
;;

let is_http value =
  match String.index_opt value ':' with
  | Some index ->
    let scheme = String.lowercase_ascii (String.sub value 0 index) in
    scheme = "http" || scheme = "https"
  | None -> false
;;

let is_image_type file_type =
  List.mem
    (String.lowercase_ascii file_type)
    [ "jpg"; "jpeg"; "png"; "gif"; "webp"; "heic"; "heif"; "tiff"; "bmp" ]
;;

let item_value (item : Journal_media_runtime.item) =
  match item.presentation with
  | Journal_media.File path -> path
  | Journal_media.External url -> url
  | Journal_media.Placeholder message -> message
  | Journal_media.Hidden -> "Waiting for file"
;;

(* Local files render through [file_image] (tap mounts a [file_preview] via the
   "preview" action); externals open via [link]; everything else is a retryable
   placeholder. *)
let item_view ~root ~on_event (item : Journal_media_runtime.item) =
  let invoke (handler : Ui.Event.handler) (_ : Lui_protocol.event) =
    Ui.Event.Handler.Private.invoke handler Ui.Event.Payload.Unit
  in
  let preview = emit_handler ~root ~on_event "preview" ~asset:(item_value item) () in
  let mount : Lui_elements.t =
    match item.presentation with
    | Journal_media.File path when is_image_type item.file_type ->
      Lui_elements.file_image
        ~path
        ~max_pixel_size:1024
        ~max_height:240
        ~accessibility_identifier:("journal-media:" ^ item.token)
        ~on_press:(invoke preview)
        []
    | Journal_media.File _ ->
      Lui_elements.button
        ~text:"Open attachment"
        ~icon:(Ui.journal_icon "doc")
        ~accessibility_identifier:("journal-media:" ^ item.token)
        ~on_press:(invoke preview)
        []
    | Journal_media.External url when is_http url ->
      Lui_elements.link
        ~url
        ~text:"Open external attachment"
        ~icon:(Ui.journal_icon "arrow.up.right.square")
        ~accessibility_identifier:("journal-media:" ^ item.token)
        []
    | _ ->
      let retry = emit_handler ~root ~on_event "retry" ~asset:item.token () in
      Lui_elements.column
        ~gap:8
        ~accessibility_identifier:("journal-media:" ^ item.token)
        [ Ui.mount
            (V.row
               ~spacing:8.
               [ V.symbol ~name:"photo" ()
               ; V.text
                   ~style:
                     (Ui.Style.Text_style.create
                        ~foreground:Ui.Style.Text_style.Secondary
                        ())
                   (item_value item)
               ])
        ; Ui.mount
            (V.buttons
               ~actions:
                 [ V.buttons_action
                     ~label:"Retry"
                     ~icon:"arrow.clockwise"
                     ~on_press:retry
                     ()
                 ]
               ())
        ]
  in
  Ui.element mount
;;

let picker_mounts ~root ~on_event (picker : Journal_media_runtime.picker) =
  let invoke handler (_ : Lui_protocol.event) =
    Ui.Event.Handler.Private.invoke handler Ui.Event.Payload.Unit
  in
  let candidate (item : Journal_media_runtime.item) =
    Lui_elements.button
      ~text:(if String.equal item.file_type "" then "file" else item.file_type)
      ~icon:(Ui.journal_icon "doc")
      ~disabled:picker.busy
      ~accessibility_identifier:("journal-media-candidate:" ^ item.token)
      ~on_press:
        (invoke (emit_handler ~root ~on_event "reuse-select" ~asset:item.token ()))
      []
  in
  List.concat
    [ (if picker.busy && picker.candidates = []
       then [ Ui.mount (V.loading ~message:"Loading attachments" ()) ]
       else [])
    ; List.map candidate picker.candidates
    ; (if picker.candidates_more
       then
         [ Lui_elements.button
             ~text:"More attachments"
             ~disabled:picker.busy
             ~on_press:(invoke (emit_handler ~root ~on_event "reuse-next" ()))
             []
         ]
       else [])
    ; [ Lui_elements.button
          ~text:"Cancel"
          ~variant:`secondary
          ~on_press:(invoke (emit_handler ~root ~on_event "reuse-cancel" ()))
          []
      ]
    ]
;;

let view ~scope ~root ~media ~editable ~on_event child =
  let items, more, error, picker =
    match media with
    | None -> [], false, None, None
    | Some view -> view.Journal_media_runtime.items, view.more, view.error, view.picker
  in
  let invoke handler (_ : Lui_protocol.event) =
    Ui.Event.Handler.Private.invoke handler Ui.Event.Payload.Unit
  in
  let actions_menu =
    if editable
    then
      [ Lui_elements.menu
          ~icon:(Ui.journal_icon "ellipsis.circle")
          ~label:"Attachment actions"
          ~accessibility_identifier:"journal-media-actions"
          [ Lui_elements.menu_item
              ~text:"Replace file…"
              ~on_press:(invoke (emit_handler ~root ~on_event "replace" ()))
              []
          ; Lui_elements.menu_item
              ~text:"Reuse existing…"
              ~on_press:(invoke (emit_handler ~root ~on_event "reuse" ()))
              []
          ]
      ]
    else []
  in
  let content =
    Lui_elements.column
      ~gap:8
      ~cross:`start
      ((Ui.mount child
        ::
        (match actions_menu with
         | [] -> []
         | menu -> [ Lui_elements.row [ Lui_elements.spacer []; Lui_elements.row menu ] ])
       )
       @ List.map (fun item -> Ui.mount (item_view ~root ~on_event item)) items
       @ (match picker with
          | None -> []
          | Some picker -> picker_mounts ~root ~on_event picker)
       @ (match error with
          | None -> []
          | Some message ->
            [ Ui.mount
                (V.text
                   ~style:
                     (Ui.Style.Text_style.create
                        ~foreground:Ui.Style.Text_style.Secondary
                        ())
                   message)
            ; Lui_elements.button
                ~text:"Retry attachments"
                ~on_press:(invoke (emit_handler ~root ~on_event "retry" ()))
                []
            ])
       @
       if more
       then
         [ Lui_elements.button
             ~text:"Next attachments"
             ~on_press:(invoke (emit_handler ~root ~on_event "next" ()))
             []
         ]
       else [])
  in
  Ui.element ~key:(Ui.Key.string ("media:" ^ scope ^ ":" ^ root)) content
;;
