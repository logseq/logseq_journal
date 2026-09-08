module ID = Bonsai_flutter_spec.Id
module Platform = Bonsai_flutter.Application_platform
module Ui = Bonsai_flutter_ui
module Graph_service = Logseq_db_worker_bonsai.Logseq_db_worker_bonsai_service

module Admission_refresh = struct
  type observation =
    | Unavailable
    | Loading
    | Available of Logseq_db_worker.Protocol.v2_admission_inspection

  type result =
    | Inspected of Logseq_db_worker.Protocol.v2_admission_inspection
    | Inspection_unavailable

  type directive =
    | No_request
    | Request of Journal_graph_request.admission_request

  type t =
    { open_ : bool
    ; graph_generation : int option
    ; in_flight : Journal_graph_request.admission_request option
    ; pending : bool
    ; observation : observation
    ; next_request_generation : int64
    }

  let closed =
    { open_ = false
    ; graph_generation = None
    ; in_flight = None
    ; pending = false
    ; observation = Unavailable
    ; next_request_generation = 1L
    }
  ;;

  let request state graph_generation observation =
    let request : Journal_graph_request.admission_request =
      { graph_generation; request_generation = state.next_request_generation }
    in
    ( { open_ = true
      ; graph_generation = Some graph_generation
      ; in_flight = Some request
      ; pending = false
      ; observation
      ; next_request_generation = Int64.succ state.next_request_generation
      }
    , Request request )
  ;;

  let unavailable state ~open_ graph_generation =
    { state with
      open_
    ; graph_generation = Some graph_generation
    ; in_flight = None
    ; pending = false
    ; observation = Unavailable
    }
  ;;

  let open_ state ~graph_generation ~graph_open =
    if graph_open
    then request state graph_generation Loading
    else unavailable state ~open_:true graph_generation, No_request
  ;;

  let trigger state ~graph_generation ~graph_open =
    if not state.open_
    then state, No_request
    else if not graph_open
    then unavailable state ~open_:true graph_generation, No_request
    else if state.graph_generation <> Some graph_generation
    then request state graph_generation Loading
    else if Option.is_some state.in_flight
    then { state with pending = true }, No_request
    else (
      let observation =
        match state.observation with
        | Available _ as available -> available
        | Unavailable | Loading -> Loading
      in
      request state graph_generation observation)
  ;;

  let complete state ~request:completed ~result =
    if (not state.open_) || state.in_flight <> Some completed
    then state, No_request
    else (
      let observation =
        match result with
        | Inspected inspection -> Available inspection
        | Inspection_unavailable -> Unavailable
      in
      if state.pending
      then request state completed.graph_generation observation
      else { state with in_flight = None; observation }, No_request)
  ;;

  let close state =
    { closed with next_request_generation = state.next_request_generation }
  ;;

  let observation state = state.observation
end

type delete_phase =
  | Undoable
  | Committing

type pending_delete =
  { mutation_id : string
  ; block_id : string
  ; expected_revision : string
  ; staged : Journal_timeline_state.staged_delete
  ; deadline : Core.Time_ns.t
  ; phase : delete_phase
  }

type pending_status =
  { mutation_id : string
  ; block_id : string
  ; expected_revision : string
  ; task_state : Journal_model.task_state
  }

type timeline_notice =
  | Delete_undo
  | Delete_failed
  | Status_failed of string

type feed_projection_context =
  { local_day : int
  ; projection_fingerprint : Journal_calendar.projection_fingerprint
  }

type feed_refresh_cause =
  | Calendar_refresh
  | Sync_refresh

type feed_refresh =
  { generation : int64
  ; context : feed_projection_context
  ; cause : feed_refresh_cause
  ; graph_generation : Graph_service.graph_id option
  }

type modal =
  | No_modal
  | Status_sheet of string
  | Account
  | Settings
  | Diagnostics
  | Error_info
  | Cache_reset_confirmation of Logseq_db_types.Graph_types.Uuid.t

type worker_error_occurrence =
  { sequence : int64
  ; error : Logseq_db_worker.Error.t
  ; request_id : Logseq_db_types.Graph_types.Uuid.t option
  ; phase : string option
  ; graph_generation : int
  ; graph_id : Logseq_db_types.Graph_types.Uuid.t option
  ; operation : string
  ; occurred_at_label : string option
  ; active : bool
  }

type graph_error =
  | Worker_graph_error of worker_error_occurrence
  | Transport_graph_error of string
  | Calendar_startup_failure of Journal_calendar.error

type capture_failure =
  | Worker_capture_failure of worker_error_occurrence
  | Local_capture_failure of string

type sync_failure =
  | Worker_sync_failure of worker_error_occurrence
  | Non_worker_sync_failure of string

type sync_error_notice =
  { sequence : int64
  ; failure : sync_failure
  }

type state =
  { favorites : Journal_routes.Favorites.t
  ; favorites_requests : Journal_graph_request.favorites_request list
  ; routes : Journal_routes.t
  ; timeline : Journal_timeline_state.t
  ; next_request_generation : int64
  ; next_local_sequence : int64
  ; calendar : Journal_calendar.t option
  ; pending_delete : pending_delete option
  ; pending_status : pending_status option
  ; direct_capture : Journal_capture.t option
  ; capture_affordance_key : int64
  ; journals_scroll : Journal_timeline_state.Root_scroll_trigger.t
  ; favorites_scroll : Journal_timeline_state.Root_scroll_trigger.t
  ; root_active : bool
  ; capture_error : capture_failure option
  ; timeline_notice : timeline_notice option
  ; write_enabled : bool
  ; graph_ready : bool
  ; feed_loaded : bool
  ; presented_feed_context : feed_projection_context option
  ; feed_refresh : feed_refresh option
  ; graph_error : graph_error option
  ; sync_error : sync_error_notice option
  ; manager : Graph_service.snapshot option
  ; graph_state : Logseq_db_worker.graph_state
  ; diagnostics : Graph_service.diagnostics option
  ; admission_refresh : Admission_refresh.t
  ; bootstrap_progress : Graph_service.bootstrap_progress option
  ; next_worker_error_sequence : int64
  ; worker_errors : worker_error_occurrence list
  ; next_sync_error_sequence : int64
  ; e2ee_password : Journal_capture.t
  ; typography_preset : Journal_visual_tokens.typography_preset option
  ; modal : modal
  }

let favorites_event state event =
  let favorites, requests = Journal_routes.Favorites.step state.favorites event in
  { state with favorites; favorites_requests = state.favorites_requests @ requests }
;;

let reset_destination_scroll state =
  match Journal_routes.destination state.routes with
  | Journals ->
    { state with journals_scroll = Journal_timeline_state.Root_scroll_trigger.initial }
  | Favorites ->
    { state with favorites_scroll = Journal_timeline_state.Root_scroll_trigger.initial }
;;

let select_destination state destination =
  if Journal_routes.destination state.routes = destination
  then state
  else
    { state with routes = Journal_routes.select_destination state.routes destination }
    |> fun state ->
    favorites_event state (Select (destination = Journal_routes.Favorites))
    |> reset_destination_scroll
;;

let initial_anchor : Journal_routes.anchor = { block_id = None; first_index = 0 }
let feed_day_limit = 7
let sync_error_card_lifetime = Core.Time_ns.Span.of_sec 5.

let initial_state =
  { favorites = Journal_routes.Favorites.create ~graph_generation:(-1)
  ; favorites_requests = []
  ; routes = Journal_routes.create ~anchor:initial_anchor
  ; timeline = Journal_timeline_state.empty ~today:0
  ; next_request_generation = 1L
  ; next_local_sequence = 1L
  ; calendar = None
  ; pending_delete = None
  ; pending_status = None
  ; direct_capture = None
  ; capture_affordance_key = 1L
  ; journals_scroll = Journal_timeline_state.Root_scroll_trigger.initial
  ; favorites_scroll = Journal_timeline_state.Root_scroll_trigger.initial
  ; root_active = true
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
  ; diagnostics = None
  ; admission_refresh = Admission_refresh.closed
  ; bootstrap_progress = None
  ; next_worker_error_sequence = 1L
  ; worker_errors = []
  ; next_sync_error_sequence = 1L
  ; e2ee_password = Journal_capture.create ~session_number:9_000_000L ~source:""
  ; typography_preset = None
  ; modal = No_modal
  }
;;

let feed_projection_context (calendar : Journal_calendar.t) =
  { local_day = Journal_calendar.local_day calendar
  ; projection_fingerprint = Journal_calendar.projection_fingerprint calendar
  }
;;

let equal_feed_projection_context left right =
  left.local_day = right.local_day
  && Journal_calendar.equal_projection_fingerprint
       left.projection_fingerprint
       right.projection_fingerprint
;;

let show_sync_error state failure =
  { state with
    sync_error = Some { sequence = state.next_sync_error_sequence; failure }
  ; next_sync_error_sequence = Int64.succ state.next_sync_error_sequence
  }
;;

let current_graph_generation state =
  Option.map
    (fun (manager : Graph_service.snapshot) -> manager.selected_graph)
    state.manager
  |> Option.join
;;

let local_deletion_active state =
  Option.fold
    ~none:false
    ~some:(fun snapshot -> Option.is_some snapshot.Graph_service.local_deletion)
    state.manager
;;

let discard_local_graph_state state =
  { state with
    journals_scroll = Journal_timeline_state.Root_scroll_trigger.initial
  ; favorites_scroll = Journal_timeline_state.Root_scroll_trigger.initial
  ; root_active = true
  ; favorites =
      Journal_routes.Favorites.create ~graph_generation:state.graph_state.generation
  ; favorites_requests = []
  ; routes = Journal_routes.graph_unavailable state.routes
  ; timeline = Journal_timeline_state.empty ~today:0
  ; feed_loaded = false
  ; capture_affordance_key = Int64.succ state.capture_affordance_key
  ; direct_capture = None
  ; pending_delete = None
  ; pending_status = None
  ; capture_error = None
  ; timeline_notice = None
  ; write_enabled = false
  ; graph_ready = false
  ; feed_refresh = None
  ; presented_feed_context = None
  ; admission_refresh = Admission_refresh.closed
  ; next_request_generation = Int64.succ state.next_request_generation
  ; next_local_sequence = Int64.succ state.next_local_sequence
  ; modal = No_modal
  }
;;

let local_deletion_available state =
  match state.manager with
  | Some snapshot ->
    snapshot.local_deletion = None
    && snapshot.selected_graph <> None
    && (Journal_startup.derive ~snapshot ~graph:state.graph_state).phase = Ready
    && snapshot.startup.failure = None
  | None -> false
;;

let apply_manager_state state (manager_state : Graph_service.state) =
  let snapshot = manager_state.snapshot in
  let state =
    if Option.is_some snapshot.local_deletion && not (local_deletion_active state)
    then discard_local_graph_state state
    else state
  in
  let previous_sync_error =
    Option.bind state.manager (fun manager -> manager.last_error)
  in
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
  let state = if graph_context_changed then discard_local_graph_state state else state in
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
    | Status_sheet _, _ when graph_context_changed -> No_modal
    | Cache_reset_confirmation confirmation, Some selected
      when Logseq_db_types.Graph_types.Uuid.equal confirmation selected -> state.modal
    | (No_modal | Status_sheet _ | Account | Settings | Diagnostics | Error_info), _ ->
      state.modal
    | Cache_reset_confirmation _, (None | Some _) -> No_modal
  in
  let state =
    { state with
      manager = Some snapshot
    ; diagnostics = Some manager_state.diagnostics
    ; e2ee_password
    ; next_local_sequence
    ; modal
    ; graph_ready = state.graph_ready && not graph_context_changed
    ; graph_error = state.graph_error
    }
  in
  match snapshot.last_error with
  | Some message when previous_sync_error <> Some message ->
    show_sync_error state (Non_worker_sync_failure message)
  | None | Some _ -> state
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
  Journal_timeline_state.find_block timeline ~block_id
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

let capture_failure_message = function
  | Worker_capture_failure occurrence -> Logseq_db_worker.Error.message occurrence.error
  | Local_capture_failure message -> message
;;

let fail_active_mutation state failure =
  let message = capture_failure_message failure in
  match state.pending_delete with
  | Some pending_delete ->
    { state with
      timeline = Journal_timeline_state.undo_delete state.timeline pending_delete.staged
    ; pending_delete = None
    ; timeline_notice = Some Delete_failed
    }
  | None ->
    (match state.pending_status with
     | Some _ ->
       { state with
         pending_status = None
       ; timeline_notice = Some (Status_failed message)
       }
     | None ->
       (match state.direct_capture, Journal_routes.detail state.routes with
        | Some capture, _ ->
          { state with
            direct_capture = Some (Journal_capture.fail capture ~message)
          ; capture_error = Some failure
          }
        | None, Some detail ->
          { state with
            routes =
              Journal_routes.update_detail
                state.routes
                (Journal_detail.fail detail ~message)
          }
        | None, None -> state))
;;

let terminal_graph_state state graph_error =
  { state with
    routes = Journal_routes.graph_unavailable state.routes
  ; write_enabled = false
  ; graph_ready = false
  ; feed_loaded = true
  ; feed_refresh = None
  ; pending_delete = None
  ; pending_status = None
  ; timeline_notice = None
  ; graph_error = Some graph_error
  }
;;

let newest_first_worker_errors state = state.worker_errors

let latest_worker_error state =
  match state.worker_errors with
  | occurrence :: _ -> occurrence
  | [] -> invalid_arg "worker error ledger is empty"
;;

let graph_error_message = function
  | Worker_graph_error occurrence -> Logseq_db_worker.Error.message occurrence.error
  | Transport_graph_error message -> message
  | Calendar_startup_failure error -> Journal_calendar.error_message error
;;

let sync_failure_message = function
  | Worker_sync_failure occurrence -> Logseq_db_worker.Error.message occurrence.error
  | Non_worker_sync_failure message -> message
;;

let record_worker_error state ~operation ?request_id ?phase error =
  let occurrence =
    { sequence = state.next_worker_error_sequence
    ; error
    ; request_id
    ; phase
    ; graph_generation = state.graph_state.generation
    ; graph_id = state.graph_state.graph_id
    ; operation
    ; occurred_at_label =
        Option.map
          (fun calendar ->
             Printf.sprintf
               "%04d-%02d-%02d %02d:%02d"
               (Journal_calendar.local_day calendar / 10_000)
               (Journal_calendar.local_day calendar / 100 mod 100)
               (Journal_calendar.local_day calendar mod 100)
               (Journal_calendar.local_minute_of_day calendar / 60)
               (Journal_calendar.local_minute_of_day calendar mod 60))
          state.calendar
    ; active = true
    }
  in
  { state with
    next_worker_error_sequence = Int64.succ state.next_worker_error_sequence
  ; worker_errors = occurrence :: state.worker_errors
  }
;;

let record_runtime_worker_failure
      state
      (worker_failure : Journal_graph_runtime.worker_failure)
  =
  record_worker_error
    state
    ~operation:worker_failure.operation
    ~request_id:worker_failure.request_id
    worker_failure.error
;;

let failure_source_message = function
  | Journal_graph_runtime.Worker_failure worker_failure ->
    Logseq_db_worker.Error.message worker_failure.error
  | Projection_failure message -> message
;;

let record_failure_source state = function
  | Journal_graph_runtime.Worker_failure worker_failure ->
    record_runtime_worker_failure state worker_failure
  | Projection_failure _ -> state
;;

let resolve_worker_errors state =
  { state with
    worker_errors =
      List.map (fun occurrence -> { occurrence with active = false }) state.worker_errors
  }
;;

let service_error ~operation message =
  let origin =
    Logseq_db_worker.Error.create_cause_or_fallback
      ~component:Logseq_db_worker.Error.Worker_service
      ~operation
      ~code:(Some "serviceFailure")
      ~message
      ~fallback_message:"Worker service reported a display-unsafe failure."
  in
  Logseq_db_worker.Error.create_with_origin
    ~code:Logseq_db_worker.Error.Closed_session
    ~message:"The Logseq DB worker service is unavailable."
    ~details:[]
    ~origin
  |> Result.get_ok
;;

let graph_lifecycle_owns_publication error =
  let trace = Logseq_db_worker.Error.trace error in
  not (String.equal trace.origin.operation "terminalStorageFailure")
;;

let fail_feed_transport state message =
  if state.feed_loaded
  then
    show_sync_error { state with feed_refresh = None } (Non_worker_sync_failure message)
  else terminal_graph_state state (Transport_graph_error message)
;;

let presentation_for_day _state day =
  Journal_calendar.present_journal_day day |> Result.to_option
;;

let today_presentation state =
  Option.bind state.calendar (fun calendar ->
    Journal_calendar.present_journal_day (Journal_calendar.local_day calendar)
    |> Result.to_option)
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

let apply_worker_response_unstaged state (response : Journal_graph_runtime.response) =
  match response.payload with
  | Favorites_loaded (request, result) -> favorites_event state (Loaded (request, result))
  | Favorites_failed (request, stale, message) ->
    favorites_event state (Failed (request, stale, message))
  | Favorites_invalidated -> favorites_event state Invalidate
  | Journal_graph_runtime.Graph_ready info ->
    ignore info.admission_facts;
    let state = resolve_worker_errors state in
    { state with write_enabled = true; graph_ready = true; graph_error = None }
  | Admission_inspected _ | Admission_unavailable _ -> state
  | Feed_loaded { request_generation; feed; complete } ->
    (match state.feed_refresh with
     | Some refresh when Int64.equal refresh.generation request_generation ->
       let current_context = Option.map feed_projection_context state.calendar in
       let current_graph_generation = current_graph_generation state in
       if
         Option.equal equal_feed_projection_context current_context (Some refresh.context)
         && current_graph_generation = refresh.graph_generation
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
  | Day_blocks_failed { day; request_generation; stale_cursor; failure } ->
    (match Journal_timeline_state.pending_request state.timeline with
     | Some (generation, Day request)
       when Int64.equal generation request_generation && request.day = day ->
       let state = if stale_cursor then state else record_failure_source state failure in
       { state with
         timeline =
           Journal_timeline_state.fail_day_request
             state.timeline
             ~generation:request_generation
             ~day
             ~stale_cursor
             ~message:(failure_source_message failure)
       }
     | _ -> state)
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
  | Feed_failed { request_generation; failure } ->
    let state = record_failure_source state failure in
    let message = failure_source_message failure in
    let terminal_failure state =
      match failure with
      | Journal_graph_runtime.Worker_failure _ ->
        terminal_graph_state state (Worker_graph_error (latest_worker_error state))
      | Projection_failure _ -> terminal_graph_state state (Transport_graph_error message)
    in
    let sync_failure =
      match failure with
      | Journal_graph_runtime.Worker_failure _ ->
        Worker_sync_failure (latest_worker_error state)
      | Projection_failure _ -> Non_worker_sync_failure message
    in
    (match state.feed_refresh with
     | Some refresh when Int64.equal refresh.generation request_generation ->
       if state.feed_loaded
       then show_sync_error state sync_failure
       else terminal_failure state
     | None | Some _ ->
       (match Journal_timeline_state.pending_request state.timeline with
        | Some (generation, Feed { before_day = None })
          when Int64.equal generation request_generation ->
          if state.feed_loaded
          then show_sync_error state sync_failure
          else terminal_failure state
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
    let pending_status, timeline_notice =
      match state.pending_status with
      | Some pending when String.equal pending.block_id (Journal_model.id block) ->
        ( None
        , if Journal_model.task_state block = pending.task_state
          then None
          else
            Some (Status_failed "The stored status did not match the requested status.") )
      | None | Some _ -> state.pending_status, state.timeline_notice
    in
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
    ; pending_status
    ; timeline_notice
    ; timeline =
        Option.fold
          ~none:(Journal_timeline_state.replace_block state.timeline block)
          ~some:(Journal_timeline_state.replace_timeline_entry state.timeline)
          timeline_entry_update
    }
  | Block_removed { block_id } ->
    { state with timeline = Journal_timeline_state.remove_block state.timeline ~block_id }
  | Page_tree_reconciled { page; value } ->
    { state with
      timeline =
        Journal_timeline_state.replace_timeline_entry_page state.timeline ~page value
    }
  | Children_reconciled detail ->
    let routes =
      match Journal_routes.detail state.routes with
      | None -> state.routes
      | Some current ->
        Journal_routes.update_detail
          state.routes
          (Journal_detail.reconcile_children current detail)
    in
    { state with
      routes
    ; timeline = Journal_timeline_state.reconcile_detail state.timeline detail
    }
  | Update_conflict latest ->
    (match state.pending_status with
     | Some pending when String.equal pending.block_id (Journal_model.id latest) ->
       { state with
         timeline = Journal_timeline_state.replace_block state.timeline latest
       ; pending_status = None
       ; timeline_notice = Some (Status_failed "Status changed elsewhere. Try again.")
       }
     | None | Some _ ->
       (match Journal_routes.detail state.routes with
        | None -> state
        | Some detail ->
          { state with
            routes =
              Journal_routes.update_detail
                state.routes
                (Journal_detail.apply_conflict detail latest)
          }))
  | Child_created { child; timeline_entry_update } ->
    (match Journal_routes.detail state.routes with
     | None -> state
     | Some detail ->
       let detail =
         Journal_detail.apply_child_created
           detail
           ~child
           ~parent:timeline_entry_update.block
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
           (let timeline =
              Journal_timeline_state.undo_delete state.timeline pending.staged
            in
            Journal_timeline_state.replace_block timeline latest)
       ; pending_delete = None
       ; timeline_notice = Some Delete_failed
       })
  | Open_failed worker_failure ->
    let state = record_runtime_worker_failure state worker_failure in
    terminal_graph_state state (Worker_graph_error (latest_worker_error state))
  | Rejected failure
    when Journal_routes.route state.routes = Journal_routes.Detail_loading ->
    let state = record_failure_source state failure in
    { state with
      routes =
        Journal_routes.apply_missing_detail
          state.routes
          ~request_generation:(Journal_routes.detail_request_generation state.routes)
    }
  | Rejected failure ->
    let state = record_failure_source state failure in
    let capture_failure =
      match failure with
      | Journal_graph_runtime.Worker_failure _ ->
        Worker_capture_failure (latest_worker_error state)
      | Projection_failure message -> Local_capture_failure message
    in
    fail_active_mutation state capture_failure
;;

let apply_worker_response state (response : Journal_graph_runtime.response) =
  match state.pending_delete, response.payload with
  | None, _ | Some _, Subtree_deleted _ -> apply_worker_response_unstaged state response
  | Some pending, _ ->
    let timeline = Journal_timeline_state.undo_delete state.timeline pending.staged in
    let state = apply_worker_response_unstaged { state with timeline } response in
    (match state.pending_delete with
     | None -> state
     | Some pending ->
       (match
          Journal_timeline_state.stage_delete state.timeline ~block_id:pending.block_id
        with
        | Some (timeline, staged) ->
          { state with timeline; pending_delete = Some { pending with staged } }
        | None -> { state with pending_delete = None; timeline_notice = None }))
;;

module Root_navigation = struct
  type t = state

  type event =
    | Scroll of
        { destination : Journal_routes.destination
        ; pixels : float
        ; delta : float
        }
    | Root_active of bool
    | Non_scrollable of Journal_routes.destination
    | Select of Journal_routes.destination
    | Capture_edited of string
    | Capture_admitted of Journal_capture.t
    | Completed of Journal_graph_runtime.response
    | Graph_replaced of int

  let replace_graph state generation =
    { state with
      journals_scroll = Journal_timeline_state.Root_scroll_trigger.initial
    ; favorites_scroll = Journal_timeline_state.Root_scroll_trigger.initial
    ; root_active = true
    ; favorites = Journal_routes.Favorites.create ~graph_generation:generation
    ; favorites_requests = []
    ; routes = Journal_routes.create ~anchor:initial_anchor
    ; direct_capture = None
    ; pending_delete = None
    ; pending_status = None
    ; timeline = Journal_timeline_state.empty ~today:0
    ; graph_state = { state.graph_state with generation }
    ; graph_ready = false
    ; feed_loaded = false
    ; capture_error = None
    ; capture_affordance_key = Int64.succ state.capture_affordance_key
    }
  ;;

  let create ~graph_generation = replace_graph initial_state graph_generation

  let step state = function
    | Root_active active ->
      if active = state.root_active
      then state
      else (
        let state = { state with root_active = active } in
        if active then reset_destination_scroll state else state)
    | Non_scrollable destination ->
      if state.root_active && Journal_routes.destination state.routes = destination
      then reset_destination_scroll state
      else state
    | Scroll { destination; pixels; delta } ->
      if (not state.root_active) || Journal_routes.destination state.routes <> destination
      then state
      else (
        let step trigger =
          Journal_timeline_state.Root_scroll_trigger.step trigger ~pixels ~delta
        in
        match destination with
        | Journals -> { state with journals_scroll = step state.journals_scroll }
        | Favorites -> { state with favorites_scroll = step state.favorites_scroll })
    | Select destination -> select_destination state destination
    | Capture_edited source ->
      let capture, next_local_sequence =
        match state.direct_capture with
        | None ->
          ( Journal_capture.create ~session_number:state.next_local_sequence ~source
          , Int64.succ state.next_local_sequence )
        | Some capture ->
          Journal_capture.update_source capture ~source, state.next_local_sequence
      in
      { state with
        direct_capture = Some capture
      ; next_local_sequence
      ; capture_error = None
      }
    | Capture_admitted capture ->
      { state with direct_capture = Some capture; capture_error = None }
    | Completed response -> apply_worker_response state response
    | Graph_replaced generation -> replace_graph state generation
  ;;

  let scroll_trigger state = function
    | Journal_routes.Journals -> state.journals_scroll
    | Favorites -> state.favorites_scroll
  ;;

  let navigation_visible state =
    Journal_timeline_state.Root_scroll_trigger.presentation
      (scroll_trigger state (Journal_routes.destination state.routes))
    = Extended
  ;;

  let destination state = Journal_routes.destination state.routes
  let capture state = state.direct_capture
  let favorites state = state.favorites
end

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

let transparent_row_button_content
      ~(typography : Journal_visual_tokens.typography)
      ?leading
      label
  =
  let label =
    styled_text ~token:typography.entry label
    |> Ui.Widget.align ~alignment:Ui.Layout.Alignment.Center_start
  in
  let children =
    match leading with
    | None -> [ Ui.Widget.Flex.expanded label ]
    | Some leading ->
      [ Ui.Widget.Flex.fixed leading
      ; Ui.Widget.Flex.expanded
          (label |> Ui.Widget.padding ~insets:(Ui.Layout.Edge_insets.only ~left:16. ()))
      ]
  in
  Ui.Widget.Flex.row children
  |> Ui.Widget.padding ~insets:(Ui.Layout.Edge_insets.only ~left:16. ~right:16. ())
  |> Ui.Widget.constrained_box
       ~constraints:
         (Ui.Layout.Box_constraints.create
            ~min_height:Journal_visual_tokens.hit_regions.minimum_target
            ())
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

let status_sheet_options =
  [ "backlog", Journal_model.Backlog
  ; "todo", Todo
  ; "doing", Doing
  ; "in-review", In_review
  ; "done", Done
  ; "canceled", Canceled
  ; "clear", No_status
  ]
;;

let status_sheet_sizing =
  let semantics =
    Ui.Navigation.Modal_bottom_sheet.Handle_semantics.create
      ~label:"Status picker size"
      ~medium_value:"Medium"
      ~large_value:"Large"
  in
  Ui.Navigation.Modal_bottom_sheet.Detents.create
    ~initial:Ui.Navigation.Modal_bottom_sheet.Detent.Medium
    ~dismiss_on_drag:true
    ~semantics
    [ Ui.Navigation.Modal_bottom_sheet.Detent.Medium ]
  |> fun detents -> Ui.Navigation.Modal_bottom_sheet.Sizing.Detented detents
;;

let status_sheet_page
      ~tokens
      ~typography
      ~text_scale
      ~viewport_height
      ~bottom_inset
      ~reduced_motion
      ~block
      dispatch
  =
  let block_id = Journal_model.id block in
  let current = Journal_model.task_state block in
  let minimum_target = Journal_visual_tokens.hit_regions.minimum_target in
  let row_extent = Float.max minimum_target (minimum_target *. text_scale) in
  let heading =
    styled_text ~token:typography.Journal_visual_tokens.dialog_title "Set status"
    |> Ui.Widget.padding
         ~insets:(Ui.Layout.Edge_insets.only ~left:16. ~right:16. ~top:2. ~bottom:2. ())
    |> Ui.Widget.semantics
         ~properties:
           (Ui.Semantics.create ~label:"Set status" ~role:Ui.Semantics.Role.Header ())
    |> Ui.Widget.with_test_id (Ui.Test_id.string "journal-status-sheet-heading")
  in
  let rows =
    List.map
      (fun (tag, task_state) ->
         let selected = current = task_state in
         let enabled = not selected in
         let status_palette =
           Journal_visual_tokens.status_swipe_action tokens task_state
         in
         let icon_tint =
           match task_state with
           | Journal_model.No_status -> status_palette.foreground
           | _ -> status_palette.background
         in
         let label =
           match task_state with
           | Journal_model.No_status -> "Clear"
           | _ -> Journal_model.status_name task_state
         in
         let on_press = bind_action dispatch ("status-sheet-select:" ^ tag) in
         let icon =
           Material_icon_catalog.create
             ~size:22.
             ~color:icon_tint
             (Material_icon_catalog.for_task_state task_state)
           |> Ui.Widget.with_test_id
                (Ui.Test_id.string ("journal-status-sheet-option-icon:" ^ tag))
         in
         let content =
           transparent_row_button_content ~typography ~leading:icon label
           |> Ui.Widget.with_test_id
                (Ui.Test_id.string ("journal-status-sheet-option-label:" ^ tag))
         in
         let tile =
           Ui.Material.text_button
             ~key:(Ui.Key.string ("journal-status-sheet-option:" ^ tag))
             ~enabled
             ~on_press
             ~child:content
             ()
           |> Ui.Widget.with_test_id
                (Ui.Test_id.string ("journal-status-sheet-option:" ^ tag))
         in
         let properties =
           Ui.Semantics.create
             ~label
             ~role:Ui.Semantics.Role.Button
             ~enabled
             ~selected
             ~focusable:enabled
             ~actions:(if enabled then [ Ui.Semantics.Action.Tap ] else [])
             ()
         in
         (if enabled
          then Ui.Widget.semantics ~on_action:on_press ~properties tile
          else Ui.Widget.semantics ~properties tile)
         |> Ui.Widget.sized_box ~height:row_extent)
      status_sheet_options
  in
  let heading_extent =
    (typography.Journal_visual_tokens.dialog_title.line_height *. text_scale) +. 4.
  in
  let detent_handle_extent = 48. in
  let available =
    Float.max row_extent ((viewport_height *. 0.5) -. detent_handle_extent -. bottom_inset)
  in
  let scroll_height =
    Float.min (float_of_int (List.length rows) *. row_extent) (available -. heading_extent)
    |> Float.max row_extent
  in
  let scroll =
    Ui.Widget.Scroll_view.vertical
      ~key:(Ui.Key.string "journal-status-sheet-scroll")
      ~primary:true
      ~on_scroll:
        (Ui.Event.Handler.create ~name:"journal-status-sheet-scroll" (fun _ -> ()))
      [ Ui.Widget.Sliver.list rows ]
      ()
    |> Ui.Widget.Viewport.Vertical.with_test_id
         (Ui.Test_id.string "journal-status-sheet-scroll")
    |> Ui.Widget.Viewport.Vertical.with_height ~height:scroll_height
  in
  let content =
    Ui.Widget.Flex.column [ Ui.Widget.Flex.fixed heading; Ui.Widget.Flex.fixed scroll ]
    |> Ui.Widget.safe_area ~left:false ~top:false ~right:false ~bottom:true
    |> Ui.Widget.with_test_id
         (Ui.Test_id.string ("journal-status-sheet-safe-area:" ^ block_id))
  in
  let duration = (Journal_visual_tokens.motion ~reduced_motion).route_transition_ms in
  let presentation =
    Ui.Navigation.Modal_bottom_sheet.create
      ~barrier_dismissible:true
      ~barrier_label:"Dismiss status picker"
      ~sizing:status_sheet_sizing
      ~use_safe_area:false
      ~request_focus:true
      ~transition_duration_ms:duration
      ~reverse_transition_duration_ms:duration
      ()
  in
  let route_id = "journal-status-sheet:" ^ block_id in
  content
  |> Ui.Widget.page
       ~key:(Ui.Key.string route_id)
       ~page_key:(ID.Navigation.Page_key.of_string route_id)
       ~presentation:(Ui.Navigation.Modal_bottom_sheet presentation)
       ~can_pop:true
       ~restoration_id:(ID.Navigation.Restoration_id.of_string route_id)
  |> Ui.Widget.with_test_id (Ui.Test_id.string ("journal-status-sheet-page:" ^ block_id))
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

module Root_scroll = struct
  type props =
    { destination : int
    ; revision : int
    ; anchor_offset : float
    ; visible : bool
    ; duration_ms : int
    ; active : bool
    }

  let kind_id = ID.Native_widget.Kind_id.of_int 1003

  let decode_event ~event_id payload =
    if Bytes.length payload <> 24
    then Error "Invalid root scroll event"
    else (
      let destination =
        match Bytes.get_int32_le payload 0 with
        | 0l -> Some Journal_routes.Journals
        | 1l -> Some Journal_routes.Favorites
        | _ -> None
      in
      let pixels = Int64.float_of_bits (Bytes.get_int64_le payload 8) in
      let delta = Int64.float_of_bits (Bytes.get_int64_le payload 16) in
      match destination, ID.Native_widget.Event_id.to_int event_id with
      | Some destination, 1 when Float.is_finite pixels && Float.is_finite delta ->
        Ok (Root_navigation.Scroll { destination; pixels; delta })
      | Some destination, 2 -> Ok (Root_navigation.Non_scrollable destination)
      | _ -> Error "Unknown root scroll event")
  ;;

  let event_of_payload = function
    | Ui.Event.Payload.Native_event event
      when event.kind_id = kind_id && event.version = 1 ->
      decode_event ~event_id:event.event_id event.payload |> Result.to_option
    | _ -> None
  ;;

  let extension =
    Ui.Native_widget.Extension.create
      ~kind_id
      ~version:1
      ~capabilities:[]
      ~encode_props:(fun props ->
        let bytes = Bytes.make 32 '\000' in
        Bytes.set_int32_le bytes 0 (Int32.of_int props.destination);
        Bytes.set_int32_le bytes 4 (if props.visible then 1l else 0l);
        Bytes.set_int32_le bytes 24 (Int32.of_int props.duration_ms);
        Bytes.set_int32_le bytes 28 (if props.active then 1l else 0l);
        Bytes.set_int64_le bytes 8 (Int64.of_int props.revision);
        Bytes.set_int64_le bytes 16 (Int64.bits_of_float props.anchor_offset);
        bytes)
      ~decode_event
      ()
  ;;

  let wrap
        ~graph_generation
        ~destination
        ~favorites
        ~profile
        ~visible
        ~duration_ms
        ~active
        ~on_event
        child
    =
    let rows = Journal_routes.Favorites.items favorites in
    let anchor = Journal_routes.Favorites.anchor favorites in
    let anchor_offset =
      rows
      |> List.to_seq
      |> Seq.take anchor.first_index
      |> Seq.fold_left
           (fun sum item ->
              sum
              +. Journal_row.Item.visible_extent
                   (Journal_row.Item.of_favorite (Journal_graph_projection.favorite item))
                   ~profile
                   ~expanded:false)
           0.
    in
    Ui.Native_widget.widget_with_handler
      extension
      ~key:(Ui.Key.string ("journal-root-scroll:" ^ string_of_int graph_generation))
      ~props:
        { destination = (if destination = Journal_routes.Journals then 0 else 1)
        ; revision = Journal_routes.Favorites.revision favorites
        ; anchor_offset
        ; visible
        ; duration_ms
        ; active
        }
      ~on_event
      ~children:[ child ]
      ()
  ;;
end

let favorites_sliver
      ~tokens
      ~typography
      ~profile
      ~device_pixel_ratio
      ~rtl
      ~reduced_motion
      ~state
      ~on_visible_range
      ~on_retry
  =
  let module F = Journal_routes.Favorites in
  let status message =
    Ui.Widget.text message |> Ui.Widget.center |> Ui.Widget.Sliver.fill
  in
  let rows = F.items state in
  let notice =
    match F.error state with
    | Some message ->
      Some
        (Ui.Widget.column
           [ live_region_text message
           ; Ui.Material.text_button ~on_press:on_retry ~child:(Ui.Widget.text "Retry") ()
             |> Ui.Widget.with_test_id (Ui.Test_id.string "favorites-retry-button")
           ]
         |> Ui.Widget.with_test_id (Ui.Test_id.string "favorites-retry")
         |> Ui.Widget.Sliver.box)
    | None -> None
  in
  let body =
    if rows = []
    then (
      match F.error state with
      | Some _ -> []
      | None when (not (F.initialized state)) || F.loading state ->
        [ status "Loading favorites…" ]
      | None -> [ status "No favorites yet" ])
    else (
      let first_index, window = F.window state in
      let item value =
        value |> Journal_graph_projection.favorite |> Journal_row.Item.of_favorite
      in
      let extent value =
        Journal_row.Item.visible_extent (item value) ~profile ~expanded:false
      in
      let items =
        List.mapi
          (fun index (value : Logseq_db_worker.Protocol.v2_favorite_item) ->
             Journal_row.view
               ~tokens
               ~typography
               ~profile
               ~device_pixel_ratio
               ~rtl
               ~item:(item value)
               ~show_timestamp:false
               ~expanded:false
               ~show_divider:false
               ~sort_base:(100. +. (float_of_int (first_index + index) *. 10.))
               ~reduced_motion
               ~interaction:Journal_row.Display_only
             |> Ui.Widget.Keyed.create
                  ~key:
                    (Ui.Key.string
                       (Logseq_db_types.Graph_types.Uuid.to_string value.membership_uuid)))
          window
      in
      [ Ui.Widget.Sliver.varied_extent
          ~key:(Ui.Key.string "favorites-list")
          ~total_count:(List.length rows)
          ~first_index
          ~default_item_extent:profile.Journal_visual_tokens.block_line_height
          ~extent_overrides:
            (List.mapi
               (fun index value ->
                  Ui.Widget.Sparse_extent_override.{ index; extent = extent value })
               rows)
          ~overscan:12
          ~items
          ~on_visible_range
          ()
        |> Ui.Widget.Sliver.with_test_id (Ui.Test_id.string "favorites-list")
      ])
  in
  body @ Option.to_list notice
;;

let timeline_page
      ~graph_generation
      ~destination
      ~favorites
      ~on_select_destination
      ~on_favorites_visible_range
      ~on_favorites_retry
      ~viewport_width
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
      ~sync_phase
      ~today_date
      ~day_presentation
      ~reduced_motion
      ~rtl
      ~content_horizontal_inset
      ~capture_enabled
      ~capture_save_enabled
      ~capture_saving
      ~capture_task_selected
      ~capture_affordance_key
      ~capture_fab_presentation
      ~navigation_visible
      ~root_active
      ~on_capture_event
      ~on_scroll
      ~on_visible_range
      ~on_retry_day
      ~on_toggle_children
      ~delete_enabled
      ~actions_enabled
      ~on_status
      ~on_delete
      ~error_info_available
      ~on_error_info
      ~account_menu_available
      ~on_account_menu
  =
  let header =
    Journal_header.sliver
      ~viewport_width
      ~tokens
      ~typography
      ~text_scale
      ~top_inset
      ~device_pixel_ratio
      ~context:
        (match destination with
         | Journal_routes.Journals -> Journal_header.Context.today ~date:today_date
         | Favorites -> Journal_header.Context.favorites)
      ~sync_phase
      ~on_error_info:(if error_info_available then Some on_error_info else None)
      ~on_account_menu:(if account_menu_available then Some on_account_menu else None)
  in
  let capture_button ~id ~test_id ~tooltip ~position ~visibility ~style ~enabled icon =
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
         |> Ui.Widget.with_test_id (Ui.Test_id.string test_id))
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
            ~id:2
            ~test_id:"journal-capture-composer-task"
            ~tooltip:
              (if capture_task_selected
               then "Capture as task, on"
               else "Capture as task, off")
            ~position:Ui.Native_widget.Expandable_message_composer.Leading
            ~visibility:Always
            ~style:(if capture_task_selected then Filled else Plain)
            ~enabled:capture_enabled
            Material_icon_catalog.Timelapse
        ; capture_button
            ~id:1
            ~test_id:"journal-capture-composer-submit"
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
        ~day_presentation
        ~reduced_motion
        ~delete_enabled
        ~actions_enabled
        ~on_status
        ~on_delete
        ~on_visible_range
        ~on_retry_day
        ~on_toggle_children
  in
  let favorites_selected = destination = Journal_routes.Favorites in
  let slivers =
    if favorites_selected
    then
      favorites_sliver
        ~tokens
        ~typography
        ~profile
        ~device_pixel_ratio
        ~rtl
        ~reduced_motion
        ~state:favorites
        ~on_visible_range:on_favorites_visible_range
        ~on_retry:on_favorites_retry
    else [ timeline ]
  in
  let timeline =
    Ui.Widget.Scroll_view.vertical
      ~key:
        (Ui.Key.string
           (if favorites_selected then "favorites-scroll" else "journal-scroll"))
      ~primary:true
      ~on_scroll:
        (Ui.Event.Handler.create ~name:"root-scroll-owned-natively" (fun _ -> ()))
      (header :: slivers)
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
      let banner =
        live_region_text message
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
  let navigation =
    Ui.Material.navigation_bar
      ~layout:Ui.Material.Compact
      ~selected_index:(if favorites_selected then 1 else 0)
      ~label_behavior:Ui.Material.Never
      ~on_select:on_select_destination
      [ Ui.Material.Navigation_destination.create
          ~label:"Journals"
          ~icon:(Material_icon_catalog.create ~size:24. View_day)
          ()
      ; Ui.Material.Navigation_destination.create
          ~label:"Favorites"
          ~icon:(Material_icon_catalog.create ~size:24. Star)
          ()
      ]
      ()
    |> Ui.Widget.with_test_id (Ui.Test_id.string "journal-root-navigation")
  in
  Ui.Material.scaffold
    ~body
    ~bottom_navigation_bar:navigation
    ?floating_action_button:(if favorites_selected then None else Some capture)
    ~floating_action_button_location:Ui.Material.End_float
    ()
  |> Root_scroll.wrap
       ~graph_generation
       ~destination
       ~favorites
       ~profile
       ~visible:navigation_visible
       ~duration_ms:capture_motion.route_transition_ms
       ~active:root_active
       ~on_event:on_scroll
  |> Ui.Widget.page
       ~key:(Ui.Key.string "journal-timeline")
       ~page_key:(ID.Navigation.Page_key.of_string "journal-timeline")
       ~can_pop:false
  |> Ui.Widget.with_test_id (Ui.Test_id.string "journal-timeline-page")
;;

let dialog_body
      ~(typography : Journal_visual_tokens.typography)
      ~test_id
      ~title
      ~message
      ~primary
      ~secondary
  =
  Ui.Material.Dialog.alert
    ~title
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
  let controls =
    [ action
        ~role:Text
        ~test_id:"journal-account-settings"
        ~label:"Settings"
        ~hint:"Open application presentation settings"
        ~command:"open-settings"
        "Settings"
    ; action
        ~role:Text
        ~test_id:"journal-account-diagnostics"
        ~label:"Diagnostics"
        ~hint:"Open read-only application diagnostics"
        ~command:"open-diagnostics"
        "Diagnostics"
    ; action
        ~role:Text
        ~test_id:"journal-account-switch-graph"
        ~label:"Switch graph"
        ~hint:"Close the current graph and choose another authorized graph"
        ~command:"switch-graph"
        "Switch graph"
    ]
    @ (if cache_reset_available
       then
         [ action
             ~role:Text
             ~test_id:"journal-account-reset-local-copy"
             ~label:"Delete local graph copy"
             ~hint:"Delete this local copy and return to graph selection"
             ~command:"request-local-cache-reset"
             "Delete local graph copy"
         ]
       else [])
    @ [ action
          ~role:Text
          ~test_id:"journal-account-sign-out"
          ~label:"Sign out"
          ~hint:"Close the current graph and return to sign in"
          ~command:"sign-out"
          "Sign out"
      ]
  in
  let cancel =
    action
      ~role:Text
      ~test_id:"journal-account-menu-dismiss"
      ~label:"Close account menu"
      ~hint:"Return to the journal"
      ~command:"close-account-menu"
      "Cancel"
  in
  let content =
    Ui.Widget.column
      (styled_text
         ~token:typography.supporting
         "Manage the current Logseq graph and authenticated session."
       :: controls)
    |> Ui.Widget.with_test_id (Ui.Test_id.string "journal-account-actions")
  in
  Ui.Material.Dialog.alert ~title:"Account" ~content ~actions:[ cancel ] ()
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

let settings_dialog_page
      ~tokens
      ~(typography : Journal_visual_tokens.typography)
      ~preset
      ~reduced_motion
      dispatch
  =
  let chip option label command test_id =
    let selected = preset = option in
    let on_press = bind_action dispatch command in
    Ui.Material.Chip.filter ~key:(Ui.Key.string test_id) ~selected ~on_press ~label ()
    |> Ui.Widget.with_test_id (Ui.Test_id.string test_id)
    |> Ui.Widget.semantics
         ~on_action:on_press
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
  Ui.Material.Dialog.alert ~title:"Settings" ~content ~actions:[ close ] ()
  |> Ui.Widget.with_test_id (Ui.Test_id.string "journal-settings")
  |> modal_dialog_page
       ~tokens
       ~reduced_motion
       ~page_key:"journal-settings-dialog"
       ~test_id:"journal-settings-dialog-page"
       ~barrier_label:"Settings"
;;

let obsolete_diagnostic_row = function
  | "Phase" | "Startup presentation" -> true
  | _ -> false
;;

let current_diagnostic_rows rows =
  List.filter (fun (label, _) -> not (obsolete_diagnostic_row label)) rows
;;

let diagnostic_rows (diagnostics : Graph_service.diagnostics) =
  List.concat_map
    (fun (group : Graph_service.diagnostic_group) ->
       current_diagnostic_rows group.entries)
    diagnostics.groups
;;

let sync_phase_name : Graph_service.sync_phase -> string = function
  | Offline -> "Offline"
  | Connecting -> "Connecting"
  | Pulling -> "Pulling"
  | Submitting -> "Submitting"
  | Current -> "Current"
  | Paused -> "Paused"
  | Failed -> "Failed"
;;

let startup_phase_name : Journal_startup.startup_phase -> string = function
  | Signed_out -> "Signed out"
  | Loading_catalog -> "Loading catalog"
  | Awaiting_selection -> "Awaiting selection"
  | Restoring_local -> "Restoring local"
  | Deleting_local -> "Deleting local copy"
  | Bootstrapping -> "Bootstrapping"
  | Awaiting_e2ee_password -> "Awaiting E2EE password"
  | Ready -> "Ready"
  | Failed -> "Failed"
;;

let graph_phase_name : Logseq_db_worker.graph_phase -> string = function
  | Graph_closed -> "Closed"
  | Graph_opening -> "Opening"
  | Graph_open -> "Open"
  | Graph_closing -> "Closing"
  | Graph_failed -> "Failed"
;;

let diagnostic_phase_rows ~snapshot ~(graph : Logseq_db_worker.graph_state) =
  match snapshot with
  | None ->
    [ "Sync phase", "Not available"
    ; "Startup phase", "Not available"
    ; "Graph phase", graph_phase_name graph.phase
    ]
  | Some snapshot ->
    let startup = Journal_startup.derive ~snapshot ~graph in
    [ "Sync phase", sync_phase_name snapshot.sync_phase
    ; "Startup phase", startup_phase_name startup.phase
    ; "Graph phase", graph_phase_name graph.phase
    ]
;;

let format_bytes bytes =
  let bytes = max 0 bytes in
  let format_scaled divisor suffix =
    if bytes mod divisor = 0
    then Printf.sprintf "%d %s" (bytes / divisor) suffix
    else Printf.sprintf "%.1f %s" (Float.of_int bytes /. Float.of_int divisor) suffix
  in
  if bytes < 1024
  then Printf.sprintf "%d B" bytes
  else if bytes < 1024 * 1024
  then format_scaled 1024 "KB"
  else format_scaled (1024 * 1024) "MB"
;;

let admission_rows observation =
  let values =
    match (observation : Admission_refresh.observation) with
    | Available inspection ->
      [ Printf.sprintf "%d / %d" inspection.active_records inspection.maximum_records
      ; Printf.sprintf
          "%s / %s"
          (format_bytes inspection.active_bytes)
          (format_bytes inspection.maximum_bytes)
      ; format_bytes inspection.protected_wire_bytes
      ; format_bytes inspection.retained_origin_evidence_bytes
      ]
    | Loading -> List.init 4 (fun _ -> "Loading")
    | Unavailable -> List.init 4 (fun _ -> "Not available")
  in
  List.combine
    [ "Outbox records"; "Outbox bytes"; "Protected payload"; "Origin evidence" ]
    values
;;

let diagnostic_groups diagnostics =
  let unavailable labels = List.map (fun label -> label, "Not available") labels in
  match diagnostics with
  | None ->
    [ "Manager", unavailable [ "Last error" ]
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
  | Some (diagnostics : Graph_service.diagnostics) ->
    diagnostics.groups
    |> List.filter_map (fun (group : Graph_service.diagnostic_group) ->
      let entries = current_diagnostic_rows group.entries in
      if entries = [] then None else Some (group.title, entries))
;;

let worker_error_detail_value = function
  | Logseq_db_worker.Error.Detail_string value -> value
  | Detail_int value -> Int64.to_string value
  | Detail_bool value -> string_of_bool value
  | Detail_uuid value -> Logseq_db_types.Graph_types.Uuid.to_string value
  | Detail_strings values -> String.concat ", " values
  | Detail_uuids values ->
    values |> List.map Logseq_db_types.Graph_types.Uuid.to_string |> String.concat ", "
;;

let error_info_page ~(typography : Journal_visual_tokens.typography) occurrences dispatch =
  let back =
    action_target
      ~role:Text
      ~test_id:"journal-error-info-back"
      ~label:"Back from Error info"
      ~hint:"Return to the previous page"
      ~on_press:(bind_action dispatch "close-error-info")
      (styled_text "Back")
  in
  let header =
    Ui.Widget.Flex.row
      [ Ui.Widget.Flex.fixed back
      ; Ui.Widget.Flex.expanded
          (styled_text ~token:typography.manager_title "Error info"
           |> Ui.Widget.semantics
                ~properties:
                  (Ui.Semantics.create
                     ~label:"Error info"
                     ~role:Ui.Semantics.Role.Header
                     ~heading_level:1
                     ()))
      ]
    |> Ui.Widget.padding ~insets:(Ui.Layout.Edge_insets.all 16.)
  in
  let labeled_row label value =
    Ui.Widget.Flex.column
      [ Ui.Widget.Flex.fixed (styled_text ~token:typography.button_label label)
      ; Ui.Widget.Flex.fixed (styled_text ~token:typography.supporting value)
      ]
    |> Ui.Widget.padding
         ~insets:(Ui.Layout.Edge_insets.symmetric ~horizontal:12. ~vertical:4. ())
  in
  let cause_row depth label (cause : Logseq_db_worker.Error.cause) =
    let code = Option.fold ~none:"" ~some:(fun value -> " · " ^ value) cause.code in
    Ui.Widget.Flex.column
      [ Ui.Widget.Flex.fixed
          (styled_text
             ~token:typography.button_label
             (Printf.sprintf
                "%s · %s%s"
                (Logseq_db_worker.Error.component_string cause.component)
                cause.operation
                code))
      ; Ui.Widget.Flex.fixed (styled_text ~token:typography.supporting cause.message)
      ]
    |> Ui.Widget.padding
         ~insets:
           (Ui.Layout.Edge_insets.only
              ~left:(12. +. (Float.of_int depth *. 12.))
              ~right:12.
              ~top:4.
              ~bottom:4.
              ())
    |> Ui.Widget.semantics
         ~properties:
           (Ui.Semantics.create
              ~label:
                (Printf.sprintf
                   "%s, %s, %s"
                   label
                   (Logseq_db_worker.Error.component_string cause.component)
                   cause.message)
              ())
  in
  let card (occurrence : worker_error_occurrence) =
    let error = occurrence.error in
    let trace = Logseq_db_worker.Error.trace error in
    let status = if occurrence.active then "Active" else "Resolved" in
    let metadata =
      [ Some ("Operation", occurrence.operation)
      ; Option.map (fun phase -> "Request phase", phase) occurrence.phase
      ; Option.map
          (fun request_id ->
             "Request ID", Logseq_db_types.Graph_types.Uuid.to_string request_id)
          occurrence.request_id
      ; Some ("Graph generation", string_of_int occurrence.graph_generation)
      ; Option.map
          (fun graph_id ->
             "Graph ID", Logseq_db_types.Graph_types.Uuid.to_string graph_id)
          occurrence.graph_id
      ; Option.map (fun label -> "Observed at", label) occurrence.occurred_at_label
      ]
      |> List.filter_map Fun.id
    in
    let details =
      Logseq_db_worker.Error.details error
      |> List.map (fun (detail : Logseq_db_worker.Error.detail) ->
        detail.name, worker_error_detail_value detail.value)
    in
    let causes =
      List.mapi (fun index cause -> cause_row index "Context" cause) trace.contexts
      @ [ cause_row (List.length trace.contexts) "Origin" trace.origin ]
      @
      if trace.truncated
      then [ labeled_row "Causal trace" "Earlier outer contexts were truncated." ]
      else []
    in
    Ui.Widget.Flex.column
      ([ Ui.Widget.Flex.fixed
           (styled_text
              ~token:typography.dialog_title
              (Logseq_db_worker.Error.code_string (Logseq_db_worker.Error.code error)))
       ; Ui.Widget.Flex.fixed
           (styled_text ~token:typography.entry (Logseq_db_worker.Error.message error))
       ; Ui.Widget.Flex.fixed
           (labeled_row ("Occurrence " ^ Int64.to_string occurrence.sequence) status)
       ]
       @ List.map
           (fun row -> Ui.Widget.Flex.fixed (labeled_row (fst row) (snd row)))
           metadata
       @ List.map
           (fun row -> Ui.Widget.Flex.fixed (labeled_row (fst row) (snd row)))
           details
       @ List.map Ui.Widget.Flex.fixed causes)
    |> Ui.Widget.padding ~insets:(Ui.Layout.Edge_insets.all 12.)
    |> Ui.Material.card ~elevation:1.
    |> Ui.Widget.padding
         ~insets:(Ui.Layout.Edge_insets.symmetric ~horizontal:16. ~vertical:8. ())
    |> Ui.Widget.with_test_id
         (Ui.Test_id.string
            ("journal-worker-error-" ^ Int64.to_string occurrence.sequence))
  in
  let rows =
    match occurrences with
    | [] -> [ styled_text ~token:typography.supporting "No worker errors observed." ]
    | occurrences -> List.map card occurrences
  in
  let scroll =
    Ui.Widget.Scroll_view.vertical
      ~key:(Ui.Key.string "journal-error-info-scroll")
      ~on_scroll:(Ui.Event.Handler.create ~name:"journal-error-info-scroll" (fun _ -> ()))
      [ Ui.Widget.Sliver.list rows ]
      ()
    |> Ui.Widget.Viewport.Vertical.with_test_id
         (Ui.Test_id.string "journal-error-info-scroll")
  in
  let body =
    Ui.Widget.Body.Vertical.create
      [ Ui.Widget.Body.Vertical.fixed header; Ui.Widget.Body.Vertical.fill scroll ]
    |> Ui.Widget.Body.safe_area
  in
  Ui.Material.scaffold ~body ()
  |> Ui.Widget.page
       ~key:(Ui.Key.string "journal-error-info")
       ~page_key:(ID.Navigation.Page_key.of_string "journal-error-info")
       ~presentation:(Ui.Navigation.Standard Ui.Navigation.Fade)
       ~can_pop:true
  |> Ui.Widget.with_test_id (Ui.Test_id.string "journal-error-info-page")
;;

let diagnostics_page
      ~tokens
      ~(typography : Journal_visual_tokens.typography)
      ~reduced_motion
      ~snapshot
      ~graph
      ~admission
      diagnostics
      dispatch
  =
  let close =
    action_target
      ~role:Text
      ~test_id:"journal-diagnostics-close"
      ~label:"Close Diagnostics"
      ~hint:"Return to the previous screen"
      ~on_press:(bind_action dispatch "close-diagnostics")
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
    (heading "Phases" :: List.map row (diagnostic_phase_rows ~snapshot ~graph))
    @ (heading "Overlay DB" :: List.map row (admission_rows admission))
    @ (diagnostic_groups diagnostics
       |> List.concat_map (fun (title, rows) -> heading title :: List.map row rows))
  in
  let scroll =
    Ui.Widget.Scroll_view.vertical
      ~key:(Ui.Key.string "journal-diagnostics-scroll")
      ~on_scroll:
        (Ui.Event.Handler.create ~name:"journal-diagnostics-scroll" (fun _ -> ()))
      [ Ui.Widget.Sliver.list current ]
      ()
    |> Ui.Widget.Viewport.Vertical.with_test_id
         (Ui.Test_id.string "journal-diagnostics-scroll")
  in
  let header =
    Ui.Widget.Flex.row
      [ Ui.Widget.Flex.expanded
          (styled_text ~token:typography.manager_title "Diagnostics"
           |> Ui.Widget.semantics
                ~properties:
                  (Ui.Semantics.create
                     ~label:"Diagnostics"
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
       ~page_key:"journal-diagnostics-dialog"
       ~test_id:"journal-diagnostics-dialog-page"
       ~barrier_label:"Diagnostics"
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
      ~label:"Delete local graph copy"
      ~hint:"Delete the local copy and return to graph selection"
      ~on_press:(bind_action dispatch "confirm-local-cache-reset")
      (styled_text "Delete local graph copy")
  in
  dialog_body
    ~typography
    ~test_id:"local-cache-reset-dialog"
    ~title:"Delete local graph copy?"
    ~message:
      "This deletes the local copy, including unsaved drafts and pending local changes, \
       then returns to graph selection. The remote graph and cached encryption key are \
       retained. Select a graph to open or download it."
    ~primary:cancel
    ~secondary:confirm
  |> modal_dialog_page
       ~tokens
       ~reduced_motion
       ~page_key:"local-cache-reset-dialog"
       ~test_id:"local-cache-reset-dialog-page"
       ~barrier_label:"Delete local graph copy confirmation"
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
  let diagnostics_entry () =
    action_target
      ~role:Outlined
      ~test_id:"journal-startup-diagnostics"
      ~label:"Diagnostics"
      ~hint:"Open read-only application diagnostics"
      ~on_press:(bind_action dispatch "open-diagnostics")
      (styled_text "Diagnostics")
    |> Ui.Widget.padding
         ~insets:(Ui.Layout.Edge_insets.symmetric ~horizontal:24. ~vertical:12. ())
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
      |> Ui.Material.Tooltip.plain ~message:"Refresh graphs"
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
        (fun (graph : Graph_service.graph) ->
           let graph_id = Logseq_db_types.Graph_types.Uuid.to_string graph.graph_id in
           let on_press = bind_action dispatch ("select-graph:" ^ graph_id) in
           Ui.Material.text_button
             ~key:(Ui.Key.string ("graph-picker:" ^ graph_id))
             ~on_press
             ~child:(transparent_row_button_content ~typography graph.name)
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
        snapshot.Graph_service.catalog
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
      [ Ui.Widget.Body.Vertical.fixed toolbar
      ; Ui.Widget.Body.Vertical.fill scroll
      ; Ui.Widget.Body.Vertical.fixed (diagnostics_entry ())
      ]
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
         | Deleting_local ->
           let message =
             match snapshot.local_deletion with
             | Some (Deletion_in_progress Closing_graph) -> "Closing the local graph"
             | Some (Deletion_in_progress Deleting_mirror) -> "Deleting the local copy"
             | Some (Deletion_in_progress Clearing_selection) ->
               "Clearing the saved selection"
             | None | Some (Deletion_failed _) -> "Deleting the local copy"
           in
           message, []
         | Bootstrapping ->
           let progress_text =
             match state.bootstrap_progress with
             | None -> "Preparing the local mirror"
             | Some progress ->
               Printf.sprintf "Downloaded %Ld bytes" progress.Graph_service.received_bytes
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
             | Some Journal_startup.Refresh_catalog ->
               Some ("refresh-catalog", "Retry", "Retry startup")
             | Some Begin_online_recovery ->
               Some
                 ( "begin-online-recovery"
                 , "Continue online"
                 , "Continue startup with online recovery" )
             | Some Retry_graph_open ->
               Some ("begin-online-recovery", "Retry", "Retry startup")
             | Some Submit_e2ee_password | Some Sign_in | None -> None
           in
           let action_name, action_label, action_hint =
             match action with
             | Some (name, label, hint) -> Some name, label, hint
             | None -> None, "Retry", "Retry startup"
           in
           ( message
           , if Option.is_none action_name
             then []
             else
               [ Ui.Widget.Flex.fixed
                   (action_target
                      ~role:Filled_tonal
                      ~test_id:"graph-picker-retry"
                      ~label:action_label
                      ~hint:action_hint
                      ~enabled:(Option.is_some action_name)
                      ~on_press:
                        (bind_action
                           dispatch
                           (Option.value action_name ~default:"retry-disabled"))
                      (styled_text action_label))
               ] ))
    in
    Ui.Widget.Flex.column
      ((Ui.Widget.Flex.fixed (title_widget title) :: controls)
       @ [ Ui.Widget.Flex.fixed (diagnostics_entry ()) ])
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

(* One serialized generator lifetime spans every component and graph switch. *)
let block_identity_state = ref Logseq_db_types.Squuid.empty
let block_identity_mutex = Mutex.create ()

let read_block_entropy () =
  let descriptor = Unix.openfile "/dev/urandom" [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close descriptor)
    (fun () ->
       let bytes = Bytes.create 16 in
       let rec read offset =
         if offset < Bytes.length bytes
         then (
           match Unix.read descriptor bytes offset (Bytes.length bytes - offset) with
           | 0 -> raise End_of_file
           | count -> read (offset + count)
           | exception Unix.Unix_error (Unix.EINTR, _, _) -> read offset)
       in
       read 0;
       bytes)
;;

let with_block_identity ?(entropy = read_block_entropy) ~creation_time ~f () =
  Mutex.lock block_identity_mutex;
  let identity =
    Fun.protect
      ~finally:(fun () -> Mutex.unlock block_identity_mutex)
      (fun () ->
         let random =
           try Ok (entropy ()) with
           | _ ->
             Error
               "Unable to create a block ID because device randomness is unavailable. \
                Your draft is kept; try saving again."
         in
         Result.bind random (fun random_bytes ->
           match
             Logseq_db_types.Squuid.next
               !block_identity_state
               ~timestamp_ms:(Journal_time.instant_unix_ms creation_time)
               ~random_bytes
           with
           | Ok (state, identity) ->
             block_identity_state := state;
             Ok identity
           | Error error ->
             let message =
               match error with
               | Timestamp_out_of_range ->
                 "The clock is outside the supported block ID range. Check your device \
                  date and try saving again."
               | Invalid_random_length _ ->
                 "OS randomness returned an invalid length. Try saving again."
               | Payload_exhausted ->
                 "Block IDs at the current timestamp are exhausted. Wait for the clock \
                  to advance and try saving again."
             in
             Error ("Unable to create a block ID. Your draft is kept. " ^ message)))
  in
  Result.map f identity
;;

let sibling_order value = Printf.sprintf "%012Ld" value

let component ~calendar_sampler client handlers graph =
  let state, set_state_and_effect =
    Bonsai.Cont.state_machine0
      ~equal:( = )
      ~default_model:initial_state
      ~apply_action:(fun context state update ->
        let state, scheduled_effect = update state in
        let active =
          Journal_routes.route state.routes = Timeline && state.modal = No_modal
        in
        let state = Root_navigation.step state (Root_active active) in
        let destination = Journal_routes.destination state.routes in
        let empty =
          match destination with
          | Journals ->
            (not state.feed_loaded)
            || Option.is_some state.graph_error
            || Journal_timeline_state.total_count state.timeline = 0
          | Favorites -> Journal_routes.Favorites.items state.favorites = []
        in
        let state =
          if empty then Root_navigation.step state (Non_scrollable destination) else state
        in
        Bonsai.Cont.Apply_action_context.schedule_event context scheduled_effect;
        state)
      graph
  in
  let set_state =
    Bonsai.Cont.map set_state_and_effect ~f:(fun update ->
      fun f -> update (fun state -> f state, Bonsai.Effect.Ignore))
  in
  let set_state_ref = ref None in
  let state_ref = ref initial_state in
  let graph_runtime =
    Journal_graph_runtime.create
      ~localtime:(Journal_calendar.Sampler.localtime calendar_sampler)
      ()
  in
  let started_graph_generation = ref None in
  let send_manager command =
    Bonsai.Effect.of_thunk (fun () ->
      ignore
        (Worker.send client (Graph_service.Client_command command) : Worker.send_result))
  in
  let submit request = Journal_graph_runtime.submit graph_runtime request in
  let fail_graph_transport state message =
    terminal_graph_state state (Transport_graph_error message)
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
  let admission_worker_requests = Hashtbl.create 4 in
  let favorites_worker_requests = Hashtbl.create 2 in
  let rec run_admission_directive set_state_and_effect = function
    | Admission_refresh.No_request -> Bonsai.Effect.Ignore
    | Request request ->
      Bonsai.Effect.bind
        (Bonsai.Effect.of_thunk (fun () ->
           let output = submit (Journal_graph_request.Inspect_admission request) in
           Journal_graph_transport.deliver
             ~runtime:graph_runtime
             ~send:(fun protocol_request ->
               match
                 Worker.send client (Graph_service.Graph_request protocol_request)
               with
               | Accepted worker_request_id ->
                 Hashtbl.replace
                   admission_worker_requests
                   worker_request_id
                   (request, protocol_request);
                 Journal_graph_transport.Accepted
               | Full -> Full
               | Not_ready -> Not_ready
               | Stopping -> Stopping)
             output))
        ~f:(fun delivery ->
          match delivery.Journal_graph_transport.error with
          | None -> Bonsai.Effect.Ignore
          | Some _ ->
            update_admission set_state_and_effect (fun state ->
              Admission_refresh.complete
                state.admission_refresh
                ~request
                ~result:Inspection_unavailable))
  and update_admission set_state_and_effect transition =
    set_state_and_effect (fun state ->
      let admission_refresh, directive = transition state in
      ( { state with admission_refresh }
      , run_admission_directive set_state_and_effect directive ))
  in
  let trigger_admission set_state_and_effect ~graph_generation ~graph_open =
    update_admission set_state_and_effect (fun state ->
      Admission_refresh.trigger state.admission_refresh ~graph_generation ~graph_open)
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
    Bonsai.Effect.bind
      (Bonsai.Effect.of_thunk (fun () -> deliver_output (submit request)))
      ~f:(fun delivery ->
        match !set_state_ref with
        | None -> Bonsai.Effect.Ignore
        | Some set_state ->
          set_state (fun state -> apply_delivery_responses state delivery))
  in
  let observe_graph_state
        set_state
        set_state_and_effect
        (graph_state : Logseq_db_worker.graph_state)
    =
    let update =
      set_state (fun state ->
        let state =
          match graph_state.phase, graph_state.error with
          | Graph_failed, Some error
            when state.graph_state.phase <> Graph_failed
                 || state.graph_state.generation <> graph_state.generation ->
            if graph_lifecycle_owns_publication error
            then record_worker_error state ~operation:"graphLifecycle" error
            else state
          | Graph_failed, Some _
          | Graph_failed, None
          | Graph_closed, _
          | Graph_opening, _
          | Graph_open, _
          | Graph_closing, _ -> state
        in
        let graph_error =
          match graph_state.phase, graph_state.error with
          | Graph_failed, Some error ->
            List.find_opt
              (fun occurrence -> occurrence.error == error)
              state.worker_errors
            |> Option.map (fun occurrence -> Worker_graph_error occurrence)
          | Graph_failed, None
          | Graph_closed, _
          | Graph_opening, _
          | Graph_open, _
          | Graph_closing, _ -> None
        in
        let state =
          if
            state.graph_state.generation <> graph_state.generation
            || state.graph_state.graph_id <> graph_state.graph_id
          then Root_navigation.step state (Graph_replaced graph_state.generation)
          else state
        in
        { state with
          graph_state
        ; write_enabled =
            (if graph_state.phase = Graph_open then state.write_enabled else false)
        ; graph_ready =
            (if graph_state.phase = Graph_open then state.graph_ready else false)
        ; graph_error
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
          Hashtbl.clear favorites_worker_requests;
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
                  favorites =
                    Journal_routes.Favorites.create
                      ~graph_generation:graph_state.generation
                ; favorites_requests = []
                ; routes = Journal_routes.create ~anchor:initial_anchor
                ; direct_capture = None
                ; graph_ready = false
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
    Bonsai.Effect.bind update ~f:(fun () ->
      Bonsai.Effect.Many
        [ start_graph
        ; trigger_admission
            set_state_and_effect
            ~graph_generation:graph_state.generation
            ~graph_open:(graph_state.phase = Graph_open)
        ])
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
            Bonsai.Cont.map3
              state
              set_state_and_effect
              until
              ~f:(fun snapshot set_state_and_effect until ->
                match snapshot.pending_delete with
                | None -> Bonsai.Effect.Ignore
                | Some activated ->
                  let delayed_commit =
                    Bonsai.Effect.bind (until activated.deadline) ~f:(fun () ->
                      set_state_and_effect (fun state ->
                        match state.pending_delete with
                        | Some pending
                          when String.equal pending.mutation_id activated.mutation_id
                               && pending.phase = Undoable ->
                          let request : Journal_graph_projection.delete_subtree =
                            { mutation_id = pending.mutation_id
                            ; block_id = pending.block_id
                            ; expected_revision = pending.expected_revision
                            }
                          in
                          ( { state with
                              pending_delete = Some { pending with phase = Committing }
                            ; timeline_notice = None
                            }
                          , send (Journal_graph_request.Delete_subtree request) )
                        | None | Some _ -> state, Bonsai.Effect.Ignore))
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
  let apply_manager_transition set_state set_state_and_effect manager_state =
    let manager = manager_state.Graph_service.snapshot in
    if Option.is_some manager.local_deletion
    then (
      Journal_graph_runtime.reset graph_runtime;
      Hashtbl.clear favorites_worker_requests;
      Hashtbl.clear admission_worker_requests;
      started_graph_generation := None);
    let update = set_state (fun state -> apply_manager_state state manager_state) in
    let sign_out =
      if (not manager.Graph_service.startup.authenticated) && !sign_out_in_flight
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
                show_sync_error
                  state
                  (Non_worker_sync_failure
                     "Unable to sign out of the authenticated session"))))
      else Bonsai.Effect.Ignore
    in
    let termination_ready =
      if
        !termination_in_flight
        && (manager.Graph_service.startup.awaiting_selection
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
      let snapshot = !state_ref in
      Bonsai.Effect.Many
        [ sign_out
        ; termination_ready
        ; trigger_admission
            set_state_and_effect
            ~graph_generation:snapshot.graph_state.generation
            ~graph_open:(snapshot.graph_state.phase = Graph_open)
        ])
  in
  let registered = ref false in
  let event_subscription =
    Bonsai.Cont.map3
      state
      set_state
      set_state_and_effect
      ~f:(fun snapshot set_state set_state_and_effect ->
        state_ref := snapshot;
        set_state_ref := Some set_state;
        if not !registered
        then (
          registered := true;
          ignore (Worker.send client Graph_service.Get_graph_state : Worker.send_result);
          Worker.on_event client (fun event ->
            match event with
            | Worker.Push { payload = Graph_service.Graph_push push; _ } ->
              let snapshot = !state_ref in
              let admission_refresh =
                trigger_admission
                  set_state_and_effect
                  ~graph_generation:snapshot.graph_state.generation
                  ~graph_open:(snapshot.graph_state.phase = Graph_open)
              in
              if not snapshot.graph_ready
              then admission_refresh
              else (
                let generation = snapshot.next_request_generation in
                let output =
                  Journal_graph_runtime.reconcile_push
                    graph_runtime
                    ~request_generation:generation
                    push
                in
                if output.requests = [] && output.responses = []
                then Bonsai.Effect.Ignore
                else (
                  let reloads_feed =
                    List.exists
                      (fun (request : Logseq_db_worker.Protocol.request) ->
                         match request.command with
                         | V2_list_journals _ -> true
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
                          { state with
                            feed_refresh =
                              Some
                                { generation
                                ; context
                                ; cause = Sync_refresh
                                ; graph_generation = current_graph_generation state
                                }
                          ; next_request_generation = Int64.succ generation
                          }
                        | None | Some _ -> state)
                    else Bonsai.Effect.Ignore
                  in
                  Bonsai.Effect.Many
                    [ admission_refresh
                    ; Bonsai.Effect.bind prepare ~f:(fun () ->
                        Bonsai.Effect.bind
                          (Bonsai.Effect.of_thunk (fun () -> deliver_output output))
                          ~f:(fun delivery ->
                            set_state (fun state ->
                              let state =
                                List.fold_left
                                  apply_worker_response
                                  state
                                  delivery.responses
                              in
                              match delivery.error with
                              | Some message -> fail_feed_transport state message
                              | None -> state)))
                    ]))
            | Worker.Response
                { request_id
                ; outcome = Worker.Completed (Graph_service.Graph_response response)
                ; _
                } ->
              Hashtbl.remove admission_worker_requests request_id;
              Hashtbl.remove favorites_worker_requests request_id;
              let output = Journal_graph_runtime.receive graph_runtime response in
              Bonsai.Effect.bind
                (Bonsai.Effect.of_thunk (fun () -> deliver_output output))
                ~f:(fun delivery ->
                  let update =
                    set_state_and_effect (fun state ->
                      let state, effects =
                        List.fold_left
                          (fun (state, effects) response ->
                             let completion =
                               match response.Journal_graph_runtime.payload with
                               | Admission_inspected { request; observation } ->
                                 Some (request, Admission_refresh.Inspected observation)
                               | Admission_unavailable request ->
                                 Some (request, Admission_refresh.Inspection_unavailable)
                               | _ -> None
                             in
                             match completion with
                             | None ->
                               Root_navigation.step state (Completed response), effects
                             | Some (request, result) ->
                               let admission_refresh, directive =
                                 Admission_refresh.complete
                                   state.admission_refresh
                                   ~request
                                   ~result
                               in
                               ( { state with admission_refresh }
                               , run_admission_directive set_state_and_effect directive
                                 :: effects ))
                          (state, [])
                          delivery.responses
                      in
                      let state =
                        match delivery.error with
                        | None -> state
                        | Some message when Option.is_some state.feed_refresh ->
                          fail_feed_transport state message
                        | Some message -> fail_graph_transport state message
                      in
                      state, Bonsai.Effect.Many (List.rev effects))
                  in
                  Bonsai.Effect.bind update ~f:(fun () ->
                    let refresh_after_worker_event =
                      let (Logseq_db_worker.Protocol.V2_response { outcome; _ }) =
                        response
                      in
                      match outcome with
                      | V2_mutation_committed _ ->
                        let snapshot = !state_ref in
                        trigger_admission
                          set_state_and_effect
                          ~graph_generation:snapshot.graph_state.generation
                          ~graph_open:(snapshot.graph_state.phase = Graph_open)
                      | _ -> Bonsai.Effect.Ignore
                    in
                    refresh_after_worker_event))
            | Worker.Response { outcome = Completed Client_command_completed; _ } ->
              Bonsai.Effect.Ignore
            | Worker.Response { outcome = Completed (Graph_state graph_state); _ }
            | Worker.Push { payload = Graph_state_changed graph_state; _ } ->
              observe_graph_state set_state set_state_and_effect graph_state
            | Worker.Push { payload = Client_state_changed manager_state; _ } ->
              apply_manager_transition set_state set_state_and_effect manager_state
            | Worker.Push { payload = Need_id_token challenge; _ } ->
              Bonsai.Effect.bind
                (Platform.request
                   application_platform
                   (Journal_platform.id_token_request challenge))
                ~f:(function
                  | Error _ -> send_manager (Graph_service.Reject_token challenge)
                  | Ok payload ->
                    let challenge_id = Graph_service.token_request_id challenge in
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
            | Worker.Response { request_id; outcome = Failed _ | Cancelled | Shutdown; _ }
              when Hashtbl.mem favorites_worker_requests request_id ->
              let request, protocol_request =
                Hashtbl.find favorites_worker_requests request_id
              in
              Journal_graph_runtime.abandon graph_runtime protocol_request;
              Hashtbl.remove favorites_worker_requests request_id;
              set_state (fun state ->
                favorites_event
                  state
                  (Failed (request, false, "Favorites read was interrupted. Try again.")))
            | Worker.Response { request_id; outcome = Failed _ | Cancelled | Shutdown; _ }
              when Hashtbl.mem admission_worker_requests request_id ->
              let request, protocol_request =
                Hashtbl.find admission_worker_requests request_id
              in
              Journal_graph_runtime.abandon graph_runtime protocol_request;
              Hashtbl.remove admission_worker_requests request_id;
              update_admission set_state_and_effect (fun state ->
                Admission_refresh.complete
                  state.admission_refresh
                  ~request
                  ~result:Inspection_unavailable)
            | Worker.Response { outcome = Failed error; _ } ->
              set_state (fun state ->
                let worker_error = service_error ~operation:"handleRequest" error in
                let state =
                  record_worker_error state ~operation:"handleRequest" worker_error
                in
                match state.feed_refresh with
                | Some _ ->
                  show_sync_error
                    { state with feed_refresh = None }
                    (Worker_sync_failure (latest_worker_error state))
                | None ->
                  fail_active_mutation
                    state
                    (Worker_capture_failure (latest_worker_error state)))
            | Worker.Response { outcome = Cancelled | Shutdown; _ } ->
              set_state (fun state ->
                match state.feed_refresh with
                | Some _ ->
                  show_sync_error
                    { state with feed_refresh = None }
                    (Non_worker_sync_failure "Worker unavailable")
                | None ->
                  fail_active_mutation state (Local_capture_failure "Worker unavailable"))
            | Worker.Terminal { error; _ } ->
              set_state (fun state ->
                let worker_error = service_error ~operation:"terminal" error in
                record_worker_error state ~operation:"terminal" worker_error
                |> fun state ->
                terminal_graph_state
                  state
                  (Worker_graph_error (latest_worker_error state))));
          ()))
  in
  let platform_registered = ref false in
  let platform_subscription =
    Bonsai.Cont.map set_state ~f:(fun set_state ->
      if not !platform_registered
      then (
        platform_registered := true;
        let install_calendar calendar =
          Journal_graph_runtime.set_calendar graph_runtime calendar;
          set_state (fun state ->
            match state.calendar with
            | Some current when not (Journal_calendar.is_newer ~than:current calendar) ->
              state
            | None | Some _ ->
              let graph_error =
                match state.graph_error with
                | Some (Calendar_startup_failure _) -> None
                | other -> other
              in
              { state with calendar = Some calendar; graph_error })
        in
        let sample_calendar () =
          Bonsai.Effect.of_thunk (fun () ->
            Journal_calendar.Sampler.sample calendar_sampler)
        in
        let apply_network_lifecycle payload =
          match Journal_platform.decode_network_lifecycle payload with
          | Error _ -> Bonsai.Effect.Ignore
          | Ok (Backgrounded _) -> send_manager (Graph_service.Set_foreground false)
          | Ok (Foreground_resumed _) ->
            Bonsai.Effect.bind (sample_calendar ()) ~f:(function
              | Error error ->
                Bonsai.Effect.Many
                  [ set_state (fun state ->
                      { state with graph_error = Some (Calendar_startup_failure error) })
                  ; send_manager (Graph_service.Set_foreground true)
                  ]
              | Ok calendar ->
                Bonsai.Effect.bind (install_calendar calendar) ~f:(fun () ->
                  send_manager (Graph_service.Set_foreground true)))
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
          then
            if local_deletion_active !state_ref
            then
              Bonsai.Effect.bind
                (Platform.request
                   application_platform
                   Journal_platform.termination_ready_request)
                ~f:(fun _ -> Bonsai.Effect.Ignore)
            else (
              termination_in_flight := true;
              send_manager Graph_service.Return_to_graph_picker)
          else (
            match Journal_platform.decode_network_lifecycle payload with
            | Ok _ -> apply_network_lifecycle payload
            | Error _ -> apply_authenticated_user payload)
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
        let calendar_startup =
          Bonsai.Effect.bind (sample_calendar ()) ~f:(function
            | Error error ->
              set_state (fun state ->
                { state with graph_error = Some (Calendar_startup_failure error) })
            | Ok calendar ->
              Bonsai.Effect.bind (install_calendar calendar) ~f:(fun () ->
                managed_startup))
        in
        Bonsai.Effect.Many
          [ calendar_startup
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
              let cause =
                match state.feed_refresh with
                | Some { cause = Sync_refresh; _ } -> Sync_refresh
                | None | Some _ -> Calendar_refresh
              in
              { state with
                feed_refresh =
                  Some
                    { generation
                    ; context
                    ; cause
                    ; graph_generation = current_graph_generation state
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
              set_state (fun state ->
                let state =
                  List.fold_left
                    (fun state response ->
                       Root_navigation.step state (Completed response))
                    state
                    delivery.responses
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
  let favorites_drain_key =
    Bonsai.Cont.map state ~f:(fun state -> state.favorites_requests)
  in
  let favorites_drain_callback =
    Bonsai.Cont.map set_state ~f:(fun set_state requests ->
      let deliver (request : Journal_graph_request.favorites_request) =
        if request.graph_generation <> !state_ref.graph_state.generation
        then Bonsai.Effect.Ignore
        else
          Bonsai.Effect.bind
            (Bonsai.Effect.of_thunk (fun () ->
               let output = submit (Journal_graph_request.Load_favorites request) in
               Journal_graph_transport.deliver
                 ~runtime:graph_runtime
                 ~send:(fun protocol_request ->
                   match
                     Worker.send client (Graph_service.Graph_request protocol_request)
                   with
                   | Accepted worker_request_id ->
                     Hashtbl.replace
                       favorites_worker_requests
                       worker_request_id
                       (request, protocol_request);
                     Journal_graph_transport.Accepted
                   | Full -> Full
                   | Not_ready -> Not_ready
                   | Stopping -> Stopping)
                 output))
            ~f:(fun delivery ->
              set_state (fun state ->
                let state =
                  List.fold_left
                    (fun state response ->
                       Root_navigation.step state (Completed response))
                    state
                    delivery.responses
                in
                match delivery.error with
                | None -> state
                | Some message -> favorites_event state (Failed (request, false, message))))
      in
      Bonsai.Effect.bind
        (set_state (fun state ->
           { state with
             favorites_requests =
               List.filter
                 (fun request -> not (List.mem request requests))
                 state.favorites_requests
           }))
        ~f:(fun () -> Bonsai.Effect.Many (List.map deliver requests)))
  in
  Bonsai.Cont.Edge.on_change
    ~equal:( = )
    favorites_drain_key
    ~callback:favorites_drain_callback
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
        Bonsai.Effect.bind
          (set_state (fun state ->
             if
               Int64.equal state.next_request_generation generation
               && Journal_timeline_state.next_request state.timeline = Some request
             then
               { state with
                 timeline =
                   Journal_timeline_state.begin_request state.timeline ~generation request
               ; next_request_generation = Int64.succ generation
               }
             else state))
          ~f:(fun () ->
            Bonsai.Effect.bind
              (Bonsai.Effect.of_thunk (fun () -> deliver_output output))
              ~f:(fun delivery ->
                set_state (fun state ->
                  let state = apply_delivery_responses state delivery in
                  match delivery.error, request with
                  | Some message, Journal_timeline_state.Day { day; _ } ->
                    { state with
                      timeline =
                        Journal_timeline_state.fail_day_request
                          state.timeline
                          ~generation
                          ~day
                          ~stale_cursor:false
                          ~message
                    }
                  | _ -> state))))
  in
  Bonsai.Cont.Edge.on_change
    ~equal:
      (Option.equal
         (fun (left_generation, left_request) (right_generation, right_request) ->
            Int64.equal left_generation right_generation && left_request = right_request))
    timeline_drain_key
    ~callback:timeline_drain_callback
    graph;
  let environment =
    Driver.Handler.environment handlers |> Bonsai_flutter.Environment.value
  in
  let current_time = Bonsai.Cont.Clock.get_current_time graph in
  let sync_error_timer_key =
    Bonsai.Cont.map state ~f:(fun state ->
      Option.map (fun notice -> notice.sequence) state.sync_error)
  in
  let sync_error_timer_callback =
    let until = Bonsai.Cont.Clock.until graph in
    Bonsai.Cont.map3
      set_state
      current_time
      until
      ~f:(fun set_state current_time until -> function
      | None -> Bonsai.Effect.Ignore
      | Some scheduled_sequence ->
        let hide =
          Bonsai.Effect.bind current_time ~f:(fun now ->
            Bonsai.Effect.bind
              (until (Core.Time_ns.add now sync_error_card_lifetime))
              ~f:(fun () ->
                set_state (fun state ->
                  match state.sync_error with
                  | Some { sequence = current_sequence; _ }
                    when Int64.equal current_sequence scheduled_sequence ->
                    { state with sync_error = None }
                  | None | Some _ -> state)))
        in
        Bonsai.Effect.of_thunk (fun () -> Bonsai.Effect.Expert.handle hide))
  in
  Bonsai.Cont.Edge.on_change
    ~equal:(Option.equal Int64.equal)
    sync_error_timer_key
    ~callback:sync_error_timer_callback
    graph;
  let dependencies =
    Bonsai.Cont.map5
      state
      set_state
      set_state_and_effect
      environment
      current_time
      ~f:(fun state set_state set_state_and_effect environment current_time ->
        state, set_state, set_state_and_effect, environment, current_time)
  in
  let dispatch =
    Driver.Handler.create
      handlers
      ~name:"journal-dispatch"
      ~equal:
        (fun
          (left, left_set, left_effect, left_environment, left_time)
          (right, right_set, right_effect, right_environment, right_time) ->
        left = right
        && left_set == right_set
        && left_effect == right_effect
        && left_environment = right_environment
        && left_time == right_time)
      dependencies
      ~f:
        (fun
          (snapshot, set_state, set_state_and_effect, environment, current_time)
          payload ->
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
            , snapshot.pending_status
            , snapshot.calendar )
          with
          | false, _, _, _
          | true, Some _, _, _
          | true, None, Some _, _
          | true, None, None, None -> Bonsai.Effect.Ignore
          | true, None, None, Some _ ->
            let capture =
              match snapshot.direct_capture with
              | None ->
                Journal_capture.create
                  ~session_number:snapshot.next_local_sequence
                  ~source
              | Some capture -> Journal_capture.update_source capture ~source
            in
            (match Journal_capture.phase capture with
             | Saving -> Bonsai.Effect.Ignore
             | Failed _ ->
               let capture, request = Journal_capture.retry capture in
               (match request with
                | None -> Bonsai.Effect.Ignore
                | Some request ->
                  with_direct_request
                    (Root_navigation.step snapshot (Capture_admitted capture))
                    request)
             | Editing ->
               if String.equal (String.trim source) ""
               then Bonsai.Effect.Ignore
               else (
                 match Journal_calendar.Sampler.sample calendar_sampler with
                 | Error error ->
                   update (fun state ->
                     { state with
                       capture_error =
                         Some
                           (Local_capture_failure (Journal_calendar.error_message error))
                     })
                 | Ok calendar ->
                   Journal_graph_runtime.set_calendar graph_runtime calendar;
                   let creation_time =
                     Journal_time.of_calendar calendar |> Result.get_ok
                   in
                   let number = snapshot.next_local_sequence in
                   let admission =
                     with_block_identity
                       ~creation_time
                       ~f:(fun block_id ->
                         Journal_capture.admit_save
                           capture
                           ~mutation_id:(fresh_identity ())
                           ~block_id:(Logseq_db_types.Graph_types.Uuid.to_string block_id)
                           ~sibling_order:(sibling_order number)
                           ~calendar_generation:(Journal_calendar.generation calendar)
                           ~creation_time)
                       ()
                   in
                   (match admission with
                    | Error message ->
                      update (fun state ->
                        { state with
                          direct_capture = Some capture
                        ; capture_error = Some (Local_capture_failure message)
                        })
                    | Ok (_, None) -> Bonsai.Effect.Ignore
                    | Ok (capture, Some request) ->
                      with_direct_request
                        (Root_navigation.step
                           { snapshot with
                             calendar = Some calendar
                           ; next_local_sequence = Int64.succ number
                           }
                           (Capture_admitted capture))
                        request)))
        in
        match payload with
        | payload
          when local_deletion_active snapshot
               &&
               match payload with
               | Ui.Event.Payload.Text ("open-diagnostics" | "close-diagnostics")
               | Ui.Event.Payload.Route_pop _ -> false
               | _ -> true -> Bonsai.Effect.Ignore
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
        | Ui.Event.Payload.Text "select-journals" ->
          update (fun state ->
            Root_navigation.step state (Select Journal_routes.Journals))
        | Ui.Event.Payload.Text "select-favorites" ->
          update (fun state ->
            Root_navigation.step state (Select Journal_routes.Favorites))
        | Ui.Event.Payload.Text "favorites-retry" ->
          update (fun state -> favorites_event state Retry)
        | Ui.Event.Payload.Int64_pair { first = first_index; second = last_exclusive }
          when Journal_routes.destination snapshot.routes = Journal_routes.Favorites ->
          update (fun state ->
            favorites_event
              state
              (Visible
                 { first_index = Int64.to_int first_index
                 ; last_exclusive = Int64.to_int last_exclusive
                 }))
        | Ui.Event.Payload.Visible_range _
          when Journal_routes.destination snapshot.routes = Journal_routes.Favorites ->
          Bonsai.Effect.Ignore
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
        | Ui.Event.Payload.Scroll _ -> Bonsai.Effect.Ignore
        | Ui.Event.Payload.Native_event _ as payload
          when Option.is_some (Root_scroll.event_of_payload payload) ->
          update (fun state ->
            Root_navigation.step state (Option.get (Root_scroll.event_of_payload payload)))
        | Ui.Event.Payload.Native_event _ as payload ->
          (match
             Ui.Native_widget.Expandable_message_composer.event_of_payload payload
           with
           | Some (Text_changed text) ->
             update (fun state -> Root_navigation.step state (Capture_edited text))
           | Some (Button_pressed { button_id = 1; text }) -> admit_direct_capture text
           | Some (Button_pressed { button_id = 2; text }) ->
             (match
                snapshot.write_enabled, snapshot.pending_delete, snapshot.pending_status
              with
              | true, None, None ->
                update (fun state ->
                  let capture =
                    match state.direct_capture with
                    | None ->
                      Journal_capture.create
                        ~session_number:state.next_local_sequence
                        ~source:text
                    | Some capture -> Journal_capture.update_source capture ~source:text
                  in
                  { state with
                    direct_capture = Some (Journal_capture.toggle_task_intent capture)
                  ; capture_error = None
                  })
              | false, _, _ | true, Some _, _ | true, None, Some _ -> Bonsai.Effect.Ignore)
           | Some (Button_pressed _) -> Bonsai.Effect.Ignore
           | None -> Bonsai.Effect.Ignore)
        | Ui.Event.Payload.Route_pop { page_key; _ } ->
          update (fun state ->
            match state.modal with
            | Status_sheet block_id ->
              let expected =
                ID.Navigation.Page_key.of_string ("journal-status-sheet:" ^ block_id)
              in
              if ID.Navigation.Page_key.equal page_key expected
              then { state with modal = No_modal }
              else state
            | Error_info -> { state with modal = No_modal }
            | No_modal | Account | Settings | Diagnostics | Cache_reset_confirmation _ ->
              back_state state)
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
          else if String.equal action "open-diagnostics"
          then
            set_state_and_effect (fun state ->
              let admission_refresh, directive =
                Admission_refresh.open_
                  state.admission_refresh
                  ~graph_generation:state.graph_state.generation
                  ~graph_open:(state.graph_state.phase = Graph_open)
              in
              ( { state with modal = Diagnostics; admission_refresh }
              , run_admission_directive set_state_and_effect directive ))
          else if String.equal action "close-diagnostics"
          then
            update (fun state ->
              { state with
                modal = No_modal
              ; admission_refresh = Admission_refresh.close state.admission_refresh
              })
          else if String.equal action "open-error-info"
          then
            update (fun state ->
              if state.worker_errors = []
              then state
              else { state with modal = Error_info })
          else if String.equal action "close-error-info"
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
              | Some { selected_graph = Some graph_id; _ }
                when local_deletion_available state ->
                { state with modal = Cache_reset_confirmation graph_id }
              | None | Some _ -> state)
          else if String.equal action "cancel-local-cache-reset"
          then update (fun state -> { state with modal = No_modal })
          else if String.equal action "confirm-local-cache-reset"
          then (
            match snapshot.modal with
            | No_modal | Status_sheet _ | Account | Settings | Diagnostics | Error_info ->
              Bonsai.Effect.Ignore
            | Cache_reset_confirmation graph_id ->
              if not (local_deletion_available snapshot)
              then Bonsai.Effect.Ignore
              else
                Bonsai.Effect.bind (update discard_local_graph_state) ~f:(fun () ->
                  send_manager (Graph_service.Delete_local_cache graph_id)))
          else if String.equal action "delete-undo"
          then
            update (fun state ->
              match state.pending_delete with
              | Some { phase = Undoable; staged; _ } ->
                { state with
                  timeline = Journal_timeline_state.undo_delete state.timeline staged
                ; pending_delete = None
                ; timeline_notice = None
                }
              | None | Some { phase = Committing; _ } -> state)
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
          else if String.starts_with ~prefix:"timeline-retry:" action
          then (
            match
              int_of_string_opt (String.sub action 15 (String.length action - 15))
            with
            | None -> Bonsai.Effect.Ignore
            | Some day ->
              update (fun state ->
                { state with
                  timeline = Journal_timeline_state.retry_day state.timeline ~day
                }))
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
            | Some detail, Some _ ->
              (match Journal_calendar.Sampler.sample calendar_sampler with
               | Error error ->
                 update (fun state ->
                   { state with
                     capture_error =
                       Some (Local_capture_failure (Journal_calendar.error_message error))
                   })
               | Ok calendar ->
                 Journal_graph_runtime.set_calendar graph_runtime calendar;
                 let creation_time = Journal_time.of_calendar calendar |> Result.get_ok in
                 let number = snapshot.next_local_sequence in
                 let admission =
                   with_block_identity
                     ~creation_time
                     ~f:(fun block_id ->
                       Journal_detail.admit_child
                         detail
                         ~mutation_id:(fresh_identity ())
                         ~calendar_generation:(Journal_calendar.generation calendar)
                         ~block_id:(Logseq_db_types.Graph_types.Uuid.to_string block_id)
                         ~sibling_order:(sibling_order number)
                         ~creation_time)
                     ()
                 in
                 (match admission with
                  | Error message ->
                    update (fun state ->
                      { state with capture_error = Some (Local_capture_failure message) })
                  | Ok (_, None) -> Bonsai.Effect.Ignore
                  | Ok (detail, Some request) ->
                    with_request
                      { snapshot with
                        calendar = Some calendar
                      ; routes = Journal_routes.update_detail snapshot.routes detail
                      ; capture_error = None
                      ; next_local_sequence = Int64.succ number
                      }
                      request))
            | None, _ | _, None -> Bonsai.Effect.Ignore)
          else if String.length action > 16 && String.sub action 0 16 = "timeline-status:"
          then (
            let block_id = String.sub action 16 (String.length action - 16) in
            match
              ( snapshot.write_enabled
              , snapshot.pending_delete
              , snapshot.pending_status
              , block_in_timeline snapshot.timeline block_id )
            with
            | true, None, None, Some _ ->
              update (fun state -> { state with modal = Status_sheet block_id })
            | false, _, _, _
            | true, Some _, _, _
            | true, None, Some _, _
            | true, None, None, None -> Bonsai.Effect.Ignore)
          else if
            String.length action > 20 && String.sub action 0 20 = "status-sheet-select:"
          then (
            let tag = String.sub action 20 (String.length action - 20) in
            let task_state = List.assoc_opt tag status_sheet_options in
            match
              ( snapshot.modal
              , snapshot.write_enabled
              , snapshot.pending_delete
              , snapshot.pending_status
              , task_state )
            with
            | Status_sheet block_id, true, None, None, Some task_state ->
              (match block_in_timeline snapshot.timeline block_id with
               | None -> update (fun state -> { state with modal = No_modal })
               | Some block when Journal_model.task_state block = task_state ->
                 Bonsai.Effect.Ignore
               | Some block ->
                 let pending_status =
                   { mutation_id = fresh_identity ()
                   ; block_id
                   ; expected_revision = Journal_model.revision block
                   ; task_state
                   }
                 in
                 let request =
                   Journal_graph_request.Set_task_state
                     { mutation_id = pending_status.mutation_id
                     ; block_id
                     ; expected_revision = pending_status.expected_revision
                     ; task_state
                     }
                 in
                 with_request
                   { snapshot with
                     modal = No_modal
                   ; pending_status = Some pending_status
                   ; timeline_notice = None
                   }
                   request)
            | No_modal, _, _, _, _
            | Account, _, _, _, _
            | Settings, _, _, _, _
            | Diagnostics, _, _, _, _
            | Error_info, _, _, _, _
            | Cache_reset_confirmation _, _, _, _, _
            | Status_sheet _, false, _, _, _
            | Status_sheet _, true, Some _, _, _
            | Status_sheet _, true, None, Some _, _
            | Status_sheet _, true, None, None, None -> Bonsai.Effect.Ignore)
          else if String.length action > 16 && String.sub action 0 16 = "timeline-delete:"
          then (
            let block_id = String.sub action 16 (String.length action - 16) in
            match
              ( snapshot.write_enabled
              , snapshot.pending_delete
              , snapshot.pending_status
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
        | Int64_bool _
        | Int64_list _
        | Int64_pair _
        | Float _
        | Float_range _
        | Civil_date _
        | Civil_time _
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
            | Some failure, _ -> capture_failure_message failure, None, 4_000
            | None, Some Delete_undo ->
              ( "Block and descendants removed"
              , Some "Undo"
              , if accessible_navigation then 10_000 else 5_000 )
            | None, Some Delete_failed -> "Delete failed. Block restored.", None, 4_000
            | None, Some (Status_failed message) ->
              "Unable to change status: " ^ message, None, 4_000
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
    let tokens =
      Journal_visual_tokens.resolve
        ~brightness:environment.brightness
        ~high_contrast:environment.high_contrast
    in
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
    let capture_task_selected =
      match state.direct_capture with
      | Some capture -> Journal_capture.task_state capture = Journal_model.Todo
      | None -> false
    in
    let row_actions_enabled =
      state.write_enabled
      && Option.is_none state.pending_delete
      && Option.is_none state.pending_status
    in
    let sync_error =
      Option.map (fun notice -> sync_failure_message notice.failure) state.sync_error
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
          ~graph_generation:state.graph_state.generation
          ~destination:(Journal_routes.destination state.routes)
          ~favorites:state.favorites
          ~on_select_destination:
            (Ui.Event.Handler.create ~name:"select-root-destination" (function
               | Ui.Event.Payload.Int64 0L ->
                 Ui.Event.Handler.Private.invoke dispatch (Text "select-journals")
               | Int64 1L ->
                 Ui.Event.Handler.Private.invoke dispatch (Text "select-favorites")
               | _ -> ()))
          ~on_favorites_visible_range:
            (Ui.Event.Handler.create ~name:"favorites-visible-range" (function
               | Ui.Event.Payload.Visible_range range ->
                 Ui.Event.Handler.Private.invoke
                   dispatch
                   (Int64_pair
                      { first = range.first_index; second = range.last_exclusive })
               | _ -> ()))
          ~on_favorites_retry:(bind_action dispatch "favorites-retry")
          ~viewport_width:environment.viewport_width
          ~tokens
          ~typography
          ~profile
          ~text_scale:environment.text_scale
          ~top_inset:environment.safe_area.top
          ~bottom_inset:environment.safe_area.bottom
          ~device_pixel_ratio:environment.device_pixel_ratio
          ~timeline_state:state.timeline
          ~loading:(not state.feed_loaded)
          ~graph_error:(Option.map graph_error_message state.graph_error)
          ~sync_error
          ~sync_phase:
            (Option.map
               (fun (manager : Graph_service.snapshot) -> manager.sync_phase)
               state.manager)
          ~today_date:(today_presentation state)
          ~day_presentation:(presentation_for_day state)
          ~reduced_motion
          ~rtl:(is_rtl_locale environment.locale)
          ~content_horizontal_inset
          ~capture_enabled:
            (state.write_enabled
             && Option.is_none state.pending_delete
             && Option.is_none state.pending_status
             && not capture_saving)
          ~capture_save_enabled:
            (state.write_enabled
             && Option.is_none state.pending_delete
             && Option.is_none state.pending_status
             && not capture_saving)
          ~capture_saving
          ~capture_task_selected
          ~capture_affordance_key:state.capture_affordance_key
          ~capture_fab_presentation:
            (Journal_timeline_state.Root_scroll_trigger.presentation
               state.journals_scroll)
          ~navigation_visible:(Root_navigation.navigation_visible state)
          ~root_active:state.root_active
          ~on_capture_event:dispatch
          ~on_scroll:dispatch
          ~on_visible_range:dispatch
          ~on_retry_day:(prefix_action dispatch "timeline-retry:")
          ~on_toggle_children:(prefix_action dispatch "timeline-toggle-children:")
          ~delete_enabled:state.write_enabled
          ~actions_enabled:row_actions_enabled
          ~on_status:(prefix_action dispatch "timeline-status:")
          ~on_delete:(prefix_action dispatch "timeline-delete:")
          ~error_info_available:(state.worker_errors <> [])
          ~on_error_info:(bind_action dispatch "open-error-info")
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
      | Status_sheet block_id ->
        (match block_in_timeline state.timeline block_id with
         | None -> pages
         | Some block ->
           pages
           @ [ status_sheet_page
                 ~tokens
                 ~typography
                 ~text_scale:environment.text_scale
                 ~viewport_height:environment.viewport_height
                 ~bottom_inset:environment.safe_area.bottom
                 ~reduced_motion
                 ~block
                 dispatch
             ])
      | Cache_reset_confirmation _ ->
        pages
        @ [ local_cache_reset_dialog_page ~tokens ~typography ~reduced_motion dispatch ]
      | Account ->
        let cache_reset_available = local_deletion_available state in
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
      | Diagnostics ->
        pages
        @ [ diagnostics_page
              ~tokens
              ~typography
              ~reduced_motion
              ~snapshot:state.manager
              ~graph:state.graph_state
              ~admission:(Admission_refresh.observation state.admission_refresh)
              state.diagnostics
              dispatch
          ]
      | Error_info ->
        pages
        @ [ error_info_page ~typography (newest_first_worker_errors state) dispatch ]
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
    let (Managed_sync { base_url }) = startup.Logseq_db_worker.Config.target in
    managed_sync_startup := true;
    managed_sync_origin := base_url;
    Ok startup
  | Error error -> Error (Journal_startup.Error.to_string error)
;;

let create ?(calendar_sampler = fun () -> Journal_calendar.Sampler.create ()) ~service () =
  App.create_with_worker
    ~name:"Logseq Journal"
    ~decode_config
    ~service
    (fun client handlers graph ->
       component ~calendar_sampler:(calendar_sampler ()) client handlers graph)
;;

module For_testing = struct
  let read_block_entropy = read_block_entropy
  let with_block_identity = with_block_identity

  let favorites_page ~width ~scale ~dark ~high_contrast ~rtl ~reduced_motion items =
    let profile =
      Journal_visual_tokens.select_row_profile
        ~preset:Balanced
        ~viewport_width:width
        ~text_scale:scale
    in
    let tokens =
      Journal_visual_tokens.resolve
        ~brightness:(if dark then Dark else Light)
        ~high_contrast
    in
    let typography = Journal_visual_tokens.typography Balanced in
    let favorites, requests =
      Journal_routes.Favorites.step
        (Journal_routes.Favorites.create ~graph_generation:1)
        (Select true)
    in
    let favorites, _ =
      Journal_routes.Favorites.step
        favorites
        (Loaded
           ( List.hd requests
           , { favorites_page = None
             ; generation = "fixture"
             ; projection_revision = "fixture"
             ; items
             ; next_cursor = None
             } ))
    in
    let handler = Ui.Event.Handler.create ~name:"root-visual-fixture" (fun _ -> ()) in
    timeline_page
      ~graph_generation:1
      ~destination:Journal_routes.Favorites
      ~favorites
      ~on_select_destination:handler
      ~on_favorites_visible_range:handler
      ~on_favorites_retry:handler
      ~viewport_width:width
      ~tokens
      ~typography
      ~profile
      ~text_scale:scale
      ~top_inset:47.
      ~bottom_inset:34.
      ~device_pixel_ratio:1.
      ~timeline_state:(Journal_timeline_state.empty ~today:20260908)
      ~loading:false
      ~graph_error:None
      ~sync_error:None
      ~sync_phase:(Some Graph_service.Connecting)
      ~today_date:None
      ~day_presentation:(fun _ -> None)
      ~reduced_motion
      ~rtl
      ~content_horizontal_inset:
        (Float.max 0. ((width -. Journal_visual_tokens.timeline_max_width) /. 2.))
      ~capture_enabled:false
      ~capture_save_enabled:false
      ~capture_saving:false
      ~capture_task_selected:false
      ~capture_affordance_key:1L
      ~capture_fab_presentation:Journal_timeline_state.Extended
      ~navigation_visible:true
      ~root_active:true
      ~on_capture_event:handler
      ~on_scroll:handler
      ~on_visible_range:handler
      ~on_retry_day:handler
      ~on_toggle_children:handler
      ~delete_enabled:false
      ~actions_enabled:false
      ~on_status:handler
      ~on_delete:handler
      ~error_info_available:true
      ~on_error_info:handler
      ~account_menu_available:true
      ~on_account_menu:handler
    |> fun page -> Ui.Widget.navigator ~on_pop:handler [ page ]
  ;;

  let app_with_service ?calendar_sampler service =
    let calendar_sampler = Option.map (fun sampler () -> sampler) calendar_sampler in
    create ?calendar_sampler ~service ()
  ;;
end

let app = create ~service:Graph_service.service ()
