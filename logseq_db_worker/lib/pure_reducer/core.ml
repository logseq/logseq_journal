type target_kind =
  | Managed
  | Snapshot
  | Import_snapshot
  | Synced_mirror
  | Native_local

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

type engine_handle = string

type engine_opened =
  { engine : engine_handle
  ; graph_id : Logseq_db_types.Graph_types.Uuid.t option
  ; basis : int64 option
  }

let engine_opened ~engine_id ~graph_id ~basis = { engine = engine_id; graph_id; basis }
let engine_handle_id handle = handle
let opened_engine_handle opened = opened.engine
let opened_graph_id opened = opened.graph_id
let opened_basis opened = opened.basis

type effect_id = int64

type ticket =
  { id : effect_id
  ; generation : int
  }

let effect_id_to_string = Int64.to_string

type managed_mutation_prepared =
  { admission_id : string
  ; input : Logseq_sync_pure_reducer.Core.local_batch_input
  }

type managed_request_result =
  | Managed_immediate of Logseq_db_worker_contract.Protocol.response
  | Managed_prepared of managed_mutation_prepared

type lifecycle_result =
  | Lifecycle_unchanged
  | Lifecycle_opened of engine_opened * int
  | Lifecycle_closed of int
  | Lifecycle_failed of int * Logseq_db_worker_contract.Error.t

type sync_worker_result =
  { event : Logseq_sync_pure_reducer.Core.event option
  ; lifecycle : lifecycle_result
  ; mutation_success : Logseq_db_types.Mutation.success option
  }

type _ runner_request =
  | Open_engine : Logseq_db_worker_contract.Config.t -> engine_opened runner_request
  | Execute_request :
      { engine : engine_handle
      ; request : Logseq_db_worker_contract.Protocol.request
      }
      -> Logseq_db_worker_contract.Protocol.response runner_request
  | Close_engine : engine_handle -> unit runner_request
  | Prepare_managed_mutation :
      { engine : engine_handle
      ; scope : Logseq_sync_pure_reducer.Core.graph_scope
      ; admission_id : string
      ; request : Logseq_db_worker_contract.Protocol.request
      }
      -> managed_request_result runner_request
  | Handle_sync_worker_effect :
      Logseq_sync_pure_reducer.Core.worker_effect
      -> sync_worker_result runner_request

type runner_effect = Request : ticket * 'a runner_request -> runner_effect
type effect_error = Logseq_db_worker_contract.Error.t

type runner_completion =
  | Open_engine_completed of ticket * (engine_opened, effect_error) result
  | Execute_request_completed of
      ticket * (Logseq_db_worker_contract.Protocol.response, effect_error) result
  | Close_engine_completed of ticket * (unit, effect_error) result
  | Prepare_managed_mutation_completed of
      ticket * (managed_request_result, effect_error) result
  | Sync_worker_effect_completed of ticket * (sync_worker_result, effect_error) result

type output =
  | Reply of request_id * Logseq_db_worker_contract.Protocol.response
  | Graph_push of Logseq_db_worker_contract.Protocol.push
  | Sync_output of Logseq_sync_pure_reducer.Core.output
  | Graph_state_changed of graph_state
  | Diagnostic of string

type instruction =
  | Run_worker of runner_effect
  | Run_sync of Logseq_sync_pure_reducer.Core.runner_effect
  | Publish of output

module Sync = Logseq_sync_pure_reducer.Core

let sync_effect_name runner_effect =
  match runner_effect with
  | Sync.Request (_, Sync.Load_catalog _) -> "Load_catalog"
  | Sync.Request (_, Sync.Save_catalog _) -> "Save_catalog"
  | Sync.Request (_, Sync.Fetch_catalog _) -> "Fetch_catalog"
  | Sync.Request (_, Sync.Fetch_snapshot_baseline _) -> "Fetch_snapshot_baseline"
  | Sync.Request (_, Sync.Fetch_snapshot_metadata _) -> "Fetch_snapshot_metadata"
  | Sync.Request (_, Sync.Download_snapshot _) -> "Download_snapshot"
  | Sync.Request (_, Sync.Fetch_e2ee_graph_key _) -> "Fetch_e2ee_graph_key"
  | Sync.Request (_, Sync.Fetch_e2ee_user_keys _) -> "Fetch_e2ee_user_keys"
  | Sync.Request (_, Sync.Load_and_unlock_graph_key _) -> "Load_and_unlock_graph_key"
  | Sync.Request (_, Sync.Fetch_and_unlock_graph_key _) -> "Fetch_and_unlock_graph_key"
  | Sync.Request (_, Sync.Unlock_private_key _) -> "Unlock_private_key"
  | Sync.Request (_, Sync.Encrypt_protected_values _) -> "Encrypt_protected_values"
  | Sync.Request (_, Sync.Decrypt_protected_values _) -> "Decrypt_protected_values"
  | Sync.Start_websocket _ -> "Start_websocket"
  | Sync.Send_websocket _ -> "Send_websocket"
  | Sync.Close_websocket _ -> "Close_websocket"
  | Sync.Schedule_timer _ -> "Schedule_timer"
  | Sync.Cancel_effects _ -> "Cancel_effects"
;;

let instruction_diagnostic = function
  | Run_worker (Request (_, Open_engine _)) -> "run-worker:Open_engine"
  | Run_worker (Request (_, Execute_request _)) -> "run-worker:Execute_request"
  | Run_worker (Request (_, Close_engine _)) -> "run-worker:Close_engine"
  | Run_worker (Request (_, Prepare_managed_mutation _)) ->
    "run-worker:Prepare_managed_mutation"
  | Run_worker (Request (_, Handle_sync_worker_effect _)) ->
    "run-worker:Handle_sync_worker_effect"
  | Run_sync runner_effect -> "run-sync:" ^ sync_effect_name runner_effect
  | Publish (Sync_output (State_changed _)) -> "publish:sync-state"
  | Publish (Sync_output (Token_requested _)) -> "publish:sync-token"
  | Publish (Sync_output (Bootstrap_progressed _)) -> "publish:sync-bootstrap"
  | Publish (Sync_output (Graph_invalidated _)) -> "publish:sync-invalidation"
  | Publish (Reply _) -> "publish:reply"
  | Publish (Graph_push _) -> "publish:graph-push"
  | Publish (Graph_state_changed _) -> "publish:graph-state"
  | Publish (Diagnostic _) -> "publish:diagnostic"
;;

let equal_instruction left right =
  match left, right with
  | Run_sync left, Run_sync right ->
    Logseq_sync_pure_reducer.Core.equal_runner_effect left right
  | Run_worker left, Run_worker right -> left = right
  | Publish left, Publish right -> left = right
  | (Run_worker _ | Run_sync _ | Publish _), _ -> false
;;

let equal_instructions left right =
  List.length left = List.length right && List.for_all2 equal_instruction left right
;;

type config =
  { worker : Logseq_db_worker_contract.Config.t
  ; sync : Logseq_sync_pure_reducer.Core.config option
  }

type config_error = Invalid_config of string

let config ~worker ~sync =
  match worker.Logseq_db_worker_contract.Config.target, sync with
  | Managed_sync _, None -> Error (Invalid_config "managed target requires sync config")
  | (Snapshot _ | Import_snapshot _ | Synced_mirror _ | Native_local_graph _), Some _ ->
    Error (Invalid_config "local target cannot contain sync config")
  | _ -> Ok { worker; sync }
;;

type view =
  { target : target_kind
  ; graph : graph_state
  ; sync : Logseq_sync_pure_reducer.Core.state option
  ; pending_requests : int
  ; pending_effects : int
  ; shutdown : bool
  }

type pending =
  | Pending_open of ticket
  | Pending_execute of request_id * Logseq_db_worker_contract.Protocol.request * ticket
  | Pending_prepare of request_id * Logseq_db_worker_contract.Protocol.request * ticket
  | Pending_sync_worker of ticket * Logseq_sync_pure_reducer.Core.worker_effect

type managed_request =
  { admission_id : string
  ; id : request_id
  ; request : Logseq_db_worker_contract.Protocol.request
  }

type state =
  { config : config
  ; target : target_kind
  ; graph : graph_state
  ; sync_core : Logseq_sync_pure_reducer.Core.t option
  ; engine : engine_handle option
  ; pending : pending list
  ; managed_requests : managed_request list
  ; next_effect_id : int64
  ; next_mutation_admission : int64
  ; lifecycle_generation : int64
  ; shutdown : bool
  }

type create_error = Invalid_create of string

let target_kind = function
  | Logseq_db_worker_contract.Config.Managed_sync _ -> Managed
  | Snapshot _ -> Snapshot
  | Import_snapshot _ -> Import_snapshot
  | Synced_mirror _ -> Synced_mirror
  | Native_local_graph _ -> Native_local
;;

let initial (config : config) =
  let sync_core =
    match config.sync with
    | None -> Ok None
    | Some config ->
      Result.map_error
        (fun (Logseq_sync_pure_reducer.Core.Invalid_create message) ->
           Invalid_create message)
        (Logseq_sync_pure_reducer.Core.initial config)
      |> Result.map Option.some
  in
  Result.map
    (fun sync_core ->
       { config
       ; target = target_kind config.worker.target
       ; graph = { generation = 0; graph_id = None; phase = Graph_closed; error = None }
       ; sync_core
       ; engine = None
       ; pending = []
       ; managed_requests = []
       ; next_effect_id = 0L
       ; next_mutation_admission = 0L
       ; lifecycle_generation = 0L
       ; shutdown = false
       })
    sync_core
;;

let view state =
  { target = state.target
  ; graph = state.graph
  ; sync = Option.map Logseq_sync_pure_reducer.Core.state state.sync_core
  ; pending_requests =
      List.fold_left
        (fun count -> function
           | Pending_execute _ | Pending_prepare _ -> count + 1
           | Pending_open _ | Pending_sync_worker _ -> count)
        0
        state.pending
  ; pending_effects = List.length state.pending
  ; shutdown = state.shutdown
  }
;;

let equal_view left right = left = right

type event =
  | Start
  | Graph_request of
      { id : request_id
      ; request : Logseq_db_worker_contract.Protocol.request
      }
  | Sync_event of Logseq_sync_pure_reducer.Core.event
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

let remove_pending id pending =
  List.filter
    (function
      | Pending_open ticket -> not (Int64.equal id ticket.id)
      | Pending_execute (_, _, ticket) -> not (Int64.equal id ticket.id)
      | Pending_prepare (_, _, ticket) -> not (Int64.equal id ticket.id)
      | Pending_sync_worker (ticket, _) -> not (Int64.equal id ticket.id))
    pending
;;

let has_pending id pending =
  List.exists
    (function
      | Pending_open ticket -> Int64.equal id ticket.id
      | Pending_execute (_, _, ticket) -> Int64.equal id ticket.id
      | Pending_prepare (_, _, ticket) -> Int64.equal id ticket.id
      | Pending_sync_worker (ticket, _) -> Int64.equal id ticket.id)
    pending
;;

let worker_error ~code ~message =
  Logseq_db_worker_contract.Error.create ~code ~message ~details:[] |> Result.get_ok
;;

let unavailable_response
      (request : Logseq_db_worker_contract.Protocol.request)
      phase
      message
  =
  Logseq_db_worker_contract.Protocol.failed
    ~request_id:request.Logseq_db_worker_contract.Protocol.request_id
    ~phase
    ~basis:None
    (worker_error ~code:Closed_session ~message)
;;

let managed_failure (request : Logseq_db_worker_contract.Protocol.request) lower_message =
  let origin =
    Logseq_db_worker_contract.Error.create_cause_or_fallback
      ~component:Logseq_db_worker_contract.Error.Managed_sync
      ~operation:"completeManagedMutation"
      ~code:(Some "managedMutationFailure")
      ~message:lower_message
      ~fallback_message:"Managed sync reported a display-unsafe failure."
  in
  let error =
    Logseq_db_worker_contract.Error.create_with_origin
      ~code:Unsupported_semantics
      ~message:"The managed mutation could not be completed."
      ~details:[]
      ~origin
    |> Result.get_ok
  in
  Logseq_db_worker_contract.Protocol.failed
    ~request_id:request.Logseq_db_worker_contract.Protocol.request_id
    ~phase:Execute
    ~basis:None
    error
;;

let mutation_response (request : Logseq_db_worker_contract.Protocol.request) success =
  Logseq_db_worker_contract.Protocol.Succeeded
    { request_id = request.Logseq_db_worker_contract.Protocol.request_id
    ; basis = success.Logseq_db_types.Mutation.basis_after
    ; success = Mutation_result success
    }
;;

let mutation_push success =
  let invalidation =
    Logseq_db_worker_contract.Protocol.
      { basis = success.Logseq_db_types.Mutation.basis_after
      ; changed_uuids = success.changed_uuids
      ; changed_uuids_truncated = success.changed_uuids_truncated
      ; invalidate_graph_info = true
      ; invalidate_pages = true
      ; invalidate_tags = true
      ; invalidate_properties = true
      ; invalidate_tasks = true
      ; invalidate_references = true
      }
  in
  Logseq_db_worker_contract.Protocol.Graph_invalidated invalidation
;;

let retire_graph_requests state message =
  let pending_replies =
    List.filter_map
      (function
        | Pending_execute (id, request, _) | Pending_prepare (id, request, _) ->
          Some (Publish (Reply (id, unavailable_response request Execute message)))
        | Pending_open _ | Pending_sync_worker _ -> None)
      state.pending
  in
  let managed_replies =
    List.map
      (fun pending ->
         Publish
           (Reply (pending.id, unavailable_response pending.request Execute message)))
      state.managed_requests
  in
  { state with pending = []; managed_requests = [] }, pending_replies @ managed_replies
;;

let apply_lifecycle state = function
  | Lifecycle_unchanged -> state, []
  | Lifecycle_opened (opened, generation) ->
    let graph =
      { generation; graph_id = opened.graph_id; phase = Graph_open; error = None }
    in
    ( { state with graph; engine = Some opened.engine }
    , [ Publish (Graph_state_changed graph) ] )
  | Lifecycle_closed generation ->
    let graph = { generation; graph_id = None; phase = Graph_closed; error = None } in
    let state, replies =
      retire_graph_requests
        { state with graph; engine = None }
        "The graph closed before the request completed."
    in
    state, Publish (Graph_state_changed graph) :: replies
  | Lifecycle_failed (generation, error) ->
    let graph =
      { state.graph with generation; phase = Graph_failed; error = Some error }
    in
    let state, replies =
      retire_graph_requests
        { state with graph; engine = None }
        "The graph failed before the request completed."
    in
    state, Publish (Graph_state_changed graph) :: replies
;;

let translate_sync transition state =
  let state =
    { state with sync_core = Some transition.Logseq_sync_pure_reducer.Core.next }
  in
  let rec loop state reversed = function
    | [] -> { next = state; effects = List.rev reversed }
    | Logseq_sync_pure_reducer.Core.Run runner_effect :: rest ->
      loop state (Run_sync runner_effect :: reversed) rest
    | Publish output :: rest -> loop state (Publish (Sync_output output) :: reversed) rest
    | Delegate runner_effect :: rest ->
      let ticket, state = fresh_ticket state in
      let state =
        { state with
          pending = Pending_sync_worker (ticket, runner_effect) :: state.pending
        }
      in
      loop
        state
        (Run_worker (Request (ticket, Handle_sync_worker_effect runner_effect))
         :: reversed)
        rest
  in
  loop state [] transition.effects
;;

let step state event =
  if state.shutdown
  then no_effects state
  else (
    match event with
    | Start when state.target = Managed -> no_effects state
    | Start ->
      let ticket, state = fresh_ticket state in
      let next =
        { state with
          graph = { state.graph with phase = Graph_opening; error = None }
        ; pending = Pending_open ticket :: state.pending
        }
      in
      { next
      ; effects =
          [ Run_worker (Request (ticket, Open_engine state.config.worker))
          ; Publish (Graph_state_changed next.graph)
          ]
      }
    | Graph_request { id; request } when state.graph.phase <> Graph_open ->
      let response =
        unavailable_response
          request
          Logseq_db_worker_contract.Protocol.Open
          "The graph is not open."
      in
      { next = state; effects = [ Publish (Reply (id, response)) ] }
    | Graph_request { id; request } ->
      (match state.engine with
       | None ->
         let response =
           unavailable_response
             request
             Logseq_db_worker_contract.Protocol.Execute
             "The graph session is unavailable."
         in
         { next = state; effects = [ Publish (Reply (id, response)) ] }
       | Some engine ->
         (match state.target, request.Logseq_db_worker_contract.Protocol.command with
          | Managed, Mutate _ ->
            (match
               Option.bind
                 state.sync_core
                 Logseq_sync_pure_reducer.Core.admitted_graph_scope
             with
             | None ->
               let response =
                 unavailable_response request Execute "No managed graph is admitted."
               in
               { next = state; effects = [ Publish (Reply (id, response)) ] }
             | Some scope ->
               let admission_id = Int64.to_string state.next_mutation_admission in
               let state =
                 { state with
                   next_mutation_admission = Int64.succ state.next_mutation_admission
                 }
               in
               let ticket, state = fresh_ticket state in
               { next =
                   { state with
                     pending = Pending_prepare (id, request, ticket) :: state.pending
                   }
               ; effects =
                   [ Run_worker
                       (Request
                          ( ticket
                          , Prepare_managed_mutation
                              { engine; scope; admission_id; request } ))
                   ]
               })
          | Managed, Read _
          | (Snapshot | Import_snapshot | Synced_mirror | Native_local), _ ->
            let ticket, state = fresh_ticket state in
            { next =
                { state with
                  pending = Pending_execute (id, request, ticket) :: state.pending
                }
            ; effects =
                [ Run_worker (Request (ticket, Execute_request { engine; request })) ]
            }))
    | Sync_event event ->
      (match state.sync_core with
       | None -> no_effects state
       | Some core -> translate_sync (Logseq_sync_pure_reducer.Core.step core event) state)
    | Set_foreground foreground ->
      let lifecycle_generation = Int64.succ state.lifecycle_generation in
      let state = { state with lifecycle_generation } in
      (match state.sync_core with
       | None -> no_effects state
       | Some core ->
         translate_sync
           (Logseq_sync_pure_reducer.Core.step
              core
              (Foreground_changed { foreground; lifecycle_generation }))
           state)
    | Runner_completed (Open_engine_completed (ticket, result)) ->
      if
        ticket.generation <> state.graph.generation
        || not (has_pending ticket.id state.pending)
      then no_effects state
      else (
        let state = { state with pending = remove_pending ticket.id state.pending } in
        match result with
        | Ok opened ->
          let graph =
            { state.graph with
              graph_id = opened.graph_id
            ; phase = Graph_open
            ; error = None
            }
          in
          { next = { state with graph; engine = Some opened.engine }
          ; effects = [ Publish (Graph_state_changed graph) ]
          }
        | Error error ->
          let graph = { state.graph with phase = Graph_failed; error = Some error } in
          { next = { state with graph }
          ; effects = [ Publish (Graph_state_changed graph) ]
          })
    | Runner_completed (Execute_request_completed (ticket, result)) ->
      if
        ticket.generation <> state.graph.generation
        || not (has_pending ticket.id state.pending)
      then no_effects state
      else (
        let request_id, request =
          List.find_map
            (function
              | Pending_execute (request_id, request, candidate)
                when Int64.equal candidate.id ticket.id -> Some (request_id, request)
              | Pending_open _
              | Pending_prepare _
              | Pending_sync_worker _
              | Pending_execute _ -> None)
            state.pending
          |> Option.get
        in
        let state = { state with pending = remove_pending ticket.id state.pending } in
        let response, state, graph_effects =
          match result with
          | Ok response -> response, state, []
          | Error error ->
            let graph = { state.graph with phase = Graph_failed; error = Some error } in
            ( Logseq_db_worker_contract.Protocol.failed
                ~request_id:request.Logseq_db_worker_contract.Protocol.request_id
                ~phase:Execute
                ~basis:None
                error
            , { state with graph }
            , [ Publish (Graph_state_changed graph) ] )
        in
        { next = state
        ; effects = graph_effects @ [ Publish (Reply (request_id, response)) ]
        })
    | Runner_completed (Prepare_managed_mutation_completed (ticket, result)) ->
      if
        ticket.generation <> state.graph.generation
        || not (has_pending ticket.id state.pending)
      then no_effects state
      else (
        let request_id, request =
          List.find_map
            (function
              | Pending_prepare (request_id, request, candidate)
                when Int64.equal candidate.id ticket.id -> Some (request_id, request)
              | Pending_open _
              | Pending_execute _
              | Pending_prepare _
              | Pending_sync_worker _ -> None)
            state.pending
          |> Option.get
        in
        let state = { state with pending = remove_pending ticket.id state.pending } in
        match result with
        | Error error ->
          let response =
            Logseq_db_worker_contract.Protocol.failed
              ~request_id:request.request_id
              ~phase:Execute
              ~basis:None
              error
          in
          { next = state; effects = [ Publish (Reply (request_id, response)) ] }
        | Ok (Managed_immediate response) ->
          { next = state; effects = [ Publish (Reply (request_id, response)) ] }
        | Ok (Managed_prepared prepared) ->
          let managed_request =
            { admission_id = prepared.admission_id; id = request_id; request }
          in
          let state =
            { state with managed_requests = managed_request :: state.managed_requests }
          in
          (match state.sync_core with
           | None ->
             { next = state
             ; effects =
                 [ Publish
                     (Reply
                        ( request_id
                        , managed_failure
                            request
                            "Managed synchronization is unavailable." ))
                 ]
             }
           | Some core ->
             translate_sync
               (Logseq_sync_pure_reducer.Core.step
                  core
                  (Local_batch_prepared prepared.input))
               state))
    | Runner_completed (Close_engine_completed _) -> no_effects state
    | Runner_completed (Sync_worker_effect_completed (ticket, result)) ->
      if
        ticket.generation <> state.graph.generation
        || not (has_pending ticket.id state.pending)
      then no_effects state
      else (
        let worker_effect =
          List.find_map
            (function
              | Pending_sync_worker (candidate, runner_effect)
                when Int64.equal candidate.id ticket.id -> Some runner_effect
              | Pending_open _
              | Pending_execute _
              | Pending_prepare _
              | Pending_sync_worker _ -> None)
            state.pending
          |> Option.get
        in
        let state = { state with pending = remove_pending ticket.id state.pending } in
        match result with
        | Ok result ->
          let state, lifecycle_effects = apply_lifecycle state result.lifecycle in
          let transitioned =
            match state.sync_core, result.event with
            | Some core, Some event ->
              translate_sync (Logseq_sync_pure_reducer.Core.step core event) state
            | (None | Some _), None | None, Some _ -> no_effects state
          in
          let state = transitioned.next in
          let terminal_effects, state =
            match worker_effect with
            | Logseq_sync_pure_reducer.Core.Complete_local_batch request ->
              (match
                 List.find_opt
                   (fun pending -> String.equal pending.admission_id request.admission_id)
                   state.managed_requests
               with
               | None -> [], state
               | Some pending ->
                 let state =
                   { state with
                     managed_requests =
                       List.filter
                         (fun candidate ->
                            not (String.equal candidate.admission_id request.admission_id))
                         state.managed_requests
                   }
                 in
                 (match request.action, result.mutation_success with
                  | Commit _, Some success ->
                    let effects =
                      (if success.status = Logseq_db_types.Mutation.Applied
                       then [ Publish (Graph_push (mutation_push success)) ]
                       else [])
                      @ [ Publish
                            (Reply (pending.id, mutation_response pending.request success))
                        ]
                    in
                    effects, state
                  | Reject { message; _ }, _ ->
                    ( [ Publish
                          (Reply (pending.id, managed_failure pending.request message))
                      ]
                    , state )
                  | Commit _, None ->
                    ( [ Publish
                          (Reply
                             ( pending.id
                             , managed_failure
                                 pending.request
                                 "The managed mutation did not commit." ))
                      ]
                    , state )))
            | Inspect_mirror _
            | Activate_snapshot _
            | Delete_mirror _
            | Attach_graph _
            | Detach_graph _
            | Reset_managed_account _
            | Inspect_authoritative_batch _
            | Apply_authoritative_batch _
            | Commit_outbox_transition _ -> [], state
          in
          { next = state
          ; effects = lifecycle_effects @ transitioned.effects @ terminal_effects
          }
        | Error error ->
          let terminal_effects, state =
            match worker_effect with
            | Logseq_sync_pure_reducer.Core.Complete_local_batch request ->
              (match
                 List.find_opt
                   (fun pending -> String.equal pending.admission_id request.admission_id)
                   state.managed_requests
               with
               | None -> [], state
               | Some pending ->
                 ( [ Publish
                       (Reply
                          ( pending.id
                          , managed_failure
                              pending.request
                              (Logseq_db_worker_contract.Error.message error) ))
                   ]
                 , { state with
                     managed_requests =
                       List.filter
                         (fun candidate ->
                            not (String.equal candidate.admission_id request.admission_id))
                         state.managed_requests
                   } ))
            | Inspect_mirror _
            | Activate_snapshot _
            | Delete_mirror _
            | Attach_graph _
            | Detach_graph _
            | Reset_managed_account _
            | Inspect_authoritative_batch _
            | Apply_authoritative_batch _
            | Commit_outbox_transition _ -> [], state
          in
          { next = state
          ; effects =
              Publish (Diagnostic (Logseq_db_worker_contract.Error.message error))
              :: terminal_effects
          })
    | Shutdown ->
      let state, replies = retire_graph_requests state "The worker shut down." in
      let close_effects, state =
        match state.engine with
        | None -> [], state
        | Some engine ->
          let ticket, state = fresh_ticket state in
          [ Run_worker (Request (ticket, Close_engine engine)) ], state
      in
      { next =
          { state with
            shutdown = true
          ; graph = { state.graph with phase = Graph_closed }
          }
      ; effects = replies @ close_effects
      })
;;

let complete_open runner_effect result =
  match runner_effect with
  | Request (ticket, Open_engine _) ->
    Some (Runner_completed (Open_engine_completed (ticket, result)))
  | Request (_, Execute_request _)
  | Request (_, Close_engine _)
  | Request (_, Prepare_managed_mutation _)
  | Request (_, Handle_sync_worker_effect _) -> None
;;

let complete_execute runner_effect result =
  match runner_effect with
  | Request (ticket, Execute_request _) ->
    Some (Runner_completed (Execute_request_completed (ticket, result)))
  | Request (_, Open_engine _)
  | Request (_, Close_engine _)
  | Request (_, Prepare_managed_mutation _)
  | Request (_, Handle_sync_worker_effect _) -> None
;;
