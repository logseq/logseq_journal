module Ui = Journal_view
module V = Ui.View

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

let secondary value =
  Ui.mount
    (V.text
       ~style:(Ui.Style.Text_style.create ~foreground:Ui.Style.Text_style.Secondary ())
       value)
;;

(* One upload row inside the settings form: spinner while a retry is in
   flight, title + secondary message, and a retry affordance when the upload
   can be retried. *)
let upload_row ~on_event (row : Journal_uploads.row) =
  Lui_elements.row
    ~key:("journal-upload-row:" ^ row.id)
    ~accessibility_identifier:("journal-upload:" ^ row.id)
    ~gap:8
    ~cross:`start
    [ (if row.busy then Lui_elements.spinner [] else Lui_elements.row ~width:0 [])
    ; Lui_elements.column
        ~gap:2
        ~cross:`start
        ~grow:1.
        [ Ui.mount (V.text row.title); secondary row.message ]
    ; (if row.retry
       then
         Lui_elements.button
           ~text:"Retry"
           ~accessibility_identifier:("journal-upload-retry:" ^ row.id)
           ~on_press:(fun _ -> on_event ("retry:" ^ row.id))
           []
       else Lui_elements.row ~width:0 [])
    ]
;;

let view ~uploads ~offline ~presented ~days ~on_event child =
  let recent, favorites =
    match offline with
    | None -> "Waiting for a graph", "Waiting for a graph"
    | Some (recent, favorites) -> describe recent, describe favorites
  in
  let sheet =
    if presented
    then
      [ Lui_elements.sheet
          ~key:"journal-asset-settings-sheet"
          ~text:"Attachment settings"
          ~style_class:"navigation-form"
          ~detents:"medium,large"
          ~sizing:"form"
          ~min_width:360
          ~min_height:280
          ~on_dismiss:(fun _ -> on_event "dismissed")
          [ Lui_elements.column
              ~style_class:"form"
              ~gap:0
              ([ Lui_elements.heading ~level:3 ~value:"Offline attachments" []
               ; Lui_elements.number_stepper
                   ~accessibility_identifier:"journal-asset-days"
                   ~value:(float_of_int days)
                   ~min:0.
                   ~max:3660.
                   ~step:1.
                   ~text:(Printf.sprintf "Recent journal days: %d" days)
                   ~on_value_changed:(fun event ->
                     match event with
                     | Lui_protocol.ValueChanged (_, value) ->
                       on_event ("days:" ^ Int.to_string (int_of_float value))
                     | _ -> ())
                   []
               ]
               @ List.map (upload_row ~on_event) uploads
               @ [ secondary recent; secondary favorites ])
          ; Lui_elements.toolbar
              [ Lui_elements.button
                  ~text:"Done"
                  ~style_class:"confirmation-action"
                  ~accessibility_identifier:"journal-asset-settings-done"
                  ~on_press:(fun _ -> on_event "dismissed")
                  []
              ]
          ]
      ]
    else []
  in
  Ui.element
    ~key:(Ui.Key.string "asset-settings")
    (Lui_elements.column ~grow:1.0 (Ui.mount child :: sheet))
;;
