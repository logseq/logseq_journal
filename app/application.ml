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

type feed_projection_context =
  { local_day : int
  ; time_zone_id : string
  ; utc_offset_seconds : int
  }

type feed_refresh_cause =
  | Calendar_refresh
  | Sync_refresh

type feed_refresh =
  { generation : int64
  ; context : feed_projection_context
  ; cause : feed_refresh_cause
  ; graph_generation : Logseq_sync_pure_reducer.Core.graph_id option
  ; minimum_basis : int64 option
  }

type formatting_context =
  { locale : string
  ; days : int list
  }

type modal =
  | No_modal
  | Account
  | Settings
  | Sync_diagnostics
  | Cache_reset_confirmation of Logseq_db_types.Graph_types.Uuid.t

type state =
  { routes : Journal_routes.t
  ; timeline : Journal_timeline_state.t
  ; next_request_generation : int64
  ; next_local_sequence : int64
  ; calendar : Journal_calendar.t option
  ; formatted_context : formatting_context option
  ; day_labels : (int * string) list
  ; pending_delete : pending_delete option
  ; direct_capture : Journal_capture.t option
  ; capture_affordance_key : int64
  ; capture_fab_scroll : Journal_timeline_state.capture_fab_scroll
  ; capture_error : string option
  ; timeline_notice : timeline_notice option
  ; write_enabled : bool
  ; graph_ready : bool
  ; feed_loaded : bool
  ; presented_feed_context : feed_projection_context option
  ; feed_refresh : feed_refresh option
  ; graph_error : string option
  ; sync_error : string option
  ; manager : Logseq_sync_pure_reducer.Core.snapshot option
  ; graph_state : Logseq_db_worker.graph_state
  ; sync_diagnostics : Logseq_sync_pure_reducer.Core.diagnostics option
  ; bootstrap_progress : Logseq_sync_pure_reducer.Core.bootstrap_progress option
  ; e2ee_password : Journal_capture.t
  ; typography_preset : Journal_visual_tokens.typography_preset option
  ; modal : modal
  }

let initial_anchor : Journal_routes.anchor = { block_id = None; first_index = 0 }
let feed_day_limit = 7

let initial_state =
  { routes = Journal_routes.create ~anchor:initial_anchor
  ; timeline = Journal_timeline_state.empty ~today:0
  ; next_request_generation = 1L
  ; next_local_sequence = 1L
  ; calendar = None
  ; formatted_context = None
  ; day_labels = []
  ; pending_delete = None
  ; direct_capture = None
  ; capture_affordance_key = 1L
  ; capture_fab_scroll = Journal_timeline_state.initial_capture_fab_scroll
  ; capture_error = None
  ; timeline_notice = None
  ; write_enabled = false
  ; graph_ready = false
  ; feed_loaded = false
  ; presented_feed_context = None
  ; feed_refresh = None
  ; graph_error = None
  ; sync_error = None
  ; manager = None
  ; graph_state = { generation = -1; graph_id = None; phase = Graph_closed; error = None }
  ; sync_diagnostics = None
  ; bootstrap_progress = None
  ; e2ee_password = Journal_capture.create ~session_number:9_000_000L ~source:""
  ; typography_preset = None
  ; modal = No_modal
  }
;;

let feed_projection_context (calendar : Journal_calendar.t) =
  { local_day = calendar.local_day
  ; time_zone_id = calendar.time_zone_id
  ; utc_offset_seconds = calendar.utc_offset_seconds
  }
;;

let equal_feed_projection_context left right =
  left.local_day = right.local_day
  && String.equal left.time_zone_id right.time_zone_id
  && left.utc_offset_seconds = right.utc_offset_seconds
;;

let equal_formatting_context left right =
  String.equal left.locale right.locale && left.days = right.days
;;

let current_graph_generation state =
  Option.map
    (fun (manager : Logseq_sync_pure_reducer.Core.snapshot) -> manager.selected_graph)
    state.manager
  |> Option.join
;;

let apply_manager_state state (manager_state : Logseq_sync_pure_reducer.Core.state) =
  let snapshot = manager_state.snapshot in
  let graph_context_changed =
    match state.manager with
    | None -> Option.is_some snapshot.selected_graph
    | Some previous ->
      not
        (Option.equal
           Logseq_db_types.Graph_types.Uuid.equal
           previous.selected_graph
           snapshot.selected_graph)
  in
  let was_awaiting_password =
    match state.manager with
    | Some { startup = { awaiting_e2ee_password = true; _ }; _ } -> true
    | None | Some _ -> false
  in
  let is_awaiting_password = snapshot.startup.awaiting_e2ee_password in
  let e2ee_password, next_local_sequence =
    if is_awaiting_password = was_awaiting_password
    then state.e2ee_password, state.next_local_sequence
    else
      ( Journal_capture.create ~session_number:state.next_local_sequence ~source:""
      , Int64.succ state.next_local_sequence )
  in
  let modal =
    match state.modal, snapshot.selected_graph with
    | Cache_reset_confirmation confirmation, Some selected
      when Logseq_db_types.Graph_types.Uuid.equal confirmation selected -> state.modal
    | (No_modal | Account | Settings | Sync_diagnostics), _ -> state.modal
    | Cache_reset_confirmation _, (None | Some _) -> No_modal
  in
  { state with
    manager = Some snapshot
  ; sync_diagnostics = Some manager_state.diagnostics
  ; e2ee_password
  ; next_local_sequence
  ; modal
  ; capture_fab_scroll =
      (if graph_context_changed
       then Journal_timeline_state.initial_capture_fab_scroll
       else state.capture_fab_scroll)
  ; graph_ready = state.graph_ready && not graph_context_changed
  ; sync_error = snapshot.last_error
  ; graph_error = state.graph_error
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
    | Child_preview { block; _ } when String.equal (Journal_model.id block) block_id ->
      Some block
    | Day_heading _
    | Top_level _
    | Child_preview _
    | Day_continuation _
    | Children_loading _
    | Children_more _
    | Feed_continuation _ -> None)
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
    (match state.direct_capture, Journal_routes.detail state.routes with
     | Some capture, _ ->
       { state with
         direct_capture = Some (Journal_capture.fail capture ~message)
       ; capture_error = Some message
       }
     | None, Some detail ->
       { state with
         routes =
           Journal_routes.update_detail state.routes (Journal_detail.fail detail ~message)
       }
     | None, None -> state)
;;

let terminal_graph_state state message =
  { state with
    routes = Journal_routes.graph_unavailable state.routes
  ; write_enabled = false
  ; graph_ready = false
  ; feed_loaded = true
  ; feed_refresh = None
  ; pending_delete = None
  ; timeline_notice = None
  ; graph_error = Some message
  }
;;

let fail_feed_transport state message =
  if state.feed_loaded
  then { state with feed_refresh = None; sync_error = Some message }
  else terminal_graph_state state message
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
      | Children_loading _ | Children_more _ | Feed_continuation _ -> None)
  in
  let days =
    match state.calendar with
    | None -> from_slots
    | Some calendar -> calendar.local_day :: from_slots
  in
  List.sort_uniq Int.compare days
;;

let formatting_context state =
  Option.map
    (fun (calendar : Journal_calendar.t) ->
       { locale = calendar.locale; days = distinct_days state })
    state.calendar
;;

let label_for_day state day =
  match state.formatted_context, formatting_context state with
  | Some formatted, Some current when equal_formatting_context formatted current ->
    Option.value (List.assoc_opt day state.day_labels) ~default:(journal_day_iso day)
  | None, _ | Some _, None | Some _, Some _ -> journal_day_iso day
;;

let today_label state =
  match state.calendar with
  | None -> "Date unavailable"
  | Some calendar ->
    (match state.formatted_context, formatting_context state with
     | Some formatted, Some current when equal_formatting_context formatted current ->
       Option.value
         (List.assoc_opt calendar.local_day state.day_labels)
         ~default:"Date unavailable"
     | None, _ | Some _, None | Some _, Some _ -> "Date unavailable")
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
  | Journal_graph_runtime.Graph_ready info ->
    ignore info.admission_facts;
    { state with write_enabled = true; graph_ready = true; graph_error = None }
  | Feed_loaded { request_generation; feed; complete } ->
    (match state.feed_refresh with
     | Some refresh when Int64.equal refresh.generation request_generation ->
       let current_context = Option.map feed_projection_context state.calendar in
       let current_graph_generation = current_graph_generation state in
       let basis_is_current =
         match refresh.minimum_basis, response.basis with
         | None, _ -> true
         | Some minimum, Some basis -> Int64.compare basis minimum >= 0
         | Some _, None -> false
       in
       if
         Option.equal equal_feed_projection_context current_context (Some refresh.context)
         && current_graph_generation = refresh.graph_generation
         && basis_is_current
       then (
         let today = refresh.context.local_day in
         let timeline =
           match refresh.cause with
           | Calendar_refresh ->
             Journal_timeline_state.set_today state.timeline ~today
             |> fun timeline ->
             Journal_timeline_state.begin_request
               timeline
               ~generation:request_generation
               (Feed { before_day = None })
           | Sync_refresh ->
             Journal_timeline_state.empty ~today
             |> fun timeline ->
             Journal_timeline_state.begin_request
               timeline
               ~generation:request_generation
               (Feed { before_day = None })
         in
         let timeline =
           Journal_timeline_state.apply_feed timeline ~generation:request_generation feed
         in
         let timeline =
           if complete
           then timeline
           else
             Journal_timeline_state.begin_request
               timeline
               ~generation:request_generation
               (Feed { before_day = None })
         in
         { state with
           timeline
         ; feed_loaded = true
         ; presented_feed_context = Some refresh.context
         ; feed_refresh = (if complete then None else state.feed_refresh)
         ; sync_error = None
         })
       else state
     | None | Some _ ->
       let accepted_initial_feed =
         match Journal_timeline_state.pending_request state.timeline with
         | Some (expected_generation, Feed { before_day = None }) ->
           Int64.equal expected_generation request_generation
         | Some (_, Feed { before_day = Some _ })
         | Some (_, Day _)
         | Some (_, Children _)
         | None -> false
       in
       let timeline =
         Journal_timeline_state.apply_feed
           state.timeline
           ~generation:request_generation
           feed
       in
       let timeline =
         if complete || not accepted_initial_feed
         then timeline
         else
           Journal_timeline_state.begin_request
             timeline
             ~generation:request_generation
             (Feed { before_day = None })
       in
       { state with
         timeline
       ; feed_loaded = state.feed_loaded || accepted_initial_feed
       ; presented_feed_context =
           (if accepted_initial_feed
            then Option.map feed_projection_context state.calendar
            else state.presented_feed_context)
       })
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
  | Feed_failed { request_generation; message } ->
    (match state.feed_refresh with
     | Some refresh when Int64.equal refresh.generation request_generation ->
       if state.feed_loaded
       then { state with sync_error = Some message }
       else terminal_graph_state state message
     | None | Some _ ->
       (match Journal_timeline_state.pending_request state.timeline with
        | Some (generation, Feed { before_day = None })
          when Int64.equal generation request_generation ->
          if state.feed_loaded
          then { state with sync_error = Some message }
          else terminal_graph_state state message
        | Some (_, Feed { before_day = Some _ })
        | Some (_, Day _)
        | Some (_, Children _)
        | Some (_, Feed { before_day = None })
        | None -> state))
  | Block_captured { block; timeline_entry_update } ->
    ignore block;
    { state with
      direct_capture = None
    ; capture_affordance_key = Int64.succ state.capture_affordance_key
    ; capture_error = None
    ; timeline =
        Option.fold
          ~none:state.timeline
          ~some:(Journal_timeline_state.prepend_timeline_entry state.timeline)
          timeline_entry_update
    }
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
  | Open_failed error -> terminal_graph_state state (Logseq_db_worker.Error.message error)
  | Rejected _ when Journal_routes.route state.routes = Journal_routes.Detail_loading ->
    { state with
      routes =
        Journal_routes.apply_missing_detail
          state.routes
          ~request_generation:(Journal_routes.detail_request_generation state.routes)
    }
  | Rejected message -> fail_active_mutation state message
;;

let application_theme preset =
  let seed = Ui.Style.Color.rgb ~red:0 ~green:38 ~blue:47 in
  let theme_text_style (token : Journal_visual_tokens.text_token) =
    Ui.Style.Text_style.create
      ~font_size:token.font_size
      ~font_weight:token.weight
      ~line_height:(token.line_height /. token.font_size)
      ()
  in
  let app_typography = Journal_visual_tokens.typography preset in
  let typography =
    Ui.Theme.Typography.material
      ~font_family:"PingFang SC"
      ~font_family_fallback:[ "CupertinoSystemText"; "Apple Color Emoji" ]
      ~title_large:(theme_text_style app_typography.dialog_title)
      ~title_medium:(theme_text_style app_typography.header_subtitle)
      ~body_large:(theme_text_style app_typography.input)
      ~body_medium:(theme_text_style app_typography.supporting)
      ~body_small:(theme_text_style app_typography.timestamp)
      ~label_large:(theme_text_style app_typography.button_label)
      ~label_medium:(theme_text_style app_typography.timestamp)
      ()
  in
  let shape = Ui.Theme.Shape.create ~small:8. ~medium:12. ~large:16. () in
  let data brightness contrast_level =
    Ui.Theme.material
      ~brightness
      ~color_scheme:(Ui.Theme.Color_scheme.from_seed ~color:seed ~contrast_level ())
      ~typography
      ~shape
      ()
  in
  let light = data Ui.Style.Brightness.Light 0. in
  let dark = data Ui.Style.Brightness.Dark 0. in
  let high_contrast_light = data Ui.Style.Brightness.Light 1. in
  let high_contrast_dark = data Ui.Style.Brightness.Dark 1. in
  Ui.Theme.application
    ~mode:Ui.Theme.System
    ~light
    ~dark
    ~high_contrast_light
    ~high_contrast_dark
    ()
;;

let text_style (token : Journal_visual_tokens.text_token) =
  Ui.Style.Text_style.create
    ~font_size:token.font_size
    ~font_weight:token.weight
    ~line_height:(token.line_height /. token.font_size)
    ()
;;

let styled_text ?token value =
  match token with
  | None -> Ui.Widget.text value
  | Some token -> Ui.Widget.text ~style:(text_style token) value
;;

type action_role =
  | Filled
  | Filled_tonal
  | Outlined
  | Text

let action_target
      ?(enabled = true)
      ?(minimum_target = 44.)
      ?key
      ~role
      ~test_id
      ~label
      ~hint
      ~on_press
      child
  =
  let button =
    (match role with
     | Filled -> Ui.Material.filled_button ?key ~enabled ~on_press ~child ()
     | Filled_tonal -> Ui.Material.filled_tonal_button ?key ~enabled ~on_press ~child ()
     | Outlined -> Ui.Material.outlined_button ?key ~enabled ~on_press ~child ()
     | Text -> Ui.Material.text_button ?key ~enabled ~on_press ~child ())
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

let live_region_text value =
  styled_text value
  |> Ui.Widget.semantics
       ~properties:(Ui.Semantics.create ~label:value ~live_region:true ())
;;

let prefix_action handler prefix =
  Ui.Event.Handler.create ~name:("journal-action-prefix:" ^ prefix) (function
    | Ui.Event.Payload.Text value ->
      Ui.Event.Handler.Private.invoke handler (Ui.Event.Payload.Text (prefix ^ value))
    | _ -> ())
;;

let timeline_page
      ~tokens
      ~typography
      ~profile
      ~text_scale
      ~top_inset
      ~bottom_inset
      ~device_pixel_ratio
      ~timeline_state
      ~loading
      ~graph_error
      ~sync_error
      ~cache_reset_available
      ~today_subtitle
      ~day_label
      ~reduced_motion
      ~rtl
      ~content_horizontal_inset
      ~capture_enabled
      ~capture_save_enabled
      ~capture_saving
      ~capture_affordance_key
      ~capture_fab_presentation
      ~on_capture_event
      ~on_scroll
      ~on_visible_range
      ~on_toggle_children
      ~delete_enabled
      ~on_delete
      ~on_cache_reset_requested
      ~account_menu_available
      ~on_account_menu
  =
  let header =
    Journal_header.sliver
      ~typography
      ~text_scale
      ~top_inset
      ~device_pixel_ratio
      ~context:(Journal_header.Context.today ~subtitle:today_subtitle)
      ~on_account_menu:(if account_menu_available then Some on_account_menu else None)
  in
  let capture_button ~id ~tooltip ~position ~visibility ~style ~enabled icon =
    Ui.Native_widget.Expandable_message_composer.button
      ~id
      ~tooltip
      ~position
      ~visibility
      ~style
      ~enabled
      ~child:
        (Material_icon_catalog.create
           ~key:(Ui.Key.string ("journal-capture-action-icon:" ^ string_of_int id))
           ~size:20.
           icon
         |> Ui.Widget.with_test_id (Ui.Test_id.string "journal-capture-composer-submit"))
      ()
  in
  let capture_motion = Journal_visual_tokens.motion ~reduced_motion in
  let capture =
    Ui.Native_widget.Expandable_message_composer.create_with_handler
      ~key:
        (Ui.Key.string
           ("journal-capture-expandable:" ^ Int64.to_string capture_affordance_key))
      ~enabled:capture_enabled
      ~fab_presentation:
        (match capture_fab_presentation with
         | Journal_timeline_state.Extended ->
           Ui.Native_widget.Expandable_message_composer.Extended
         | Compact -> Compact)
      ~fab_label:"Capture"
      ~fab_tooltip:"Open Capture"
      ~fab_icon:
        (Material_icon_catalog.create
           ~key:(Ui.Key.string "journal-capture-fab-icon")
           ~size:20.
           Material_icon_catalog.Add
         |> Ui.Widget.with_test_id (Ui.Test_id.string "journal-capture-fab-icon"))
      ~animation_duration_ms:capture_motion.route_transition_ms
      ~animation_curve:Ui.Animation.Curve.Ease_out
      ~max_lines:Journal_visual_tokens.composer_geometry.maximum_lines
      ~hint_text:"Capture a thought"
      ~buttons:
        [ capture_button
            ~id:1
            ~tooltip:
              (if capture_saving then "Saving journal block" else "Save journal block")
            ~position:Ui.Native_widget.Expandable_message_composer.Trailing
            ~visibility:When_non_empty
            ~style:Filled
            ~enabled:capture_save_enabled
            Material_icon_catalog.Arrow_upward
        ]
      ~on_event:on_capture_event
      ()
    |> Ui.Widget.with_test_id (Ui.Test_id.string "journal-capture-expandable")
  in
  let timeline =
    match graph_error with
    | Some message ->
      Ui.Widget.Sliver.fill
        (live_region_text ("Unable to open Logseq graph: " ^ message)
         |> Ui.Widget.center
         |> Ui.Widget.with_test_id (Ui.Test_id.string "logseq-graph-open-failed"))
      |> Ui.Widget.Sliver.with_test_id (Ui.Test_id.string "journal-timeline")
    | None when loading ->
      Ui.Widget.Sliver.fill (Journal_timeline.loading_view ~typography ())
      |> Ui.Widget.Sliver.with_test_id (Ui.Test_id.string "journal-timeline")
    | None ->
      Journal_timeline.view
        ~tokens
        ~typography
        ~profile
        ~device_pixel_ratio
        ~end_padding:(64. +. bottom_inset)
        ~rtl
        ~state:timeline_state
        ~day_label
        ~reduced_motion
        ~delete_enabled
        ~on_delete
        ~on_visible_range
        ~on_toggle_children
  in
  let timeline =
    Ui.Widget.Scroll_view.vertical
      ~key:(Ui.Key.string "journal-scroll")
      ~on_scroll
      [ header; timeline ]
      ()
    |> Ui.Widget.Viewport.Vertical.with_test_id (Ui.Test_id.string "journal-scroll")
  in
  let base =
    Ui.Widget.Body.Vertical.create [ Ui.Widget.Body.Vertical.fill timeline ]
    |> Ui.Widget.Body.with_test_id (Ui.Test_id.string "journal-root-surface")
  in
  let overlays =
    match sync_error with
    | None -> []
    | Some message ->
      let message = live_region_text message in
      let contents =
        if cache_reset_available
        then
          [ Ui.Widget.Flex.expanded message
          ; Ui.Widget.Flex.fixed
              (action_target
                 ~role:Filled_tonal
                 ~test_id:"request-local-cache-reset"
                 ~label:"Reset local graph copy"
                 ~hint:"Delete this local mirror and download it again"
                 ~on_press:on_cache_reset_requested
                 (styled_text "Reset local copy"))
          ]
        else [ Ui.Widget.Flex.expanded message ]
      in
      let banner =
        Ui.Widget.Flex.row contents
        |> Ui.Widget.padding ~insets:(Ui.Layout.Edge_insets.all 12.)
        |> Ui.Material.card ~elevation:2.
        |> Ui.Widget.with_test_id (Ui.Test_id.string "journal-sync-error")
        |> Ui.Widget.Stack.positioned ~left:16. ~right:16. ~top:64.
      in
      [ banner ]
  in
  let body =
    Ui.Widget.Body.overlay ~base ~overlays ()
    |> Ui.Widget.Body.with_test_id (Ui.Test_id.string "journal-root-overlay")
    |> Ui.Widget.Body.padding
         ~insets:(Ui.Layout.Edge_insets.symmetric ~horizontal:content_horizontal_inset ())
    |> Ui.Widget.Body.with_test_id (Ui.Test_id.string "journal-content-width-padding")
  in
  Ui.Material.scaffold
    ~body
    ~floating_action_button:capture
    ~floating_action_button_location:Ui.Material.End_float
    ()
  |> Ui.Widget.page
       ~key:(Ui.Key.string "journal-timeline")
       ~page_key:(ID.Navigation.Page_key.of_string "journal-timeline")
       ~can_pop:false
  |> Ui.Widget.with_test_id (Ui.Test_id.string "journal-timeline-page")
;;

let dialog_body ~typography ~test_id ~title ~message ~primary ~secondary =
  Ui.Material.alert_dialog
    ~title:(styled_text ~token:typography.Journal_visual_tokens.dialog_title title)
    ~content:(styled_text ~token:typography.supporting message)
    ~actions:[ primary; secondary ]
    ()
  |> Ui.Widget.with_test_id (Ui.Test_id.string test_id)
;;

let modal_dialog_page ~tokens:_ ~reduced_motion ~page_key ~test_id ~barrier_label dialog =
  let transition_ms =
    (Journal_visual_tokens.motion ~reduced_motion).route_transition_ms
  in
  let presentation =
    Ui.Navigation.Modal_dialog.create
      ~barrier_dismissible:false
      ~barrier_label
      ~use_safe_area:true
      ~request_focus:true
      ~transition_duration_ms:transition_ms
      ~reverse_transition_duration_ms:transition_ms
      ()
  in
  dialog
  |> Ui.Widget.page
       ~key:(Ui.Key.string page_key)
       ~page_key:(ID.Navigation.Page_key.of_string page_key)
       ~presentation:(Ui.Navigation.Modal_dialog presentation)
       ~can_pop:false
       ~restoration_id:(ID.Navigation.Restoration_id.of_string page_key)
  |> Ui.Widget.with_test_id (Ui.Test_id.string test_id)
;;

let account_dialog_page
      ~tokens
      ~(typography : Journal_visual_tokens.typography)
      ~reduced_motion
      ~cache_reset_available
      dispatch
  =
  let action ~role ~test_id ~label ~hint ~command text =
    action_target
      ~role
      ~test_id
      ~label
      ~hint
      ~on_press:(bind_action dispatch command)
      (styled_text text)
  in
  let actions =
    [ action
        ~role:Outlined
        ~test_id:"journal-account-settings"
        ~label:"Settings"
        ~hint:"Open application presentation settings"
        ~command:"open-settings"
        "Settings"
    ; action
        ~role:Outlined
        ~test_id:"journal-account-sync-diagnostics"
        ~label:"Sync diagnostics"
        ~hint:"Open read-only sync state diagnostics"
        ~command:"open-sync-diagnostics"
        "Sync diagnostics"
    ; action
        ~role:Outlined
        ~test_id:"journal-account-switch-graph"
        ~label:"Switch graph"
        ~hint:"Close the current graph and choose another authorized graph"
        ~command:"switch-graph"
        "Switch graph"
    ]
    @ (if cache_reset_available
       then
         [ action
             ~role:Filled_tonal
             ~test_id:"journal-account-reset-local-copy"
             ~label:"Reset local graph copy"
             ~hint:"Delete this local mirror and download a fresh snapshot"
             ~command:"request-local-cache-reset"
             "Reset local copy"
         ]
       else [])
    @ [ action
          ~role:Filled
          ~test_id:"journal-account-sign-out"
          ~label:"Sign out"
          ~hint:"Close the current graph and return to sign in"
          ~command:"sign-out"
          "Sign out"
      ; action
          ~role:Text
          ~test_id:"journal-account-menu-dismiss"
          ~label:"Close account menu"
          ~hint:"Return to the journal"
          ~command:"close-account-menu"
          "Cancel"
      ]
  in
  Ui.Material.alert_dialog
    ~title:(styled_text ~token:typography.dialog_title "Account")
    ~content:
      (styled_text
         ~token:typography.supporting
         "Manage the current Logseq graph and authenticated session.")
    ~actions
    ()
  |> Ui.Widget.with_test_id (Ui.Test_id.string "journal-account-menu")
  |> modal_dialog_page
       ~tokens
       ~reduced_motion
       ~page_key:"journal-account-dialog"
       ~test_id:"journal-account-dialog-page"
       ~barrier_label:"Account actions"
;;

let typography_metrics preset =
  match preset with
  | Journal_visual_tokens.Dense ->
    [ "Header title 22/28 SemiBold"
    ; "Entry 15/20 Normal"
    ; "Supporting text 14/20 Normal"
    ; "Button label 14/20 Medium"
    ; "Manager title 24/32 SemiBold"
    ]
  | Balanced ->
    [ "Header title 22/28 SemiBold"
    ; "Entry 16/22 Normal"
    ; "Supporting text 14/20 Normal"
    ; "Button label 14/20 Medium"
    ; "Manager title 24/32 SemiBold"
    ]
  | Comfortable ->
    [ "Header title 24/32 SemiBold"
    ; "Entry 17/24 Normal"
    ; "Supporting text 15/22 Normal"
    ; "Button label 15/20 Medium"
    ; "Manager title 28/34 SemiBold"
    ]
;;

let settings_dialog_page ~tokens ~typography ~preset ~reduced_motion dispatch =
  let chip option label command test_id =
    let selected = preset = option in
    let on_selected = bind_action dispatch command in
    Ui.Material.choice_chip
      ~key:(Ui.Key.string test_id)
      ~selected
      ~on_selected
      ~label:(styled_text ~token:typography.Journal_visual_tokens.button_label label)
      ()
    |> Ui.Widget.with_test_id (Ui.Test_id.string test_id)
    |> Ui.Widget.semantics
         ~on_action:on_selected
         ~properties:
           (Ui.Semantics.create
              ~label
              ~role:Ui.Semantics.Role.Button
              ~enabled:true
              ~selected
              ~focusable:true
              ~actions:[ Ui.Semantics.Action.Tap ]
              ())
  in
  let choices =
    Ui.Widget.Flex.row
      [ Ui.Widget.Flex.expanded
          (chip
             Journal_visual_tokens.Dense
             "A Dense"
             "select-typography:dense"
             "typography-preset-dense")
      ; Ui.Widget.Flex.expanded
          (chip
             Balanced
             "B Balanced"
             "select-typography:balanced"
             "typography-preset-balanced")
      ; Ui.Widget.Flex.expanded
          (chip
             Comfortable
             "C Comfortable"
             "select-typography:comfortable"
             "typography-preset-comfortable")
      ]
    |> Ui.Widget.semantics
         ~properties:
           (Ui.Semantics.create
              ~label:"Typography preset"
              ~value:(Journal_visual_tokens.stored_value_of_typography_preset preset)
              ())
    |> Ui.Widget.with_test_id (Ui.Test_id.string "typography-preset-group")
  in
  let metrics =
    typography_metrics preset
    |> List.map (fun metric ->
      styled_text ~token:typography.supporting metric |> Ui.Widget.Flex.fixed)
    |> Ui.Widget.Flex.column
    |> Ui.Widget.with_test_id (Ui.Test_id.string "typography-preset-metrics")
  in
  let content =
    Ui.Widget.Flex.column
      [ Ui.Widget.Flex.fixed (styled_text ~token:typography.dialog_title "Typography")
      ; Ui.Widget.Flex.fixed
          (styled_text
             ~token:typography.supporting
             "Choose the reading density used throughout the app.")
      ; Ui.Widget.Flex.fixed choices
      ; Ui.Widget.Flex.fixed metrics
      ]
  in
  let close =
    action_target
      ~role:Text
      ~test_id:"journal-settings-close"
      ~label:"Close Settings"
      ~hint:"Return to the journal"
      ~on_press:(bind_action dispatch "close-settings")
      (styled_text "Close")
  in
  Ui.Material.alert_dialog
    ~title:
      (styled_text ~token:typography.dialog_title "Settings"
       |> Ui.Widget.semantics
            ~properties:
              (Ui.Semantics.create
                 ~label:"Settings"
                 ~role:Ui.Semantics.Role.Header
                 ~heading_level:1
                 ()))
    ~content
    ~actions:[ close ]
    ()
  |> Ui.Widget.with_test_id (Ui.Test_id.string "journal-settings")
  |> modal_dialog_page
       ~tokens
       ~reduced_motion
       ~page_key:"journal-settings-dialog"
       ~test_id:"journal-settings-dialog-page"
       ~barrier_label:"Settings"
;;

let sync_diagnostic_rows (diagnostics : Logseq_sync_pure_reducer.Core.diagnostics) =
  List.concat_map
    (fun (group : Logseq_sync_pure_reducer.Core.diagnostic_group) -> group.entries)
    diagnostics.groups
;;

let diagnostic_groups diagnostics =
  let unavailable labels = List.map (fun label -> label, "Not available") labels in
  match diagnostics with
  | None ->
    [ "Manager", unavailable [ "Phase"; "Startup presentation"; "Last error" ]
    ; ( "Scope fences"
      , unavailable
          [ "Account generation"
          ; "Graph generation"
          ; "Presentation generation"
          ; "Connection generation"
          ] )
    ; ( "Graph"
      , unavailable [ "Graph selected"; "Selected graph"; "Applied server transaction" ] )
    ; "Transport", unavailable [ "Transport scope"; "Transport"; "WebSocket initialized" ]
    ; "Pull", unavailable [ "Pull" ]
    ; "Submission", unavailable [ "Submission" ]
    ; "Recovery", unavailable [ "Reconnect attempt"; "Uncertain transactions" ]
    ; "Serialization", unavailable [ "Serialization" ]
    ; "Authorization", unavailable [ "Pending token challenges" ]
    ]
  | Some (diagnostics : Logseq_sync_pure_reducer.Core.diagnostics) ->
    List.map
      (fun (group : Logseq_sync_pure_reducer.Core.diagnostic_group) -> group.title, group.entries)
      diagnostics.groups
;;

let diagnostic_history_lines = function
  | None -> [ "No transitions" ]
  | Some ({ history = []; _ } : Logseq_sync_pure_reducer.Core.diagnostics) -> [ "No transitions" ]
  | Some ({ history; _ } : Logseq_sync_pure_reducer.Core.diagnostics) -> history
;;

let sync_diagnostics_page
      ~tokens
      ~(typography : Journal_visual_tokens.typography)
      ~reduced_motion
      diagnostics
      dispatch
  =
  let close =
    action_target
      ~role:Text
      ~test_id:"journal-sync-diagnostics-close"
      ~label:"Close Sync diagnostics"
      ~hint:"Return to the journal"
      ~on_press:(bind_action dispatch "close-sync-diagnostics")
      (styled_text "Close")
  in
  let heading title =
    styled_text ~token:typography.dialog_title title
    |> Ui.Widget.padding
         ~insets:(Ui.Layout.Edge_insets.only ~left:16. ~right:16. ~top:16. ~bottom:8. ())
  in
  let row (label, value) =
    Ui.Widget.Flex.column
      [ Ui.Widget.Flex.fixed (styled_text ~token:typography.button_label label)
      ; Ui.Widget.Flex.fixed (styled_text ~token:typography.supporting value)
      ]
    |> Ui.Widget.padding
         ~insets:(Ui.Layout.Edge_insets.symmetric ~horizontal:16. ~vertical:6. ())
  in
  let current =
    diagnostic_groups diagnostics
    |> List.concat_map (fun (title, rows) -> heading title :: List.map row rows)
  in
  let history =
    heading "Recent transitions"
    :: List.map
         (fun line ->
            styled_text ~token:typography.supporting line
            |> Ui.Widget.padding
                 ~insets:(Ui.Layout.Edge_insets.symmetric ~horizontal:16. ~vertical:4. ()))
         (diagnostic_history_lines diagnostics)
  in
  let scroll =
    Ui.Widget.Scroll_view.vertical
      ~key:(Ui.Key.string "journal-sync-diagnostics-scroll")
      ~on_scroll:
        (Ui.Event.Handler.create ~name:"journal-sync-diagnostics-scroll" (fun _ -> ()))
      [ Ui.Widget.Sliver.list (current @ history) ]
      ()
    |> Ui.Widget.Viewport.Vertical.with_test_id
         (Ui.Test_id.string "journal-sync-diagnostics-scroll")
  in
  let header =
    Ui.Widget.Flex.row
      [ Ui.Widget.Flex.expanded
          (styled_text ~token:typography.manager_title "Sync diagnostics"
           |> Ui.Widget.semantics
                ~properties:
                  (Ui.Semantics.create
                     ~label:"Sync diagnostics"
                     ~role:Ui.Semantics.Role.Header
                     ~heading_level:1
                     ()))
      ; Ui.Widget.Flex.fixed close
      ]
    |> Ui.Widget.padding ~insets:(Ui.Layout.Edge_insets.all 16.)
  in
  let body =
    Ui.Widget.Body.Vertical.create
      [ Ui.Widget.Body.Vertical.fixed header; Ui.Widget.Body.Vertical.fill scroll ]
    |> Ui.Widget.Body.safe_area
  in
  Ui.Material.scaffold ~body ()
  |> modal_dialog_page
       ~tokens
       ~reduced_motion
       ~page_key:"journal-sync-diagnostics-dialog"
       ~test_id:"journal-sync-diagnostics-dialog-page"
       ~barrier_label:"Sync diagnostics"
;;

let local_cache_reset_dialog_page ~tokens ~typography ~reduced_motion dispatch =
  let cancel =
    action_target
      ~role:Text
      ~test_id:"cancel-local-cache-reset"
      ~label:"Keep local graph copy"
      ~hint:"Close without deleting local data"
      ~on_press:(bind_action dispatch "cancel-local-cache-reset")
      (styled_text "Cancel")
  in
  let confirm =
    action_target
      ~role:Filled
      ~test_id:"confirm-local-cache-reset"
      ~label:"Delete and redownload local graph copy"
      ~hint:"Delete the local mirror and download it again"
      ~on_press:(bind_action dispatch "confirm-local-cache-reset")
      (styled_text "Delete and redownload")
  in
  dialog_body
    ~typography
    ~test_id:"local-cache-reset-dialog"
    ~title:"Reset local graph copy?"
    ~message:
      "This deletes the local mirror, including pending local changes, then downloads a \
       fresh snapshot. The authorized server graph is not changed."
    ~primary:cancel
    ~secondary:confirm
  |> modal_dialog_page
       ~tokens
       ~reduced_motion
       ~page_key:"local-cache-reset-dialog"
       ~test_id:"local-cache-reset-dialog-page"
       ~barrier_label:"Reset local graph copy confirmation"
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

let detail_text_field ~typography detail dispatch =
  match Journal_detail.editor_value detail with
  | None ->
    styled_text
      ~token:typography.Journal_visual_tokens.entry
      (Journal_model.source (Journal_detail.root detail))
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
             ~role:Filled
             ~test_id:"detail-child-save"
             ~label:"Save direct child"
             ~hint:"Persist this direct child"
             ~on_press:(bind_action dispatch "detail-child-save")
             (styled_text "Save child"))
      ]
;;

let detail_page ~(typography : Journal_visual_tokens.typography) detail dispatch =
  let root = Journal_detail.root detail in
  let navigation_enabled =
    match Journal_detail.mode detail with
    | Journal_detail.Saving | Saving_child -> false
    | Reading | Editing | Confirm_discard | Conflict | Failed _ | Adding_child | Committed
      -> true
  in
  let back =
    action_target
      ~enabled:navigation_enabled
      ~role:Text
      ~test_id:"detail-back"
      ~label:"Back to Timeline"
      ~hint:"Return to the Timeline anchor"
      ~on_press:(bind_action dispatch "back")
      (styled_text "Back")
  in
  let save =
    action_target
      ~enabled:(Journal_detail.can_save detail)
      ~role:Filled
      ~test_id:"detail-save"
      ~label:"Save entry changes"
      ~hint:"Persist the complete source"
      ~on_press:(bind_action dispatch "detail-save")
      (styled_text "Save")
  in
  let add_child =
    action_target
      ~role:Filled_tonal
      ~test_id:"detail-add-child"
      ~label:"Add direct child"
      ~hint:"Create one direct child block"
      ~on_press:(bind_action dispatch "detail-add-child")
      (styled_text "Add child")
  in
  let task =
    action_target
      ~role:Outlined
      ~test_id:"detail-task"
      ~label:"Toggle task completion"
      ~hint:"Persist task state without leaving Detail"
      ~on_press:(bind_action dispatch "detail-task")
      (styled_text
         (match Journal_model.task_state root with
          | Journal_model.No_status -> "Make task"
          | Done | Canceled -> "Mark todo"
          | Todo | Doing | In_review | Now | Backlog | Waiting | Later -> "Mark done"))
  in
  let children =
    Journal_detail.children detail
    |> List.map (fun child ->
      styled_text ~token:typography.supporting (Journal_model.source child)
      |> Ui.Widget.with_test_id
           (Ui.Test_id.string ("detail-child:" ^ Journal_model.id child)))
  in
  let status =
    match Journal_detail.mode detail with
    | Journal_detail.Conflict ->
      Ui.Widget.Flex.row
        [ Ui.Widget.Flex.expanded (live_region_text "A newer version exists")
        ; Ui.Widget.Flex.fixed
            (action_target
               ~role:Filled_tonal
               ~test_id:"detail-retry"
               ~label:"Retry edit"
               ~hint:"Rebase the local draft on the latest revision"
               ~on_press:(bind_action dispatch "detail-retry")
               (styled_text "Retry"))
        ]
    | Failed message ->
      Ui.Widget.Flex.row
        [ Ui.Widget.Flex.expanded (live_region_text message)
        ; Ui.Widget.Flex.fixed
            (action_target
               ~role:Filled_tonal
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
                 (styled_text
                    ~token:typography.Journal_visual_tokens.dialog_title
                    "Entry detail")
             ; Ui.Widget.Flex.expanded save
             ])
      ; Ui.Widget.Flex.fixed
          (styled_text ~token:typography.entry (Journal_model.source root))
      ; Ui.Widget.Flex.fixed
          (Ui.Widget.Flex.row
             [ Ui.Widget.Flex.expanded task; Ui.Widget.Flex.expanded add_child ])
      ; Ui.Widget.Flex.expanded (detail_text_field ~typography detail dispatch)
      ; Ui.Widget.Flex.fixed
          (Ui.Widget.Flex.column (List.map Ui.Widget.Flex.fixed children))
      ; Ui.Widget.Flex.fixed (child_editor detail dispatch)
      ; Ui.Widget.Flex.fixed status
      ]
    |> Ui.Widget.padding ~insets:(Ui.Layout.Edge_insets.all 16.)
    |> Ui.Widget.safe_area
  in
  route_page
    ~page_key:"journal-detail-route"
    ~transition:Ui.Navigation.None
    (Ui.Widget.Body.static content)
;;

let detail_discard_dialog_page ~tokens ~typography ~reduced_motion dispatch =
  let keep =
    action_target
      ~role:Text
      ~test_id:"detail-keep-editing"
      ~label:"Keep editing"
      ~hint:"Return to the local draft"
      ~on_press:(bind_action dispatch "keep-editing")
      (styled_text "Keep editing")
  in
  let discard =
    action_target
      ~role:Filled
      ~test_id:"detail-discard"
      ~label:"Discard Detail changes"
      ~hint:"Return to the saved Detail"
      ~on_press:(bind_action dispatch "discard")
      (styled_text "Discard")
  in
  dialog_body
    ~typography
    ~test_id:"detail-discard-dialog"
    ~title:"Discard changes?"
    ~message:"The edited source has not been saved."
    ~primary:keep
    ~secondary:discard
  |> modal_dialog_page
       ~tokens
       ~reduced_motion
       ~page_key:"detail-discard-dialog"
       ~test_id:"detail-discard-dialog-page"
       ~barrier_label:"Discard Detail changes confirmation"
;;

let message_page ~typography ~page_key ~title dispatch =
  let content =
    Ui.Widget.Flex.column
      [ Ui.Widget.Flex.fixed
          (action_target
             ~role:Text
             ~test_id:(page_key ^ "-back")
             ~label:"Back to Timeline"
             ~hint:"Return to the Timeline anchor"
             ~on_press:(bind_action dispatch "back")
             (styled_text "Back"))
      ; Ui.Widget.Flex.expanded
          (styled_text ~token:typography.Journal_visual_tokens.dialog_title title
           |> Ui.Widget.center
           |> Ui.Widget.semantics
                ~properties:(Ui.Semantics.create ~label:title ~live_region:true ()))
      ]
    |> Ui.Widget.safe_area
  in
  route_page ~page_key ~transition:Ui.Navigation.Fade (Ui.Widget.Body.static content)
;;

let manager_page ~(typography : Journal_visual_tokens.typography) state dispatch =
  let title_widget title =
    styled_text ~token:typography.Journal_visual_tokens.manager_title title
    |> Ui.Widget.semantics
         ~properties:(Ui.Semantics.create ~label:title ~live_region:true ())
  in
  let graph_picker snapshot =
    let refresh =
      let on_press = bind_action dispatch "refresh-catalog" in
      let icon =
        Material_icon_catalog.create ~size:22. Material_icon_catalog.Refresh
        |> Ui.Widget.with_test_id (Ui.Test_id.string "graph-picker-refresh-icon")
      in
      Ui.Material.icon_button
        ~key:(Ui.Key.string "graph-picker-refresh")
        ~on_press
        ~icon
        ()
      |> Ui.Widget.with_test_id (Ui.Test_id.string "graph-picker-refresh")
      |> Ui.Widget.semantics
           ~on_action:on_press
           ~properties:
             (Ui.Semantics.create
                ~label:"Refresh graphs"
                ~hint:"Refresh the authorized graph catalog"
                ~role:Ui.Semantics.Role.Button
                ~enabled:true
                ~focusable:true
                ~actions:[ Ui.Semantics.Action.Tap ]
                ())
      |> Ui.Widget.sized_box ~width:48. ~height:48.
    in
    let toolbar =
      Ui.Widget.Flex.row
        [ Ui.Widget.Flex.expanded (title_widget "Choose a graph")
        ; Ui.Widget.Flex.fixed refresh
        ]
      |> Ui.Widget.with_test_id (Ui.Test_id.string "graph-picker-toolbar")
    in
    let rows =
      List.map
        (fun (graph : Logseq_sync_pure_reducer.Core.graph) ->
           let graph_id = Logseq_db_types.Graph_types.Uuid.to_string graph.graph_id in
           let on_press = bind_action dispatch ("select-graph:" ^ graph_id) in
           Ui.Material.list_tile
             ~key:(Ui.Key.string ("graph-picker:" ^ graph_id))
             ~on_press
             ~title:(styled_text ~token:typography.entry graph.name)
             ()
           |> Ui.Widget.with_test_id (Ui.Test_id.string ("graph-picker:" ^ graph_id))
           |> Ui.Widget.semantics
                ~on_action:on_press
                ~properties:
                  (Ui.Semantics.create
                     ~label:("Open " ^ graph.name)
                     ~hint:"Open this authorized graph"
                     ~role:Ui.Semantics.Role.Button
                     ~enabled:true
                     ~focusable:true
                     ~actions:[ Ui.Semantics.Action.Tap ]
                     ()))
        snapshot.Logseq_sync_pure_reducer.Core.catalog
    in
    let scroll =
      Ui.Widget.Scroll_view.vertical
        ~key:(Ui.Key.string "graph-picker-scroll")
        ~on_scroll:(Ui.Event.Handler.create ~name:"graph-picker-scroll" (fun _ -> ()))
        [ Ui.Widget.Sliver.list rows ]
        ()
      |> Ui.Widget.Viewport.Vertical.with_test_id
           (Ui.Test_id.string "graph-picker-scroll")
      |> Ui.Widget.Viewport.Vertical.padding
           ~insets:(Ui.Layout.Edge_insets.symmetric ~vertical:8. ())
    in
    Ui.Widget.Body.Vertical.create
      [ Ui.Widget.Body.Vertical.fixed toolbar; Ui.Widget.Body.Vertical.fill scroll ]
    |> Ui.Widget.Body.padding ~insets:(Ui.Layout.Edge_insets.all 24.)
    |> Ui.Widget.Body.safe_area
  in
  let compact_body () =
    let title, controls =
      match state.manager with
      | None -> "Preparing your account", []
      | Some snapshot ->
        let startup = Journal_startup.derive ~snapshot ~graph:state.graph_state in
        (match startup.phase with
         | Journal_startup.Signed_out -> "Sign in to open a graph", []
         | Loading_catalog -> "Loading your graphs", []
         | Awaiting_selection -> assert false
         | Restoring_local -> "Restoring your graph", []
         | Bootstrapping ->
           let progress_text =
             match state.bootstrap_progress with
             | None -> "Preparing the local mirror"
             | Some progress ->
               Printf.sprintf
                 "Downloaded %Ld bytes"
                 progress.Logseq_sync_pure_reducer.Core.received_bytes
           in
           ( "Downloading graph"
           , [ Ui.Widget.Flex.fixed
                 (styled_text ~token:typography.supporting progress_text)
             ] )
         | Awaiting_e2ee_password ->
           let password = state.e2ee_password in
           let editor =
             Ui.Material.text_field
               ~key:(Ui.Key.string "e2ee-password-editor")
               ~enabled:true
               ~obscure_text:true
               ~keyboard_type:Ui.Text_editing.Text
               ~input_action:Ui.Text_editing.Done
               ~autofocus:true
               ~max_utf8_bytes:4096
               ~session_id:(Journal_capture.session_id password)
               ~document_revision:(Journal_capture.document_revision password)
               ~accepted_local_revision:(Journal_capture.accepted_local_revision password)
               ~update_mode:(Journal_capture.update_mode password)
               ~value:(Journal_capture.value password)
               ~on_edit:dispatch
               ~on_submit:(bind_action dispatch "submit-e2ee-password")
               ~on_focus_changed:dispatch
               ~on_limit_reached:dispatch
               ()
             |> Ui.Widget.with_test_id (Ui.Test_id.string "e2ee-password-editor")
           in
           let submit =
             action_target
               ~enabled:(Journal_capture.can_save password)
               ~role:Filled
               ~test_id:"e2ee-password-submit"
               ~label:"Unlock encrypted graph"
               ~hint:"Submit the encryption password"
               ~on_press:(bind_action dispatch "submit-e2ee-password")
               (styled_text "Unlock")
           in
           ( "Unlock encrypted graph"
           , [ Ui.Widget.Flex.fixed
                 (styled_text
                    ~token:typography.supporting
                    "Enter your encryption password to continue.")
             ; Ui.Widget.Flex.fixed editor
             ; Ui.Widget.Flex.fixed submit
             ] )
         | Ready -> "Opening journal", []
         | Failed ->
           let message, recovery =
             match startup.error with
             | None -> "Unable to open graph", None
             | Some error -> error.message, error.recovery
           in
           let action =
             match recovery with
             | Some Journal_startup.Refresh_catalog -> Some "refresh-catalog"
             | Some Begin_online_recovery | Some Retry_graph_open ->
               Some "begin-online-recovery"
             | Some Submit_e2ee_password | Some Sign_in | None -> None
           in
           ( message
           , [ Ui.Widget.Flex.fixed
                 (action_target
                    ~role:Filled_tonal
                    ~test_id:"graph-picker-retry"
                    ~label:"Retry"
                    ~hint:"Retry startup"
                    ~enabled:(Option.is_some action)
                    ~on_press:
                      (bind_action
                         dispatch
                         (Option.value action ~default:"retry-disabled"))
                    (styled_text "Retry"))
             ] ))
    in
    Ui.Widget.Flex.column (Ui.Widget.Flex.fixed (title_widget title) :: controls)
    |> Ui.Widget.padding ~insets:(Ui.Layout.Edge_insets.all 24.)
    |> Ui.Widget.safe_area
    |> Ui.Widget.Body.static
  in
  let body =
    match state.manager with
    | Some snapshot
      when (Journal_startup.derive ~snapshot ~graph:state.graph_state).phase
           = Awaiting_selection -> graph_picker snapshot
    | None | Some _ -> compact_body ()
  in
  route_page ~page_key:"sync-manager-route" ~transition:Ui.Navigation.None body
;;

let identity_sequence = ref 0L
let managed_sync_startup = ref true
let managed_sync_origin = ref "https://api.logseq.io"

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
  let started_graph_generation = ref None in
  let send_manager command =
    Bonsai.Effect.of_thunk (fun () ->
      ignore
        (Worker.send client (Graph_service.Client_command command) : Worker.send_result))
  in
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
    | Feed_failed _
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
        match Worker.send client (Graph_service.Graph_request request) with
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
  let observe_graph_state set_state (graph_state : Logseq_db_worker.graph_state) =
    let update =
      set_state (fun state ->
        { state with
          graph_state
        ; graph_ready =
            (if graph_state.phase = Graph_open then state.graph_ready else false)
        ; graph_error =
            (if graph_state.phase = Graph_failed then graph_state.error else None)
        })
    in
    let start_graph =
      match graph_state.phase with
      | Graph_open ->
        let graph_key =
          Option.map Logseq_db_types.Graph_types.Uuid.to_string graph_state.graph_id
          |> Option.value ~default:"local"
        in
        if !started_graph_generation = Some (graph_key, graph_state.generation)
        then Bonsai.Effect.Ignore
        else (
          started_graph_generation := Some (graph_key, graph_state.generation);
          Journal_graph_runtime.reset graph_runtime;
          let current = !state_ref in
          let graph_info = Journal_graph_runtime.start graph_runtime in
          let feed_generation = current.next_request_generation in
          let feed_output =
            match current.calendar with
            | None -> Journal_graph_runtime.{ requests = []; responses = [] }
            | Some _ ->
              submit
                (Journal_graph_request.Load_feed
                   { before_day = None
                   ; day_limit = feed_day_limit
                   ; blocks_per_day = 64
                   ; slot_limit = 128
                   ; request_generation = feed_generation
                   })
          in
          let output =
            Journal_graph_runtime.
              { requests = graph_info :: feed_output.requests
              ; responses = feed_output.responses
              }
          in
          let prepare =
            set_state (fun state ->
              let state =
                { state with
                  graph_ready = false
                ; feed_loaded = false
                ; presented_feed_context = None
                ; feed_refresh = None
                ; graph_error = None
                }
              in
              match state.calendar with
              | None -> state
              | Some calendar ->
                let context = feed_projection_context calendar in
                { state with
                  timeline =
                    (Journal_timeline_state.empty ~today:context.local_day
                     |> fun timeline ->
                     Journal_timeline_state.begin_request
                       timeline
                       ~generation:feed_generation
                       (Feed { before_day = None }))
                ; next_request_generation = Int64.succ feed_generation
                })
          in
          Bonsai.Effect.bind prepare ~f:(fun () ->
            Bonsai.Effect.bind
              (Bonsai.Effect.of_thunk (fun () -> deliver_output output))
              ~f:(fun delivery ->
                set_state (fun state -> apply_delivery_responses state delivery))))
      | Graph_closed | Graph_opening | Graph_closing | Graph_failed ->
        started_graph_generation := None;
        Bonsai.Effect.Ignore
    in
    Bonsai.Effect.bind update ~f:(fun () -> start_graph)
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
  let host_effects = Driver.Handler.host_effects handlers in
  let sign_out_in_flight = ref false in
  let termination_in_flight = ref false in
  let apply_manager_transition set_state manager_state =
    let manager = manager_state.Logseq_sync_pure_reducer.Core.snapshot in
    let update = set_state (fun state -> apply_manager_state state manager_state) in
    let sign_out =
      if (not manager.Logseq_sync_pure_reducer.Core.startup.authenticated) && !sign_out_in_flight
      then (
        sign_out_in_flight := false;
        Bonsai.Effect.bind
          (Platform.request application_platform Journal_platform.sign_out_request)
          ~f:(fun result ->
            set_state (fun state ->
              match result with
              | Ok payload
                when Result.is_ok (Journal_platform.decode_sign_out_response payload) ->
                state
              | Error _ | Ok _ ->
                { state with
                  sync_error = Some "Unable to sign out of the authenticated session"
                })))
      else Bonsai.Effect.Ignore
    in
    let termination_ready =
      if
        !termination_in_flight
        && (manager.Logseq_sync_pure_reducer.Core.startup.awaiting_selection
            || not manager.startup.authenticated)
      then (
        termination_in_flight := false;
        Bonsai.Effect.bind
          (Platform.request
             application_platform
             Journal_platform.termination_ready_request)
          ~f:(fun _ -> Bonsai.Effect.Ignore))
      else Bonsai.Effect.Ignore
    in
    Bonsai.Effect.bind update ~f:(fun () ->
      Bonsai.Effect.Many [ sign_out; termination_ready ])
  in
  let registered = ref false in
  let event_subscription =
    Bonsai.Cont.map2 state set_state ~f:(fun snapshot set_state ->
      state_ref := snapshot;
      set_state_ref := Some set_state;
      if not !registered
      then (
        registered := true;
        ignore (Worker.send client Graph_service.Get_graph_state : Worker.send_result);
        Worker.on_event client (fun event ->
          match event with
          | Worker.Push
              { payload =
                  Graph_service.Graph_push
                    (Logseq_db_worker.Protocol.Graph_invalidated invalidation)
              ; _
              } ->
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
              else (
                let reloads_feed =
                  List.exists
                    (fun (request : Logseq_db_worker.Protocol.request) ->
                       match request.command with
                       | Read (List_pages _) -> true
                       | _ -> false)
                    output.requests
                in
                let sent_request = output.requests <> [] in
                let prepare =
                  if sent_request && reloads_feed
                  then
                    set_state (fun state ->
                      match state.calendar with
                      | Some calendar when state.graph_ready ->
                        let context = feed_projection_context calendar in
                        let minimum_basis =
                          match state.feed_refresh with
                          | Some { minimum_basis = Some basis; _ } ->
                            Some (Int64.max basis invalidation.basis)
                          | None | Some _ -> Some invalidation.basis
                        in
                        { state with
                          feed_refresh =
                            Some
                              { generation
                              ; context
                              ; cause = Sync_refresh
                              ; graph_generation = current_graph_generation state
                              ; minimum_basis
                              }
                        ; next_request_generation = Int64.succ generation
                        }
                      | None | Some _ -> state)
                  else Bonsai.Effect.Ignore
                in
                Bonsai.Effect.bind prepare ~f:(fun () ->
                  Bonsai.Effect.bind
                    (Bonsai.Effect.of_thunk (fun () -> deliver_output output))
                    ~f:(fun delivery ->
                      List.iter clear_delete_command delivery.responses;
                      set_state (fun state ->
                        let state =
                          List.fold_left apply_worker_response state delivery.responses
                        in
                        match delivery.error with
                        | Some message -> fail_feed_transport state message
                        | None -> state)))))
          | Worker.Response
              { outcome = Worker.Completed (Graph_service.Graph_response response); _ } ->
            let output = Journal_graph_runtime.receive graph_runtime response in
            Bonsai.Effect.bind
              (Bonsai.Effect.of_thunk (fun () -> deliver_output output))
              ~f:(fun delivery ->
                List.iter clear_delete_command delivery.responses;
                let update =
                  set_state (fun state ->
                    let state =
                      List.fold_left apply_worker_response state delivery.responses
                    in
                    match delivery.error with
                    | None -> state
                    | Some message when Option.is_some state.feed_refresh ->
                      fail_feed_transport state message
                    | Some message -> fail_graph_transport state message)
                in
                update)
          | Worker.Response { outcome = Completed (Client_state manager_state); _ } ->
            apply_manager_transition set_state manager_state
          | Worker.Response { outcome = Completed (Graph_state graph_state); _ }
          | Worker.Push { payload = Graph_state_changed graph_state; _ } ->
            observe_graph_state set_state graph_state
          | Worker.Push { payload = Client_state_changed manager_state; _ } ->
            apply_manager_transition set_state manager_state
          | Worker.Push { payload = Need_id_token challenge; _ } ->
            Bonsai.Effect.bind
              (Platform.request
                 application_platform
                 (Journal_platform.id_token_request challenge))
              ~f:(function
                | Error _ -> send_manager (Graph_service.Reject_token challenge)
                | Ok payload ->
                  let challenge_id = Logseq_sync_pure_reducer.Core.token_request_id challenge in
                  (match
                     Journal_platform.decode_id_token_response ~challenge_id payload
                   with
                   | Error _ -> send_manager (Graph_service.Reject_token challenge)
                   | Ok token ->
                     send_manager
                       (Graph_service.Provide_token { request = challenge; token })))
          | Worker.Push { payload = Bootstrap_progress progress; _ } ->
            set_state (fun state ->
              match state.manager with
              | Some manager when manager.selected_graph = Some progress.graph_id ->
                { state with bootstrap_progress = Some progress }
              | None | Some _ -> state)
          | Worker.Response { outcome = Failed error; _ } ->
            pending_delete_ref := None;
            set_state (fun state ->
              match state.feed_refresh with
              | Some _ -> { state with feed_refresh = None; sync_error = Some error }
              | None -> fail_active_mutation state error)
          | Worker.Response { outcome = Cancelled | Shutdown; _ } ->
            pending_delete_ref := None;
            set_state (fun state ->
              match state.feed_refresh with
              | Some _ ->
                { state with feed_refresh = None; sync_error = Some "Worker unavailable" }
              | None -> fail_active_mutation state "Worker unavailable")
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
            let calendar_update =
              set_state (fun state ->
                match state.calendar with
                | Some current
                  when Int64.compare current.generation event.snapshot.generation >= 0 ->
                  state
                | None ->
                  { state with
                    calendar = Some event.snapshot
                  ; formatted_context = None
                  ; day_labels = []
                  }
                | Some current ->
                  let formatting_changed =
                    current.local_day <> event.snapshot.local_day
                    || not (String.equal current.locale event.snapshot.locale)
                  in
                  { state with
                    calendar = Some event.snapshot
                  ; formatted_context =
                      (if formatting_changed then None else state.formatted_context)
                  ; day_labels = (if formatting_changed then [] else state.day_labels)
                  })
            in
            (match event.reason with
             | Journal_platform.Resumed
             | Requested
             | Significant_time_changed
             | Time_zone_changed
             | Locale_changed -> calendar_update)
        in
        let apply_network_lifecycle payload =
          match Journal_platform.decode_network_lifecycle payload with
          | Error _ -> Bonsai.Effect.Ignore
          | Ok (Backgrounded _) -> send_manager (Graph_service.Set_foreground false)
          | Ok (Foreground_resumed _) -> send_manager (Graph_service.Set_foreground true)
        in
        let apply_authenticated_user payload =
          match Journal_platform.decode_authenticated_user payload with
          | Error _ -> Bonsai.Effect.Ignore
          | Ok user_id ->
            (match user_id with
             | None -> sign_out_in_flight := true
             | Some _ -> ());
            send_manager (Graph_service.Reconcile_authenticated_user { user_id })
        in
        let apply_local_account_binding result =
          match result with
          | Error _ -> Bonsai.Effect.Ignore
          | Ok payload ->
            (match Journal_platform.decode_local_account_binding payload with
             | Error _ | Ok None -> Bonsai.Effect.Ignore
             | Ok (Some binding) ->
               if String.equal binding.managed_sync_origin !managed_sync_origin
               then
                 send_manager
                   (Graph_service.Restore_local_account { user_id = binding.user_id })
               else Bonsai.Effect.Ignore)
        in
        let apply_typography_preference result =
          let stored_value =
            match result with
            | Ok payload ->
              (match Journal_platform.decode_typography_preset_preference payload with
               | Ok value -> value
               | Error _ -> None)
            | Error _ -> None
          in
          let preset =
            Journal_visual_tokens.typography_preset_of_stored_value stored_value
          in
          set_state (fun state -> { state with typography_preset = Some preset })
        in
        let apply_platform payload =
          if Journal_platform.is_prepare_to_terminate_event payload
          then (
            termination_in_flight := true;
            send_manager Graph_service.Return_to_graph_picker)
          else (
            match Journal_platform.decode_network_lifecycle payload with
            | Ok _ -> apply_network_lifecycle payload
            | Error _ ->
              (match Journal_platform.decode_calendar payload with
               | Ok _ -> apply_calendar payload
               | Error _ -> apply_authenticated_user payload))
        in
        Platform.on_event application_platform apply_platform;
        let managed_startup =
          if not !managed_sync_startup
          then Bonsai.Effect.Ignore
          else
            Bonsai.Effect.bind
              (Platform.request
                 application_platform
                 Journal_platform.local_account_binding_request)
              ~f:(fun binding ->
                Bonsai.Effect.bind (apply_local_account_binding binding) ~f:(fun () ->
                  Platform.request
                    application_platform
                    Journal_platform.authenticated_user_request
                  |> Bonsai.Effect.bind ~f:(function
                    | Error _ -> Bonsai.Effect.Ignore
                    | Ok payload -> apply_authenticated_user payload)))
        in
        Bonsai.Effect.Many
          [ Platform.request application_platform Journal_platform.get_calendar_request
            |> Bonsai.Effect.bind ~f:(function
              | Error _ -> Bonsai.Effect.Ignore
              | Ok payload -> apply_calendar payload)
          ; managed_startup
          ; Platform.request
              application_platform
              Journal_platform.typography_preset_preference_request
            |> Bonsai.Effect.bind ~f:apply_typography_preference
          ]
        |> Bonsai.Effect.Expert.handle);
      ())
  in
  let feed_key =
    Bonsai.Cont.map state ~f:(fun state ->
      match state.graph_ready, state.calendar with
      | true, Some calendar ->
        let context = feed_projection_context calendar in
        if
          state.feed_loaded
          && Option.equal
               equal_feed_projection_context
               state.presented_feed_context
               (Some context)
        then None
        else if
          match Journal_timeline_state.pending_request state.timeline with
          | Some (_, Feed { before_day = None }) -> true
          | Some (_, Feed { before_day = Some _ })
          | Some (_, Day _)
          | Some (_, Children _)
          | None -> false
        then None
        else Some context
      | false, _ | true, None -> None)
  in
  let feed_callback =
    Bonsai.Cont.map2 state set_state ~f:(fun snapshot set_state -> function
      | None -> Bonsai.Effect.Ignore
      | Some context ->
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
        let prepare =
          set_state (fun state ->
            if state.feed_loaded
            then (
              let cause, minimum_basis =
                match state.feed_refresh with
                | Some { cause = Sync_refresh; minimum_basis; _ } ->
                  Sync_refresh, minimum_basis
                | None | Some _ -> Calendar_refresh, None
              in
              { state with
                feed_refresh =
                  Some
                    { generation
                    ; context
                    ; cause
                    ; graph_generation = current_graph_generation state
                    ; minimum_basis
                    }
              ; next_request_generation = Int64.succ generation
              })
            else
              { state with
                timeline =
                  (Journal_timeline_state.empty ~today:context.local_day
                   |> fun timeline ->
                   Journal_timeline_state.begin_request timeline ~generation request)
              ; feed_loaded = false
              ; presented_feed_context = None
              ; feed_refresh = None
              ; next_request_generation = Int64.succ generation
              })
        in
        Bonsai.Effect.bind prepare ~f:(fun () ->
          Bonsai.Effect.bind
            (Bonsai.Effect.of_thunk (fun () -> deliver_output output))
            ~f:(fun delivery ->
              List.iter clear_delete_command delivery.responses;
              set_state (fun state ->
                let state =
                  List.fold_left apply_worker_response state delivery.responses
                in
                match delivery.error with
                | Some message -> fail_feed_transport state message
                | None -> state))))
  in
  Bonsai.Cont.Edge.on_change
    ~equal:(Option.equal equal_feed_projection_context)
    feed_key
    ~callback:feed_callback
    graph;
  let timeline_presentation_key =
    Bonsai.Cont.map state ~f:(fun state ->
      match state.feed_loaded, state.manager with
      | true, Some snapshot when snapshot.timeline_presentation_pending ->
        Some (snapshot.selected_graph, snapshot.applied_server_t)
      | false, _ | true, None | true, Some _ -> None)
  in
  let timeline_presentation_callback =
    Bonsai.Cont.map timeline_presentation_key ~f:(fun current -> function
      | None -> Bonsai.Effect.Ignore
      | Some _ as key ->
        if current <> key
        then Bonsai.Effect.Ignore
        else
          Bonsai.Effect.bind
            (send_manager Graph_service.Acknowledge_local_feed)
            ~f:(fun () ->
              Platform.request
                application_platform
                Journal_platform.timeline_presented_request
              |> Bonsai.Effect.bind ~f:(function
                | Error _ -> Bonsai.Effect.Ignore
                | Ok payload ->
                  (match Journal_platform.decode_timeline_presented payload with
                   | Error _ -> Bonsai.Effect.Ignore
                   | Ok () -> send_manager Graph_service.Acknowledge_timeline_presented))))
  in
  Bonsai.Cont.Edge.on_change
    ~equal:(Option.equal (fun left right -> left = right))
    timeline_presentation_key
    ~callback:timeline_presentation_callback
    graph;
  let timeline_drain_key =
    Bonsai.Cont.map state ~f:(fun state ->
      if not (state.graph_ready && state.feed_loaded)
      then None
      else
        Option.map
          (fun request -> state.next_request_generation, request)
          (Journal_timeline_state.next_request state.timeline))
  in
  let timeline_drain_callback =
    Bonsai.Cont.map set_state ~f:(fun set_state -> function
      | None -> Bonsai.Effect.Ignore
      | Some (generation, request) ->
        let output = submit (worker_request generation request) in
        let sent_request = output.requests <> [] in
        Bonsai.Effect.bind
          (Bonsai.Effect.of_thunk (fun () -> deliver_output output))
          ~f:(fun delivery ->
            List.iter clear_delete_command delivery.responses;
            set_state (fun state ->
              let state = apply_delivery_responses state delivery in
              match
                ( delivery.error
                , sent_request
                , Int64.equal state.next_request_generation generation
                , Journal_timeline_state.next_request state.timeline )
              with
              | None, true, true, Some current when current = request ->
                { state with
                  timeline =
                    Journal_timeline_state.begin_request
                      state.timeline
                      ~generation
                      request
                ; next_request_generation = Int64.succ generation
                }
              | None, false, _, _
              | None, true, false, _
              | None, true, true, None
              | None, true, true, Some _
              | Some _, _, _, _ -> state)))
  in
  Bonsai.Cont.Edge.on_change
    ~equal:
      (Option.equal
         (fun (left_generation, left_request) (right_generation, right_request) ->
            Int64.equal left_generation right_generation && left_request = right_request))
    timeline_drain_key
    ~callback:timeline_drain_callback
    graph;
  let format_key =
    Bonsai.Cont.map state ~f:(fun state ->
      match state.calendar, formatting_context state with
      | Some calendar, Some context
        when state.feed_loaded
             && not
                  (Option.equal
                     equal_formatting_context
                     state.formatted_context
                     (Some context)) -> Some (calendar.generation, context)
      | None, _ | Some _, None | Some _, Some _ -> None)
  in
  let format_callback =
    Bonsai.Cont.map set_state ~f:(fun set_state request_key ->
      match request_key with
      | None -> Bonsai.Effect.Ignore
      | Some (generation, context) ->
        (match Journal_platform.format_journal_days_request ~generation context.days with
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
                            = context.days ->
                    set_state (fun state ->
                      match state.calendar, formatting_context state with
                      | Some calendar, Some current
                        when Int64.equal calendar.generation generation
                             && equal_formatting_context current context ->
                        { state with
                          formatted_context = Some context
                        ; day_labels = formatted.headings
                        }
                      | None, _ | Some _, None | Some _, Some _ -> state)
                  | Ok _ -> Bonsai.Effect.Ignore))))
  in
  Bonsai.Cont.Edge.on_change
    ~equal:
      (Option.equal (fun (left_generation, left) (right_generation, right) ->
         Int64.equal left_generation right_generation
         && equal_formatting_context left right))
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
        let with_direct_request next request =
          Bonsai.Effect.bind (update (fun _ -> next)) ~f:(fun () -> send request)
        in
        let admit_direct_capture source =
          match
            ( snapshot.write_enabled
            , snapshot.pending_delete
            , snapshot.direct_capture
            , snapshot.calendar )
          with
          | false, _, _, _ | true, Some _, _, _ | true, None, _, None ->
            Bonsai.Effect.Ignore
          | true, None, Some capture, Some _
            when Journal_capture.phase capture = Journal_capture.Saving ->
            Bonsai.Effect.Ignore
          | true, None, Some capture, Some _
            when match Journal_capture.phase capture with
                 | Journal_capture.Failed _ ->
                   String.equal (Journal_capture.source capture) source
                 | Editing | Saving -> false ->
            let capture, request = Journal_capture.retry capture in
            (match request with
             | None -> Bonsai.Effect.Ignore
             | Some request ->
               with_direct_request
                 { snapshot with direct_capture = Some capture; capture_error = None }
                 request)
          | true, None, None, Some calendar | true, None, Some _, Some calendar ->
            if String.equal (String.trim source) ""
            then Bonsai.Effect.Ignore
            else (
              match creation_time calendar with
              | Error _ -> Bonsai.Effect.Ignore
              | Ok creation_time ->
                let number = snapshot.next_local_sequence in
                let capture = Journal_capture.create ~session_number:number ~source in
                let capture, request =
                  Journal_capture.admit_save
                    capture
                    ~mutation_id:(fresh_identity ())
                    ~block_id:(fresh_identity ())
                    ~sibling_order:(sibling_order number)
                    ~calendar_generation:calendar.generation
                    ~creation_time
                in
                (match request with
                 | None -> Bonsai.Effect.Ignore
                 | Some request ->
                   with_direct_request
                     { snapshot with
                       direct_capture = Some capture
                     ; capture_error = None
                     ; next_local_sequence = Int64.succ number
                     }
                     request))
        in
        match payload with
        | Ui.Event.Payload.Text_edit edit ->
          update (fun state ->
            match Journal_routes.detail state.routes with
            | Some detail when Option.is_some (Journal_detail.child_capture detail) ->
              { state with
                routes =
                  Journal_routes.update_detail
                    state.routes
                    (Journal_detail.apply_child_text_edit detail edit)
              }
            | Some detail ->
              { state with
                routes =
                  Journal_routes.update_detail
                    state.routes
                    (Journal_detail.apply_text_edit detail edit)
              }
            | None ->
              (match state.manager with
               | Some { startup = { awaiting_e2ee_password = true; _ }; _ } ->
                 { state with
                   e2ee_password =
                     Journal_capture.apply_text_edit state.e2ee_password edit
                 }
               | None | Some _ -> state))
        | Ui.Event.Payload.Visible_range range ->
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
            Journal_timeline_state.observe_visible_range
              timeline
              ~first_index
              ~last_exclusive
          in
          update (fun state -> { state with timeline = observe state.timeline })
        | Ui.Event.Payload.Scroll { pixels; delta } ->
          update (fun state ->
            let capture_fab_scroll =
              Journal_timeline_state.update_capture_fab_scroll
                state.capture_fab_scroll
                ~pixels
                ~delta
            in
            if capture_fab_scroll = state.capture_fab_scroll
            then state
            else { state with capture_fab_scroll })
        | Ui.Event.Payload.Native_event _ as payload ->
          (match
             Ui.Native_widget.Expandable_message_composer.event_of_payload payload
           with
           | Some (Text_changed text) ->
             update (fun state ->
               match state.direct_capture with
               | Some capture
                 when match Journal_capture.phase capture with
                      | Journal_capture.Failed _ ->
                        not (String.equal (Journal_capture.source capture) text)
                      | Editing | Saving -> false ->
                 { state with direct_capture = None; capture_error = None }
               | None | Some _ -> state)
           | Some (Button_pressed { button_id = 1; text }) -> admit_direct_capture text
           | Some (Button_pressed _) -> Bonsai.Effect.Ignore
           | None -> Bonsai.Effect.Ignore)
        | Ui.Event.Payload.Route_pop _ -> update back_state
        | Ui.Event.Payload.Text action ->
          if String.length action > 13 && String.sub action 0 13 = "select-graph:"
          then (
            let graph_id = String.sub action 13 (String.length action - 13) in
            match Logseq_db_types.Graph_types.Uuid.of_string graph_id with
            | Error _ -> Bonsai.Effect.Ignore
            | Ok graph_id -> send_manager (Graph_service.Select_graph graph_id))
          else if String.equal action "refresh-catalog"
          then send_manager Graph_service.Refresh_catalog
          else if String.equal action "begin-online-recovery"
          then send_manager Graph_service.Begin_online_recovery
          else if String.equal action "open-account-menu"
          then update (fun state -> { state with modal = Account })
          else if String.equal action "close-account-menu"
          then update (fun state -> { state with modal = No_modal })
          else if String.equal action "open-settings"
          then update (fun state -> { state with modal = Settings })
          else if String.equal action "close-settings"
          then update (fun state -> { state with modal = No_modal })
          else if String.equal action "open-sync-diagnostics"
          then update (fun state -> { state with modal = Sync_diagnostics })
          else if String.equal action "close-sync-diagnostics"
          then update (fun state -> { state with modal = No_modal })
          else if
            String.length action > 18 && String.sub action 0 18 = "select-typography:"
          then (
            let stored_value = String.sub action 18 (String.length action - 18) in
            let preset =
              Journal_visual_tokens.typography_preset_of_stored_value (Some stored_value)
            in
            if
              (not
                 (String.equal
                    stored_value
                    (Journal_visual_tokens.stored_value_of_typography_preset preset)))
              || snapshot.typography_preset = Some preset
            then Bonsai.Effect.Ignore
            else
              Bonsai.Effect.Many
                [ update (fun state -> { state with typography_preset = Some preset })
                ; Platform.request
                    application_platform
                    (Journal_platform.set_typography_preset_preference_request
                       stored_value)
                  |> Bonsai.Effect.bind ~f:(fun result ->
                    match result with
                    | Ok payload
                      when Result.is_ok
                             (Journal_platform.decode_set_typography_preset_preference
                                payload) -> Bonsai.Effect.Ignore
                    | Error _ | Ok _ -> Bonsai.Effect.Ignore)
                ])
          else if String.equal action "switch-graph"
          then
            Bonsai.Effect.Many
              [ update (fun state -> { state with modal = No_modal })
              ; send_manager Graph_service.Return_to_graph_picker
              ]
          else if String.equal action "sign-out"
          then (
            sign_out_in_flight := true;
            Bonsai.Effect.Many
              [ update (fun state -> { state with modal = No_modal })
              ; send_manager
                  (Graph_service.Reconcile_authenticated_user { user_id = None })
              ])
          else if String.equal action "submit-e2ee-password"
          then (
            let password = Journal_capture.source snapshot.e2ee_password in
            if String.equal (String.trim password) ""
            then Bonsai.Effect.Ignore
            else
              Bonsai.Effect.Many
                [ send_manager (Graph_service.Submit_e2ee_password password)
                ; update (fun state ->
                    { state with
                      e2ee_password =
                        Journal_capture.create
                          ~session_number:state.next_local_sequence
                          ~source:""
                    ; next_local_sequence = Int64.succ state.next_local_sequence
                    })
                ])
          else if String.equal action "request-local-cache-reset"
          then
            update (fun state ->
              match state.manager with
              | Some { selected_graph = Some graph_id; _ } ->
                { state with modal = Cache_reset_confirmation graph_id }
              | None | Some _ -> state)
          else if String.equal action "cancel-local-cache-reset"
          then update (fun state -> { state with modal = No_modal })
          else if String.equal action "confirm-local-cache-reset"
          then (
            match snapshot.modal with
            | No_modal | Account | Settings | Sync_diagnostics -> Bonsai.Effect.Ignore
            | Cache_reset_confirmation graph_id ->
              Bonsai.Effect.Many
                [ send_manager (Graph_service.Delete_local_cache graph_id)
                ; update (fun state -> { state with modal = No_modal })
                ])
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
          else if String.equal action "back"
          then update back_state
          else if String.equal action "keep-editing"
          then
            update (fun state ->
              { state with routes = Journal_routes.keep_editing state.routes })
          else if String.equal action "discard"
          then
            update (fun state ->
              { state with routes = Journal_routes.discard state.routes })
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
              , snapshot.pending_delete
              , block_in_timeline snapshot.timeline block_id )
            with
            | true, None, Some block ->
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
            | false, _, _ | true, Some _, _ | true, None, None -> Bonsai.Effect.Ignore)
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
              update (fun state ->
                let timeline = state.timeline in
                let timeline =
                  if Journal_timeline_state.is_expanded timeline ~block_id
                  then Journal_timeline_state.collapse timeline ~parent_id:block_id
                  else Journal_timeline_state.expand timeline ~parent_id:block_id
                in
                { state with timeline })
            | None, Some _ -> Bonsai.Effect.Ignore)
          else Bonsai.Effect.Ignore
        | Unit
        | Bool _
        | Int64 _
        | Int64_list _
        | Float _
        | Float_range _
        | Tap _
        | Pointer _
        | Key _ -> Bonsai.Effect.Ignore)
  in
  let snack_bar_cancellation : Bonsai_flutter.Host_effect.Cancellation.t option ref =
    ref None
  in
  let snack_bar_key =
    Bonsai.Cont.map2 state environment ~f:(fun state environment ->
      ( ( (if
             state.graph_ready
             && Journal_routes.route state.routes = Journal_routes.Timeline
           then state.timeline_notice
           else None)
        , state.capture_error )
      , environment.accessible_navigation ))
  in
  let snack_bar_callback =
    Bonsai.Cont.map
      dispatch
      ~f:(fun dispatch ((notice, capture_error), accessible_navigation) ->
        Option.iter Bonsai_flutter.Host_effect.Cancellation.cancel !snack_bar_cancellation;
        snack_bar_cancellation := None;
        match capture_error, notice with
        | None, None -> Bonsai.Effect.Ignore
        | _, _ ->
          let cancellation = Bonsai_flutter.Host_effect.Cancellation.create () in
          snack_bar_cancellation := Some cancellation;
          let message, action_label, duration_ms =
            match capture_error, notice with
            | Some message, _ -> message, None, 4_000
            | None, Some Delete_undo ->
              ( "Block and descendants removed"
              , Some "Undo"
              , if accessible_navigation then 10_000 else 5_000 )
            | None, Some Delete_failed -> "Delete failed. Block restored.", None, 4_000
            | None, None -> assert false
          in
          Bonsai.Effect.bind
            (Bonsai_flutter.Host_effect.show_snack_bar
               ~cancellation
               ?action_label
               ~duration_ms
               host_effects
               ~message
               ())
            ~f:(function
            | Ok Bonsai_flutter.Host_effect.Action ->
              Bonsai.Effect.of_thunk (fun () ->
                Ui.Event.Handler.Private.invoke
                  dispatch
                  (Ui.Event.Payload.Text "delete-undo"))
            | Ok (Dismiss | Swipe | Hide | Remove | Timeout) | Error _ ->
              Bonsai.Effect.Ignore))
  in
  Bonsai.Cont.Edge.on_change
    ~equal:(fun (left_notice, left_accessible) (right_notice, right_accessible) ->
      left_notice = right_notice && Bool.equal left_accessible right_accessible)
    snack_bar_key
    ~callback:snack_bar_callback
    graph;
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
    let preset =
      Option.value state.typography_preset ~default:Journal_visual_tokens.Balanced
    in
    let typography = Journal_visual_tokens.typography preset in
    let tokens = Journal_visual_tokens.resolve ~high_contrast:environment.high_contrast in
    let profile =
      Journal_visual_tokens.select_row_profile
        ~preset
        ~viewport_width:environment.viewport_width
        ~text_scale:environment.text_scale
    in
    let capture_saving =
      match state.direct_capture with
      | Some capture -> Journal_capture.phase capture = Journal_capture.Saving
      | None -> false
    in
    let root =
      match state.graph_ready, state.manager with
      | false, Some _ -> manager_page ~typography state dispatch
      | false, None | true, _ ->
        let content_horizontal_inset =
          Float.max
            0.
            ((environment.viewport_width -. Journal_visual_tokens.timeline_max_width)
             /. 2.)
        in
        timeline_page
          ~tokens
          ~typography
          ~profile
          ~text_scale:environment.text_scale
          ~top_inset:environment.safe_area.top
          ~bottom_inset:environment.safe_area.bottom
          ~device_pixel_ratio:environment.device_pixel_ratio
          ~timeline_state:state.timeline
          ~loading:(not state.feed_loaded)
          ~graph_error:state.graph_error
          ~sync_error:state.sync_error
          ~cache_reset_available:
            (match state.manager with
             | Some { selected_graph = Some _; _ } -> true
             | None | Some _ -> false)
          ~today_subtitle:(today_label state)
          ~day_label:(label_for_day state)
          ~reduced_motion
          ~rtl:(is_rtl_locale environment.locale)
          ~content_horizontal_inset
          ~capture_enabled:
            (state.write_enabled
             && Option.is_none state.pending_delete
             && not capture_saving)
          ~capture_save_enabled:
            (state.write_enabled
             && Option.is_none state.pending_delete
             && not capture_saving)
          ~capture_saving
          ~capture_affordance_key:state.capture_affordance_key
          ~capture_fab_presentation:
            (Journal_timeline_state.capture_fab_presentation state.capture_fab_scroll)
          ~on_capture_event:dispatch
          ~on_scroll:dispatch
          ~on_visible_range:dispatch
          ~on_toggle_children:(prefix_action dispatch "timeline-toggle-children:")
          ~delete_enabled:(state.write_enabled && Option.is_none state.pending_delete)
          ~on_delete:(prefix_action dispatch "timeline-delete:")
          ~on_cache_reset_requested:(bind_action dispatch "request-local-cache-reset")
          ~account_menu_available:true
          ~on_account_menu:(bind_action dispatch "open-account-menu")
    in
    let pages =
      match Journal_routes.route state.routes with
      | Journal_routes.Timeline -> [ root ]
      | Detail_loading ->
        [ root
        ; message_page
            ~typography
            ~page_key:"journal-detail-loading"
            ~title:"Loading entry"
            dispatch
        ]
      | Detail ->
        (match Journal_routes.detail state.routes with
         | Some detail ->
           [ root; detail_page ~typography detail dispatch ]
           @
           if Journal_detail.mode detail = Journal_detail.Confirm_discard
           then
             [ detail_discard_dialog_page ~tokens ~typography ~reduced_motion dispatch ]
           else []
         | None -> [ root ])
      | Missing_detail ->
        [ root
        ; message_page
            ~typography
            ~page_key:"journal-detail-missing"
            ~title:"Entry unavailable"
            dispatch
        ]
    in
    let pages =
      match state.modal with
      | Cache_reset_confirmation _ ->
        pages
        @ [ local_cache_reset_dialog_page ~tokens ~typography ~reduced_motion dispatch ]
      | Account ->
        let cache_reset_available =
          match state.manager with
          | Some { selected_graph = Some _; _ } -> true
          | None | Some _ -> false
        in
        pages
        @ [ account_dialog_page
              ~tokens
              ~typography
              ~reduced_motion
              ~cache_reset_available
              dispatch
          ]
      | Settings ->
        pages
        @ [ settings_dialog_page ~tokens ~typography ~preset ~reduced_motion dispatch ]
      | Sync_diagnostics ->
        pages
        @ [ sync_diagnostics_page
              ~tokens
              ~typography
              ~reduced_motion
              state.sync_diagnostics
              dispatch
          ]
      | No_modal -> pages
    in
    let body =
      match state.typography_preset with
      | None ->
        Ui.Widget.empty ()
        |> Ui.Widget.with_test_id (Ui.Test_id.string "typography-preference-loading")
      | Some _ ->
        Ui.Widget.navigator
          ~key:(Ui.Key.string "journal-navigator")
          ~restoration_scope_id:
            (ID.Navigation.Restoration_scope_id.of_string "logseq-journal")
          ~on_pop:dispatch
          pages
        |> Ui.Widget.with_test_id (Ui.Test_id.string "journal-navigator")
    in
    App.View.create ~theme:(application_theme preset) ~body)
;;

let decode_config payload =
  match Journal_startup.decode payload with
  | Ok startup ->
    (match startup.Logseq_db_worker.Config.target with
     | Managed_sync { base_url } ->
       managed_sync_startup := true;
       managed_sync_origin := base_url
     | Snapshot _ | Import_snapshot _ | Synced_mirror _ | Native_local_graph _ ->
       managed_sync_startup := false);
    Ok startup
  | Error error -> Error (Journal_startup.Error.to_string error)
;;

let app =
  App.create_with_worker
    ~name:"Logseq Journal"
    ~decode_config
    ~service:Graph_service.service
    component
;;
