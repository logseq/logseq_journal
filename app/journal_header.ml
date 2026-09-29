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

(* Feedback banners pin below (or above) the safe-area edge and shrink to the
   tighter layout first, exactly like the old chrome extension's ViewThatFits
   preference order. *)
let feedback ~key ~top ~visible ~compact ~expanded body =
  Ui.element
    ~key
    (Lui_elements.edge_inset
       ~edge:(if top then `top else `bottom)
       ~visible
       ~background:"bar"
       [ Ui.mount (V.Body.Private.to_widget body)
       ; Lui_elements.view_that_fits [ Ui.mount compact; Ui.mount expanded ]
       ])
  |> V.Body.static
;;

let date_header ~title = Ui.element (Lui_elements.heading ~level:3 ~value:title [])

let detail ~on_back ~actions body =
  let back =
    V.buttons
      ~actions:
        [ V.buttons_action ~label:"Back" ~icon:"chevron.left" ~on_press:on_back () ]
      ()
    |> test_id "BackButton"
  in
  (* Controls span the bar; the title floats centered over them. *)
  Ui.element
    ~key:(Ui.Key.string "journal-detail-header")
    (Lui_elements.edge_inset
       ~edge:`top
       [ Ui.mount (V.Body.Private.to_widget body)
       ; Lui_elements.overlay
           [ Lui_elements.row
               ~padding_horizontal:16
               ~min_height:44
               [ Ui.mount back; Lui_elements.spacer []; Ui.mount (V.buttons ~actions ()) ]
           ; Lui_elements.align `center (Lui_elements.heading ~level:5 ~value:"Block" [])
           ]
       ])
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
  let connecting = sync_phase = Some Graph_service.Connecting in
  let controls =
    Lui_elements.row
      ~main:`end_
      ~gap:8
      ((if connecting then [ Ui.mount (V.progress ~style:Circular ()) ] else [])
       @
       match cluster with
       | Some cluster -> [ Ui.mount cluster ]
       | None -> [])
  in
  (* Page chrome: controls float top-trailing when there is no title; a titled
     page pins a top bar with the centered title and trailing controls. *)
  let chrome =
    match context with
    | Journals ->
      Lui_elements.overlay
        [ Ui.mount (V.Body.Private.to_widget body)
        ; Lui_elements.align
            `top_trailing
            (Lui_elements.row
               ~main:`end_
               ~padding_horizontal:16
               ~padding_vertical:8
               [ controls ])
        ]
    | Favorites ->
      Lui_elements.edge_inset
        ~edge:`top
        [ Ui.mount (V.Body.Private.to_widget body)
        ; Lui_elements.overlay
            [ Lui_elements.row
                ~padding_horizontal:16
                ~min_height:44
                [ Lui_elements.spacer []; controls ]
            ; Lui_elements.align
                `center
                (Lui_elements.heading
                   ~level:5
                   ~value:"Favorites"
                   ~accessibility_identifier:"favorites-header-title"
                   [])
            ]
        ]
  in
  let body =
    Ui.element ~key chrome |> test_id "journal-floating-chrome" |> V.Body.static
  in
  if platform <> "ios" || Option.is_none capture_expanded
  then
    (* The inset reserves scrolling space; each buttons composite
       supplies its own glass without system toolbar chrome. *)
    Ui.element
      ~key:(Ui.Key.string "journal-bottom-controls")
      (Lui_elements.edge_inset
         ~edge:`bottom
         [ Ui.mount (V.Body.Private.to_widget body)
         ; Lui_elements.column
             ~padding_horizontal:16
             ~padding_vertical:8
             [ Ui.mount
                 (V.row ~spacing:16. [ destinations; V.spacer (); capture ]
                  |> test_id "journal-bottom-controls")
             ]
         ])
    |> V.Body.static
  else body
;;
