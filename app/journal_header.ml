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
      (* Chrome slots are positional on the native side — absent slots must
       still mount a (zero-size) node or the host's index lookup shifts. *)
    ~children:
      [ V.Body.Private.to_widget body; V.column [ compact ]; V.column [ expanded ] ]
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

let detail ~on_back ~actions body =
  let back =
    V.buttons
      ~actions:
        [ V.buttons_action ~label:"Back" ~icon:"chevron.left" ~on_press:on_back () ]
      ()
    |> test_id "BackButton"
  in
  Ui.Native_widget.widget
    chrome
    ~key:(Ui.Key.string "journal-detail-header")
    ~props:(`Assoc [ "mode", `String "detail"; "title", `String "Block" ])
    ~on_event:(fun _ -> ())
    ~children:[ V.Body.Private.to_widget body; back; V.buttons ~actions () ]
    ()
  |> V.Body.static
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
      ~capture_expanded
      ~body
  =
  let account_action =
    Option.map
      (fun dispatch ->
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
         V.buttons_menu_action
           ~label:"Account menu"
           ~icon:(Journal_symbols.name Journal_symbols.Account)
           ~on_select:
             (Ui.Event.Handler.create (function
                | Ui.Event.Payload.Int64 id ->
                  List.find_opt (fun (candidate, _, _, _, _) -> candidate = id) actions
                  |> Option.iter (fun (_, _, _, action, _) ->
                    Ui.Event.Handler.Private.invoke
                      dispatch
                      (Ui.Event.Payload.Text action))
                | _ -> ()))
           (List.map
              (fun (id, title, symbol, _, role) ->
                 V.Menu.action ~id ~role ~title ~icon:symbol ())
              actions))
      on_account_action
  in
  let error_action =
    Option.map
      (fun on_press ->
         V.buttons_action
           ~label:"Error info"
           ~icon:(Journal_symbols.name Journal_symbols.Error)
           ~on_press
           ())
      on_error_info
  in
  (* The error and account chrome controls fuse into one capsule: error leads
     so the account menu stays the trailing glyph. *)
  let cluster =
    match Option.to_list error_action @ Option.to_list account_action with
    | [] -> None
    | actions ->
      let view = V.buttons ~actions () in
      let view =
        if Option.is_some error_action
        then
          view
          |> V.help ~message:"Inspect application errors"
          |> test_id "journal-error-info-button"
        else view
      in
      let view =
        if Option.is_some account_action
        then
          view
          |> V.semantics
               ~properties:
                 (Ui.Semantics.create
                    ~label:"Account menu"
                    ~hint:"Switch graphs, delete the local copy, or sign out"
                    ~role:Button
                    ())
          |> test_id "journal-account-menu-button"
        else view
      in
      Some view
  in
  let capture =
    (* buttons has no disabled state — guard the handler instead. *)
    V.buttons
      ~actions:
        [ V.buttons_action
            ~label:"Capture"
            ~icon:"square.and.pencil"
            ~on_press:
              (Ui.Event.Handler.create (fun payload ->
                 if capture_enabled
                 then Ui.Event.Handler.Private.invoke on_capture payload))
            ()
        ]
      ()
    |> V.semantics ~properties:(Ui.Semantics.create ~label:"Capture" ())
    |> test_id "journal-capture-open"
  in
  let destinations =
    V.buttons
      ~actions:
        [ V.buttons_action
            ~label:"Journals"
            ~icon:(Journal_symbols.name Journal_symbols.Journals)
            ~on_press:on_journals
            ()
        ; V.buttons_action
            ~label:"Favorites"
            ~icon:(Journal_symbols.name Journal_symbols.Favorites)
            ~on_press:on_favorites
            ()
        ]
      ()
  in
  let sync_feedback =
    V.column
      ~spacing:4.
      [ (if sync_phase = Some Graph_service.Connecting
         then V.loading ~message:"Connecting" () |> test_id "journal-header-sync-progress"
         else V.empty ())
      ; (match sync_error with
         | None -> V.empty ()
         | Some text ->
           V.text text |> V.text_selection ~enabled:true |> test_id "journal-sync-error")
      ]
    |> V.padding ~insets:(Ui.Layout.Edge_insets.all 8.)
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
  let body = body |> V.Body.with_test_id (Ui.Test_id.string "journal-root-navigation") in
  let body =
    Ui.Native_widget.widget
      chrome
      ~key
      ~props:
        (`Assoc
            [ "mode", `String "page"
            ; ( "title"
              , match context with
                | Journals -> `Null
                | Favorites -> `String "Favorites" )
            ; "connecting", `Bool (sync_phase = Some Graph_service.Connecting)
            ; "controls", `Bool (Option.is_some cluster)
            ])
      ~on_event:(fun _ -> ())
        (* Keep absent slots mounted so the native child indexes stay stable. *)
      ~children:
        [ V.Body.Private.to_widget body
        ; V.column (Option.to_list cluster)
        ; V.column
            [ (if sync_phase = Some Graph_service.Connecting
               then
                 V.progress ~style:Circular ()
                 |> V.semantics ~properties:(Ui.Semantics.create ~label:"Connecting" ())
                 |> test_id "journal-header-sync-progress"
               else V.empty ())
            ]
        ]
      ()
    |> test_id "journal-floating-chrome"
    |> V.Body.static
  in
  if platform <> "ios" || Option.is_none capture_expanded
  then
    (* The native inset reserves scrolling space; each buttons composite
       supplies its own glass without system toolbar chrome. *)
    Ui.Native_widget.widget
      chrome
      ~key:(Ui.Key.string "journal-bottom-controls")
      ~props:(`Assoc [ "mode", `String "bottom-controls" ])
      ~on_event:(fun _ -> ())
      ~children:
        [ V.Body.Private.to_widget body
        ; V.row ~spacing:16. [ destinations; V.spacer (); capture ]
          |> test_id "journal-bottom-controls"
        ]
      ()
    |> V.Body.static
  else body
;;
