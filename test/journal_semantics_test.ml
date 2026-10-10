module Ui = Journal_view

let fail format = Printf.ksprintf failwith format

let require condition format =
  Printf.ksprintf (fun message -> if not condition then failwith message) format
;;

let require_ok = function
  | Ok value -> value
  | Error error -> fail "unexpected fixture rejection: %s" error
;;

let block_id = "20000000-0000-4000-a000-000000000001"
let page_id = "20000000-0000-4000-b000-000000000001"
let mutation_id = "20000000-0000-4000-9000-000000000001"

let creation_time =
  Journal_time.create
    ~instant_unix_ms:1_786_237_500_000L
    ~local_day:20260809
    ~local_minute_of_day:545
  |> require_ok
;;

let block
      ?(id = block_id)
      ?parent_id
      ?(source = "Literal #journal @person 👩🏽‍💻")
      ?(task_state = Journal_model.Done)
      ?(child_count = 3)
      ()
  =
  Journal_model.create
    ~id
    ~page_id
    ~journal_day:20260809
    ~parent_id
    ~sibling_order:"000000000001"
    ~source
    ~task_state
    ~child_count
    ~creation_time
    ~revision:"block-4"
    ~last_mutation_id:mutation_id
  |> require_ok
;;

module V = Ui.View
module Wire_nodes = Set.Make (Int)

let track_wire_teardown on_drop =
  let parents = Hashtbl.create 64 in
  let children = Hashtbl.create 64 in
  let children_of node =
    Option.value (Hashtbl.find_opt children node) ~default:Wire_nodes.empty
  in
  let unlink node =
    match Hashtbl.find_opt parents node with
    | None -> ()
    | Some parent ->
      Hashtbl.replace children parent (Wire_nodes.remove node (children_of parent));
      Hashtbl.remove parents node
  in
  let drop node =
    unlink node;
    Wire_nodes.iter (Hashtbl.remove parents) (children_of node);
    Hashtbl.remove children node;
    on_drop node
  in
  let rec detach node =
    Wire_nodes.iter detach (children_of node);
    drop node
  in
  function
  | Lui_protocol.InsertChild (parent, child, _) | MoveChild (parent, child, _) ->
    unlink child;
    Hashtbl.replace parents child parent;
    Hashtbl.replace children parent (Wire_nodes.add child (children_of parent))
  | RemoveChild (parent, child) ->
    if Hashtbl.find_opt parents child = Some parent then unlink child
  | DropNode node -> drop node
  | DetachSubtree node -> detach node
  | _ -> ()
;;

let dropped_wire_nodes ops =
  let dropped = Hashtbl.create 64 in
  let track = track_wire_teardown (fun node -> Hashtbl.replace dropped node ()) in
  List.iter track ops;
  dropped
;;

let test_timeline_media_targets () =
  let targets = ref [] in
  ignore
    (Journal_row.view
       ~show_timestamp:false
       ~render_media:(fun ~title:_ ~root ~image_children:_ child ->
         targets := root :: !targets;
         child)
       { Journal_graph_projection.block = block ()
       ; child_summaries =
           [ { block_id = "visible-child"; source = "Summary"; asset_file_type = None } ]
       }
     : V.t);
  require
    (List.sort String.compare !targets
     = List.sort String.compare [ block_id; "visible-child" ])
    "media discovery must target each displayed source, including summaries"
;;

let test_native_lui_events () =
  let received = ref [] in
  Journal_bridge.register
    { init = (fun _ _ _ -> "")
    ; dispatch =
        (fun event ->
          received := event :: !received;
          "")
    ; extension_event = (fun _ _ _ -> "")
    ; pump = (fun () -> "")
    ; platform_event = (fun _ -> ())
    ; platform_response = (fun _ -> ())
    ; platform_failure = (fun _ -> ())
    ; dispose = (fun () -> "")
    ; root_node = (fun () -> 0)
    };
  ignore (Journal_bridge.scroll_completed 7 42 "unavailable");
  ignore (Journal_bridge.visible_range 8 0 14);
  ignore (Journal_bridge.picked 9 {|{"token":11,"files":[{"name":"日记.md"}]}|});
  require
    (List.rev !received
     = [ Lui_protocol.ScrollCompleted (7, 42, "unavailable")
       ; Lui_protocol.VisibleRange (8, 0, 14)
       ; Lui_protocol.Picked (9, {|{"token":11,"files":[{"name":"日记.md"}]}|})
       ])
    "native LUI events must preserve their node IDs and payloads"
;;

let with_mounted view run =
  let batches = ref [] in
  let backend : Lui_protocol.backend =
    { backend_profile = Lui_protocol.profile IOS SwiftUIHost
    ; apply_batch =
        (fun batch ->
          batches := batch :: !batches;
          true)
    }
  in
  let app =
    Lui_app.create_with_extensions
      backend
      Journal_lui_native.registry
      ()
      (fun () () -> ())
      (fun _ _ _ -> Ui.mount view)
  in
  Fun.protect
    ~finally:(fun () -> ignore (Lui_app.dispose app))
    (fun () ->
       require (Lui_app.start app) "view did not mount";
       ignore (Lui_app.flush app);
       let ops () =
         List.concat_map
           (fun (batch : Lui_protocol.patch_batch) -> batch.ops)
           (List.rev !batches)
       in
       run app ops)
;;

let test_scoped_theme_wire_properties () =
  let tokens =
    [ "accent", Lui_ui.Fixed "#123456"
    ; "foreground", Lui_ui.Adaptive { light = "#112233"; dark = "#ddeeff" }
    ]
  in
  let expected_tokens =
    `Assoc
      [ "accent", `String "#123456"
      ; "foreground", `Assoc [ "light", `String "#112233"; "dark", `String "#ddeeff" ]
      ]
  in
  let cases =
    [ (fun ~data view -> V.theme ~data view), Ui.Theme.Light, "light", tokens
    ; V.Body.theme, Ui.Theme.Dark, "dark", tokens
    ; V.Viewport.Vertical.theme, Ui.Theme.System, "system", []
    ]
  in
  List.iter
    (fun (apply, mode, expected_mode, tokens) ->
       let data = Ui.Theme.create ~mode ~tokens () in
       let view =
         V.column [ V.text "Theme text"; V.divider () |> V.theme ~data ] |> apply ~data
       in
       with_mounted view (fun _ ops ->
         let ops = ops () in
         let scope =
           List.find_map
             (function
               | Lui_protocol.CreateNode (node, Column) -> Some node
               | _ -> None)
             ops
           |> Option.get
         in
         let properties =
           List.filter_map
             (function
               | Lui_protocol.SetProp (node, ((ThemeValue | ThemeMode) as key), value) ->
                 require (node = scope) "theme property reached an unsupported leaf";
                 Some (key, value)
               | _ -> None)
             ops
         in
         require
           (List.assoc_opt Lui_protocol.ThemeMode properties
            = Some (Lui_protocol.StringValue expected_mode))
           "scoped theme mode was dropped";
         match tokens, List.assoc_opt Lui_protocol.ThemeValue properties with
         | [], None -> ()
         | _ :: _, Some (Lui_protocol.StringValue encoded) ->
           require
             (Yojson.Safe.from_string encoded = expected_tokens)
             "fixed/adaptive theme tokens were dropped or changed"
         | _ -> fail "empty defaults or supplied theme tokens were changed"))
    cases
;;

(* Picker label ownership is in the mounted value-control adapter. Reducer
   selection events cannot reveal a missing accessibility label that makes the
   Apple backend reject the batch before presenting the sheet. *)
let test_status_picker_keeps_accessible_group_and_selection () =
  let selections = ref [] in
  let view =
    V.Picker.create
      ~label:"Task status"
      ~style:Inline
      ~selected_id:(Some 1L)
      ~on_select:
        (Ui.Event.Handler.create (function
           | Ui.Event.Payload.Int64 id -> selections := id :: !selections
           | _ -> fail "status choice lost its typed selection"))
      [ V.Picker.option ~id:1L ~label:(V.text "Todo") ()
      ; V.Picker.option ~id:2L ~label:(V.text "Done") ()
      ; V.Picker.option ~id:3L ~enabled:false ~label:(V.text "Clear") ()
      ]
      ()
  in
  with_mounted view (fun app ops ->
    let ops = ops () in
    let group =
      List.find_map
        (function
          | Lui_protocol.CreateNode (node, RadioGroup) -> Some node
          | _ -> None)
        ops
      |> Option.get
    in
    require
      (List.exists
         (function
           | Lui_protocol.SetProp (node, AccessibilityLabel, StringValue "Task status") ->
             node = group
           | _ -> false)
         ops)
      "Task status group lost its accessible name; Apple rejects this value control";
    let radio title =
      List.find_map
        (function
          | Lui_protocol.SetProp (node, TextValue, StringValue value) when value = title
            -> Some node
          | _ -> None)
        ops
      |> Option.get
    in
    let todo = radio "Todo"
    and done_ = radio "Done"
    and clear = radio "Clear" in
    require
      (List.exists
         (function
           | Lui_protocol.SetProp (node, Checked, BoolValue true) -> node = todo
           | _ -> false)
         ops)
      "status Picker lost its current selection";
    require
      (List.exists
         (function
           | Lui_protocol.SetProp (node, Enabled, BoolValue false) -> node = clear
           | _ -> false)
         ops)
      "status Picker lost its disabled option";
    (* Native Radio uses Change for selecting an unchecked option. A false
       ToggleChanged is deselection, not a new status choice. *)
    ignore (Lui_app.dispatch_event app (Lui_protocol.ToggleChanged (todo, false)));
    ignore (Lui_app.flush app);
    require (!selections = []) "radio deselection executed a status choice";
    ignore (Lui_app.dispatch_event app (Lui_protocol.Change done_));
    ignore (Lui_app.flush app);
    require
      (!selections = [ 2L ])
      "native Radio Change did not execute its typed status selection callback";
    require
      (List.exists
         (function
           | Lui_protocol.SetProp (node, ChangeEnabled, BoolValue true) -> node = done_
           | _ -> false)
         ops)
      "native Radio did not advertise its Change binding")
;;

let has_text ops expected =
  List.exists
    (function
      | Lui_protocol.SetProp (_, TextValue, StringValue value) -> value = expected
      | _ -> false)
    ops
;;

(* Loading layout is owned by the mounted shared component, not a reducer.
   Check its public wire output alongside the source-boundary contract. *)
let test_loading_keeps_indicator_and_message () =
  let cases =
    [ Journal_timeline.loading_view (), "Loading journal", Lui_protocol.Column, true
    ; ( V.loading ~message:"Loading more journal entries" ()
      , "Loading more journal entries"
      , Lui_protocol.Row
      , false )
    ]
  in
  List.iter
    (fun (view, message, container_kind, centered) ->
       with_mounted view (fun _ ops ->
         let ops = ops () in
         let node kind =
           List.find_map
             (function
               | Lui_protocol.CreateNode (node, actual) when actual = kind -> Some node
               | _ -> None)
             ops
           |> Option.get
         in
         let container = node container_kind in
         let spinner = node Lui_protocol.Spinner in
         let text =
           List.find_map
             (function
               | Lui_protocol.SetProp (node, TextValue, StringValue value)
                 when value = message -> Some node
               | _ -> None)
             ops
           |> Option.get
         in
         List.iter
           (fun child ->
              require
                (List.exists
                   (function
                     | Lui_protocol.InsertChild (parent, actual, _) ->
                       parent = container && actual = child
                     | _ -> false)
                   ops)
                "loading indicator and message must share their layout")
           [ spinner; text ];
         if centered
         then
           List.iter
             (fun property ->
                require
                  (List.exists
                     (function
                       | Lui_protocol.SetProp (node, key, StringValue "center") ->
                         node = container && key = property
                       | _ -> false)
                     ops)
                  "initial journal loading must stay centered")
             [ Lui_protocol.MainAlignment; CrossAlignment ]))
    cases
;;

let test_timeline_has_no_chevron () =
  let handler = Ui.Event.Handler.create (fun _ -> ()) in
  let row : Journal_native_collection.row =
    { id = "block:" ^ block_id
    ; section = "20260809"
    ; header = false
    ; slot_index = Some 0
    ; block_id = Some block_id
    }
  in
  let view =
    Journal_native_collection.view
      ~key:(Ui.Key.string "test-list")
      ~test_id:(Ui.Test_id.string "test-list")
      ~rows:[ row ]
      ~scroll_target:None
      ~on_scroll_completed:handler
      ~actions_enabled:true
      ~on_visible_range:handler
      ~on_open:handler
      ~on_status:handler
      ~on_delete:handler
      ~on_copy:handler
      ~children:[ V.text "Body" ]
    |> V.Body.Private.to_widget
  in
  with_mounted view (fun _ ops ->
    require
      (not
         (List.exists
            (function
              | Lui_protocol.SetProp (_, (IconName | InlineIconName), StringValue value)
                when value = "app:chevron-right" -> true
              | _ -> false)
            (ops ())))
      "timeline still draws a trailing chevron")
;;

(* Row-action callback binding is owned by the mounted Native_list wrapper.
   Pure Application events already execute these commands; they cannot recreate
   the missing extension-event -> captured row callback binding. *)
let native_list_node ops =
  List.find_map
    (function
      | Lui_protocol.CreateExtension (node, identifier, _)
        when identifier = Journal_lui_native.list_identifier -> Some node
      | _ -> None)
    (List.rev ops)
  |> Option.get
;;

let dispatch_list_payload app node payload =
  let values =
    Lui_protocol.String_map.empty
    |> Lui_protocol.String_map.add "id" (Lui_protocol.IntValue 0)
    |> Lui_protocol.String_map.add "payload" (Lui_protocol.StringValue payload)
  in
  ignore
    (Lui_app.dispatch_event
       app
       (Lui_protocol.ExtensionEvent
          (node, Journal_lui_native.list_identifier, "event", values)));
  ignore (Lui_app.flush app)
;;

let dispatch_row_action app node row key =
  let payload =
    Yojson.Basic.to_string (`Assoc [ "row", `String row; "key", `String key ])
  in
  dispatch_list_payload
    app
    node
    (Yojson.Basic.to_string
       (`Assoc [ "type", `String "row_event"; "payload", `String payload ]))
;;

let timeline_action_view ~enabled received =
  let handler tag =
    Ui.Event.Handler.create (function
      | Ui.Event.Payload.Text id -> received := (tag, id) :: !received
      | _ -> fail "row action lost its block identity")
  in
  let ignore_event = Ui.Event.Handler.create (fun _ -> ()) in
  Journal_native_collection.view
    ~key:(Ui.Key.string "action-list")
    ~test_id:(Ui.Test_id.string "action-list")
    ~rows:
      [ { Journal_native_collection.id = "block:" ^ block_id
        ; section = "20260809"
        ; header = false
        ; slot_index = Some 0
        ; block_id = Some block_id
        }
      ]
    ~scroll_target:None
    ~on_scroll_completed:ignore_event
    ~actions_enabled:enabled
    ~on_visible_range:ignore_event
    ~on_open:(handler "open")
    ~on_status:(handler "status")
    ~on_delete:(handler "delete")
    ~on_copy:(handler "copy")
    ~children:[ V.text "Action target" ]
  |> V.Body.Private.to_widget
;;

let test_timeline_native_status_delete_callbacks () =
  let received = ref [] in
  with_mounted (timeline_action_view ~enabled:true received) (fun app ops ->
    let node = native_list_node (ops ()) in
    let row = "block:" ^ block_id in
    List.iter (dispatch_row_action app node row) [ "status"; "delete"; "copy" ];
    require
      (List.rev !received = [ "status", block_id; "delete", block_id; "copy", block_id ])
      "Timeline context Status/Delete lost their bound block callbacks";
    received := [];
    List.iter
      (dispatch_row_action app node row)
      [ "status:" ^ block_id; "delete:" ^ block_id ];
    require (!received = []) "retired swipe action still executed";
    let payload =
      List.find_map
        (function
          | Lui_protocol.SetExtensionProp (id, "payload", StringValue value)
            when id = node -> Some (Yojson.Basic.from_string value)
          | _ -> None)
        (ops ())
      |> Option.get
    in
    let open Yojson.Basic.Util in
    let row =
      payload
      |> member "sections"
      |> to_list
      |> List.hd
      |> member "rows"
      |> to_list
      |> List.hd
    in
    require (member "swipe" row = `Null) "Timeline still exposes swipe controls";
    let keys =
      row
      |> member "context_menu"
      |> member "actions"
      |> to_list
      |> List.map (fun action -> action |> member "key" |> to_string)
    in
    require (keys = [ "status"; "delete"; "copy" ]) "Timeline context menu changed")
;;

let test_native_row_actions_ignore_disabled_missing_and_malformed () =
  let received = ref [] in
  List.iter
    (fun enabled ->
       with_mounted (timeline_action_view ~enabled received) (fun app ops ->
         let node = native_list_node (ops ()) in
         let row = "block:" ^ block_id in
         if not enabled
         then
           List.iter
             (dispatch_row_action app node row)
             [ "status"; "delete"; "copy"; "status:" ^ block_id; "delete:" ^ block_id ];
         dispatch_row_action app node "missing-row" "delete";
         dispatch_row_action app node row "retired-action";
         dispatch_list_payload app node {|{"type":"row_event","payload":"invalid json"}|};
         dispatch_list_payload
           app
           node
           {|{"type":"row_event","payload":"{\"row\":4,\"key\":\"delete\"}"}|};
         require (!received = []) "disabled, missing, or malformed row action executed"))
    [ false; true ]
;;

let test_native_nested_row_actions_bind_current_owner () =
  let module N = V.Native_list in
  let received = ref [] in
  let action tag =
    V.Context_menu.action
      ~key:(Ui.Key.string "delete")
      ~title:"Delete"
      ~on_press:(Ui.Event.Handler.create (fun _ -> received := tag :: !received))
      ()
  in
  let row key tag =
    N.row
      ~key:(Ui.Key.string key)
      ~context_menu:(V.Context_menu.create ~actions:[ action tag ] ())
      (V.text tag)
  in
  let parent =
    N.disclosure_row
      ~key:(Ui.Key.string "parent")
      ~expanded:true
      ~on_expanded_changed:
        (Ui.Event.Handler.create (function
           | Ui.Event.Payload.Bool value ->
             received := (if value then "expand" else "collapse") :: !received
           | _ -> fail "disclosure payload lost Bool"))
      ~context_menu:(V.Context_menu.create ~actions:[ action "parent-delete" ] ())
      ~label:(V.text "Parent")
      [ row "child" "child-delete" ]
  in
  let closed =
    N.disclosure_row
      ~key:(Ui.Key.string "closed")
      ~expanded:false
      ~on_expanded_changed:(Ui.Event.Handler.create (fun _ -> ()))
      ~label:(V.text "Closed")
      [ row "hidden-child" "hidden-delete" ]
  in
  let view =
    N.vertical ~style:Plain [ N.section ~key:(Ui.Key.string "nested") [ parent; closed ] ]
  in
  with_mounted view (fun app ops ->
    let node = native_list_node (ops ()) in
    dispatch_row_action app node "hidden-child" "delete";
    dispatch_row_action app node "child" "delete";
    dispatch_row_action app node "parent" "delete";
    dispatch_list_payload app node {|{"type":"expanded","key":"parent","expanded":false}|};
    require
      (List.rev !received = [ "child-delete"; "parent-delete"; "collapse" ])
      "nested row action executed another owner or lost disclosure behavior")
;;

let test_native_retired_row_actions_do_not_execute () =
  let received = ref [] in
  let mounted = ref None in
  let view =
    V.of_lui (fun context parent ->
      let state = Signal.state context.ui_scheduler true in
      mounted := Some state;
      Lui_elements.dyn
        ~equal:Bool.equal
        (fun show ->
           if show
           then Ui.mount (timeline_action_view ~enabled:true received)
           else Lui_elements.column [])
        (Signal.value state)
        context
        parent)
  in
  with_mounted view (fun app ops ->
    let node = native_list_node (ops ()) in
    Signal.set (Option.get !mounted) false;
    ignore (Lui_app.flush app);
    dispatch_row_action app node ("block:" ^ block_id) "delete";
    require (!received = []) "retired List node executed an obsolete callback";
    Signal.set (Option.get !mounted) true;
    ignore (Lui_app.flush app);
    let current = native_list_node (ops ()) in
    require (current <> node) "remount reused retired extension identity";
    dispatch_row_action app current ("block:" ^ block_id) "status";
    require
      (!received = [ "status", block_id ])
      "remounted List lost its current callback")
;;

let test_mounted_input_revisions_remain_independent () =
  let module T = Journal_ids.Text_input in
  let edits = ref [] in
  let handler =
    Ui.Event.Handler.create (function
      | Ui.Event.Payload.Text_edit edit -> edits := edit :: !edits
      | _ -> fail "input callback did not translate text edit")
  in
  let ignored = Ui.Event.Handler.create (fun _ -> ()) in
  let session_id n = T.Session_id.of_int64 n in
  let revision n = T.Local_revision.of_int64 n in
  let document_revision = T.Document_revision.of_int64 9L in
  let value =
    Ui.Text_editing.Value.create
      ~text:""
      ~selection:(Ui.Text_editing.Range.create ~text:"" ~start_utf16:0 ~end_utf16:0)
      ()
  in
  let composer =
    V.composer
      ~placeholder:"Compose"
      ~session_id:(session_id 11L)
      ~document_revision
      ~accepted_local_revision:(revision 4L)
      ~value
      ~send_disabled:false
      ~actions:[]
      ~on_edit:handler
      ~on_submit:ignored
      ~on_send:ignored
      ()
  in
  let password =
    V.secure_field
      ~label:"Password"
      ~session_id:(session_id 12L)
      ~document_revision
      ~accepted_local_revision:(revision 20L)
      ~update_mode:Initiate
      ~value
      ~on_edit:handler
      ~on_submit:ignored
      ~on_focus_changed:ignored
      ()
  in
  with_mounted
    (V.column [ composer; password ])
    (fun app ops ->
       let node kind =
         List.find_map
           (function
             | Lui_protocol.CreateNode (node, actual) when actual = kind -> Some node
             | _ -> None)
           (ops ())
         |> Option.get
       in
       let input node text =
         ignore (Lui_app.dispatch_event app (Lui_protocol.TextChanged (node, text)));
         ignore (Lui_app.flush app)
       in
       input (node Textarea) "中文👩🏽‍💻";
       input (node SecureField) "密碼";
       input (node Textarea) "中文👩🏽‍💻!";
       let observed =
         List.rev_map
           (fun (edit : Ui.Event.Payload.text_edit) ->
              require
                (edit.base_document_revision = document_revision
                 && edit.selection.start_utf16 = 0
                 && edit.selection.end_utf16 = 0
                 && edit.composing = None)
                "input translation changed revision/selection metadata";
              ( T.Session_id.to_int64 edit.session_id
              , T.Local_revision.to_int64 edit.local_revision
              , edit.text ))
           !edits
       in
       require
         (observed = [ 11L, 5L, "中文👩🏽‍💻"; 12L, 21L, "密碼"; 11L, 6L, "中文👩🏽‍💻!" ])
         "simultaneous composer/password mounts shared revisions or changed Unicode text")
;;

let test_long_body_can_expand () =
  let source =
    String.concat
      "\n"
      [ "First line"; "Second line"; "Third line"; "Fourth line retained" ]
  in
  let view =
    Journal_row.view
      ~show_timestamp:false
      ~render_media:(fun ~title:_ ~root:_ ~image_children:_ child -> child)
      { Journal_graph_projection.block =
          block ~source ~task_state:No_status ~child_count:0 ()
      ; child_summaries = []
      }
  in
  with_mounted view (fun app ops ->
    let button =
      List.find_map
        (function
          | Lui_protocol.SetProp (node, TextValue, StringValue "Show more") -> Some node
          | _ -> None)
        (ops ())
    in
    require (Option.is_some button) "long body has no expansion control";
    require
      (List.exists
         (function
           | Lui_protocol.SetProp (_, StyleClass, StringValue "line-clamp-3") -> true
           | _ -> false)
         (ops ()))
      "body is not initially clamped";
    ignore (Lui_app.dispatch_event app (Lui_protocol.Press (Option.get button)));
    ignore (Lui_app.flush app);
    require (has_text (ops ()) "Show less") "expansion did not reveal collapse action";
    ignore (Lui_app.dispatch_event app (Lui_protocol.Press (Option.get button)));
    ignore (Lui_app.flush app);
    let last_label =
      List.find_map
        (function
          | Lui_protocol.SetProp
              (_, TextValue, StringValue (("Show more" | "Show less") as value)) ->
            Some value
          | _ -> None)
        (List.rev (ops ()))
    in
    require
      (last_label = Some "Show more")
      "the native row's retained expansion action must collapse again")
;;

let media_item n file_type presentation size =
  let module A = Logseq_db_types.Asset_descriptor in
  let uuid =
    Logseq_db_types.Graph_types.Uuid.of_string
      (Printf.sprintf "88000000-0000-4000-8000-%012d" n)
    |> Result.get_ok
  in
  let version = A.version ~checksum:(String.make 64 'a') ~file_type |> Result.get_ok in
  let asset =
    A.create
      ~uuid
      ~source:(Managed (Some version))
      ~current_checksum:None
      ~size
      ~dimensions:(if file_type = "jpg" then Some (1200, 800) else None)
    |> Result.get_ok
  in
  { Journal_media_runtime.token = string_of_int n; asset; file_type; presentation }
;;

let seeded_media_store views =
  let store = Journal_media_view.Store.create () in
  List.iter
    (fun (root, view) -> Journal_media_view.Store.update store ~root (Some view))
    views;
  store
;;

let media_view items =
  Journal_media_view.view
    ~scope:"fixture"
    ~root:block_id
    ~store:
      (seeded_media_store
         [ block_id, { Journal_media_runtime.items; more = false; error = None } ])
    ~on_event:(fun _ -> ())
    (V.text "Example body")
;;

let test_detail_media_preserves_rendering_without_asset_actions () =
  let view =
    Journal_media_view.view
      ~scope:"detail-action-removal"
      ~root:block_id
      ~store:
        (seeded_media_store
           [ ( block_id
             , { Journal_media_runtime.items =
                   [ media_item 41 "png" (File "/tmp/existing-image.png") None ]
               ; more = false
               ; error = None
               } )
           ])
      ~on_event:(fun _ -> ())
      (V.text "Existing detail body")
  in
  with_mounted view (fun _ ops ->
    let ops = ops () in
    require
      (has_text ops "Existing detail body")
      "removing media actions lost the detail body";
    List.iter
      (fun label ->
         require
           (not (has_text ops label))
           "removed media action is still mounted: %s"
           label)
      [ "Replace file…"; "Reuse existing…" ];
    require
      (List.exists
         (function
           | Lui_protocol.CreateNode (_, FileImage) -> true
           | _ -> false)
         ops)
      "removing media actions lost existing attachment rendering")
;;

let test_single_image_beside_body () =
  with_mounted
    (media_view [ media_item 1 "jpg" (File "/tmp/portrait.jpg") None ])
    (fun _ ops ->
       let operations = ops () in
       let image =
         List.find_map
           (function
             | Lui_protocol.CreateNode (node, FileImage) -> Some node
             | _ -> None)
           operations
         |> Option.get
       in
       let value property =
         List.find_map
           (function
             | Lui_protocol.SetProp (node, p, value) when node = image && p = property ->
               Some value
             | _ -> None)
           operations
       in
       require
         (value Lui_protocol.WidthValue = Some (Lui_protocol.IntValue 102))
         "single image must be a compact right-hand thumbnail";
       require
         (value Lui_protocol.HeightValue = Some (Lui_protocol.IntValue 102))
         "single thumbnail must have a square frame";
       let parent =
         List.find_map
           (function
             | Lui_protocol.InsertChild (parent, child, _) when child = image ->
               Some parent
             | _ -> None)
           operations
         |> Option.get
       in
       let row =
         List.find_map
           (function
             | Lui_protocol.InsertChild (row, child, _) when child = parent -> Some row
             | _ -> None)
           operations
         |> Option.get
       in
       require
         (List.exists
            (function
              | Lui_protocol.CreateNode (node, Row) -> node = row
              | _ -> false)
            operations)
         "single image and text must share a horizontal row";
       require
         (value Lui_protocol.ImageFitValue = Some (Lui_protocol.StringValue "fill"))
         "thumbnail must use proportional crop")
;;

let test_images_use_lui_gallery_and_preview () =
  let view =
    media_view
      [ media_item 1 "jpg" (File "/tmp/sample-a.jpg") None
      ; media_item 2 "jpg" (File "/tmp/sample-b.jpg") None
      ]
  in
  with_mounted view (fun app ops ->
    let images =
      List.filter_map
        (function
          | Lui_protocol.CreateNode (node, FileImage) -> Some node
          | _ -> None)
        (ops ())
    in
    List.iter
      (fun image ->
         require
           (List.exists
              (function
                | Lui_protocol.SetProp (node, WidthValue, IntValue 190) -> node = image
                | _ -> false)
              (ops ()))
           "gallery tiles must be 190pt wide";
         require
           (List.exists
              (function
                | Lui_protocol.SetProp (node, HeightValue, IntValue 90) -> node = image
                | _ -> false)
              (ops ()))
           "gallery tiles must be compact 90pt high")
      images;
    require (List.length images = 2) "real images do not use LUI file_image";
    require
      (List.exists
         (function
           | Lui_protocol.SetProp (_, OrientationValue, StringValue "horizontal") -> true
           | _ -> false)
         (ops ()))
      "multi-image strip is not horizontal";
    ignore (Lui_app.dispatch_event app (Lui_protocol.Press (List.hd images)));
    ignore (Lui_app.flush app);
    require
      (List.exists
         (function
           | Lui_protocol.CreateExtension (_, "journal-image-preview", _) -> true
           | _ -> false)
         (ops ()))
      "image press did not open native image group preview")
;;

let test_file_cards_use_actual_metadata () =
  let view =
    media_view
      [ media_item 1 "pdf" (File "/tmp/opaque-cache-hash") (Some 1_800_000L)
      ; media_item 2 "txt" (File "/tmp/another-cache-hash") None
      ]
  in
  with_mounted view (fun _ ops ->
    require (has_text (ops ()) "PDF attachment") "file type fallback is absent";
    require (has_text (ops ()) "PDF · 1.8 MB") "known size is absent";
    require (has_text (ops ()) "TXT") "unknown size should leave only type";
    require
      (not (has_text (ops ()) "opaque-cache-hash"))
      "cache basename was used as filename";
    require (not (has_text (ops ()) "TXT · 0 B")) "unknown size was fabricated")
;;

let test_attachment_unavailable_keeps_retry () =
  with_mounted
    (media_view [ media_item 1 "jpg" (Failed "Not downloaded") None ])
    (fun _ ops ->
       require
         (has_text (ops ()) "Not downloaded" && has_text (ops ()) "Retry")
         "unavailable image lost its real placeholder or retry")
;;

let test_empty_media_has_no_attachment_chrome () =
  with_mounted (media_view []) (fun _ ops ->
    require
      (not
         (List.exists
            (function
              | Lui_protocol.CreateNode (_, (FileImage | FilePreview | Scroll)) -> true
              | _ -> false)
            (ops ())))
      "empty media created attachment layout")
;;

let test_status_and_tags_mount () =
  let block =
    Journal_model.with_tag_titles (block ~task_state:Doing ()) ~tag_titles:[ "阅读"; "工作" ]
  in
  let view =
    Journal_row.view
      ~show_timestamp:false
      ~render_media:(fun ~title:_ ~root:_ ~image_children:_ child -> child)
      { Journal_graph_projection.block; child_summaries = [] }
  in
  with_mounted view (fun _ ops ->
    require (has_text (ops ()) "Doing") "status must mount using supported LUI nodes";
    require (has_text (ops ()) "#阅读  #工作") "named tags must accompany status")
;;

let test_reference_body_and_summary () =
  let target = "20000000-0000-4000-a000-000000000099" in
  let token = "[[" ^ target ^ "]]" in
  let source = String.concat "\n" [ "Resolved 中文"; "Second"; "Third"; "Fourth" ] in
  let entry =
    { Journal_graph_projection.block = block ~source:token ~task_state:No_status ()
    ; child_summaries =
        [ { block_id = "visible-child"
          ; source = "child " ^ token
          ; asset_file_type = None
          }
        ]
    }
  in
  let render_source =
    Journal_model.render_references ~lookup:(fun id ->
      if id = target then Some source else None)
  in
  let view =
    Journal_row.view
      ~render_source
      ~show_timestamp:false
      ~render_media:(fun ~title:_ ~root:_ ~image_children:_ child -> child)
      entry
  in
  with_mounted view (fun _ ops ->
    require (has_text (ops ()) source) "root reference did not mount resolved content";
    require
      (has_text (ops ()) ("child " ^ source))
      "summary reference did not mount resolved content";
    require (has_text (ops ()) "Show more") "resolved long content did not clamp";
    require
      (Journal_model.source entry.block = token)
      "rendering changed persisted source")
;;

(* Valid graph input reproduces the discarded image classification and the
   resulting composition at the narrow mounted production boundary. *)
module Graph = Logseq_db_types.Graph_types

let graph_node ?file_type ?(order = "a") ~id ~parent title =
  let uuid = Graph.Uuid.of_string id |> require_ok in
  let properties =
    match file_type with
    | None -> []
    | Some value ->
      [ Graph.
          { ident = "logseq.property.asset/type"
          ; uuid = Graph.Uuid.of_string mutation_id |> require_ok
          ; title = "Asset type"
          ; schema =
              { property_type = String; cardinality = One; hidden = true; public = false }
          ; values = [ String_value value ]
          ; values_truncated = false
          }
      ]
  in
  Graph.
    { uuid
    ; parent = Uuid.of_string parent |> require_ok
    ; page = Uuid.of_string page_id |> require_ok
    ; title
    ; order
    ; created_at_ms = Journal_time.instant_unix_ms creation_time
    ; updated_at_ms = Journal_time.instant_unix_ms creation_time
    ; refs = []
    ; tags = []
    ; properties
    }
;;

let projected_entry nodes =
  let items =
    List.map
      (fun (depth, block) ->
         { Journal_graph_projection.block; depth; revision = "test-revision" })
      nodes
  in
  let result =
    Journal_graph_projection.timeline_entry_page
      ~page:{ id = page_id; day = 20260809; title = "Example journal" }
      ~time_context:{ localtime = Unix.gmtime }
      { items; continuation = None }
    |> require_ok
  in
  require (List.length result.entries = 1) "image parent disappeared from projection";
  List.hd result.entries
;;

let asset_id (item : Journal_media_runtime.item) = Graph.Uuid.to_string item.asset.uuid
let media_state items = { Journal_media_runtime.items; more = false; error = None }

let projected_row ?store ~views ~on_event entry =
  let store =
    match store with
    | Some store -> store
    | None -> seeded_media_store views
  in
  Journal_row.view
    ~show_timestamp:false
    ~render_media:(fun ~title ~root ~image_children child ->
      Journal_media_view.row
        ~store
        ~title
        ~scope:"direct-child-regression"
        ~root
        ~image_children
        ~on_event
        child)
    entry
;;

let image_paths ops =
  let images =
    List.filter_map
      (function
        | Lui_protocol.CreateNode (node, FileImage) -> Some node
        | _ -> None)
      ops
  in
  List.filter_map
    (function
      | Lui_protocol.SetProp (node, PathValue, StringValue path) when List.mem node images
        -> Some path
      | _ -> None)
    ops
;;

let child_gallery_fixture ?(source = "Parent prose") ?(duplicates = false) () =
  let first = media_item 71 "png" (File "/tmp/synthetic-first.png") None in
  let second = media_item 72 "jpg" (File "/tmp/synthetic-second.jpg") None in
  let pdf = media_item 73 "pdf" (File "/tmp/synthetic-plan.pdf") (Some 32476L) in
  let deeper = media_item 74 "png" (File "/tmp/synthetic-deeper.png") None in
  let plain_id = "20000000-0000-4000-a000-000000000075" in
  let entry =
    projected_entry
      [ 0, graph_node ~id:block_id ~parent:page_id source
      ; ( 1
        , graph_node
            ~file_type:"jpg"
            ~order:"b"
            ~id:(asset_id second)
            ~parent:block_id
            "asset-portrait.jpg" )
      ; ( 1
        , graph_node
            ~file_type:"PNG"
            ~order:"a"
            ~id:(asset_id first)
            ~parent:block_id
            "camera.png" )
      ; 1, graph_node ~order:"c" ~id:plain_id ~parent:block_id "photo.png"
      ; ( 1
        , graph_node
            ~file_type:"pdf"
            ~order:"d"
            ~id:(asset_id pdf)
            ~parent:block_id
            "plan.pdf" )
      ; 2, graph_node ~file_type:"png" ~id:(asset_id deeper) ~parent:plain_id "deep.png"
      ]
  in
  let views =
    [ asset_id first, media_state [ first ]
    ; asset_id second, media_state [ second ]
    ; asset_id pdf, media_state [ pdf ]
    ; asset_id deeper, media_state [ deeper ]
    ]
  in
  let views =
    if duplicates then (block_id, media_state [ second; first ]) :: views else views
  in
  entry, views, first, second
;;

let test_direct_image_children_share_parent_gallery () =
  let entry, views, _, _ = child_gallery_fixture ~duplicates:true () in
  with_mounted (projected_row ~views ~on_event:ignore entry) (fun app ops ->
    let initial = ops () in
    require (has_text initial "Parent prose") "parent prose was hidden";
    require (not (has_text initial "camera.png")) "image asset title leaked into prose";
    require
      (not (has_text initial "asset-portrait.jpg"))
      "portrait asset title leaked into prose";
    require (has_text initial "photo.png") "ordinary note named photo.png was hidden";
    require (has_text initial "plan.pdf") "non-image asset title was hidden";
    require (has_text initial "PDF attachment") "file attachment card was removed";
    require
      (image_paths initial = [ "/tmp/synthetic-first.png"; "/tmp/synthetic-second.jpg" ])
      "direct gallery lost sibling order, repeated parent references, or included \
       grandchildren";
    let images =
      List.filter_map
        (function
          | Lui_protocol.CreateNode (node, FileImage) -> Some node
          | _ -> None)
        initial
    in
    List.iter
      (fun node ->
         require
           (List.exists
              (function
                | Lui_protocol.SetProp (n, WidthValue, IntValue 190) -> n = node
                | _ -> false)
              initial)
           "aggregated child did not use gallery tile width";
         require
           (List.exists
              (function
                | Lui_protocol.SetProp (n, ImageFitValue, StringValue "fill") -> n = node
                | _ -> false)
              initial)
           "gallery tile did not preserve proportional crop")
      images;
    require
      (List.exists
         (function
           | Lui_protocol.SetProp (_, OrientationValue, StringValue "horizontal") -> true
           | _ -> false)
         initial)
      "direct children did not share a horizontal gallery";
    ignore (Lui_app.dispatch_event app (Lui_protocol.Press (List.nth images 1)));
    ignore (Lui_app.flush app);
    let preview =
      List.find_map
        (function
          | Lui_protocol.CreateExtension (node, "journal-image-preview", _) -> Some node
          | _ -> None)
        (ops ())
    in
    require (Option.is_some preview) "gallery child press did not open native preview";
    require
      (List.exists
         (function
           | Lui_protocol.SetExtensionProp (node, "payload", StringValue json) ->
             Some node = preview
             && Yojson.Safe.Util.member "selected_index" (Yojson.Safe.from_string json)
                = `Int 1
           | _ -> false)
         (ops ()))
      "gallery preview selected a different child")
;;

let test_image_children_load_without_title_flash () =
  let entry, views, first, second = child_gallery_fixture () in
  let initial_entry =
    projected_entry
      [ 0, graph_node ~id:block_id ~parent:page_id "Parent prose"
      ; 1, graph_node ~file_type:"png" ~id:(asset_id first) ~parent:block_id "camera.png"
      ]
  in
  let events = ref [] in
  let current = ref None in
  let slot = Signal.state_slot "child-gallery-late-fixture" in
  let view =
    V.of_lui (fun context parent ->
      let state =
        Signal.state_at
          context.ui_scheduler
          context.ui_state_scope
          slot
          (initial_entry, [])
      in
      current := Some state;
      Lui_elements.dyn
        ~equal:( = )
        (fun (entry, views) ->
           Ui.mount
             (projected_row
                ~views
                ~on_event:(fun event -> events := event :: !events)
                entry))
        (Signal.value state)
        context
        parent)
  in
  let columns operations =
    List.filter_map
      (function
        | Lui_protocol.CreateNode (node, Column) -> Some node
        | _ -> None)
      operations
  in
  let root_requested id =
    List.exists
      (fun (event : Journal_media_view.event) -> event.action = Root && event.root = id)
      !events
  in
  with_mounted view (fun app ops ->
    require
      (not (has_text (ops ()) "camera.png"))
      "image filename flashed before media query completed";
    let initial_columns = columns (ops ()) in
    List.iter
      (fun node -> ignore (Lui_app.dispatch_event app (Lui_protocol.Appear node)))
      initial_columns;
    ignore (Lui_app.flush app);
    require
      (root_requested (asset_id first))
      "first hidden image child was not discovered";
    events := [];
    Signal.set (Option.get !current) (entry, []);
    ignore (Lui_app.flush app);
    require
      (not (has_text (ops ()) "asset-portrait.jpg"))
      "late child title flashed before its media query completed";
    let new_columns =
      List.filter (fun node -> not (List.mem node initial_columns)) (columns (ops ()))
    in
    (* The host sends appearance only for newly mounted children. Retained
       parent columns do not get another onAppear when children arrive. *)
    List.iter
      (fun node -> ignore (Lui_app.dispatch_event app (Lui_protocol.Appear node)))
      new_columns;
    ignore (Lui_app.flush app);
    require
      (root_requested (asset_id second))
      "lazy child arrival relied on a second parent appearance";
    Signal.set (Option.get !current) (entry, views);
    ignore (Lui_app.flush app);
    require
      (image_paths (ops ()) = [ "/tmp/synthetic-first.png"; "/tmp/synthetic-second.jpg" ])
      "late image metadata did not produce ordered gallery";
    let image =
      List.find_map
        (function
          | Lui_protocol.SetProp (node, PathValue, StringValue "/tmp/synthetic-first.png")
            -> Some node
          | _ -> None)
        (ops ())
      |> Option.get
    in
    events := [];
    ignore (Lui_app.dispatch_event app (Lui_protocol.Appear image));
    ignore (Lui_app.flush app);
    require
      (List.exists
         (fun (event : Journal_media_view.event) ->
            event.action = Asset && event.root = asset_id first)
         !events)
      "aggregated image download event was routed to its parent instead of owner")
;;

let test_empty_parent_keeps_direct_images () =
  let entry, views, _, _ = child_gallery_fixture ~source:"" () in
  with_mounted (projected_row ~views ~on_event:ignore entry) (fun _ ops ->
    require (List.length (image_paths (ops ())) = 2) "empty parent lost image gallery";
    require
      (not (has_text (ops ()) "camera.png"))
      "empty parent substituted asset filename as prose")
;;

let test_top_image_asset_has_no_filename_body () =
  let image = media_item 81 "png" (File "/tmp/synthetic-root.png") None in
  let entry =
    projected_entry
      [ 0, graph_node ~file_type:"png" ~id:(asset_id image) ~parent:page_id "camera.png" ]
  in
  with_mounted
    (projected_row
       ~views:[ asset_id image, media_state [ image ] ]
       ~on_event:ignore
       entry)
    (fun _ ops ->
       require
         (not (has_text (ops ()) "camera.png"))
         "top-level image asset filename is prose";
       require
         (image_paths (ops ()) = [ "/tmp/synthetic-root.png" ])
         "top image asset was hidden with its title")
;;

(* Availability is runtime state, but the frame contract is owned by the public
   row renderer and graph image metadata, not the download reducer. *)
let check_stable_image_slots ~entry ~images ~width ~height =
  let current = ref None in
  let slot = Signal.state_slot "stable-image-slot-fixture" in
  let views presentation count =
    images
    |> List.mapi (fun index item ->
      ( asset_id item
      , media_state (if index < count then [ { item with presentation } ] else []) ))
  in
  let view =
    V.of_lui (fun context parent ->
      let state = Signal.state_at context.ui_scheduler context.ui_state_scope slot [] in
      current := Some state;
      Lui_elements.dyn
        ~equal:( = )
        (fun views -> Ui.mount (projected_row ~views ~on_event:ignore entry))
        (Signal.value state)
        context
        parent)
  in
  with_mounted view (fun app ops ->
    let slot_nodes operations =
      List.filter_map
        (function
          | Lui_protocol.SetProp (node, AccessibilityIdentifier, StringValue name)
            when String.starts_with ~prefix:"journal-image-slot:" name -> Some (name, node)
          | _ -> None)
        operations
    in
    let initial = slot_nodes (ops ()) in
    require
      (List.length initial = List.length images)
      "known image graph metadata must reserve final slots before descriptors arrive";
    List.iter
      (fun item ->
         require
           (List.mem_assoc ("journal-image-slot:" ^ asset_id item) initial)
           "reserved slot lost graph asset identity")
      images;
    let check () =
      let operations = ops () in
      let dropped = dropped_wire_nodes operations in
      List.iter
        (fun (_, node) ->
           let prop property =
             List.fold_left
               (fun value -> function
                  | Lui_protocol.SetProp (id, p, v) when id = node && p = property ->
                    Some v
                  | Lui_protocol.RemoveProp (id, p) when id = node && p = property -> None
                  | _ -> value)
               None
               operations
           in
           require
             (prop WidthValue = Some (IntValue width)
              && prop HeightValue = Some (IntValue height))
             "image availability changed the final slot dimensions";
           require
             (not (Hashtbl.mem dropped node))
             "image availability replaced a reserved slot")
        initial
    in
    check ();
    List.iter
      (fun next ->
         Signal.set (Option.get !current) next;
         ignore (Lui_app.flush app);
         check ())
      [ views (Placeholder "Waiting for file") 1
      ; views (Placeholder "Opening file") (List.length images)
      ; views (File "/tmp/synthetic-first.png") 1
      ; views (File "/tmp/synthetic-first.png") (List.length images)
      ; views Hidden (List.length images)
      ; []
      ; views (Placeholder "Retrying file") (List.length images)
      ; views (File "/tmp/synthetic-first.png") (List.length images)
      ])
;;

let test_known_single_slot_survives_availability () =
  let first = media_item 91 "png" Hidden None in
  let entry =
    projected_entry
      [ 0, graph_node ~id:block_id ~parent:page_id "Short body"
      ; 1, graph_node ~file_type:"png" ~id:(asset_id first) ~parent:block_id "camera.png"
      ]
  in
  check_stable_image_slots ~entry ~images:[ first ] ~width:102 ~height:102
;;

let test_known_root_slot_survives_availability () =
  let first = media_item 92 "png" Hidden None in
  let entry =
    projected_entry
      [ 0, graph_node ~file_type:"png" ~id:(asset_id first) ~parent:page_id "camera.png" ]
  in
  check_stable_image_slots ~entry ~images:[ first ] ~width:102 ~height:102
;;

let test_known_gallery_slots_survive_separate_arrivals () =
  let entry, _, first, second = child_gallery_fixture () in
  check_stable_image_slots ~entry ~images:[ first; second ] ~width:190 ~height:90
;;

let test_native_list_payload_binds_nested_contents () =
  let module N = V.Native_list in
  let row key = N.row ~key:(Ui.Key.string key) (V.text key) in
  let nested =
    N.disclosure_row
      ~key:(Ui.Key.string "parent")
      ~expanded:true
      ~on_expanded_changed:(Ui.Event.Handler.create (fun _ -> ()))
      ~label:(V.text "parent")
      [ row "child-a"; row "child-b" ]
  in
  let view =
    N.vertical
      ~style:Plain
      [ N.section
          ~key:(Ui.Key.string "first")
          ~header:(V.text "first-header")
          ~footer:(V.text "first-footer")
          [ row "first-row"; nested ]
      ; N.section
          ~key:(Ui.Key.string "second")
          ~header:(V.text "second-header")
          [ row "second-row" ]
      ]
  in
  with_mounted view (fun _ ops ->
    let ops = ops () in
    let list_node =
      List.find_map
        (function
          | Lui_protocol.CreateExtension (node, identifier, _)
            when identifier = Journal_lui_native.list_identifier -> Some node
          | _ -> None)
        ops
      |> Option.get
    in
    let payload =
      List.find_map
        (function
          | Lui_protocol.SetExtensionProp (node, "payload", StringValue value)
            when node = list_node -> Some (Yojson.Basic.from_string value)
          | _ -> None)
        ops
      |> Option.get
    in
    let member key = function
      | `Assoc fields -> List.assoc key fields
      | _ -> fail "expected list payload object"
    in
    let children =
      List.filter_map
        (function
          | Lui_protocol.InsertChild (parent, child, index) when parent = list_node ->
            Some (index, child)
          | _ -> None)
        ops
    in
    let text_at = function
      | `Int index ->
        let child = List.assoc index children in
        List.find_map
          (function
            | Lui_protocol.SetProp (node, TextValue, StringValue value) when node = child
              -> Some value
            | _ -> None)
          ops
        |> Option.get
      | _ -> fail "expected mounted content index"
    in
    let rec check_row row =
      let key = member "key" row in
      require
        (key = `String (text_at (member "content_index" row)))
        "row index bound another row's content";
      match member "type" row with
      | `String "disclosure" ->
        (match member "children" row with
         | `List rows -> List.iter check_row rows
         | _ -> fail "expected disclosure children")
      | _ -> ()
    in
    match member "sections" payload with
    | `List sections ->
      List.iter
        (fun section ->
           let key = member "key" section in
           (match key with
            | `String key ->
              require
                (text_at (member "header_index" section) = key ^ "-header")
                "section header bound another child"
            | _ -> fail "expected section key");
           (match member "footer_index" section with
            | `Null -> ()
            | index ->
              require
                (text_at index = "first-footer")
                "section footer bound another child");
           match member "rows" section with
           | `List rows -> List.iter check_row rows
           | _ -> fail "expected section rows")
        sections
    | _ -> fail "expected list sections")
;;

(* The Store subscription lifetime and the mounted component composition have
   no pure reducer owner. Exercise their public APIs with valid runtime views;
   transfer requests and leases remain covered by their state owners. *)
let mounted_nodes ops property expected =
  let values = Hashtbl.create 64 in
  let track_teardown = track_wire_teardown (Hashtbl.remove values) in
  List.iter
    (fun op ->
       track_teardown op;
       match op with
       | Lui_protocol.SetProp (node, key, value) when key = property ->
         Hashtbl.replace values node value
       | Lui_protocol.RemoveProp (node, key) when key = property ->
         Hashtbl.remove values node
       | _ -> ())
    ops;
  Hashtbl.fold
    (fun node value nodes -> if value = expected then node :: nodes else nodes)
    values
    []
;;

let mounted_node ops property expected =
  match mounted_nodes ops property expected with
  | [ node ] -> node
  | nodes -> fail "expected one current node, found %d" (List.length nodes)
;;

let current_text ops text =
  mounted_nodes ops Lui_protocol.TextValue (Lui_protocol.StringValue text) <> []
;;

let require_nodes_retained nodes operations =
  let dropped = dropped_wire_nodes operations in
  List.iter
    (fun node ->
       require
         (not (Hashtbl.mem dropped node))
         "item presentation dropped an unaffected body, slot, or sibling node")
    nodes
;;

let test_reactive_child_gallery_routes_and_preserves_siblings () =
  let module Store = Journal_media_view.Store in
  let entry, views, first, second = child_gallery_fixture ~duplicates:true () in
  let store = Store.create () in
  List.iter (fun (root, view) -> Store.update store ~root (Some view)) views;
  let events = ref [] in
  with_mounted
    (projected_row
       ~store
       ~views
       ~on_event:(fun event -> events := event :: !events)
       entry)
    (fun app ops ->
       let node key value = mounted_node (ops ()) key (Lui_protocol.StringValue value) in
       let first_slot =
         node AccessibilityIdentifier ("journal-image-slot:" ^ asset_id first)
       in
       let second_slot =
         node AccessibilityIdentifier ("journal-image-slot:" ^ asset_id second)
       in
       let body = node TextValue "Parent prose" in
       let sibling = node PathValue "/tmp/synthetic-second.jpg" in
       let assert_event owner token =
         events := [];
         let image = node AccessibilityIdentifier ("journal-media:" ^ token) in
         ignore (Lui_app.dispatch_event app (Lui_protocol.Appear image));
         ignore (Lui_app.flush app);
         require
           (List.exists
              (fun (event : Journal_media_view.event) ->
                 event.action = Asset && event.root = owner && event.asset = token)
              !events)
           "gallery appearance used an obsolete parent/child descriptor owner"
       in
       assert_event (asset_id first) first.token;
       List.iter
         (fun presentation ->
            Store.update
              store
              ~root:(asset_id first)
              (Some (media_state [ { first with presentation } ]));
            ignore (Lui_app.flush app);
            require_nodes_retained [ first_slot; second_slot; body; sibling ] (ops ());
            require
              (node AccessibilityIdentifier ("journal-image-slot:" ^ asset_id first)
               = first_slot)
              "availability replaced its reserved image slot";
            require
              (node PathValue "/tmp/synthetic-second.jpg" = sibling)
              "availability replaced the sibling image")
         [ Journal_media.Hidden
         ; Placeholder "Opening file"
         ; File "/tmp/reactive-child.png"
         ];
       assert_event (asset_id first) first.token;
       (* Removing a child descriptor rebinds the slot to an existing parent
         reference. Restoring it must restore its own event/Store subscription. *)
       Store.update store ~root:(asset_id first) None;
       ignore (Lui_app.flush app);
       assert_event block_id first.token;
       let rebound =
         { first with
           token = "child-rebound"
         ; presentation = Journal_media.File "/tmp/rebound-child.png"
         }
       in
       Store.update store ~root:(asset_id first) (Some (media_state [ rebound ]));
       ignore (Lui_app.flush app);
       assert_event (asset_id first) rebound.token;
       Store.update
         store
         ~root:block_id
         (Some
            (media_state
               [ { first with presentation = File "/tmp/parent-only.png" }; second ]));
       ignore (Lui_app.flush app);
       require
         (mounted_nodes (ops ()) PathValue (StringValue "/tmp/parent-only.png") = [])
         "parent duplicate overrode the child's own descriptor";
       Store.update
         store
         ~root:(asset_id first)
         (Some
            (media_state
               [ { rebound with presentation = File "/tmp/rebound-current.png" } ]));
       ignore (Lui_app.flush app);
       ignore (node PathValue "/tmp/rebound-current.png");
       require
         (mounted_nodes (ops ()) PathValue (StringValue "/tmp/rebound-child.png") = [])
         "rebound item kept an obsolete file path";
       (* Actual structure removal/addition retains the graph-known gallery slot. *)
       Store.update store ~root:block_id (Some (media_state [ second ]));
       Store.update store ~root:(asset_id first) None;
       ignore (Lui_app.flush app);
       require
         (mounted_nodes
            (ops ())
            AccessibilityIdentifier
            (StringValue ("journal-image-slot:" ^ asset_id first))
          <> [])
         "descriptor removal lost the graph-known gallery slot";
       require
         (mounted_nodes (ops ()) PathValue (StringValue "/tmp/rebound-current.png") = [])
         "descriptor removal kept a stale file";
       Store.update store ~root:(asset_id first) (Some (media_state [ first ]));
       ignore (Lui_app.flush app);
       assert_event (asset_id first) first.token)
;;

let test_reactive_nonimage_structure_and_presentation () =
  let module Store = Journal_media_view.Store in
  let pdf = media_item 111 "pdf" (Placeholder "Waiting for file") (Some 32476L) in
  let txt = media_item 112 "txt" (File "/tmp/reactive-notes.txt") None in
  let store = Store.create () in
  Store.update store ~root:block_id (Some (media_state [ pdf ]));
  let view =
    Journal_media_view.view
      ~store
      ~scope:"reactive-files"
      ~root:block_id
      ~on_event:ignore
      (V.text "Persistent file body")
  in
  with_mounted
    (V.column [ view; V.text "Unaffected outer sibling" ])
    (fun app ops ->
       let body = mounted_node (ops ()) TextValue (StringValue "Persistent file body") in
       let sibling =
         mounted_node (ops ()) TextValue (StringValue "Unaffected outer sibling")
       in
       let update view =
         Store.update store ~root:block_id view;
         ignore (Lui_app.flush app)
       in
       update
         (Some (media_state [ { pdf with presentation = File "/tmp/reactive-plan.pdf" } ]));
       require
         (current_text (ops ()) "PDF attachment")
         "PDF readiness did not render its file card";
       require
         (current_text (ops ()) "PDF · 32.5 KB")
         "PDF card lost actual descriptor metadata";
       require_nodes_retained [ body; sibling ] (ops ());
       update
         (Some (media_state [ { pdf with presentation = Failed "Unable to open file" } ]));
       require
         (current_text (ops ()) "Unable to open file" && current_text (ops ()) "Retry")
         "nonimage failure lost its current message or retry action";
       require
         (not (current_text (ops ()) "PDF attachment"))
         "nonimage failure kept its old file card";
       update
         (Some
            { (media_state [ pdf; txt ]) with
              more = true
            ; error = Some "Metadata unavailable"
            });
       require
         (current_text (ops ()) "TXT attachment"
          && current_text (ops ()) "Next attachments"
          && current_text (ops ()) "Metadata unavailable")
         "structure addition lost file/pagination/error chrome";
       let rebound =
         { pdf with token = "pdf-rebound"; presentation = File "/tmp/new-plan.pdf" }
       in
       update (Some (media_state [ rebound ]));
       require
         ((not (current_text (ops ()) "TXT attachment"))
          && (not (current_text (ops ()) "Next attachments"))
          && not (current_text (ops ()) "Metadata unavailable"))
         "structure removal retained old chrome";
       update
         (Some
            (media_state [ { rebound with presentation = Placeholder "Opening file" } ]));
       require
         (current_text (ops ()) "Opening file")
         "replacement token did not get a fresh item subscription";
       update None;
       require
         ((not (current_text (ops ()) "Opening file"))
          && not (current_text (ops ()) "Retry"))
         "empty structure kept an attachment item";
       require
         (current_text (ops ()) "Persistent file body"
          && current_text (ops ()) "Unaffected outer sibling")
         "empty structure lost the block body or outside sibling")
;;

let test_reactive_media_subscription_disposal_and_epoch () =
  let module Store = Journal_media_view.Store in
  let counts = Hashtbl.create 8 in
  let observe name =
    Hashtbl.replace
      counts
      name
      (1 + Option.value (Hashtbl.find_opt counts name) ~default:0)
  in
  let count name = Option.value (Hashtbl.find_opt counts name) ~default:0 in
  let store = Store.create ~observe () in
  let item = media_item 121 "png" (File "/tmp/lifetime-a.png") None in
  Store.update store ~root:block_id (Some (media_state [ item ]));
  let mounted = ref None in
  let view =
    V.of_lui (fun context parent ->
      let state = Signal.state context.ui_scheduler true in
      mounted := Some state;
      Lui_elements.dyn
        ~equal:Bool.equal
        (fun show ->
           if show
           then
             Ui.mount
               (Journal_media_view.view
                  ~store
                  ~on_region:observe
                  ~scope:"lifetime"
                  ~root:block_id
                  ~on_event:ignore
                  (V.text "Lifetime body"))
           else Lui_elements.column [])
        (Signal.value state)
        context
        parent)
  in
  with_mounted view (fun app ops ->
    let update item =
      Store.update store ~root:block_id (Some (media_state [ item ]));
      ignore (Lui_app.flush app)
    in
    let toggle show =
      Signal.set (Option.get !mounted) show;
      ignore (Lui_app.flush app)
    in
    toggle false;
    Hashtbl.clear counts;
    update { item with presentation = File "/tmp/while-unmounted.png" };
    require
      (count "media-item-notify" = 0
       && count "media-structure-notify" = 0
       && count "media-item-build" = 0
       && count "media-structure-build" = 0)
      "disposed media scope still had an active subscriber";
    toggle true;
    require
      (mounted_nodes (ops ()) PathValue (StringValue "/tmp/while-unmounted.png") <> [])
      "same-root remount did not read the latest Store item";
    Hashtbl.clear counts;
    update { item with presentation = File "/tmp/lifetime-b.png" };
    require
      (count "media-item-notify" = 1 && count "media-item-build" = 1)
      "same-root remount kept duplicate or missing subscribers";
    Store.reset store;
    Hashtbl.clear counts;
    update { item with presentation = File "/tmp/old-epoch-hidden.png" };
    require
      (count "media-item-notify" = 0 && count "media-structure-notify" = 0)
      "reset did not fence previous-epoch subscribers";
    toggle false;
    toggle true;
    Hashtbl.clear counts;
    update { item with presentation = File "/tmp/new-epoch-current.png" };
    require
      (count "media-item-notify" = 1 && count "media-item-build" = 1)
      "new epoch remount kept obsolete subscribers";
    require
      (mounted_nodes (ops ()) PathValue (StringValue "/tmp/new-epoch-current.png") <> [])
      "new epoch item did not reach the mounted file image")
;;

(* Preview composition is owned by the mounted media view, rather than a pure
   reducer. Drive public Press/extension events and Store updates at that boundary. *)
let gallery_preview ops =
  let node =
    List.find_map
      (function
        | Lui_protocol.CreateExtension (node, "journal-image-preview", _) -> Some node
        | _ -> None)
      ops
  in
  Option.bind node (fun node ->
    List.find_map
      (function
        | Lui_protocol.SetExtensionProp (id, "payload", StringValue json) when id = node
          -> Some (node, Yojson.Safe.from_string json)
        | _ -> None)
      (List.rev ops))
;;

let test_gallery_preview_order_selection_and_leases () =
  let entry, views, first, second = child_gallery_fixture ~duplicates:true () in
  let events = ref [] in
  let store = seeded_media_store views in
  with_mounted
    (projected_row
       ~store
       ~views
       ~on_event:(fun event -> events := event :: !events)
       entry)
    (fun app ops ->
       let image =
         mounted_node (ops ()) PathValue (StringValue "/tmp/synthetic-second.jpg")
       in
       ignore (Lui_app.dispatch_event app (Press image));
       ignore (Lui_app.flush app);
       let node, payload =
         match gallery_preview (ops ()) with
         | Some preview -> preview
         | None -> fail "multi-image press did not mount the native image preview"
       in
       let open Yojson.Safe.Util in
       require
         (member "paths" payload
          = `List
              [ `String "/tmp/synthetic-first.png"; `String "/tmp/synthetic-second.jpg" ]
         )
         "preview did not preserve displayed order or included PDF/grandchildren";
       require
         (member "selected_index" payload = `Int 1)
         "preview must start at the clicked image";
       let held =
         List.filter
           (fun (event : Journal_media_view.event) ->
              event.action = Preview && event.visible)
           !events
       in
       require (List.length held = 2) "preview must retain both image leases";
       require
         (List.map (fun (e : Journal_media_view.event) -> e.root) (List.rev held)
          = [ asset_id first; asset_id second ])
         "preview lease owner must be the asset's source row";
       require
         (List.length
            (List.sort_uniq
               String.compare
               (List.map (fun (e : Journal_media_view.event) -> e.slot) held))
          = 2)
         "gallery lease slots must not replace each other";
       events := [];
       let values =
         Lui_protocol.String_map.empty
         |> Lui_protocol.String_map.add "id" (Lui_protocol.IntValue 1)
         |> Lui_protocol.String_map.add
              "payload"
              (Lui_protocol.StringValue {|{"type":"dismiss"}|})
       in
       ignore
         (Lui_app.dispatch_event
            app
            (ExtensionEvent (node, "journal-image-preview", "event", values)));
       ignore (Lui_app.flush app);
       require
         (List.length
            (List.filter
               (fun (event : Journal_media_view.event) ->
                  event.action = Preview && not event.visible)
               !events)
          = 2)
         "closing preview must release all gallery references")
;;

let test_gallery_preview_filters_unavailable_and_closes_on_retirement () =
  let ready = media_item 81 "png" (File "/tmp/ready.png") None in
  let other = media_item 82 "jpg" (File "/tmp/other.jpg") None in
  let items =
    [ ready
    ; media_item 83 "pdf" (File "/tmp/document.pdf") None
    ; media_item 84 "png" (Placeholder "Unavailable") None
    ; media_item 85 "png" (External "https://example.com/photo.png") None
    ; other
    ]
  in
  let store = seeded_media_store [ block_id, media_state items ] in
  let events = ref [] in
  with_mounted
    (Journal_media_view.view
       ~store
       ~scope:"preview-retirement"
       ~root:block_id
       ~on_event:(fun event -> events := event :: !events)
       (V.text "Fixture"))
    (fun app ops ->
       let image = mounted_node (ops ()) PathValue (StringValue "/tmp/other.jpg") in
       ignore (Lui_app.dispatch_event app (Press image));
       ignore (Lui_app.flush app);
       let _, payload =
         match gallery_preview (ops ()) with
         | Some preview -> preview
         | None -> fail "ready image group did not open native preview"
       in
       require
         (Yojson.Safe.Util.member "paths" payload
          = `List [ `String "/tmp/ready.png"; `String "/tmp/other.jpg" ])
         "unavailable, external or nonimage file entered image preview";
       events := [];
       Journal_media_view.Store.update
         store
         ~root:block_id
         (Some
            (media_state [ { ready with presentation = Placeholder "Removed" }; other ]));
       ignore (Lui_app.flush app);
       require
         (List.length
            (List.filter
               (fun (event : Journal_media_view.event) ->
                  event.action = Preview && not event.visible)
               !events)
          = 2)
         "retiring a preview member must release the whole gallery")
;;

let test_single_image_save_preview_and_document_compatibility () =
  List.iter
    (fun (file_type, path) ->
       let item = media_item 91 file_type (File path) None in
       with_mounted (media_view [ item ]) (fun app ops ->
         let node =
           if Journal_media_view.is_image_type file_type
           then mounted_node (ops ()) PathValue (StringValue path)
           else mounted_node (ops ()) TextValue (StringValue "PDF attachment")
         in
         ignore (Lui_app.dispatch_event app (Press node));
         ignore (Lui_app.flush app);
         if Journal_media_view.is_image_type file_type
         then (
           let _, payload =
             match gallery_preview (ops ()) with
             | Some preview -> preview
             | None -> fail "single image did not mount the Save-enabled native preview"
           in
           require
             (Yojson.Safe.Util.member "paths" payload = `List [ `String path ]
              && Yojson.Safe.Util.member "selected_index" payload = `Int 0)
             "single image preview payload changed")
         else (
           let _, payload =
             match gallery_preview (ops ()) with
             | Some preview -> preview
             | None -> fail "document did not keep native file preview"
           in
           require
             (Yojson.Safe.Util.member "document" payload = `Bool true)
             "document unexpectedly exposed image Save")))
    [ "png", "/tmp/single-image.png"; "pdf", "/tmp/single-document.pdf" ]
;;

let test_gallery_disposal_releases_preview_references_once () =
  let items =
    [ media_item 92 "png" (File "/tmp/dispose-a.png") None
    ; media_item 93 "jpg" (File "/tmp/dispose-b.jpg") None
    ]
  in
  let store = seeded_media_store [ block_id, media_state items ] in
  let events = ref [] in
  with_mounted
    (Journal_media_view.view
       ~store
       ~scope:"gallery-disposal"
       ~root:block_id
       ~on_event:(fun event -> events := event :: !events)
       (V.text "Fixture"))
    (fun app ops ->
       let node = mounted_node (ops ()) PathValue (StringValue "/tmp/dispose-b.jpg") in
       ignore (Lui_app.dispatch_event app (Press node));
       ignore (Lui_app.flush app);
       events := [];
       ignore (Lui_app.dispose app);
       let releases () =
         List.length
           (List.filter
              (fun (event : Journal_media_view.event) ->
                 event.action = Preview && not event.visible)
              !events)
       in
       require (releases () = 2) "disposing row must release both preview references";
       Journal_media_view.Store.update store ~root:block_id None;
       require (releases () = 2) "disposed preview subscriptions released twice")
;;

(* Presentation defects cannot be reproduced by reducer transitions: the reducer
   already requests the sheet/preview correctly. Exercise the public renderer
   and native event contract without duplicating Worker or storage coverage. *)
let test_sheet_has_native_navigation_and_keeps_cancel_delivery () =
  let check label =
    let closed = ref 0 in
    let close =
      V.button
        ~role:Cancel
        ~on_press:(Ui.Event.Handler.create (fun _ -> incr closed))
        ~child:(V.label ~title:(V.text label) ~icon:(V.symbol ~name:"xmark" ()) ())
        ()
    in
    let content =
      V.text "Sheet content"
      |> V.Body.static
      |> V.Body.toolbar
           ~items:
             [ V.Toolbar.item
                 ~key:(Ui.Key.string "close")
                 ~placement:Cancellation_action
                 close
             ]
    in
    let dismissed = ref false in
    let view =
      V.Sheet.create
        ~title:"Diagnostics"
        ~presented:true
        ~on_presented_changed:
          (Ui.Event.Handler.create (function
             | Ui.Event.Payload.Bool false -> dismissed := true
             | _ -> ()))
        ~sizing:Form
        ~detents:[ Large ]
        ~content
        (V.empty ())
    in
    with_mounted view (fun app ops ->
      let sheet =
        List.find_map
          (function
            | Lui_protocol.CreateNode (node, Sheet) -> Some node
            | _ -> None)
          (ops ())
        |> Option.get
      in
      require
        (List.exists
           (function
             | Lui_protocol.SetProp (node, StyleClass, StringValue style)
               when node = sheet ->
               List.mem "navigation-content" (String.split_on_char ' ' style)
             | _ -> false)
           (ops ()))
        "sheet has no native navigation host for its Close toolbar";
      let close =
        List.find_map
          (function
            | Lui_protocol.CreateNode (node, Button) -> Some node
            | _ -> None)
          (ops ())
        |> Option.get
      in
      let property key =
        List.find_map
          (function
            | Lui_protocol.SetProp (node, actual, value) when node = close && actual = key
              -> Some value
            | _ -> None)
          (List.rev (ops ()))
      in
      require
        (property InlineIconName = Some (StringValue "app:xmark"))
        "missing native close glyph";
      require
        (property AccessibilityLabel = Some (StringValue label))
        "close lost its accessible name";
      require
        (property TextValue <> Some (StringValue label))
        "cancellation still displays text";
      require
        (property WidthValue = Some (IntValue 44)
         && property HeightValue = Some (IntValue 44))
        "cancellation target is smaller than 44pt";
      ignore (Lui_app.dispatch_event app (Press close));
      ignore (Lui_app.flush app);
      require (!closed = 1) "Close action no longer reaches its owner";
      ignore (Lui_app.dispatch_event app (Dismiss sheet));
      ignore (Lui_app.flush app);
      require !dismissed "interactive dismissal no longer reaches its owner")
  in
  List.iter check [ "Close"; "Cancel" ]
;;

let test_labeled_content_keeps_interactive_value () =
  let pressed = ref 0 in
  let value =
    V.button
      ~on_press:(Ui.Event.Handler.create (fun _ -> incr pressed))
      ~child:(V.text "Retry")
      ()
  in
  with_mounted
    (V.labeled_content ~label:(V.text "Connection") ~value ())
    (fun app ops ->
       let button =
         List.find_map
           (function
             | Lui_protocol.CreateNode (node, Button) -> Some node
             | _ -> None)
           (ops ())
       in
       require (Option.is_some button) "interactive labeled value became static text";
       ignore (Lui_app.dispatch_event app (Press (Option.get button)));
       ignore (Lui_app.flush app);
       require (!pressed = 1) "labeled value lost its action")
;;

let test_timeline_document_title_follows_its_asset_child () =
  let entry, views, _, _ = child_gallery_fixture () in
  with_mounted (projected_row ~views ~on_event:ignore entry) (fun app ops ->
    let card = mounted_node (ops ()) TextValue (StringValue "PDF attachment") in
    ignore (Lui_app.dispatch_event app (Press card));
    ignore (Lui_app.flush app);
    let _, payload =
      match gallery_preview (ops ()) with
      | Some preview -> preview
      | None -> fail "document child preview missing"
    in
    require
      (Yojson.Safe.Util.member "title" payload = `String "plan.pdf")
      "document child used its parent's prose as the friendly title")
;;

let test_document_preview_preserves_friendly_title_path_and_lease () =
  List.iter
    (fun file_type ->
       let path = "/tmp/immutable-checksum." ^ file_type in
       let title = "旅行计划与会议记录." ^ file_type in
       let item = media_item 99 file_type (File path) None in
       let events = ref [] in
       let store = seeded_media_store [ block_id, media_state [ item ] ] in
       with_mounted
         (Journal_media_view.view
            ~store
            ~title
            ~scope:"friendly-document-title"
            ~root:block_id
            ~on_event:(fun event -> events := event :: !events)
            (V.text title))
         (fun app ops ->
            let node =
              mounted_node
                (ops ())
                TextValue
                (StringValue (String.uppercase_ascii file_type ^ " attachment"))
            in
            ignore (Lui_app.dispatch_event app (Press node));
            ignore (Lui_app.flush app);
            let preview, payload =
              match gallery_preview (ops ()) with
              | Some preview -> preview
              | None -> fail "document preview dropped its friendly graph title"
            in
            let member = Yojson.Safe.Util.member in
            require
              (member "document" payload = `Bool true
               && member "title" payload = `String title)
              "document preview lost its title or exposed image actions";
            require
              (member "paths" payload = `List [ `String path ])
              "friendly title must not rename the immutable cached file";
            let values =
              Lui_protocol.String_map.empty
              |> Lui_protocol.String_map.add "id" (Lui_protocol.IntValue 1)
              |> Lui_protocol.String_map.add
                   "payload"
                   (Lui_protocol.StringValue {|{"type":"dismiss"}|})
            in
            ignore
              (Lui_app.dispatch_event
                 app
                 (ExtensionEvent (preview, "journal-image-preview", "event", values)));
            ignore (Lui_app.flush app);
            let count visible =
              List.length
                (List.filter
                   (fun (event : Journal_media_view.event) ->
                      event.action = Preview && event.visible = visible)
                   !events)
            in
            require
              (count true = 1 && count false = 1)
              "document dismissal must release exactly its own retained file lease"))
    [ "pdf"; "txt" ]
;;

let test_detail_uses_shared_capture_control () =
  let projection : Journal_graph_projection.detail =
    { root = block (); children = { blocks = []; continuation = None } }
  in
  let routes =
    Journal_routes.create ()
    |> fun routes ->
    Journal_routes.open_detail routes ~block_id ~request_generation:1L
    |> fun routes ->
    Journal_routes.apply_detail_response routes ~request_generation:1L projection
  in
  List.iter
    (fun write_enabled ->
       let actions = ref [] in
       let body =
         Application.For_testing.detail_page ~routes ~write_enabled (fun action ->
           actions := action :: !actions)
       in
       with_mounted (V.Body.Private.to_widget body) (fun app ops ->
         (* Pure routes cannot reproduce native positional-slot mounting. The
            public renderer must retain its body without an empty toolbar slot. *)
         let header =
           List.find_map
             (function
               | Lui_protocol.SetExtensionProp (id, "payload", StringValue value)
                 when Yojson.Basic.Util.member "mode" (Yojson.Basic.from_string value)
                      = `String "detail" -> Some id
               | _ -> None)
             (ops ())
           |> Option.get
         in
         let slots =
           List.filter_map
             (function
               | Lui_protocol.InsertChild (parent, child, _) when parent = header ->
                 Some child
               | _ -> None)
             (ops ())
         in
         require
           (List.length slots = 2)
           "Detail native Chrome must retain body and one options control";
         require
           (List.length (mounted_nodes (ops ()) AccessibilityLabel (StringValue "Block options")) = 1)
           "Detail must have one discoverable options menu";
         let captures =
           mounted_nodes (ops ()) AccessibilityLabel (StringValue "Capture")
         in
         require (List.length captures = 1) "Detail must have one shared Capture control";
         List.iter
           (fun label ->
              require
                (mounted_nodes (ops ()) AccessibilityLabel (StringValue label) = [])
                "Detail retains removed toolbar action %s"
                label)
           [ "Append"; "Attach file" ];
         ignore (Lui_app.dispatch_event app (Press (List.hd captures)));
         ignore (Lui_app.flush app);
         require
           (!actions = if write_enabled then [ Application.For_testing.Append ] else [])
           "Detail Capture failed to dispatch through its current write gate"))
    [ true; false ]
;;

let test_detail_three_tiers_keep_deep_order_and_plain_rows () =
  let id n = Printf.sprintf "20000000-0000-4000-a000-%012d" n in
  let root = block ~source:"周末去山里走走，\n顺便记录这次路线和沿途的风景。" ()
    |> Journal_model.with_tag_titles ~tag_titles:[ "周末"; "trip" ] in
  let child = block ~id:(id 2) ~parent_id:block_id ~source:"出发前的准备" () in
  let grandchild = block ~id:(id 3) ~parent_id:(id 2) ~source:"带上雨衣和充电宝\n下载离线地图" () in
  let deep = block ~id:(id 4) ~parent_id:(id 3) ~source:"更深一层，完整保留中文内容" () in
  let deeper = block ~id:(id 5) ~parent_id:(id 4) ~source:"第四层以下仍然可以阅读" ~child_count:0 () in
  let sibling = block ~id:(id 6) ~parent_id:block_id ~source:"沿途记录" ~child_count:0 () in
  let projection root children : Journal_graph_projection.detail =
    { root; children = { blocks = children; continuation = None } }
  in
  let routes = Journal_routes.create ()
    |> fun t -> Journal_routes.open_detail t ~block_id ~request_generation:1L
    |> fun t -> Journal_routes.apply_detail_response t ~request_generation:1L (projection root [ child; sibling ])
  in
  let load detail parent children =
    let detail, requests = Journal_detail.step detail (Set_branch_expanded (Journal_model.id parent, true)) in
    let generation = match requests with
      | [ Journal_graph_request.Load_detail { limit = 64; request_generation; _ } ] -> request_generation
      | _ -> fail "Expanding one branch must issue exactly one bounded page read"
    in
    fst (Journal_detail.step detail (Loaded (generation, projection parent children)))
  in
  let detail = Option.get (Journal_routes.detail routes)
    |> fun t -> load t child [ grandchild ]
    |> fun t -> load t grandchild [ deep ]
    |> fun t -> load t deep [ deeper ]
  in
  let routes = Journal_routes.update_detail routes detail in
  let body = Application.For_testing.detail_page ~routes ~write_enabled:true ignore in
  with_mounted (V.Body.Private.to_widget body) (fun _ ops ->
    let payloads = List.filter_map (function
      | Lui_protocol.SetExtensionProp (_, "payload", StringValue s) -> Some (Yojson.Basic.from_string s)
      | _ -> None) (ops ()) in
    let list = List.find (fun p -> Yojson.Basic.Util.member "sections" p <> `Null) payloads in
    let rows = Yojson.Basic.Util.(list |> member "sections" |> to_list |> List.hd |> member "rows" |> to_list) in
    require (List.length rows = 6) "Detail flattens only visual layout, preserving all loaded descendants and order";
    require (List.map (Yojson.Basic.Util.member "key") rows =
      List.map (fun b -> `String ("block:" ^ Journal_model.id b))
        [ root; child; grandchild; deep; deeper; sibling ]) "Detail changes owner traversal order";
    List.iter (fun row ->
      require (Yojson.Basic.Util.member "type" row = `String "row") "Detail retains disclosure nesting";
      require (Yojson.Basic.Util.member "separator" row = `String "hidden") "Detail retains hierarchy separators") rows;
    let labels = List.filter (fun p -> Yojson.Basic.Util.member "mode" p = `String "detail-text") payloads in
    require (List.exists (fun p -> Yojson.Basic.Util.member "id" p = `String ("detail-tags:" ^ block_id)
      && Yojson.Basic.Util.member "text" p = `String "#周末  #trip") labels) "Detail drops owned tags";
    let expected = [ root, 0; child, 1; grandchild, 2; deep, 2; deeper, 2; sibling, 1 ] in
    List.iter (fun (block, level) ->
      let label = List.find (fun p -> Yojson.Basic.Util.member "id" p = `String ("detail-block:" ^ Journal_model.id block)) labels in
      require (Yojson.Basic.Util.member "level" label = `Int level) "Detail loses the three-level typography cap";
      require (Yojson.Basic.Util.member "text" label <> `Null) "Detail drops long or Chinese text") expected)
;;

let test_detail_flat_branch_keeps_explicit_collapse_action () =
  let child = block ~id:"20000000-0000-4000-a000-000000000002" ~parent_id:block_id ~child_count:0 () in
  let projection : Journal_graph_projection.detail =
    { root = block (); children = { blocks = [ child ]; continuation = None } } in
  let routes = Journal_routes.create ()
    |> fun t -> Journal_routes.open_detail t ~block_id ~request_generation:1L
    |> fun t -> Journal_routes.apply_detail_response t ~request_generation:1L projection in
  let actions = ref [] in
  let body = Application.For_testing.detail_page ~routes ~write_enabled:true (fun a -> actions := a :: !actions) in
  with_mounted (V.Body.Private.to_widget body) (fun app ops ->
    dispatch_row_action app (native_list_node (ops ())) ("block:" ^ block_id) "collapse";
    require (!actions = [ Application.For_testing.Set_expanded (block_id, false) ])
      "Removing disclosure chrome loses the existing bounded collapse action")
;;

let tests =
  [ "Detail three typography tiers and deep flat rows", test_detail_three_tiers_keep_deep_order_and_plain_rows
  ; "Detail flat branch retains collapse", test_detail_flat_branch_keeps_explicit_collapse_action
  ] @
  [ "Detail shared Capture control", test_detail_uses_shared_capture_control
  ; ( "timeline asset child preview title"
    , test_timeline_document_title_follows_its_asset_child )
  ; ( "native sheet navigation and cancellation"
    , test_sheet_has_native_navigation_and_keeps_cancel_delivery )
  ; "interactive labeled value", test_labeled_content_keeps_interactive_value
  ; ( "document friendly title and lease"
    , test_document_preview_preserves_friendly_title_path_and_lease )
  ; ( "single image save preview and document compatibility"
    , test_single_image_save_preview_and_document_compatibility )
  ; ( "gallery disposal releases once"
    , test_gallery_disposal_releases_preview_references_once )
  ; ( "gallery preview order selection and leases"
    , test_gallery_preview_order_selection_and_leases )
  ; ( "gallery preview filtering and retirement"
    , test_gallery_preview_filters_unavailable_and_closes_on_retirement )
  ; ( "native status Picker contracts"
    , test_status_picker_keeps_accessible_group_and_selection )
  ; "independent mounted input revisions", test_mounted_input_revisions_remain_independent
  ; ( "Timeline native Status/Delete callbacks"
    , test_timeline_native_status_delete_callbacks )
  ; ( "native action rejection"
    , test_native_row_actions_ignore_disabled_missing_and_malformed )
  ; "nested native action owners", test_native_nested_row_actions_bind_current_owner
  ; "retired native action owners", test_native_retired_row_actions_do_not_execute
  ; ( "reactive gallery owner routing and sibling identity"
    , test_reactive_child_gallery_routes_and_preserves_siblings )
  ; ( "reactive nonimage structure and presentation"
    , test_reactive_nonimage_structure_and_presentation )
  ; ( "reactive media subscriber lifetime"
    , test_reactive_media_subscription_disposal_and_epoch )
  ; ( "detail media without asset actions"
    , test_detail_media_preserves_rendering_without_asset_actions )
  ; "native list nested content bindings", test_native_list_payload_binds_nested_contents
  ; "known single image stable slot", test_known_single_slot_survives_availability
  ; "known root image stable slot", test_known_root_slot_survives_availability
  ; "known gallery stable slots", test_known_gallery_slots_survive_separate_arrivals
  ; "direct image child composition", test_direct_image_children_share_parent_gallery
  ; "late image child discovery", test_image_children_load_without_title_flash
  ; "empty parent image gallery", test_empty_parent_keeps_direct_images
  ; "top image asset body", test_top_image_asset_has_no_filename_body
  ; "scoped theme wire properties", test_scoped_theme_wire_properties
  ; "loading indicator and message", test_loading_keeps_indicator_and_message
  ; "UUID reference body and summary", test_reference_body_and_summary
  ; "status and tags mount", test_status_and_tags_mount
  ; "timeline no chevron", test_timeline_has_no_chevron
  ; "expand long body", test_long_body_can_expand
  ; "single image beside body", test_single_image_beside_body
  ; "LUI image gallery and preview", test_images_use_lui_gallery_and_preview
  ; "file card metadata", test_file_cards_use_actual_metadata
  ; "unavailable attachment retry", test_attachment_unavailable_keeps_retry
  ; "empty media", test_empty_media_has_no_attachment_chrome
  ; "timeline media targets", test_timeline_media_targets
  ; "native LUI events", test_native_lui_events
  ]
;;

let () =
  let failed =
    List.filter_map
      (fun (name, run) ->
         Printf.printf "running %s\n%!" name;
         try
           run ();
           None
         with
         | error ->
           Printf.eprintf "%s: %s\n%!" name (Printexc.to_string error);
           Some name)
      tests
  in
  if failed <> [] then fail "Failed: %s" (String.concat ", " failed)
;;
