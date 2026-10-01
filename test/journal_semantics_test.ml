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
      ?(source = "Literal #journal @person 👩🏽‍💻")
      ?(task_state = Journal_model.Done)
      ?(child_count = 3)
      ()
  =
  Journal_model.create
    ~id:block_id
    ~page_id
    ~journal_day:20260809
    ~parent_id:None
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

let test_timeline_media_targets () =
  let targets = ref [] in
  ignore
    (Journal_row.view
       ~show_timestamp:false
       ~render_media:(fun ~root child ->
         targets := root :: !targets;
         child)
       { Journal_graph_projection.block = block ()
       ; child_summaries = [ { block_id = "visible-child"; source = "Summary" } ]
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
    ; dispatch = (fun event -> received := event :: !received; "")
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

let has_text ops expected =
  List.exists
    (function
      | Lui_protocol.SetProp (_, TextValue, StringValue value) -> value = expected
      | _ -> false)
    ops
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

let test_long_body_can_expand () =
  let source =
    String.concat
      "\n"
      [ "First line"; "Second line"; "Third line"; "Fourth line retained" ]
  in
  let view =
    Journal_row.view
      ~show_timestamp:false
      ~render_media:(fun ~root:_ child -> child)
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

let media_view items =
  Journal_media_view.view
    ~scope:"fixture"
    ~root:block_id
    ~media:
      (Some { Journal_media_runtime.items; more = false; error = None; picker = None })
    ~editable:false
    ~on_event:(fun _ -> ())
    (V.text "Example body")
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
           | Lui_protocol.CreateNode (_, FilePreview) -> true
           | _ -> false)
         (ops ()))
      "image press did not open LUI file_preview")
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
    (media_view [ media_item 1 "jpg" (Placeholder "Not downloaded") None ])
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
      ~render_media:(fun ~root:_ child -> child)
      { Journal_graph_projection.block; child_summaries = [] }
  in
  with_mounted view (fun _ ops ->
    require (has_text (ops ()) "Doing") "status must mount using supported LUI nodes";
    require (has_text (ops ()) "#阅读  #工作") "named tags must accompany status")
;;

let tests =
  [ "status and tags mount", test_status_and_tags_mount
  ; "timeline no chevron", test_timeline_has_no_chevron
  ; "expand long body", test_long_body_can_expand
  ; "LUI image gallery and preview", test_images_use_lui_gallery_and_preview
  ; "file card metadata", test_file_cards_use_actual_metadata
  ; "unavailable attachment retry", test_attachment_unavailable_keeps_retry
  ; "empty media", test_empty_media_has_no_attachment_chrome
  ; "timeline media targets", test_timeline_media_targets
  ; "native LUI events", test_native_lui_events
  ]

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
