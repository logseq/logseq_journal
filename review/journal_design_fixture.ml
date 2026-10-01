(* Synthetic simulator-only preview. Uses production OCaml/LUI timeline and media views. *)
module U = Journal_view
module V = U.View
module G = Logseq_db_types.Graph_types
module A = Logseq_db_types.Asset_descriptor

let uuid n =
  G.Uuid.of_string (Printf.sprintf "20261001-0000-4000-8000-%012d" n) |> Result.get_ok
;;

let path name = Filename.concat (Sys.getenv "JOURNAL_DESIGN_ASSETS") name

let block n source status tags =
  Journal_model.create
    ~id:(G.Uuid.to_string (uuid n))
    ~page_id:(G.Uuid.to_string (uuid 99))
    ~journal_day:20261001
    ~parent_id:None
    ~sibling_order:(string_of_int n)
    ~source
    ~task_state:status
    ~child_count:0
    ~creation_time:
      (Journal_time.create
         ~instant_unix_ms:1790849400000L
         ~local_day:20261001
         ~local_minute_of_day:570
       |> Result.get_ok)
    ~revision:"synthetic"
    ~last_mutation_id:(G.Uuid.to_string (uuid 98))
  |> Result.get_ok
  |> fun value -> Journal_model.with_tag_titles value ~tag_titles:tags
;;

let item n typ name size =
  let asset =
    A.create
      ~uuid:(uuid (100 + n))
      ~source:
        (Managed
           (Some (A.version ~checksum:(String.make 64 'a') ~file_type:typ |> Result.get_ok)))
      ~current_checksum:None
      ~size
      ~dimensions:None
    |> Result.get_ok
  in
  { Journal_media_runtime.token = string_of_int n
  ; asset
  ; file_type = typ
  ; presentation = Journal_media.File (path name)
  }
;;

let page =
  { Journal_graph_projection.id = G.Uuid.to_string (uuid 99)
  ; day = 20261001
  ; title = "Oct 1, 2026 · Synthetic preview"
  }
;;

let entries () =
  List.map
    (fun block -> { Journal_graph_projection.block; child_summaries = [] })
    [ block 1 "清晨沿着海岸走了一段，海风很轻。把今天喜欢的两张照片留在这里。" No_status [ "户外"; "周末计划" ]
    ; block 2 "整理这周的阅读笔记，把下次讨论要用的材料放在一起。" Doing [ "阅读"; "工作" ]
    ; block
        3
        "最近想把每天的小片段记得更具体一点。\n\
         今天的散步没有目的地，走到海边便坐了一会儿。\n\
         远处的船慢慢离岸，路过的人谈论着天气。\n\
         回来以后，把一路上想到的事写在这里。\n\
         明天再看，也许会发现一些不同的细节。"
        Todo
        [ "日常" ]
    ; block 4 "晚上做了热汤，留了一段安静的时间给自己。" No_status []
    ]
;;

let render_media ~root child =
  let images =
    if root = G.Uuid.to_string (uuid 1)
    then
      [ item 1 "jpg" "coast.jpg" (Some 426000L); item 2 "jpg" "road.jpg" (Some 319000L) ]
    else if root = G.Uuid.to_string (uuid 2)
    then [ item 3 "pdf" "reading.pdf" (Some 1800000L); item 4 "txt" "notes.txt" None ]
    else []
  in
  Journal_media_view.view
    ~scope:"synthetic-preview"
    ~root
    ~media:
      (Some
         { Journal_media_runtime.items = images
         ; more = false
         ; error = None
         ; picker = None
         })
    ~editable:false
    ~on_event:(fun _ -> ())
    child
;;

let patch = ref ""
let current = ref None

let init _ _ _ =
  let entries = entries () in
  let state = Journal_timeline_state.empty ~today:20261001 in
  let state =
    Journal_timeline_state.begin_request state ~generation:1L (Feed { before_day = None })
  in
  let state =
    Journal_timeline_state.apply_feed
      state
      ~generation:1L
      { Journal_graph_projection.days =
          [ { page; entries; has_more_entries = false; continuation = None } ]
      ; has_more_days = false
      ; slot_count = 5
      }
  in
  let no_op = U.Event.Handler.create (fun _ -> ()) in
  let body =
    Journal_timeline.view
      ~render_media
      ~state
      ~day_presentation:(fun _ ->
        Some
          { Journal_calendar.date_text = "2026.10.01 · 合成样例"
          ; weekday_text = "Thu"
          ; accessibility_label = "Synthetic preview"
          })
      ~on_visible_range:no_op
      ~on_scroll_completed:no_op
      ~on_retry_day:no_op
      ~on_open_block:no_op
      ~delete_enabled:true
      ~actions_enabled:true
      ~on_status:no_op
      ~on_delete:no_op
  in
  let body =
    Journal_header.view
      ~key:(U.Key.string "fixture-header")
      ~platform:"ios"
      ~context:Journal_header.Context.journals
      ~sync_phase:None
      ~sync_error:None
      ~on_error_info:None
      ~on_account_action:None
      ~local_deletion_available:false
      ~on_journals:no_op
      ~on_favorites:no_op
      ~on_capture:no_op
      ~capture_enabled:false
      ~capture_expanded:None
      ~body
  in
  let backend =
    { Lui_protocol.backend_profile = Lui_protocol.profile IOS SwiftUIHost
    ; apply_batch =
        (fun batch ->
          patch := Lui_wire.encode_batch batch;
          true)
    }
  in
  let app =
    Lui_app.create_with_extensions
      backend
      Journal_lui_native.registry
      ()
      (fun () () -> ())
      (fun _ _ _ -> U.mount body)
  in
  current := Some app;
  ignore (Lui_app.start app);
  ignore (Lui_app.flush app);
  !patch
;;

let update f =
  patch := "";
  Option.iter
    (fun app ->
       f app;
       ignore (Lui_app.flush app))
    !current;
  !patch
;;

let () =
  Journal_bridge.register
    { init
    ; dispatch =
        (fun event -> update (fun app -> ignore (Lui_app.dispatch_event app event)))
    ; extension_event = (fun _ _ _ -> "")
    ; pump = (fun () -> update (fun _ -> ()))
    ; platform_event = (fun _ -> ())
    ; platform_response = (fun _ -> ())
    ; platform_failure = (fun _ -> ())
    ; dispose = (fun () -> update (fun app -> ignore (Lui_app.dispose app)))
    ; root_node = (fun () -> Option.fold ~none:0 ~some:Lui_app.root_node !current)
    ; loading_signal = (fun () -> 1)
    }
;;
