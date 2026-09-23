module Graph_service = Logseq_db_worker_lui.Logseq_db_worker_lui_service
module Ui = Journal_view

module Context = struct
  type t =
    | Journals
    | Favorites

  let journals = Journals
  let favorites = Favorites

  let semantics_label = function
    | Journals -> "Journals"
    | Favorites -> "Favorites"
  ;;
end

module V = Ui.View

let test_id id view = V.with_test_id (Ui.Test_id.string id) view

let chrome =
  Ui.Native_widget.Extension.create
    ~kind_id:(Journal_ids.Native_widget.Kind_id.of_int 2103)
    ~version:2
    ~capabilities:[ Stateful; Semantics ]
    ~encode_props:(fun props -> Yojson.Basic.to_string props |> Bytes.of_string)
    ~decode_event:(fun ~event_id:_ _ -> Error "Chrome uses child control events")
    ()
;;

let feedback ~key ~top ~visible ~compact ~expanded body =
  Ui.Native_widget.widget
    chrome
    ~key
    ~props:
      (`Assoc [ "mode", `String "feedback"; "top", `Bool top; "visible", `Bool visible ])
    ~on_event:(fun _ -> ())
    ~children:[ V.Body.Private.to_widget body; compact; expanded ]
    ()
  |> V.Body.static
;;

let date_header ~title =
  Ui.Native_widget.widget
    chrome
    ~props:(`Assoc [ "mode", `String "header"; "title", `String title ])
    ~on_event:(fun _ -> ())
    ~children:[]
    ()
;;

let view
      ~key
      ~platform
      ~context
      ~sync_phase
      ~sync_error
      ~on_error_info
      ~on_account_action
      ~local_deletion_available
      ~on_journals
      ~on_favorites
      ~on_capture
      ~capture_enabled
      ~body
  =
  let selected =
    match context with
    | Context.Favorites -> true
    | Journals -> false
  in
  let heading value =
    V.text ~style:(Ui.Style.Text_style.create ~font_weight:Semi_bold ()) value
  in
  let navigation label symbol selected on_press =
    V.button
      ~on_press
      ~child:(V.label ~title:(V.text label) ~icon:(Journal_symbols.create symbol) ())
      ()
    |> V.semantics ~properties:(Ui.Semantics.create ~label ~selected ())
  in
  let account =
    match on_account_action with
    | None -> V.empty ()
    | Some dispatch ->
      let actions =
        [ ( 5L
          , "Attachment settings"
          , "slider.horizontal.3"
          , "open-asset-settings"
          , V.Button_role.Normal )
        ; 1L, "Diagnostics", "stethoscope", "open-diagnostics", V.Button_role.Normal
        ; ( 2L
          , "Switch graph"
          , "arrow.triangle.2.circlepath"
          , "switch-graph"
          , V.Button_role.Normal )
        ]
        @ (if local_deletion_available
           then
             [ ( 3L
               , "Delete local graph copy"
               , "trash"
               , "request-local-cache-reset"
               , V.Button_role.Destructive )
             ]
           else [])
        @ [ ( 4L
            , "Sign out"
            , "rectangle.portrait.and.arrow.right"
            , "sign-out"
            , V.Button_role.Normal )
          ]
      in
      V.Menu.create
        ~on_select:
          (Ui.Event.Handler.create (function
             | Ui.Event.Payload.Int64 id ->
               List.find_opt (fun (candidate, _, _, _, _) -> candidate = id) actions
               |> Option.iter (fun (_, _, _, action, _) ->
                 Ui.Event.Handler.Private.invoke dispatch (Ui.Event.Payload.Text action))
             | _ -> ()))
        ~label:
          (V.label
             ~title:(V.text "Account menu")
             ~icon:(Journal_symbols.create Journal_symbols.Account)
             ())
        (List.map
           (fun (id, title, symbol, _, role) ->
              V.Menu.action
                ~id
                ~role
                ~label:(V.label ~title:(V.text title) ~icon:(V.symbol ~name:symbol ()) ())
                ())
           actions)
      |> V.semantics
           ~properties:
             (Ui.Semantics.create
                ~label:"Account menu"
                ~hint:"Switch graphs, delete the local copy, or sign out"
                ~role:Button
                ())
      |> test_id "journal-account-menu-button"
  in
  let error =
    match on_error_info with
    | None -> V.empty ()
    | Some on_press ->
      V.button
        ~on_press
        ~child:
          (V.label
             ~title:(V.text "Error info")
             ~icon:(Journal_symbols.create Journal_symbols.Error)
             ())
        ()
      |> V.help ~message:"Inspect application errors"
      |> test_id "journal-error-info-button"
  in
  let capture =
    V.button
      ~enabled:capture_enabled
      ~on_press:on_capture
      ~child:
        (V.label
           ~title:(V.text "Capture")
           ~icon:(V.symbol ~name:"square.and.pencil" ())
           ())
      ()
    |> V.semantics ~properties:(Ui.Semantics.create ~label:"Capture" ())
    |> test_id "journal-capture-open"
  in
  let sync_feedback =
    V.column
      ~spacing:4.
      [ (if sync_phase = Some Graph_service.Connecting
         then
           V.row [ V.progress ~style:Circular (); V.text "Connecting" ]
           |> test_id "journal-header-sync-progress"
         else V.empty ())
      ; (match sync_error with
         | None -> V.empty ()
         | Some text ->
           V.text text |> V.text_selection ~enabled:true |> test_id "journal-sync-error")
      ]
    |> V.padding ~insets:(Ui.Layout.Edge_insets.all 8.)
  in
  let controls name placement values =
    if platform = "ios"
    then
      [ V.Toolbar.group
          ~key:(Ui.Key.string name)
          ~placement
          (List.map
             (fun (key, value) -> V.Toolbar.child ~key:(Ui.Key.string key) value)
             values)
      ]
    else
      List.map
        (fun (key, value) ->
           V.Toolbar.item ~key:(Ui.Key.string (name ^ ":" ^ key)) ~placement value)
        values
  in
  let navigation_placement =
    if platform = "ios" then V.Toolbar.Bottom_bar else Navigation
  in
  let capture_placement =
    if platform = "ios" then V.Toolbar.Bottom_bar else Primary_action
  in
  let items =
    (match context with
     | Context.Journals -> []
     | Favorites ->
       [ V.Toolbar.item
           ~key:(Ui.Key.string "title")
           ~placement:Principal
           (heading "Favorites" |> test_id "favorites-header-title")
       ])
    @ (match context with
       | Context.Journals when platform = "ios" -> []
       | Journals | Favorites ->
         controls
           "account"
           V.Toolbar.Primary_action
           (Option.to_list (Option.map (fun _ -> "error", error) on_error_info)
            @ Option.to_list (Option.map (fun _ -> "account", account) on_account_action)
           ))
    @ controls
        "destinations"
        navigation_placement
        [ ( "journals"
          , navigation "Journals" Journal_symbols.Journals (not selected) on_journals )
        ; ( "favorites"
          , navigation "Favorites" Journal_symbols.Favorites selected on_favorites )
        ]
    @ (if platform = "ios"
       then
         [ V.Toolbar.spacer
             ~key:(Ui.Key.string "capture-space")
             ~placement:Bottom_bar
             Flexible
         ]
       else [])
    @ [ V.Toolbar.item ~key:(Ui.Key.string "capture") ~placement:capture_placement capture
      ]
  in
  let body =
    match context with
    | Context.Journals -> body
    | Favorites ->
      feedback
        ~key
        ~top:true
        ~visible:(sync_phase = Some Graph_service.Connecting || Option.is_some sync_error)
        ~compact:sync_feedback
        ~expanded:sync_feedback
        body
  in
  let body =
    body
    |> V.Body.toolbar ~items
    |> V.Body.with_test_id (Ui.Test_id.string "journal-root-navigation")
  in
  let body =
    match context with
    | Context.Favorites -> body
    | Journals ->
      Ui.Native_widget.widget
        chrome
        ~key
        ~props:
          (`Assoc
              [ "mode", `String "journal"
              ; "connecting", `Bool (sync_phase = Some Graph_service.Connecting)
              ; "account", `Bool (Option.is_some on_account_action)
              ; "error", `Bool (Option.is_some on_error_info)
              ])
        ~on_event:(fun _ -> ())
        ~children:
          [ V.Body.Private.to_widget body
          ; (if platform = "ios" then account else V.empty ())
          ; (if platform = "ios" then error else V.empty ())
          ; (if sync_phase = Some Graph_service.Connecting
             then
               V.progress ~style:Circular ()
               |> V.semantics ~properties:(Ui.Semantics.create ~label:"Connecting" ())
               |> test_id "journal-header-sync-progress"
             else V.empty ())
          ]
        ()
      |> test_id "journal-floating-chrome"
      |> V.Body.static
  in
  body
;;
