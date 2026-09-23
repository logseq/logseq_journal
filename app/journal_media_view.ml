module Ui = Journal_view

let extension =
  Ui.Native_widget.Extension.create
    ~kind_id:(Journal_ids.Native_widget.Kind_id.of_int 2105)
    ~version:1
    ~capabilities:[ Stateful; Semantics ]
    ~encode_props:(fun json -> Yojson.Basic.to_string json |> Bytes.of_string)
    ~decode_event:(fun ~event_id:_ bytes -> Ok (Bytes.to_string bytes))
    ()
;;

let item_json (item : Journal_media_runtime.item) =
  let width, height =
    match item.asset.dimensions with
    | Some (w, h) -> w, h
    | None -> 4, 3
  in
  let kind, value =
    match item.presentation with
    | Journal_media.File path -> "file", path
    | External url -> "external", url
    | Placeholder message -> "placeholder", message
    | Hidden -> "placeholder", "Waiting for file"
  in
  `Assoc
    [ "id", `String item.token
    ; "kind", `String kind
    ; "value", `String value
    ; "type", `String item.file_type
    ; "width", `Int width
    ; "height", `Int height
    ]
;;

let view ~scope ~root ~media ~editable ~on_event child =
  let items, more, error, picker =
    match media with
    | None -> [], false, None, None
    | Some view -> view.Journal_media_runtime.items, view.more, view.error, view.picker
  in
  Ui.Native_widget.widget
    extension
    ~key:(Ui.Key.string ("media:" ^ scope ^ ":" ^ root))
    ~props:
      (`Assoc
          [ "root", `String root
          ; "items", `List (List.map item_json items)
          ; "more", `Bool more
          ; "editable", `Bool editable
          ; ( "picker"
            , match picker with
              | None -> `Null
              | Some picker ->
                `Assoc
                  [ "items", `List (List.map item_json picker.candidates)
                  ; "more", `Bool picker.candidates_more
                  ; "busy", `Bool picker.busy
                  ] )
          ; ( "error"
            , match error with
              | None -> `Null
              | Some message -> `String message )
          ])
    ~on_event
    ~children:[ child ]
    ()
;;
