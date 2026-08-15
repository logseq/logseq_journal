module ID = Bonsai_flutter_spec.Id
module Platform = Bonsai_flutter.Application_platform
module Ui = Bonsai_flutter_ui
module Graph_service = Logseq_db_worker_bonsai.Logseq_db_worker_bonsai_service

type delete_phase =
  | Undoable
  | Committing

type pending_delete =
  { mutation_id : string
  ; block_id : string
  ; expected_revision : int
  ; staged : Journal_timeline_state.staged_delete
  ; deadline : Core.Time_ns.t
  ; phase : delete_phase
  }

type timeline_notice =
  | Delete_undo
  | Delete_failed

type state =
  { routes : Journal_routes.t
  ; timeline : Journal_timeline_state.t
  ; next_request_generation : int64
  ; next_local_sequence : int64
  ; calendar : Journal_calendar.t option
  ; formatted_generation : int64 option
  ; day_labels : (int * string) list
  ; pending_timeline_mutation : string option
  ; pending_delete : pending_delete option
  ; timeline_notice : timeline_notice option
  ; write_enabled : bool
  ; graph_ready : bool
  ; feed_loaded : bool
  ; graph_error : string option
  }

let initial_anchor : Journal_routes.anchor = { block_id = None; first_index = 0 }
let feed_day_limit = 7

let initial_state =
  { routes = Journal_routes.create ~anchor:initial_anchor
  ; timeline = Journal_timeline_state.empty ~today:0
  ; next_request_generation = 1L
  ; next_local_sequence = 1L
  ; calendar = None
  ; formatted_generation = None
  ; day_labels = []
  ; pending_timeline_mutation = None
  ; pending_delete = None
  ; timeline_notice = None
  ; write_enabled = false
  ; graph_ready = false
  ; feed_loaded = false
  ; graph_error = None
  }
;;

let worker_request generation = function
  | Journal_timeline_state.Feed { before_day } ->
    Journal_graph_request.Load_feed
      { before_day
      ; day_limit = feed_day_limit
      ; blocks_per_day = 64
      ; slot_limit = 128
      ; request_generation = generation
      }
  | Day { day; after } ->
    Journal_graph_request.Load_day_blocks
      { day; after; limit = 64; request_generation = generation }
  | Children { parent_id; epoch = _ } ->
    Journal_graph_request.Load_detail
      { block_id = parent_id; after = None; limit = 3; request_generation = generation }
;;

let block_in_timeline timeline block_id =
  Journal_timeline_state.retained_slots timeline
  |> List.find_map (function
    | Journal_timeline_state.Top_level entry
      when String.equal (Journal_model.id entry.block) block_id -> Some entry.block
    | Child_preview { block; _ }
      when String.equal (Journal_model.id block) block_id -> Some block
    | Day_heading _
    | Top_level _
    | Child_preview _
    | Day_continuation _
    | Children_loading _
    | Children_more _
    | Feed_continuation _
    | Bottom_clearance -> None)
;;

let open_detail_state state detail request_generation =
  let routes =
    Journal_routes.apply_detail_response state.routes ~request_generation detail
  in
  let routes =
    match Journal_routes.detail routes with
    | None -> routes
    | Some detail ->
      Journal_routes.update_detail routes (Journal_detail.begin_edit detail)
  in
  { state with routes }
;;

let fail_active_mutation state message =
  match state.pending_delete with
  | Some pending_delete ->
    { state with
      timeline = Journal_timeline_state.undo_delete pending_delete.staged
    ; pending_delete = None
    ; timeline_notice = Some Delete_failed
    }
  | None ->
    (match Journal_routes.capture state.routes, Journal_routes.detail state.routes with
     | Some capture, _ ->
       { state with
         routes =
           Journal_routes.update_capture
             state.routes
             (Journal_capture.fail capture ~message)
       }
     | None, Some detail ->
       { state with
         routes =
           Journal_routes.update_detail state.routes (Journal_detail.fail detail ~message)
       }
     | None, None -> { state with pending_timeline_mutation = None })
;;

let terminal_graph_state state message =
  { state with
    routes = Journal_routes.graph_unavailable state.routes
  ; write_enabled = false
  ; graph_ready = false
  ; feed_loaded = true
  ; pending_timeline_mutation = None
  ; pending_delete = None
  ; graph_error = Some message
  }
;;

let journal_day_iso day =
  Printf.sprintf "%04d-%02d-%02d" (day / 10_000) (day / 100 mod 100) (day mod 100)
;;

let distinct_days state =
  let from_slots =
    Journal_timeline_state.retained_slots state.timeline
    |> List.filter_map (function
      | Journal_timeline_state.Day_heading page -> Some page.day
      | Top_level entry -> Some (Journal_model.journal_day entry.block)
      | Child_preview { block; _ } -> Some (Journal_model.journal_day block)
      | Day_continuation { day; _ } -> Some day
      | Children_loading _
      | Children_more _
      | Feed_continuation _
      | Bottom_clearance -> None)
  in
  let days =
    match state.calendar with
    | None -> from_slots
    | Some calendar -> calendar.local_day :: from_slots
  in
  List.sort_uniq Int.compare days
;;

let label_for_day state day =
  match state.formatted_generation, state.calendar with
  | Some formatted_generation, Some calendar
    when Int64.equal formatted_generation calendar.generation ->
    Option.value (List.assoc_opt day state.day_labels) ~default:(journal_day_iso day)
  | None, _ | Some _, None | Some _, Some _ -> journal_day_iso day
;;

let today_label state =
  match state.calendar with
  | None -> "Date unavailable"
  | Some calendar ->
    (match state.formatted_generation with
     | Some generation when Int64.equal generation calendar.generation ->
       Option.value
         (List.assoc_opt calendar.local_day state.day_labels)
         ~default:"Date unavailable"
     | None | Some _ -> "Date unavailable")
;;

let rtl_languages = [ "ar"; "fa"; "he"; "ur" ]

let is_rtl_locale locale =
  let rec language_length index =
    if index = String.length locale
    then index
    else (
      match String.get locale index with
      | '-' | '_' -> index
      | _ -> language_length (index + 1))
  in
  let language = String.sub locale 0 (language_length 0) |> String.lowercase_ascii in
  List.exists (String.equal language) rtl_languages
;;

let back_state state =
  let detail_block_id = Journal_routes.detail_block_id state.routes in
  let detail_root = Option.map Journal_detail.root (Journal_routes.detail state.routes) in
  let routes = Journal_routes.back state.routes in
  let timeline =
    match detail_block_id, detail_root, Journal_routes.route routes with
    | Some block_id, Some root, Journal_routes.Timeline ->
      Journal_timeline_state.replace_block state.timeline root
      |> Journal_timeline_state.return_from_detail ~block_id
    | Some block_id, None, Journal_routes.Timeline ->
      Journal_timeline_state.return_from_detail state.timeline ~block_id
    | Some _, _, _ | None, _, _ -> state.timeline
  in
  { state with routes; timeline }
;;

let apply_worker_response state (response : Journal_graph_runtime.response) =
  match response.payload with
  | Journal_graph_runtime.Graph_ready _ ->
    { state with
      write_enabled = true
    ; graph_ready = true
    ; graph_error = None
    }
  | Feed_loaded { request_generation; feed } ->
    let accepted_initial_feed =
      match Journal_timeline_state.pending_request state.timeline with
      | Some (expected_generation, Feed { before_day = None }) ->
        Int64.equal expected_generation request_generation
      | Some (_, Feed { before_day = Some _ })
      | Some (_, Day _)
      | Some (_, Children _)
      | None -> false
    in
    { state with
      timeline =
        Journal_timeline_state.apply_feed
          state.timeline
          ~generation:request_generation
          feed
    ; feed_loaded = state.feed_loaded || accepted_initial_feed
    }
  | Day_blocks_loaded { request_generation; page } ->
    { state with
      timeline =
        Journal_timeline_state.apply_timeline_entry_page
          state.timeline
          ~generation:request_generation
          page
    }
  | Detail_loaded { request_generation; detail }
    when Journal_routes.route state.routes = Journal_routes.Detail_loading ->
    open_detail_state state detail request_generation
  | Detail_loaded { request_generation; detail } ->
    { state with
      timeline =
        Journal_timeline_state.apply_detail
          state.timeline
          ~generation:request_generation
          detail
    }
  | Block_captured { block; timeline_entry_update } ->
    (match Journal_routes.capture state.routes with
     | None -> state
     | Some capture ->
       let capture = Journal_capture.commit capture block in
       let routes =
         Journal_routes.update_capture state.routes capture |> Journal_routes.discard
       in
       { state with
         routes
       ; timeline =
           Option.fold
             ~none:state.timeline
             ~some:(Journal_timeline_state.prepend_timeline_entry state.timeline)
             timeline_entry_update
       })
  | Block_updated { block; timeline_entry_update } ->
    let routes =
      match Journal_routes.detail state.routes with
      | None -> state.routes
      | Some detail ->
        Journal_routes.update_detail
          state.routes
          (Journal_detail.apply_block detail block |> Journal_detail.begin_edit)
    in
    { state with
      routes
    ; timeline =
        Option.fold
          ~none:(Journal_timeline_state.replace_block state.timeline block)
          ~some:(Journal_timeline_state.replace_timeline_entry state.timeline)
          timeline_entry_update
    ; pending_timeline_mutation = None
    }
  | Update_conflict latest ->
    (match Journal_routes.detail state.routes with
     | None -> state
     | Some detail ->
       { state with
         routes =
           Journal_routes.update_detail
             state.routes
             (Journal_detail.apply_conflict detail latest)
       })
  | Child_created { child; parent_revision; timeline_entry_update } ->
    (match Journal_routes.detail state.routes with
     | None -> state
     | Some detail ->
       let detail =
         Journal_detail.apply_child_created detail ~child ~parent_revision
         |> Journal_detail.begin_edit
       in
       { state with
         routes = Journal_routes.update_detail state.routes detail
       ; timeline =
           Journal_timeline_state.replace_timeline_entry
             state.timeline
             timeline_entry_update
       })
  | Block_found _ -> state
  | Subtree_deleted { block_id; parent; timeline_entry_update; _ } ->
    (match state.pending_delete with
     | Some pending when String.equal pending.block_id block_id ->
       { state with
         timeline =
           Option.fold
             ~none:
               (Option.fold
                  ~none:state.timeline
                  ~some:(Journal_timeline_state.replace_block state.timeline)
                  parent)
             ~some:(Journal_timeline_state.replace_timeline_entry state.timeline)
             timeline_entry_update
       ; pending_delete = None
       ; timeline_notice = None
       }
     | None | Some _ -> state)
  | Delete_conflict latest ->
    (match state.pending_delete with
     | None -> state
     | Some pending ->
       { state with
         timeline =
           (let timeline = Journal_timeline_state.undo_delete pending.staged in
            Journal_timeline_state.replace_block timeline latest)
       ; pending_delete = None
       ; timeline_notice = Some Delete_failed
       })
  | Open_failed error ->
    terminal_graph_state state (Logseq_db_worker.Error.message error)
  | Rejected _
    when Journal_routes.route state.routes = Journal_routes.Detail_loading ->
    { state with
      routes =
        Journal_routes.apply_missing_detail
          state.routes
          ~request_generation:(Journal_routes.detail_request_generation state.routes)
    }
  | Rejected message -> fail_active_mutation state message
;;

let color red green blue = Ui.Style.Color.rgb ~red ~green ~blue

let text_style ?size ?weight ?height ?color () =
  Ui.Style.Text_style.create
    ?font_size:size
    ?font_weight:weight
    ?line_height:height
    ?color
    ()
;;

let styled_text ?size ?weight ?height ?color value =
  Ui.Widget.text ~style:(text_style ?size ?weight ?height ?color ()) value
;;

let action_target
      ?(enabled = true)
      ?(minimum_target = 44.)
      ~test_id
      ~label
      ~hint
      ~on_press
      child
  =
  let button =
    Ui.Material.text_button ~enabled ~on_press ~child ()
    |> Ui.Widget.with_test_id (Ui.Test_id.string test_id)
  in
  let properties =
    Ui.Semantics.create
      ~label
      ~hint
      ~role:Ui.Semantics.Role.Button
      ~enabled
      ~focusable:enabled
      ~actions:(if enabled then [ Ui.Semantics.Action.Tap ] else [])
      ()
  in
  (if enabled
   then Ui.Widget.semantics ~on_action:on_press ~properties button
   else Ui.Widget.semantics ~properties button)
  |> Ui.Widget.constrained_box
       ~constraints:
         (Ui.Layout.Box_constraints.create
            ~min_width:minimum_target
            ~min_height:minimum_target
            ())
;;

let bind_action handler action =
  Ui.Event.Handler.create ~name:("journal-action:" ^ action) (fun _payload ->
    Ui.Event.Handler.Private.invoke handler (Ui.Event.Payload.Text action))
;;

let live_region_text ?color value =
  styled_text ?color value
  |> Ui.Widget.semantics
       ~properties:(Ui.Semantics.create ~label:value ~live_region:true ())
;;

let prefix_action handler prefix =
  Ui.Event.Handler.create ~name:("journal-action-prefix:" ^ prefix) (function
    | Ui.Event.Payload.Text value ->
      Ui.Event.Handler.Private.invoke handler (Ui.Event.Payload.Text (prefix ^ value))
    | _ -> ())
;;

let timeline_notice_view ~tokens notice undo =
  let palette = Journal_visual_tokens.palette tokens in
  let message, action =
    match notice with
    | Delete_undo -> "Block and descendants removed", Some undo
    | Delete_failed -> "Delete failed. Block restored.", None
  in
  let message =
    live_region_text ~color:palette.snackbar_primary_text message
    |> Ui.Widget.with_test_id (Ui.Test_id.string "journal-delete-message")
  in
  let children =
    match action with
    | None -> [ Ui.Widget.Flex.expanded message ]
    | Some on_press ->
      let undo =
        action_target
          ~minimum_target:48.
          ~test_id:"journal-delete-undo"
          ~label:"Undo block deletion"
          ~hint:"Restore the removed block and descendants"
          ~on_press
          (styled_text ~color:palette.snackbar_action_text "Undo")
      in
      [ Ui.Widget.Flex.expanded message; Ui.Widget.Flex.fixed undo ]
  in
  Ui.Widget.Flex.row children
  |> Ui.Widget.padding
       ~insets:
         (Ui.Layout.Edge_insets.symmetric
            ~horizontal:Journal_visual_tokens.spacing.x4
            ~vertical:Journal_visual_tokens.spacing.x1
            ())
  |> Ui.Widget.constrained_box
       ~constraints:
         (Ui.Layout.Box_constraints.create
            ~min_height:Journal_visual_tokens.snackbar_geometry.minimum_height
            ())
  |> Ui.Widget.decorated_box
       ~decoration:
         (Ui.Style.Decoration.create
            ~background:palette.snackbar_surface
            ~border_radius:Journal_visual_tokens.snackbar_geometry.corner_radius
            ())
  |> Ui.Widget.with_test_id (Ui.Test_id.string "journal-delete-snackbar")
;;

let timeline_page
      ~tokens
      ~profile
      ~text_scale
      ~device_pixel_ratio
      ~timeline_state
      ~loading
      ~graph_error
      ~today_subtitle
      ~day_label
      ~reduced_motion
      ~rtl
      ~safe_bottom
      ~viewport_width
      ~content_horizontal_inset
      ~capture_enabled
      ~capture_composer_key
      ~on_capture_event
      ~on_visible_range
      ~on_task_toggle
      ~on_toggle_children
      ~delete_enabled
      ~on_delete
      ~timeline_notice
      ~on_delete_undo
  =
  let palette = Journal_visual_tokens.palette tokens in
  let header =
    Journal_header.view
      ~tokens
      ~text_scale
      ~device_pixel_ratio
      ~context:(Journal_header.Context.today ~subtitle:today_subtitle)
  in
  let capture_button ~id ~tooltip ~position ~visibility ~style label =
    Ui.Native_widget.Message_composer.button
      ~id
      ~tooltip
      ~position
      ~visibility
      ~style
      ~child:
        (styled_text ~size:20. ~color:palette.on_fab label
         |> Ui.Widget.with_test_id
              (Ui.Test_id.string
                 (if id = 1
                  then "journal-capture-composer-plus"
                  else "journal-capture-composer-submit")))
      ()
  in
  let capture =
    Ui.Native_widget.Message_composer.create_with_handler
      ~key:(Ui.Key.string ("journal-capture-composer:" ^ Int64.to_string capture_composer_key))
      ~enabled:capture_enabled
      ~autofocus:false
      ~max_lines:5
      ~hint_text:"Capture a thought"
      ~buttons:
        [ capture_button
            ~id:1
            ~tooltip:"Open full Capture editor"
            ~position:Ui.Native_widget.Message_composer.Leading
            ~visibility:Always
            ~style:Plain
            "+"
        ; capture_button
            ~id:2
            ~tooltip:"Continue Capture"
            ~position:Trailing
            ~visibility:When_non_empty
            ~style:Filled
            "↑"
        ]
      ~on_event:on_capture_event
      ()
    |> Ui.Widget.with_test_id (Ui.Test_id.string "journal-capture-composer")
    |> Ui.Widget.safe_area ~left:false ~top:false ~right:false
    |> Ui.Widget.with_test_id (Ui.Test_id.string "journal-capture-composer-safe-area")
  in
  let timeline =
    match graph_error with
    | Some message ->
      Journal_timeline.Empty
        (live_region_text
           ~color:palette.sheet_error
           ("Unable to open Logseq graph: " ^ message)
         |> Ui.Widget.center
         |> Ui.Widget.with_test_id (Ui.Test_id.string "logseq-graph-open-failed"))
    | None when loading ->
      Journal_timeline.Empty (Journal_timeline.loading_view tokens)
    | None ->
      Journal_timeline.view
        ~tokens
        ~profile
        ~device_pixel_ratio
        ~rtl
        ~state:timeline_state
        ~day_label
        ~reduced_motion
        ~safe_bottom
        ~delete_enabled
        ~on_delete
        ~on_visible_range
        ~on_task_toggle
        ~on_toggle_children
  in
  let base =
    match timeline with
    | Journal_timeline.Empty timeline ->
      Ui.Widget.Flex.column
        [ Ui.Widget.Flex.fixed header; Ui.Widget.Flex.expanded timeline ]
      |> Ui.Widget.Body.static
    | Populated timeline ->
      Ui.Widget.Body.Vertical.create
        [ Ui.Widget.Body.Vertical.fixed header; Ui.Widget.Body.Vertical.fill timeline ]
  in
  let base =
    base
    |> Ui.Widget.Body.decorated_box
         ~decoration:(Ui.Style.Decoration.create ~background:palette.background ())
    |> Ui.Widget.Body.with_test_id (Ui.Test_id.string "journal-root-surface")
    |> Ui.Widget.Body.safe_area ~left:false ~right:false ~bottom:false
  in
  let overlay =
    let geometry = Journal_visual_tokens.composer_geometry in
    capture
    |> Ui.Widget.Stack.positioned
         ~left:geometry.horizontal_margin
         ~right:geometry.horizontal_margin
         ~bottom:geometry.bottom_inset
  in
  let overlays =
    match timeline_notice with
    | None -> [ overlay ]
    | Some notice ->
      let geometry = Journal_visual_tokens.snackbar_geometry in
      let content_width =
        Float.max 0. (viewport_width -. (2. *. content_horizontal_inset))
      in
      let snackbar_width =
        Float.min
          geometry.maximum_width
          (Float.max 0. (content_width -. (2. *. geometry.margin)))
      in
      let left = Float.max 0. ((content_width -. snackbar_width) /. 2.) in
      let bottom =
        safe_bottom
        +. Journal_visual_tokens.composer_geometry.bottom_inset
        +. Journal_visual_tokens.composer_geometry.minimum_height
        +. geometry.vertical_gap
      in
      let snackbar =
        timeline_notice_view ~tokens notice on_delete_undo
        |> Ui.Widget.sized_box ~width:snackbar_width
        |> Ui.Widget.with_test_id (Ui.Test_id.string "journal-delete-snackbar-position")
        |> Ui.Widget.Stack.positioned ~left ~bottom
      in
      [ overlay; snackbar ]
  in
  let body =
    Ui.Widget.Body.overlay ~base ~overlays ()
    |> Ui.Widget.Body.with_test_id (Ui.Test_id.string "journal-root-overlay")
    |> Ui.Widget.Body.padding
         ~insets:(Ui.Layout.Edge_insets.symmetric ~horizontal:content_horizontal_inset ())
    |> Ui.Widget.Body.with_test_id (Ui.Test_id.string "journal-content-width-padding")
    |> Ui.Widget.Body.decorated_box
         ~decoration:(Ui.Style.Decoration.create ~background:palette.background ())
  in
  Ui.Material.scaffold ~body ()
  |> Ui.Widget.page
       ~key:(Ui.Key.string "journal-timeline")
       ~page_key:(ID.Navigation.Page_key.of_string "journal-timeline")
       ~can_pop:false
  |> Ui.Widget.with_test_id (Ui.Test_id.string "journal-timeline-page")
;;

let dialog_body ~test_id ~title ~message ~primary ~secondary =
  Ui.Widget.Flex.column
    [ Ui.Widget.Flex.fixed
        (styled_text
           ~size:20.
           ~weight:Ui.Style.Font_weight.Bold
           ~color:(color 13 20 47)
           title)
    ; Ui.Widget.Flex.fixed (styled_text ~size:15. ~color:(color 64 70 95) message)
    ; Ui.Widget.Flex.fixed
        (Ui.Widget.Flex.row
           [ Ui.Widget.Flex.expanded primary; Ui.Widget.Flex.expanded secondary ])
    ]
  |> Ui.Widget.padding ~insets:(Ui.Layout.Edge_insets.all 20.)
  |> Ui.Material.dialog ~barrier_dismissible:false
  |> Ui.Widget.with_test_id (Ui.Test_id.string test_id)
;;

let page_body ?dialog content =
  let base = Ui.Widget.Body.static content in
  match dialog with
  | None -> base
  | Some dialog ->
    Ui.Widget.Body.overlay ~base ~overlays:[ Ui.Widget.Stack.positioned dialog ] ()
;;

let route_page ~page_key ~transition body =
  Ui.Material.scaffold ~body ()
  |> Ui.Widget.page
       ~key:(Ui.Key.string page_key)
       ~page_key:(ID.Navigation.Page_key.of_string page_key)
       ~presentation:(Ui.Navigation.Standard transition)
       ~can_pop:false
  |> Ui.Widget.with_test_id (Ui.Test_id.string page_key)
;;

let capture_text_field capture dispatch =
  Ui.Material.text_field
    ~key:(Ui.Key.string "capture-editor")
    ~enabled:(Journal_capture.phase capture = Journal_capture.Editing)
    ~keyboard_type:Ui.Text_editing.Multiline
    ~input_action:Ui.Text_editing.Newline
    ~autofocus:true
    ~max_utf8_bytes:65_536
    ~session_id:(Journal_capture.session_id capture)
    ~document_revision:(Journal_capture.document_revision capture)
    ~accepted_local_revision:(Journal_capture.accepted_local_revision capture)
    ~update_mode:(Journal_capture.update_mode capture)
    ~value:(Journal_capture.value capture)
    ~on_edit:dispatch
    ~on_submit:dispatch
    ~on_focus_changed:dispatch
    ~on_limit_reached:dispatch
    ()
  |> Ui.Widget.with_test_id (Ui.Test_id.string "capture-editor")
;;

let capture_child_text_field index editor dispatch =
  let test_id = Printf.sprintf "capture-child-editor:%d" index in
  Ui.Material.text_field
    ~key:(Ui.Key.string test_id)
    ~enabled:true
    ~keyboard_type:Ui.Text_editing.Multiline
    ~input_action:Ui.Text_editing.Newline
    ~max_utf8_bytes:65_536
    ~session_id:(Journal_capture.editor_session_id editor)
    ~document_revision:(Journal_capture.editor_document_revision editor)
    ~accepted_local_revision:(Journal_capture.editor_accepted_local_revision editor)
    ~update_mode:(Journal_capture.editor_update_mode editor)
    ~value:(Journal_capture.editor_value editor)
    ~on_edit:dispatch
    ~on_submit:dispatch
    ~on_focus_changed:dispatch
    ~on_limit_reached:dispatch
    ()
  |> Ui.Widget.with_test_id (Ui.Test_id.string test_id)
;;

let capture_sheet_page
      ~tokens
      ~device_pixel_ratio
      ~date_context
      ~reduced_motion
      ~viewport_width
      ~viewport_height
      capture
      dispatch
  =
  let palette = Journal_visual_tokens.palette tokens in
  let header_min_height = 56. in
  let action_min_height = 56. in
  let editor_min_height = 120. in
  let content_horizontal_inset =
    if Float.compare viewport_width 720. > 0
    then Float.max 0. ((viewport_width -. 560.) /. 2.)
    else if Float.compare viewport_width 360. >= 0
    then Float.min 10. (viewport_width /. 2.)
    else Float.min 8. (viewport_width /. 2.)
  in
  let fixed_content_height = header_min_height +. action_min_height in
  let editor_height =
    Float.max editor_min_height (viewport_height -. fixed_content_height)
  in
  let close = bind_action dispatch "capture-close" in
  let save = bind_action dispatch "capture-save" in
  let task = bind_action dispatch "capture-task" in
  let add_child = bind_action dispatch "capture-add-child" in
  let close_target =
    action_target
      ~enabled:(Journal_capture.phase capture <> Journal_capture.Saving)
      ~test_id:"capture-close"
      ~label:"Close new block editor"
      ~hint:"Return to the Journal timeline"
      ~on_press:close
      (styled_text ~size:20. ~color:palette.text_primary "×")
  in
  let title =
    styled_text
      ~size:20.
      ~weight:Ui.Style.Font_weight.Semi_bold
      ~color:palette.text_primary
      "New block"
    |> Ui.Widget.semantics
         ~properties:
           (Ui.Semantics.create
              ~label:"New block"
              ~role:Ui.Semantics.Role.Header
              ~heading_level:1
              ())
  in
  let date =
    styled_text ~size:14. ~color:palette.text_secondary date_context
    |> Ui.Widget.with_test_id (Ui.Test_id.string "capture-date-context")
  in
  let header =
    Ui.Widget.Flex.row
      [ Ui.Widget.Flex.fixed
          (if Journal_capture.phase capture = Journal_capture.Confirm_discard
           then Ui.Widget.empty ()
           else close_target)
      ; Ui.Widget.Flex.expanded
          (Ui.Widget.Flex.column [ Ui.Widget.Flex.fixed title; Ui.Widget.Flex.fixed date ]
           |> Ui.Widget.sized_box ~height:header_min_height)
      ]
    |> Ui.Widget.padding ~insets:(Ui.Layout.Edge_insets.symmetric ~horizontal:12. ())
    |> Ui.Widget.constrained_box
         ~constraints:(Ui.Layout.Box_constraints.create ~min_height:header_min_height ())
    |> Ui.Widget.with_test_id (Ui.Test_id.string "capture-header")
  in
  let task_label =
    match Journal_capture.task_state capture with
    | Journal_model.Not_a_task -> "Make task"
    | Todo -> "To do"
    | Done -> "Done"
  in
  let task =
    action_target
      ~enabled:(Journal_capture.phase capture = Journal_capture.Editing)
      ~test_id:"capture-task"
      ~label:task_label
      ~hint:"Change optional task state"
      ~on_press:task
      (styled_text ~size:15. task_label)
    |> Ui.Widget.decorated_box
         ~decoration:
           (Ui.Style.Decoration.create
              ~background:palette.sheet_secondary_action
              ~border_radius:22.
              ())
  in
  let add_child =
    action_target
      ~enabled:(Journal_capture.can_add_child capture)
      ~test_id:"capture-add-child"
      ~label:"Add direct child"
      ~hint:"Add a direct child to this new block"
      ~on_press:add_child
      (styled_text ~size:15. "Add child")
  in
  let status =
    (match Journal_capture.phase capture with
     | Journal_capture.Failed message ->
       Ui.Widget.Flex.row
         [ Ui.Widget.Flex.expanded (live_region_text ~color:palette.sheet_error message)
         ; Ui.Widget.Flex.fixed
             (action_target
                ~test_id:"capture-retry"
                ~label:"Retry saving journal block"
                ~hint:"Retry the admitted journal mutation"
                ~on_press:(bind_action dispatch "capture-retry")
                (styled_text "Retry"))
         ]
     | Saving -> live_region_text "Saving journal block"
     | Editing | Confirm_discard | Committed -> Ui.Widget.empty ())
    |> Ui.Widget.with_test_id (Ui.Test_id.string "capture-status")
  in
  let save_action =
    if Journal_capture.phase capture = Journal_capture.Saving
    then
      Ui.Material.circular_progress_indicator ()
      |> Ui.Widget.semantics
           ~properties:
             (Ui.Semantics.create ~label:"Saving journal block" ~live_region:true ())
      |> Ui.Widget.constrained_box
           ~constraints:
             (Ui.Layout.Box_constraints.create ~min_width:44. ~min_height:44. ())
    else
      action_target
        ~enabled:(Journal_capture.can_save capture)
        ~test_id:"capture-save"
        ~label:"Save journal block"
        ~hint:"Persist this journal block"
        ~on_press:save
        (styled_text ~size:20. ~color:palette.on_fab "↑")
      |> Ui.Widget.decorated_box
           ~decoration:
             (Ui.Style.Decoration.create
                ~background:palette.sheet_primary_action
                ~border_radius:22.
                ())
  in
  let action_row =
    Ui.Widget.Flex.row
      [ Ui.Widget.Flex.expanded task
      ; Ui.Widget.Flex.expanded add_child
      ; Ui.Widget.Flex.fixed save_action
      ]
    |> Ui.Widget.padding ~insets:(Ui.Layout.Edge_insets.only ~left:12. ~right:12. ())
    |> Ui.Widget.constrained_box
         ~constraints:(Ui.Layout.Box_constraints.create ~min_height:action_min_height ())
    |> Ui.Widget.safe_area ~left:false ~top:false ~right:false
    |> Ui.Widget.with_test_id (Ui.Test_id.string "capture-action-row")
  in
  let editor =
    let child_editors = Journal_capture.child_editors capture in
    let parent_height = if List.is_empty child_editors then editor_height else 120. in
    let parent =
      capture_text_field capture dispatch
      |> Ui.Widget.semantics
           ~properties:
             (Ui.Semantics.create
                ~label:"Journal block content"
                ~role:Ui.Semantics.Role.Text_field
                ())
      |> Ui.Widget.sized_box ~height:parent_height
    in
    let children =
      List.mapi
        (fun index child_editor ->
           capture_child_text_field index child_editor dispatch
           |> Ui.Widget.semantics
                ~properties:
                  (Ui.Semantics.create
                     ~label:(Printf.sprintf "Direct child %d content" (index + 1))
                     ~role:Ui.Semantics.Role.Text_field
                     ())
           |> Ui.Widget.sized_box ~height:120.
           |> Ui.Widget.Flex.fixed)
        child_editors
    in
    let editor_input =
      Ui.Widget.Flex.column (Ui.Widget.Flex.fixed parent :: children)
    in
    Ui.Widget.Scroll_view.vertical ~primary:true ~on_scroll:dispatch editor_input ()
    |> Ui.Widget.Viewport.Vertical.with_test_id
         (Ui.Test_id.string "capture-primary-scroll")
    |> Ui.Widget.Viewport.Vertical.with_height ~height:editor_min_height
  in
  let content =
    Ui.Widget.Flex.column
      [ Ui.Widget.Flex.fixed header
      ; Ui.Widget.Flex.fixed
          (Ui.Widget.empty ()
           |> Ui.Widget.sized_box
                ~height:
                  (Journal_visual_tokens.physical_divider_thickness ~device_pixel_ratio)
           |> Ui.Widget.decorated_box
                ~decoration:
                  (Ui.Style.Decoration.create ~background:palette.sheet_outline ()))
      ; Ui.Widget.Flex.expanded editor
      ; Ui.Widget.Flex.fixed status
      ; Ui.Widget.Flex.fixed action_row
      ]
    |> Ui.Widget.decorated_box
         ~decoration:(Ui.Style.Decoration.create ~background:palette.sheet_surface ())
    |> Ui.Widget.with_test_id (Ui.Test_id.string "capture-sheet-surface")
    |> Ui.Widget.padding
         ~insets:(Ui.Layout.Edge_insets.symmetric ~horizontal:content_horizontal_inset ())
  in
  let dialog =
    if Journal_capture.phase capture <> Journal_capture.Confirm_discard
    then None
    else (
      let keep =
        action_target
          ~test_id:"capture-keep-editing"
          ~label:"Keep editing"
          ~hint:"Return to the draft"
          ~on_press:(bind_action dispatch "keep-editing")
          (styled_text "Keep editing")
      in
      let discard =
        action_target
          ~test_id:"capture-discard"
          ~label:"Discard draft"
          ~hint:"Discard and return to Timeline"
          ~on_press:(bind_action dispatch "discard")
          (styled_text "Discard")
      in
      Some
        (dialog_body
           ~test_id:"capture-discard-dialog"
           ~title:"Discard draft?"
           ~message:"This journal entry has unsaved changes."
           ~primary:keep
           ~secondary:discard))
  in
  let content =
    match dialog with
    | None -> content
    | Some dialog ->
      Ui.Widget.Stack.create
        [ Ui.Widget.Stack.child content; Ui.Widget.Stack.positioned dialog ]
  in
  let motion = Journal_visual_tokens.motion ~reduced_motion in
  let presentation =
    Ui.Navigation.Modal_bottom_sheet.create
      ~barrier_dismissible:false
      ~barrier_color:palette.modal_scrim
      ~sizing:Ui.Navigation.Modal_bottom_sheet.Sizing.Scroll_controlled
      ~use_safe_area:true
      ~request_focus:true
      ~transition_duration_ms:motion.capture_sheet_enter_ms
      ~reverse_transition_duration_ms:motion.capture_sheet_exit_ms
      ()
  in
  content
  |> Ui.Widget.page
       ~key:(Ui.Key.string "journal-capture-sheet")
       ~page_key:(ID.Navigation.Page_key.of_string "journal-capture-sheet")
       ~presentation:(Ui.Navigation.Modal_bottom_sheet presentation)
       ~can_pop:(Journal_capture.can_pop capture)
       ~restoration_id:(ID.Navigation.Restoration_id.of_string "journal-capture-sheet")
  |> Ui.Widget.with_test_id (Ui.Test_id.string "journal-capture-sheet")
;;

let detail_text_field detail dispatch =
  match Journal_detail.editor_value detail with
  | None -> styled_text (Journal_model.source (Journal_detail.root detail))
  | Some value ->
    Ui.Material.text_field
      ~key:(Ui.Key.string "detail-editor")
      ~enabled:(Journal_detail.mode detail = Journal_detail.Editing)
      ~keyboard_type:Ui.Text_editing.Multiline
      ~input_action:Ui.Text_editing.Newline
      ~max_utf8_bytes:65_536
      ~session_id:(Journal_detail.session_id detail)
      ~document_revision:(Journal_detail.document_revision detail)
      ~accepted_local_revision:(Journal_detail.accepted_local_revision detail)
      ~update_mode:(Journal_detail.update_mode detail)
      ~value
      ~on_edit:dispatch
      ~on_submit:dispatch
      ~on_focus_changed:dispatch
      ~on_limit_reached:dispatch
      ()
    |> Ui.Widget.with_test_id (Ui.Test_id.string "detail-editor")
;;

let child_editor detail dispatch =
  match Journal_detail.child_capture detail with
  | None -> Ui.Widget.empty ()
  | Some capture ->
    let editor =
      Ui.Material.text_field
        ~key:(Ui.Key.string "detail-child-editor")
        ~enabled:true
        ~keyboard_type:Ui.Text_editing.Multiline
        ~input_action:Ui.Text_editing.Newline
        ~autofocus:true
        ~max_utf8_bytes:65_536
        ~session_id:(Journal_capture.session_id capture)
        ~document_revision:(Journal_capture.document_revision capture)
        ~accepted_local_revision:(Journal_capture.accepted_local_revision capture)
        ~update_mode:(Journal_capture.update_mode capture)
        ~value:(Journal_capture.value capture)
        ~on_edit:dispatch
        ~on_submit:dispatch
        ~on_focus_changed:dispatch
        ~on_limit_reached:dispatch
        ()
      |> Ui.Widget.with_test_id (Ui.Test_id.string "detail-child-editor")
    in
    Ui.Widget.Flex.column
      [ Ui.Widget.Flex.fixed
          (Ui.Widget.constrained_box
             ~constraints:
               (Ui.Layout.Box_constraints.create ~min_height:120. ~max_height:120. ())
             editor)
      ; Ui.Widget.Flex.fixed
          (action_target
             ~enabled:(Journal_capture.can_save capture)
             ~test_id:"detail-child-save"
             ~label:"Save direct child"
             ~hint:"Persist this direct child"
             ~on_press:(bind_action dispatch "detail-child-save")
             (styled_text "Save child"))
      ]
;;

let detail_page detail dispatch =
  let root = Journal_detail.root detail in
  let navigation_enabled =
    match Journal_detail.mode detail with
    | Journal_detail.Saving | Saving_child -> false
    | Reading
    | Editing
    | Confirm_discard
    | Conflict
    | Failed _
    | Adding_child
    | Committed -> true
  in
  let back =
    action_target
      ~enabled:navigation_enabled
      ~test_id:"detail-back"
      ~label:"Back to Timeline"
      ~hint:"Return to the Timeline anchor"
      ~on_press:(bind_action dispatch "back")
      (styled_text "Back")
  in
  let save =
    action_target
      ~enabled:(Journal_detail.can_save detail)
      ~test_id:"detail-save"
      ~label:"Save entry changes"
      ~hint:"Persist the complete source"
      ~on_press:(bind_action dispatch "detail-save")
      (styled_text "Save")
  in
  let add_child =
    action_target
      ~test_id:"detail-add-child"
      ~label:"Add direct child"
      ~hint:"Create one direct child block"
      ~on_press:(bind_action dispatch "detail-add-child")
      (styled_text "Add child")
  in
  let task =
    action_target
      ~test_id:"detail-task"
      ~label:"Toggle task completion"
      ~hint:"Persist task state without leaving Detail"
      ~on_press:(bind_action dispatch "detail-task")
      (styled_text
         (match Journal_model.task_state root with
          | Journal_model.Todo -> "Mark done"
          | Done -> "Mark todo"
          | Not_a_task -> "Make task"))
  in
  let children =
    Journal_detail.children detail
    |> List.map (fun child ->
      styled_text (Journal_model.source child)
      |> Ui.Widget.with_test_id
           (Ui.Test_id.string ("detail-child:" ^ Journal_model.id child)))
  in
  let status =
    match Journal_detail.mode detail with
    | Journal_detail.Conflict ->
      Ui.Widget.Flex.row
        [ Ui.Widget.Flex.expanded
            (live_region_text ~color:(color 176 32 32) "A newer version exists")
        ; Ui.Widget.Flex.fixed
            (action_target
               ~test_id:"detail-retry"
               ~label:"Retry edit"
               ~hint:"Rebase the local draft on the latest revision"
               ~on_press:(bind_action dispatch "detail-retry")
               (styled_text "Retry"))
        ]
    | Failed message ->
      Ui.Widget.Flex.row
        [ Ui.Widget.Flex.expanded (live_region_text ~color:(color 176 32 32) message)
        ; Ui.Widget.Flex.fixed
            (action_target
               ~test_id:"detail-retry"
               ~label:"Retry mutation"
               ~hint:"Retry the admitted mutation"
               ~on_press:(bind_action dispatch "detail-retry")
               (styled_text "Retry"))
        ]
    | Saving | Saving_child -> live_region_text "Saving"
    | Reading | Editing | Confirm_discard | Adding_child | Committed -> Ui.Widget.empty ()
  in
  let content =
    Ui.Widget.Flex.column
      [ Ui.Widget.Flex.fixed
          (Ui.Widget.Flex.row
             [ Ui.Widget.Flex.expanded back
             ; Ui.Widget.Flex.fixed
                 (styled_text ~size:22. ~weight:Ui.Style.Font_weight.Bold "Entry detail")
             ; Ui.Widget.Flex.expanded save
             ])
      ; Ui.Widget.Flex.fixed (styled_text (Journal_model.source root))
      ; Ui.Widget.Flex.fixed
          (Ui.Widget.Flex.row
             [ Ui.Widget.Flex.expanded task; Ui.Widget.Flex.expanded add_child ])
      ; Ui.Widget.Flex.expanded (detail_text_field detail dispatch)
      ; Ui.Widget.Flex.fixed
          (Ui.Widget.Flex.column (List.map Ui.Widget.Flex.fixed children))
      ; Ui.Widget.Flex.fixed (child_editor detail dispatch)
      ; Ui.Widget.Flex.fixed status
      ]
    |> Ui.Widget.padding ~insets:(Ui.Layout.Edge_insets.all 16.)
    |> Ui.Widget.safe_area
  in
  let dialog =
    if Journal_detail.mode detail <> Journal_detail.Confirm_discard
    then None
    else (
      let keep =
        action_target
          ~test_id:"detail-keep-editing"
          ~label:"Keep editing"
          ~hint:"Return to the local draft"
          ~on_press:(bind_action dispatch "keep-editing")
          (styled_text "Keep editing")
      in
      let discard =
        action_target
          ~test_id:"detail-discard"
          ~label:"Discard Detail changes"
          ~hint:"Return to the saved Detail"
          ~on_press:(bind_action dispatch "discard")
          (styled_text "Discard")
      in
      Some
        (dialog_body
           ~test_id:"detail-discard-dialog"
           ~title:"Discard changes?"
           ~message:"The edited source has not been saved."
           ~primary:keep
           ~secondary:discard))
  in
  route_page
    ~page_key:"journal-detail-route"
    ~transition:Ui.Navigation.None
    (page_body ?dialog content)
;;

let message_page ~page_key ~title dispatch =
  let content =
    Ui.Widget.Flex.column
      [ Ui.Widget.Flex.fixed
          (action_target
             ~test_id:(page_key ^ "-back")
             ~label:"Back to Timeline"
             ~hint:"Return to the Timeline anchor"
             ~on_press:(bind_action dispatch "back")
             (styled_text "Back"))
      ; Ui.Widget.Flex.expanded
          (styled_text ~size:20. ~weight:Ui.Style.Font_weight.Bold title
           |> Ui.Widget.center
           |> Ui.Widget.semantics
                ~properties:(Ui.Semantics.create ~label:title ~live_region:true ()))
      ]
    |> Ui.Widget.safe_area
  in
  route_page ~page_key ~transition:Ui.Navigation.Fade (Ui.Widget.Body.static content)
;;

let identity_sequence = ref 0L

let fresh_identity () =
  identity_sequence := Int64.succ !identity_sequence;
  let entropy =
    Printf.sprintf "%f:%Ld:%d" (Unix.gettimeofday ()) !identity_sequence (Unix.getpid ())
    |> Digest.string
    |> Digest.to_hex
  in
  Printf.sprintf
    "%s-%s-4%s-8%s-%s"
    (String.sub entropy 0 8)
    (String.sub entropy 8 4)
    (String.sub entropy 13 3)
    (String.sub entropy 17 3)
    (String.sub entropy 20 12)
;;

let sibling_order value = Printf.sprintf "%012Ld" value

let creation_time (calendar : Journal_calendar.t) =
  Journal_time.create
    ~instant_unix_ms:calendar.instant_unix_ms
    ~local_day:calendar.local_day
    ~local_minute_of_day:calendar.local_minute_of_day
    ~time_zone_id:calendar.time_zone_id
    ~utc_offset_seconds:calendar.utc_offset_seconds
;;

let component client handlers graph =
  let state, set_state = Bonsai_v017.state ~equal:( = ) initial_state graph in
  let set_state_ref = ref None in
  let state_ref = ref initial_state in
  let graph_runtime = Journal_graph_runtime.create () in
  let submit request = Journal_graph_runtime.submit graph_runtime request in
  let pending_delete_ref : pending_delete option ref = ref None in
  let clear_delete_command response =
    match (response : Journal_graph_runtime.response).payload with
    | Subtree_deleted _ | Delete_conflict _ | Open_failed _ | Rejected _ ->
      pending_delete_ref := None
    | Graph_ready _
    | Feed_loaded _
    | Day_blocks_loaded _
    | Detail_loaded _
    | Block_captured _
    | Block_updated _
    | Update_conflict _
    | Child_created _
    | Block_found _ -> ()
  in
  let fail_graph_transport state message =
    pending_delete_ref := None;
    terminal_graph_state state message
  in
  let deliver_output output =
    Journal_graph_transport.deliver
      ~runtime:graph_runtime
      ~send:(fun request ->
        match Worker.send client request with
        | Accepted _ -> Journal_graph_transport.Accepted
        | Full -> Full
        | Not_ready -> Not_ready
        | Stopping -> Stopping)
      output
  in
  let apply_delivery_responses state delivery =
    let state =
      List.fold_left
        (fun state response -> apply_worker_response state response)
        state
        delivery.Journal_graph_transport.responses
    in
    match delivery.error with
    | None -> state
    | Some message -> fail_graph_transport state message
  in
  let send request =
    let output = submit request in
    Bonsai.Effect.bind
      (Bonsai.Effect.of_thunk (fun () -> deliver_output output))
      ~f:(fun delivery ->
        List.iter clear_delete_command delivery.responses;
        match !set_state_ref with
        | None -> Bonsai.Effect.Ignore
        | Some set_state ->
          set_state (fun state -> apply_delivery_responses state delivery))
  in
  let timer_branch =
    Bonsai.Cont.map state ~f:(fun state ->
      if Option.is_some state.pending_delete then 1 else 0)
  in
  let delete_timer =
    Bonsai.Cont.Let_syntax.Let_syntax.switch
      ~here:(Core.Source_code_position.of_pos __POS__)
      ~match_:timer_branch
      ~branches:2
      ~with_:(fun branch ->
        if branch = 0
        then Bonsai.Cont.return ()
        else (
          let until = Bonsai.Cont.Clock.until graph in
          let on_activate =
            Bonsai.Cont.map3 state set_state until ~f:(fun snapshot set_state until ->
              match snapshot.pending_delete with
              | None -> Bonsai.Effect.Ignore
              | Some activated ->
                let delayed_commit =
                  Bonsai.Effect.bind (until activated.deadline) ~f:(fun () ->
                    match !pending_delete_ref with
                    | Some latest
                      when String.equal latest.mutation_id activated.mutation_id
                           && latest.phase = Undoable ->
                      let committing = { latest with phase = Committing } in
                      pending_delete_ref := Some committing;
                      let request : Journal_graph_projection.delete_subtree =
                        { mutation_id = latest.mutation_id
                        ; block_id = latest.block_id
                        ; expected_revision = latest.expected_revision
                        }
                      in
                      Bonsai.Effect.Many
                        [ set_state (fun state ->
                            match state.pending_delete with
                            | Some pending
                              when String.equal pending.mutation_id latest.mutation_id
                                   && pending.phase = Undoable ->
                              { state with
                                pending_delete = Some committing
                              ; timeline_notice = None
                              }
                            | None | Some _ -> state)
                        ; send (Journal_graph_request.Delete_subtree request)
                        ]
                    | None | Some _ -> Bonsai.Effect.Ignore)
                in
                Bonsai.Effect.of_thunk (fun () ->
                  Bonsai.Effect.Expert.handle delayed_commit))
          in
          Bonsai.Cont.Edge.lifecycle ~on_activate graph;
          Bonsai.Cont.return ()))
  in
  let application_platform = Driver.Handler.application_platform handlers in
  let registered = ref false in
  let apply_response_and_drain response state =
    let state = apply_worker_response state response in
    match response.Journal_graph_runtime.payload with
    | Detail_loaded _ ->
      (match Journal_timeline_state.next_request state.timeline with
       | Some (Journal_timeline_state.Children _ as request) ->
         let generation = state.next_request_generation in
         let output = submit (worker_request generation request) in
         let delivery = deliver_output output in
         List.iter clear_delete_command delivery.responses;
         let state = apply_delivery_responses state delivery in
         (match delivery.error with
          | Some _ -> state
          | None ->
            { state with
              timeline =
                Journal_timeline_state.begin_request state.timeline ~generation request
            ; next_request_generation = Int64.succ generation
            })
       | Some (Feed _ | Day _) | None -> state)
    | Graph_ready _
    | Block_captured _
    | Child_created _
    | Block_updated _
    | Update_conflict _
    | Subtree_deleted _
    | Delete_conflict _
    | Block_found _
    | Feed_loaded _
    | Day_blocks_loaded _
    | Open_failed _
    | Rejected _ -> state
  in
  let event_subscription =
    Bonsai.Cont.map2 state set_state ~f:(fun snapshot set_state ->
      state_ref := snapshot;
      set_state_ref := Some set_state;
      if not !registered
      then (
        registered := true;
        let startup_delivery =
          deliver_output
            Journal_graph_runtime.
              { requests = [ start graph_runtime ]; responses = [] }
        in
        (match startup_delivery.error with
         | None -> ()
         | Some message ->
           set_state (fun state -> fail_graph_transport state message)
           |> Bonsai.Effect.Expert.handle);
        Worker.on_event client (fun event ->
          match event with
          | Worker.Push
              { payload = Logseq_db_worker.Protocol.Graph_invalidated invalidation; _ } ->
            let snapshot = !state_ref in
            if not snapshot.graph_ready
            then Bonsai.Effect.Ignore
            else (
              let generation = snapshot.next_request_generation in
              let output =
                Journal_graph_runtime.reconcile_invalidation
                  graph_runtime
                  ~request_generation:generation
                  invalidation
              in
              if output.requests = [] && output.responses = []
              then Bonsai.Effect.Ignore
              else
                let reloads_feed =
                  List.exists
                    (fun (request : Logseq_db_worker.Protocol.request) ->
                       match request.command with
                       | Read (List_pages _) -> true
                       | Read _ | Mutate _ -> false)
                    output.requests
                in
                Bonsai.Effect.bind
                  (Bonsai.Effect.of_thunk (fun () -> deliver_output output))
                  ~f:(fun delivery ->
                    List.iter clear_delete_command delivery.responses;
                    set_state (fun state ->
                      let state = apply_delivery_responses state delivery in
                      match delivery.error, reloads_feed, state.calendar with
                      | None, true, Some calendar when state.graph_ready ->
                        { state with
                          timeline =
                            (Journal_timeline_state.empty ~today:calendar.local_day
                             |> fun timeline ->
                             Journal_timeline_state.begin_request
                               timeline
                               ~generation
                               (Feed { before_day = None }))
                        ; feed_loaded = false
                        ; next_request_generation = Int64.succ generation
                        }
                      | None, false, _
                      | None, true, None
                      | None, true, Some _
                      | Some _, _, _ -> state)))
          | Worker.Response
              { outcome =
                  Worker.Completed
                    (response : Logseq_db_worker.Protocol.response)
              ; _
              } ->
            let output = Journal_graph_runtime.receive graph_runtime response in
            Bonsai.Effect.bind
              (Bonsai.Effect.of_thunk (fun () -> deliver_output output))
              ~f:(fun delivery ->
                List.iter clear_delete_command delivery.responses;
                set_state (fun state ->
                  let state =
                    List.fold_left
                      (fun state response -> apply_response_and_drain response state)
                      state
                      delivery.responses
                  in
                  match delivery.error with
                  | None -> state
                  | Some message -> fail_graph_transport state message))
          | Worker.Response { outcome = Failed error; _ } ->
            pending_delete_ref := None;
            set_state (fun state -> fail_active_mutation state error)
          | Worker.Response { outcome = Cancelled | Shutdown; _ } ->
            pending_delete_ref := None;
            set_state (fun state -> fail_active_mutation state "Worker unavailable")
          | Worker.Terminal { error; _ } ->
            pending_delete_ref := None;
            set_state (fun state -> terminal_graph_state state error)));
      ())
  in
  let platform_registered = ref false in
  let platform_subscription =
    Bonsai.Cont.map set_state ~f:(fun set_state ->
      if not !platform_registered
      then (
        platform_registered := true;
        let apply_calendar payload =
          match Journal_platform.decode_calendar payload with
          | Error _ -> Bonsai.Effect.Ignore
          | Ok event ->
            Journal_graph_runtime.set_calendar graph_runtime event.snapshot;
            set_state (fun state ->
              match state.calendar with
              | Some current
                when Int64.compare current.generation event.snapshot.generation >= 0
                -> state
              | None | Some _ ->
                { state with
                  calendar = Some event.snapshot
                ; formatted_generation = None
                ; day_labels = []
                })
        in
        Platform.on_event application_platform apply_calendar;
        Platform.request application_platform Journal_platform.get_calendar_request
        |> Bonsai.Effect.bind ~f:(function
          | Error _ -> Bonsai.Effect.Ignore
          | Ok payload -> apply_calendar payload)
        |> Bonsai.Effect.Expert.handle);
      ())
  in
  let feed_key =
    Bonsai.Cont.map state ~f:(fun state ->
      match state.graph_ready, state.calendar with
      | true, Some calendar -> Some (calendar.generation, calendar.local_day)
      | false, _ | true, None -> None)
  in
  let feed_callback =
    Bonsai.Cont.map2 state set_state ~f:(fun snapshot set_state -> function
      | None -> Bonsai.Effect.Ignore
      | Some (calendar_generation, today) ->
        (match snapshot.calendar with
         | Some calendar
           when snapshot.graph_ready
                && Int64.equal calendar.generation calendar_generation
                && calendar.local_day = today ->
           let generation = snapshot.next_request_generation in
           let output =
             submit
               (Journal_graph_request.Load_feed
                  { before_day = None
                  ; day_limit = feed_day_limit
                  ; blocks_per_day = 64
                  ; slot_limit = 128
                  ; request_generation = generation
                 })
           in
           let request = Journal_timeline_state.Feed { before_day = None } in
           Bonsai.Effect.bind
             (Bonsai.Effect.of_thunk (fun () -> deliver_output output))
             ~f:(fun delivery ->
               List.iter clear_delete_command delivery.responses;
               set_state (fun state ->
                 let state = apply_delivery_responses state delivery in
                 match delivery.error, state.calendar with
                 | ( None
                   , Some current )
                   when state.graph_ready
                        && Int64.equal current.generation calendar_generation
                        && current.local_day = today ->
                   { state with
                     timeline =
                       (Journal_timeline_state.empty ~today
                        |> fun timeline ->
                        Journal_timeline_state.begin_request timeline ~generation request)
                   ; feed_loaded = false
                   ; next_request_generation = Int64.succ generation
                   }
                 | Some _, _ | None, None | None, Some _ -> state))
         | None | Some _ -> Bonsai.Effect.Ignore))
  in
  Bonsai.Cont.Edge.on_change
    ~equal:
      (Option.equal (fun (left_generation, left_day) (right_generation, right_day) ->
         Int64.equal left_generation right_generation && left_day = right_day))
    feed_key
    ~callback:feed_callback
    graph;
  let format_key =
    Bonsai.Cont.map state ~f:(fun state ->
      match state.calendar with
      | Some calendar when state.feed_loaded ->
        Some (calendar.generation, distinct_days state)
      | None | Some _ -> None)
  in
  let format_callback =
    Bonsai.Cont.map set_state ~f:(fun set_state request_key ->
      match request_key with
      | None -> Bonsai.Effect.Ignore
      | Some (generation, days) ->
        (match Journal_platform.format_journal_days_request ~generation days with
         | Error _ -> Bonsai.Effect.Ignore
         | Ok request ->
           Bonsai.Effect.bind
             (Platform.request application_platform request)
             ~f:(fun result ->
               match result with
               | Error _ -> Bonsai.Effect.Ignore
               | Ok payload ->
                 (match Journal_platform.decode_formatted_journal_days payload with
                  | Error _ -> Bonsai.Effect.Ignore
                  | Ok formatted
                    when Int64.equal formatted.generation generation
                         && List.map fst formatted.headings
                            |> List.sort Int.compare
                            = days ->
                    set_state (fun state ->
                      match state.calendar with
                      | Some calendar when Int64.equal calendar.generation generation ->
                        { state with
                          formatted_generation = Some generation
                        ; day_labels = formatted.headings
                        }
                      | None | Some _ -> state)
                  | Ok _ -> Bonsai.Effect.Ignore))))
  in
  Bonsai.Cont.Edge.on_change
    ~equal:
      (Option.equal (fun (left_generation, left_days) (right_generation, right_days) ->
         Int64.equal left_generation right_generation && left_days = right_days))
    format_key
    ~callback:format_callback
    graph;
  let environment =
    Driver.Handler.environment handlers |> Bonsai_flutter.Environment.value
  in
  let current_time = Bonsai.Cont.Clock.get_current_time graph in
  let dependencies =
    Bonsai.Cont.map4
      state
      set_state
      environment
      current_time
      ~f:(fun state set_state environment current_time ->
        state, set_state, environment, current_time)
  in
  let dispatch =
    Driver.Handler.create
      handlers
      ~name:"journal-dispatch"
      ~equal:
        (fun
          (left, left_set, left_environment, left_time)
          (right, right_set, right_environment, right_time) ->
        left = right
        && left_set == right_set
        && left_environment = right_environment
        && left_time == right_time)
      dependencies
      ~f:(fun (snapshot, set_state, environment, current_time) payload ->
        let update f = set_state f in
        let with_request next request =
          Bonsai.Effect.Many [ update (fun _ -> next); send request ]
        in
        let open_capture source =
          update (fun state ->
            match state.write_enabled, state.pending_delete with
            | false, _ | true, Some _ -> state
            | true, None ->
              let session_number = state.next_local_sequence in
              { state with
                routes =
                  Journal_routes.open_capture
                    state.routes
                    ~session_number
                    ~source
              ; next_local_sequence = Int64.succ session_number
              })
        in
        match payload with
        | Ui.Event.Payload.Text_edit edit ->
          update (fun state ->
            match
              Journal_routes.capture state.routes, Journal_routes.detail state.routes
            with
            | Some capture, _ ->
              { state with
                routes =
                  Journal_routes.update_capture
                    state.routes
                    (Journal_capture.apply_text_edit capture edit)
              }
            | None, Some detail when Option.is_some (Journal_detail.child_capture detail)
              ->
              { state with
                routes =
                  Journal_routes.update_detail
                    state.routes
                    (Journal_detail.apply_child_text_edit detail edit)
              }
            | None, Some detail ->
              { state with
                routes =
                  Journal_routes.update_detail
                    state.routes
                    (Journal_detail.apply_text_edit detail edit)
              }
            | None, None -> state)
        | Ui.Event.Payload.Native_event _ as payload ->
          (match Ui.Native_widget.Message_composer.event_of_payload payload with
           | Some (Text_changed _) -> Bonsai.Effect.Ignore
           | Some (Button_pressed { button_id = 1; _ }) -> open_capture ""
           | Some (Button_pressed { button_id = 2; text })
             when String.equal (String.trim text) "" -> Bonsai.Effect.Ignore
           | Some (Button_pressed { button_id = 2; text }) -> open_capture text
           | Some (Button_pressed _) -> Bonsai.Effect.Ignore
           | None ->
             (match Ui.Native_widget.Sparse_extent_list.visible_range_of_payload payload with
              | None -> Bonsai.Effect.Ignore
              | Some range ->
             let observe timeline =
               let total_count = Journal_timeline_state.total_count timeline in
               let bounded value =
                 value
                 |> Int64.max 0L
                 |> Int64.min (Int64.of_int total_count)
                 |> Int64.to_int
               in
               let first_index = bounded range.first_index in
               let last_exclusive = bounded range.last_exclusive in
               ( Journal_timeline_state.observe_visible_range
                   timeline
                   ~first_index
                   ~last_exclusive
               , first_index
               , last_exclusive )
             in
             let timeline, first_index, last_exclusive = observe snapshot.timeline in
             (match
                Journal_timeline_state.request_for_visible_range
                  timeline
                  ~first_index
                  ~last_exclusive
              with
              | None ->
                update (fun state ->
                  let timeline, _, _ = observe state.timeline in
                  { state with timeline })
              | Some request ->
                let generation = snapshot.next_request_generation in
                with_request
                  { snapshot with
                    timeline =
                      Journal_timeline_state.begin_request timeline ~generation request
                  ; next_request_generation = Int64.succ generation
                  }
                    (worker_request generation request))))
        | Ui.Event.Payload.Route_pop _ -> update back_state
        | Ui.Event.Payload.Text action ->
          if String.equal action "open-capture"
          then open_capture ""
          else if String.equal action "delete-undo"
          then (
            pending_delete_ref := None;
            update (fun state ->
              match state.pending_delete with
              | Some { phase = Undoable; staged; _ } ->
                { state with
                  timeline = Journal_timeline_state.undo_delete staged
                ; pending_delete = None
                ; timeline_notice = None
                }
              | None | Some { phase = Committing; _ } -> state))
          else if String.equal action "capture-close" || String.equal action "back"
          then update back_state
          else if String.equal action "keep-editing"
          then
            update (fun state ->
              { state with routes = Journal_routes.keep_editing state.routes })
          else if String.equal action "discard"
          then
            update (fun state ->
              { state with routes = Journal_routes.discard state.routes })
          else if String.equal action "capture-task"
          then
            update (fun state ->
              match Journal_routes.capture state.routes with
              | None -> state
              | Some capture ->
                { state with
                  routes =
                    Journal_routes.update_capture
                      state.routes
                      (Journal_capture.toggle_task capture)
                })
          else if String.equal action "capture-add-child"
          then
            update (fun state ->
              match Journal_routes.capture state.routes with
              | None -> state
              | Some capture ->
                let session_number = state.next_local_sequence in
                { state with
                  routes =
                    Journal_routes.update_capture
                      state.routes
                      (Journal_capture.add_child capture ~session_number)
                ; next_local_sequence = Int64.succ session_number
                })
          else if String.equal action "capture-save"
          then (
            match Journal_routes.capture snapshot.routes, snapshot.calendar with
            | Some capture, Some calendar ->
              (match creation_time calendar with
               | Error _ -> Bonsai.Effect.Ignore
               | Ok creation_time ->
                 let number = snapshot.next_local_sequence in
                 let child_identities =
                   Journal_capture.child_editors capture
                   |> List.mapi (fun index _ ->
                     ( fresh_identity ()
                     , fresh_identity ()
                     , sibling_order
                         Int64.(add number (of_int (index + 1))) ))
                 in
                 let capture, request =
                   Journal_capture.admit_save
                     capture
                     ~mutation_id:(fresh_identity ())
                     ~block_id:(fresh_identity ())
                     ~sibling_order:(sibling_order number)
                     ~child_identities
                     ~calendar_generation:calendar.generation
                     ~creation_time
                 in
                 (match request with
                  | None -> Bonsai.Effect.Ignore
                  | Some request ->
                    with_request
                      { snapshot with
                        routes = Journal_routes.update_capture snapshot.routes capture
                      ; next_local_sequence =
                          Int64.add
                            number
                            (Int64.of_int (List.length child_identities + 1))
                      }
                      request))
            | None, _ | _, None -> Bonsai.Effect.Ignore)
          else if String.equal action "capture-retry"
          then (
            match Journal_routes.capture snapshot.routes with
            | None -> Bonsai.Effect.Ignore
            | Some capture ->
              let capture, request = Journal_capture.retry capture in
              (match request with
               | None -> Bonsai.Effect.Ignore
               | Some request ->
                 with_request
                   { snapshot with
                     routes = Journal_routes.update_capture snapshot.routes capture
                   }
                   request))
          else if String.equal action "detail-save"
          then (
            match Journal_routes.detail snapshot.routes with
            | None -> Bonsai.Effect.Ignore
            | Some detail ->
              let number = snapshot.next_local_sequence in
              let detail, request =
                Journal_detail.admit_save detail ~mutation_id:(fresh_identity ())
              in
              (match request with
               | None -> Bonsai.Effect.Ignore
               | Some request ->
                 with_request
                   { snapshot with
                     routes = Journal_routes.update_detail snapshot.routes detail
                   ; next_local_sequence = Int64.succ number
                   }
                   request))
          else if String.equal action "detail-retry"
          then (
            match Journal_routes.detail snapshot.routes with
            | None -> Bonsai.Effect.Ignore
            | Some detail ->
              let number = snapshot.next_local_sequence in
              let detail, request =
                Journal_detail.retry detail ~mutation_id:(fresh_identity ())
              in
              (match request with
               | None -> Bonsai.Effect.Ignore
               | Some request ->
                 with_request
                   { snapshot with
                     routes = Journal_routes.update_detail snapshot.routes detail
                   ; next_local_sequence = Int64.succ number
                   }
                   request))
          else if String.equal action "detail-task"
          then (
            match Journal_routes.detail snapshot.routes with
            | None -> Bonsai.Effect.Ignore
            | Some detail ->
              let number = snapshot.next_local_sequence in
              let detail, request =
                Journal_detail.admit_task_toggle detail ~mutation_id:(fresh_identity ())
              in
              (match request with
               | None -> Bonsai.Effect.Ignore
               | Some request ->
                 with_request
                   { snapshot with
                     routes = Journal_routes.update_detail snapshot.routes detail
                   ; next_local_sequence = Int64.succ number
                   }
                   request))
          else if String.equal action "detail-add-child"
          then
            update (fun state ->
              match Journal_routes.detail state.routes with
              | None -> state
              | Some detail ->
                let number = state.next_local_sequence in
                { state with
                  routes =
                    Journal_routes.update_detail
                      state.routes
                      (Journal_detail.begin_child detail ~session_number:number)
                ; next_local_sequence = Int64.succ number
                })
          else if String.equal action "detail-child-save"
          then (
            match Journal_routes.detail snapshot.routes, snapshot.calendar with
            | Some detail, Some calendar ->
              (match creation_time calendar with
               | Error _ -> Bonsai.Effect.Ignore
               | Ok creation_time ->
                 let number = snapshot.next_local_sequence in
                 let detail, request =
                   Journal_detail.admit_child
                     detail
                     ~mutation_id:(fresh_identity ())
                     ~block_id:(fresh_identity ())
                     ~sibling_order:(sibling_order number)
                     ~creation_time
                 in
                 (match request with
                  | None -> Bonsai.Effect.Ignore
                  | Some request ->
                    with_request
                      { snapshot with
                        routes = Journal_routes.update_detail snapshot.routes detail
                      ; next_local_sequence = Int64.succ number
                      }
                      request))
            | None, _ | _, None -> Bonsai.Effect.Ignore)
          else if String.length action > 16 && String.sub action 0 16 = "timeline-delete:"
          then (
            let block_id = String.sub action 16 (String.length action - 16) in
            match
              ( snapshot.write_enabled
              , snapshot.pending_timeline_mutation
              , snapshot.pending_delete
              , block_in_timeline snapshot.timeline block_id )
            with
            | true, None, None, Some block ->
              (match Journal_timeline_state.stage_delete snapshot.timeline ~block_id with
               | None -> Bonsai.Effect.Ignore
               | Some (timeline, staged) ->
                 let duration = if environment.accessible_navigation then 10. else 5. in
                 Bonsai.Effect.bind current_time ~f:(fun now ->
                   let pending_delete =
                     { mutation_id = fresh_identity ()
                     ; block_id
                     ; expected_revision = Journal_model.revision block
                     ; staged
                     ; deadline = Core.Time_ns.add now (Core.Time_ns.Span.of_sec duration)
                     ; phase = Undoable
                     }
                   in
                   pending_delete_ref := Some pending_delete;
                   update (fun _ ->
                     { snapshot with
                       timeline
                     ; pending_delete = Some pending_delete
                     ; timeline_notice = Some Delete_undo
                     ; next_request_generation =
                         Int64.succ snapshot.next_request_generation
                     })))
            | false, _, _, _
            | true, Some _, _, _
            | true, None, Some _, _
            | true, None, None, None -> Bonsai.Effect.Ignore)
          else if String.length action > 14 && String.sub action 0 14 = "timeline-task:"
          then (
            let block_id = String.sub action 14 (String.length action - 14) in
            match
              ( snapshot.pending_timeline_mutation
              , snapshot.pending_delete
              , block_in_timeline snapshot.timeline block_id )
            with
            | None, None, Some block ->
              let number = snapshot.next_local_sequence in
              let task_state =
                match Journal_model.task_state block with
                | Journal_model.Todo -> Journal_model.Done
                | Done -> Todo
                | Not_a_task -> Todo
              in
              let request =
                Journal_graph_request.Set_task_state
                  { mutation_id = fresh_identity ()
                  ; block_id
                  ; expected_revision = Journal_model.revision block
                  ; task_state
                  }
              in
              with_request
                { snapshot with
                  pending_timeline_mutation = Some block_id
                ; next_local_sequence = Int64.succ number
                }
                request
            | Some _, _, _ | None, Some _, _ | None, None, None -> Bonsai.Effect.Ignore)
          else if
            String.length action > 25
            && String.sub action 0 25 = "timeline-toggle-children:"
          then (
            let block_id = String.sub action 25 (String.length action - 25) in
            match
              snapshot.pending_delete, block_in_timeline snapshot.timeline block_id
            with
            | Some _, _ -> Bonsai.Effect.Ignore
            | None, None -> Bonsai.Effect.Ignore
            | None, Some block when Journal_model.child_count block > 0 ->
              let timeline =
                if Journal_timeline_state.is_expanded snapshot.timeline ~block_id
                then Journal_timeline_state.collapse snapshot.timeline ~parent_id:block_id
                else Journal_timeline_state.expand snapshot.timeline ~parent_id:block_id
              in
              (match Journal_timeline_state.next_request timeline with
               | None -> update (fun state -> { state with timeline })
               | Some request ->
                 let generation = snapshot.next_request_generation in
                 with_request
                   { snapshot with
                     timeline =
                       Journal_timeline_state.begin_request timeline ~generation request
                   ; next_request_generation = Int64.succ generation
                   }
                   (worker_request generation request))
            | None, Some _ -> Bonsai.Effect.Ignore)
          else Bonsai.Effect.Ignore
        | Unit | Bool _ | Int64 _ | Tap _ | Pointer _ | Key _ | Scroll _ | Visible_range _
          -> Bonsai.Effect.Ignore)
  in
  let state = Bonsai.Cont.map2 state delete_timer ~f:(fun state () -> state) in
  let state =
    Bonsai.Cont.map3 state event_subscription platform_subscription ~f:(fun state () () ->
      state)
  in
  Bonsai.Cont.map3 state dispatch environment ~f:(fun state dispatch environment ->
    let reduced_motion =
      environment.reduced_motion
      || environment.disable_animations
      || environment.accessible_navigation
    in
    let tokens = Journal_visual_tokens.resolve ~high_contrast:environment.high_contrast in
    let profile =
      Journal_visual_tokens.select_row_profile
        ~viewport_width:environment.viewport_width
        ~text_scale:environment.text_scale
    in
    let root =
      let content_horizontal_inset =
        Float.max
          0.
          ((environment.viewport_width -. Journal_visual_tokens.timeline_max_width) /. 2.)
      in
      timeline_page
        ~tokens
        ~profile
        ~text_scale:environment.text_scale
        ~device_pixel_ratio:environment.device_pixel_ratio
        ~timeline_state:state.timeline
        ~loading:(not state.feed_loaded)
        ~graph_error:state.graph_error
        ~today_subtitle:(today_label state)
        ~day_label:(label_for_day state)
        ~reduced_motion
        ~rtl:(is_rtl_locale environment.locale)
        ~safe_bottom:environment.safe_area.bottom
        ~viewport_width:environment.viewport_width
        ~content_horizontal_inset
        ~capture_enabled:(state.write_enabled && Option.is_none state.pending_delete)
        ~capture_composer_key:state.next_local_sequence
        ~on_capture_event:dispatch
        ~on_visible_range:dispatch
        ~on_task_toggle:(prefix_action dispatch "timeline-task:")
        ~on_toggle_children:(prefix_action dispatch "timeline-toggle-children:")
        ~delete_enabled:
          (state.write_enabled
           && Option.is_none state.pending_timeline_mutation
           && Option.is_none state.pending_delete)
        ~on_delete:(prefix_action dispatch "timeline-delete:")
        ~timeline_notice:state.timeline_notice
        ~on_delete_undo:(bind_action dispatch "delete-undo")
    in
    let pages =
      match Journal_routes.route state.routes with
      | Journal_routes.Timeline -> [ root ]
      | Capture ->
        (match Journal_routes.capture state.routes with
         | Some capture ->
           [ root
           ; capture_sheet_page
               ~tokens
               ~device_pixel_ratio:environment.device_pixel_ratio
               ~date_context:(today_label state)
               ~reduced_motion
               ~viewport_width:environment.viewport_width
               ~viewport_height:environment.viewport_height
               capture
               dispatch
           ]
         | None -> [ root ])
      | Detail_loading ->
        [ root
        ; message_page ~page_key:"journal-detail-loading" ~title:"Loading entry" dispatch
        ]
      | Detail ->
        (match Journal_routes.detail state.routes with
         | Some detail -> [ root; detail_page detail dispatch ]
         | None -> [ root ])
      | Missing_detail ->
        [ root
        ; message_page
            ~page_key:"journal-detail-missing"
            ~title:"Entry unavailable"
            dispatch
        ]
    in
    Ui.Widget.navigator
      ~key:(Ui.Key.string "journal-navigator")
      ~restoration_scope_id:
        (ID.Navigation.Restoration_scope_id.of_string "logseq-journal")
      ~on_pop:dispatch
      pages
    |> Ui.Widget.with_test_id (Ui.Test_id.string "journal-navigator"))
;;

let decode_config payload =
  match Journal_startup.decode payload with
  | Ok startup -> Ok startup
  | Error error -> Error (Journal_startup.Error.to_string error)
;;

let app =
  App.create_with_worker
    ~name:"Logseq Journal"
    ~decode_config
    ~service:Graph_service.service
    component
;;
