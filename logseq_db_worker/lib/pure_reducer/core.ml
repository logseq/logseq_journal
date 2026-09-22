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
      ; request : Logseq_db_worker_contract.Protocol.request
      }
      -> Logseq_db_worker_contract.Protocol.response runner_request
  | Close_database : database_handle -> unit runner_request
  | Handle_sync_worker_effect :
      Logseq_sync_pure_reducer.Core.worker_effect
      -> sync_worker_result runner_request

type runner_effect = Request : ticket * 'a runner_request -> runner_effect
type effect_error = Logseq_db_worker_contract.Error.t

type runner_completion =
  | Execute_request_completed of
      ticket * (Logseq_db_worker_contract.Protocol.response, effect_error) result
  | Close_database_completed of ticket * (unit, effect_error) result
  | Sync_worker_effect_completed of ticket * (sync_worker_result, effect_error) result

type asset_notice =
  | Asset_availability of
      { consumer : string
      ; asset : Logseq_db_types.Graph_types.Uuid.t
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
  | Reply of request_id * Logseq_db_worker_contract.Protocol.response
  | Graph_push of Logseq_db_worker_contract.Protocol.push
  | Sync_output of Logseq_sync_pure_reducer.Core.output
  | Graph_state_changed of graph_state
  | Diagnostic of string

type upload_recovery_ticket =
  { scope : Logseq_sync_pure_reducer.Core.graph_scope
  ; after : Logseq_db_types.Graph_types.Uuid.t option
  ; limit : int
  ; serial : int
  }

type instruction =
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
  | Publish (Graph_push _) -> "publish:graph-push"
  | Publish (Sync_output _) -> "publish:sync-output"
  | Publish (Graph_state_changed _) -> "publish:graph-state"
  | Publish (Diagnostic _) -> "publish:diagnostic"
;;

let equal_instruction left right =
  match left, right with
  | Read_uploads l, Read_uploads r -> l = r
  | Run_upload (lc, li), Run_upload (rc, ri) -> lc = rc && li = ri
  | Run_asset (lc, li), Run_asset (rc, ri) -> lc = rc && li = ri
  | Close_asset_scope left, Close_asset_scope right -> left = right
  | Run_sync left, Run_sync right -> Sync.equal_runner_effect left right
  | Run_worker left, Run_worker right -> left = right
  | Publish left, Publish right -> left = right
  | ( ( Run_worker _
      | Run_sync _
      | Run_asset _
      | Run_upload _
      | Read_uploads _
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
  | Pending_execute of request_id * Logseq_db_worker_contract.Protocol.request * ticket
  | Pending_sync_worker of ticket * Sync.worker_effect

type state =
  { graph : graph_state
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
    { graph = { generation = 0; graph_id = None; phase = Graph_closed; error = None }
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
  | Start
  | Graph_request of
      { id : request_id
      ; request : Logseq_db_worker_contract.Protocol.request
      }
  | Sync_event of Sync.event
  | Projection_push of Logseq_db_worker_contract.Protocol.push
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

let worker_error ~code ~message =
  Logseq_db_worker_contract.Error.create ~code ~message ~details:[] |> Result.get_ok
;;

let unavailable_response request message =
  Logseq_db_worker_contract.Protocol.failed
    ~request_id:request.Logseq_db_worker_contract.Protocol.request_id
    (worker_error ~code:Closed_session ~message)
;;

let translate_sync transition state =
  let state = { state with sync_core = transition.Sync.next } in
  let rec loop state reversed = function
    | [] -> { next = state; effects = List.rev reversed }
    | Sync.Run sync_effect :: rest -> loop state (Run_sync sync_effect :: reversed) rest
    | Sync.Publish output :: rest ->
      loop state (Publish (Sync_output output) :: reversed) rest
    | Sync.Delegate (Sync.Detach_graph scope) :: rest ->
      let graph = { state.graph with phase = Graph_closing } in
      loop
        { state with graph; deferred_detach = Some scope }
        (Publish (Graph_state_changed graph) :: reversed)
        rest
    | Sync.Delegate worker_effect :: rest ->
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
    , [ Publish (Graph_state_changed graph) ] )
  | Lifecycle_closed generation ->
    let graph = { generation; graph_id = None; phase = Graph_closed; error = None } in
    { state with graph; database = None }, [ Publish (Graph_state_changed graph) ]
  | Lifecycle_failed (generation, error) ->
    let graph =
      { state.graph with generation; phase = Graph_failed; error = Some error }
    in
    { state with graph; database = None }, [ Publish (Graph_state_changed graph) ]
;;

let execute_completion state ticket result =
  let pending =
    List.find_map
      (function
        | Pending_execute (id, request, candidate) when Int64.equal candidate.id ticket.id
          -> Some (id, request)
        | Pending_execute _ | Pending_sync_worker _ -> None)
      state.pending
  in
  match pending with
  | None -> no_effects state
  | Some (id, request) ->
    let state = { state with pending = remove_pending ticket.id state.pending } in
    let response =
      match result with
      | Ok response -> response
      | Error error ->
        Logseq_db_worker_contract.Protocol.failed ~request_id:request.request_id error
    in
    let transitioned =
      match response with
      | Logseq_db_worker_contract.Protocol.V2_response
          { outcome = V2_mutation_committed _; _ } ->
        translate_sync (Sync.step state.sync_core Sync.Local_outbox_changed) state
      | V2_response _ -> no_effects state
    in
    { next = transitioned.next
    ; effects = Publish (Reply (id, response)) :: transitioned.effects
    }
;;

let step state event =
  if state.shutdown
  then no_effects state
  else (
    match event with
    | Uploads_loaded _
    | Upload_requested _
    | Upload_completed _
    | Asset_requested _
    | Asset_completed _ -> no_effects state
    | Start -> no_effects state
    | Projection_push push ->
      if
        state.graph.phase = Graph_open
        && Sync.admitted_graph_scope state.sync_core <> None
      then { next = state; effects = [ Publish (Graph_push push) ] }
      else no_effects state
    | Graph_request { id; request } ->
      (match state.graph.phase, state.database with
       | Graph_open, Some database ->
         let ticket, state = fresh_ticket state in
         { next =
             { state with
               pending = Pending_execute (id, request, ticket) :: state.pending
             }
         ; effects =
             [ Run_worker (Request (ticket, Execute_request { database; request })) ]
         }
       | (Graph_closed | Graph_opening | Graph_closing | Graph_failed), _
       | Graph_open, None ->
         { next = state
         ; effects =
             [ Publish (Reply (id, unavailable_response request "The graph is not open."))
             ]
         })
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
        ticket.generation <> state.graph.generation
        || not (has_pending ticket.id state.pending)
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
           | Some (Sync.Apply_authoritative_batch request) ->
             let transitioned =
               translate_sync
                 (Sync.step
                    state.sync_core
                    (Sync.Authoritative_batch_failed
                       { scope = Sync.effect_scope_of_graph request.scope.graph; message }))
                 state
             in
             { next = transitioned.next
             ; effects = Publish (Diagnostic message) :: transitioned.effects
             }
           | Some (Sync.Apply_outbox_transition request) ->
             let transitioned =
               translate_sync
                 (Sync.step
                    state.sync_core
                    (Sync.Outbox_transition_failed { request; message }))
                 state
             in
             { transitioned with
               effects = Publish (Diagnostic message) :: transitioned.effects
             }
           | Some (Sync.Detach_graph scope) ->
             translate_sync
               (Sync.step
                  state.sync_core
                  (Sync.Graph_detached (scope, Error "Graph close failed.")))
               state
           | Some (Sync.Delete_mirror request) ->
             translate_sync
               (Sync.step
                  state.sync_core
                  (Sync.Mirror_deleted (request, Error "Mirror deletion failed.")))
               state
           | Some _ | None -> { next = state; effects = [ Publish (Diagnostic message) ] })
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
      ; effects = close_effects
      })
;;

(* Drain all already-issued database operations before executing the existing close.
   Their replies still finish; Sync rejects their superseded graph events. *)
let step state event =
  let transition = step state event in
  match transition.next.deferred_detach, transition.next.pending with
  | Some scope, [] when not transition.next.shutdown ->
    let ticket, next = fresh_ticket transition.next in
    let worker_effect = Sync.Detach_graph scope in
    { next =
        { next with
          deferred_detach = None
        ; pending = [ Pending_sync_worker (ticket, worker_effect) ]
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
  else Sync.asset_context state.sync_core
;;

let asset_online state =
  state.foreground
  &&
  match (Sync.state state.sync_core).snapshot.sync_phase with
  | Offline | Paused | Failed -> false
  | Connecting | Pulling | Submitting | Current -> true
;;

let asset_unlocked (context : Sync.asset_context) =
  (not context.encrypted) || Option.is_some context.key
;;

let asset_instructions (context : Sync.asset_context) instructions =
  List.map
    (function
      | Transfer.Notify { consumer; asset; availability } ->
        Publish
          (Asset_notice
             (context.scope, Asset_availability { consumer; asset; availability }))
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

let apply_asset state context transfer event =
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
            (Transfer.config ~active:3 ~foreground_reserved:1 ~pending:128 ~retries:3
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
      (fun (context, _, _) ->
         match current with
         | Some active -> context.Sync.scope = active.scope
         | None -> false)
      transition.next.uploads
  in
  let cancellations =
    List.concat_map
      (fun (context, _, upload) ->
         let _, instructions = Asset_upload.step upload Shutdown in
         List.map (fun instruction -> Run_upload (context, instruction)) instructions)
      retired
  in
  let cache_closes =
    retired
    |> List.map (fun (context, _, _) -> context.Sync.scope)
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
  let apply context operation upload upload_event =
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
       | Ok _ | Error _ ->
         ( { state with recovery = Some (ticket.scope, ticket.after, true) }
         , [ Publish (Diagnostic "Upload recovery could not read a valid checkpoint page")
           ] ))
    | Sync_event Sync.Online_recovery_requested ->
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
