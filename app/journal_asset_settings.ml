module Ui = Bonsai_swiftui_ui

type event =
  | Days of Journal_asset_policy.settings
  | Dismissed
  | Retry_upload of Logseq_db_types.Graph_types.Uuid.t

let decode payload =
  if payload = "dismissed"
  then Some Dismissed
  else if String.starts_with ~prefix:"retry:" payload
  then (
    match
      Logseq_db_types.Graph_types.Uuid.of_string
        (String.sub payload 6 (String.length payload - 6))
    with
    | Ok operation -> Some (Retry_upload operation)
    | Error _ -> None)
  else if String.starts_with ~prefix:"days:" payload
  then (
    let value = String.sub payload 5 (String.length payload - 5) in
    Option.bind (int_of_string_opt value) (fun recent_days ->
      match Journal_asset_policy.settings ~recent_days with
      | Ok settings -> Some (Days settings)
      | Error _ -> None))
  else None
;;

let extension =
  Ui.Native_widget.Extension.create
    ~kind_id:(Bonsai_swiftui_spec.Id.Native_widget.Kind_id.of_int 2106)
    ~version:1
    ~capabilities:[ Stateful; Semantics ]
    ~encode_props:(fun json -> Yojson.Basic.to_string json |> Bytes.of_string)
    ~decode_event:(fun ~event_id:_ bytes -> Ok (Bytes.to_string bytes))
    ()
;;

let describe (status : Journal_asset_policy.offline) =
  let files =
    Printf.sprintf "%d of %d attachments available offline" status.ready status.total
  in
  match status.enumeration with
  | Inactive -> "Waiting for a graph"
  | Enumerating -> "Scanning attachments; " ^ files
  | Paused -> "Waiting for capacity; " ^ files
  | Failed -> "Could not discover all attachments; " ^ files
  | Complete when status.total = 0 -> "No managed attachments in this scope"
  | Complete when status.ready = status.total -> "All attachments available offline"
  | Complete when status.failed > 0 -> files ^ "; some downloads need attention"
  | Complete -> files ^ "; downloads pending"
;;

let view ~uploads ~offline ~presented ~on_event child =
  let recent, favorites =
    match offline with
    | None -> "Waiting for a graph", "Waiting for a graph"
    | Some (recent, favorites) -> describe recent, describe favorites
  in
  Ui.Native_widget.widget
    extension
    ~key:(Ui.Key.string "asset-settings")
    ~props:
      (`Assoc
          [ "presented", `Bool presented
          ; "recent", `String recent
          ; "favorites", `String favorites
          ; ( "uploads"
            , `List
                (List.map
                   (fun (row : Journal_uploads.row) ->
                      `Assoc
                        [ "id", `String row.id
                        ; "title", `String row.title
                        ; "message", `String row.message
                        ; "busy", `Bool row.busy
                        ; "retry", `Bool row.retry
                        ])
                   uploads) )
          ])
    ~on_event
    ~children:[ child ]
    ()
;;
