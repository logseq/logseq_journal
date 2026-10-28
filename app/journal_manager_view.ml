module Ui = Journal_view
module V = Ui.View
module Graph_service = Logseq_db_worker_lui.Logseq_db_worker_lui_service
module Presentation = Journal_page_layout

type picker_live =
  { residents : string list
  ; replacement : string option
  ; status : string
  ; authenticated : bool
  ; checking : bool
  ; deleting : Graph_service.local_copy_request option
  ; presence : string -> (Graph_service.local_copy_presence, string) result option
  }

type picker =
  { graphs : Graph_service.graph Rrbvec.t
  ; selected_graph : Logseq_db_types.Graph_types.Uuid.t option
  ; live : picker_live
  }

type unlock =
  { graph_name : string
  ; password : Journal_capture.t
  ; pending : bool
  ; challenge_ready : bool
  ; error : string option
  }

type busy =
  { loading : bool
  ; initial : bool
  ; active : bool
  ; value : float option
  ; message : string
  ; choose_graph : bool
  }

type recovery = Refresh | Retry_local of string | Recover_online of string

type props =
  | Account_failure
  | Signed_out
  | Busy of busy
  | Picker of picker
  | Unlock of unlock
  | Failed of { message : string; recovery : recovery option; choose_graph : bool }
  | Graph_unavailable of V.t

type action =
  | Startup_retry
  | Refresh_catalog
  | Begin_online_recovery
  | Remove_resident of string
  | Move_resident of int * int
  | Replace_resident of string
  | Cancel_replacement
  | Select_graph of string
  | Switch_graph
  | Close_picker
  | Visible_range of int64 * int64
  | Request_local_copy_reset of string
  | Sign_out
  | Submit_password
  | Edit_password of Ui.Event.Payload.text_edit
  | Diagnostics

let handler on_action action =
  Ui.Event.Handler.create ~name:"journal-action" (fun _ -> on_action action)
;;

type unlock_chrome_props = { mode : string; title : string; pending : bool; error : string option [@default None] }
[@@deriving yojson]

let graph_picker_list ?header ?(residents=[]) ?on_visible_range rows =
  V.Native_list.vertical ~key:(Ui.Key.string "graph-list") ~style:Plain ?on_visible_range
    (residents @ [ V.Native_list.section ~key:(Ui.Key.string "graphs") ?header ~separator:Hidden rows ])
  |> fun list -> V.column ~spacing:0. [list]
  |> V.with_test_id (Ui.Test_id.string "graph-picker-list")
  |> V.frame ~max_width:Fill ~max_height:Fill
  |> V.Body.static
;;

let view ?picker_signal props ~on_action =
  let button ?(role = V.Button_role.Normal) ?(enabled = true) ~id ~command title symbol =
    V.button
      ~key:(Ui.Key.string id)
      ~role
      ~enabled
      ~on_press:(handler on_action command)
      ~child:(V.label ~title:(V.text title) ~icon:(V.symbol ~name:symbol ()) ())
      ()
    |> V.with_test_id (Ui.Test_id.string id)
  in
  let capsule ~id ~command title symbol =
    V.buttons
      ~actions:
        [ V.buttons_action
            ~label:title
            ~icon:symbol
            ~text:title
            ~on_press:(handler on_action command)
            ()
        ]
      ()
    |> V.with_test_id (Ui.Test_id.string id)
  in
  let diagnostics =
    button
      ~id:"journal-startup-diagnostics"
      ~command:Diagnostics
      "Diagnostics"
      "stethoscope"
  in
  let account_menu ?(sign_out = false) () =
      V.buttons
        ~actions:
          [ V.buttons_menu_action
              ~label:"Account menu"
              ~icon:"ellipsis"
              ~on_select:
                (Ui.Event.Handler.create (function
                   | Ui.Event.Payload.Int64 1L -> on_action Diagnostics
                   | Int64 2L when sign_out -> on_action Sign_out
                   | _ -> ()))
              ([ V.Menu.action ~id:1L ~title:"Diagnostics" ~icon:"stethoscope" () ]
               @
               if sign_out
               then
                 [ V.Menu.action
                     ~id:2L
                     ~title:"Sign out"
                     ~icon:"rectangle.portrait.and.arrow.right"
                     ()
                 ]
               else [])
          ]
        ()
      |> V.with_test_id (Ui.Test_id.string "journal-startup-menu")
  in
  let toolbar ?(sign_out = false) title actions body =
    let account_menu = account_menu ~sign_out () in
    body
    |> V.Body.toolbar
         ~items:
           ((V.Toolbar.item
               ~key:(Ui.Key.string "startup-title")
               ~placement:Principal
               (V.text title)
             :: actions)
            @ [ V.Toolbar.item
                  ~key:(Ui.Key.string "startup-menu")
                  ~placement:Primary_action
                  account_menu
              ])
  in
  let unavailable ~title ~symbol ~message ~actions =
    Presentation.unavailable ~title ~symbol ~message ~actions
    |> V.frame ~max_width:Fill ~max_height:Fill
    |> V.Body.static
  in
  let choose_graph =
    capsule
      ~id:"graph-picker-choose"
      ~command:Switch_graph
      "Choose another graph"
      "folder"
  in
  let busy ({ loading; initial; active; value; message; choose_graph = choose } : busy) =
    Journal_header.startup ~loading ~initial ~active ?value ~message
      (if choose then choose_graph else V.empty ())
  in
  let graph_picker snapshot =
    let reactive ?grow ~equal build =
      match picker_signal with
      | None -> build snapshot.live
      | Some signal -> V.of_lui
          (Lui_elements.stack ?grow
             [Lui_elements.dyn ~equal (fun current -> Ui.mount (build current)) signal])
    in
    let icon_button ?(enabled = true) ?tooltip ~id ~command ~label icon =
      V.of_lui (Lui_elements.button ~key:id ~accessibility_identifier:id
        ~text:"" ~label ~icon ~size:`icon ~variant:`ghost ~disabled:(not enabled) ?tooltip
        ~on_press:(fun _ -> on_action command) [])
    in
    let refresh = reactive
      ~equal:(fun left right -> left.deleting = right.deleting)
      (fun owner -> icon_button ~enabled:(owner.deleting = None)
        ~id:"graph-picker-refresh" ~command:Refresh_catalog ~label:"Refresh graphs"
        ~tooltip:"Refresh the authorized graph catalog" `refresh_cw)
    in
    let projected context project = Option.map (fun source ->
      let signal = Signal.map project source in
      Signal.on_dispose context.Lui_ui.ui_scope (fun () -> Signal.dispose_signal signal);
      signal) picker_signal in
    let status_text current = current.status in
    let status = V.of_lui (fun context parent ->
      Lui_elements.text ~value:(status_text snapshot.live)
        ?value_signal:(projected context status_text)
        ~foreground:"error-foreground" ~accessibility_identifier:"graph-picker-local-copy-status" [] context parent)
    in
    let resident_name id = Rrbvec.to_seq snapshot.graphs |> Seq.find_map (fun (graph:Graph_service.graph)->
      if Logseq_db_types.Graph_types.Uuid.to_string graph.graph_id=id then Some graph.name else None)
      |> Option.value ~default:"Graph" in
    let resident_rows=List.init 3 (fun index ->
      let slot=string_of_int(index+1) in
      let assigned=List.nth_opt snapshot.live.residents index in
      let content=match assigned with
        | None -> V.row ~spacing:12. [V.symbol ~name:"plus.circle" ();V.column ~alignment:Leading
            [V.text ("Slot " ^ slot);V.text ~style:(Ui.Style.Text_style.create ~foreground:Secondary ()) "Choose a graph below"]]
        | Some id -> V.row ~spacing:10.
            [V.text slot;V.text(resident_name id) |> V.frame ~max_width:Fill
            ; (match snapshot.live.replacement with
               | Some _ -> button ~id:("graph-resident-replace:" ^ id) ~command:(Replace_resident id) "Replace" "arrow.triangle.2.circlepath"
               | None -> V.row ~spacing:4.
                   [icon_button ~enabled:(index>0) ~id:("graph-resident-up:" ^ id) ~command:(Move_resident (index,-1))
                      ~label:("Move " ^ resident_name id ^ " earlier") `arrow_up
                   ;icon_button ~id:("graph-resident-remove:" ^ id) ~command:(Remove_resident id)
                      ~label:("Close " ^ resident_name id) `x]) ] in
      V.Native_list.row ~key:(Ui.Key.string ("resident-slot:" ^ slot)) ~separator:Hidden
        (content |> V.frame ~max_width:Fill ~min_height:44.)) in
    let resident_header=V.column ~alignment:Leading ~spacing:6.
      ([V.text "Resident graphs · up to 3"] @ match snapshot.live.replacement with
       | None -> [] | Some id -> [V.text ("Choose a slot to replace with " ^ resident_name id);
           button ~id:"graph-resident-replace-cancel" ~command:Cancel_replacement "Cancel replacement" "xmark"]) in
    let residents=[V.Native_list.section ~key:(Ui.Key.string "resident-graphs")
      ~header:resident_header ~separator:Hidden resident_rows] in
    let content =
      match Rrbvec.is_empty snapshot.graphs with
      | true -> unavailable ~title:"No graphs available" ~symbol:"folder"
          ~message:"Refresh to check for graphs available to your account." ~actions:(V.empty ())
      | false ->
        let rows = Seq.map (fun (graph : Graph_service.graph) ->
          let id = Logseq_db_types.Graph_types.Uuid.to_string graph.graph_id in
          let current = snapshot.selected_graph = Some graph.graph_id in
          let presence owner = owner.presence id in
          let subtitle owner =
            if current then "Current graph"
            else if Option.fold ~none:false ~some:(fun request -> request.Graph_service.graph_id = graph.graph_id) owner.deleting
            then "Deleting local copy…"
                 else (
                   match presence owner with
              | Some (Ok Graph_service.Not_downloaded) -> "Download and open"
              | Some (Error _) -> "Unable to check local copy"
                   | _ -> "")
               in
          let selection_enabled owner = owner.deleting = None in
          let deletion_enabled owner =
            owner.authenticated
            && not current && not (List.mem id owner.residents) && not owner.checking
            && owner.deleting = None && presence owner <> Some (Ok Graph_service.Not_downloaded) in
          (* Native List cells retain their interactive children. Property signals
             update status and enabled state without replacing callback owners. *)
          let row = V.of_lui (fun context parent ->
            let select = V.Navigation_link.create ~key:(Ui.Key.string ("graph-picker:" ^ id))
                ~activation_id:id ~disclosure:false ~enabled:(selection_enabled snapshot.live)
                ?enabled_signal:(projected context selection_enabled)
                ~on_activate:(handler on_action (Select_graph id))
                ~label:(V.row ~spacing:12.
                  [ V.symbol ~name:(if graph.encrypted then "lock.doc" else "folder") ()
                  ; V.column ~spacing:3. ~alignment:Leading
                      [V.text graph.name; V.of_lui (fun context parent ->
                        Lui_elements.text ~value:(subtitle snapshot.live)
                          ?value_signal:(projected context subtitle)
                          ~foreground:"secondary" [] context parent)]
                    |> V.frame ~max_width:Fill
                  ; (if current then V.symbol ~name:"checkmark.circle" ()
                     else reactive ~equal:(fun left right -> presence left = presence right)
                       (fun owner -> if presence owner = Some (Ok Graph_service.Not_downloaded)
                         then V.symbol ~name:"icloud.and.arrow.down" () else V.column [])) ]
                  |> V.frame ~max_width:Fill ~min_height:44.)
                () |> V.with_test_id (Ui.Test_id.string ("graph-picker:" ^ id))
                |> V.frame ~max_width:Fill in
            let options = V.buttons ~key:(Ui.Key.string ("graph-picker-options:" ^ id))
                ~actions:[V.buttons_menu_action ~label:("Options for " ^ graph.name) ~icon:"ellipsis"
                  ~on_select:(Ui.Event.Handler.create (function
                    | Ui.Event.Payload.Int64 1L -> on_action (Request_local_copy_reset id)
                    | _ -> ()))
                  ([V.Menu.action ~id:1L ~title:"Delete local copy" ~icon:"trash" ~role:Destructive
                      ~enabled:(deletion_enabled snapshot.live) ?enabled_signal:(projected context deletion_enabled)
                      ~test_id:(Ui.Test_id.string ("graph-picker-delete:" ^ id)) ()]
                   @ if current then [V.Menu.action ~id:2L
                       ~title:"Switch graphs first." ~enabled:false ()]
                     else if not snapshot.live.authenticated then [V.Menu.action ~id:2L
                       ~title:"Connect your account to manage local copies." ~enabled:false ()]
                     else [])]
                () |> V.with_test_id (Ui.Test_id.string ("graph-picker-options:" ^ id)) in
            Ui.mount (V.row ~spacing:8. [select; options] |> V.frame ~max_width:Fill) context parent)
          in
          V.Native_list.row ~key:(Ui.Key.string id) ~separator:Hidden row
        ) (Rrbvec.to_seq snapshot.graphs) |> List.of_seq in
        graph_picker_list ~header:status ~residents
          ~on_visible_range:(Ui.Event.Handler.create (function
            | Ui.Event.Payload.Visible_range range ->
              on_action (Visible_range (Int64.max 0L (Int64.sub range.first_index 3L),
                Int64.max 0L (Int64.sub range.last_exclusive 3L)))
            | _ -> ())) rows
    in
    Journal_header.graph_picker
      ~leading:(V.column (if Option.is_some snapshot.selected_graph then
        [icon_button ~id:"graph-picker-close" ~command:Close_picker ~label:"Close" `x]
        else []))
      ~controls:(V.row ~spacing:8. [refresh; account_menu ~sign_out:snapshot.live.authenticated ()])
      content
  in
  let unlock ({ graph_name; password; pending; challenge_ready; error } : unlock) =
    let ignored = Ui.Event.Handler.create (fun _ -> ()) in
    let submit = handler on_action Submit_password in
    let editor =
      V.secure_field
        ~label:"Encryption password"
        ~prompt:"Enter password"
        ~appearance:Ui.Text_editing.Field_appearance.Plain
        ~key:(Ui.Key.string "e2ee-password-editor")
        ~enabled:(not pending)
        ~keyboard:Ui.Text_editing.Keyboard.Text
        ~submit_label:Ui.Text_editing.Submit_label.Go
        ~autofocus:(not pending)
        ~max_utf8_bytes:4096
        ~session_id:(Journal_capture.session_id password)
        ~document_revision:(Journal_capture.document_revision password)
        ~accepted_local_revision:(Journal_capture.accepted_local_revision password)
        ~update_mode:(Journal_capture.update_mode password)
        ~value:(Journal_capture.value password)
        ~on_edit:(Ui.Event.Handler.create ~name:"journal-dispatch" (function
          | Ui.Event.Payload.Text_edit edit -> on_action (Edit_password edit)
          | _ -> ()))
        ~on_submit:submit
        ~on_focus_changed:ignored
        ~on_limit_reached:ignored
        ()
      |> V.with_test_id (Ui.Test_id.string "e2ee-password-editor")
    in
    let unlock_button =
      V.of_lui
        (Lui_elements.button
           ~key:"unlock-submit"
           ~variant:`primary
           ~size:`lg
           ~text_alignment:`center
           ~grow:1.
           ~min_height:44
           ~disabled:(pending || not challenge_ready || not (Journal_capture.can_save password))
           ~on_press:(fun _ -> on_action Submit_password)
           ~text:(if pending then "Unlocking…" else "Unlock graph")
           [])
      |> V.frame ~max_width:Fill
      |> V.with_test_id (Ui.Test_id.string "e2ee-password-submit")
    in
    let choose_graph =
      V.button
        ~key:(Ui.Key.string "unlock-cancel")
        ~style:Plain
        ~on_press:(handler on_action Switch_graph)
        ~child:(V.text "Change graph")
        ()
      |> V.frame ~min_height:44.
      |> V.with_test_id (Ui.Test_id.string "e2ee-password-cancel")
    in
    let chrome =
      Ui.Native_widget.Extension.create
        ~kind_id:(Journal_ids.Native_widget.Kind_id.of_int 2103)
        ~version:2
        ~capabilities:[ Stateful; Semantics ]
        ~encode_props:(fun props -> unlock_chrome_props_to_yojson props |> Yojson.Safe.to_string |> Bytes.of_string)
        ~decode_event:(fun ~event_id:_ _ -> Error "Unlock uses child control events")
        ()
    in
    Ui.Native_widget.widget
      chrome
      ~key:(Ui.Key.string "graph-unlock")
      ~props:{ mode = "unlock"; title = graph_name; pending; error }
      ~on_event:(fun _ -> ())
      ~children:[ editor; unlock_button; choose_graph; diagnostics ]
      ()
    |> V.Body.static
    |> V.Body.toolbar
         ~items:
           [ V.Toolbar.item
               ~key:(Ui.Key.string "startup-diagnostics")
               ~placement:Secondary_action
               diagnostics
           ]
  in
  let body = match props with
    | Account_failure ->
      unavailable ~title:"Unable to prepare your account" ~symbol:"person.crop.circle.badge.exclamationmark"
        ~message:"Retry to check your account and open your journal."
        ~actions:(capsule ~id:"journal-startup-retry" ~command:Startup_retry "Retry" "arrow.clockwise")
      |> toolbar "Journals"
          [ V.Toolbar.item ~key:(Ui.Key.string "startup-diagnostics")
              ~placement:Secondary_action diagnostics ]
    | Signed_out ->
      unavailable ~title:"Sign in to open a graph" ~symbol:"person.crop.circle"
        ~message:"Connect your account to access your graphs." ~actions:(V.empty ())
      |> toolbar "Journals" []
    | Busy value -> busy value |> toolbar "" []
    | Picker value -> graph_picker value
    | Unlock value -> unlock value
    | Graph_unavailable child ->
      child |> V.frame ~max_width:Fill ~max_height:Fill |> V.Body.static
      |> toolbar "Journals" []
    | Failed { message; recovery; choose_graph = choose } ->
      let actions = match recovery with
        | Some Refresh -> capsule ~id:"graph-picker-retry" ~command:Refresh_catalog "Retry" "arrow.clockwise"
        | Some (Retry_local id) -> capsule ~id:"graph-picker-retry" ~command:(Select_graph id) "Retry local open" "arrow.clockwise"
        | Some (Recover_online title) -> capsule ~id:"graph-picker-retry" ~command:Begin_online_recovery title "arrow.clockwise"
        | None -> V.empty () in
      let actions = if choose then V.column ~spacing:12. [actions; choose_graph] else actions in
      let actions = V.of_lui (Lui_elements.row ~gap:0 ~main:`center ~cross:`center [Ui.mount actions]) in
      unavailable ~title:"Unable to open graph" ~symbol:"questionmark.folder" ~message ~actions
      |> toolbar "Journals" []
  in
  body |> V.Body.with_test_id (Ui.Test_id.string "sync-manager-route")
;;
