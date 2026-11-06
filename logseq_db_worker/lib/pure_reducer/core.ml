module Read = Worker_pure_read

type graph_phase =
  | Graph_closed
  | Graph_opening
  | Graph_open
  | Graph_closing
  | Graph_failed

type graph_state =
  { generation : int
  ; graph_id : Logseq_db_types.Graph_types.Uuid.t option
  ; phase : graph_phase
  ; error : Logseq_db_worker_contract.Error.t option
  }

type request_id = int64

let request_id_of_int64 value = value
let request_id_to_int64 value = value
let equal_request_id = Int64.equal

type database_handle = string

type database_opened =
  { database : database_handle
  ; graph_id : Logseq_db_types.Graph_types.Uuid.t
  }

let database_opened ~database_id ~graph_id = { database = database_id; graph_id }
let database_handle_id handle = handle
let opened_database_handle opened = opened.database
let opened_graph_id opened = opened.graph_id

type effect_id = int64

type ticket =
  { id : effect_id
  ; generation : int
  }

let effect_id_to_string = Int64.to_string

type lifecycle_result =
  | Lifecycle_unchanged
  | Lifecycle_opened of database_opened * int
  | Lifecycle_closed of int
  | Lifecycle_failed of int * Logseq_db_worker_contract.Error.t

type sync_worker_result =
  { event : Logseq_sync_pure_reducer.Core.event option
  ; lifecycle : lifecycle_result
  }

type _ runner_request =
  | Execute_request :
      { database : database_handle
      ; read : Worker_pure_read.packed_query
      }
      -> Worker_pure_read.answer runner_request
  | Close_database : database_handle -> unit runner_request
  | Handle_sync_worker_effect :
      Logseq_sync_pure_reducer.Core.worker_effect
      -> sync_worker_result runner_request

type runner_effect = Request : ticket * 'a runner_request -> runner_effect
type effect_error = Logseq_db_worker_contract.Error.t

type runner_completion =
  | Execute_request_completed of
      ticket * (Worker_pure_read.answer, effect_error) result
  | Close_database_completed of ticket * (unit, effect_error) result
  | Sync_worker_effect_completed of ticket * (sync_worker_result, effect_error) result

type asset_notice =
  | Asset_availability of
      { consumer : string
      ; asset : Logseq_db_types.Graph_types.Uuid.t
      ; descriptor : Logseq_db_types.Asset_descriptor.t
      ; availability : Logseq_sync_pure_reducer.Asset_transfer.availability
      }
  | Asset_demand_accepted of string
  | Asset_backpressure of string
  | Asset_capacity_available
  | Upload_status of
      { operation : Logseq_db_types.Graph_types.Uuid.t
      ; asset : Logseq_db_types.Graph_types.Uuid.t
      ; target : Logseq_db_types.Graph_types.Uuid.t
      ; title : string
      ; status : Asset_upload.status
      }

type output =
  | Asset_notice of Logseq_sync_pure_reducer.Core.graph_scope * asset_notice
  | Reply of request_id * Worker_pure_read.answer
  | Graph_push of Worker_pure_data.changefeed_signal
  | Sync_output of Logseq_sync_pure_reducer.Core.output
  | Graph_state_changed of graph_state
  | Scoped_graph_state_changed of Logseq_sync_pure_reducer.Core.graph_scope * graph_state
  | Scoped_graph_push of Logseq_sync_pure_reducer.Core.graph_scope * Worker_pure_data.changefeed_signal
  | Diagnostic of string

type upload_recovery_ticket =
  { scope : Logseq_sync_pure_reducer.Core.graph_scope
  ; after : Logseq_db_types.Graph_types.Uuid.t option
  ; limit : int
  ; serial : int
  }

type instruction =
  | Sync_io_fence_reached of int64 * Logseq_sync_pure_reducer.Core.effect_scope * (unit,string) result
  | Asset_cleanup_barrier_reached of int64
  | Deliver_protected_result of Logseq_sync_pure_reducer.Core.protected_output
  | Deliver_asset_result of Logseq_sync_pure_reducer.Core.asset_output
  | Read_uploads of upload_recovery_ticket
  | Run_upload of Logseq_sync_pure_reducer.Core.asset_context * Asset_upload.instruction
  | Run_asset of
      Logseq_sync_pure_reducer.Core.asset_context
      * Logseq_sync_pure_reducer.Asset_transfer.instruction
  | Close_asset_scope of Logseq_sync_pure_reducer.Core.graph_scope
  | Run_worker of runner_effect
  | Run_sync of Logseq_sync_pure_reducer.Core.runner_effect
  | Publish of output

module Sync = Logseq_sync_pure_reducer.Core

let instruction_diagnostic = function
  | Sync_io_fence_reached _->"sync-io-fence"
  | Asset_cleanup_barrier_reached _ -> "asset-cleanup-barrier"
  | Deliver_protected_result _ -> "deliver-protected-result"
  | Deliver_asset_result _ -> "deliver-asset-result"
  | Read_uploads _ -> "read-uploads"
  | Run_upload _ -> "run-upload"
  | Run_asset _ -> "run-asset"
  | Close_asset_scope _ -> "close-asset-scope"
  | Publish (Asset_notice _) -> "publish:asset-notice"
  | Run_worker (Request (_, Execute_request _)) -> "run-worker:Execute_request"
  | Run_worker (Request (_, Close_database _)) -> "run-worker:Close_database"
  | Run_worker (Request (_, Handle_sync_worker_effect _)) ->
    "run-worker:Handle_sync_worker_effect"
  | Run_sync sync_effect -> "run-sync:" ^ Sync.runner_effect_diagnostic sync_effect
  | Publish (Reply _) -> "publish:reply"
  | Publish (Graph_push _ | Scoped_graph_push _) -> "publish:graph-push"
  | Publish (Sync_output _) -> "publish:sync-output"
  | Publish (Graph_state_changed _ | Scoped_graph_state_changed _) -> "publish:graph-state"
  | Publish (Diagnostic _) -> "publish:diagnostic"
;;

let equal_instruction left right =
  match left, right with
  | Sync_io_fence_reached(li,ls,lr),Sync_io_fence_reached(ri,rs,rr)->li=ri && ls=rs && lr=rr
  | Asset_cleanup_barrier_reached l,Asset_cleanup_barrier_reached r->l=r
  | Deliver_protected_result l, Deliver_protected_result r -> l = r
  | Deliver_asset_result l, Deliver_asset_result r -> l = r
  | Read_uploads l, Read_uploads r -> l = r
  | Run_upload (lc, li), Run_upload (rc, ri) -> lc = rc && li = ri
  | Run_asset (lc, li), Run_asset (rc, ri) -> lc = rc && li = ri
  | Close_asset_scope left, Close_asset_scope right -> left = right
  | Run_sync left, Run_sync right -> Sync.equal_runner_effect left right
  | Run_worker left, Run_worker right -> left = right
  | Publish left, Publish right -> left = right
  | ( ( Sync_io_fence_reached _
      | Asset_cleanup_barrier_reached _
      | Run_worker _
      | Run_sync _
      | Run_asset _
      | Run_upload _
      | Read_uploads _
      | Deliver_protected_result _
      | Deliver_asset_result _
      | Close_asset_scope _
      | Publish _ )
    , _ ) -> false
;;

let equal_instructions left right =
  List.length left = List.length right && List.for_all2 equal_instruction left right
;;

type config = Sync.config

let config ~worker:_ ~sync = sync

type view =
  { graph : graph_state
  ; sync : Sync.state
  ; pending_requests : int
  ; pending_effects : int
  ; shutdown : bool
  }

type pending =
  | Pending_execute of request_id * Read.packed_query * ticket
  | Pending_sync_worker of ticket * Sync.worker_effect

type graph_session =
  { owner : Sync.graph_scope
  ; saved_graph : graph_state
  ; saved_assets : (Sync.asset_context * Logseq_sync_pure_reducer.Asset_transfer.t) option
  ; saved_recovery : (Sync.graph_scope * Logseq_db_types.Graph_types.Uuid.t option * bool) option
  ; saved_recovery_pending : upload_recovery_ticket option
  ; saved_recovery_serial : int
  ; saved_uploads : (Sync.asset_context * Logseq_db_types.Graph_types.Uuid.t * Asset_upload.t) list
  ; saved_database : database_handle option
  ; saved_deferred_detach : Sync.graph_scope option
  ; saved_pending : pending list
  }

type state =
  { account_reset : Sync.account_scope option
  ; resident_mode : bool
  ; active_scope : Sync.graph_scope option
  ; graph_sessions : graph_session list
  ; graph : graph_state
  ; sync_core : Sync.t
  ; assets : (Sync.asset_context * Logseq_sync_pure_reducer.Asset_transfer.t) option
  ; recovery :
      (Sync.graph_scope * Logseq_db_types.Graph_types.Uuid.t option * bool) option
  ; recovery_pending : upload_recovery_ticket option
  ; recovery_serial : int
  ; uploads :
      (Sync.asset_context * Logseq_db_types.Graph_types.Uuid.t * Asset_upload.t) list
  ; foreground : bool
  ; database : database_handle option
  ; deferred_detach : Sync.graph_scope option
  ; pending : pending list
  ; next_effect_id : int64
  ; lifecycle_generation : int64
  ; shutdown : bool
  }

type create_error = Invalid_create of string

let initial config =
  Sync.initial config
  |> Result.map_error (fun (Sync.Invalid_create message) -> Invalid_create message)
  |> Result.map (fun sync_core ->
    { account_reset = None
    ; resident_mode = false
    ; active_scope = None
    ; graph_sessions = []
    ; graph = { generation = 0; graph_id = None; phase = Graph_closed; error = None }
    ; sync_core
    ; assets = None
    ; recovery = None
    ; recovery_pending = None
    ; recovery_serial = 0
    ; uploads = []
    ; foreground = true
    ; database = None
    ; deferred_detach = None
    ; pending = []
    ; next_effect_id = 0L
    ; lifecycle_generation = 0L
    ; shutdown = false
    })
;;

let view state =
  { graph = state.graph
  ; sync = Sync.state state.sync_core
  ; pending_requests =
      List.fold_left
        (fun count -> function
           | Pending_execute _ -> count + 1
           | Pending_sync_worker _ -> count)
        0
        state.pending
  ; pending_effects = List.length state.pending
  ; shutdown = state.shutdown
  }
;;

let equal_view left right = left = right

type event =
  | Asset_cleanup_barrier of int64
  | Upload_requested of
      { graph_generation : int
      ; operation : Logseq_db_types.Graph_types.Uuid.t
      ; event : Asset_upload.event
      }
  | Uploads_loaded of
      upload_recovery_ticket * (Logseq_db_types.Asset_upload_intent.t list, string) result
  | Upload_completed of Asset_upload.ticket * Asset_upload.completion
  | Asset_requested of
      { graph_generation : int
      ; event : Logseq_sync_pure_reducer.Asset_transfer.event
      }
  | Asset_completed of
      Logseq_sync_pure_reducer.Core.graph_scope
      * Logseq_sync_pure_reducer.Asset_transfer.event
  | Graph_request_for_scope of
      { scope : Logseq_sync_pure_reducer.Core.graph_scope
      ; id : request_id
      ; read : Worker_pure_read.packed_query
      }
  | Projection_push_for_scope of Logseq_sync_pure_reducer.Core.graph_scope * Worker_pure_data.changefeed_signal
  | Asset_requested_for_scope of Logseq_sync_pure_reducer.Core.graph_scope * Logseq_sync_pure_reducer.Asset_transfer.event
  | Upload_requested_for_scope of Logseq_sync_pure_reducer.Core.graph_scope * Logseq_db_types.Graph_types.Uuid.t * Asset_upload.event
  | Start
  | Graph_request of
      { id : request_id
      ; read : Worker_pure_read.packed_query
      }
  | Sync_event of Sync.event
  | Projection_push of Worker_pure_data.changefeed_signal
  | Set_foreground of bool
  | Runner_completed of runner_completion
  | Shutdown

type transition =
  { next : state
  ; effects : instruction list
  }

let no_effects next = { next; effects = [] }

let fresh_ticket state =
  let ticket = { id = state.next_effect_id; generation = state.graph.generation } in
  ticket, { state with next_effect_id = Int64.succ state.next_effect_id }
;;

let pending_id = function
  | Pending_execute (_, _, ticket) | Pending_sync_worker (ticket, _) -> ticket.id
;;

let remove_pending id values =
  List.filter (fun pending -> not (Int64.equal id (pending_id pending))) values
;;

let has_pending id values =
  List.exists (fun pending -> Int64.equal id (pending_id pending)) values
;;

let failed_read (Read.Read_query(budget,query)) error =
  Read.For_worker.answer budget query (Error error)
;;
let unavailable_response read message = failed_read read (Read.Service_failed message)
;;


let graph_pending = function
  | Pending_sync_worker (_,(Sync.Reset_managed_account _ | Sync.Delete_mirror _)) -> false
  | _ -> true
let freeze_graph owner state =
  {owner
  ; saved_graph = state.graph
  ; saved_assets = state.assets
  ; saved_recovery = state.recovery
  ; saved_recovery_pending = state.recovery_pending
  ; saved_recovery_serial = state.recovery_serial
  ; saved_uploads = state.uploads
  ; saved_database = state.database
  ; saved_deferred_detach = state.deferred_detach
  ; saved_pending = List.filter graph_pending state.pending
  }
let remember_graph state =
  let owner=match state.active_scope,state.graph.graph_id with
    | Some scope,_ -> Some scope
    | None,Some id -> (match Sync.scope_for_graph state.sync_core ~graph_id:id with
        | Some scope when scope.graph_generation=state.graph.generation -> Some scope | _ -> None)
    | None,None -> None in
  match owner with
  | None -> state
  | Some owner -> {state with active_scope=Some owner;
      graph_sessions=freeze_graph owner state :: List.filter (fun s->s.owner<>owner) state.graph_sessions}
let load_graph state (owner:Sync.graph_scope) =
  let state=remember_graph state in
  match List.find_opt (fun s->s.owner=owner) state.graph_sessions with
  | Some saved -> {state with active_scope=Some owner
    ; graph = saved.saved_graph
    ; assets = saved.saved_assets
    ; recovery = saved.saved_recovery
    ; recovery_pending = saved.saved_recovery_pending
    ; recovery_serial = saved.saved_recovery_serial
    ; uploads = saved.saved_uploads
    ; database = saved.saved_database
    ; deferred_detach = saved.saved_deferred_detach
    ; pending = List.filter (fun p->not(graph_pending p)) state.pending @ saved.saved_pending
    }
  | None -> {state with active_scope=Some owner;
      graph={generation=owner.graph_generation;graph_id=Some owner.graph_id;phase=Graph_opening;error=None};
      assets=None;recovery=None;recovery_pending=None;recovery_serial=0;uploads=[];
      database=None;deferred_detach=None;pending=[]}
let restore_visible_graph state =
  match Sync.admitted_graph_scope state.sync_core with
  | Some scope -> load_graph state scope
  | None -> state
let graph_publication state graph =
  match state.active_scope with
  | Some scope when state.resident_mode ->
    Publish (Scoped_graph_state_changed (scope,graph))
  | _ -> Publish (Graph_state_changed graph)
let worker_effect_scope = function
  | Sync.Inspect_mirror {scope;_} | Attach_graph {scope;_} | Detach_graph scope
  | Inspect_sync scope | Apply_outbox_transition {scope;_} -> Some scope
  | Activate_snapshot activation -> Some (Sync.snapshot_activation_scope activation)
  | Apply_authoritative_batch {scope;_} -> Some scope.graph
  | Reset_managed_account _ | Delete_mirror _ -> None
;;

let translate_sync transition state =
  let resident_mode=state.resident_mode || (Sync.state transition.Sync.next).snapshot.resident_graphs<>[] in
  let state = { (remember_graph state) with sync_core = transition.Sync.next;resident_mode } in
  let rec loop state reversed = function
    | [] -> { next = remember_graph state; effects = List.rev reversed }
    | Sync.Run sync_effect :: rest -> loop state (Run_sync sync_effect :: reversed) rest
    | Sync.Publish (Sync.Protected_finished output) :: rest ->
      loop state (Deliver_protected_result output :: reversed) rest
    | Sync.Publish (Sync.Asset_finished output) :: rest ->
      loop state (Deliver_asset_result output :: reversed) rest
    | Sync.Publish output :: rest ->
      loop state (Publish (Sync_output output) :: reversed) rest
    | Sync.Delegate (Sync.Detach_graph scope) :: rest ->
      let state = if not state.resident_mode then state else load_graph state scope in
      let graph = { state.graph with phase = Graph_closing } in
      loop
        { state with graph; deferred_detach = Some scope }
        (graph_publication state graph :: reversed)
        rest
    | Sync.Delegate (Sync.Reset_managed_account account) :: rest ->
      let state=remember_graph state in
      let sessions=List.map (fun session ->
        if session.saved_database=None then session else
          {session with saved_graph={session.saved_graph with phase=Graph_closing};
            saved_deferred_detach=Some session.owner}) state.graph_sessions in
      let state={state with account_reset=Some account;graph_sessions=sessions} in
      let state=match state.active_scope with
        | None->state | Some scope ->
          (match List.find_opt (fun s->s.owner=scope) sessions with
           | None->state | Some session->{state with graph=session.saved_graph;deferred_detach=session.saved_deferred_detach}) in
      loop state reversed rest
    | Sync.Delegate worker_effect :: rest ->
      let state = if not state.resident_mode then state
        else Option.fold ~none:state ~some:(load_graph state) (worker_effect_scope worker_effect) in
      let ticket, state = fresh_ticket state in
      let state =
        { state with
          pending = Pending_sync_worker (ticket, worker_effect) :: state.pending
        }
      in
      loop
        state
        (Run_worker (Request (ticket, Handle_sync_worker_effect worker_effect))
         :: reversed)
        rest
  in
  loop state [] transition.effects
;;

let apply_lifecycle state = function
  | Lifecycle_unchanged -> state, []
  | Lifecycle_opened (opened, generation) ->
    let graph =
      { generation; graph_id = Some opened.graph_id; phase = Graph_open; error = None }
    in
    ( { state with graph; database = Some opened.database }
    , [ graph_publication state graph ] )
  | Lifecycle_closed generation ->
    let graph = { generation; graph_id = None; phase = Graph_closed; error = None } in
    { state with graph; database = None }, [ graph_publication state graph ]
  | Lifecycle_failed (generation, error) ->
    let graph =
      { state.graph with generation; phase = Graph_failed; error = Some error }
    in
    { state with graph; database = None }, [ graph_publication state graph ]
;;

let execute_completion state ticket result =
  match List.find_map (function
    | Pending_execute(id,read,candidate) when candidate.id=ticket.id -> Some(id,read)
    | _ -> None) state.pending with
  | None -> no_effects state
  | Some(id,read) ->
    let response=match result with Ok answer->answer|Error error->failed_read read (Read.Db_error error) in
    {next={state with pending=remove_pending ticket.id state.pending};effects=[Publish(Reply(id,response))]}
;;

let failure_diagnostic error =
  let module D = Logseq_db_types.Failure_diagnostic in
  List.find_map
    (fun (detail : Logseq_db_worker_contract.Error.detail) ->
       match detail.name, detail.value with
       | name, Detail_string source when name = D.detail_name -> D.decode source
       | _ -> None)
    (Logseq_db_worker_contract.Error.details error)
;;

let failure_signal fallback error =
  let module D = Logseq_db_types.Failure_diagnostic in
  Option.fold
    ~none:fallback
    ~some:(fun value -> D.signal_prefix ^ D.encode value)
    (failure_diagnostic error)
;;

let report_sync_failure state transition signal =
  (* Sync owns scope acceptance. An ignored completion must not be re-labelled
     as an error belonging to whichever graph is now on screen. *)
  if Sync.state transition.next.sync_core = Sync.state state.sync_core
  then transition
  else { transition with effects = Publish (Diagnostic signal) :: transition.effects }
;;

let step state event =
  if state.shutdown
  then (
    match event with
    | Sync_event
        (( Sync.Asset_requested _ | Sync.Protected_requested _ | Sync.Shutdown
         | Sync.Runner_completed (Sync.Asset_completion _ | Sync.Protected_completion _)
           ) as event) -> translate_sync (Sync.step state.sync_core event) state
    | _ -> no_effects state)
  else (
    match event with
    | Asset_cleanup_barrier _
    | Uploads_loaded _
    | Upload_requested _
    | Upload_completed _
    | Asset_requested _
    | Asset_completed _ -> no_effects state
    | Graph_request_for_scope _ | Projection_push_for_scope _
    | Asset_requested_for_scope _ | Upload_requested_for_scope _ -> no_effects state
    | Start -> no_effects state
    | Projection_push push ->
      if
        state.graph.phase = Graph_open
        && Sync.admitted_graph_scope state.sync_core <> None
      then { next = state; effects = [ Publish (Graph_push push) ] }
      else no_effects state
    | Graph_request { id; read } ->
      let Read.Read_query(budget,query)=read in
      let owner=Read.For_worker.read_budget_owner budget in
      (match Read.validate_query owner budget query with
       | Error error -> {next=state;effects=[Publish(Reply(id,failed_read read error))]}
       | Ok () -> match state.graph.phase,state.database with
         | Graph_open,Some database ->
           let ticket,state=fresh_ticket state in
           {next={state with pending=Pending_execute(id,read,ticket)::state.pending};
            effects=[Run_worker(Request(ticket,Execute_request{database;read}))]}
         | _ -> {next=state;effects=[Publish(Reply(id,unavailable_response read "The graph is not open."))]})
    | Sync_event event -> translate_sync (Sync.step state.sync_core event) state
    | Set_foreground foreground ->
      let lifecycle_generation = Int64.succ state.lifecycle_generation in
      let state = { state with lifecycle_generation; foreground } in
      translate_sync
        (Sync.step
           state.sync_core
           (Sync.Foreground_changed { foreground; lifecycle_generation }))
        state
    | Runner_completed (Execute_request_completed (ticket, result)) ->
      if
        ticket.generation <> state.graph.generation
        || not (has_pending ticket.id state.pending)
      then no_effects state
      else execute_completion state ticket result
    | Runner_completed (Close_database_completed _) -> no_effects state
    | Runner_completed (Sync_worker_effect_completed (ticket, result)) ->
      if
        not (has_pending ticket.id state.pending)
        || (ticket.generation <> state.graph.generation && not (List.exists (function
          | Pending_sync_worker (candidate,(Sync.Reset_managed_account _ | Sync.Delete_mirror _))->candidate.id=ticket.id
          | _->false) state.pending))
      then no_effects state
      else (
        let worker_effect =
          List.find_map
            (function
              | Pending_sync_worker (candidate, worker_effect)
                when Int64.equal candidate.id ticket.id -> Some worker_effect
              | Pending_sync_worker _ | Pending_execute _ -> None)
            state.pending
        in
        let state = { state with pending = remove_pending ticket.id state.pending } in
        match result with
        | Error error ->
          let message = Logseq_db_worker_contract.Error.message error in
          (match worker_effect with
           | Some (Sync.Inspect_mirror request) ->
             let changed=translate_sync
               (Sync.step state.sync_core (Sync.Graph_attachment_failed
                  {scope=Sync.effect_scope_of_graph request.scope;message})) state in
             report_sync_failure state changed (failure_signal "worker.inspectMirror" error)
           | Some (Sync.Attach_graph request) ->
             let changed=translate_sync
               (Sync.step state.sync_core (Sync.Graph_attachment_failed
                  {scope=Sync.effect_scope_of_graph request.scope;message})) state in
             report_sync_failure state changed (failure_signal "worker.attachGraph" error)
           | Some (Sync.Inspect_sync scope) ->
             let changed=translate_sync
               (Sync.step state.sync_core (Sync.Graph_attachment_failed
                  {scope=Sync.effect_scope_of_graph scope;message})) state in
             report_sync_failure state changed (failure_signal "worker.inspectSync" error)
           | Some (Sync.Activate_snapshot request) ->
             let changed=translate_sync
               (Sync.step state.sync_core
                  (Sync.Snapshot_activation_failed (Sync.snapshot_activation_failed request ~message))) state in
             report_sync_failure state changed (failure_signal "worker.activateSnapshot" error)
           | Some (Sync.Apply_authoritative_batch request) ->
             let transitioned =
               translate_sync
                 (Sync.step
                    state.sync_core
                    (Sync.Authoritative_batch_failed
                       { scope = Sync.effect_scope_of_graph request.scope.graph; message }))
                 state
             in
             let origin = (Logseq_db_worker_contract.Error.trace error).origin in
             let signal =
               match origin.component, origin.operation, origin.code with
               | Managed_sync, "applyAuthoritative", Some ("authoritativeDecodeFailed" | "authoritativeIntegrityFailure" as category) ->
                 let module Diagnostic = Logseq_db_types.Authoritative_diagnostic in
                 let detail = List.find_map (fun (detail:Logseq_db_worker_contract.Error.detail) ->
                   match detail.name,detail.value with
                   | name,Detail_string source when name=Diagnostic.detail_name -> Diagnostic.decode source
                   | _ -> None) (Logseq_db_worker_contract.Error.details error) in
                 Option.fold ~none:("worker.applyAuthoritative." ^ category)
                   ~some:(fun value -> (if category="authoritativeIntegrityFailure" then Diagnostic.integrity_signal_prefix else Diagnostic.signal_prefix) ^ Diagnostic.encode value) detail
               | Managed_sync, "applyAuthoritative", Some category ->
                 "worker.applyAuthoritative." ^ category
               | _ -> "worker.applyAuthoritative"
             in
             report_sync_failure state transitioned (failure_signal signal error)
           | Some (Sync.Apply_outbox_transition request) ->
             let transitioned =
               translate_sync
                 (Sync.step
                    state.sync_core
                    (Sync.Outbox_transition_failed { request; message }))
                 state
             in
             report_sync_failure state transitioned (failure_signal "worker.applyOutbox" error)
           | Some (Sync.Detach_graph scope) ->
             let changed=translate_sync
               (Sync.step state.sync_core (Sync.Graph_detached (scope, Error message))) state in
             report_sync_failure state changed (failure_signal "worker.closeDatabase" error)
           | Some (Sync.Delete_mirror request) ->
             let changed=translate_sync
               (Sync.step state.sync_core (Sync.Mirror_deleted (request, Error message))) state in
             report_sync_failure state changed (failure_signal "worker.deleteMirror" error)
           | Some _ | None ->
             let code = match worker_effect with
               | Some (Sync.Inspect_mirror _) -> "worker.inspectMirror"
               | Some (Sync.Attach_graph _) -> "worker.attachGraph"
               | Some (Sync.Inspect_sync _) -> "worker.inspectSync"
               | Some (Sync.Reset_managed_account _) -> "worker.resetAccount"
               | Some _ | None -> "worker.operation"
             in
             { next = state; effects = [ Publish (Diagnostic (failure_signal code error)) ] })
        | Ok result ->
          let state, lifecycle_effects =
            match state.graph.phase, worker_effect with
            | Graph_closing, Some (Sync.Detach_graph _) ->
              apply_lifecycle state result.lifecycle
            | Graph_closing, _ -> state, []
            | _ -> apply_lifecycle state result.lifecycle
          in
          let transitioned =
            match result.event with
            | None -> no_effects state
            | Some event -> translate_sync (Sync.step state.sync_core event) state
          in
          { next = transitioned.next; effects = lifecycle_effects @ transitioned.effects })
    | Shutdown ->
      let stopped_sync = translate_sync (Sync.step state.sync_core Sync.Shutdown) state in
      let state = stopped_sync.next in
      let close_effects, state =
        match state.database with
        | None -> [], state
        | Some database ->
          let ticket, state = fresh_ticket state in
          [ Run_worker (Request (ticket, Close_database database)) ], state
      in
      { next =
          { state with
            shutdown = true
          ; database = None
          ; pending = []
          ; graph = { state.graph with phase = Graph_closed; graph_id = None }
          }
      ; effects = stopped_sync.effects @ close_effects
      })
;;

(* Drain all already-issued database operations before executing the existing close.
   Their replies still finish; Sync rejects their superseded graph events. *)
let step state event =
  let transition = step state event in
  match transition.next.deferred_detach, List.filter graph_pending transition.next.pending with
  | Some scope, [] when not transition.next.shutdown ->
    let ticket, next = fresh_ticket transition.next in
    let worker_effect = Sync.Detach_graph scope in
    { next =
        { next with
          deferred_detach = None
        ; pending = Pending_sync_worker (ticket, worker_effect) :: List.filter (fun p->not(graph_pending p)) next.pending
        }
    ; effects =
        transition.effects
        @ [ Run_worker (Request (ticket, Handle_sync_worker_effect worker_effect)) ]
    }
  | _ -> transition
;;

let complete_execute runner_effect result =
  match runner_effect with
  | Request (ticket, Execute_request _) ->
    Some (Runner_completed (Execute_request_completed (ticket, result)))
  | Request (_, Close_database _) | Request (_, Handle_sync_worker_effect _) -> None
;;

module Transfer = Logseq_sync_pure_reducer.Asset_transfer

let asset_scope state =
  if state.shutdown || state.graph.phase <> Graph_open
  then None
  else match state.active_scope with
    | Some scope when state.resident_mode -> Sync.asset_context_for_scope state.sync_core scope
    | _ -> Sync.asset_context state.sync_core
;;

let asset_online state =
  let sync=Option.value (Option.bind state.active_scope (Sync.state_for_scope state.sync_core))
    ~default:(Sync.state state.sync_core) in
  state.foreground
  && (let f=sync.snapshot.startup in
      f.authenticated && f.network_phase<>Sync.Local_only)
  &&
  match sync.snapshot.sync_phase with
  | Offline | Paused | Failed -> false
  | Connecting | Pulling | Submitting | Current -> true
;;

let asset_unlocked (context : Sync.asset_context) =
  (not context.encrypted) || Option.is_some context.key
;;

let asset_instructions (context : Sync.asset_context) instructions =
  List.map
    (function
      | Transfer.Notify { consumer; asset; descriptor; availability } ->
        Publish
          (Asset_notice
             (context.scope, Asset_availability { consumer; asset; descriptor; availability }))
      | Backpressure consumer ->
        Publish (Asset_notice (context.scope, Asset_backpressure consumer))
      | Capacity_available ->
        Publish (Asset_notice (context.scope, Asset_capacity_available))
      | instruction -> Run_asset (context, instruction))
    instructions
;;

let reconcile_assets state =
  match state.assets, asset_scope state with
  | None, _ -> state, []
  | Some (old, transfer), Some context when old.scope = context.scope ->
    let transfer, network =
      Transfer.step transfer (Network_changed (asset_online state))
    in
    let transfer, unlock =
      Transfer.step transfer (Unlock_changed (asset_unlocked context))
    in
    ( { state with assets = Some (context, transfer) }
    , asset_instructions context (network @ unlock) )
  | Some (context, transfer), _ ->
    let _, instructions = Transfer.step transfer Shutdown in
    ( { state with assets = None }
    , asset_instructions context instructions @ [ Close_asset_scope context.scope ] )
;;

let asset_ticket_current state ticket =
  match state.assets, asset_scope state with
  | Some (context, transfer), Some current when context.scope = current.scope ->
    Transfer.ticket_current transfer ticket
  | _ -> false
;;

let asset_scope_current state scope =
  match state.assets, asset_scope state with
  | Some (context, _), Some current -> context.scope = scope && current.scope = scope
  | _ -> false
;;

let apply_asset state (context : Sync.asset_context) transfer event =
  let transfer, instructions = Transfer.step transfer event in
  let accepted =
    match event with
    | Transfer.Replace { consumer; _ }
      when not
             (List.exists
                (function
                  | Transfer.Backpressure _ -> true
                  | _ -> false)
                instructions) ->
      [ Publish (Asset_notice (context.Sync.scope, Asset_demand_accepted consumer)) ]
    | _ -> []
  in
  { next = { state with assets = Some (context, transfer) }
  ; effects = asset_instructions context instructions @ accepted
  }
;;

let step state event =
  let transition = step state event in
  let state, effects = reconcile_assets transition.next in
  let asset_transition =
    match event, asset_scope state with
    | Asset_requested { graph_generation; event }, Some context
      when graph_generation = context.scope.graph_generation ->
      let transfer =
        match state.assets with
        | Some (_, transfer) -> transfer
        | None ->
          Transfer.create
            (Transfer.config ~active:3 ~foreground_reserved:1 ~pending:128 ~retries:0
             |> Result.get_ok)
            ~scope:context.scope
            ~online:(asset_online state)
            ~unlocked:(asset_unlocked context)
      in
      apply_asset state context transfer event
    | Asset_completed (scope, event), Some context when context.scope = scope ->
      (match state.assets with
       | Some (_, transfer) -> apply_asset state context transfer event
       | None -> no_effects state)
    | _ -> no_effects state
  in
  { asset_transition with
    effects = transition.effects @ effects @ asset_transition.effects
  }
;;

let upload_ticket_current state (ticket : Asset_upload.ticket) =
  match asset_scope state with
  | Some context when context.scope = ticket.scope ->
    List.exists
      (fun (_, operation, upload) ->
         operation = ticket.operation && Asset_upload.ticket_current upload ticket)
      state.uploads
  | _ -> false
;;

let upload_presentation upload =
  Option.bind (Asset_upload.checkpoint upload) (fun intent ->
    Option.map
      (fun status ->
         ( intent.Logseq_db_types.Asset_upload_intent.operation_id
         , intent.asset
         , intent.target
         , intent.title
         , status ))
      (Asset_upload.status upload))
;;

let upload_notices (context : Sync.asset_context) before after =
  let previous = upload_presentation before
  and next = upload_presentation after in
  match next with
  | Some (operation, asset, target, title, status) when previous <> next ->
    [ Publish
        (Asset_notice
           (context.scope, Upload_status { operation; asset; target; title; status }))
    ]
  | _ -> []
;;

let step state event =
  let transition = step state event in
  let current = asset_scope transition.next in
  let retained, retired =
    List.partition
      (fun ((context : Sync.asset_context), _, _) ->
         match current with
         | Some active -> context.Sync.scope = active.scope
         | None -> false)
      transition.next.uploads
  in
  let cancellations =
    List.concat_map
      (fun ((context : Sync.asset_context), _, upload) ->
         let _, instructions = Asset_upload.step upload Shutdown in
         List.map (fun instruction -> Run_upload (context, instruction)) instructions)
      retired
  in
  let cache_closes =
    retired
    |> List.map (fun ((context : Sync.asset_context), _, _) -> context.Sync.scope)
    |> List.sort_uniq compare
    |> List.map (fun scope -> Close_asset_scope scope)
  in
  let retained, availability_effects =
    match current with
    | None -> retained, []
    | Some context ->
      let available = asset_online transition.next && asset_unlocked context in
      let uploads, instructions =
        List.fold_left
          (fun (uploads, effects) (_, operation, upload) ->
             let previous = upload in
             let upload, instructions =
               Asset_upload.step upload (Availability_changed available)
             in
             ( (context, operation, upload) :: uploads
             , effects
               @ upload_notices context previous upload
               @ List.map
                   (fun instruction -> Run_upload (context, instruction))
                   instructions ))
          ([], [])
          retained
      in
      List.rev uploads, instructions
  in
  let state = { transition.next with uploads = retained } in
  let apply (context : Sync.asset_context) operation upload upload_event =
    let previous = upload in
    let upload, instructions = Asset_upload.step upload upload_event in
    let remaining = List.filter (fun (_, id, _) -> id <> operation) state.uploads in
    let terminal =
      match Asset_upload.checkpoint upload with
      | Some { phase = Complete | Cancelled; _ } -> true
      | _ -> false
    in
    let uploads =
      if terminal then remaining else (context, operation, upload) :: remaining
    in
    { next = { state with uploads }
    ; effects =
        upload_notices context previous upload
        @ List.map (fun instruction -> Run_upload (context, instruction)) instructions
    }
  in
  let changed =
    match event, current with
    | Upload_requested { graph_generation; operation; event }, Some context
      when graph_generation = context.scope.graph_generation ->
      (match List.find_opt (fun (_, id, _) -> id = operation) state.uploads with
       | Some (_, _, upload) -> apply context operation upload event
       | None ->
         (match event with
          | (Asset_upload.Start intent | Restore intent)
            when intent.operation_id = operation
                 && intent.graph = context.scope.graph_id
                 && intent.account = context.scope.account.user_id
                 && intent.origin
                    = Uri.to_string context.scope.account.managed_sync_origin ->
            if
              (List.length state.uploads
               +
               match state.recovery_pending with
               | Some ticket -> ticket.limit
               | None -> 0)
              >= 32
            then
              { next = state
              ; effects = [ Publish (Diagnostic "Upload queue capacity reached") ]
              }
            else
              apply
                context
                operation
                (Asset_upload.create
                   ~scope:context.scope
                   ~available:(asset_online state && asset_unlocked context))
                event
          | _ -> no_effects state))
    | Upload_completed (ticket, completion), Some context
      when context.scope = ticket.scope ->
      (match List.find_opt (fun (_, id, _) -> id = ticket.operation) state.uploads with
       | Some (_, _, upload) ->
         apply
           context
           ticket.operation
           upload
           (Asset_upload.Completed (ticket, completion))
       | None -> no_effects state)
    | _ -> no_effects state
  in
  { changed with
    effects =
      transition.effects
      @ cancellations
      @ cache_closes
      @ availability_effects
      @ changed.effects
  }
;;

let upload_recovery_current state ticket =
  state.recovery_pending = Some ticket
  &&
  match asset_scope state with
  | Some context -> context.scope = ticket.scope
  | None -> false
;;

let step state event =
  let transition = step state event in
  let state = transition.next in
  let state =
    match asset_scope state, state.recovery with
    | None, _ -> { state with recovery = None; recovery_pending = None }
    | Some context, Some (scope, _, _) when scope = context.scope -> state
    | Some context, _ ->
      { state with recovery = Some (context.scope, None, false); recovery_pending = None }
  in
  let state, recovered =
    match event with
    | Uploads_loaded (ticket, result) when upload_recovery_current state ticket ->
      let state = { state with recovery_pending = None } in
      let valid intents =
        let rec ordered previous = function
          | [] -> true
          | (i : Logseq_db_types.Asset_upload_intent.t) :: rest ->
            i.origin = Uri.to_string ticket.scope.account.managed_sync_origin
            && i.account = ticket.scope.account.user_id
            && i.graph = ticket.scope.graph_id
            && (match previous with
                | None -> true
                | Some previous ->
                  String.compare
                    (Logseq_db_types.Graph_types.Uuid.to_string previous)
                    (Logseq_db_types.Graph_types.Uuid.to_string i.operation_id)
                  < 0)
            && ordered (Some i.operation_id) rest
        in
        List.length intents <= ticket.limit && ordered ticket.after intents
      in
      (match result with
       | Ok intents when valid intents ->
         let after =
           List.fold_left
             (fun _ i -> Some i.Logseq_db_types.Asset_upload_intent.operation_id)
             ticket.after
             intents
         in
         let state =
           { state with
             recovery = Some (ticket.scope, after, List.length intents < ticket.limit)
           }
         in
         List.fold_left
           (fun (state, effects) i ->
              let restored =
                step
                  state
                  (Upload_requested
                     { graph_generation = ticket.scope.graph_generation
                     ; operation = i.Logseq_db_types.Asset_upload_intent.operation_id
                     ; event = Asset_upload.Restore i
                     })
              in
              restored.next, effects @ restored.effects)
           (state, [])
           intents
       | (Ok _ | Error _) as failure ->
         let module D=Logseq_db_types.Failure_diagnostic in
         let diagnostic=match failure with
           | Ok _ -> D.create ~operation:"restoreUploads" ~reason:"invalidContent" ()
           | Error source -> D.of_source ~operation:"restoreUploads" ~reason:"persistenceFailed" source in
         ( { state with recovery = Some (ticket.scope, ticket.after, true) }
         , [ Publish (Diagnostic (D.signal_prefix ^ D.encode diagnostic)) ] ))
    | Sync_event (Sync.Online_recovery_requested _) ->
      (match asset_scope state with
       | None -> state, []
       | Some context ->
         let state =
           if state.recovery_pending = None
           then { state with recovery = Some (context.scope, None, false) }
           else state
         in
         List.fold_left
           (fun (state, effects) (_, operation, _) ->
              let retried =
                step
                  state
                  (Upload_requested
                     { graph_generation = context.scope.graph_generation
                     ; operation
                     ; event = Asset_upload.Retry
                     })
              in
              retried.next, effects @ retried.effects)
           (state, [])
           state.uploads)
    | _ -> state, []
  in
  let state, reads =
    match state.recovery, state.recovery_pending with
    | Some (scope, after, false), None when List.length state.uploads < 32 ->
      let ticket =
        { scope
        ; after
        ; limit = min 16 (32 - List.length state.uploads)
        ; serial = state.recovery_serial + 1
        }
      in
      ( { state with recovery_pending = Some ticket; recovery_serial = ticket.serial }
      , [ Read_uploads ticket ] )
    | _ -> state, []
  in
  { next = state; effects = transition.effects @ recovered @ reads }
;;

let import_context state ~graph_generation =
  let reserved =
    match state.recovery_pending with
    | Some ticket -> ticket.limit
    | None -> 0
  in
  match asset_scope state with
  | Some context
    when context.scope.graph_generation = graph_generation
         && List.length state.uploads + reserved < 32 -> Some context
  | _ -> None
;;


let step_session = step
let graph_scopes state =
  List.filter_map (fun id -> Sync.scope_for_graph state.sync_core ~graph_id:id)
    (Sync.resident_graphs state.sync_core)
let graph_state_for_scope state (scope:Sync.graph_scope) =
  if Sync.scope_for_graph state.sync_core ~graph_id:scope.graph_id <> Some scope then None
  else Some (load_graph state scope).graph
type coordination_state =
  { sync : Sync.coordination_state
  ; residents : (Sync.graph_scope * graph_state) list
  }
let coordination_state state =
  let sync=Sync.coordination_state state.sync_core in
  {sync;residents=List.map (fun (scope,_) -> scope,(load_graph state scope).graph) sync.residents}
let session_for_ticket state ticket =
  List.find_opt (fun s -> has_pending ticket.id s.saved_pending) (remember_graph state).graph_sessions
let scope_of_event state = function
  | Graph_request_for_scope {scope;_} | Projection_push_for_scope (scope,_)
  | Asset_requested_for_scope (scope,_) | Upload_requested_for_scope (scope,_,_)
  | Asset_completed (scope,_) -> Some scope
  | Upload_completed (ticket,_) -> Some ticket.Asset_upload.scope
  | Uploads_loaded (ticket,_) -> Some ticket.scope
  | Sync_event event -> Sync.event_graph_scope state.sync_core event
  | Runner_completed (Execute_request_completed (ticket,_) | Close_database_completed (ticket,_)
      | Sync_worker_effect_completed (ticket,_)) ->
    Option.map (fun s->s.owner) (session_for_ticket state ticket)
  | _ -> None
let step state event =
  let state=match event with Sync_event (Sync.Resident_graphs_changed _) -> {state with resident_mode=true} | _->state in
  let known=state.resident_mode in
  let admitted (scope:Sync.graph_scope)=Sync.scope_for_graph state.sync_core ~graph_id:scope.Sync.graph_id=Some scope in
  let owner=match event with
    | Graph_request_for_scope {scope;_} | Projection_push_for_scope (scope,_)
    | Asset_requested_for_scope (scope,_) | Upload_requested_for_scope (scope,_,_)
        when not(admitted scope) -> None
    | _ -> scope_of_event state event in
  let owner=Option.bind owner (fun scope->if admitted scope || state.active_scope=Some scope
    || List.exists(fun session->session.owner=scope) state.graph_sessions then Some scope else None) in
  let state=match owner with Some scope when known->load_graph state scope | _->state in
  let event=match event with
    | Graph_request_for_scope {scope;id;read} ->
      if Sync.scope_for_graph state.sync_core ~graph_id:scope.graph_id = Some scope
      then Graph_request {id;read}
      else Graph_request_for_scope {scope;id;read}
    | Asset_requested_for_scope (scope,event) when admitted scope -> Asset_requested {graph_generation=scope.graph_generation;event}
    | Upload_requested_for_scope (scope,operation,event) when admitted scope -> Upload_requested {graph_generation=scope.graph_generation;operation;event}
    | Projection_push_for_scope (scope,push) when Sync.scope_for_graph state.sync_core ~graph_id:scope.graph_id=Some scope -> Projection_push push
    | event -> event in
  let transition=match event with
    | Graph_request_for_scope {id;read;_} ->
      {next=state;effects=[Publish (Reply (id,unavailable_response read "The graph scope is no longer open."))]}
    | _ -> step_session state event in
  let transition=match event with
    | Set_foreground _ | Shutdown when known ->
      let sessions=(remember_graph state).graph_sessions in
      List.fold_left (fun result session ->
        if state.active_scope=Some session.owner then result else
        let loaded=load_graph result.next session.owner in
        let loaded=if event=Shutdown then {loaded with shutdown=false} else loaded in
        let part=step_session loaded (if event=Shutdown then Shutdown else Start) in
        {next=remember_graph part.next;effects=result.effects @ part.effects}) transition sessions
    | _->transition in
  let next=remember_graph transition.next in
  let next,drains=List.fold_left (fun (next,effects) session ->
    if session.saved_deferred_detach<>None && session.saved_pending=[] then
      let drained=step_session (load_graph next session.owner) Start in
      remember_graph drained.next,effects @ drained.effects
    else next,effects) (next,[]) next.graph_sessions in
  let next,account_effects=match next.account_reset with
    | Some account when List.for_all (fun session->session.saved_database=None
        && session.saved_deferred_detach=None && session.saved_pending=[]) next.graph_sessions ->
      let ticket,next=fresh_ticket next in
      let request=Sync.Reset_managed_account account in
      {next with account_reset=None;pending=Pending_sync_worker(ticket,request)::next.pending},
        [Run_worker(Request(ticket,Handle_sync_worker_effect request))]
    | _->next,[] in
  let effects=List.map (function
    | Publish (Graph_push push) ->
      (match owner with Some scope->Publish (Scoped_graph_push (scope,push)) | None->Publish (Graph_push push))
    | instruction -> instruction) (transition.effects @ drains @ account_effects) in
  let next={next with graph_sessions=List.filter (fun session ->
    session.saved_database<>None || session.saved_graph.phase<>Graph_closed
    || session.saved_pending<>[] || session.saved_deferred_detach<>None) next.graph_sessions} in
  let next=if next.graph.phase=Graph_closed && next.database=None && List.filter graph_pending next.pending=[]
    then {next with active_scope=None} else next in
  {next=(if known || (Sync.state next.sync_core).snapshot.resident_graphs<>[] then restore_visible_graph next else next);effects}
let step_without_asset_barrier=step
let step state event=match event with
  | Sync_event(Sync.IO_fence_completed(id,scope,result))->{next=state;effects=[Sync_io_fence_reached(id,scope,result)]}
  | Sync_event(Sync.IO_fence_requested _ as event)->translate_sync(Sync.step state.sync_core event)state
  | Asset_cleanup_barrier token->{next=state;effects=[Asset_cleanup_barrier_reached token]}
  | _->step_without_asset_barrier state event

let asset_ticket_current_single = asset_ticket_current
let asset_ticket_current state ticket =
  let scope=match ticket with Transfer.Lookup t->t.scope | Download t->t.scope in
  asset_ticket_current_single (load_graph state scope) ticket
let asset_scope_current_single = asset_scope_current
let asset_scope_current state scope = asset_scope_current_single (load_graph state scope) scope
let upload_ticket_current_single = upload_ticket_current
let upload_ticket_current state (ticket:Asset_upload.ticket) = upload_ticket_current_single (load_graph state ticket.scope) ticket
let upload_recovery_current_single = upload_recovery_current
let upload_recovery_current state ticket = upload_recovery_current_single (load_graph state ticket.scope) ticket
let import_context_single = import_context
let import_context state ~graph_generation =
  match List.find_opt (fun (scope:Sync.graph_scope)->scope.graph_generation=graph_generation) (graph_scopes state) with
  | Some scope -> import_context_single (load_graph state scope) ~graph_generation
  | None -> import_context_single state ~graph_generation
let import_context_for_scope state (scope:Sync.graph_scope) =
  if Sync.scope_for_graph state.sync_core ~graph_id:scope.graph_id<>Some scope then None
  else import_context_single (load_graph state scope) ~graph_generation:scope.graph_generation
;;

module Observation_registry = struct
  module G = Logseq_db_types.Graph_types
  module S = Logseq_sync_pure_reducer.Core

  module Entries = Map.Make (struct
      type t = int64 * G.Uuid.t

      let compare (registration, id) (other_registration, other_id) =
        let order = Int64.compare registration other_registration in
        if order = 0 then G.Uuid.compare id other_id else order
      ;;
    end)

  type live =
    { scope : S.graph_scope
    ; read : Worker_pure_read.packed_query
    ; epoch : int64
    }

  type entry =
    | Live of live
    | Closing of S.graph_scope
    | Gone of S.graph_scope
    | Gone_unallocated of S.timeline_scope

  type t =
    { entries : entry Entries.t
    ; finished : unit Entries.t
    ; closed : int64
    ; active : int
    ; retained : int
    }

  type decision =
    | Start
    | Existing
    | Retired
    | Full
    | Mismatch
    | Invalid

  type release =
    | Release
    | Already_released
    | Unknown
    | Release_full
    | Wrong_owner

  let empty = { entries = Entries.empty; finished=Entries.empty; closed=0L; active = 0; retained = 0 }

  let same_scope (a : S.graph_scope) (b : S.graph_scope) =
    G.Uuid.equal a.graph_id b.graph_id
    && a.graph_generation = b.graph_generation
    && a.account.user_id = b.account.user_id
    && Uri.equal a.account.managed_sync_origin b.account.managed_sync_origin
    && a.account.account_generation = b.account.account_generation
    && a.account.lifecycle_generation = b.account.lifecycle_generation
  ;;

  let same_owner (scope : S.graph_scope) (owner : S.timeline_scope) =
    G.Uuid.equal scope.graph_id owner.graph_id
    && scope.graph_generation = owner.graph_generation
    && scope.account.account_generation = owner.startup.account_generation
  ;;

  let equal_owner (a : S.timeline_scope) (b : S.timeline_scope) =
    G.Uuid.equal a.graph_id b.graph_id
    && a.graph_generation = b.graph_generation
    && a.startup.account_generation = b.startup.account_generation
  ;;

  let reserve state ~registration ~id ~scope ~read =
    let Worker_pure_read.Read_query(budget,query)=read in
    let owner=Worker_pure_read.For_worker.read_budget_owner budget in
    let maximum_bytes=Worker_pure_read.For_worker.read_budget_maximum_bytes budget in
    let key = registration, id in
    if
      registration <= 0L
      || maximum_bytes <= 0
      || maximum_bytes > Worker_pure_data.maximum_response_bytes
      || not (Worker_pure_read.observable query)
      || not (Worker_pure_read.matches_asset_scope owner scope)
      || Worker_pure_read.For_worker.binding_serial(Worker_pure_read.For_worker.session_binding owner)<>registration
      || Result.is_error(Worker_pure_read.validate_query owner budget query)
    then state, Invalid
    else if registration<=state.closed then state,Retired else (
      match Entries.find_opt key state.entries with
      | Some (Gone old | Closing old) ->
        state, if same_scope scope old then Retired else Mismatch
      | Some (Gone_unallocated old) ->
        state, if same_owner scope old then Retired else Mismatch
      | Some (Live old) ->
        ( state
        , if
            same_scope scope old.scope
            && Worker_pure_read.equal_packed_query old.read read
          then Existing
          else Mismatch )
      | None when Entries.mem key state.finished -> state,Retired
      | None when state.active >= 256 || state.retained >= 8192 -> state, Full
      | None ->
        ( { state with entries =
              Entries.add
                key
                (Live { scope; read; epoch = 0L })
                state.entries
          ; active = state.active + 1
          ; retained = state.retained + 1
          }
        , Start ))
  ;;

  let release state ~registration ~id ~scope =
    let key = registration, id in
    match Entries.find_opt key state.entries with
    | Some (Live old) when same_scope scope old.scope ->
      { state with entries = Entries.add key (Closing old.scope) state.entries }, Release
    | Some (Closing old) when same_scope scope old -> state, Release
    | Some (Gone old) when same_scope scope old -> state, Already_released
    | Some (Gone_unallocated old) when same_owner scope old -> state, Already_released
    | Some _ -> state, Wrong_owner
    | None when registration>0L && registration<=state.closed -> state,Unknown
    | None when registration <= 0L || state.retained >= 8192 -> state, Release_full
    | None ->
      ( { state with
          entries = Entries.add key (Gone scope) state.entries
        ; retained = state.retained + (if Entries.mem key state.finished then 0 else 1)
        }
      , Unknown )
  ;;

  let release_unallocated state ~registration ~id ~(owner : S.timeline_scope) =
    let key = registration, id in
    match Entries.find_opt key state.entries with
    | Some (Gone_unallocated old) when equal_owner owner old -> state, Already_released
    | Some _ -> state, Wrong_owner
    | None when registration>0L && registration<=state.closed -> state,Unknown
    | None
      when registration <= 0L
           || owner.startup.account_generation < 0
           || owner.graph_generation < 0
           || state.retained >= 8192 -> state, Release_full
    | None ->
      ( { state with
          entries = Entries.add key (Gone_unallocated owner) state.entries
        ; retained = state.retained + (if Entries.mem key state.finished then 0 else 1)
        }
      , Unknown )
  ;;

  let released state ~registration ~id ~scope =
    let key = registration, id in
    match Entries.find_opt key state.entries with
    | Some (Closing old) when same_scope old scope ->
      { state with
        entries = Entries.add key (Gone old) state.entries
      ; active = state.active - 1
      }
    | _ -> state
  ;;

  let advance state ~registration ~id =
    let key = registration, id in
    match Entries.find_opt key state.entries with
    | Some (Live old) when old.epoch < Int64.max_int ->
      let epoch = Int64.succ old.epoch in
      ( { state with entries = Entries.add key (Live { old with epoch }) state.entries }
      , Some epoch )
    | _ -> state, None
  ;;

  let current state ~registration ~id ~epoch =
    match Entries.find_opt (registration, id) state.entries with
    | Some (Live value) -> value.epoch = epoch
    | _ -> false
  ;;

  let scope state ~registration ~id =
    match Entries.find_opt (registration, id) state.entries with
    | Some (Live value) -> Some value.scope
    | Some (Gone scope | Closing scope) -> Some scope
    | Some (Gone_unallocated _) | None -> None
  ;;

  let epoch state ~registration ~id =
    match Entries.find_opt (registration, id) state.entries with
    | Some (Live value) -> Some value.epoch
    | _ -> None
  ;;

  let creator_finished state ~registration ~id =
    let key=registration,id in
    if registration<=0L || (registration<=state.closed && not(Entries.mem key state.entries))
    then state else
    let known=Entries.mem key state.entries || Entries.mem key state.finished in
    {state with finished=Entries.add key () state.finished;
      retained=state.retained+(if known then 0 else 1)}
  ;;

  let finalize state ~registration ~id ~owner =
    let key=registration,id in
    let remove ()=
      let known=Entries.mem key state.entries || Entries.mem key state.finished in
      {state with entries=Entries.remove key state.entries;finished=Entries.remove key state.finished;
        retained=state.retained-(if known then 1 else 0)},Ok() in
    match Entries.find_opt key state.entries with
    |None->remove()
    |Some(Gone scope) when same_owner scope owner && Entries.mem key state.finished->remove()
    |Some(Gone_unallocated actual) when equal_owner actual owner && Entries.mem key state.finished->remove()
    |Some _->state,Error "Observation owner, creator or physical cleanup is not settled"
  ;;

  let active state = state.active
  let retained state = state.retained

  let retire_registration state ~registration =
    let entries =
      Entries.filter (fun (binding, _) _ -> binding <> registration) state.entries
    in
    let active, retained =
      Entries.fold
        (fun _ entry (active, retained) ->
           ( (active
              +
              match entry with
              | Live _ | Closing _ -> 1
              | Gone _ | Gone_unallocated _ -> 0)
           , retained + 1 ))
        entries
        (0, 0)
    in
    let finished=Entries.filter(fun(binding,_) _->binding<>registration)state.finished in
    let retained=Entries.fold(fun key () count->count+(if Entries.mem key entries then 0 else 1))finished retained in
    { entries;finished;closed=max state.closed registration;active;retained }
  ;;
end

module Changefeed_owner = struct
  type ownership = Unclaimed | Registered of int64 | Retired of int64
  type retained = { read : Read.packed_query; batch : Read.change_batch }
  type t = {owner:ownership;pending:retained option;acknowledged:(string*string)option;
    resync:bool;windows:int;bytes:int}
  type pull = Read | Cached of Read.change_batch | Refused
  let empty={owner=Unclaimed;pending=None;acknowledged=None;resync=false;windows=0;bytes=0}
  let unclaimed state=state.owner=Unclaimed
  let needs_resync state=state.resync
  let owns state registration=state.owner=Registered registration
  let claim state ~registration =
    if registration<=0L then state,false else match state.owner with
    |Unclaimed->{state with owner=Registered registration},true
    |Registered actual->state,actual=registration
    |Retired previous when registration>previous->
      {state with owner=Registered registration;pending=None;acknowledged=None;resync=false},true
    |Retired _->state,false
  let pull state ~registration ~read =
    if not(owns state registration) then Refused else
    let Read.Read_query(budget,query)=read in
    match query with
    |Read.Changes _->(match Read.validate_query (Read.For_worker.read_budget_owner budget) budget query,state.pending with
      |Ok(),None->Read
      |Ok(),Some retained when Read.equal_packed_query read retained.read->Cached retained.batch
      |_->Refused)
    |_->Refused
  let remember state ~registration ~read (batch:Read.change_batch) =
    let Read.Read_query(budget,query)=read in
    match pull state ~registration ~read,query with
    |Read,Read.Changes _->
      (match Read.validate_value (Read.For_worker.read_budget_owner budget) budget query batch with
       |Ok()->Ok{state with pending=Some{read;batch};resync=false}
       |Error _->Error "Changefeed response does not match its retained pull")
    |_->Error "Changefeed ownership or retained response mismatch"
  let pending_matches state generation through=match state.pending with
    |Some{batch;_}->batch.generation=generation && batch.through=through
    |None->false
  let may_ack state ~registration ~generation ~through=owns state registration &&
    (pending_matches state generation through || state.acknowledged=Some(generation,through))
  let acknowledged state ~registration ~generation ~through =
    if not(may_ack state ~registration ~generation ~through) then state else
    {state with acknowledged=Some(generation,through);
      pending=(if pending_matches state generation through then None else state.pending)}
  let invalidate state =
    { state with
      pending = None
    ; acknowledged = None
    ; resync = true
    ; windows = 0
    ; bytes = 0
    }
  ;;

  let retain_window state ~encoded_bytes =
    if
      encoded_bytes <= 0
      || state.windows >= 256
      || encoded_bytes > Worker_pure_data.maximum_response_bytes - state.bytes
    then invalidate state, false
    else
      ( { state with windows = state.windows + 1; bytes = state.bytes + encoded_bytes }
      , true )
  ;;

  let release_windows state ~count ~encoded_bytes =
    if
      count < 0
      || count > state.windows
      || encoded_bytes < 0
      || encoded_bytes > state.bytes
    then invalid_arg "Changefeed retention accounting mismatch"
    else
      { state with windows = state.windows - count; bytes = state.bytes - encoded_bytes }
  ;;

  let retire state ~registration =
    if owns state registration
    then
      { state with
        owner = Retired registration
      ; pending = None
      ; acknowledged = None
      ; resync = false
      }
    else state
  ;;
end


module Orphan_cleanup = struct
  type resource = { scope : Logseq_sync_pure_reducer.Core.graph_scope; handle : string }
  module Resources=Map.Make(struct type t=resource let compare=Stdlib.compare end)
  module Queue=Map.Make(Int64)
  type work={resource:resource;attempt:int64;failures:int}
  type entry={attempt:int64 option;failures:int}
  type t={resources:entry Resources.t;ready:resource Queue.t;serial:int64}
  let empty={resources=Resources.empty;ready=Queue.empty;serial=0L}
  let count t=Resources.cardinal t.resources
  let acquisition_open t=Resources.is_empty t.resources
  let resource work=work.resource
  let first_attempt (work:work)=work.failures=0
  let retry_delay (work:work)=if work.failures=0 then 0. else min 1. (0.05 *. (2. ** float_of_int(work.failures-1)))
  let track t resource=
    if Resources.mem resource t.resources then t else
    {resources=Resources.add resource {attempt=None;failures=0} t.resources;
      ready=Queue.add t.serial resource t.ready;serial=Int64.succ t.serial}
  let next t=match Queue.min_binding_opt t.ready with
    | None->t,None
    | Some(attempt,resource)->
      let entry=Resources.find resource t.resources in
      {t with ready=Queue.remove attempt t.ready;
        resources=Resources.add resource {entry with attempt=Some attempt}t.resources},Some{resource;attempt;failures=entry.failures}
  let completed t work result=match Resources.find_opt work.resource t.resources with
    | Some entry when entry.attempt=Some work.attempt->
      (match result with
       | Ok()->{t with resources=Resources.remove work.resource t.resources}
       | Error _->{resources=Resources.add work.resource {attempt=None;failures=min 6(entry.failures+1)}t.resources;
           ready=Queue.add t.serial work.resource t.ready;serial=Int64.succ t.serial})
    | _->t
end

module Demand_registry = struct
  type owner={registration:int64;scope:Logseq_sync_pure_reducer.Core.graph_scope;consumer:string}
  module Keys=Map.Make(struct type t=int64*string let compare=Stdlib.compare end)
  type payload=Logseq_sync_pure_reducer.Asset_transfer.priority * Logseq_db_types.Asset_descriptor.t list
  type entry={owner:owner;payload:payload option;retired:bool;settled:bool}
  type t={entries:entry Keys.t;finished:unit Keys.t;closed:int64}
  type reservation=Start|Existing|Retired|Mismatch|Full|Invalid
  type release=Release|Already_settled|Unknown|Mismatch|Full
  let empty={entries=Keys.empty;finished=Keys.empty;closed=0L}
  let key owner=owner.registration,owner.consumer
  let same_scope (a:Logseq_sync_pure_reducer.Core.graph_scope) (b:Logseq_sync_pure_reducer.Core.graph_scope)=
    a.graph_id=b.graph_id && a.graph_generation=b.graph_generation
    && a.account.user_id=b.account.user_id && Uri.equal a.account.managed_sync_origin b.account.managed_sync_origin
    && a.account.account_generation=b.account.account_generation
    && a.account.lifecycle_generation=b.account.lifecycle_generation
  let admitted t owner=owner.registration>t.closed && match Keys.find_opt(key owner)t.entries with
    | Some entry->not entry.retired && same_scope entry.owner.scope owner.scope
    | None->false
  let reserve t owner ~priority ~assets : t * reservation =
    if owner.registration<=t.closed then t,Retired
    else if owner.registration<=0L || owner.consumer="" || String.length owner.consumer>512
         || List.length assets>Worker_pure_data.maximum_page_size then t,Invalid else
    let bytes=List.fold_left(fun bytes asset->if bytes>Worker_pure_data.maximum_response_bytes then bytes else
      bytes+1+String.length(Yojson.Safe.to_string(Logseq_db_types.Asset_descriptor.to_yojson asset)))2 assets in
    if bytes>Worker_pure_data.maximum_response_bytes then t,Invalid else
    match Keys.find_opt(key owner)t.entries with
    | Some entry when not(same_scope entry.owner.scope owner.scope)->t,Mismatch
    | Some{retired=true;_}->t,Retired
    | Some entry when entry.payload=Some(priority,assets)->t,Existing
    | Some _->t,Mismatch
    | None when Keys.mem(key owner)t.finished->t,Retired
    | None->
      let pending=Keys.fold(fun _ entry count->count+(if entry.settled then 0 else 1))t.entries 0 in
      if pending>=128 || Keys.cardinal t.entries>=8192 then t,Full else
      {t with entries=Keys.add(key owner){owner;payload=Some(priority,assets);retired=false;settled=false}t.entries},Start
  let retire t owner : t * release =
    if owner.registration<=0L || owner.consumer="" || String.length owner.consumer>512 then t,Mismatch else
    match Keys.find_opt(key owner)t.entries with
    | Some entry when not(same_scope entry.owner.scope owner.scope)->t,Mismatch
    | Some{settled=true;_}->t,Already_settled
    | Some entry->{t with entries=Keys.add(key owner){entry with retired=true}t.entries},Release
    | None when owner.registration<=t.closed->t,Unknown
    | None when Keys.cardinal t.entries>=8192->t,Full
    | None->{t with entries=Keys.add(key owner){owner;payload=None;retired=true;settled=true}t.entries},Unknown
  let settled t owner=match Keys.find_opt(key owner)t.entries with
    | Some entry when entry.retired && same_scope entry.owner.scope owner.scope->
      {t with entries=Keys.add(key owner){entry with settled=true;payload=None}t.entries}
    | _->t
  let pending t ~registration=Keys.fold(fun _ entry values->
    if entry.owner.registration=registration && not entry.settled then Rrbvec.push_back values entry.owner else values)
    t.entries Rrbvec.empty
  let creator_finished t ~registration ~consumer =
    let key=registration,consumer in
    if registration<=0L || (registration<=t.closed && not(Keys.mem key t.entries)) then t
    else {t with finished=Keys.add key () t.finished}
  let finalize t owner =
    let remove ()={t with entries=Keys.remove(key owner)t.entries;finished=Keys.remove(key owner)t.finished},Ok() in
    match Keys.find_opt(key owner)t.entries with
    |None->remove()
    |Some entry when same_scope entry.owner.scope owner.scope && entry.retired && entry.settled
        && Keys.mem(key owner)t.finished->remove()
    |Some _->t,Error "Demand owner, creator or physical cleanup is not settled"
  let forget_settled t ~registration=
    let entries=Keys.filter(fun _ entry->entry.owner.registration>registration || not entry.settled)t.entries in
    let finished=Keys.filter(fun((binding,_)as key) _->binding>registration || Keys.mem key entries)t.finished in
    {closed=max t.closed registration;entries;finished}
end

module Writer_fence = struct
  module Scope = struct
    type t=Logseq_sync_pure_reducer.Core.graph_scope
    let key (scope:t)=
      (Uri.to_string scope.account.managed_sync_origin,scope.account.user_id,
       scope.account.account_generation,scope.graph_id,scope.graph_generation)
    let compare a b=Stdlib.compare(key a)(key b)
  end
  module Scopes=Map.Make(Scope)
  module Operations=Map.Make(Int64)
  type operation={serial:int64;scope:Scope.t}
  type fence={scope:Scope.t;serial:int64}
  type error=Fenced|Full
  type t={next:int64;operations:operation Operations.t;fences:fence Scopes.t}
  let empty={next=0L;operations=Operations.empty;fences=Scopes.empty}
  let same_incarnation a b=Scope.compare a b=0
  let operation_id (operation:operation)=operation.serial
  let pending state scope=Operations.fold(fun _ (op:operation) count->
    count+(if same_incarnation op.scope scope then 1 else 0))state.operations 0
  let fenced state scope=Scopes.mem scope state.fences
  let admit state scope=
    if fenced state scope then state,Error Fenced
    else if Operations.cardinal state.operations>=256 || state.next=Int64.max_int then state,Error Full
    else let serial=Int64.succ state.next in
      let operation:operation={serial;scope} in
      {state with next=serial;operations=Operations.add serial operation state.operations},Ok operation
  let admit_cleanup state scope=
    if Operations.cardinal state.operations>=512 || state.next=Int64.max_int then state,Error Full
    else let serial=Int64.succ state.next in
      let operation:operation={serial;scope} in
      {state with next=serial;operations=Operations.add serial operation state.operations},Ok operation
  let finish state (operation:operation)=
    match Operations.find_opt operation.serial state.operations with
    |Some actual when actual=operation->{state with operations=Operations.remove operation.serial state.operations}
    |_->state
  let freeze state scope=
    match Scopes.find_opt scope state.fences with
    |Some fence->state,Ok fence
    |None when Scopes.cardinal state.fences>=8192 || state.next=Int64.max_int->state,Error Full
    |None->let serial=Int64.succ state.next in
      let fence:fence={scope;serial} in
      {state with next=serial;fences=Scopes.add scope fence state.fences},Ok fence
  let drained state (fence:fence)=
    Option.exists(fun (actual:fence)->actual.serial=fence.serial && actual.scope=fence.scope)
      (Scopes.find_opt fence.scope state.fences) && pending state fence.scope=0
end

module Registration_retirement = struct
  module Registrations=Map.Make(Int64)
  module Scopes=Set.Make(Writer_fence.Scope)
  type entry={owner:Sync.account_scope option;retiring:bool}
  type t={closed:int64;entries:entry Registrations.t}
  type plan={owner:Sync.account_scope option;scopes:Sync.graph_scope Rrbvec.t;join_account:bool;blocked:bool}
  let empty={closed=0L;entries=Registrations.empty}
  let bind state ~registration ~account =
    if registration<=0L then Error "Invalid coordination registration."
    else if Registrations.mem registration state.entries then Ok state
    else if registration<=state.closed then Error "Coordination retirement registration already released."
    else if Registrations.cardinal state.entries>=8192 then Error "Coordination retirement ownership is full."
    else Ok{state with entries=Registrations.add registration{owner=account;retiring=false}state.entries}
  let observe state ~registration ~account=match registration,account with
    |Some registration,Some owner->
      (match Registrations.find_opt registration state.entries with
       |Some{owner=None;retiring=false}->{state with entries=Registrations.add registration{owner=Some owner;retiring=false}state.entries}
       |_->state)
    |_->state
  let same_account (a:Sync.account_scope) (b:Sync.account_scope)=Uri.equal a.managed_sync_origin b.managed_sync_origin
    && a.user_id=b.user_id && a.account_generation=b.account_generation
  let begin_release (state:t) ~registration ~active_account ~active_scopes ~physical_scopes =
    let entry=Registrations.find_opt registration state.entries in
    let owner=Option.bind entry(fun(entry:entry)->entry.owner) in
    let active=Rrbvec.fold_left(fun scopes scope->Scopes.add scope scopes)Scopes.empty active_scopes in
    let scopes=Rrbvec.fold_left(fun scopes (scope:Sync.graph_scope)->
      if Option.exists(fun owner->same_account owner scope.account)owner && not(Scopes.mem scope active)
      then Scopes.add scope scopes else scopes)Scopes.empty physical_scopes |> Scopes.to_seq |> Rrbvec.of_seq in
    let join_account=Option.exists(fun owner->not(Option.exists(fun actual->same_account owner actual
      && owner.Sync.lifecycle_generation=actual.Sync.lifecycle_generation)active_account))owner in
    let blocked=Option.exists(fun owner->Option.exists(fun actual->
      Uri.equal owner.Sync.managed_sync_origin actual.Sync.managed_sync_origin && owner.user_id=actual.user_id
      && (owner.account_generation<>actual.account_generation || owner.lifecycle_generation<>actual.lifecycle_generation))active_account)owner in
    let state=match entry with None->state|Some entry->{state with entries=Registrations.add registration{entry with retiring=true}state.entries} in
    state,{owner;scopes=(if blocked then Rrbvec.empty else scopes);join_account;blocked}
  let released state ~registration={closed=max state.closed registration;entries=Registrations.remove registration state.entries}
end

module Host_handoff = struct
  module S=Logseq_sync_pure_reducer.Core
  module G=Logseq_db_types.Graph_types
  module Ids=Set.Make(G.Uuid)
  module Receipts=Map.Make(G.Uuid)
  module Scopes=Set.Make(Writer_fence.Scope)
  type mode=Normal|Force
  type change=Close_graph of G.Uuid.t|Remove_graph of G.Uuid.t * mode|Replace_account|Stop_connection
  type facts={authenticated:bool;version:int64;registration:int64 option;account:S.account_scope option;scopes:S.graph_scope Rrbvec.t;catalog:G.Uuid.t Rrbvec.t}
  type request={version:int64;id:G.Uuid.t;registration:int64;owner:S.account_scope;change:change;
    expected:S.graph_scope Rrbvec.t;captured:S.graph_scope Rrbvec.t}
  type attempt={lifetime:G.Uuid.t;serial:int64;id:G.Uuid.t}
  type receipt={attempt:attempt;request:request;copy_generation:Logseq_overlay_db.Types.mirror_generation option}
  type error=Busy|Retired|Mismatch|Owner_changed|Scopes_changed|Baseline_changed|Full|Missing_copy_witness|Not_settled
  type phase=Preparing|Safe of receipt|Consumed of receipt|Failed of error
  type entry={attempt:attempt;request:request;keys:Scopes.t;phase:phase;settlement_pending:bool}
  type t={lifetime:G.Uuid.t;next:int64;active:entry option;retired:Ids.t;consumed_receipts:receipt Receipts.t;retained_cost:int}
  type admission=Start of attempt|Existing of phase|Refused of error
  let empty ~lifetime={lifetime;next=0L;active=None;retired=Ids.empty;consumed_receipts=Receipts.empty;retained_cost=0}
  let receipt_request (receipt:receipt)=receipt.request
  let receipt_copy_generation (receipt:receipt)=receipt.copy_generation
  let same_attempt (a:attempt)(b:attempt)=a.lifetime=b.lifetime && a.serial=b.serial && a.id=b.id
  let same_logical (a:S.account_scope)(b:S.account_scope)=
    Uri.equal a.managed_sync_origin b.managed_sync_origin && a.user_id=b.user_id
  let same_owner a b=same_logical a b && a.S.account_generation=b.S.account_generation
    && a.lifecycle_generation=b.lifecycle_generation
  let affects change (scope:S.graph_scope)=match change with
    |Close_graph id|Remove_graph(id,_)->scope.graph_id=id
    |Replace_account|Stop_connection->true
  let capture ~owner ~change scopes=Rrbvec.filter(fun (scope:S.graph_scope)->
    affects change scope && (change=Stop_connection || same_logical owner scope.account))scopes
  let all predicate values=Rrbvec.fold_left(fun ok value->ok && predicate value)true values
  let any predicate values=Rrbvec.fold_left(fun yes value->yes || predicate value)false values
  let keys values=Rrbvec.fold_left(fun keys scope->Scopes.add scope keys)Scopes.empty values
  let frame_error (facts:facts)(entry:entry)=
    if facts.registration<>Some entry.request.registration
      || not(Option.exists(same_owner entry.request.owner)facts.account)
    then Some Owner_changed
    else if (match entry.request.change with Remove_graph(id,_)->not facts.authenticated || not(any((=)id)facts.catalog)|_->false)
    then Some Owner_changed
    else if not(all(fun scope->not(affects entry.request.change scope) || Scopes.mem scope entry.keys)facts.scopes)
    then Some Scopes_changed else None
  let observe state facts=match state.active with
    |Some({phase=(Preparing|Safe _);_}as entry)->
      (match frame_error facts entry with None->state
       |Some error->{state with active=Some{entry with phase=Failed error}})
    |_->state
  let equivalent (a:request)(b:request)=a.id=b.id && a.version=b.version && a.registration=b.registration
    && same_owner a.owner b.owner && a.change=b.change && Scopes.equal(keys a.expected)(keys b.expected)
  let prepare state (facts:facts) (request:request)=
    let state=observe state facts in
    if Ids.mem request.id state.retired then state,Refused Retired else
    match state.active with
    |Some entry when entry.request.id=request.id->
      state,(if equivalent entry.request request then Existing entry.phase else Refused Mismatch)
    |Some{settlement_pending=true;_}|Some{phase=(Preparing|Safe _|Consumed _);_}->state,Refused Busy
    |Some entry when entry.request.change<>request.change || not(same_owner entry.request.owner request.owner)->state,Refused Busy
    |previous->
      if state.next=Int64.max_int || Ids.cardinal state.retired + (if previous=None then 1 else 2)>8192
        || Rrbvec.length request.captured>8192 || Rrbvec.length request.expected>8192
        || state.retained_cost + 1 + Rrbvec.length request.expected + Rrbvec.length request.captured > 32768
      then state,Refused Full else
      if request.version<>facts.version then state,Refused Baseline_changed else
      let catalog_allows=match request.change with
        |Remove_graph(id,_)->facts.authenticated && any((=)id)facts.catalog
        |Close_graph id->any((=)id)facts.catalog || any(fun (scope:S.graph_scope)->scope.graph_id=id)request.captured
        |Replace_account|Stop_connection->true in
      let owned_scope(scope:S.graph_scope)=affects request.change scope
        && (request.change=Stop_connection || same_logical scope.account request.owner) in
      if request.registration<=0L || facts.registration<>Some request.registration
        || not(Option.exists(same_owner request.owner)facts.account) || not catalog_allows
        || not(all owned_scope request.expected) || not(all owned_scope request.captured)
      then state,Refused Owner_changed else
      let expected=keys request.expected and captured=keys request.captured in
      if not(all(fun scope->not(affects request.change scope)
        || (Scopes.mem scope expected && Scopes.mem scope captured))facts.scopes)
      then state,Refused Scopes_changed else
      let serial=Int64.succ state.next in
      let attempt={lifetime=state.lifetime;serial;id=request.id} in
      let retired=Option.fold ~none:state.retired ~some:(fun entry->Ids.add entry.request.id state.retired)previous in
      let entry={attempt;request;keys=captured;phase=Preparing;settlement_pending=true} in
      {state with next=serial;retired;active=Some entry},Start attempt
  let released_registration state registration=match state.active with
    |Some entry when entry.request.registration=registration && not entry.settlement_pending->
      (match entry.phase,entry.request.change with Consumed _,(Stop_connection|Replace_account)->state,None|_->
        {state with active=None;retired=Ids.add entry.request.id state.retired},Some entry.request.id)
    |_->state,None
  let phase state id=Option.bind state.active(fun entry->if entry.request.id=id then Some entry.phase else None)
  let settled state attempt ~copy_generation=match state.active with
    |Some({phase=Preparing;_}as entry) when same_attempt entry.attempt attempt->
      let phase=match entry.request.change,copy_generation with
        |Remove_graph _,None->Failed Missing_copy_witness
        |(Close_graph _|Replace_account|Stop_connection),Some _->Failed Mismatch
        |_->Safe{attempt;request=entry.request;copy_generation} in
      {state with active=Some{entry with phase;settlement_pending=false}}
    |Some entry when same_attempt entry.attempt attempt->
      {state with active=Some{entry with settlement_pending=false}}
    |_->state
  let current state=Option.map(fun entry->entry.request,entry.phase)state.active
  let completed state receipt=match state.active with
    |Some{phase=Consumed actual;_}when actual=receipt->
      {state with active=None;retired=Ids.add receipt.request.id state.retired}
    |_->state
  let failed state attempt=match state.active with
    |Some{phase=Consumed _;_}->state
    |Some entry when same_attempt entry.attempt attempt->{state with active=Some{entry with phase=Failed Not_settled;settlement_pending=false}}
    |_->state
  let consumed state (receipt:receipt)=
    if receipt.attempt.lifetime<>state.lifetime then Error Mismatch else
    match Receipts.find_opt receipt.request.id state.consumed_receipts with
    |Some actual when actual=receipt->Ok true
    |Some _->Error Mismatch
    |None->
    match receipt.request.change,state.active with
    |(Replace_account|Stop_connection),Some{phase=Consumed actual;_} when actual=receipt->Ok true
    |(Replace_account|Stop_connection),Some{phase=Safe actual;_} when actual=receipt->Ok false
    |(Replace_account|Stop_connection),Some{phase=Failed _;attempt;request;_}
       when same_attempt attempt receipt.attempt && request=receipt.request && receipt.copy_generation=None->Ok false
    |_->Error Not_settled
  let consume state (facts:facts) (receipt:receipt)=
    let state=observe state facts in
    if receipt.attempt.lifetime<>state.lifetime then state,Error Mismatch else
    match state.active with
    |Some{phase=Safe actual;_}when actual=receipt->
      let consumed_receipts,retained_cost=match receipt.request.change with
        |Replace_account|Stop_connection->Receipts.add receipt.request.id receipt state.consumed_receipts,
          state.retained_cost+1+Rrbvec.length receipt.request.expected+Rrbvec.length receipt.request.captured
        |Close_graph _|Remove_graph _->state.consumed_receipts,state.retained_cost in
      {state with active=Some{(Option.get state.active)with phase=Consumed actual};consumed_receipts;retained_cost},Ok receipt.request.change
    |Some{phase=Failed error;_}->state,Error error
    |_->state,Error(if Ids.mem receipt.request.id state.retired then Retired else Not_settled)
end

let host_fence_blocks state id=Logseq_sync_pure_reducer.Core.host_fence_blocks state.sync_core id
let host_fence_active state=Logseq_sync_pure_reducer.Core.host_fence_active state.sync_core
