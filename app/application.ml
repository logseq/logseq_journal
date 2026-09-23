module ID = Journal_ids
module Ui = Journal_view
module V = Ui.View
module Graph_service = Logseq_db_worker_lui.Logseq_db_worker_lui_service
module Worker = Logseq_db_worker_lui.Journal_worker
module Journal_worker_runtime = Logseq_db_worker_lui.Journal_worker_runtime
module Journal_worker_ids = Logseq_db_worker_lui.Journal_worker_ids

(* Shim replacing [Bonsai.Effect]: an effect is just a thunk scheduled by
   the reducer plumbing. Effects run inline on the app thread. *)
module Effect = struct
  type 'a t = unit -> 'a

  let ignore : unit t = fun () -> ()
  let of_thunk f = f
  let bind (t : 'a t) ~f : 'b t = fun () -> f (t ()) ()
  let many (ts : unit t list) : unit t = fun () -> List.iter (fun t -> t ()) ts
  let run (t : unit t) = t ()
end

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
  ; staged : Journal_timeline_state.staged_delete option
  ; detail_staged : (int64 * Journal_detail.staged_delete) option
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
  | Delete_failed of string
  | Status_failed of string

let operation_failure = function
  | Some (Delete_failed message) ->
    Some
      ( "Delete failed"
      , message
      , "The block has been restored. Review it before trying Delete again." )
  | Some (Status_failed message) ->
    Some
      ( "Status not changed"
      , message
      , "The block keeps its current status. Open its Status menu to try again." )
  | None | Some Delete_undo -> None
;;

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
  | Capture_sheet
  | Append_sheet
  | Status_sheet of string
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

module Graph_drafts = Map.Make (String)
module Media_views = Map.Make (String)

type graph_drafts =
  { capture_draft : Journal_capture.t option
  ; append_drafts : Journal_routes.retained_drafts
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
  ; draft_graph : Graph_service.graph_id option
  ; graph_drafts : graph_drafts Graph_drafts.t
  ; asset_offline : (Journal_asset_policy.offline * Journal_asset_policy.offline) option
  ; uploads : Journal_uploads.t
  ; asset_settings_open : bool
  ; media_views : Journal_media_runtime.view Media_views.t
  ; import_completion : (string * string option) option
  ; pending_replace : string option
  ; replace_request : int
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
  ; modal : modal
  ; confirmation_sequence : int64
  ; environment : Journal_environment.snapshot
  }

let favorites_event state event =
  let favorites, requests = Journal_routes.Favorites.step state.favorites event in
  { state with favorites; favorites_requests = state.favorites_requests @ requests }
;;

let select_destination state destination =
  if Journal_routes.destination state.routes = destination
  then state
  else
    { state with routes = Journal_routes.select_destination state.routes destination }
    |> fun state ->
    favorites_event state (Select (destination = Journal_routes.Favorites))
;;

let feed_day_limit = 7
let sync_error_card_lifetime = Core.Time_ns.Span.of_sec 5.

let initial_state =
  { favorites = Journal_routes.Favorites.create ~graph_generation:(-1)
  ; favorites_requests = []
  ; routes = Journal_routes.create ()
  ; timeline = Journal_timeline_state.empty ~today:0
  ; next_request_generation = 1L
  ; next_local_sequence = 1L
  ; calendar = None
  ; pending_delete = None
  ; pending_status = None
  ; direct_capture = None
  ; draft_graph = None
  ; graph_drafts = Graph_drafts.empty
  ; asset_offline = None
  ; uploads = Journal_uploads.empty
  ; asset_settings_open = false
  ; media_views = Media_views.empty
  ; import_completion = None
  ; pending_replace = None
  ; replace_request = 0
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
  ; modal = No_modal
  ; confirmation_sequence = 0L
  ; environment = Journal_environment.fallback
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

let track_capture_session state =
  match state.direct_capture with
  | None -> state
  | Some capture ->
    let next =
      ID.Text_input.Session_id.to_int64 (Journal_capture.session_id capture) |> Int64.succ
    in
    { state with next_local_sequence = Int64.max state.next_local_sequence next }
;;

let clear_graph_surface state =
  { state with
    favorites =
      Journal_routes.Favorites.create ~graph_generation:state.graph_state.generation
  ; favorites_requests = []
  ; routes = Journal_routes.create ()
  ; timeline = Journal_timeline_state.empty ~today:0
  ; feed_loaded = false
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

let discard_local_graph_state state =
  let graph_drafts =
    match state.draft_graph with
    | None -> state.graph_drafts
    | Some id ->
      Graph_drafts.remove
        (Logseq_db_types.Graph_types.Uuid.to_string id)
        state.graph_drafts
  in
  { (clear_graph_surface state) with draft_graph = None; graph_drafts }
;;

let clear_account_drafts state =
  { (clear_graph_surface state) with
    draft_graph = None
  ; graph_drafts = Graph_drafts.empty
  }
;;

let switch_draft_graph state graph_id =
  let graph_drafts =
    match state.draft_graph with
    | None -> state.graph_drafts
    | Some id ->
      let capture_draft =
        Option.map
          (fun capture ->
             match Journal_capture.phase capture with
             | Saving ->
               Journal_capture.fail
                 capture
                 ~message:"Save was interrupted. Retry to confirm the original attempt."
             | Editing | Failed _ -> capture)
          state.direct_capture
      in
      Graph_drafts.add
        (Logseq_db_types.Graph_types.Uuid.to_string id)
        { capture_draft
        ; append_drafts = Journal_routes.retain_drafts ~interrupted:true state.routes
        }
        state.graph_drafts
  in
  let state = clear_graph_surface state in
  let retained =
    Option.bind graph_id (fun id ->
      Graph_drafts.find_opt (Logseq_db_types.Graph_types.Uuid.to_string id) graph_drafts)
  in
  let graph_drafts =
    match graph_id with
    | None -> graph_drafts
    | Some id ->
      Graph_drafts.remove (Logseq_db_types.Graph_types.Uuid.to_string id) graph_drafts
  in
  let direct_capture, routes =
    match retained with
    | None -> None, state.routes
    | Some retained ->
      ( Option.map
          (fun capture ->
             Journal_capture.rebind capture ~session_number:state.next_local_sequence)
          retained.capture_draft
      , Journal_routes.restore_drafts state.routes retained.append_drafts )
  in
  { state with draft_graph = graph_id; graph_drafts; direct_capture; routes }
  |> track_capture_session
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
    match state.manager with
    | Some previous
      when previous.startup.account_generation <> snapshot.startup.account_generation ->
      clear_account_drafts state
    | None | Some _ -> state
  in
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
  let state =
    if graph_context_changed
    then switch_draft_graph state snapshot.selected_graph
    else state
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
    | (Status_sheet _ | Capture_sheet | Append_sheet), _ when graph_context_changed ->
      No_modal
    | Cache_reset_confirmation confirmation, Some selected
      when Logseq_db_types.Graph_types.Uuid.equal confirmation selected -> state.modal
    | ( ( No_modal
        | Capture_sheet
        | Append_sheet
        | Status_sheet _
        | Diagnostics
        | Error_info )
      , _ ) -> state.modal
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
;;

let block_in_timeline timeline block_id =
  Journal_timeline_state.find_block timeline ~block_id
;;

let open_detail_state state detail request_generation =
  let routes =
    Journal_routes.apply_detail_response state.routes ~request_generation detail
  in
  { state with routes }
;;

let capture_failure_message = function
  | Worker_capture_failure occurrence -> Logseq_db_worker.Error.message occurrence.error
  | Local_capture_failure message -> message
;;

let restore_deleted state (pending : pending_delete) =
  let timeline =
    Option.fold
      ~none:state.timeline
      ~some:(Journal_timeline_state.undo_delete state.timeline)
      pending.staged
  in
  let routes =
    match pending.detail_staged, Journal_routes.detail state.routes with
    | Some (session, staged), Some detail
      when session = Journal_routes.detail_request_generation state.routes ->
      Journal_routes.update_detail state.routes (Journal_detail.undo_delete detail staged)
    | _ -> state.routes
  in
  favorites_event { state with timeline; routes } (Reveal_target pending.block_id)
;;

let hide_deleted state (pending : pending_delete) =
  let timeline, staged =
    match
      Journal_timeline_state.stage_delete state.timeline ~block_id:pending.block_id
    with
    | None -> state.timeline, pending.staged
    | Some (timeline, staged) -> timeline, Some staged
  in
  let routes, detail_staged =
    match Journal_routes.detail state.routes with
    | None -> state.routes, pending.detail_staged
    | Some detail ->
      (match Journal_detail.stage_delete detail ~block_id:pending.block_id with
       | None -> state.routes, pending.detail_staged
       | Some (hidden, staged) ->
         let routes =
           if Journal_model.id (Journal_detail.root detail) = pending.block_id
           then Journal_routes.back state.routes
           else Journal_routes.update_detail state.routes hidden
         in
         routes, Some (Journal_routes.detail_request_generation state.routes, staged))
  in
  favorites_event
    { state with
      timeline
    ; routes
    ; pending_delete = Some { pending with staged; detail_staged }
    }
    (Hide_target pending.block_id)
;;

let fail_active_mutation state failure =
  let message = capture_failure_message failure in
  match state.pending_delete with
  | Some pending_delete ->
    { (restore_deleted state pending_delete) with
      pending_delete = None
    ; timeline_notice = Some (Delete_failed message)
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

let back_state state =
  let detail_root = Option.map Journal_detail.root (Journal_routes.detail state.routes) in
  let routes = Journal_routes.back state.routes in
  let timeline =
    match detail_root, Journal_routes.route routes with
    | Some root, Journal_routes.Timeline when Journal_model.journal_day_opt root <> None
      -> Journal_timeline_state.replace_block state.timeline root
    | _ -> state.timeline
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
  | Feed_refresh_started { request_generation } ->
    (match state.calendar, state.feed_refresh with
     | _, Some refresh when Int64.compare refresh.generation request_generation > 0 ->
       state
     | Some calendar, _ when state.graph_ready ->
       { state with
         feed_refresh =
           Some
             { generation = request_generation
             ; context = feed_projection_context calendar
             ; cause = Sync_refresh
             ; graph_generation = current_graph_generation state
             }
       ; next_request_generation =
           Int64.max state.next_request_generation (Int64.succ request_generation)
       }
     | None, _ | Some _, _ -> state)
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
             Journal_timeline_state.reset state.timeline ~today
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
         | Some (_, Feed { before_day = Some _ }) | Some (_, Day _) | None -> false
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
    (match Journal_routes.detail state.routes with
     | None -> state
     | Some current ->
       let current, _ =
         Journal_detail.step current (Loaded (request_generation, detail))
       in
       { state with routes = Journal_routes.update_detail state.routes current })
  | Detail_failed { request_generation; block_id; missing; stale_cursor; failure } ->
    if
      Journal_routes.detail_request_generation state.routes = request_generation
      && Journal_routes.detail_block_id state.routes = Some block_id
      && Journal_routes.route state.routes = Journal_routes.Detail_loading
    then
      { state with
        routes =
          Journal_routes.apply_detail_failure
            state.routes
            ~request_generation
            ~missing
            ~message:(failure_source_message failure)
      }
    else (
      match Journal_routes.detail state.routes with
      | None -> state
      | Some detail ->
        let detail, _ =
          Journal_detail.step
            detail
            (Load_failed (request_generation, stale_cursor, failure_source_message failure))
        in
        { state with routes = Journal_routes.update_detail state.routes detail })
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
        | Some (_, Feed { before_day = None })
        | None -> state))
  | Block_captured { block; timeline_entry_update } ->
    let completed =
      Option.fold
        ~none:false
        ~some:(fun capture -> Journal_capture.completed_by capture block)
        state.direct_capture
    in
    { state with
      direct_capture = (if completed then None else state.direct_capture)
    ; modal = (if completed && state.modal = Capture_sheet then No_modal else state.modal)
    ; capture_error = (if completed then None else state.capture_error)
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
          (Journal_detail.apply_block detail block)
    in
    { state with
      routes
    ; pending_status
    ; timeline_notice
    ; timeline =
        Option.fold
          ~none:
            (if Journal_model.journal_day_opt block = None
             then state.timeline
             else Journal_timeline_state.replace_block state.timeline block)
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
    { state with routes }
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
                (Journal_detail.apply_block detail latest)
          }))
  | Child_failed { block_id; failure } ->
    let state = record_failure_source state failure in
    { state with
      routes =
        Journal_routes.apply_child_failure
          state.routes
          ~block_id
          ~message:(failure_source_message failure)
    }
  | Child_created { child; parent; timeline_entry_update } ->
    let was_editing =
      Option.bind (Journal_routes.detail state.routes) Journal_detail.child_capture
      <> None
    in
    let routes = Journal_routes.apply_child_created state.routes ~child ~parent in
    let completed_active =
      was_editing
      && Option.bind (Journal_routes.detail routes) Journal_detail.child_capture = None
    in
    { state with
      routes
    ; modal =
        (if state.modal = Append_sheet && completed_active then No_modal else state.modal)
    ; timeline =
        Option.fold
          ~none:state.timeline
          ~some:(Journal_timeline_state.replace_timeline_entry state.timeline)
          timeline_entry_update
    }
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
       let state = restore_deleted state pending in
       { state with
         timeline =
           (if Journal_model.journal_day_opt latest = None
            then state.timeline
            else Journal_timeline_state.replace_block state.timeline latest)
       ; pending_delete = None
       ; timeline_notice =
           Some (Delete_failed "The block changed elsewhere. Delete was not applied.")
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
    let state = apply_worker_response_unstaged (restore_deleted state pending) response in
    (match state.pending_delete with
     | None -> state
     | Some pending -> hide_deleted state pending)
;;

module Root_navigation = struct
  type t = state

  type event =
    | Select of Journal_routes.destination
    | Capture_opened
    | Capture_closed
    | Capture_native_edit of Ui.Event.Payload.text_edit
    | Capture_task_intent of bool
    | Capture_edited of string
    | Capture_admitted of Journal_capture.t
    | Completed of Journal_graph_runtime.response
    | Graph_replaced of
        { generation : int
        ; graph_id : Logseq_db_types.Graph_types.Uuid.t option
        }
    | Account_cleared
    | Local_copy_deleted

  let replace_graph state generation graph_id =
    let state = switch_draft_graph state graph_id in
    { state with
      favorites = Journal_routes.Favorites.create ~graph_generation:generation
    ; favorites_requests = []
    ; pending_delete = None
    ; pending_status = None
    ; timeline = Journal_timeline_state.empty ~today:0
    ; graph_state = { state.graph_state with generation }
    ; graph_ready = false
    ; feed_loaded = false
    ; capture_error = None
    ; timeline_notice = None
    }
  ;;

  let create ~graph_generation = replace_graph initial_state graph_generation None

  let step state event =
    let state =
      match event with
      | Select destination -> select_destination state destination
      | Capture_opened ->
        let state =
          match state.direct_capture with
          | Some _ -> state
          | None ->
            { state with
              direct_capture =
                Some
                  (Journal_capture.create
                     ~session_number:state.next_local_sequence
                     ~source:"")
            ; next_local_sequence = Int64.succ state.next_local_sequence
            }
        in
        { state with modal = Capture_sheet }
      | Capture_closed -> { state with modal = No_modal }
      | Capture_native_edit edit ->
        { state with
          direct_capture =
            Option.map
              (fun capture -> Journal_capture.apply_text_edit capture edit)
              state.direct_capture
        }
      | Capture_task_intent selected ->
        { state with
          direct_capture =
            Option.map
              (fun capture ->
                 if Journal_capture.task_state capture = Journal_model.Todo = selected
                 then capture
                 else Journal_capture.toggle_task_intent capture)
              state.direct_capture
        }
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
      | Graph_replaced { generation; graph_id } ->
        let state = replace_graph state generation graph_id in
        { state with graph_state = { state.graph_state with graph_id } }
      | Account_cleared -> clear_account_drafts state
      | Local_copy_deleted -> discard_local_graph_state state
    in
    track_capture_session state
  ;;

  let destination state = Journal_routes.destination state.routes
  let capture_presented state = state.modal = Capture_sheet
  let capture state = state.direct_capture
  let favorites state = state.favorites
end

let application_theme () = Ui.Theme.create ~mode:System ()

let secondary_text value =
  V.text ~style:(Ui.Style.Text_style.create ~foreground:Secondary ()) value
;;

let bind_action handler action =
  Ui.Event.Handler.create ~name:("journal-action:" ^ action) (fun _payload ->
    Ui.Event.Handler.Private.invoke handler (Ui.Event.Payload.Text action))
;;

module Presentation = struct
  let keyed children =
    List.mapi
      (fun index child ->
         let key =
           match V.For_testing.key child, V.For_testing.test_id child with
           | Some key, _ -> key
           | None, Some id -> id
           | None, None -> string_of_int index
         in
         V.Keyed.create ~key child)
      children
  ;;

  let form children =
    V.Form.vertical ~key:(Ui.Key.string "form") (keyed children)
    |> V.Body.Vertical.fill
    |> fun content -> V.Body.Vertical.create [ content ]
  ;;

  let list children =
    V.Native_list.vertical
      ~key:(Ui.Key.string "graph-list")
      ~style:Inset
      [ V.Native_list.section
          ~key:(Ui.Key.string "graphs")
          ~separator:Hidden
          (List.mapi
             (fun index child ->
                let key =
                  match V.For_testing.test_id child with
                  | Some id -> Ui.Key.string id
                  | None -> Ui.Key.int index
                in
                V.Native_list.row ~key ~separator:Hidden child)
             children)
      ]
    |> V.Body.Vertical.fill
    |> fun content -> V.Body.Vertical.create [ content ]
  ;;

  let unavailable ~title ~symbol ~message ~actions =
    V.content_unavailable
      ~label:(V.label ~title:(V.text title) ~icon:(V.symbol ~name:symbol ()) ())
      ~description:(V.text message |> V.text_selection ~enabled:true)
      ~actions
      ()
  ;;

  let section ?key title children =
    V.Section.create
      ~key:(Option.value key ~default:(Ui.Key.string title))
      ~header:(V.text title)
      [ V.Keyed.create
          ~key:"content"
          (V.column ~alignment:Leading children |> V.text_selection ~enabled:true)
      ]
  ;;

  let labeled label content =
    V.labeled_content
      ~key:(Ui.Key.string label)
      ~label:(V.text label)
      ~value:(V.text_selection ~enabled:true content)
      ()
  ;;
end

let dismiss_toolbar ~test_id ~command dispatch body =
  let close =
    V.button
      ~role:Cancel
      ~on_press:(bind_action dispatch command)
      ~child:(V.text "Close")
      ()
    |> V.with_test_id (Ui.Test_id.string test_id)
  in
  V.Body.toolbar
    ~items:
      [ V.Toolbar.item ~key:(Ui.Key.string test_id) ~placement:Cancellation_action close ]
    body
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

let status_sheet_page ~tokens ~block dispatch =
  let options =
    List.mapi
      (fun index (tag, state) -> Int64.of_int index, tag, state)
      status_sheet_options
  in
  let selected_id =
    List.find_opt (fun (_, _, state) -> state = Journal_model.task_state block) options
    |> Option.map (fun (id, _, _) -> id)
  in
  let picker =
    V.Picker.create
      ~label:"Task status"
      ~style:Inline
      ~selected_id
      ~on_select:
        (Ui.Event.Handler.create (function
           | Ui.Event.Payload.Int64 id ->
             List.find_opt (fun (candidate, _, _) -> candidate = id) options
             |> Option.iter (fun (_, tag, _) ->
               Ui.Event.Handler.Private.invoke
                 dispatch
                 (Ui.Event.Payload.Text ("status-sheet-select:" ^ tag)))
           | _ -> ()))
      (List.map
         (fun (id, tag, state) ->
            let palette = Journal_visual_tokens.status_swipe_action tokens state in
            let icon_tint =
              if state = Journal_model.No_status
              then palette.foreground
              else palette.background
            in
            let title =
              if state = Journal_model.No_status
              then "Clear"
              else Journal_model.status_name state
            in
            let label =
              V.label
                ~title:(V.text title)
                ~icon:
                  (Journal_symbols.create
                     ~color:icon_tint
                     (Journal_symbols.for_task_state state))
                ()
              |> V.with_test_id (Ui.Test_id.string ("journal-status-sheet-option:" ^ tag))
            in
            V.Picker.option ~id ~label ())
         options)
      ()
  in
  Presentation.form [ picker ]
  |> dismiss_toolbar ~test_id:"journal-status-close" ~command:"close-status" dispatch
  |> V.Body.with_test_id
       (Ui.Test_id.string ("journal-status-sheet-page:" ^ Journal_model.id block))
;;

let live_region_text value =
  V.text value
  |> V.semantics ~properties:(Ui.Semantics.create ~label:value ~live_region:true ())
;;

let operation_feedback ~scope ~state dispatch body =
  let failure =
    if state.graph_ready then operation_failure state.timeline_notice else None
  in
  let summary, actions =
    match failure with
    | None -> "", V.empty ()
    | Some (summary, _, _) ->
      let action suffix title command =
        V.button ~on_press:(bind_action dispatch command) ~child:(V.text title) ()
        |> V.with_test_id (Ui.Test_id.string (scope ^ "-operation-" ^ suffix))
      in
      ( summary
      , V.row
          ~spacing:16.
          [ action "details" "Details" "open-error-info"
          ; action "dismiss" "Dismiss" "dismiss-operation-error"
          ] )
  in
  let label =
    V.label
      ~title:(live_region_text summary)
      ~icon:(V.symbol ~name:"exclamationmark.circle" ())
      ()
  in
  let padded view = V.padding ~insets:(Ui.Layout.Edge_insets.all 16.) view in
  Journal_header.feedback
    ~key:(Ui.Key.string (scope ^ "-feedback"))
    ~top:false
    ~visible:(summary <> "")
    ~compact:(padded (V.row ~spacing:16. [ label; V.spacer (); actions ]))
    ~expanded:(padded (V.column ~alignment:Leading ~spacing:8. [ label; actions ]))
    body
;;

let graph_unavailable_view ~message ~on_details ~on_diagnostics ~on_choose_graph =
  let action id title symbol handler =
    V.button
      ~on_press:handler
      ~child:(V.label ~title:(V.text title) ~icon:(V.symbol ~name:symbol ()) ())
      ()
    |> V.with_test_id (Ui.Test_id.string id)
  in
  Presentation.unavailable
    ~title:"Unable to open journal"
    ~symbol:"questionmark.folder"
    ~message
    ~actions:
      (V.column
         (Option.to_list
            (Option.map
               (action "graph-failure-choose" "Choose a graph" "folder")
               on_choose_graph)
          @ Option.to_list
              (Option.map
                 (action "graph-failure-details" "Error details" "exclamationmark.circle")
                 on_details)
          @ [ action
                "graph-failure-diagnostics"
                "Diagnostics"
                "stethoscope"
                on_diagnostics
            ]))
  |> V.with_test_id (Ui.Test_id.string "logseq-graph-open-failed")
;;

let prefix_action handler prefix =
  Ui.Event.Handler.create ~name:("journal-action-prefix:" ^ prefix) (function
    | Ui.Event.Payload.Text value ->
      Ui.Event.Handler.Private.invoke handler (Ui.Event.Payload.Text (prefix ^ value))
    | _ -> ())
;;

let media_scope state =
  let route =
    match Journal_routes.route state.routes with
    | Timeline ->
      (match Journal_routes.destination state.routes with
       | Journals -> "journals"
       | Favorites -> "favorites")
    | Detail -> "detail"
    | Detail_loading -> "detail-loading"
    | Missing_detail -> "detail-missing"
    | Failed_detail _ -> "detail-failed"
  in
  Printf.sprintf
    "%d:%s:%s"
    state.graph_state.generation
    route
    (Int64.to_string (Journal_routes.detail_request_generation state.routes))
;;

let media_label state dispatch ~root child =
  let scope = media_scope state in
  let editable =
    state.write_enabled
    &&
    match Journal_routes.detail state.routes with
    | Some detail -> String.equal root (Journal_model.id (Journal_detail.root detail))
    | None -> false
  in
  Journal_media_view.view
    ~scope
    ~root
    ~media:(Media_views.find_opt root state.media_views)
    ~editable
    ~on_event:(fun payload ->
      Ui.Event.Handler.Private.invoke
        dispatch
        (Ui.Event.Payload.Text ("media-session:" ^ scope ^ ":media:" ^ payload)))
    child
;;

module Favorites_list = struct
  module Keys = Set.Make (String)

  let view ~keys ~block_keys ~actions_enabled ~on_visible_range ~on_open ~children =
    let block_keys = Keys.of_list block_keys in
    let footer, children =
      match List.rev children with
      | footer :: rest -> footer, List.rev rest
      | [] -> invalid_arg "Favorites_list: missing footer"
    in
    let rows =
      List.map2
        (fun key label ->
           let label =
             if Keys.mem key block_keys
             then
               V.Navigation_link.create
                 ~key:(Ui.Key.string ("favorite-open:" ^ key))
                 ~activation_id:key
                 ~enabled:actions_enabled
                 ~on_activate:(bind_action on_open key)
                 ~label
                 ()
             else label
           in
           V.Native_list.row ~key:(Ui.Key.string key) ~separator:Hidden label)
        keys
        children
    in
    V.Native_list.vertical
      ~key:(Ui.Key.string "favorites-native-list")
      ~style:Plain
      ~on_visible_range
      [ V.Native_list.section
          ~key:(Ui.Key.string "favorites")
          ~separator:Hidden
          ~footer
          rows
      ]
    |> V.Viewport.Vertical.with_test_id (Ui.Test_id.string "favorites-native-list")
    |> V.Body.Vertical.fill
    |> fun content -> V.Body.Vertical.create [ content ]
  ;;
end

let favorites_view
      ~render_media
      ~state
      ~actions_enabled
      ~on_visible_range
      ~on_retry
      ~on_open_favorite
  =
  let module F = Journal_routes.Favorites in
  let rows = F.items state in
  let retry =
    V.button ~on_press:on_retry ~child:(V.text "Retry") ()
    |> V.with_test_id (Ui.Test_id.string "favorites-retry-button")
  in
  let busy = V.row [ V.progress ~style:Circular (); V.text "Loading favorites" ] in
  let content =
    if rows = []
    then
      (match F.error state with
       | Some message ->
         Presentation.unavailable
           ~title:"Unable to load favorites"
           ~symbol:"exclamationmark.triangle"
           ~message
           ~actions:retry
       | None when (not (F.initialized state)) || F.loading state ->
         busy |> V.frame ~max_width:Fill ~max_height:Fill
       | None ->
         Presentation.unavailable
           ~title:"No favorites yet"
           ~symbol:"star"
           ~message:"Favorite pages and blocks appear here."
           ~actions:(V.empty ()))
      |> V.Body.static
    else (
      let keys, children =
        List.split
          (List.map
             (fun value ->
                let favorite = Journal_graph_projection.favorite value in
                let key = favorite.membership_id in
                let text = V.text favorite.title in
                let label =
                  if favorite.task_state = Journal_model.No_status
                  then text
                  else
                    V.column
                      [ text; V.text (Journal_model.status_name favorite.task_state) ]
                in
                let row =
                  match favorite.target with
                  | Page _ -> V.label ~title:label ~icon:(V.symbol ~name:"doc.text" ()) ()
                  | Block _ -> label
                in
                let root =
                  match favorite.target with
                  | Page id | Block id -> id
                in
                key, V.column ~key:(Ui.Key.string key) [ render_media ~root row ])
             rows)
      in
      let footer =
        match F.error state with
        | Some message ->
          V.column [ live_region_text message; retry ]
          |> V.with_test_id (Ui.Test_id.string "favorites-retry")
        | None when F.loading state -> busy
        | None -> V.empty ()
      in
      Favorites_list.view
        ~actions_enabled
        ~keys
        ~block_keys:
          (List.filter_map
             (fun value ->
                let favorite = Journal_graph_projection.favorite value in
                match favorite.target with
                | Page _ -> None
                | Block _ -> Some favorite.membership_id)
             rows)
        ~on_open:on_open_favorite
        ~on_visible_range
        ~children:(children @ [ footer ]))
  in
  content
;;

let composer_page
      ~scope
      ~capture
      ~saving
      ~enabled
      ~on_edit
      ~on_toggle
      ~on_save
      ~on_close
      ~error
  =
  let ignored = Ui.Event.Handler.create (fun _ -> ()) in
  let can_submit =
    enabled
    && (not saving)
    && (Journal_capture.can_save capture
        ||
        match Journal_capture.phase capture with
        | Failed _ -> true
        | _ -> false)
  in
  let editor =
    V.text_editor
      ~autofocus:true
      ~key:(Ui.Key.string (scope ^ "-editor"))
      ~enabled:(enabled && not saving)
      ~session_id:(Journal_capture.session_id capture)
      ~document_revision:(Journal_capture.document_revision capture)
      ~accepted_local_revision:(Journal_capture.accepted_local_revision capture)
      ~update_mode:(Journal_capture.update_mode capture)
      ~value:(Journal_capture.value capture)
      ~on_edit
      ~on_submit:ignored
      ~on_focus_changed:ignored
      ()
    |> V.frame ~max_width:Fill ~max_height:Fill
    |> V.semantics ~properties:(Ui.Semantics.create ~label:"Draft" ())
    |> V.with_test_id (Ui.Test_id.string (scope ^ "-editor"))
  in
  let close =
    V.button ~role:Cancel ~on_press:on_close ~child:(V.text "Close") ()
    |> V.with_test_id (Ui.Test_id.string (scope ^ "-close"))
  in
  let task =
    V.toggle
      ~style:Button
      ~enabled:(enabled && not saving)
      ~value:(Journal_capture.task_state capture = Journal_model.Todo)
      ~on_changed:on_toggle
      ~label:
        (V.label ~title:(V.text "Task") ~icon:(V.symbol ~name:"checkmark.square" ()) ())
      ()
    |> V.with_test_id (Ui.Test_id.string (scope ^ "-task"))
  in
  let save =
    V.button ~enabled:can_submit ~on_press:on_save ~child:(V.text "Save") ()
    |> V.with_test_id (Ui.Test_id.string (scope ^ "-submit"))
  in
  V.column
    ~spacing:12.
    ([ editor ]
     @ (if saving then [ V.progress ~style:Circular (); V.text "Saving…" ] else [])
     @ Option.to_list (Option.map live_region_text error))
  |> V.padding ~insets:(Ui.Layout.Edge_insets.all 16.)
  |> V.Body.static
  |> V.Body.toolbar
       ~items:
         [ V.Toolbar.item
             ~key:(Ui.Key.string "composer-close")
             ~placement:Cancellation_action
             close
         ; V.Toolbar.item
             ~key:(Ui.Key.string "composer-task")
             ~placement:Primary_action
             task
         ; V.Toolbar.item
             ~key:(Ui.Key.string "composer-save")
             ~placement:Confirmation_action
             save
         ]
;;

let timeline_page
      ~render_media
      ~platform
      ~graph_generation
      ~on_scroll_completed
      ~destination
      ~favorites
      ~on_select_destination
      ~on_favorites_visible_range
      ~on_favorites_retry
      ~timeline_state
      ~loading
      ~graph_error
      ~sync_error
      ~sync_phase
      ~day_presentation
      ~capture_enabled
      ~on_capture_event
      ~on_visible_range
      ~on_retry_day
      ~on_open_block
      ~on_open_favorite
      ~delete_enabled
      ~actions_enabled
      ~interaction_enabled
      ~on_status
      ~on_delete
      ~error_info_available
      ~on_error_info
      ~account_menu_available
      ~cache_reset_available
      ~on_account_action
  =
  let timeline =
    match graph_error with
    | Some message ->
      graph_unavailable_view
        ~message
        ~on_details:(if error_info_available then Some on_error_info else None)
        ~on_diagnostics:(bind_action on_account_action "open-diagnostics")
        ~on_choose_graph:None
      |> V.Body.static
    | None when loading ->
      Journal_timeline.loading_view ()
      |> V.with_test_id (Ui.Test_id.string "journal-timeline")
      |> V.Body.static
    | None ->
      Journal_timeline.view
        ~render_media
        ~state:timeline_state
        ~day_presentation
        ~delete_enabled
        ~actions_enabled:(actions_enabled && interaction_enabled)
        ~on_status
        ~on_delete
        ~on_visible_range
        ~on_retry_day
        ~on_scroll_completed
        ~on_open_block
  in
  let favorites_selected = destination = Journal_routes.Favorites in
  let content =
    if favorites_selected
    then
      favorites_view
        ~render_media
        ~state:favorites
        ~actions_enabled:interaction_enabled
        ~on_visible_range:on_favorites_visible_range
        ~on_retry:on_favorites_retry
        ~on_open_favorite
    else timeline
  in
  let destination_action index =
    Ui.Event.Handler.create (fun _ ->
      Ui.Event.Handler.Private.invoke on_select_destination (Ui.Event.Payload.Int64 index))
  in
  Journal_header.view
    ~platform
    ~key:(Ui.Key.string ("journal-root:" ^ string_of_int graph_generation))
    ~context:
      (match destination with
       | Journal_routes.Journals -> Journal_header.Context.journals
       | Favorites -> Journal_header.Context.favorites)
    ~sync_phase
    ~sync_error
    ~on_error_info:(if error_info_available then Some on_error_info else None)
    ~on_account_action:(if account_menu_available then Some on_account_action else None)
    ~local_deletion_available:cache_reset_available
    ~on_journals:(destination_action 0L)
    ~on_favorites:(destination_action 1L)
    ~on_capture:(bind_action on_capture_event "open-capture")
    ~capture_enabled
    ~body:content
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

let error_info_page ~sync_error ~operation_failure occurrences dispatch =
  let labeled_row label value = Presentation.labeled label (V.text value) in
  let cause_row label (cause : Logseq_db_worker.Error.cause) =
    let code = Option.fold ~none:"" ~some:(fun value -> " · " ^ value) cause.code in
    V.column
      [ V.text
          ~style:(Ui.Style.Text_style.create ~font_weight:Semi_bold ())
          (Printf.sprintf
             "%s · %s%s"
             (Logseq_db_worker.Error.component_string cause.component)
             cause.operation
             code)
      ; secondary_text cause.message
      ]
    |> Presentation.labeled label
    |> V.semantics
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
      List.mapi
        (fun index cause -> cause_row ("Context " ^ string_of_int (index + 1)) cause)
        trace.contexts
      @ [ cause_row "Origin" trace.origin ]
      @
      if trace.truncated
      then [ labeled_row "Causal trace" "Earlier outer contexts were truncated." ]
      else []
    in
    Presentation.section
      ~key:(Ui.Key.int64 occurrence.sequence)
      (Logseq_db_worker.Error.code_string (Logseq_db_worker.Error.code error))
      ([ V.text (Logseq_db_worker.Error.message error)
       ; labeled_row ("Occurrence " ^ Int64.to_string occurrence.sequence) status
       ]
       @ List.map (fun row -> labeled_row (fst row) (snd row)) metadata
       @ List.map (fun row -> labeled_row (fst row) (snd row)) details
       @ causes)
    |> V.with_test_id
         (Ui.Test_id.string
            ("journal-worker-error-" ^ Int64.to_string occurrence.sequence))
  in
  let rows =
    match occurrences with
    | [] when Option.is_none operation_failure && Option.is_none sync_error ->
      [ secondary_text "No worker errors observed." ]
    | occurrences -> List.map card occurrences
  in
  let operation =
    match operation_failure with
    | None -> []
    | Some (title, message, recovery) ->
      [ Presentation.section title [ V.text message; V.text recovery ] ]
  in
  let sync =
    match sync_error with
    | None -> []
    | Some message -> [ Presentation.section "Sync error" [ V.text message ] ]
  in
  Presentation.form (sync @ operation @ rows)
  |> dismiss_toolbar
       ~test_id:"journal-error-info-close"
       ~command:"close-error-info"
       dispatch
  |> V.Body.with_test_id (Ui.Test_id.string "journal-error-info-page")
;;

let diagnostics_page ~snapshot ~graph ~admission diagnostics dispatch =
  let groups =
    [ "Phases", diagnostic_phase_rows ~snapshot ~graph
    ; "Overlay DB", admission_rows admission
    ]
    @ diagnostic_groups diagnostics
  in
  Presentation.form
    (List.map
       (fun (title, rows) ->
          Presentation.section
            title
            (List.map
               (fun (label, value) -> Presentation.labeled label (V.text value))
               rows))
       groups)
  |> dismiss_toolbar
       ~test_id:"journal-diagnostics-close"
       ~command:"close-diagnostics"
       dispatch
  |> V.Body.with_test_id (Ui.Test_id.string "journal-diagnostics-dialog-page")
;;

module Cache_confirmation = struct
  let local_cache ~token dispatch body =
    let request =
      Option.map
        (fun token ->
           V.Confirmation.request
             ~token
             ~title:"Delete local graph copy?"
             ~message:
               "This deletes the local copy, including unsaved drafts and pending local \
                changes, then returns to graph selection. The remote graph and cached \
                encryption key are retained. Select a graph to open or download it."
             [ V.Confirmation.action ~key:"cancel" ~title:"Cancel" ~role:Cancel ()
             ; V.Confirmation.action
                 ~key:"delete"
                 ~title:"Delete local graph copy"
                 ~role:Destructive
                 ()
             ])
        token
    in
    V.Confirmation.alert
      ~key:(Ui.Key.string "local-cache-confirmation")
      ~request
      ~on_response:dispatch
      body
    |> V.with_test_id (Ui.Test_id.string "local-cache-reset-confirmation")
  ;;
end

module Detail_outline = struct
  let scope routes =
    Printf.sprintf "detail-session:%Ld:" (Journal_routes.detail_request_generation routes)
  ;;
end

module Detail_list = struct
  let view ~key ~detail ~enabled ~on_action ~on_scroll_completed ~children =
    let depth = function
      | Journal_detail.Block row -> row.depth
      | More row -> row.depth
    in
    let rec siblings level items =
      match items with
      | (row, label) :: rest when depth row = level ->
        let nested, rest = siblings (level + 1) rest in
        let row_key = Ui.Key.string (Journal_detail.row_key row) in
        let item =
          match row with
          | Journal_detail.More _ ->
            V.Native_list.row ~key:row_key ~separator:Hidden label
          | Block { block; expanded; leaf; _ } ->
            let id = Journal_model.id block in
            let delete = bind_action on_action ("detail-delete:" ^ id) in
            let swipe_actions =
              V.Swipe_actions.create
                ~allows_full_swipe:false
                ~actions:
                  [ V.Swipe_actions.action
                      ~key:(Ui.Key.string ("delete:" ^ id))
                      ~enabled
                      ~side:End
                      ~title:"Delete"
                      ~symbol:"trash"
                      ~role:Destructive
                      ~background:Journal_visual_tokens.delete_action_background
                      ~on_press:delete
                      ()
                  ]
                ()
            in
            let context_menu =
              V.Context_menu.create
                ~actions:
                  [ V.Context_menu.action
                      ~key:(Ui.Key.string "delete")
                      ~enabled
                      ~role:Destructive
                      ~title:"Delete block and descendants"
                      ~symbol:"trash"
                      ~on_press:delete
                      ()
                  ]
                ()
            in
            if leaf
            then
              V.Native_list.row
                ~key:row_key
                ~separator:Hidden
                ~swipe_actions
                ~context_menu
                label
            else
              V.Native_list.disclosure_row
                ~key:row_key
                ~separator:Hidden
                ~swipe_actions
                ~context_menu
                ~test_id:(Ui.Test_id.string ("detail-disclosure:" ^ id))
                ~expanded
                ~on_expanded_changed:
                  (Ui.Event.Handler.create (function
                     | Ui.Event.Payload.Bool expanded ->
                       Ui.Event.Handler.Private.invoke
                         on_action
                         (Text
                            ((if expanded then "detail-expand:" else "detail-collapse:")
                             ^ id))
                     | _ -> ()))
                ~label
                nested
        in
        let siblings, rest = siblings level rest in
        item :: siblings, rest
      | _ -> [], items
    in
    let rows, _ = siblings 0 (List.combine (Journal_detail.rows detail) children) in
    let scroll_request =
      Option.map
        (fun id ->
           V.Native_list.scroll_request
             ~token:(Journal_detail.composer_revision detail)
             ~target:
               (V.Native_list.target
                  ~section:(Ui.Key.string "outline")
                  ~row_path:
                    [ Ui.Key.string
                        ("block:" ^ Journal_model.id (Journal_detail.root detail))
                    ; Ui.Key.string ("block:" ^ id)
                    ])
             ~anchor:Bottom
             ~animated:false
             ())
        (Journal_detail.reveal_id detail)
    in
    V.Native_list.vertical
      ~key
      ~style:Plain
      ?scroll_request
      ~on_scroll_completed
      [ V.Native_list.section ~key:(Ui.Key.string "outline") ~separator:Hidden rows ]
    |> V.Viewport.Vertical.with_test_id (Ui.Test_id.string "journal-detail-outline")
    |> V.Body.Vertical.fill
    |> fun content -> V.Body.Vertical.create [ content ]
  ;;
end

let detail_page ~state ~on_scroll_completed dispatch =
  let detail = Journal_routes.detail state.routes in
  let enabled =
    state.write_enabled && state.pending_delete = None && state.pending_status = None
  in
  let saving =
    Option.fold
      ~none:false
      ~some:(fun detail -> Journal_detail.mode detail = Saving_child)
      detail
  in
  let scope = Detail_outline.scope state.routes in
  let on_action action = bind_action dispatch (scope ^ action) in
  let button ~id ~command title =
    V.button ~on_press:(on_action command) ~child:(V.text title) ()
    |> V.with_test_id (Ui.Test_id.string id)
  in
  let rows detail =
    List.map
      (function
        | Journal_detail.More { parent_id; loading; error; _ } ->
          if loading
          then V.row [ V.progress ~style:Circular (); V.text "Loading children" ]
          else
            V.column
              (Option.to_list (Option.map live_region_text error)
               @ [ button
                     ~id:("detail-more:" ^ parent_id)
                     ~command:("detail-more:" ^ parent_id)
                     (if Option.is_some error
                      then "Retry loading children"
                      else "Load more")
                 ])
        | Block { block; _ } ->
          let source =
            if Journal_model.task_state block = No_status
            then Journal_model.source block
            else
              Journal_model.status_name (Journal_model.task_state block)
              ^ "  "
              ^ Journal_model.source block
          in
          V.text ~key:(Ui.Key.string ("detail-label:" ^ Journal_model.id block)) source
          |> V.with_test_id (Ui.Test_id.string ("detail-block:" ^ Journal_model.id block))
          |> media_label state dispatch ~root:(Journal_model.id block))
      (Journal_detail.rows detail)
  in
  let content =
    match detail with
    | Some detail ->
      Detail_list.view
        ~key:(Ui.Key.string scope)
        ~detail
        ~enabled:(enabled && not saving)
        ~on_action:(prefix_action dispatch scope)
        ~on_scroll_completed
        ~children:(rows detail)
    | None ->
      (match Journal_routes.route state.routes with
       | Detail_loading ->
         V.column [ V.progress ~style:Circular (); V.text "Loading block" ]
         |> V.frame ~max_width:Fill ~max_height:Fill
       | Missing_detail ->
         Presentation.unavailable
           ~title:"Block unavailable"
           ~symbol:"doc"
           ~message:"This block may have been deleted or moved."
           ~actions:(V.empty ())
       | Failed_detail message ->
         Presentation.unavailable
           ~title:"Unable to open block"
           ~symbol:"exclamationmark.triangle"
           ~message
           ~actions:(button ~id:"detail-retry" ~command:"detail-retry" "Retry")
       | Detail | Timeline -> V.empty ())
      |> V.Body.static
  in
  let composer =
    V.button
      ~enabled:(enabled && Option.is_some detail && not saving)
      ~on_press:(bind_action dispatch "open-append")
      ~child:(V.label ~title:(V.text "Append") ~icon:(V.symbol ~name:"plus" ()) ())
      ()
    |> V.with_test_id (Ui.Test_id.string "journal-append-open")
  in
  content
  |> V.Body.toolbar
       ~items:
         [ V.Toolbar.item ~key:(Ui.Key.string "append") ~placement:Primary_action composer
         ; V.Toolbar.item
             ~key:(Ui.Key.string "attach")
             ~placement:Primary_action
             (Journal_asset_import.view
                ~key:(Ui.Key.string (scope ^ "import"))
                ~enabled:(enabled && Option.is_some detail && not saving)
                ~completion:state.import_completion
                ~replacement:state.pending_replace
                ~request:state.replace_request
                ~on_select:(fun payload ->
                  Ui.Event.Handler.Private.invoke
                    dispatch
                    (Ui.Event.Payload.Text (scope ^ "import-asset:" ^ payload))))
         ]
  |> V.Body.with_test_id (Ui.Test_id.string "journal-detail-route")
;;

let manager_page state dispatch =
  let button ?(role = V.Button_role.Normal) ?(enabled = true) ~id ~command title symbol =
    V.button
      ~key:(Ui.Key.string id)
      ~role
      ~enabled
      ~on_press:(bind_action dispatch command)
      ~child:(V.label ~title:(V.text title) ~icon:(V.symbol ~name:symbol ()) ())
      ()
    |> V.with_test_id (Ui.Test_id.string id)
  in
  let diagnostics =
    button
      ~id:"journal-startup-diagnostics"
      ~command:"open-diagnostics"
      "Diagnostics"
      "stethoscope"
  in
  let toolbar title actions body =
    body
    |> V.Body.toolbar
         ~items:
           (V.Toolbar.item
              ~key:(Ui.Key.string "startup-title")
              ~placement:Principal
              (V.text title)
            :: V.Toolbar.item
                 ~key:(Ui.Key.string "startup-diagnostics")
                 ~placement:Secondary_action
                 diagnostics
            :: actions)
  in
  let unavailable ~title ~symbol ~message ~actions =
    Presentation.unavailable ~title ~symbol ~message ~actions
    |> V.frame ~max_width:Fill ~max_height:Fill
    |> V.Body.static
  in
  let choose_graph =
    button
      ~id:"graph-picker-choose"
      ~command:"switch-graph"
      "Choose another graph"
      "folder"
  in
  let can_choose_graph =
    Option.fold
      ~none:false
      ~some:(fun (snapshot : Graph_service.snapshot) ->
        snapshot.startup.authenticated
        && Option.is_some snapshot.selected_graph
        && Option.is_none snapshot.local_deletion)
      state.manager
  in
  let busy ?value ?(allow_graph_selection = false) title message =
    V.column
      ~spacing:12.
      [ V.progress ?value ~style:(if Option.is_some value then Linear else Circular) ()
      ; V.text title
      ; V.text message
      ; (if allow_graph_selection && can_choose_graph then choose_graph else V.empty ())
      ]
    |> V.frame ~max_width:Fill ~max_height:Fill
    |> V.padding ~insets:(Ui.Layout.Edge_insets.all 24.)
    |> V.Body.static
  in
  let graph_picker snapshot =
    let refresh =
      button
        ~id:"graph-picker-refresh"
        ~command:"refresh-catalog"
        "Refresh graphs"
        "arrow.clockwise"
      |> V.help ~message:"Refresh the authorized graph catalog"
    in
    let content =
      match snapshot.Graph_service.catalog with
      | [] ->
        unavailable
          ~title:"No graphs available"
          ~symbol:"folder"
          ~message:"Refresh to check for graphs available to your account."
          ~actions:(V.empty ())
      | graphs ->
        Presentation.list
          (List.map
             (fun (graph : Graph_service.graph) ->
                let graph_id =
                  Logseq_db_types.Graph_types.Uuid.to_string graph.graph_id
                in
                button
                  ~id:("graph-picker:" ^ graph_id)
                  ~command:("select-graph:" ^ graph_id)
                  graph.name
                  (if graph.encrypted then "lock.doc" else "folder"))
             graphs)
        |> V.Body.with_test_id (Ui.Test_id.string "graph-picker-list")
    in
    toolbar
      "Choose a graph"
      [ V.Toolbar.item
          ~key:(Ui.Key.string "graph-picker-refresh")
          ~placement:Primary_action
          refresh
      ]
      content
  in
  let unlock error =
    let password = state.e2ee_password in
    let ignored = Ui.Event.Handler.create (fun _ -> ()) in
    let submit = bind_action dispatch "submit-e2ee-password" in
    let editor =
      V.secure_field
        ~label:"Encryption password"
        ~prompt:"Enter password"
        ~appearance:Ui.Text_editing.Field_appearance.Plain
        ~key:(Ui.Key.string "e2ee-password-editor")
        ~enabled:true
        ~keyboard:Ui.Text_editing.Keyboard.Text
        ~submit_label:Ui.Text_editing.Submit_label.Go
        ~autofocus:true
        ~max_utf8_bytes:4096
        ~session_id:(Journal_capture.session_id password)
        ~document_revision:(Journal_capture.document_revision password)
        ~accepted_local_revision:(Journal_capture.accepted_local_revision password)
        ~update_mode:(Journal_capture.update_mode password)
        ~value:(Journal_capture.value password)
        ~on_edit:dispatch
        ~on_submit:submit
        ~on_focus_changed:ignored
        ~on_limit_reached:ignored
        ()
      |> V.with_test_id (Ui.Test_id.string "e2ee-password-editor")
    in
    let graph_name =
      Option.bind state.manager (fun snapshot ->
        Option.bind snapshot.selected_graph (fun selected ->
          List.find_opt
            (fun (graph : Graph_service.graph) ->
               Logseq_db_types.Graph_types.Uuid.equal graph.graph_id selected)
            snapshot.catalog))
      |> Option.map (fun (graph : Graph_service.graph) -> graph.name)
      |> Option.value ~default:"Encrypted graph"
    in
    let unlock_button =
      V.button
        ~key:(Ui.Key.string "unlock-submit")
        ~style:Prominent
        ~enabled:(Journal_capture.can_save password)
        ~on_press:submit
        ~child:(V.text "Unlock graph")
        ()
      |> V.frame ~max_width:Fill
      |> V.with_test_id (Ui.Test_id.string "e2ee-password-submit")
    in
    let choose_graph =
      V.button
        ~key:(Ui.Key.string "unlock-cancel")
        ~role:Cancel
        ~style:Plain
        ~on_press:(bind_action dispatch "switch-graph")
        ~child:(V.text "Choose another graph")
        ()
      |> V.with_test_id (Ui.Test_id.string "e2ee-password-cancel")
    in
    Presentation.form
      [ Presentation.section
          "Unlock your graph"
          [ V.symbol ~name:"lock.shield" ()
          ; V.text ~key:(Ui.Key.string "graph-name") graph_name
            |> V.text_selection ~enabled:true
          ; V.text "Enter your encryption password to access your notes."
          ]
      ; Presentation.section
          "Encryption password"
          [ editor
          ; (match error with
             | None -> V.empty ()
             | Some message -> live_region_text message)
          ; unlock_button
          ; V.text "Use the encryption password you set up in Logseq."
          ; choose_graph
          ]
      ]
    |> V.Body.toolbar
         ~items:
           [ V.Toolbar.item
               ~key:(Ui.Key.string "startup-diagnostics")
               ~placement:Secondary_action
               diagnostics
           ]
  in
  let body =
    match state.manager with
    | None -> busy "Preparing your account" "" |> toolbar "Journals" []
    | Some snapshot ->
      let startup = Journal_startup.derive ~snapshot ~graph:state.graph_state in
      (match startup.phase with
       | Awaiting_selection -> graph_picker snapshot
       | Awaiting_e2ee_password -> unlock None
       | Failed
         when Option.fold
                ~none:false
                ~some:(fun (error : Journal_startup.startup_error) ->
                  error.recovery = Some Submit_e2ee_password)
                startup.error ->
         unlock
           (Option.map
              (fun (error : Journal_startup.startup_error) -> error.message)
              startup.error)
       | Signed_out ->
         unavailable
           ~title:"Sign in to open a graph"
           ~symbol:"person.crop.circle"
           ~message:"Connect your account to access your graphs."
           ~actions:(V.empty ())
         |> toolbar "Journals" []
       | Loading_catalog ->
         busy ~allow_graph_selection:true "Loading your graphs" ""
         |> toolbar "Journals" []
       | (Ready | Restoring_local)
         when Option.is_some state.graph_error
              && state.graph_state.phase = Graph_open
              && state.graph_state.generation = snapshot.startup.graph_generation
              && Option.equal
                   Logseq_db_types.Graph_types.Uuid.equal
                   state.graph_state.graph_id
                   snapshot.selected_graph ->
         graph_unavailable_view
           ~message:(graph_error_message (Option.get state.graph_error))
           ~on_details:
             (if state.worker_errors = []
              then None
              else Some (bind_action dispatch "open-error-info"))
           ~on_diagnostics:(bind_action dispatch "open-diagnostics")
           ~on_choose_graph:(Some (bind_action dispatch "switch-graph"))
         |> V.frame ~max_width:Fill ~max_height:Fill
         |> V.Body.static
         |> toolbar "Journals" []
       | Ready ->
         busy ~allow_graph_selection:true "Opening journal" "" |> toolbar "Journals" []
       | Restoring_local ->
         busy ~allow_graph_selection:true "Restoring your graph" ""
         |> toolbar "Journals" []
       | Deleting_local ->
         let message =
           match snapshot.local_deletion with
           | Some (Deletion_in_progress Closing_graph) -> "Closing the local graph"
           | Some (Deletion_in_progress Deleting_mirror) -> "Deleting the local copy"
           | Some (Deletion_in_progress Clearing_selection) ->
             "Clearing the saved selection"
           | None | Some (Deletion_failed _) -> "Deleting the local copy"
         in
         busy message "" |> toolbar "Journals" []
       | Bootstrapping ->
         let value, message =
           match state.bootstrap_progress with
           | None -> None, "Preparing the local mirror"
           | Some progress ->
             let value =
               Option.bind progress.Graph_service.total_bytes (fun total ->
                 if total <= 0L || progress.received_bytes < 0L
                 then None
                 else
                   Some
                     (Float.min
                        1.
                        (Int64.to_float progress.received_bytes /. Int64.to_float total)))
             in
             value, Printf.sprintf "Downloaded %Ld bytes" progress.received_bytes
         in
         busy ?value ~allow_graph_selection:true "Downloading graph" message
         |> toolbar "Journals" []
       | Failed ->
         let message, recovery =
           match startup.error with
           | None -> "Unable to open graph", None
           | Some error -> error.message, error.recovery
         in
         let actions =
           match recovery with
           | Some Refresh_catalog ->
             button
               ~id:"graph-picker-retry"
               ~command:"refresh-catalog"
               "Retry"
               "arrow.clockwise"
           | Some Begin_online_recovery | Some Retry_graph_open ->
             button
               ~id:"graph-picker-retry"
               ~command:"begin-online-recovery"
               "Retry"
               "arrow.clockwise"
           | Some Submit_e2ee_password | Some Sign_in | None -> V.empty ()
         in
         let actions =
           if
             Option.is_some snapshot.selected_graph
             && Option.is_none snapshot.local_deletion
           then V.column ~spacing:12. [ actions; choose_graph ]
           else actions
         in
         unavailable
           ~title:"Unable to open graph"
           ~symbol:"questionmark.folder"
           ~message
           ~actions
         |> toolbar "Journals" [])
  in
  body |> V.Body.with_test_id (Ui.Test_id.string "sync-manager-route")
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

let media_key state =
  if
    state.graph_state.phase = Logseq_db_worker.Graph_open
    &&
    match Journal_routes.route state.routes with
    | Timeline | Detail -> true
    | _ -> false
  then Some (state.graph_state.generation, media_scope state)
  else None
;;

let upload_context state =
  if state.graph_state.phase = Logseq_db_worker.Graph_open
  then
    Option.map
      (fun graph -> state.graph_state.generation, graph)
      state.graph_state.graph_id
  else None
;;

type action =
  | Update of (state -> state * unit Effect.t)
  | Platform_response of int * (bytes, string) result
  | Environment_changed of Journal_environment.snapshot

type app_context =
  { app : (state, action) Lui_app.reducer_app
  ; pump : Journal_pump.t
  ; client :
      (Graph_service.request, Graph_service.response, Graph_service.push) Worker.client
  ; send_action : action -> unit
  ; apply_platform : bytes -> unit Effect.t
  ; running : bool ref
  }

let latest_patch = ref ""
let current_app : app_context option ref = ref None

let decode_extension_values payload =
  let json =
    try Yojson.Safe.from_string payload with
    | _ -> `Null
  in
  match json with
  | `Assoc fields ->
    List.fold_left
      (fun map (key, value) ->
         match value with
         | `String s -> Lui_protocol.String_map.add key (Lui_protocol.StringValue s) map
         | `Bool b -> Lui_protocol.String_map.add key (Lui_protocol.BoolValue b) map
         | `Int i -> Lui_protocol.String_map.add key (Lui_protocol.IntValue i) map
         | `Float f -> Lui_protocol.String_map.add key (Lui_protocol.FloatValue f) map
         | _ -> map)
      Lui_protocol.String_map.empty
      fields
  | _ -> Lui_protocol.String_map.empty
;;

(* Platform request tags map to the tag carried by their response envelope;
   continuations are registered under the response tag. *)
let response_tag = function
  | 6 -> 7
  | 8 -> 9
  | 10 -> 11
  | 13 -> 14
  | 20 -> 21
  | 22 -> 23
  | 25 -> 26
  | tag -> tag
;;

let start ~calendar_sampler ~client ~platform_code ~host_code : app_context =
  let pump = Journal_pump.create () in
  Journal_pump.set_wakeup pump Journal_bridge.wakeup;
  let running = ref true in
  let app_cell : (state, action) Lui_app.reducer_app option ref = ref None in
  (* ocaml-signal is single-threaded and [Signal.update] is not reentrant, so
     sends issued while an update is running (effects, edge callbacks,
     continuations) are queued and drained once the outer update finishes. *)
  let pending_actions : action Queue.t = Queue.create () in
  let in_update = ref false in
  let rec send_action action =
    match !app_cell with
    | None -> ()
    | Some app ->
      if !in_update
      then Queue.add action pending_actions
      else (
        in_update := true;
        ignore (Lui_app.send app action : bool);
        drain_pending_actions ())
  and drain_pending_actions () =
    match Queue.take_opt pending_actions with
    | None -> in_update := false
    | Some action ->
      (match !app_cell with
       | Some app -> ignore (Lui_app.send app action : bool)
       | None -> ());
      drain_pending_actions ()
  in
  let set_state transition : unit Effect.t =
    fun () -> send_action (Update (fun state -> transition state, Effect.ignore))
  in
  let set_state_and_effect transition : unit Effect.t =
    fun () -> send_action (Update transition)
  in
  let state_ref = ref initial_state in
  let set_state_ref = ref None in
  set_state_ref := Some set_state;
  (* Platform requests are fire-and-forget: the host replies on the
     [platform_response] hook, or reports a failed request through
     [platform_failure]; both resolve the continuation registered under the
     matching response tag. *)
  let pending_platform : (int, (bytes, string) result -> unit) Hashtbl.t =
    Hashtbl.create 8
  in
  let emit_platform_request ?k request =
    (match k, Bytes.length request >= 8 with
     | Some k, true ->
       let tag = Bytes.get_uint16_le request 6 in
       Hashtbl.replace pending_platform (response_tag tag) k
     | Some _, false | None, _ -> ());
    Journal_bridge.platform_request (Bytes.to_string request)
  in
  let platform_request request ~f : unit Effect.t =
    fun () -> emit_platform_request ~k:(fun result -> Effect.run (f result)) request
  in
  let graph_runtime =
    Journal_graph_runtime.create
      ~localtime:(Journal_calendar.Sampler.localtime calendar_sampler)
      ()
  in
  let media_worker_requests = Hashtbl.create 16 in
  let media_changes = Hashtbl.create 16 in
  let media_context = ref None in
  let media_armed = ref None in
  let media_runtime =
    Journal_media_runtime.create
      ~send:(fun ticket request ->
        match Worker.send client request with
        | Accepted id ->
          Option.iter
            (fun ticket -> Hashtbl.replace media_worker_requests id ticket)
            ticket;
          true
        | Full | Not_ready | Stopping -> false)
      ~changed:(fun root view -> Hashtbl.replace media_changes root view)
      ~armed:(fun _root previous ->
        media_armed
        := Some (Option.map Logseq_db_types.Graph_types.Uuid.to_string previous))
  in
  let sync_media state =
    let key = media_key state in
    if key <> !media_context
    then (
      media_context := key;
      Journal_media_runtime.reset media_runtime ~graph_generation:(Option.map fst key))
  in
  let flush_media set_state =
    let changes = Hashtbl.to_seq media_changes |> List.of_seq in
    Hashtbl.clear media_changes;
    let armed = !media_armed in
    media_armed := None;
    let context = !media_context in
    if changes = [] && armed = None
    then Effect.ignore
    else
      set_state (fun state ->
        if media_key state <> context
        then state
        else
          { state with
            media_views =
              List.fold_left
                (fun views (root, (view : Journal_media_runtime.view)) ->
                   if
                     view.items = []
                     && view.error = None
                     && (not view.more)
                     && view.picker = None
                   then Media_views.remove root views
                   else Media_views.add root view views)
                state.media_views
                changes
          ; pending_replace =
              (match armed with
               | None -> state.pending_replace
               | Some previous -> Some (Option.value ~default:"" previous))
          ; replace_request =
              (match armed with
               | None -> state.replace_request
               | Some _ -> state.replace_request + 1)
          })
  in
  let import_worker_requests = Hashtbl.create 2 in
  let asset_worker_requests = Hashtbl.create 2 in
  let asset_runtime =
    Journal_asset_runtime.create
      ~changed:(fun generation recent favorites ->
        Option.iter
          (fun set_state ->
             Effect.run
               (set_state (fun state ->
                  match generation with
                  | Some generation when state.graph_state.generation = generation ->
                    { state with asset_offline = Some (recent, favorites) }
                  | None -> { state with asset_offline = None }
                  | Some _ -> state)))
          !set_state_ref)
      ~send:(fun request ->
        match Worker.send client request with
        | Worker.Accepted worker_id ->
          (match request with
           | Graph_service.Graph_request request ->
             Hashtbl.replace asset_worker_requests worker_id request.request_id
           | _ -> ());
          true
        | Full | Not_ready | Stopping -> false)
  in
  let asset_settings = ref None in
  let refresh_assets ~graph_generation calendar =
    Option.iter
      (fun (calendar, settings) ->
         Journal_asset_runtime.refresh
           asset_runtime
           ~graph_generation
           ~today:(Journal_calendar.local_day calendar)
           ~settings)
      (Option.bind calendar (fun calendar ->
         Option.map (fun settings -> calendar, settings) !asset_settings))
  in
  let started_graph_generation = ref None in
  let send_manager command =
    Effect.of_thunk (fun () ->
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
    | Admission_refresh.No_request -> Effect.ignore
    | Request request ->
      Effect.bind
        (Effect.of_thunk (fun () ->
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
          | None -> Effect.ignore
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
    Effect.bind
      (Effect.of_thunk (fun () -> deliver_output (submit request)))
      ~f:(fun delivery ->
        match !set_state_ref with
        | None -> Effect.ignore
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
          then
            Root_navigation.step
              state
              (Graph_replaced
                 { generation = graph_state.generation; graph_id = graph_state.graph_id })
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
        then Effect.ignore
        else (
          started_graph_generation := Some (graph_key, graph_state.generation);
          Journal_graph_runtime.reset graph_runtime;
          Hashtbl.clear favorites_worker_requests;
          let current = !state_ref in
          refresh_assets ~graph_generation:graph_state.generation current.calendar;
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
          Effect.bind prepare ~f:(fun () ->
            Effect.bind
              (Effect.of_thunk (fun () -> deliver_output output))
              ~f:(fun delivery ->
                set_state (fun state -> apply_delivery_responses state delivery))))
      | Graph_closed | Graph_opening | Graph_closing | Graph_failed ->
        started_graph_generation := None;
        Journal_asset_runtime.shutdown asset_runtime;
        Effect.ignore
    in
    Effect.bind update ~f:(fun () ->
      Effect.many
        [ start_graph
        ; trigger_admission
            set_state_and_effect
            ~graph_generation:graph_state.generation
            ~graph_open:(graph_state.phase = Graph_open)
        ])
  in
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
        platform_request Journal_platform.sign_out_request ~f:(fun result ->
          set_state (fun state ->
            match result with
            | Ok payload
              when Result.is_ok (Journal_platform.decode_sign_out_response payload) ->
              state
            | Error _ | Ok _ ->
              show_sync_error
                state
                (Non_worker_sync_failure "Unable to sign out of the authenticated session"))))
      else Effect.ignore
    in
    let termination_ready =
      if
        !termination_in_flight
        && (manager.Graph_service.startup.awaiting_selection
            || not manager.startup.authenticated)
      then (
        termination_in_flight := false;
        platform_request Journal_platform.termination_ready_request ~f:(fun _ ->
          Effect.ignore))
      else Effect.ignore
    in
    Effect.bind update ~f:(fun () ->
      let snapshot = !state_ref in
      Effect.many
        [ sign_out
        ; termination_ready
        ; trigger_admission
            set_state_and_effect
            ~graph_generation:snapshot.graph_state.generation
            ~graph_open:(snapshot.graph_state.phase = Graph_open)
        ])
  in
  let handle_worker_event event =
    Journal_asset_runtime.pump asset_runtime;
    sync_media !state_ref;
    Journal_media_runtime.pump media_runtime;
    match event with
    | Worker.Response { request_id; outcome = Completed response; _ }
      when Hashtbl.mem media_worker_requests request_id ->
      let ticket = Hashtbl.find media_worker_requests request_id in
      Hashtbl.remove media_worker_requests request_id;
      Journal_media_runtime.receive media_runtime ticket response;
      flush_media set_state
    | Worker.Response { request_id; outcome = Failed _ | Cancelled | Shutdown; _ }
      when Hashtbl.mem media_worker_requests request_id ->
      let ticket = Hashtbl.find media_worker_requests request_id in
      Hashtbl.remove media_worker_requests request_id;
      Journal_media_runtime.reject media_runtime ticket;
      flush_media set_state
    | Worker.Push { payload = Graph_service.Graph_push push; _ } ->
      Journal_media_runtime.refresh media_runtime;
      let snapshot = !state_ref in
      if snapshot.graph_state.phase = Graph_open
      then
        refresh_assets ~graph_generation:snapshot.graph_state.generation snapshot.calendar;
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
        then Effect.ignore
        else (
          let prepare =
            if output.requests <> []
            then
              set_state (fun state ->
                { state with
                  next_request_generation =
                    Int64.max state.next_request_generation (Int64.succ generation)
                })
            else Effect.ignore
          in
          Effect.many
            [ admission_refresh
            ; Effect.bind prepare ~f:(fun () ->
                Effect.bind
                  (Effect.of_thunk (fun () -> deliver_output output))
                  ~f:(fun delivery ->
                    set_state (fun state ->
                      let state =
                        List.fold_left apply_worker_response state delivery.responses
                      in
                      match delivery.error with
                      | Some message -> fail_feed_transport state message
                      | None -> state)))
            ]))
    | Worker.Response
        { request_id = worker_id
        ; outcome = Worker.Completed (Graph_service.Graph_response response)
        ; _
        }
      when Hashtbl.mem asset_worker_requests worker_id ->
      Hashtbl.remove asset_worker_requests worker_id;
      ignore (Journal_asset_runtime.receive asset_runtime response : bool);
      Effect.ignore
    | Worker.Response
        { request_id
        ; outcome = Worker.Completed (Graph_service.Graph_response response)
        ; _
        } ->
      Hashtbl.remove admission_worker_requests request_id;
      Hashtbl.remove favorites_worker_requests request_id;
      let output = Journal_graph_runtime.receive graph_runtime response in
      Effect.bind
        (Effect.of_thunk (fun () -> deliver_output output))
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
                     | None -> Root_navigation.step state (Completed response), effects
                     | Some (request, result) ->
                       let admission_refresh, directive =
                         Admission_refresh.complete
                           state.admission_refresh
                           ~request
                           ~result
                       in
                       ( { state with admission_refresh }
                       , run_admission_directive set_state_and_effect directive :: effects
                       ))
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
              state, Effect.many (List.rev effects))
          in
          Effect.bind update ~f:(fun () ->
            let refresh_after_worker_event =
              let (Logseq_db_worker.Protocol.V2_response { outcome; _ }) = response in
              match outcome with
              | V2_mutation_committed _ ->
                let snapshot = !state_ref in
                trigger_admission
                  set_state_and_effect
                  ~graph_generation:snapshot.graph_state.generation
                  ~graph_open:(snapshot.graph_state.phase = Graph_open)
              | _ -> Effect.ignore
            in
            refresh_after_worker_event))
    | Worker.Push { payload = Asset_notice (scope, notice); _ } ->
      Journal_asset_runtime.notice asset_runtime scope notice;
      Journal_media_runtime.notice media_runtime scope notice;
      Effect.many
        [ flush_media set_state
        ; set_state (fun state ->
            { state with
              uploads =
                Journal_uploads.notice
                  (Journal_uploads.sync state.uploads (upload_context state))
                  scope
                  notice
            })
        ]
    | Worker.Response { request_id; outcome = Completed (Asset_imported result); _ } ->
      let pending = Hashtbl.find_opt import_worker_requests request_id in
      Hashtbl.remove import_worker_requests request_id;
      let current =
        match pending with
        | Some (generation, _) ->
          let snapshot = !state_ref in
          generation = snapshot.graph_state.generation
          &&
            (match result, Journal_routes.detail snapshot.routes with
            | Ok receipt, Some detail ->
              Journal_model.id (Journal_detail.root detail)
              = Logseq_db_types.Graph_types.Uuid.to_string receipt.target
            | Error _, _ -> true
            | _ -> false)
        | None -> false
      in
      Effect.bind
        (Effect.of_thunk (fun () ->
           sync_media !state_ref;
           Result.iter (Journal_media_runtime.imported media_runtime ~current) result))
        ~f:(fun () ->
          Effect.many
            [ flush_media set_state
            ; (match pending with
               | None -> Effect.ignore
               | Some (generation, operation) ->
                 set_state (fun state ->
                   if state.graph_state.generation <> generation
                   then state
                   else
                     { state with
                       import_completion =
                         Some
                           ( operation
                           , match result with
                             | Ok _ -> None
                             | Error message -> Some message )
                     }))
            ])
    | Worker.Response { request_id; outcome = Failed _ | Cancelled | Shutdown; _ }
      when Hashtbl.mem import_worker_requests request_id ->
      let generation, operation = Hashtbl.find import_worker_requests request_id in
      Hashtbl.remove import_worker_requests request_id;
      set_state (fun state ->
        if state.graph_state.generation <> generation
        then state
        else
          { state with
            import_completion =
              Some (operation, Some "Import was interrupted. Select the file again.")
          })
    | Worker.Response { outcome = Completed (Asset_file _); _ } -> Effect.ignore
    | Worker.Response { outcome = Completed Client_command_completed; _ } -> Effect.ignore
    | Worker.Response { outcome = Completed (Graph_state graph_state); _ }
    | Worker.Push { payload = Graph_state_changed graph_state; _ } ->
      observe_graph_state set_state set_state_and_effect graph_state
    | Worker.Push { payload = Client_state_changed manager_state; _ } ->
      apply_manager_transition set_state set_state_and_effect manager_state
    | Worker.Push { payload = Need_id_token challenge; _ } ->
      platform_request (Journal_platform.id_token_request challenge) ~f:(function
        | Error _ -> send_manager (Graph_service.Reject_token challenge)
        | Ok payload ->
          let challenge_id = Graph_service.token_request_id challenge in
          (match Journal_platform.decode_id_token_response ~challenge_id payload with
           | Error _ -> send_manager (Graph_service.Reject_token challenge)
           | Ok token ->
             send_manager (Graph_service.Provide_token { request = challenge; token })))
    | Worker.Push { payload = Bootstrap_progress progress; _ } ->
      set_state (fun state ->
        match state.manager with
        | Some manager when manager.selected_graph = Some progress.graph_id ->
          { state with bootstrap_progress = Some progress }
        | None | Some _ -> state)
    | Worker.Response { request_id; outcome = Failed _ | Cancelled | Shutdown; _ }
      when Hashtbl.mem asset_worker_requests request_id ->
      let protocol_id = Hashtbl.find asset_worker_requests request_id in
      Hashtbl.remove asset_worker_requests request_id;
      Journal_asset_runtime.reject asset_runtime ~request_id:protocol_id;
      Effect.ignore
    | Worker.Response { request_id; outcome = Failed _ | Cancelled | Shutdown; _ }
      when Hashtbl.mem favorites_worker_requests request_id ->
      let request, protocol_request = Hashtbl.find favorites_worker_requests request_id in
      Journal_graph_runtime.abandon graph_runtime protocol_request;
      Hashtbl.remove favorites_worker_requests request_id;
      set_state (fun state ->
        favorites_event
          state
          (Failed (request, false, "Favorites read was interrupted. Try again.")))
    | Worker.Response { request_id; outcome = Failed _ | Cancelled | Shutdown; _ }
      when Hashtbl.mem admission_worker_requests request_id ->
      let request, protocol_request = Hashtbl.find admission_worker_requests request_id in
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
        let state = record_worker_error state ~operation:"handleRequest" worker_error in
        match state.feed_refresh with
        | Some _ ->
          show_sync_error
            { state with feed_refresh = None }
            (Worker_sync_failure (latest_worker_error state))
        | None ->
          fail_active_mutation state (Worker_capture_failure (latest_worker_error state)))
    | Worker.Response { outcome = Cancelled | Shutdown; _ } ->
      set_state (fun state ->
        match state.feed_refresh with
        | Some _ ->
          show_sync_error
            { state with feed_refresh = None }
            (Non_worker_sync_failure "Worker unavailable")
        | None -> fail_active_mutation state (Local_capture_failure "Worker unavailable"))
    | Worker.Terminal { error; _ } ->
      set_state (fun state ->
        let worker_error = service_error ~operation:"terminal" error in
        record_worker_error state ~operation:"terminal" worker_error
        |> fun state ->
        terminal_graph_state state (Worker_graph_error (latest_worker_error state)))
  in
  let install_calendar set_state calendar =
    Journal_graph_runtime.set_calendar graph_runtime calendar;
    let snapshot = !state_ref in
    if snapshot.graph_state.phase = Graph_open
    then refresh_assets ~graph_generation:snapshot.graph_state.generation (Some calendar);
    set_state (fun state ->
      match state.calendar with
      | Some current when not (Journal_calendar.is_newer ~than:current calendar) -> state
      | None | Some _ ->
        let graph_error =
          match state.graph_error with
          | Some (Calendar_startup_failure _) -> None
          | other -> other
        in
        { state with calendar = Some calendar; graph_error })
  in
  let calendar_foreground = ref true in
  let sample_calendar () =
    Effect.of_thunk (fun () -> Journal_calendar.Sampler.sample calendar_sampler)
  in
  let apply_network_lifecycle payload =
    match Journal_platform.decode_network_lifecycle payload with
    | Error _ -> Effect.ignore
    | Ok (Backgrounded _) ->
      calendar_foreground := false;
      send_manager (Graph_service.Set_foreground false)
    | Ok (Foreground_resumed _) ->
      calendar_foreground := true;
      Effect.bind (sample_calendar ()) ~f:(function
        | Error error ->
          Effect.many
            [ set_state (fun state ->
                { state with graph_error = Some (Calendar_startup_failure error) })
            ; send_manager (Graph_service.Set_foreground true)
            ]
        | Ok calendar ->
          Effect.bind (install_calendar set_state calendar) ~f:(fun () ->
            send_manager (Graph_service.Set_foreground true)))
  in
  let apply_authenticated_user payload =
    match Journal_platform.decode_authenticated_user payload with
    | Error _ -> Effect.ignore
    | Ok user_id ->
      (match user_id with
       | None -> sign_out_in_flight := true
       | Some _ -> ());
      send_manager (Graph_service.Reconcile_authenticated_user { user_id })
  in
  let apply_local_account_binding result =
    match result with
    | Error _ -> Effect.ignore
    | Ok payload ->
      (match Journal_platform.decode_local_account_binding payload with
       | Error _ | Ok None -> Effect.ignore
       | Ok (Some binding) ->
         if String.equal binding.managed_sync_origin !managed_sync_origin
         then
           send_manager
             (Graph_service.Restore_local_account { user_id = binding.user_id })
         else Effect.ignore)
  in
  let apply_platform payload =
    if Journal_platform.is_prepare_to_terminate_event payload
    then
      if local_deletion_active !state_ref
      then
        platform_request Journal_platform.termination_ready_request ~f:(fun _ ->
          Effect.ignore)
      else (
        termination_in_flight := true;
        send_manager Graph_service.Return_to_graph_picker)
    else (
      match Journal_platform.decode_network_lifecycle payload with
      | Ok _ -> apply_network_lifecycle payload
      | Error _ -> apply_authenticated_user payload)
  in
  let managed_startup =
    if not !managed_sync_startup
    then Effect.ignore
    else
      platform_request Journal_platform.local_account_binding_request ~f:(fun binding ->
        Effect.bind (apply_local_account_binding binding) ~f:(fun () ->
          platform_request Journal_platform.authenticated_user_request ~f:(function
            | Error _ -> Effect.ignore
            | Ok payload -> apply_authenticated_user payload)))
  in
  let calendar_startup =
    Effect.bind (sample_calendar ()) ~f:(function
      | Error error ->
        set_state (fun state ->
          { state with graph_error = Some (Calendar_startup_failure error) })
      | Ok calendar ->
        Effect.bind (install_calendar set_state calendar) ~f:(fun () -> managed_startup))
  in
  let calendar_tick_effect () : unit Effect.t =
    Effect.bind
      (Effect.of_thunk (fun () ->
         if (not !calendar_foreground) || !termination_in_flight
         then None
         else (
           match Journal_calendar.Sampler.sample calendar_sampler with
           | Error _ -> None
           | Ok calendar ->
             (match !state_ref.calendar with
              | Some previous
                when Journal_calendar.classify_change ~previous calendar
                     = Current_time_changed -> None
              | None | Some _ -> Some calendar))))
      ~f:(function
        | None -> Effect.ignore
        | Some calendar -> install_calendar set_state calendar)
  in
  let feed_key state =
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
        | Some (_, Feed { before_day = Some _ }) | Some (_, Day _) | None -> false
      then None
      else Some context
    | false, _ | true, None -> None
  in
  let prev_feed_key = ref (feed_key initial_state) in
  let feed_callback key =
    let snapshot = !state_ref in
    match key with
    | None -> Effect.ignore
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
      Effect.bind prepare ~f:(fun () ->
        Effect.bind
          (Effect.of_thunk (fun () -> deliver_output output))
          ~f:(fun delivery ->
            set_state (fun state ->
              let state =
                List.fold_left
                  (fun state response -> Root_navigation.step state (Completed response))
                  state
                  delivery.responses
              in
              match delivery.error with
              | Some message -> fail_feed_transport state message
              | None -> state)))
  in
  let timeline_presentation_key state =
    match state.feed_loaded, state.manager with
    | true, Some snapshot when snapshot.timeline_presentation_pending ->
      Some (snapshot.selected_graph, snapshot.applied_server_t)
    | false, _ | true, None | true, Some _ -> None
  in
  let prev_timeline_presentation_key = ref (timeline_presentation_key initial_state) in
  let timeline_presentation_callback = function
    | None -> Effect.ignore
    | Some _ ->
      Effect.bind (send_manager Graph_service.Acknowledge_local_feed) ~f:(fun () ->
        platform_request Journal_platform.timeline_presented_request ~f:(function
          | Error _ -> Effect.ignore
          | Ok payload ->
            (match Journal_platform.decode_timeline_presented payload with
             | Error _ -> Effect.ignore
             | Ok () -> send_manager Graph_service.Acknowledge_timeline_presented)))
  in
  let favorites_drain_key state = state.favorites_requests in
  let prev_favorites_drain_key = ref (favorites_drain_key initial_state) in
  let favorites_drain_callback requests =
    let deliver (request : Journal_graph_request.favorites_request) =
      if request.graph_generation <> !state_ref.graph_state.generation
      then Effect.ignore
      else
        Effect.bind
          (Effect.of_thunk (fun () ->
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
                  (fun state response -> Root_navigation.step state (Completed response))
                  state
                  delivery.responses
              in
              match delivery.error with
              | None -> state
              | Some message -> favorites_event state (Failed (request, false, message))))
    in
    Effect.bind
      (set_state (fun state ->
         { state with
           favorites_requests =
             List.filter
               (fun request -> not (List.mem request requests))
               state.favorites_requests
         }))
      ~f:(fun () -> Effect.many (List.map deliver requests))
  in
  let timeline_drain_key state =
    if not (state.graph_ready && state.feed_loaded)
    then None
    else
      Option.map
        (fun request -> state.next_request_generation, request)
        (Journal_timeline_state.next_request state.timeline)
  in
  let prev_timeline_drain_key = ref (timeline_drain_key initial_state) in
  let timeline_drain_callback = function
    | None -> Effect.ignore
    | Some (generation, request) ->
      let output = submit (worker_request generation request) in
      Effect.bind
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
          Effect.bind
            (Effect.of_thunk (fun () -> deliver_output output))
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
                | _ -> state)))
  in
  let prev_upload_key = ref (upload_context initial_state) in
  let upload_callback () =
    Effect.run
      (set_state (fun state ->
         { state with
           uploads = Journal_uploads.sync state.uploads (upload_context state)
         }))
  in
  let prev_media_key = ref (media_key initial_state) in
  let media_callback () =
    Effect.run
      (Effect.bind
         (Effect.of_thunk (fun () -> sync_media !state_ref))
         ~f:(fun () -> flush_media set_state))
  in
  let delete_timer_generation = ref 0 in
  let schedule_after span thunk =
    ignore
      (Thread.create
         (fun () ->
            if span > 0. then Unix.sleepf span;
            if !running then Journal_pump.enqueue pump thunk)
         ())
  in
  let arm_delete_timer mutation_id deadline =
    incr delete_timer_generation;
    let generation = !delete_timer_generation in
    let remaining = Core.Time_ns.(Span.to_sec (diff deadline (now ()))) in
    schedule_after remaining (fun () ->
      if !delete_timer_generation = generation
      then
        Effect.run
          (set_state_and_effect (fun state ->
             match state.pending_delete with
             | Some ({ phase = Undoable; _ } as pending)
               when String.equal pending.mutation_id mutation_id ->
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
             | None | Some _ -> state, Effect.ignore)))
  in
  let delete_timer_key state =
    match state.pending_delete with
    | Some { mutation_id; deadline; phase = Undoable; _ } -> Some (mutation_id, deadline)
    | Some _ | None -> None
  in
  let prev_delete_timer_key = ref (delete_timer_key initial_state) in
  let sync_error_timer_generation = ref 0 in
  let arm_sync_error_timer sequence =
    incr sync_error_timer_generation;
    let generation = !sync_error_timer_generation in
    schedule_after (Core.Time_ns.Span.to_sec sync_error_card_lifetime) (fun () ->
      if !sync_error_timer_generation = generation
      then
        send_action
          (Update
             (fun state ->
               ( (match state.sync_error with
                  | Some { sequence = current; _ } when Int64.equal current sequence ->
                    { state with sync_error = None }
                  | None | Some _ -> state)
               , Effect.ignore ))))
  in
  let prev_sync_error_key =
    ref (Option.map (fun notice -> notice.sequence) initial_state.sync_error)
  in
  let handle_dispatch payload =
    let snapshot = !state_ref in
    let current_time : Core.Time_ns.t Effect.t = fun () -> Core.Time_ns.now () in
    let update f = set_state f in
    let with_request next request =
      Effect.many [ update (fun _ -> next); send request ]
    in
    let with_direct_request next request =
      Effect.bind (update (fun _ -> next)) ~f:(fun () -> send request)
    in
    let open_block block_id =
      let generation = snapshot.next_request_generation in
      let routes =
        Journal_routes.open_detail
          snapshot.routes
          ~block_id
          ~request_generation:generation
      in
      with_direct_request
        { snapshot with routes; next_request_generation = Int64.succ generation }
        (Journal_graph_request.Load_detail
           { block_id; after = None; limit = 64; request_generation = generation })
    in
    let open_favorite membership_id =
      match
        List.find_opt
          (fun (item : Logseq_db_worker.Protocol.v2_favorite_item) ->
             Logseq_db_types.Graph_types.Uuid.to_string item.membership_uuid
             = membership_id)
          (Journal_routes.Favorites.items snapshot.favorites)
      with
      | Some item ->
        let routes, request =
          Journal_routes.open_favorite
            snapshot.routes
            ~request_generation:snapshot.next_request_generation
            item
        in
        (match request with
         | None -> Effect.ignore
         | Some request ->
           with_direct_request
             { snapshot with
               routes
             ; next_request_generation = Int64.succ snapshot.next_request_generation
             }
             request)
      | None -> Effect.ignore
    in
    let detail_event event =
      match Journal_routes.detail snapshot.routes with
      | None -> Effect.ignore
      | Some detail ->
        let detail, requests = Journal_detail.step detail event in
        Effect.bind
          (update (fun state ->
             { state with routes = Journal_routes.update_detail state.routes detail }))
          ~f:(fun () -> Effect.many (List.map send requests))
    in
    let update_draft ~toggle source =
      if
        (not snapshot.write_enabled)
        || snapshot.pending_delete <> None
        || snapshot.pending_status <> None
      then Effect.ignore
      else
        update (fun state ->
          match Journal_routes.detail state.routes with
          | None -> state
          | Some detail ->
            let detail = Journal_detail.update_child_source detail source in
            let detail =
              if toggle then Journal_detail.toggle_child_task detail else detail
            in
            { state with routes = Journal_routes.update_detail state.routes detail })
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
      | true, None, None, None -> Effect.ignore
      | true, None, None, Some _ ->
        let capture =
          match snapshot.direct_capture with
          | None ->
            Journal_capture.create ~session_number:snapshot.next_local_sequence ~source
          | Some capture -> Journal_capture.update_source capture ~source
        in
        (match Journal_capture.phase capture with
         | Saving -> Effect.ignore
         | Failed _ ->
           let capture, request = Journal_capture.retry capture in
           (match request with
            | None -> Effect.ignore
            | Some request ->
              with_direct_request
                (Root_navigation.step snapshot (Capture_admitted capture))
                request)
         | Editing ->
           if String.equal (String.trim source) ""
           then Effect.ignore
           else (
             match Journal_calendar.Sampler.sample calendar_sampler with
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
                | Ok (_, None) -> Effect.ignore
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
    let payload =
      match payload with
      | Ui.Event.Payload.Text action
        when String.starts_with ~prefix:"media-session:" action ->
        let prefix = "media-session:" ^ media_scope snapshot ^ ":" in
        if String.starts_with ~prefix action
        then
          Ui.Event.Payload.Text
            (String.sub
               action
               (String.length prefix)
               (String.length action - String.length prefix))
        else Ui.Event.Payload.Unit
      | Ui.Event.Payload.Text action
        when String.starts_with ~prefix:"detail-session:" action ->
        let prefix = Detail_outline.scope snapshot.routes in
        if String.starts_with ~prefix action
        then
          Ui.Event.Payload.Text
            (String.sub
               action
               (String.length prefix)
               (String.length action - String.length prefix))
        else Ui.Event.Payload.Unit
      | payload -> payload
    in
    match payload with
    | payload
      when local_deletion_active snapshot
           &&
           match payload with
           | Ui.Event.Payload.Text ("open-diagnostics" | "close-diagnostics")
           | Ui.Event.Payload.Navigation_path_changed _ -> false
           | Ui.Event.Payload.Text text
             when String.starts_with ~prefix:"asset-settings:" text -> false
           | _ -> true -> Effect.ignore
    | Ui.Event.Payload.Text "open-asset-settings" ->
      update (fun state -> { state with asset_settings_open = true })
    | Ui.Event.Payload.Text text when String.starts_with ~prefix:"asset-settings:" text ->
      (match
         Journal_asset_settings.decode (String.sub text 15 (String.length text - 15))
       with
       | None -> Effect.ignore
       | Some Dismissed ->
         update (fun state -> { state with asset_settings_open = false })
       | Some (Retry_upload operation) ->
         if local_deletion_active snapshot
         then Effect.ignore
         else
           Effect.of_thunk (fun () ->
             let current = !state_ref in
             let uploads =
               Journal_uploads.sync current.uploads (upload_context current)
             in
             Option.iter
               (fun request -> ignore (Worker.send client request : Worker.send_result))
               (Journal_uploads.retry uploads operation))
       | Some (Days settings) ->
         Effect.of_thunk (fun () ->
           asset_settings := Some settings;
           let current = !state_ref in
           if current.graph_state.phase = Graph_open
           then
             refresh_assets
               ~graph_generation:current.graph_state.generation
               current.calendar))
    | Ui.Event.Payload.Confirmation_response response ->
      set_state_and_effect (fun state ->
        match state.modal with
        | Cache_reset_confirmation graph_id
          when response.token = state.confirmation_sequence ->
          (match response.result with
           | Action "delete" when local_deletion_available state ->
             ( Root_navigation.step state Local_copy_deleted
             , send_manager (Graph_service.Delete_local_cache graph_id) )
           | Action "cancel" | Dismissed -> { state with modal = No_modal }, Effect.ignore
           | Action _ -> state, Effect.ignore)
        | _ -> state, Effect.ignore)
    | Ui.Event.Payload.Text_edit edit ->
      update (fun state ->
        match state.modal, state.manager with
        | Capture_sheet, _ -> Root_navigation.step state (Capture_native_edit edit)
        | Append_sheet, _ ->
          (match Journal_routes.detail state.routes with
           | None -> state
           | Some detail ->
             { state with
               routes =
                 Journal_routes.update_detail
                   state.routes
                   (Journal_detail.apply_child_edit detail edit)
             })
        | _, Some { startup = { awaiting_e2ee_password = true; _ }; _ }
        | _, Some { startup = { failure = Some During_e2ee; _ }; _ } ->
          { state with
            e2ee_password = Journal_capture.apply_text_edit state.e2ee_password edit
          }
        | _ -> state)
    | Ui.Event.Payload.Text "capture-submit" ->
      (match snapshot.modal, snapshot.direct_capture with
       | Capture_sheet, Some capture ->
         admit_direct_capture (Journal_capture.source capture)
       | _ -> Effect.ignore)
    | Ui.Event.Payload.Text "select-journals" ->
      update (fun state -> Root_navigation.step state (Select Journal_routes.Journals))
    | Ui.Event.Payload.Text "select-favorites" ->
      update (fun state -> Root_navigation.step state (Select Journal_routes.Favorites))
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
      Effect.ignore
    | Ui.Event.Payload.Visible_range range ->
      let observe timeline =
        let total_count = Journal_timeline_state.total_count timeline in
        let bounded value =
          value |> Int64.max 0L |> Int64.min (Int64.of_int total_count) |> Int64.to_int
        in
        let first_index = bounded range.first_index in
        let last_exclusive = bounded range.last_exclusive in
        Journal_timeline_state.observe_visible_range timeline ~first_index ~last_exclusive
      in
      (* Redelivery does not change the pure timeline. Avoid scheduling a
             no-op model update, which would recreate native menu bindings. *)
      if observe snapshot.timeline = snapshot.timeline
      then Effect.ignore
      else update (fun state -> { state with timeline = observe state.timeline })
    | Ui.Event.Payload.Navigation_path_changed [] -> update back_state
    | Ui.Event.Payload.Bool false ->
      update (fun state ->
        match state.modal with
        | Diagnostics ->
          { state with
            modal = No_modal
          ; admission_refresh = Admission_refresh.close state.admission_refresh
          }
        | No_modal -> state
        | Capture_sheet
        | Append_sheet
        | Status_sheet _
        | Error_info
        | Cache_reset_confirmation _ -> { state with modal = No_modal })
    | Ui.Event.Payload.Text action ->
      if String.starts_with ~prefix:"media:" action
      then
        Effect.bind
          (Effect.of_thunk (fun () ->
             sync_media snapshot;
             try
               let json =
                 Yojson.Basic.from_string (String.sub action 6 (String.length action - 6))
               in
               let field name = Yojson.Basic.Util.member name json in
               let text name = Yojson.Basic.Util.to_string (field name) in
               let root = text "root" in
               let visible = Yojson.Basic.Util.to_bool (field "visible") in
               match text "action" with
               | "root" -> Journal_media_runtime.root_visible media_runtime ~root visible
               | "asset" ->
                 Journal_media_runtime.asset_visible
                   media_runtime
                   ~root
                   ~asset:(text "asset")
                   visible
               | "retry" ->
                 Journal_media_runtime.retry media_runtime ~root ~asset:(text "asset")
               | "next" -> Journal_media_runtime.next media_runtime ~root
               | "replace" -> Journal_media_runtime.begin_replace media_runtime ~root
               | "reuse" -> Journal_media_runtime.begin_reuse media_runtime ~root
               | "reuse-select" ->
                 Journal_media_runtime.reuse_select
                   media_runtime
                   ~root
                   ~asset:(text "asset")
               | "reuse-next" -> Journal_media_runtime.reuse_next media_runtime ~root
               | "reuse-cancel" -> Journal_media_runtime.end_reuse media_runtime ~root
               | _ -> ()
             with
             | _ -> ()))
          ~f:(fun () -> flush_media set_state)
      else if String.starts_with ~prefix:"import-asset:" action
      then (
        let import_payload = String.sub action 13 (String.length action - 13) in
        if Journal_asset_import.is_dismissal import_payload
        then update (fun state -> { state with pending_replace = None })
        else (
          match Journal_routes.detail snapshot.routes with
          | None -> Effect.ignore
          | Some detail ->
            let target =
              Logseq_db_types.Graph_types.Uuid.of_string
                (Journal_model.id (Journal_detail.root detail))
            in
            let source =
              Result.bind target (fun target ->
                Journal_asset_import.decode ~target import_payload)
            in
            (match source with
             | Error _ -> update (fun state -> { state with pending_replace = None })
             | Ok source ->
               let operation =
                 Logseq_db_types.Graph_types.Uuid.to_string source.operation
               in
               let graph_generation = snapshot.graph_state.generation in
               Effect.many
                 [ update (fun state -> { state with pending_replace = None })
                 ; Effect.bind
                     (Effect.of_thunk (fun () ->
                        if not snapshot.write_enabled
                        then Some "The destination is not ready for imports"
                        else (
                          match
                            Worker.send
                              client
                              (Graph_service.Import_asset { graph_generation; source })
                          with
                          | Accepted id ->
                            Hashtbl.replace
                              import_worker_requests
                              id
                              (graph_generation, operation);
                            None
                          | Full | Not_ready | Stopping ->
                            Some
                              "Import is temporarily unavailable. Select the file again.")))
                     ~f:(function
                       | None -> Effect.ignore
                       | Some message ->
                         update (fun state ->
                           { state with
                             import_completion = Some (operation, Some message)
                           }))
                 ])))
      else if String.length action > 13 && String.sub action 0 13 = "select-graph:"
      then (
        let graph_id = String.sub action 13 (String.length action - 13) in
        match Logseq_db_types.Graph_types.Uuid.of_string graph_id with
        | Error _ -> Effect.ignore
        | Ok graph_id -> send_manager (Graph_service.Select_graph graph_id))
      else if String.equal action "refresh-catalog"
      then send_manager Graph_service.Refresh_catalog
      else if String.equal action "begin-online-recovery"
      then send_manager Graph_service.Begin_online_recovery
      else if
        String.equal action "open-capture"
        && snapshot.write_enabled
        && snapshot.pending_delete = None
        && snapshot.pending_status = None
      then update (fun state -> Root_navigation.step state Capture_opened)
      else if String.equal action "close-composer"
      then update (fun state -> { state with modal = No_modal })
      else if
        String.equal action "capture-task-on" || String.equal action "capture-task-off"
      then
        update (fun state ->
          Root_navigation.step state (Capture_task_intent (action = "capture-task-on")))
      else if
        String.equal action "open-append"
        && snapshot.write_enabled
        && snapshot.pending_delete = None
        && snapshot.pending_status = None
      then
        update (fun state ->
          match Journal_routes.detail state.routes with
          | None -> state
          | Some detail ->
            let detail =
              if Journal_detail.child_capture detail = None
              then Journal_detail.update_child_source detail ""
              else detail
            in
            { state with
              modal = Append_sheet
            ; routes = Journal_routes.update_detail state.routes detail
            })
      else if String.equal action "close-status"
      then
        update (fun state ->
          match state.modal with
          | Status_sheet _ -> { state with modal = No_modal }
          | _ -> state)
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
          if
            state.worker_errors = []
            && Option.is_none
                 (Option.bind state.manager (fun manager -> manager.last_error))
            && Option.is_none (operation_failure state.timeline_notice)
          then state
          else { state with modal = Error_info })
      else if String.equal action "dismiss-operation-error"
      then
        update (fun state ->
          match state.timeline_notice with
          | Some (Delete_failed _ | Status_failed _) ->
            { state with timeline_notice = None }
          | None | Some Delete_undo -> state)
      else if String.equal action "close-error-info"
      then update (fun state -> { state with modal = No_modal })
      else if String.equal action "switch-graph"
      then
        Effect.many
          [ update (fun state -> { state with modal = No_modal })
          ; send_manager Graph_service.Return_to_graph_picker
          ]
      else if String.equal action "sign-out"
      then (
        sign_out_in_flight := true;
        Effect.many
          [ update (fun state -> Root_navigation.step state Account_cleared)
          ; send_manager (Graph_service.Reconcile_authenticated_user { user_id = None })
          ])
      else if String.equal action "submit-e2ee-password"
      then (
        let password = Journal_capture.source snapshot.e2ee_password in
        if String.equal (String.trim password) ""
        then Effect.ignore
        else
          Effect.many
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
          | Some { selected_graph = Some graph_id; _ } when local_deletion_available state
            ->
            { state with
              modal = Cache_reset_confirmation graph_id
            ; confirmation_sequence = Int64.succ state.confirmation_sequence
            }
          | None | Some _ -> state)
      else if String.equal action "delete-undo"
      then
        update (fun state ->
          match state.pending_delete with
          | Some ({ phase = Undoable; _ } as pending) ->
            { (restore_deleted state pending) with
              pending_delete = None
            ; timeline_notice = None
            }
          | None | Some { phase = Committing; _ } -> state)
      else if String.equal action "back"
      then update back_state
      else if String.starts_with ~prefix:"timeline-retry:" action
      then (
        match int_of_string_opt (String.sub action 15 (String.length action - 15)) with
        | None -> Effect.ignore
        | Some day ->
          update (fun state ->
            { state with timeline = Journal_timeline_state.retry_day state.timeline ~day }))
      else if String.starts_with ~prefix:"detail-expand:" action
      then
        detail_event
          (Set_branch_expanded (String.sub action 14 (String.length action - 14), true))
      else if String.starts_with ~prefix:"detail-collapse:" action
      then
        detail_event
          (Set_branch_expanded (String.sub action 16 (String.length action - 16), false))
      else if String.starts_with ~prefix:"detail-more:" action
      then detail_event (Load_more (String.sub action 12 (String.length action - 12)))
      else if String.starts_with ~prefix:"detail-draft:" action
      then update_draft ~toggle:false (String.sub action 13 (String.length action - 13))
      else if String.starts_with ~prefix:"detail-task-intent:" action
      then update_draft ~toggle:true (String.sub action 19 (String.length action - 19))
      else if String.equal action "detail-retry"
      then (
        match Journal_routes.detail snapshot.routes with
        | None ->
          (match Journal_routes.detail_block_id snapshot.routes with
           | Some id -> open_block id
           | None -> Effect.ignore)
        | Some detail ->
          let number = snapshot.next_local_sequence in
          let detail, request = Journal_detail.retry detail in
          (match request with
           | None -> Effect.ignore
           | Some request ->
             with_direct_request
               { snapshot with
                 routes = Journal_routes.update_detail snapshot.routes detail
               ; next_local_sequence = Int64.succ number
               }
               request))
      else if
        String.starts_with ~prefix:"detail-submit:" action
        && snapshot.write_enabled
        && snapshot.pending_delete = None
        && snapshot.pending_status = None
      then (
        match Journal_routes.detail snapshot.routes, snapshot.calendar with
        | Some detail, Some _ ->
          let detail =
            Journal_detail.update_child_source
              detail
              (String.sub action 14 (String.length action - 14))
          in
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
                   if
                     match Journal_detail.mode detail with
                     | Failed _ -> true
                     | _ -> false
                   then Journal_detail.retry detail
                   else
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
              | Ok (_, None) -> Effect.ignore
              | Ok (detail, Some request) ->
                with_direct_request
                  { snapshot with
                    calendar = Some calendar
                  ; routes = Journal_routes.update_detail snapshot.routes detail
                  ; capture_error = None
                  ; next_local_sequence = Int64.succ number
                  }
                  request))
        | None, _ | _, None -> Effect.ignore)
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
        | true, None, None, None -> Effect.ignore)
      else if String.length action > 20 && String.sub action 0 20 = "status-sheet-select:"
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
           | Some block when Journal_model.task_state block = task_state -> Effect.ignore
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
        | Capture_sheet, _, _, _, _
        | Append_sheet, _, _, _, _
        | Diagnostics, _, _, _, _
        | Error_info, _, _, _, _
        | Cache_reset_confirmation _, _, _, _, _
        | Status_sheet _, false, _, _, _
        | Status_sheet _, true, Some _, _, _
        | Status_sheet _, true, None, Some _, _
        | Status_sheet _, true, None, None, None -> Effect.ignore)
      else if
        String.starts_with ~prefix:"timeline-delete:" action
        || String.starts_with ~prefix:"detail-delete:" action
      then (
        let prefix_length =
          if String.starts_with ~prefix:"detail-delete:" action then 14 else 16
        in
        let block_id =
          String.sub action prefix_length (String.length action - prefix_length)
        in
        let block =
          match Journal_routes.detail snapshot.routes with
          | Some detail -> Journal_detail.find_block detail ~block_id
          | None -> block_in_timeline snapshot.timeline block_id
        in
        match
          snapshot.write_enabled, snapshot.pending_delete, snapshot.pending_status, block
        with
        | true, None, None, Some block ->
          let saving =
            Option.fold
              ~none:false
              ~some:(fun detail -> Journal_detail.mode detail = Saving_child)
              (Journal_routes.detail snapshot.routes)
          in
          if saving
          then Effect.ignore
          else (
            let duration =
              if snapshot.environment.accessible_navigation then 10. else 5.
            in
            Effect.bind current_time ~f:(fun now ->
              let pending =
                { mutation_id = fresh_identity ()
                ; block_id
                ; expected_revision = Journal_model.revision block
                ; staged = None
                ; detail_staged = None
                ; deadline = Core.Time_ns.add now (Core.Time_ns.Span.of_sec duration)
                ; phase = Undoable
                }
              in
              update (fun state ->
                hide_deleted { state with timeline_notice = Some Delete_undo } pending)))
        | _ -> Effect.ignore)
      else if String.starts_with ~prefix:"timeline-open-block:" action
      then open_block (String.sub action 20 (String.length action - 20))
      else if String.starts_with ~prefix:"favorite-open-block:" action
      then open_favorite (String.sub action 20 (String.length action - 20))
      else Effect.ignore
    | Ui.Event.Payload.Native_event _
    | Unit
    | Bool _
    | Int _
    | Int64 _
    | Int64_bool _
    | Navigation_path_changed _
    | Int64_pair _
    | Float _
    | Scroll _
    | Native_list_completion _
    | Event _ -> Effect.ignore
  in
  let dispatch =
    Ui.Event.Handler.create ~name:"journal-dispatch" (fun payload ->
      Effect.run (handle_dispatch payload))
  in
  let timeline_scroll_completed =
    Ui.Event.Handler.create ~name:"timeline-scroll-completed" (fun payload ->
      let generation = !state_ref.graph_state.generation in
      Effect.run
        (match V.Native_list.completion_of_payload payload with
         | None -> Effect.ignore
         | Some completion ->
           set_state (fun state ->
             if state.graph_state.generation <> generation
             then state
             else
               { state with
                 timeline =
                   Journal_timeline_state.complete_scroll
                     state.timeline
                     ~token:completion.token
                     ~outcome:completion.outcome
               })))
  in
  let detail_scroll_completed =
    Ui.Event.Handler.create ~name:"detail-scroll-completed" (fun payload ->
      let generation = !state_ref.graph_state.generation in
      let route = Journal_routes.detail_request_generation !state_ref.routes in
      Effect.run
        (match V.Native_list.completion_of_payload payload with
         | None -> Effect.ignore
         | Some completion ->
           set_state (fun state ->
             if
               state.graph_state.generation <> generation
               || Journal_routes.detail_request_generation state.routes <> route
             then state
             else (
               match Journal_routes.detail state.routes with
               | None -> state
               | Some detail ->
                 { state with
                   routes =
                     Journal_routes.update_detail
                       state.routes
                       (Journal_detail.complete_reveal
                          detail
                          ~token:completion.token
                          ~outcome:completion.outcome)
                 }))))
  in
  let notice_token_sequence = ref 0L in
  let notice_cancellation : int64 option ref = ref None in
  let cancel_notice token =
    emit_platform_request (Journal_platform.notice_cancel_request ~token)
  in
  let notice_callback ((undo_available, capture_error), accessible_navigation) =
    Option.iter cancel_notice !notice_cancellation;
    notice_cancellation := None;
    match capture_error, undo_available with
    | None, false -> ()
    | _, _ ->
      let token = Int64.succ !notice_token_sequence in
      notice_token_sequence := token;
      notice_cancellation := Some token;
      let message, action_label, duration_ms =
        match capture_error, undo_available with
        | Some failure, _ -> capture_failure_message failure, None, 4_000
        | None, true ->
          ( "Block and descendants removed"
          , Some "Undo"
          , if accessible_navigation then 10_000 else 5_000 )
        | None, false -> assert false
      in
      emit_platform_request
        (Journal_platform.show_notice_request ~token ~message ~action_label ~duration_ms)
        ~k:(fun result ->
          match result with
          | Error _ -> ()
          | Ok payload ->
            (match Journal_platform.decode_notice_response ~token payload with
             | Ok Notice_action ->
               Ui.Event.Handler.Private.invoke
                 dispatch
                 (Ui.Event.Payload.Text "delete-undo")
             | Ok (Notice_dismiss | Notice_swipe | Notice_timeout) | Error _ -> ()))
  in
  let notice_key state =
    ( (state.graph_ready && state.timeline_notice = Some Delete_undo, state.capture_error)
    , state.environment.accessible_navigation )
  in
  let prev_notice_key = ref (notice_key initial_state) in
  (* Every [Edge.on_change] of the bonsai version becomes a post-update key
     comparison: the key is recomputed from the new model and the callback
     fires when it differs from the previous post-update value. *)
  let run_edge_callbacks model =
    (let key = feed_key model in
     if not (Option.equal equal_feed_projection_context !prev_feed_key key)
     then (
       prev_feed_key := key;
       Effect.run (feed_callback key)));
    (let key = timeline_presentation_key model in
     if not (Option.equal ( = ) !prev_timeline_presentation_key key)
     then (
       prev_timeline_presentation_key := key;
       Effect.run (timeline_presentation_callback key)));
    (let key = favorites_drain_key model in
     if not (!prev_favorites_drain_key = key)
     then (
       prev_favorites_drain_key := key;
       Effect.run (favorites_drain_callback key)));
    (let key = timeline_drain_key model in
     if
       not
         (Option.equal
            (fun (left_generation, left_request) (right_generation, right_request) ->
               Int64.equal left_generation right_generation
               && left_request = right_request)
            !prev_timeline_drain_key
            key)
     then (
       prev_timeline_drain_key := key;
       Effect.run (timeline_drain_callback key)));
    (let key = upload_context model in
     if not (!prev_upload_key = key)
     then (
       prev_upload_key := key;
       upload_callback ()));
    (let key = media_key model in
     if not (!prev_media_key = key)
     then (
       prev_media_key := key;
       media_callback ()));
    (let key = notice_key model in
     if
       not
         ((fun (left_notice, left_accessible) (right_notice, right_accessible) ->
             left_notice = right_notice && Bool.equal left_accessible right_accessible)
            !prev_notice_key
            key)
     then (
       prev_notice_key := key;
       notice_callback key));
    (let key = delete_timer_key model in
     if
       not
         (Option.equal
            (fun (left_id, left_deadline) (right_id, right_deadline) ->
               String.equal left_id right_id
               && Core.Time_ns.equal left_deadline right_deadline)
            !prev_delete_timer_key
            key)
     then (
       prev_delete_timer_key := key;
       match key with
       | None -> incr delete_timer_generation
       | Some (mutation_id, deadline) -> arm_delete_timer mutation_id deadline));
    (let key = Option.map (fun notice -> notice.sequence) model.sync_error in
     if not (Option.equal Int64.equal !prev_sync_error_key key)
     then (
       prev_sync_error_key := key;
       match key with
       | None -> incr sync_error_timer_generation
       | Some sequence -> arm_sync_error_timer sequence));
    model
  in
  let update model = function
    | Update transition ->
      let model, eff = transition model in
      let model = track_capture_session model in
      state_ref := model;
      Effect.run eff;
      state_ref := model;
      let model = run_edge_callbacks model in
      state_ref := model;
      model
    | Platform_response (tag, result) ->
      (match Hashtbl.find_opt pending_platform tag with
       | Some k ->
         Hashtbl.remove pending_platform tag;
         k result
       | None -> ());
      model
    | Environment_changed snapshot -> { model with environment = snapshot }
  in
  let body_view state dispatch timeline_scroll_completed detail_scroll_completed =
    let tokens =
      Journal_visual_tokens.resolve
        ~brightness:state.environment.brightness
        ~high_contrast:state.environment.high_contrast
    in
    let capture_saving =
      match state.direct_capture with
      | Some capture -> Journal_capture.phase capture = Journal_capture.Saving
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
      | false, Some _ -> manager_page state dispatch
      | false, None | true, _ ->
        timeline_page
          ~render_media:(media_label state dispatch)
          ~platform:state.environment.platform
          ~graph_generation:state.graph_state.generation
          ~on_scroll_completed:timeline_scroll_completed
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
          ~timeline_state:state.timeline
          ~loading:(not state.feed_loaded)
          ~graph_error:(Option.map graph_error_message state.graph_error)
          ~sync_error
          ~sync_phase:
            (Option.map
               (fun (manager : Graph_service.snapshot) -> manager.sync_phase)
               state.manager)
          ~day_presentation:(presentation_for_day state)
          ~capture_enabled:
            (state.write_enabled
             && Option.is_none state.pending_delete
             && Option.is_none state.pending_status
             && not capture_saving)
          ~on_capture_event:dispatch
          ~on_visible_range:dispatch
          ~on_retry_day:(prefix_action dispatch "timeline-retry:")
          ~on_open_block:(prefix_action dispatch "timeline-open-block:")
          ~on_open_favorite:(prefix_action dispatch "favorite-open-block:")
          ~delete_enabled:state.write_enabled
          ~actions_enabled:row_actions_enabled
          ~interaction_enabled:(state.modal = No_modal)
          ~on_status:(prefix_action dispatch "timeline-status:")
          ~on_delete:(prefix_action dispatch "timeline-delete:")
          ~error_info_available:
            (state.worker_errors <> []
             || Option.is_some
                  (Option.bind state.manager (fun manager -> manager.last_error))
             || Option.is_some (operation_failure state.timeline_notice))
          ~on_error_info:(bind_action dispatch "open-error-info")
          ~account_menu_available:true
          ~on_account_action:dispatch
          ~cache_reset_available:(local_deletion_available state)
    in
    let root = operation_feedback ~scope:"root" ~state dispatch root in
    let path =
      match Journal_routes.route state.routes with
      | Journal_routes.Timeline -> []
      | Detail_loading | Detail | Missing_detail | Failed_detail _ ->
        [ V.Navigation_stack.destination
            ~page_key:"journal-detail-route"
            ~title:"Block"
            ~can_pop:true
            (detail_page ~state ~on_scroll_completed:detail_scroll_completed dispatch
             |> operation_feedback ~scope:"detail" ~state dispatch)
        ]
    in
    let modal =
      match state.modal with
      | No_modal -> None
      | Capture_sheet ->
        Option.map
          (fun capture ->
             composer_page
               ~scope:"journal-capture"
               ~saving:(Journal_capture.phase capture = Journal_capture.Saving)
               ~capture
               ~enabled:state.write_enabled
               ~on_edit:dispatch
               ~on_toggle:
                 (Ui.Event.Handler.create (function
                    | Ui.Event.Payload.Bool selected ->
                      Ui.Event.Handler.Private.invoke
                        dispatch
                        (Text (if selected then "capture-task-on" else "capture-task-off"))
                    | _ -> ()))
               ~on_save:(bind_action dispatch "capture-submit")
               ~on_close:(bind_action dispatch "close-composer")
               ~error:
                 (match state.capture_error with
                  | Some failure -> Some (capture_failure_message failure)
                  | None ->
                    (match Journal_capture.phase capture with
                     | Failed message -> Some message
                     | Editing | Saving -> None)))
          state.direct_capture
      | Append_sheet ->
        Option.bind (Journal_routes.detail state.routes) (fun detail ->
          Option.map
            (fun capture ->
               composer_page
                 ~scope:"journal-append"
                 ~saving:(Journal_detail.mode detail = Journal_detail.Saving_child)
                 ~capture
                 ~enabled:state.write_enabled
                 ~on_edit:dispatch
                 ~on_toggle:
                   (Ui.Event.Handler.create (function
                      | Ui.Event.Payload.Bool selected
                        when selected
                             <> (Journal_capture.task_state capture = Journal_model.Todo)
                        ->
                        Ui.Event.Handler.Private.invoke
                          dispatch
                          (Text
                             (Detail_outline.scope state.routes
                              ^ "detail-task-intent:"
                              ^ Journal_capture.source capture))
                      | _ -> ()))
                 ~on_save:
                   (bind_action
                      dispatch
                      (Detail_outline.scope state.routes
                       ^
                       match Journal_detail.mode detail with
                       | Failed _ -> "detail-retry"
                       | _ -> "detail-submit:" ^ Journal_capture.source capture))
                 ~on_close:(bind_action dispatch "close-composer")
                 ~error:
                   (match Journal_detail.mode detail with
                    | Failed message -> Some message
                    | _ -> Option.map capture_failure_message state.capture_error))
            (Journal_detail.child_capture detail))
      | Status_sheet block_id ->
        Option.map
          (fun block -> status_sheet_page ~tokens ~block dispatch)
          (block_in_timeline state.timeline block_id)
      | Cache_reset_confirmation _ -> None
      | Diagnostics ->
        Some
          (diagnostics_page
             ~snapshot:state.manager
             ~graph:state.graph_state
             ~admission:(Admission_refresh.observation state.admission_refresh)
             state.diagnostics
             dispatch)
      | Error_info ->
        Some
          (error_info_page
             ~sync_error:(Option.bind state.manager (fun manager -> manager.last_error))
             ~operation_failure:(operation_failure state.timeline_notice)
             (newest_first_worker_errors state)
             dispatch)
    in
    let body =
      let base =
        V.Navigation_stack.create
          ~key:(Ui.Key.string "journal-navigator")
          ~title:""
          ~on_path_change:dispatch
          ~path
          root
        |> Cache_confirmation.local_cache
             ~token:
               (match state.modal with
                | Cache_reset_confirmation _ -> Some state.confirmation_sequence
                | _ -> None)
             dispatch
      in
      let status =
        match state.modal with
        | Status_sheet _ -> true
        | _ -> false
      in
      let title =
        match state.modal with
        | No_modal -> ""
        | Capture_sheet -> "Capture"
        | Append_sheet -> "Append"
        | Status_sheet _ -> "Set status"
        | Cache_reset_confirmation _ -> "Delete local graph copy?"
        | Diagnostics -> "Diagnostics"
        | Error_info -> "Error info"
      in
      V.Sheet.create
        ~key:(Ui.Key.string "journal-sheet")
        ~presented:(Option.is_some modal)
        ~on_presented_changed:dispatch
        ~interactive_dismiss:true
        ~sizing:Form
        ~detents:(if status then [ Medium; Large ] else [ Large ])
        ~content:
          (match modal with
           | None -> V.empty ()
           | Some content ->
             V.Navigation_stack.create
               ~title
               ~on_path_change:(Ui.Event.Handler.create (fun _ -> ()))
               ~path:[]
               content)
        base
    in
    let body =
      Journal_asset_settings.view
        ~uploads:
          (Journal_uploads.rows
             (Journal_uploads.sync state.uploads (upload_context state)))
        ~offline:state.asset_offline
        ~presented:state.asset_settings_open
        ~on_event:(fun value ->
          Ui.Event.Handler.Private.invoke
            dispatch
            (Ui.Event.Payload.Text ("asset-settings:" ^ value)))
        body
    in
    V.Body.theme ~data:(application_theme ()) (V.Body.static body)
  in
  let view _context model_signal _send =
    (* Dynamic elements mount under a parent, so the root must be a static
       container. *)
    Lui_elements.stack
      [ Lui_elements.dyn
          (fun model ->
             Journal_view.mount
               (body_view
                  model
                  dispatch
                  timeline_scroll_completed
                  detail_scroll_completed))
          model_signal
      ]
  in
  let os =
    match platform_code with
    | 1 -> Lui_protocol.MacOS
    | 2 -> Lui_protocol.IOS
    | 3 -> Lui_protocol.AndroidOS
    | 4 -> Lui_protocol.LinuxOS
    | 5 -> Lui_protocol.WindowsOS
    | _ -> Lui_protocol.GenericOS
  in
  let host =
    match host_code with
    | 1 -> Lui_protocol.WebHost
    | 2 -> Lui_protocol.SwiftUIHost
    | 3 -> Lui_protocol.FlutterHost
    | _ -> Lui_protocol.GenericHost
  in
  let backend =
    { Lui_protocol.backend_profile = Lui_protocol.profile os host
    ; apply_batch =
        (fun batch ->
          latest_patch := Lui_wire.encode_batch batch;
          true)
    }
  in
  let app =
    Lui_app.create_with_extensions
      backend
      Journal_lui_native.registry
      initial_state
      update
      view
  in
  app_cell := Some app;
  let context = { app; pump; client; send_action; apply_platform; running } in
  current_app := Some context;
  ignore (Worker.send client Graph_service.Get_graph_state : Worker.send_result);
  Worker.on_event client (fun event ->
    Journal_pump.enqueue pump (fun () -> Effect.run (handle_worker_event event)));
  ignore
    (Thread.create
       (fun () ->
          while !running do
            (try Worker.For_testing.await_output client with
             | _ -> ());
            if !running && not (Worker.For_testing.is_stopping client)
            then Journal_pump.enqueue pump (fun () -> ())
            else running := false
          done)
       ());
  ignore
    (Thread.create
       (fun () ->
          while !running do
            Unix.sleepf 60.;
            if !running
            then
              Journal_pump.enqueue pump (fun () -> Effect.run (calendar_tick_effect ()))
          done)
       ());
  Effect.run calendar_startup;
  ignore (Lui_app.start app);
  ignore (Lui_app.flush app);
  context
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

let create ?(calendar_sampler = fun () -> Journal_calendar.Sampler.create ()) ~service ()
  : Journal_bridge.hooks
  =
  let init platform_code host_code payload =
    latest_patch := "";
    Printexc.record_backtrace true;
    (match decode_config (Bytes.of_string payload) with
     | Error error ->
       Printf.eprintf "logseq_journal: failed to decode startup config: %s\n%!" error
     | Ok config ->
       let runtime_epoch =
         Journal_worker_ids.Runtime.Epoch.of_int64
           (Int64.of_float (Unix.gettimeofday () *. 1e6))
       in
       (match Journal_worker_runtime.start ~runtime_epoch service config with
        | Error error ->
          Printf.eprintf "logseq_journal: failed to start worker: %s\n%!" error
        | Ok client ->
          (try
             ignore
               (start
                  ~calendar_sampler:(calendar_sampler ())
                  ~client
                  ~platform_code
                  ~host_code)
           with
           | exn ->
             (* The C bridge drops exceptions during the initial patch emit,
                so surface startup failures on stderr. *)
             Printf.eprintf
               "logseq_journal: app start failed: %s\n%s%!"
               (Printexc.to_string exn)
               (Printexc.get_backtrace ()))));
    !latest_patch
  in
  let dispatch event =
    latest_patch := "";
    (match !current_app with
     | Some { app; _ } ->
       ignore (Lui_app.dispatch_event app event);
       ignore (Lui_app.flush app)
     | None -> ());
    !latest_patch
  in
  let extension_event node name values =
    latest_patch := "";
    (match !current_app with
     | Some { app; _ } ->
       (match Lui_runtime.extension_identifier (Lui_app.runtime app) node with
        | Some identifier ->
          ignore
            (Lui_app.dispatch_event
               app
               (Lui_protocol.ExtensionEvent
                  (node, identifier, name, decode_extension_values values)))
        | None -> ());
       ignore (Lui_app.flush app)
     | None -> ());
    !latest_patch
  in
  let pump () =
    latest_patch := "";
    (match !current_app with
     | Some { app; pump; client; _ } ->
       Journal_pump.drain pump;
       Worker.Private.deliver client ~max_events:64;
       Journal_pump.drain pump;
       ignore (Lui_app.flush app)
     | None -> ());
    !latest_patch
  in
  let platform_event payload =
    match !current_app with
    | Some { pump; send_action; apply_platform; _ } ->
      Journal_pump.enqueue pump (fun () ->
        let bytes = Bytes.of_string payload in
        if Journal_platform.is_environment_event bytes
        then (
          match Journal_platform.decode_environment_event bytes with
          | Ok snapshot -> send_action (Environment_changed snapshot)
          | Error _ -> ())
        else Effect.run (apply_platform bytes))
    | None -> ()
  in
  let platform_response payload =
    match !current_app with
    | Some { pump; send_action; _ } ->
      let bytes = Bytes.of_string payload in
      if Bytes.length bytes >= 8
      then (
        let tag = Bytes.get_uint16_le bytes 6 in
        Journal_pump.enqueue pump (fun () ->
          send_action (Platform_response (tag, Ok bytes))))
    | None -> ()
  in
  let platform_failure payload =
    match !current_app with
    | Some { pump; send_action; _ } ->
      let bytes = Bytes.of_string payload in
      if Bytes.length bytes >= 8
      then (
        let tag = response_tag (Bytes.get_uint16_le bytes 6) in
        Journal_pump.enqueue pump (fun () ->
          send_action
            (Platform_response (tag, Error "application platform request failed"))))
    | None -> ()
  in
  let dispose () =
    latest_patch := "";
    (match !current_app with
     | Some context ->
       context.running := false;
       Worker.Private.request_stop context.client;
       ignore (Lui_app.dispose context.app);
       current_app := None
     | None -> ());
    !latest_patch
  in
  let root_node () =
    match !current_app with
    | Some { app; _ } -> Lui_app.root_node app
    | None -> 0
  in
  { Journal_bridge.init
  ; dispatch
  ; extension_event
  ; pump
  ; platform_event
  ; platform_response
  ; platform_failure
  ; dispose
  ; root_node
  }
;;

module For_testing = struct
  let diagnostics_page dispatch =
    diagnostics_page
      ~snapshot:None
      ~graph:{ generation = 0; graph_id = None; phase = Graph_closed; error = None }
      ~admission:Admission_refresh.Unavailable
      (Some { groups = [] })
      dispatch
  ;;

  let read_block_entropy = read_block_entropy
  let with_block_identity = with_block_identity

  let favorites_page items =
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
      ~render_media:(media_label initial_state handler)
      ~platform:"ios"
      ~graph_generation:1
      ~on_scroll_completed:handler
      ~destination:Journal_routes.Favorites
      ~favorites
      ~on_select_destination:handler
      ~on_favorites_visible_range:handler
      ~on_favorites_retry:handler
      ~timeline_state:(Journal_timeline_state.empty ~today:20260908)
      ~loading:false
      ~graph_error:None
      ~sync_error:None
      ~sync_phase:(Some Graph_service.Connecting)
      ~day_presentation:(fun _ -> None)
      ~capture_enabled:false
      ~on_capture_event:handler
      ~on_visible_range:handler
      ~on_retry_day:handler
      ~on_open_block:handler
      ~on_open_favorite:handler
      ~delete_enabled:false
      ~actions_enabled:false
      ~interaction_enabled:true
      ~on_status:handler
      ~on_delete:handler
      ~error_info_available:true
      ~on_error_info:handler
      ~account_menu_available:true
      ~on_account_action:handler
      ~cache_reset_available:false
    |> fun page ->
    V.Navigation_stack.create ~title:"" ~on_path_change:handler ~path:[] page
  ;;

  let app_with_service ?calendar_sampler service =
    let calendar_sampler = Option.map (fun sampler () -> sampler) calendar_sampler in
    create ?calendar_sampler ~service ()
  ;;
end

let native_hooks = create ~service:Graph_service.service ()
