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
  ; detail_staged : Journal_routes.staged_delete option
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
module Reference_sources = Map.Make (String)

type graph_drafts =
  { capture_draft : Journal_capture.t option
  ; append_drafts : Journal_routes.retained_drafts
  }

(* Attachments drained into the graph once a capture completes: set by
   Block_captured, consumed by the edge drain. *)
type capture_import_batch =
  { batch_generation : int
  ; batch_target : string
  ; batch_items : Journal_asset_import.staged list
  }

type state =
  { favorites : Journal_routes.Favorites.t
  ; favorites_media_roots : string Rrbvec.t
  ; favorites_requests : Journal_graph_request.favorites_request list
  ; routes : Journal_routes.t
  ; timeline : Journal_timeline_state.t
  ; timeline_structure_revision : int
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
  ; reference_sources : string Reference_sources.t
  ; media_views : Journal_media_runtime.view Media_views.t
  ; import_completion : (string * string option) option
  ; asset_import_request : int
  ; asset_import_owner : (string * int64) option
  ; capture_pick_request : int
  ; capture_pick_source : Journal_asset_import.source
  ; capture_imports : capture_import_batch option
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
  let favorites_media_roots =
    if
      Journal_routes.Favorites.revision favorites
      = Journal_routes.Favorites.revision state.favorites
    then state.favorites_media_roots
    else
      Journal_routes.Favorites.items favorites
      |> List.map (fun (item : Logseq_db_worker.Protocol.v2_favorite_item) ->
        match item.target with
        | V2_favorite_page { uuid; _ } | V2_favorite_block { uuid; _ } ->
          Logseq_db_types.Graph_types.Uuid.to_string uuid)
      |> Rrbvec.of_list
  in
  if favorites == state.favorites && requests = []
  then state
  else
    { state with
      favorites
    ; favorites_media_roots
    ; favorites_requests = state.favorites_requests @ requests
    }
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
  ; favorites_media_roots = Rrbvec.empty
  ; favorites_requests = []
  ; routes = Journal_routes.create ()
  ; timeline = Journal_timeline_state.empty ~today:0
  ; timeline_structure_revision = 0
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
  ; reference_sources = Reference_sources.empty
  ; media_views = Media_views.empty
  ; import_completion = None
  ; asset_import_request = 0
  ; asset_import_owner = None
  ; capture_pick_request = 0
  ; capture_pick_source = Journal_asset_import.Files
  ; capture_imports = None
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
    if Int64.compare next state.next_local_sequence <= 0
    then state
    else { state with next_local_sequence = next }
;;

let clear_graph_surface state =
  (match state.direct_capture with
   | Some capture ->
     List.iter
       Journal_asset_import.discard_staged_file
       (Journal_capture.pending_attachments capture)
   | None -> ());
  { state with
    favorites =
      Journal_routes.Favorites.create ~graph_generation:state.graph_state.generation
  ; favorites_media_roots = Rrbvec.empty
  ; favorites_requests = []
  ; routes = Journal_routes.create ()
  ; timeline = Journal_timeline_state.empty ~today:0
  ; feed_loaded = false
  ; reference_sources = Reference_sources.empty
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
  if routes == state.routes then state else { state with routes }
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
    Option.fold
      ~none:state.routes
      ~some:(Journal_routes.undo_delete state.routes)
      pending.detail_staged
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
    let routes, staged =
      Journal_routes.stage_delete state.routes ~block_id:pending.block_id
    in
    ( routes
    , match staged with
      | Some _ -> staged
      | None -> pending.detail_staged )
  in
  favorites_event
    { state with
      timeline
    ; routes
    ; pending_delete = Some { pending with staged; detail_staged }
    }
    (Hide_target pending.block_id)
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
  | Reference_sources_changed updates ->
    let reference_sources =
      List.fold_left
        (fun sources (id, source) ->
           match source with
           | _ when Reference_sources.find_opt id sources = source -> sources
           | None -> Reference_sources.remove id sources
           | Some source -> Reference_sources.add id source sources)
        state.reference_sources
        updates
    in
    if reference_sources == state.reference_sources
    then state
    else { state with reference_sources }
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
  | Detail_loaded { request_generation; detail } ->
    open_detail_state state detail request_generation
  | Detail_failed { request_generation; block_id; missing; stale_cursor; failure } ->
    let routes =
      Journal_routes.apply_detail_failure
        state.routes
        ~block_id
        ~stale_cursor
        ~request_generation
        ~missing
        ~message:(failure_source_message failure)
    in
    if routes == state.routes then state else { state with routes }
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
    let completed_capture =
      Option.bind state.direct_capture (fun capture ->
        if Journal_capture.completed_by capture block then Some capture else None)
    in
    let completed = Option.is_some completed_capture in
    { state with
      direct_capture = (if completed then None else state.direct_capture)
    ; modal = (if completed && state.modal = Capture_sheet then No_modal else state.modal)
    ; capture_error = (if completed then None else state.capture_error)
    ; capture_imports =
        (match
           Option.bind completed_capture (fun capture ->
             Journal_capture.attachment_imports capture)
         with
         | Some (batch_target, batch_items) ->
           Some
             { batch_generation = state.graph_state.generation
             ; batch_target
             ; batch_items
             }
         | None -> state.capture_imports)
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
      Journal_routes.map_details state.routes ~f:(fun detail ->
        Journal_detail.apply_block detail block)
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
    { state with
      timeline = Journal_timeline_state.remove_block state.timeline ~block_id
    ; routes = fst (Journal_routes.stage_delete state.routes ~block_id)
    }
  | Page_tree_reconciled { page; value } ->
    { state with
      timeline =
        Journal_timeline_state.replace_timeline_entry_page state.timeline ~page value
    }
  | Children_reconciled detail ->
    let routes =
      Journal_routes.map_details state.routes ~f:(fun current ->
        Journal_detail.reconcile_children current detail)
    in
    { state with routes }
  | Update_conflict latest ->
    let routes =
      Journal_routes.map_details state.routes ~f:(fun detail ->
        Journal_detail.apply_block detail latest)
    in
    let state = { state with routes } in
    (match state.pending_status with
     | Some pending when String.equal pending.block_id (Journal_model.id latest) ->
       { state with
         timeline = Journal_timeline_state.replace_block state.timeline latest
       ; pending_status = None
       ; timeline_notice = Some (Status_failed "Status changed elsewhere. Try again.")
       }
     | None | Some _ -> state)
  | Child_failed { block_id; failure; mutation_id = _ } ->
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
       let state =
         { state with
           routes =
             Journal_routes.map_details state.routes ~f:(fun detail ->
               Journal_detail.apply_block detail latest)
         }
       in
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
  | Mutation_failed { kind; mutation_id; block_id; failure } ->
    let state = record_failure_source state failure in
    let message = failure_source_message failure in
    (match kind with
     | Capture_mutation ->
       (match state.direct_capture with
        | None -> state
        | Some capture ->
          let failed =
            Journal_capture.fail_attempt capture ~mutation_id ~block_id ~message
          in
          if failed == capture
          then state
          else
            { state with
              direct_capture = Some failed
            ; capture_error =
                Some
                  (match failure with
                   | Worker_failure _ ->
                     Worker_capture_failure (latest_worker_error state)
                   | Projection_failure message -> Local_capture_failure message)
            })
     | Status_mutation ->
       (match state.pending_status with
        | Some pending
          when pending.mutation_id = mutation_id && pending.block_id = block_id ->
          { state with
            pending_status = None
          ; timeline_notice = Some (Status_failed message)
          }
        | _ -> state)
     | Delete_subtree_mutation ->
       (match state.pending_delete with
        | Some pending
          when pending.mutation_id = mutation_id && pending.block_id = block_id ->
          { (restore_deleted state pending) with
            pending_delete = None
          ; timeline_notice = Some (Delete_failed message)
          }
        | _ -> state)
     | Source_mutation -> state)
  | Rejected failure ->
    let state = record_failure_source state failure in
    show_sync_error
      state
      (match failure with
       | Worker_failure _ -> Worker_sync_failure (latest_worker_error state)
       | Projection_failure message -> Non_worker_sync_failure message)
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
    | Capture_discarded
    | Capture_picker_requested of Journal_asset_import.source
    | Capture_asset_picked of Journal_asset_import.staged * int option
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
    ; favorites_media_roots = Rrbvec.empty
    ; favorites_requests = []
    ; pending_delete = None
    ; pending_status = None
    ; timeline = Journal_timeline_state.empty ~today:0
    ; reference_sources = Reference_sources.empty
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
        if state.modal = Capture_sheet
        then state
        else { state with modal = Capture_sheet }
      | Capture_closed ->
        if state.modal = No_modal then state else { state with modal = No_modal }
      | Capture_discarded ->
        (match state.direct_capture with
         | Some capture when Journal_capture.phase capture = Journal_capture.Editing ->
           List.iter
             Journal_asset_import.discard_staged_file
             (Journal_capture.pending_attachments capture);
           { state with
             modal = No_modal
           ; direct_capture = None
           ; capture_error = None
           ; capture_pick_request = state.capture_pick_request + 1
           }
         | None | Some _ -> state)
      | Capture_picker_requested source ->
        { state with
          capture_pick_source = source
        ; capture_pick_request = state.capture_pick_request + 1
        }
      | Capture_asset_picked (staged, request_id) ->
        (match state.direct_capture with
         | Some capture when request_id = Some state.capture_pick_request ->
           { state with
             direct_capture = Some (Journal_capture.add_attachment capture staged)
           ; capture_error = None
           }
         | None | Some _ ->
           Journal_asset_import.discard_staged_file staged;
           state)
      | Capture_native_edit edit ->
        (match state.direct_capture with
         | None -> state
         | Some capture ->
           let next = Journal_capture.apply_text_edit capture edit in
           if next == capture then state else { state with direct_capture = Some next })
      | Capture_task_intent selected ->
        (match state.direct_capture with
         | None -> state
         | Some capture ->
           let next =
             if Journal_capture.task_state capture = Journal_model.Todo = selected
             then capture
             else Journal_capture.toggle_task_intent capture
           in
           if next == capture then state else { state with direct_capture = Some next })
      | Capture_edited source ->
        let capture, next_local_sequence =
          match state.direct_capture with
          | None ->
            ( Journal_capture.create ~session_number:state.next_local_sequence ~source
            , Int64.succ state.next_local_sequence )
          | Some capture ->
            Journal_capture.update_source capture ~source, state.next_local_sequence
        in
        if
          (match state.direct_capture with
           | Some previous -> previous == capture
           | None -> false)
          && state.capture_error = None
        then state
        else
          { state with
            direct_capture = Some capture
          ; next_local_sequence
          ; capture_error = None
          }
      | Capture_admitted capture ->
        (match state.direct_capture with
         | Some previous when previous == capture && state.capture_error = None -> state
         | _ -> { state with direct_capture = Some capture; capture_error = None })
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
    V.Body.Vertical.create
      [ V.Body.Vertical.fixed
          (V.Native_list.vertical
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
             ])
      ]
    |> V.Body.Private.to_widget
    |> V.frame ~max_height:Fill
    |> V.Body.static
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
      ~header_text:title
      (keyed children)
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
      let action title icon command =
        V.buttons_action
          ~label:title
          ~icon
          ~text:title
          ~on_press:(bind_action dispatch command)
          ()
      in
      ( summary
      , V.buttons
          ~actions:
            [ action "Details" "exclamationmark.circle" "open-error-info"
            ; action "Dismiss" "xmark" "dismiss-operation-error"
            ]
          ()
        |> V.with_test_id (Ui.Test_id.string (scope ^ "-operation-actions")) )
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
    V.buttons
      ~actions:
        [ V.buttons_action ~label:title ~icon:symbol ~text:title ~on_press:handler () ]
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

let media_presentation_scope state ~detail =
  if detail
  then
    Printf.sprintf
      "%d:detail:%Ld"
      state.graph_state.generation
      (Journal_routes.detail_request_generation state.routes)
  else
    Printf.sprintf
      "%d:%s"
      state.graph_state.generation
      (match Journal_routes.destination state.routes with
       | Journals -> "journals"
       | Favorites -> "favorites")
;;

let media_label
      ?store
      ?(on_region = fun _ -> ())
      ?(detail = false)
      state
      dispatch
      ~root
      child
  =
  let scope = media_presentation_scope state ~detail in
  Journal_media_view.view
    ?store
    ~on_region
    ~scope
    ~root
    ~media:(Media_views.find_opt root state.media_views)
    ~on_event:(fun payload ->
      Ui.Event.Handler.Private.invoke
        dispatch
        (Ui.Event.Payload.Text ("media-session:" ^ scope ^ ":media:" ^ payload)))
    child
;;

let row_media_label
      ?store
      ?(on_region = fun _ -> ())
      state
      dispatch
      ~root
      ~image_children
      child
  =
  let scope = media_presentation_scope state ~detail:false in
  Journal_media_view.row
    ?store
    ~on_region
    ~scope
    ~root
    ~image_children
    ~media_for_root:(fun id -> Media_views.find_opt id state.media_views)
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

let render_source state =
  Journal_model.render_references ~lookup:(fun id ->
    Reference_sources.find_opt id state.reference_sources)
;;

let favorites_view
      ~render_source
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
    V.buttons
      ~actions:
        [ V.buttons_action
            ~label:"Retry"
            ~icon:"arrow.clockwise"
            ~text:"Retry"
            ~on_press:on_retry
            ()
        ]
      ()
    |> V.with_test_id (Ui.Test_id.string "favorites-retry-button")
  in
  let busy = V.loading ~message:"Loading favorites" () in
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
                let text =
                  V.text
                    (match favorite.target with
                     | Page _ -> favorite.title
                     | Block _ -> render_source favorite.title)
                in
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

(* Composer asset attachments: arms the shared journal-asset-import picker
   (source-selecting request) and renders the pending strip natively around
   the composer. *)
type composer_assets =
  { request : Journal_asset_import.request
  ; camera : bool
  ; completion : (string * string option) option
  ; on_attach : Journal_asset_import.source -> unit
  ; on_event : string -> unit
  }

let composer_content
      ~scope
      ~placeholder
      ~capture
      ~saving
      ~enabled
      ~on_edit
      ~on_toggle
      ~on_save
      ~error
      ~assets
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
  let task_selected = Journal_capture.task_state capture = Journal_model.Todo in
  let task =
    (* Circular icon capsule matching the composer actions row — buttons has
       no disabled state, so the guard lives in the handler. *)
    V.buttons
      ~actions:
        [ V.buttons_action
            ~label:"Task"
            ~icon:(if task_selected then "checkmark.circle" else "circle")
            ~on_press:
              (Ui.Event.Handler.create (fun _ ->
                 if enabled && not saving
                 then
                   Ui.Event.Handler.Private.invoke
                     on_toggle
                     (Ui.Event.Payload.Bool (not task_selected))))
            ()
        ]
      ()
    |> V.with_test_id (Ui.Test_id.string (scope ^ "-task"))
  in
  let attach =
    match assets with
    | None -> []
    | Some assets ->
      let action ~label ~icon source =
        V.buttons_action
          ~label
          ~icon
          ~on_press:
            (Ui.Event.Handler.create (fun _ ->
               if enabled && (not saving) && Journal_capture.can_attach capture
               then assets.on_attach source))
          ()
      in
      [ V.buttons
          ~actions:
            ([ action ~label:"文件" ~icon:"doc" Journal_asset_import.Files
             ; action ~label:"照片" ~icon:"photo" Journal_asset_import.Photos
             ]
             @
             if assets.camera
             then [ action ~label:"相机" ~icon:"camera" Journal_asset_import.Camera ]
             else [])
          ()
        |> V.with_test_id (Ui.Test_id.string (scope ^ "-attach"))
      ]
  in
  let pending = Journal_capture.pending_attachments capture in
  let attachments =
    match pending with
    | [] -> None
    | _ ->
      Some
        (V.of_lui
           (Lui_elements.row
              ~gap:8
              (List.map
                 (fun staged ->
                    Lui_element_combine.composer_attachment
                      ~disabled:((not enabled) || saving)
                      ~key:(Journal_asset_import.staged_token staged)
                      ~path:(Journal_asset_import.staged_path staged)
                      ~title:(Journal_asset_import.staged_title staged)
                      ~file_type:(Journal_asset_import.staged_type staged)
                      ~on_remove:(fun _ ->
                        match assets with
                        | None -> ()
                        | Some assets when enabled && not saving ->
                          assets.on_event
                            (Yojson.Basic.to_string
                               (`Assoc
                                   [ "action", `String "remove"
                                   ; ( "token"
                                     , `String (Journal_asset_import.staged_token staged)
                                     )
                                   ]))
                        | Some _ -> ())
                      ())
                 pending)))
  in
  let discard =
    if
      scope = "journal-capture" && Journal_capture.phase capture = Journal_capture.Editing
    then
      [ V.buttons
          ~actions:
            [ V.buttons_action
                ~label:"Discard draft"
                ~icon:"trash"
                ~on_press:(bind_action on_edit "discard-capture")
                ()
            ]
          ()
      ]
    else []
  in
  let composer =
    V.composer
      ~key:(Ui.Key.string (scope ^ "-composer"))
      ~accessibility_identifier:(scope ^ "-composer")
      ~autofocus:true
      ~label:"Draft"
      ~placeholder
      ~session_id:(Journal_capture.session_id capture)
      ~document_revision:(Journal_capture.document_revision capture)
      ~accepted_local_revision:(Journal_capture.accepted_local_revision capture)
      ~value:(Journal_capture.value capture)
      ~send_disabled:(not can_submit)
      ?attachments
      ?feedback:(Option.map live_region_text error)
      ~actions:(attach @ [ task ] @ discard)
      ~on_edit
      ~on_submit:ignored
      ~on_send:on_save
      ()
  in
  let content =
    V.column
      ~spacing:12.
      ([ composer ] @ if saving then [ V.loading ~message:"Saving…" () ] else [])
    |> V.padding ~insets:(Ui.Layout.Edge_insets.all 16.)
  in
  content
;;

let composer_page
      ~scope
      ~placeholder
      ~capture
      ~saving
      ~enabled
      ~on_edit
      ~on_toggle
      ~on_save
      ~on_close
      ~error
      ~assets
  =
  let close =
    V.button ~role:Cancel ~on_press:on_close ~child:(V.text "Close") ()
    |> V.with_test_id (Ui.Test_id.string (scope ^ "-close"))
  in
  composer_content
    ~scope
    ~placeholder
    ~capture
    ~saving
    ~enabled
    ~on_edit
    ~on_toggle
    ~on_save
    ~error
    ~assets
  |> V.Body.static
  |> V.Body.toolbar
       ~items:
         [ V.Toolbar.item
             ~key:(Ui.Key.string "composer-close")
             ~placement:Cancellation_action
             close
         ]
;;

let timeline_page
      ~header_signal
      ~timeline_store
      ~on_region
      ~render_source
      ~render_media
      ~render_row_media
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
      ~capture_expanded
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
  let timeline () =
    on_region "timeline";
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
        ?store:timeline_store
        ~on_region
        ~render_source
        ~render_media:render_row_media
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
        ()
  in
  let favorites_selected = destination = Journal_routes.Favorites in
  let content =
    if favorites_selected
    then (
      on_region "favorites";
      favorites_view
        ~render_source
        ~render_media
        ~state:favorites
        ~actions_enabled:interaction_enabled
        ~on_visible_range:on_favorites_visible_range
        ~on_retry:on_favorites_retry
        ~on_open_favorite)
    else timeline ()
  in
  let destination_action index =
    Ui.Event.Handler.create (fun _ ->
      Ui.Event.Handler.Private.invoke on_select_destination (Ui.Event.Payload.Int64 index))
  in
  let header =
    match header_signal with
    | None -> Journal_header.view
    | Some presentation_signal -> Journal_header.reactive_view ~presentation_signal
  in
  header
    ~platform
    ~key:(Ui.Key.string ("journal-root:" ^ string_of_int graph_generation))
    ~context:
      (match destination with
       | Journal_routes.Journals -> Journal_header.Context.journals
       | Favorites -> Journal_header.Context.favorites)
    ~sync_phase
    ~sync_error
    ~on_error_info:
      (if error_info_available || Option.is_some header_signal
       then Some on_error_info
       else None)
    ~on_account_action:(if account_menu_available then Some on_account_action else None)
    ~local_deletion_available:cache_reset_available
    ~on_journals:(destination_action 0L)
    ~on_favorites:(destination_action 1L)
    ~on_capture:(bind_action on_capture_event "open-capture")
    ~capture_enabled
    ~capture_expanded
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
    | Some message -> [ V.feedback_banner ~kind:`error ~message () ]
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
    Printf.sprintf
      "detail-session:%s:%Ld:"
      (Option.value (Journal_routes.active_entry_id routes) ~default:"root")
      (Journal_routes.detail_request_generation routes)
  ;;
end

module Detail_list = struct
  let view ~key ~detail ~enabled ~on_action ~on_scroll_completed ~children =
    let row_actions = Hashtbl.create 16 in
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
            let open_block = bind_action on_action ("detail-open:" ^ id) in
            let register action handler =
              Hashtbl.replace row_actions (Journal_detail.row_key row, action) handler
            in
            register "open" open_block;
            if enabled
            then (
              register "delete" delete;
              register ("delete:" ^ id) delete);
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
                      ~key:(Ui.Key.string "open")
                      ~title:"Open block"
                      ~symbol:"arrow.up.right.square"
                      ~on_press:open_block
                      ()
                  ; V.Context_menu.action
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
      ~on_row_event:
        (Ui.Event.Handler.create (function
           | Ui.Event.Payload.Native_event { payload; _ } ->
             (match
                try Yojson.Basic.from_string (Bytes.to_string payload) with
                | _ -> `Null
              with
              | `Assoc fields ->
                (match List.assoc_opt "row" fields, List.assoc_opt "key" fields with
                 | Some (`String row), Some (`String action) ->
                   Option.iter
                     (fun handler ->
                        Ui.Event.Handler.Private.invoke handler Ui.Event.Payload.Unit)
                     (Hashtbl.find_opt row_actions (row, action))
                 | _ -> ())
              | _ -> ())
           | _ -> ()))
      [ V.Native_list.section ~key:(Ui.Key.string "outline") ~separator:Hidden rows ]
    |> V.Viewport.Vertical.with_test_id (Ui.Test_id.string "journal-detail-outline")
    |> V.Body.Vertical.fill
    |> fun content -> V.Body.Vertical.create [ content ]
  ;;
end

let detail_page
      ?media_store
      ?(on_region = fun _ -> ())
      ~state
      ~on_scroll_completed
      dispatch
  =
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
  let button ~id ~command ~symbol title =
    V.buttons
      ~actions:
        [ V.buttons_action
            ~label:title
            ~icon:symbol
            ~text:title
            ~on_press:(on_action command)
            ()
        ]
      ()
    |> V.with_test_id (Ui.Test_id.string id)
  in
  let rows detail =
    List.map
      (function
        | Journal_detail.More { parent_id; loading; error; _ } ->
          if loading
          then V.loading ~message:"Loading children" ()
          else
            V.column
              (Option.to_list (Option.map live_region_text error)
               @ [ button
                     ~id:("detail-more:" ^ parent_id)
                     ~command:("detail-more:" ^ parent_id)
                     ~symbol:
                       (if Option.is_some error then "arrow.clockwise" else "ellipsis")
                     (if Option.is_some error
                      then "Retry loading children"
                      else "Load more")
                 ])
        | Block { block; _ } ->
          let source =
            if Journal_model.task_state block = No_status
            then render_source state (Journal_model.source block)
            else
              Journal_model.status_name (Journal_model.task_state block)
              ^ "  "
              ^ render_source state (Journal_model.source block)
          in
          V.text ~key:(Ui.Key.string ("detail-label:" ^ Journal_model.id block)) source
          |> V.with_test_id (Ui.Test_id.string ("detail-block:" ^ Journal_model.id block))
          |> media_label
               ?store:media_store
               ~on_region
               ~detail:true
               state
               dispatch
               ~root:(Journal_model.id block))
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
       | Detail_loading -> V.loading ~centered:true ~message:"Loading block" ()
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
           ~actions:
             (button
                ~id:"detail-retry"
                ~command:"detail-retry"
                ~symbol:"arrow.clockwise"
                "Retry")
       | Detail | Timeline -> V.empty ())
      |> V.Body.static
  in
  let actions_enabled = enabled && Option.is_some detail && not saving in
  let action ~label ~icon command =
    V.buttons_action
      ~label
      ~icon
      ~on_press:
        (Ui.Event.Handler.create (fun _ ->
           if actions_enabled
           then Ui.Event.Handler.Private.invoke (on_action command) Ui.Event.Payload.Unit))
      ()
  in
  content
  |> Journal_header.detail
       ~actions:
         [ action ~label:"Append" ~icon:"plus" "open-append"
         ; action ~label:"Attach file" ~icon:"paperclip" "open-asset-import"
         ]
  |> Journal_asset_import.view
       ~key:(Ui.Key.string (scope ^ "import"))
       ~enabled:actions_enabled
       ~completion:state.import_completion
       ~request:
         (Journal_asset_import.file_request
            ~id:
              (if
                 state.asset_import_owner
                 = Option.map
                     (fun id -> id, Journal_routes.detail_request_generation state.routes)
                     (Journal_routes.active_entry_id state.routes)
               then state.asset_import_request
               else 0))
       ~pending:[]
       ~on_select:(fun payload ->
         Ui.Event.Handler.Private.invoke
           dispatch
           (Ui.Event.Payload.Text (scope ^ "import-asset:" ^ payload)))
  |> V.Body.static
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
  let capsule ~id ~command title symbol =
    V.buttons
      ~actions:
        [ V.buttons_action
            ~label:title
            ~icon:symbol
            ~text:title
            ~on_press:(bind_action dispatch command)
            ()
        ]
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
    capsule
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
             capsule
               ~id:"graph-picker-retry"
               ~command:"refresh-catalog"
               "Retry"
               "arrow.clockwise"
           | Some Begin_online_recovery | Some Retry_graph_open ->
             capsule
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
  if state.graph_state.phase = Logseq_db_worker.Graph_open
  then Some (state.graph_state.generation, state.graph_state.graph_id)
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

let start ~on_view_region ~calendar_sampler ~client ~platform_code ~host_code
  : app_context
  =
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
  let media_store = Journal_media_view.Store.create ~observe:on_view_region () in
  let timeline_store = Journal_timeline.Store.create ~observe:on_view_region () in
  let timeline_store_generation = ref initial_state.graph_state.generation in
  let prepare_presentation state =
    if !timeline_store_generation <> state.graph_state.generation
    then (
      timeline_store_generation := state.graph_state.generation;
      Journal_timeline.Store.reset timeline_store);
    let timeline_structure_revision =
      Journal_timeline.Store.synchronize timeline_store state.timeline
    in
    if state.timeline_structure_revision = timeline_structure_revision
    then state
    else { state with timeline_structure_revision }
  in
  ignore (Journal_timeline.Store.synchronize timeline_store initial_state.timeline : int);
  let media_context = ref None in
  let media_page state =
    ( Journal_routes.destination state.routes
    , Journal_routes.active_entry_id state.routes
    , Journal_routes.detail_request_generation state.routes )
  in
  let active_media_page = ref (media_page initial_state) in
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
  in
  let sync_media state =
    let key = media_key state in
    if key <> !media_context
    then (
      media_context := key;
      Journal_media_view.Store.reset media_store;
      Journal_media_runtime.reset media_runtime ~graph_generation:(Option.map fst key))
  in
  let flush_media set_state =
    let changes = Hashtbl.to_seq media_changes |> List.of_seq in
    Hashtbl.clear media_changes;
    let context = !media_context in
    if changes = []
    then Effect.ignore
    else
      set_state (fun state ->
        if media_key state <> context
        then state
        else (
          let media_views =
            List.fold_left
              (fun views (root, (view : Journal_media_runtime.view)) ->
                 let empty = view.items = [] && view.error = None && not view.more in
                 Journal_media_view.Store.update
                   media_store
                   ~root
                   (if empty then None else Some view);
                 if empty
                 then Media_views.remove root views
                 else if Media_views.find_opt root views = Some view
                 then views
                 else Media_views.add root view views)
              state.media_views
              changes
          in
          if media_views == state.media_views then state else { state with media_views }))
  in
  let import_worker_requests = Hashtbl.create 2 in
  (* operation token -> staged pick whose temp copy is removed on completion *)
  let capture_staged_items = Hashtbl.create 2 in
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
  let graph_worker_requests = Hashtbl.create 16 in
  let deliver_output output =
    Journal_graph_transport.deliver
      ~runtime:graph_runtime
      ~send:(fun request ->
        match Worker.send client (Graph_service.Graph_request request) with
        | Accepted worker_id ->
          Hashtbl.replace graph_worker_requests worker_id request;
          Journal_graph_transport.Accepted
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
          Hashtbl.clear graph_worker_requests;
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
                ; favorites_media_roots = Rrbvec.empty
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
      Hashtbl.clear graph_worker_requests;
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
      Hashtbl.remove graph_worker_requests request_id;
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
    | Worker.Push { payload = (Asset_notice _ | Asset_notices _) as payload; _ } ->
      let notices = Graph_service.asset_notices payload in
      List.iter
        (fun (scope, notice) ->
           Journal_asset_runtime.notice asset_runtime scope notice;
           Journal_media_runtime.notice media_runtime scope notice)
        notices;
      Effect.many
        [ flush_media set_state
        ; set_state (fun state ->
            { state with
              uploads =
                List.fold_left
                  (fun uploads (scope, notice) ->
                     Journal_uploads.notice uploads scope notice)
                  (Journal_uploads.sync state.uploads (upload_context state))
                  notices
            })
        ]
    | Worker.Response { request_id; outcome = Completed (Asset_imported result); _ } ->
      let pending = Hashtbl.find_opt import_worker_requests request_id in
      Hashtbl.remove import_worker_requests request_id;
      (match pending with
       | Some (_, operation, _) ->
         (match Hashtbl.find_opt capture_staged_items operation with
          | Some staged ->
            Hashtbl.remove capture_staged_items operation;
            Journal_asset_import.discard_staged_file staged
          | None -> ())
       | None -> ());
      let current =
        match pending with
        | Some (generation, _, owner) ->
          let snapshot = !state_ref in
          generation = snapshot.graph_state.generation
          &&
          let routes =
            Option.bind owner (fun (entry_id, request_generation) ->
              Option.bind
                (Journal_routes.at_entry snapshot.routes ~entry_id)
                (fun routes ->
                   if Journal_routes.detail_request_generation routes = request_generation
                   then Some routes
                   else None))
          in
          (match result, Option.bind routes Journal_routes.detail with
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
               | Some (generation, operation, owner) ->
                 set_state (fun state ->
                   if
                     state.graph_state.generation <> generation
                     || Option.fold
                          ~none:false
                          ~some:(fun (entry_id, request_generation) ->
                            match Journal_routes.at_entry state.routes ~entry_id with
                            | Some routes ->
                              Journal_routes.detail_request_generation routes
                              <> request_generation
                            | None -> true)
                          owner
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
      let generation, operation, owner = Hashtbl.find import_worker_requests request_id in
      Hashtbl.remove import_worker_requests request_id;
      (match Hashtbl.find_opt capture_staged_items operation with
       | Some staged ->
         Hashtbl.remove capture_staged_items operation;
         Journal_asset_import.discard_staged_file staged
       | None -> ());
      set_state (fun state ->
        if
          state.graph_state.generation <> generation
          || Option.fold
               ~none:false
               ~some:(fun (entry_id, request_generation) ->
                 match Journal_routes.at_entry state.routes ~entry_id with
                 | Some routes ->
                   Journal_routes.detail_request_generation routes <> request_generation
                 | None -> true)
               owner
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
    | Worker.Response
        { request_id; outcome = (Failed _ | Cancelled | Shutdown) as outcome; _ }
      when Hashtbl.mem graph_worker_requests request_id ->
      let request = Hashtbl.find graph_worker_requests request_id in
      Hashtbl.remove graph_worker_requests request_id;
      let message =
        match outcome with
        | Failed message -> message
        | Cancelled -> "Worker request cancelled"
        | Shutdown -> "Worker request interrupted by shutdown"
        | Completed _ -> assert false
      in
      let output = Journal_graph_runtime.fail_request graph_runtime request ~message in
      Effect.bind
        (Effect.of_thunk (fun () -> deliver_output output))
        ~f:(fun delivery ->
          set_state (fun state ->
            let state = List.fold_left apply_worker_response state delivery.responses in
            match delivery.error with
            | None -> state
            | Some message when Option.is_some state.feed_refresh ->
              fail_feed_transport state message
            | Some message -> fail_graph_transport state message))
    | Worker.Response { outcome = Failed error; _ } ->
      set_state (fun state ->
        let worker_error = service_error ~operation:"handleRequest" error in
        let state = record_worker_error state ~operation:"handleRequest" worker_error in
        match state.feed_refresh with
        | Some _ ->
          show_sync_error
            { state with feed_refresh = None }
            (Worker_sync_failure (latest_worker_error state))
        | None -> show_sync_error state (Worker_sync_failure (latest_worker_error state)))
    | Worker.Response { outcome = Cancelled | Shutdown; _ } ->
      set_state (fun state ->
        match state.feed_refresh with
        | Some _ ->
          show_sync_error
            { state with feed_refresh = None }
            (Non_worker_sync_failure "Worker unavailable")
        | None -> show_sync_error state (Non_worker_sync_failure "Worker unavailable"))
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
  let prev_capture_imports_key = ref initial_state.capture_imports in
  let capture_imports_callback batch =
    match batch with
    | None -> Effect.ignore
    | Some batch ->
      Effect.many
        (set_state (fun state ->
           match state.capture_imports with
           | Some pending when pending == batch -> { state with capture_imports = None }
           | _ -> state)
         ::
         (match Logseq_db_types.Graph_types.Uuid.of_string batch.batch_target with
          | Error _ ->
            [ Effect.of_thunk (fun () ->
                List.iter Journal_asset_import.discard_staged_file batch.batch_items)
            ]
          | Ok target ->
            List.map
              (fun staged ->
                 let operation = Journal_asset_import.staged_token staged in
                 let source = Journal_asset_import.to_import staged ~target in
                 Effect.bind
                   (Effect.of_thunk (fun () ->
                      if not !state_ref.write_enabled
                      then (
                        Journal_asset_import.discard_staged_file staged;
                        Some "The destination is not ready for imports")
                      else (
                        match
                          Worker.send
                            client
                            (Graph_service.Import_asset
                               { graph_generation = batch.batch_generation; source })
                        with
                        | Accepted request_id ->
                          Hashtbl.replace
                            import_worker_requests
                            request_id
                            (batch.batch_generation, operation, None);
                          Hashtbl.replace capture_staged_items operation staged;
                          None
                        | Full | Not_ready | Stopping ->
                          Journal_asset_import.discard_staged_file staged;
                          Some "Import is temporarily unavailable. Select the file again.")))
                   ~f:(function
                     | None -> Effect.ignore
                     | Some message ->
                       set_state (fun state ->
                         { state with import_completion = Some (operation, Some message) })))
              batch.batch_items))
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
           if not (Journal_capture.can_save capture)
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
    let media_source_active = ref true in
    let payload =
      match payload with
      | Ui.Event.Payload.Text action
        when String.starts_with ~prefix:"media-session:" action ->
        let scopes =
          media_presentation_scope snapshot ~detail:false
          :: List.filter_map
               (fun (entry : Journal_routes.detail_route Lui_navigation.entry) ->
                  Option.map
                    (fun routes ->
                       media_presentation_scope { snapshot with routes } ~detail:true)
                    (Journal_routes.at_entry snapshot.routes ~entry_id:entry.id))
               (Lui_navigation.Path.entries (Journal_routes.path snapshot.routes))
        in
        (match
           List.find_opt
             (fun scope ->
                String.starts_with ~prefix:("media-session:" ^ scope ^ ":") action)
             scopes
         with
         | Some scope ->
           media_source_active
           := scope
              = media_presentation_scope
                  snapshot
                  ~detail:(Journal_routes.route snapshot.routes <> Timeline);
           let prefix = "media-session:" ^ scope ^ ":" in
           Ui.Event.Payload.Text
             (String.sub
                action
                (String.length prefix)
                (String.length action - String.length prefix))
         | None -> Ui.Event.Payload.Unit)
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
           (* The extension re-emits its preference on every remount; only a
              real change may refresh (each refresh republishes the model and
              would loop under the full-remount view). *)
           if !asset_settings <> Some settings
           then (
             asset_settings := Some settings;
             let current = !state_ref in
             if current.graph_state.phase = Graph_open
             then
               refresh_assets
                 ~graph_generation:current.graph_state.generation
                 current.calendar)))
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
             let next = Journal_detail.apply_child_edit detail edit in
             if next == detail
             then state
             else { state with routes = Journal_routes.update_detail state.routes next })
        | _, Some { startup = { awaiting_e2ee_password = true; _ }; _ }
        | _, Some { startup = { failure = Some During_e2ee; _ }; _ } ->
          let e2ee_password = Journal_capture.apply_text_edit state.e2ee_password edit in
          (* A mount-time echo produces an identical capture; rebuilding the
             record would republish the model and remount the field, which
             echoes again — an unbounded render loop. *)
          if e2ee_password == state.e2ee_password
          then state
          else { state with e2ee_password }
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
      when Journal_routes.route snapshot.routes = Timeline
           && Journal_routes.destination snapshot.routes = Journal_routes.Favorites ->
      let total = Rrbvec.length snapshot.favorites_media_roots in
      let bounded value =
        Int64.to_int (Int64.min (Int64.of_int total) (Int64.max 0L value))
      in
      let first_index = bounded first_index in
      let last_exclusive = max first_index (bounded last_exclusive) in
      let roots =
        Rrbvec.subvec snapshot.favorites_media_roots first_index last_exclusive
        |> Option.get
        |> Rrbvec.to_list
      in
      Journal_media_runtime.retain_visible_roots media_runtime roots;
      update (fun state ->
        favorites_event state (Visible { first_index; last_exclusive }))
    | Ui.Event.Payload.Visible_range _
      when Journal_routes.route snapshot.routes <> Timeline
           || Journal_routes.destination snapshot.routes = Journal_routes.Favorites ->
      Effect.ignore
    | Ui.Event.Payload.Visible_range range ->
      let total = Int64.of_int (Journal_timeline_state.total_count snapshot.timeline) in
      let bounded value = Int64.to_int (Int64.min total (Int64.max 0L value)) in
      let first = bounded range.first_index in
      let last = bounded range.last_exclusive in
      let offset = Journal_timeline_state.first_retained_index snapshot.timeline in
      let rec collect index roots =
        if index >= last
        then roots
        else (
          let roots =
            match
              Journal_timeline_state.retained_slot snapshot.timeline (index - offset)
            with
            | Some (Top_level entry) ->
              Journal_model.id entry.block
              :: List.rev_append
                   (List.map
                      (fun (child : Journal_graph_projection.child_summary) ->
                         child.block_id)
                      entry.child_summaries)
                   roots
            | _ -> roots
          in
          collect (index + 1) roots)
      in
      Journal_media_runtime.retain_visible_roots media_runtime (collect first []);
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
        | Capture_sheet -> Root_navigation.step state Capture_closed
        | Append_sheet | Status_sheet _ | Error_info | Cache_reset_confirmation _ ->
          { state with modal = No_modal })
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
               | _ when visible && not !media_source_active -> ()
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
               | _ -> ()
             with
             | _ -> ()))
          ~f:(fun () -> flush_media set_state)
      else if String.equal action "open-asset-import"
      then
        update (fun state ->
          if
            state.write_enabled
            && Option.is_none state.pending_delete
            && Option.is_none state.pending_status
            && Option.fold
                 ~none:false
                 ~some:(fun detail -> Journal_detail.mode detail <> Saving_child)
                 (Journal_routes.detail state.routes)
          then
            { state with
              asset_import_request = state.asset_import_request + 1
            ; asset_import_owner =
                Option.map
                  (fun id -> id, Journal_routes.detail_request_generation state.routes)
                  (Journal_routes.active_entry_id state.routes)
            }
          else state)
      else if String.starts_with ~prefix:"import-asset:" action
      then (
        let import_payload = String.sub action 13 (String.length action - 13) in
        if Journal_asset_import.is_dismissal import_payload
        then Effect.ignore
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
             | Error _ -> Effect.ignore
             | Ok source ->
               let operation =
                 Logseq_db_types.Graph_types.Uuid.to_string source.operation
               in
               let graph_generation = snapshot.graph_state.generation in
               Effect.bind
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
                          ( graph_generation
                          , operation
                          , Option.map
                              (fun id ->
                                 ( id
                                 , Journal_routes.detail_request_generation
                                     snapshot.routes ))
                              (Journal_routes.active_entry_id snapshot.routes) );
                        None
                      | Full | Not_ready | Stopping ->
                        Some "Import is temporarily unavailable. Select the file again.")))
                 ~f:(function
                   | None -> Effect.ignore
                   | Some message ->
                     update (fun state ->
                       { state with import_completion = Some (operation, Some message) })))))
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
      then update (fun state -> Root_navigation.step state Capture_closed)
      else if String.equal action "discard-capture"
      then update (fun state -> Root_navigation.step state Capture_discarded)
      else if String.starts_with ~prefix:"capture-attach:" action
      then
        update (fun state ->
          match
            ( Journal_asset_import.source_of_string
                (String.sub action 15 (String.length action - 15))
            , state.direct_capture )
          with
          | Some source, Some capture
            when state.write_enabled
                 && Option.is_none state.pending_delete
                 && Option.is_none state.pending_status
                 && Journal_capture.can_attach capture ->
            Root_navigation.step state (Capture_picker_requested source)
          | _ -> state)
      else if String.starts_with ~prefix:"capture-asset:" action
      then (
        match
          Journal_asset_import.decode_event
            (String.sub action 14 (String.length action - 14))
        with
        | Error _ | Ok Journal_asset_import.Dismissed -> Effect.ignore
        | Ok (Journal_asset_import.Unavailable message) ->
          update (fun state ->
            { state with capture_error = Some (Local_capture_failure message) })
        | Ok (Journal_asset_import.Removed token) ->
          (match snapshot.direct_capture with
           | Some capture ->
             List.iter
               (fun (staged : Journal_asset_import.staged) ->
                  if String.equal (Journal_asset_import.staged_token staged) token
                  then Journal_asset_import.discard_staged_file staged)
               (Journal_capture.pending_attachments capture)
           | None -> ());
          update (fun state ->
            { state with
              direct_capture =
                Option.map
                  (fun capture -> Journal_capture.remove_attachment capture ~token)
                  state.direct_capture
            })
        | Ok (Journal_asset_import.Picked (staged, request_id)) ->
          update (fun state ->
            Root_navigation.step state (Capture_asset_picked (staged, request_id))))
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
      else if String.starts_with ~prefix:"detail-open:" action
      then open_block (String.sub action 12 (String.length action - 12))
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
          let generation = snapshot.next_request_generation in
          let routes, request =
            Journal_routes.retry_detail snapshot.routes ~request_generation:generation
          in
          (match request with
           | None -> Effect.ignore
           | Some request ->
             with_direct_request
               { snapshot with routes; next_request_generation = Int64.succ generation }
               request)
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
             else (
               let timeline =
                 Journal_timeline_state.complete_scroll
                   state.timeline
                   ~token:completion.token
                   ~outcome:completion.outcome
               in
               if timeline == state.timeline then state else { state with timeline }))))
  in
  let notice_token_sequence = ref 0L in
  let notice_cancellation : int64 option ref = ref None in
  let cancel_notice token =
    emit_platform_request (Journal_platform.notice_cancel_request ~token)
  in
  let notice_callback ((undo_available, _capture_error), accessible_navigation) =
    Option.iter cancel_notice !notice_cancellation;
    notice_cancellation := None;
    (* Composer failures are laid out above its controls. Only Undo uses
       the platform notice, so an error never covers draft actions. *)
    match undo_available with
    | false -> ()
    | true ->
      let token = Int64.succ !notice_token_sequence in
      notice_token_sequence := token;
      notice_cancellation := Some token;
      let message, action_label, duration_ms =
        ( "Block and descendants removed"
        , Some "Undo"
        , if accessible_navigation then 10_000 else 5_000 )
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
    (let key = media_page model in
     if !active_media_page <> key
     then (
       active_media_page := key;
       Journal_media_runtime.retain_visible_roots media_runtime [];
       Effect.run (flush_media set_state)));
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
    (let key = model.capture_imports in
     if not (Option.equal ( == ) !prev_capture_imports_key key)
     then (
       prev_capture_imports_key := key;
       Effect.run (capture_imports_callback key)));
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
      let model = run_edge_callbacks model |> prepare_presentation in
      state_ref := model;
      model
    | Platform_response (tag, result) ->
      (match Hashtbl.find_opt pending_platform tag with
       | Some k ->
         Hashtbl.remove pending_platform tag;
         k result
       | None -> ());
      model
    | Environment_changed snapshot ->
      prepare_presentation { model with environment = snapshot }
  in
  (* These subscriptions use complete presentation dependencies. They compare
     persistent owners rather than walking retained rows on every input event. *)
  let same_actions left right =
    left.write_enabled = right.write_enabled
    && Option.is_some left.pending_delete = Option.is_some right.pending_delete
    && Option.is_some left.pending_status = Option.is_some right.pending_status
  in
  let capture_saving state =
    Option.fold
      ~none:false
      ~some:(fun capture -> Journal_capture.phase capture = Saving)
      state.direct_capture
  in
  let equal_capture_presentation left right =
    left.direct_capture == right.direct_capture
    && left.modal = right.modal
    && left.graph_state.generation = right.graph_state.generation
    && left.write_enabled = right.write_enabled
    && left.capture_error == right.capture_error
    && left.capture_pick_request = right.capture_pick_request
    && left.capture_pick_source = right.capture_pick_source
    && left.import_completion = right.import_completion
    && left.environment.platform = right.environment.platform
  in
  let equal_calendar_projection left right =
    Option.equal
      (fun left right ->
         Journal_calendar.equal_projection_fingerprint
           (Journal_calendar.projection_fingerprint left)
           (Journal_calendar.projection_fingerprint right))
      left.calendar
      right.calendar
  in
  let error_info_available state =
    state.worker_errors <> []
    || Option.is_some (Option.bind state.manager (fun manager -> manager.last_error))
    || Option.is_some (operation_failure state.timeline_notice)
  in
  let equal_root_presentation left right =
    if (not left.graph_ready) || not right.graph_ready
    then left == right
    else
      left.graph_state.generation = right.graph_state.generation
      && left.environment.platform = right.environment.platform
      && Journal_routes.destination left.routes = Journal_routes.destination right.routes
      && same_actions left right
      && left.reference_sources == right.reference_sources
      && left.feed_loaded = right.feed_loaded
      && left.graph_error == right.graph_error
      && (Option.is_none left.graph_error
          || error_info_available left = error_info_available right)
      && equal_calendar_projection left right
      &&
      match Journal_routes.destination left.routes with
      | Journals -> left.timeline_structure_revision = right.timeline_structure_revision
      | Favorites ->
        let module F = Journal_routes.Favorites in
        F.revision left.favorites = F.revision right.favorites
        && F.loading left.favorites = F.loading right.favorites
        && F.error left.favorites = F.error right.favorites
        && F.initialized left.favorites = F.initialized right.favorites
        && F.has_more left.favorites = F.has_more right.favorites
  in
  let equal_detail_presentation left right =
    left.graph_state.generation = right.graph_state.generation
    && Journal_routes.route left.routes = Journal_routes.route right.routes
    && Journal_routes.detail_request_generation left.routes
       = Journal_routes.detail_request_generation right.routes
    && Option.equal
         Journal_detail.equal_presentation
         (Journal_routes.detail left.routes)
         (Journal_routes.detail right.routes)
    && same_actions left right
    && left.reference_sources == right.reference_sources
    && left.import_completion = right.import_completion
    && left.asset_import_request = right.asset_import_request
    && left.asset_import_owner = right.asset_import_owner
    && left.graph_ready = right.graph_ready
    && operation_failure left.timeline_notice = operation_failure right.timeline_notice
  in
  let equal_modal_presentation left right =
    match left.modal, right.modal with
    | No_modal, No_modal -> true
    | Capture_sheet, Capture_sheet -> equal_capture_presentation left right
    | Append_sheet, Append_sheet ->
      Journal_routes.active_entry_id left.routes
      = Journal_routes.active_entry_id right.routes
      && Option.equal
           (fun left right ->
              Journal_detail.child_capture left == Journal_detail.child_capture right
              && Journal_detail.mode left = Journal_detail.mode right)
           (Journal_routes.detail left.routes)
           (Journal_routes.detail right.routes)
      && Journal_routes.detail_request_generation left.routes
         = Journal_routes.detail_request_generation right.routes
      && left.write_enabled = right.write_enabled
      && left.capture_error == right.capture_error
    | _ -> left == right
  in
  let equal_shell_presentation left right =
    left.graph_state.generation = right.graph_state.generation
    && left.graph_state.graph_id = right.graph_state.graph_id
    && left.environment.platform = right.environment.platform
  in
  let body_view model_signal header_signal state dispatch timeline_scroll_completed =
    let region name ~equal build =
      V.of_lui
        (Lui_elements.stack
           ~key:("region:" ^ name ^ ":" ^ string_of_int state.graph_state.generation)
           [ Lui_elements.dyn
               ~equal
               (fun current ->
                  on_view_region name;
                  Journal_view.mount (V.column [ build current ]))
               model_signal
           ])
    in
    let capture_saving state =
      match state.direct_capture with
      | Some capture -> Journal_capture.phase capture = Journal_capture.Saving
      | None -> false
    in
    let row_actions_enabled state =
      state.write_enabled
      && Option.is_none state.pending_delete
      && Option.is_none state.pending_status
    in
    let capture_assets state ~camera =
      { request =
          Journal_asset_import.staged_request
            ~id:state.capture_pick_request
            ~source:state.capture_pick_source
      ; camera
      ; completion = state.import_completion
      ; on_attach =
          (fun source ->
            Ui.Event.Handler.Private.invoke
              dispatch
              (Text ("capture-attach:" ^ Journal_asset_import.source_to_string source)))
      ; on_event =
          (fun payload ->
            Ui.Event.Handler.Private.invoke dispatch (Text ("capture-asset:" ^ payload)))
      }
    in
    let floating_capture state =
      (* On iOS the capture composer expands directly into the bottom bar
           instead of presenting a sheet. It is mounted through the body
           overlay (see the toolbar view above) whose column already ends at
           the bottom safe-area boundary, so the capsule needs no extra
           inset. *)
      match state.modal with
      | Capture_sheet when state.environment.platform = "ios" ->
        Option.map
          (fun capture ->
             V.column
               ~spacing:0.
               [ composer_content
                   ~scope:"journal-capture"
                   ~placeholder:"New journal entry"
                   ~saving:(Journal_capture.phase capture = Journal_capture.Saving)
                   ~capture
                   ~enabled:state.write_enabled
                   ~on_edit:dispatch
                   ~on_toggle:
                     (Ui.Event.Handler.create (function
                        | Ui.Event.Payload.Bool selected ->
                          Ui.Event.Handler.Private.invoke
                            dispatch
                            (Text
                               (if selected then "capture-task-on" else "capture-task-off"))
                        | _ -> ()))
                   ~on_save:(bind_action dispatch "capture-submit")
                   ~error:
                     (match state.capture_error with
                      | Some failure -> Some (capture_failure_message failure)
                      | None ->
                        (match Journal_capture.phase capture with
                         | Failed message -> Some message
                         | Editing | Saving -> None))
                   ~assets:(Some (capture_assets state ~camera:true))
               ])
          state.direct_capture
      | _ -> None
    in
    let floating_capture =
      region "capture" ~equal:equal_capture_presentation (fun current ->
        if current.environment.platform = "ios" && current.modal = Capture_sheet
        then
          V.stack
            [ V.tap_area ~on_press:(bind_action dispatch "close-composer") ()
            ; V.column
                ~spacing:0.
                [ V.spacer ()
                ; Option.value (floating_capture current) ~default:(V.empty ())
                ]
            ]
        else V.empty ())
    in
    let root =
      region "root" ~equal:equal_root_presentation (fun state ->
        match state.graph_ready, state.manager with
        | false, Some _ -> manager_page state dispatch
        | false, None | true, _ ->
          timeline_page
            ~header_signal:(Some header_signal)
            ~timeline_store:(Some timeline_store)
            ~on_region:on_view_region
            ~render_source:(render_source state)
            ~render_media:
              (media_label ~store:media_store ~on_region:on_view_region state dispatch)
            ~render_row_media:(fun ~root ~image_children child ->
              on_view_region "timeline-row";
              row_media_label
                ~store:media_store
                ~on_region:on_view_region
                state
                dispatch
                ~root
                ~image_children
                child)
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
            ~sync_error:
              (Option.map
                 (fun notice -> sync_failure_message notice.failure)
                 state.sync_error)
            ~sync_phase:
              (Option.map
                 (fun (manager : Graph_service.snapshot) -> manager.sync_phase)
                 state.manager)
            ~day_presentation:(presentation_for_day state)
            ~capture_enabled:
              (state.write_enabled
               && Option.is_none state.pending_delete
               && Option.is_none state.pending_status
               && not (capture_saving state))
            ~on_capture_event:dispatch
            ~capture_expanded:None
            ~on_visible_range:dispatch
            ~on_retry_day:(prefix_action dispatch "timeline-retry:")
            ~on_open_block:(prefix_action dispatch "timeline-open-block:")
            ~on_open_favorite:(prefix_action dispatch "favorite-open-block:")
            ~delete_enabled:state.write_enabled
            ~actions_enabled:(row_actions_enabled state)
            ~interaction_enabled:true
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
            ~cache_reset_available:(local_deletion_available state))
    in
    let capture_adapter =
      region "capture-import" ~equal:equal_capture_presentation (fun current ->
        match current.direct_capture with
        | None -> V.empty ()
        | Some capture ->
          let assets =
            capture_assets current ~camera:(current.environment.platform = "ios")
          in
          Journal_asset_import.view
            ~key:(Ui.Key.string "journal-capture-asset-import")
            ~enabled:(current.write_enabled && Journal_capture.can_attach capture)
            ~completion:assets.completion
            ~request:assets.request
            ~pending:[]
            ~on_select:assets.on_event
            (V.Body.static (V.empty ())))
    in
    let navigator =
      V.of_lui (fun context parent ->
        let mapped =
          Signal.map (fun current -> Journal_routes.path current.routes) model_signal
        in
        let path_signal = Signal.cutoff ( == ) mapped in
        Signal.on_dispose context.Lui_ui.ui_scope (fun () ->
          Signal.dispose_signal path_signal;
          Signal.dispose_signal mapped);
        Lui_navigation.navigation_stack
          ~key:"journal-navigator"
          ~path_signal
          ~on_path_change:(fun path ->
            Effect.run
              (set_state (fun current ->
                 if current.graph_state.generation <> state.graph_state.generation
                 then current
                 else (
                   let routes = Journal_routes.accept_path current.routes path in
                   if routes == current.routes
                   then current
                   else { current with routes; modal = No_modal }))))
          ~root:(Lui_elements.column ~grow:1.0 [ Journal_view.mount root ])
          ~destination:(fun entry ->
            let initial =
              Option.value
                (Journal_routes.at_entry state.routes ~entry_id:entry.id)
                ~default:state.routes
            in
            let last = ref { state with routes = initial } in
            let projected =
              Signal.map
                (fun current ->
                   match Journal_routes.at_entry current.routes ~entry_id:entry.id with
                   | None -> !last
                   | Some routes ->
                     let focused = { current with routes } in
                     last := focused;
                     focused)
                model_signal
            in
            let local : Lui_elements.t =
              fun context parent ->
              Signal.on_dispose context.Lui_ui.ui_scope (fun () ->
                Signal.dispose_signal projected);
              Lui_elements.stack
                [ Lui_elements.dyn
                    ~equal:equal_detail_presentation
                    (fun focused ->
                       on_view_region "detail";
                       let completion =
                         Ui.Event.Handler.create (fun payload ->
                           match V.Native_list.completion_of_payload payload with
                           | None -> ()
                           | Some completion ->
                             Effect.run
                               (set_state (fun current ->
                                  match
                                    Journal_routes.at_entry
                                      current.routes
                                      ~entry_id:entry.id
                                  with
                                  | Some owner
                                    when current.graph_state.generation
                                         = focused.graph_state.generation
                                         && Journal_routes.detail_request_generation owner
                                            = Journal_routes.detail_request_generation
                                                focused.routes ->
                                    (match Journal_routes.detail owner with
                                     | None -> current
                                     | Some detail ->
                                       { current with
                                         routes =
                                           Journal_routes.update_detail_at
                                             current.routes
                                             ~entry_id:entry.id
                                             (Journal_detail.complete_reveal
                                                detail
                                                ~token:completion.token
                                                ~outcome:completion.outcome)
                                       })
                                  | _ -> current)))
                       in
                       Journal_view.mount
                         (detail_page
                            ~media_store
                            ~on_region:on_view_region
                            ~state:focused
                            ~on_scroll_completed:completion
                            dispatch
                          |> operation_feedback
                               ~scope:("detail:" ^ entry.id)
                               ~state:focused
                               dispatch))
                    projected
                ]
                context
                parent
            in
            Lui_elements.column ~grow:1.0 [ local ])
          ()
          context
          parent)
    in
    let modal state =
      let tokens =
        Journal_visual_tokens.resolve
          ~brightness:state.environment.brightness
          ~high_contrast:state.environment.high_contrast
      in
      match state.modal with
      | No_modal -> None
      | Capture_sheet ->
        if state.environment.platform = "ios"
        then None
        else
          Option.map
            (fun capture ->
               composer_page
                 ~scope:"journal-capture"
                 ~placeholder:"New journal entry"
                 ~saving:(Journal_capture.phase capture = Journal_capture.Saving)
                 ~capture
                 ~enabled:state.write_enabled
                 ~on_edit:dispatch
                 ~on_toggle:
                   (Ui.Event.Handler.create (function
                      | Ui.Event.Payload.Bool selected ->
                        Ui.Event.Handler.Private.invoke
                          dispatch
                          (Text
                             (if selected then "capture-task-on" else "capture-task-off"))
                      | _ -> ()))
                 ~on_save:(bind_action dispatch "capture-submit")
                 ~on_close:(bind_action dispatch "close-composer")
                 ~error:
                   (match state.capture_error with
                    | Some failure -> Some (capture_failure_message failure)
                    | None ->
                      (match Journal_capture.phase capture with
                       | Failed message -> Some message
                       | Editing | Saving -> None))
                 ~assets:
                   (Some
                      (capture_assets state ~camera:(state.environment.platform = "ios"))))
            state.direct_capture
      | Append_sheet ->
        Option.bind (Journal_routes.detail state.routes) (fun detail ->
          Option.map
            (fun capture ->
               composer_page
                 ~scope:"journal-append"
                 ~placeholder:"Append a block"
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
                 ~assets:None
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
    let modal_title = function
      | No_modal -> ""
      | Capture_sheet -> "Capture"
      | Append_sheet -> "Append"
      | Status_sheet _ -> "Set status"
      | Cache_reset_confirmation _ -> "Delete local graph copy?"
      | Diagnostics -> "Diagnostics"
      | Error_info -> "Error info"
    in
    let modal =
      region "modal" ~equal:equal_modal_presentation (fun current ->
        let content =
          if current.modal = Capture_sheet && current.environment.platform = "ios"
          then None
          else modal current
        in
        V.Sheet.create
          ~key:(Ui.Key.string "journal-sheet")
          ~title:(modal_title current.modal)
          ~presented:(Option.is_some content)
          ~on_presented_changed:dispatch
          ~interactive_dismiss:true
          ~sizing:Form
          ~detents:[ Large ]
          ~content:(Option.value content ~default:(V.empty ()))
          (V.empty ()))
    in
    let confirmations =
      region
        "confirmation"
        ~equal:(fun left right ->
          left.modal = right.modal
          && left.confirmation_sequence = right.confirmation_sequence)
        (fun current ->
           Cache_confirmation.local_cache
             ~token:
               (match current.modal with
                | Cache_reset_confirmation _ -> Some current.confirmation_sequence
                | _ -> None)
             dispatch
             (V.empty ()))
    in
    let feedback =
      region
        "feedback"
        ~equal:(fun left right -> left.timeline_notice = right.timeline_notice)
        (fun current ->
           if current.timeline_notice = None
           then V.empty ()
           else
             operation_feedback
               ~scope:"root"
               ~state:current
               dispatch
               (V.Body.static (V.empty ())))
    in
    let settings =
      region
        "settings"
        ~equal:(fun left right ->
          left.uploads == right.uploads
          && left.asset_offline = right.asset_offline
          && left.asset_settings_open = right.asset_settings_open)
        (fun current ->
           Journal_asset_settings.view
             ~uploads:
               (Journal_uploads.rows
                  (Journal_uploads.sync current.uploads (upload_context current)))
             ~offline:current.asset_offline
             ~presented:current.asset_settings_open
             ~on_event:(fun value ->
               Ui.Event.Handler.Private.invoke dispatch (Text ("asset-settings:" ^ value)))
             (V.empty ()))
    in
    let body =
      V.stack
        [ navigator
        ; floating_capture
        ; capture_adapter
        ; modal
        ; confirmations
        ; feedback
        ; settings
        ]
    in
    V.Body.theme ~data:(application_theme ()) (V.Body.static body)
  in
  let view context model_signal _send =
    let header_signal =
      Signal.map
        (fun state ->
           { Journal_header.sync_phase =
               Option.map
                 (fun (manager : Graph_service.snapshot) -> manager.sync_phase)
                 state.manager
           ; sync_error =
               Option.map
                 (fun notice -> sync_failure_message notice.failure)
                 state.sync_error
           ; error_available =
               state.worker_errors <> []
               || Option.is_some
                    (Option.bind state.manager (fun manager -> manager.last_error))
               || Option.is_some (operation_failure state.timeline_notice)
           ; local_deletion_available = local_deletion_available state
           ; capture_enabled =
               state.write_enabled
               && Option.is_none state.pending_delete
               && Option.is_none state.pending_status
               && not (capture_saving state)
           })
        model_signal
    in
    Signal.on_dispose context.Lui_ui.ui_scope (fun () ->
      Signal.dispose_signal header_signal);
    (* Dynamic elements mount under a parent, so the root must be a static
       container. *)
    Lui_elements.column
      [ Lui_elements.dyn
          ~equal:equal_shell_presentation
          (fun model ->
             Journal_view.mount
               (body_view
                  model_signal
                  header_signal
                  model
                  dispatch
                  timeline_scroll_completed))
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
  (* The worker fires the wakeup on its own domain whenever output lands;
     enqueueing hops through the host wakeup onto the UI thread. An OCaml
     Condition waiter thread would deadlock against the worker domain (the
     woken waiter holds the output mutex while blocked on its domain lock
     which the UI thread holds inside its runloop). *)
  Worker.Private.set_output_wakeup client (fun () ->
    Journal_pump.enqueue pump (fun () -> ()));
  (* Kick once to drain any output emitted before the wakeup was installed. *)
  Journal_pump.enqueue pump (fun () -> ());
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

let create
      ?(on_view_region = fun _ -> ())
      ?on_client
      ?(calendar_sampler = fun () -> Journal_calendar.Sampler.create ())
      ~service
      ()
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
                  ~on_view_region
                  ~calendar_sampler:(calendar_sampler ())
                  ~client
                  ~platform_code
                  ~host_code);
             Option.iter (fun observe -> observe client) on_client
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
  let timeline_media_row ~routes ~graph_generation entry dispatch =
    let state =
      { initial_state with
        routes
      ; graph_state = { initial_state.graph_state with generation = graph_generation }
      }
    in
    Journal_row.view
      ~render_media:(row_media_label state dispatch)
      ~show_timestamp:false
      entry
  ;;

  let detail_page ~routes ~write_enabled dispatch =
    detail_page
      ~state:{ initial_state with routes; write_enabled }
      ~on_scroll_completed:(Ui.Event.Handler.create (fun _ -> ()))
      dispatch
  ;;

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
      ~header_signal:None
      ~timeline_store:None
      ~on_region:(fun _ -> ())
      ~render_source:(render_source initial_state)
      ~render_media:(media_label initial_state handler)
      ~render_row_media:(row_media_label initial_state handler)
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
      ~capture_expanded:None
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

  let app_with_service ?on_client ?on_view_region ?calendar_sampler service =
    let calendar_sampler = Option.map (fun sampler () -> sampler) calendar_sampler in
    create ?on_client ?on_view_region ?calendar_sampler ~service ()
  ;;
end

let native_hooks = create ~service:Graph_service.service ()
