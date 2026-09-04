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

let instruction_diagnostic = function
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
  | Run_sync left, Run_sync right -> Sync.equal_runner_effect left right
  | Run_worker left, Run_worker right -> left = right
  | Publish left, Publish right -> left = right
  | (Run_worker _ | Run_sync _ | Publish _), _ -> false
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
  ; database : database_handle option
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
    ; database = None
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
    | Start -> no_effects state
    | Projection_push push -> { next = state; effects = [ Publish (Graph_push push) ] }
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
      let state = { state with lifecycle_generation } in
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
           | Some _ | None -> { next = state; effects = [ Publish (Diagnostic message) ] })
        | Ok result ->
          let state, lifecycle_effects = apply_lifecycle state result.lifecycle in
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

let complete_execute runner_effect result =
  match runner_effect with
  | Request (ticket, Execute_request _) ->
    Some (Runner_completed (Execute_request_completed (ticket, result)))
  | Request (_, Close_database _) | Request (_, Handle_sync_worker_effect _) -> None
;;
