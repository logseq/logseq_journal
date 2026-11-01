module Worker = Worker_api
module Id = Logseq_db_worker_lui.Journal_worker_ids.Worker
module Intents = Map.Make (String)
module Slots = Map.Make (Int64)
module Graphs = Map.Make (Worker.Uuid)

module Observation_ids = Map.Make (struct
    type t = Worker.request_id

    let compare = Worker.compare_request_id
  end)

type _ kind =
  | Unit : unit kind
  | Observed : 'a kind -> 'a Worker.observed kind
  | Mutation : Worker.mutation_progress kind
  | Info : Worker.graph_info kind
  | Admission : Worker.Protocol.v2_admission_inspection kind
  | Journal : Worker.page option kind
  | Journals : Worker.Protocol.v2_journal_item Worker.slice kind
  | Page : Worker.Protocol.v2_page_lookup kind
  | Block : Worker.Protocol.v2_block_lookup kind
  | Summary : Worker.block_summary kind
  | Children : Worker.block Worker.slice kind
  | Members : Worker.children kind
  | Tree : Worker.Protocol.v2_tree_member Worker.slice kind
  | Favorites : Worker.favorites kind
  | Statuses : Worker.task_status_catalog kind
  | Definitions : Worker.Graph.task_status_definition option list kind
  | Assets : Worker.asset_listing kind
  | Changes : Worker.change_batch kind

let kind : type a. a Worker.query -> a kind = function
  | Graph_info -> Info
  | Admission -> Admission
  | Journal _ -> Journal
  | Journals _ -> Journals
  | Page _ -> Page
  | Outline_block _ -> Block
  | Block_summary _ -> Summary
  | Children _ -> Children
  | Child_members _ -> Members
  | Tree _ -> Tree
  | Favorites _ -> Favorites
  | Task_statuses _ -> Statuses
  | Task_status_definitions _ -> Definitions
  | Asset_descriptors _ -> Assets
  | Assets _ -> Assets
  | Changes _ -> Changes
;;

let rec same_kind : type a b. a kind -> b kind -> (a, b) Worker.equality option =
  fun a b ->
  match a, b with
  | Observed a, Observed b ->
    (match same_kind a b with
     | Some Refl -> Some Refl
     | None -> None)
  | Unit, Unit -> Some Refl
  | Mutation, Mutation -> Some Refl
  | Info, Info -> Some Refl
  | Admission, Admission -> Some Refl
  | Journal, Journal -> Some Refl
  | Journals, Journals -> Some Refl
  | Page, Page -> Some Refl
  | Block, Block -> Some Refl
  | Summary, Summary -> Some Refl
  | Children, Children -> Some Refl
  | Members, Members -> Some Refl
  | Tree, Tree -> Some Refl
  | Favorites, Favorites -> Some Refl
  | Statuses, Statuses -> Some Refl
  | Definitions, Definitions -> Some Refl
  | Assets, Assets -> Some Refl
  | Changes, Changes -> Some Refl
  | _ -> None
;;

type _ planned =
  | Read : 'a Worker.query -> 'a planned
  | Operation : 'a Worker.request -> 'a planned

type query_target =
  | Cleanup of Worker.session
  | Presentation of Worker.presentation
  | Direct of Worker.session
  | Sealed of Worker.session * Worker.read_budget
  | Expected of
      Logseq_db_worker_lui.Logseq_db_worker_lui_service.timeline_scope * int * int

type 'a ticket =
  { id : Worker.request_id
  ; serial : int64
  ; kind : 'a kind
  ; query : 'a planned
  ; target : query_target
  }

type 'a slot =
  { ticket : 'a ticket
  ; dispatched : bool
  ; admitted : Id.request_id option
  ; sample_epoch : Worker.observation_epoch option
  ; origin : (Worker.session * Worker.read_budget) option
  ; result : 'a Worker.reply option
  ; early : 'a Worker.reply option
  ; cancelled : bool
  ; forgotten : bool
  }

type entry = Entry : 'a slot -> entry

type 'a observation_state =
  { obs_initial : 'a Worker.observed ticket
  ; obs_session : Worker.session
  ; obs_budget : Worker.read_budget
  ; obs_query : 'a Worker.query
  ; obs_handle : 'a Worker.observation option
  ; obs_latest : 'a Worker.observed option
  ; obs_registered : bool
  ; obs_admitted : bool
  ; obs_releasing : bool
  ; obs_release_inflight : bool
  ; obs_cleanup_waiting : bool
  ; obs_attempt : Worker.request_id option
  ; obs_cleanup_error : Worker.error option
  ; obs_error : Worker.error option
  ; obs_epoch : Worker.observation_epoch option
  ; obs_dirty : bool
  ; obs_retry : bool
  }

type observation_entry = Observing : 'a observation_state -> observation_entry

type shutdown_state =
  | Active
  | Draining
  | Stopped
  | Shutdown_failed of Worker.error

type view =
  { bootstrap_state : Worker.bootstrap_state
  ; current : Worker.projection option
  ; entries : entry Slots.t
  ; handoffs : (Worker.handoff_id * Worker.handoff_state) list
  ; shutdown : shutdown_state
  ; intents : Worker.mutation_progress Intents.t
  ; observations : observation_entry Observation_ids.t
  ; retired_observations : Worker.session Observation_ids.t
  ; retired_observation_count : int
  }

type lifecycle =
  | Running
  | Retrying
  | Stopping
  | Rebinding
  | Finished

type t =
  { client : Worker.Uuid.t
  ; next : int64
  ; binding : Worker.binding option
  ; facts : view
  ; lifecycle : lifecycle
  ; registration_pending : bool
  ; bootstrap_inflight : bool
  ; bootstrap_mailbox : Id.request_id option
  ; release_pending : bool
  ; released : bool
  ; active_handoff : Worker.handoff_id option
  ; retired : Worker.projection Graphs.t
  ; fenced : Worker.host_change list
  }

let initial ~client_id =
  { client = client_id
  ; next = 0L
  ; binding = None
  ; lifecycle = Running
  ; registration_pending = false
  ; bootstrap_inflight = false
  ; bootstrap_mailbox = None
  ; release_pending = false
  ; released = false
  ; active_handoff = None
  ; retired = Graphs.empty
  ; fenced = []
  ; facts =
      { bootstrap_state = Worker.Awaiting_baseline
      ; current = None
      ; entries = Slots.empty
      ; handoffs = []
      ; shutdown = Active
      ; intents = Intents.empty
      ; observations = Observation_ids.empty
      ; retired_observations = Observation_ids.empty
      ; retired_observation_count = 0
      }
  }
;;

let current_session facts session =
  match facts.bootstrap_state, facts.current with
  | Worker.Ready _, Some p ->
    List.exists
      (fun r -> r.Worker.phase = Worker.Open && Worker.equal_session r.session session)
      (Worker.residents p)
  | _ -> false
;;

let view t = t.facts
let bootstrap v = v.bootstrap_state
let projection v = v.current
let shutdown_state v = v.shutdown
let mutation_progress _ _ = None
let intent_key intent = Bytes.to_string (Worker.encode_mutation_intent intent)
let intent_progress view intent = Intents.find_opt (intent_key intent) view.intents
let import_progress _ _ = None

let handoff v id =
  List.find_map
    (fun (actual, value) ->
       if Worker.equal_handoff_id actual id then Some value else None)
    v.handoffs
;;

let asset_notices _ _ = []
let session_asset_notices _ _ = []
let ticket_id ticket = ticket.id

let same_ticket : type a b. a ticket -> b ticket -> (a, b) Worker.equality option =
  fun a b ->
  match same_kind a.kind b.kind with
  | Some Worker.Refl
    when Worker.equal_request_id a.id b.id && a.target = b.target && a.query = b.query ->
    Some Refl
  | _ -> None
;;

let reply : type a. view -> a ticket -> a Worker.reply option =
  fun v ticket ->
  match Slots.find_opt ticket.serial v.entries with
  | Some (Entry slot) when not slot.forgotten ->
    (match same_ticket ticket slot.ticket with
     | Some Worker.Refl -> slot.result
     | None -> None)
  | _ -> None
;;

let query_origin
  : type a. view -> a ticket -> (Worker.session * Worker.read_budget) option
  =
  fun view ticket ->
  match Slots.find_opt ticket.serial view.entries with
  | Some (Entry slot) when not slot.forgotten ->
    (match same_ticket ticket slot.ticket with
     | Some Worker.Refl -> slot.origin
     | None -> None)
  | _ -> None
;;

let find_observation
  : type a. view -> Worker.request_id -> a Worker.query -> a observation_state option
  =
  fun facts id query ->
  match Observation_ids.find_opt id facts.observations with
  | Some (Observing value) ->
    (match same_kind (kind query) (kind value.obs_query) with
     | Some Worker.Refl when query = value.obs_query -> Some value
     | _ -> None)
  | None -> None
;;

let observed facts observation =
  match
    find_observation
      facts
      (Worker.observation_id observation)
      (Worker.observation_query observation)
  with
  | Some
      { obs_handle = Some owned
      ; obs_releasing = false
      ; obs_registered = true
      ; obs_admitted = true
      ; _
      } as found ->
    (match Worker.same_observation observation owned, found with
     | Some Worker.Refl, Some value
       when current_session facts value.obs_session
            && Worker.equal_request_id
                 value.obs_initial.id
                 (Worker.observation_id observation)
            && value.obs_budget = Worker.observation_budget observation ->
       value.obs_latest
     | _ -> None)
  | _ -> None
;;

let observation_handle
  : type a. view -> a Worker.observed ticket -> a Worker.observation option
  =
  fun facts ticket ->
  match ticket.query with
  | Operation (Worker.Observe (_, query)) ->
    (match find_observation facts ticket.id query with
     | Some value
       when (not value.obs_releasing)
            && value.obs_admitted
            && current_session facts value.obs_session -> value.obs_handle
     | _ -> None)
  | _ -> None
;;

let observation_error facts observation =
  match
    find_observation
      facts
      (Worker.observation_id observation)
      (Worker.observation_query observation)
  with
  | Some value
    when Option.exists
           (fun owned -> Worker.same_observation observation owned <> None)
           value.obs_handle ->
    (match value.obs_cleanup_error with
     | Some _ as error -> error
     | None -> value.obs_error)
  | _ -> None
;;

let observation_matches : type a. a observation_state -> a Worker.observation -> bool =
  fun value observation ->
  Worker.equal_session value.obs_session (Worker.observation_session observation)
  && Worker.equal_request_id value.obs_initial.id (Worker.observation_id observation)
  && value.obs_budget = Worker.observation_budget observation
  && value.obs_query = Worker.observation_query observation
;;

let equal_observation_entry (Observing a) (Observing b) =
  match same_kind (kind a.obs_query) (kind b.obs_query) with
  | Some Worker.Refl -> a = b
  | None -> false
;;

let equal_entry (Entry a) (Entry b) =
  match same_ticket a.ticket b.ticket with
  | Some Worker.Refl ->
    a.dispatched = b.dispatched
    && a.admitted = b.admitted
    && a.sample_epoch = b.sample_epoch
    && a.origin = b.origin
    && a.result = b.result
    && a.early = b.early
    && a.cancelled = b.cancelled
    && a.forgotten = b.forgotten
  | None -> false
;;

let equal_view a b =
  a == b
  || (a.bootstrap_state = b.bootstrap_state
      && a.current = b.current
      && a.handoffs = b.handoffs
      && a.shutdown = b.shutdown
      && a.intents = b.intents
      && a.retired_observation_count = b.retired_observation_count
      && Observation_ids.equal
           Worker.equal_session
           a.retired_observations
           b.retired_observations
      && Observation_ids.equal equal_observation_entry a.observations b.observations
      && Slots.equal equal_entry a.entries b.entries)
;;

type event =
  | Worker_bound of Worker.binding
  | Retry_bootstrap
  | Admitted : 'a ticket * Id.request_id -> event
  | Admission_refused : 'a ticket * Worker.admission_error -> event
  | Admission_failed : 'a ticket * Worker.error -> event
  | Bootstrap_admitted of Worker.binding * Id.request_id
  | Bootstrap_not_admitted of Worker.binding * Worker.admission_error
  | Binding_release_completed of Worker.binding * (unit, Worker.error) result
  | Binding_release_not_admitted of Worker.binding * Worker.admission_error
  | Capacity_available
  | Shutdown_requested
  | Bootstrap_received of Worker.binding * Worker.bootstrap_state
  | Completed : 'a ticket * 'a Worker.reply -> event
  | Projection_received of Worker.projection
  | Observation_registered :
      'a Worker.observed ticket * 'a Worker.observation * Worker.observation_epoch
      -> event
  | Observation_release_completed of
      Worker.session * Worker.request_id * (unit, Worker.error) result
  | Observation_release_not_admitted of
      Worker.session * Worker.request_id * Worker.admission_error
  | Observation_notice of Worker.observation_notice
  | Observation_notices_failed of Worker.binding * Worker.error
  | Observation_received : 'a Worker.observed -> event
  | Asset_received of Worker.asset_notice
  | Cancel : 'a ticket -> event
  | Forget : 'a ticket -> event
  | Release : 'a Worker.observation -> event
  | Handoff_completed of Worker.handoff_id * Worker.handoff_state
  | Drain

type instruction =
  | Bootstrap
  | Release_binding of Worker.binding
  | Release_observation_registration of Worker.session * Worker.request_id
  | Bind_replacement
  | Send : 'a ticket * Worker.session * 'a Worker.request -> instruction
  | Cancel_request : 'a ticket -> instruction
  | Quiesce of Worker.handoff_id * Worker.host_change
  | Publish of view
  | Schedule_drain

type transition =
  { next : t
  ; instructions : instruction list
  }

let unchanged next = { next; instructions = [] }

let changed next instructions =
  let intents =
    Intents.map
      (function
        | Worker.Confirmed confirmation as progress ->
          let presentation = Worker.confirmation_presentation confirmation in
          if Option.bind next.facts.current Worker.selected = Some presentation
          then progress
          else
            Worker.Committed_pending_presentation
              (Worker.confirmation_receipt confirmation)
        | progress -> progress)
      next.facts.intents
  in
  let next = { next with facts = { next.facts with intents } } in
  { next; instructions = instructions @ [ Publish next.facts ] }
;;

let affected session = function
  | Worker.Account_will_change | Connection_will_stop -> true
  | Graph_will_close id | Graph_will_remove (id, _) ->
    Worker.Uuid.equal (Worker.graph_id session) id
;;

let validate_session ?owner state session =
  if Option.exists (fun owner -> not (Worker.matches_scope session owner)) owner
  then Error Worker.Revoked_session
  else if state.lifecycle <> Running || not (current_session state.facts session)
  then Error Worker.Revoked_session
  else if List.exists (affected session) state.fenced
  then Error Worker.Host_change_in_progress
  else Ok ()
;;

let current_target facts = function
  | Cleanup _ -> true
  | Presentation presentation ->
    current_session facts (Worker.presentation_session presentation)
    && Option.bind facts.current Worker.selected = Some presentation
  | Direct session | Sealed (session, _) -> current_session facts session
  | Expected (owner, _, _) ->
    Option.fold
      ~none:false
      ~some:(fun p ->
        List.exists
          (fun r -> r.Worker.phase = Worker.Open && Worker.matches_scope r.session owner)
          (Worker.residents p))
      facts.current
;;

let affected_target target change =
  match target with
  | Cleanup _ -> false
  | Presentation presentation ->
    affected (Worker.presentation_session presentation) change
  | Direct session | Sealed (session, _) -> affected session change
  | Expected (owner, _, _) ->
    (match change with
     | Worker.Account_will_change | Connection_will_stop -> true
     | Graph_will_close id | Graph_will_remove (id, _) ->
       Worker.Uuid.equal owner.graph_id id)
;;

let is_binding state b =
  Option.fold ~none:false ~some:(Worker.equal_binding b) state.binding
;;

let identity client serial =
  let hex =
    Digest.to_hex
      (Digest.string (Worker.Uuid.to_string client ^ ":" ^ Int64.to_string serial))
  in
  Worker.Uuid.of_string
    (Printf.sprintf
       "%s-%s-4%s-8%s-%s"
       (String.sub hex 0 8)
       (String.sub hex 8 4)
       (String.sub hex 13 3)
       (String.sub hex 17 3)
       (String.sub hex 20 12))
  |> Result.get_ok
;;

let outstanding state =
  Slots.exists (fun _ (Entry slot) -> slot.result = None) state.facts.entries
;;

let settle state instructions =
  if state.released && (not state.bootstrap_inflight) && not (outstanding state)
  then (
    match state.lifecycle with
    | Retrying ->
      changed { state with lifecycle = Rebinding } (instructions @ [ Bind_replacement ])
    | Stopping ->
      changed
        { state with
          lifecycle = Finished
        ; facts = { state.facts with shutdown = Stopped }
        }
        instructions
    | _ -> changed state instructions)
  else changed state instructions
;;

let cancel_entries ?(waiting = true) predicate facts =
  let instructions = ref [] in
  let entries =
    Slots.filter_map
      (fun _ (Entry slot as entry) ->
         if
           slot.result <> None
           || (match slot.ticket.target with
               | Cleanup _ -> true
               | _ -> false)
           || ((not slot.dispatched) && not waiting)
           || not (predicate slot.ticket.target)
         then Some entry
         else if not slot.dispatched
         then
           if slot.forgotten
           then None
           else
             Some
               (Entry
                  { slot with
                    cancelled = true
                  ; result = Some (Worker.Answered (Error Worker.Revoked_session))
                  })
         else (
           if slot.admitted <> None && not slot.cancelled
           then instructions := Cancel_request slot.ticket :: !instructions;
           Some (Entry { slot with cancelled = true })))
      facts.entries
  in
  { facts with entries }, List.rev !instructions
;;

let dispatch_waiting ?(publish = false) state instructions =
  let sends = ref [] in
  let entries =
    Slots.map
      (fun (Entry slot as entry) ->
         if state.lifecycle <> Running || slot.dispatched || slot.result <> None
         then entry
         else (
           let reject error =
             Entry { slot with result = Some (Worker.Answered (Error error)) }
           in
           match slot.ticket.target, state.facts.bootstrap_state, state.facts.current with
           | ( Expected (owner, maximum_items, maximum_bytes)
             , Worker.Ready _
             , Some projection ) ->
             (match
                List.find_opt
                  (fun r -> Worker.matches_scope r.Worker.session owner)
                  (Worker.residents projection)
              with
              | None
                when Worker.scope_is_superseded
                       ?previous:(Graphs.find_opt owner.graph_id state.retired)
                       projection
                       owner -> reject Worker.Revoked_session
              | None -> entry
              | Some { phase = Worker.Open; session; _ } ->
                let planned =
                  Result.bind
                    (Worker.read_budget
                       session
                       ~maximum_items:
                         (min maximum_items Worker.Protocol.maximum_page_size)
                       ~maximum_bytes:
                         (min
                            maximum_bytes
                            (Worker.capabilities session).limits.response_budget_bytes))
                    (fun budget ->
                       match slot.ticket.query with
                       | Read query ->
                         Result.map
                           (fun () -> Worker.Query (budget, query))
                           (Worker.validate_request
                              session
                              (Worker.Query (budget, query)))
                       | Operation _ ->
                         Error (Worker.Invalid_input "An effect cannot wait as a read"))
                in
                (match planned with
                 | Error error -> reject error
                 | Ok operation ->
                   sends := Send (slot.ticket, session, operation) :: !sends;
                   let origin =
                     match operation with
                     | Worker.Query (budget, _) -> Some (session, budget)
                     | _ -> None
                   in
                   Entry { slot with dispatched = true; origin })
              | Some { phase = Worker.Opening; _ } -> entry
              | Some { phase = Worker.Failed error; _ } -> reject error
              | Some { phase = Worker.Closing; _ } -> reject Worker.Revoked_session)
           | _, (Worker.Bootstrap_failed error | Binding_revoked error), _ -> reject error
           | _ -> entry))
      state.facts.entries
  in
  let next = { state with facts = { state.facts with entries } } in
  if
    publish
    || instructions <> []
    || !sends <> []
    || not (Slots.equal equal_entry entries state.facts.entries)
  then changed next (instructions @ List.rev !sends)
  else unchanged next
;;

let retire state lifecycle =
  let facts, instructions = cancel_entries (fun _ -> true) state.facts in
  let facts =
    { facts with
      current = None
    ; bootstrap_state = Worker.Awaiting_baseline
    ; shutdown = (if lifecycle = Stopping then Draining else facts.shutdown)
    }
  in
  match state.binding with
  | None ->
    changed
      { state with lifecycle = Finished; facts = { facts with shutdown = Stopped } }
      instructions
  | Some binding ->
    changed
      { state with lifecycle; facts; released = false; release_pending = true }
      (instructions @ [ Release_binding binding ])
;;

let apply_baseline state binding incoming =
  if state.lifecycle <> Running || not (is_binding state binding)
  then unchanged state
  else (
    let current =
      match incoming with
      | Worker.Ready p -> Some p
      | _ -> None
    in
    let valid =
      match current with
      | Some p ->
        Worker.equal_binding binding (Worker.projection_binding p)
        && Option.fold
             ~none:true
             ~some:(fun old ->
               Worker.compare_projection_version
                 (Worker.projection_version p)
                 (Worker.projection_version old)
               >= 0)
             state.facts.current
      | None -> true
    in
    if not valid
    then unchanged state
    else (
      let retired =
        match state.facts.current, current with
        | Some previous, Some projection ->
          List.fold_left
            (fun retired resident ->
               if
                 List.exists
                   (fun current ->
                      Worker.equal_session current.Worker.session resident.Worker.session)
                   (Worker.residents projection)
               then retired
               else Graphs.add (Worker.graph_id resident.session) previous retired)
            state.retired
            (Worker.residents previous)
        | _ -> state.retired
      in
      let facts = { state.facts with current; bootstrap_state = incoming } in
      let facts, instructions =
        cancel_entries
          ~waiting:false
          (fun target -> not (current_target facts target))
          facts
      in
      dispatch_waiting ~publish:true { state with facts; retired } instructions))
;;

let known_receipt facts key =
  match Intents.find_opt key facts.intents with
  | Some (Worker.Committed_pending_presentation receipt) -> Some receipt
  | Some (Worker.Confirmed confirmation) ->
    Some (Worker.confirmation_receipt confirmation)
  | _ -> None
;;

let receipt_agrees facts intent receipt =
  let key = intent_key intent in
  key = intent_key (Worker.receipt_intent receipt)
  && Option.fold
       ~none:true
       ~some:(fun original ->
         Worker.receipt_revisions original = Worker.receipt_revisions receipt)
       (known_receipt facts key)
;;

let checked_result : type a. view -> a ticket -> a Worker.reply -> a Worker.reply =
  fun facts ticket result ->
  let mismatch () =
    Worker.Answered
      (Error
         (Worker.Protocol_mismatch
            "Mutation receipt identity or original point does not match its ticket"))
  in
  match ticket.query, result with
  | Operation (Worker.Observe (_, query)), Worker.Answered (Ok value) ->
    (match find_observation facts ticket.id query with
     | Some owned when observation_matches owned value.observation -> result
     | _ ->
       Worker.Answered
         (Error
            (Worker.Protocol_mismatch
               "Observed value does not match its planned registration")))
  | Operation (Worker.Refresh handle), Worker.Answered (Ok value) ->
    (match
       ( Worker.same_observation handle value.observation
       , find_observation
           facts
           (Worker.observation_id handle)
           (Worker.observation_query handle) )
     with
     | Some Worker.Refl, Some owned when observation_matches owned handle -> result
     | _ ->
       Worker.Answered
         (Error
            (Worker.Protocol_mismatch "Refreshed value does not match its owned interest")))
  | ( Operation (Worker.Mutate intent)
    , Worker.Answered (Ok (Worker.Committed_pending_presentation receipt)) ) ->
    if receipt_agrees facts intent receipt then result else mismatch ()
  | Operation (Worker.Mutate _), Worker.Answered (Ok (Worker.Confirmed _)) -> mismatch ()
  | ( Operation (Worker.Confirm (presentation, receipt))
    , Worker.Answered (Ok (Worker.Confirmed confirmation)) ) ->
    if
      Worker.confirmation_presentation confirmation = presentation
      && Worker.receipt_revisions receipt
         = Worker.receipt_revisions (Worker.confirmation_receipt confirmation)
      && receipt_agrees
           facts
           (Worker.receipt_intent receipt)
           (Worker.confirmation_receipt confirmation)
    then result
    else mismatch ()
  | _ -> result
;;

let retain_observed_value state value ~admitted ~cancelled =
  let id = Worker.observation_id value.Worker.observation in
  match find_observation state.facts id (Worker.observation_query value.observation) with
  | Some owned when observation_matches owned value.observation ->
    let active =
      state.lifecycle = Running
      && current_session state.facts owned.obs_session
      && (not cancelled)
      && not owned.obs_releasing
    in
    let epoch_allowed =
      Option.fold
        ~none:true
        ~some:(fun epoch -> Worker.compare_observation_epoch value.epoch epoch >= 0)
        owned.obs_epoch
    in
    let accepted_update =
      active
      && admitted
      && epoch_allowed
      && Option.fold
           ~none:true
           ~some:(fun previous ->
             Worker.compare_observation_epoch value.epoch previous.Worker.epoch > 0)
           owned.obs_latest
    in
    let latest = if accepted_update then Some value else owned.obs_latest in
    let obs_epoch = if epoch_allowed then Some value.epoch else owned.obs_epoch in
    let owned =
      { owned with
        obs_handle = Some value.observation
      ; obs_registered = true
      ; obs_epoch
      ; obs_admitted = owned.obs_admitted || admitted
      ; obs_latest = latest
      ; obs_error = (if accepted_update then None else owned.obs_error)
      ; obs_releasing = owned.obs_releasing || not active
      }
    in
    { state with
      facts =
        { state.facts with
          observations = Observation_ids.add id (Observing owned) state.facts.observations
        }
    }
  | _ -> state
;;

let retain_observation_error state ticket handle error =
  let id = Worker.observation_id handle in
  let sample_epoch =
    match Slots.find_opt ticket.serial state.facts.entries with
    | Some (Entry slot) -> slot.sample_epoch
    | None -> None
  in
  match find_observation state.facts id (Worker.observation_query handle) with
  | Some owned
    when observation_matches owned handle
         && (not owned.obs_releasing)
         && Option.exists (Worker.equal_request_id ticket.id) owned.obs_attempt
         &&
         match sample_epoch, owned.obs_epoch with
         | Some epoch, Some latest -> Worker.compare_observation_epoch epoch latest >= 0
         | _ -> true ->
    { state with
      facts =
        { state.facts with
          observations =
            Observation_ids.add
              id
              (Observing { owned with obs_error = Some error })
              state.facts.observations
        }
    }
  | _ -> state
;;

let retain_observation_result
  : type a. t -> a ticket -> a Worker.reply -> admitted:bool -> cancelled:bool -> t
  =
  fun state ticket result ~admitted ~cancelled ->
  match ticket.query, result with
  | Operation (Worker.Observe _), Worker.Answered (Ok value) ->
    retain_observed_value state value ~admitted ~cancelled
  | Operation (Worker.Refresh _), Worker.Answered (Ok value) ->
    (* A canceled sampled read does not unregister its long-lived interest. *)
    if cancelled
    then state
    else retain_observed_value state value ~admitted ~cancelled:false
  | Operation (Worker.Refresh handle), Worker.Answered (Error error) ->
    if cancelled then state else retain_observation_error state ticket handle error
  | Operation (Worker.Observe (_, query)), Worker.Answered (Error error) ->
    (match find_observation state.facts ticket.id query with
     | Some owned when owned.obs_attempt = None && not owned.obs_releasing ->
       { state with
         facts =
           { state.facts with
             observations =
               Observation_ids.add
                 ticket.id
                 (Observing { owned with obs_error = Some error })
                 state.facts.observations
           }
       }
     | _ -> state)
  | Operation (Worker.Observe (_, query)), Worker.Not_admitted _ ->
    (match find_observation state.facts ticket.id query with
     | Some owned ->
       { state with
         facts =
           { state.facts with
             observations =
               Observation_ids.add
                 ticket.id
                 (Observing { owned with obs_releasing = true })
                 state.facts.observations
           }
       }
     | _ -> state)
  | Operation (Worker.Refresh handle), Worker.Not_admitted Worker.Full ->
    (match
       find_observation
         state.facts
         (Worker.observation_id handle)
         (Worker.observation_query handle)
     with
     | Some owned when observation_matches owned handle ->
       { state with
         facts =
           { state.facts with
             observations =
               Observation_ids.add
                 (Worker.observation_id handle)
                 (Observing { owned with obs_retry = true })
                 state.facts.observations
           }
       }
     | _ -> state)
  | _ -> state
;;

let finish : type a. t -> a ticket -> a Worker.reply -> bool -> transition =
  fun state ticket result require_admission ->
  match Slots.find_opt ticket.serial state.facts.entries with
  | Some (Entry slot) ->
    (match same_ticket ticket slot.ticket with
     | Some Worker.Refl
       when slot.result = None
            && (slot.early = None || not require_admission)
            && (require_admission || slot.admitted = None)
            && slot.dispatched ->
       let result = checked_result state.facts ticket result in
       if require_admission && slot.admitted = None
       then (
         let state =
           retain_observation_result
             state
             ticket
             result
             ~admitted:false
             ~cancelled:slot.cancelled
         in
         changed
           { state with
             facts =
               { state.facts with
                 entries =
                   Slots.add
                     ticket.serial
                     (Entry { slot with early = Some result })
                     state.facts.entries
               }
           }
           [])
       else (
         let state =
           retain_observation_result
             state
             ticket
             result
             ~admitted:(slot.admitted <> None)
             ~cancelled:slot.cancelled
         in
         let intents : Worker.mutation_progress Intents.t =
           match ticket.query with
           | Operation (Worker.Mutate intent) ->
             let key = intent_key intent in
             let previous = Intents.find_opt key state.facts.intents in
             let progress : Worker.mutation_progress option =
               match result with
               | Worker.Answered (Ok progress) -> Some progress
               | Worker.Not_admitted _ when slot.admitted = None -> previous
               | _ ->
                 (match previous with
                  | Some
                      (Worker.Committed_pending_presentation _ | Confirmed _ | Rejected _)
                    -> previous
                  | _ -> Some Worker.Outcome_unknown)
             in
             (match previous, progress with
              | ( Some (Worker.Committed_pending_presentation _ | Confirmed _)
                , Some (Worker.Outcome_unknown | Rejected _) ) -> state.facts.intents
              | Some (Worker.Confirmed _), Some (Worker.Committed_pending_presentation _)
                -> state.facts.intents
              | Some (Worker.Rejected _), _ -> state.facts.intents
              | _, None -> state.facts.intents
              | _, Some progress -> Intents.add key progress state.facts.intents)
           | Operation (Worker.Confirm (presentation, receipt)) ->
             let key = intent_key (Worker.receipt_intent receipt) in
             (match result with
              | Worker.Answered (Ok (Worker.Confirmed confirmation))
                when current_target state.facts (Presentation presentation) ->
                Intents.add key (Worker.Confirmed confirmation) state.facts.intents
              | _ ->
                if Intents.mem key state.facts.intents
                then state.facts.intents
                else
                  Intents.add
                    key
                    (Worker.Committed_pending_presentation receipt)
                    state.facts.intents)
           | _ -> state.facts.intents
         in
         let result =
           let cancelled_observe =
             match ticket.query with
             | Operation (Worker.Observe _) -> slot.cancelled
             | _ -> false
           in
           if cancelled_observe
           then Worker.Interrupted Worker.Cancelled
           else if state.lifecycle = Running && current_target state.facts ticket.target
           then result
           else Worker.Answered (Error Worker.Revoked_session)
         in
         let entries =
           if slot.forgotten
           then Slots.remove ticket.serial state.facts.entries
           else
             Slots.add
               ticket.serial
               (Entry { slot with result = Some result; early = None })
               state.facts.entries
         in
         settle { state with facts = { state.facts with entries; intents } } [])
     | _ -> unchanged state)
  | None -> unchanged state
;;

let retire_observation facts session id =
  match Observation_ids.find_opt id facts.observations with
  | Some (Observing value) when Worker.equal_session session value.obs_session ->
    { facts with
      observations =
        Observation_ids.add
          id
          (Observing
             { value with
               obs_releasing = true
             ; obs_cleanup_waiting = false
             ; obs_cleanup_error = None
             })
          facts.observations
    }
  | _ -> facts
;;

let cancel_observation : type a. view -> a ticket -> view =
  fun facts ticket ->
  match ticket.query with
  | Operation (Worker.Observe _) ->
    (match Observation_ids.find_opt ticket.id facts.observations with
     | Some (Observing value) when Worker.equal_request_id ticket.id value.obs_initial.id
       -> retire_observation facts value.obs_session ticket.id
     | _ -> facts)
  | _ -> facts
;;

let forget_observation : type a. t -> a ticket -> transition =
  fun state ticket ->
  match Slots.find_opt ticket.serial state.facts.entries with
  | Some (Entry slot) ->
    (match same_ticket ticket slot.ticket with
     | Some Worker.Refl ->
       let entries =
         if slot.result <> None
         then Slots.remove ticket.serial state.facts.entries
         else
           Slots.add
             ticket.serial
             (Entry { slot with forgotten = true })
             state.facts.entries
       in
       changed { state with facts = { state.facts with entries } } []
     | _ -> unchanged state)
  | _ -> unchanged state
;;

let retain_registration
  : type a.
    t
    -> a Worker.observed ticket
    -> a Worker.observation
    -> Worker.observation_epoch
    -> transition
  =
  fun state ticket handle epoch ->
  let id = Worker.observation_id handle in
  match find_observation state.facts id (Worker.observation_query handle) with
  | Some value when observation_matches value handle ->
    let matches =
      match ticket.query with
      | Operation (Worker.Observe _) ->
        Worker.equal_request_id ticket.id value.obs_initial.id
      | Operation (Worker.Refresh original) ->
        Worker.same_observation original handle <> None
      | _ -> false
    in
    if not matches
    then unchanged state
    else (
      let obs_epoch =
        match value.obs_epoch with
        | Some previous when Worker.compare_observation_epoch previous epoch >= 0 ->
          Some previous
        | _ -> Some epoch
      in
      let value =
        { value with obs_handle = Some handle; obs_registered = true; obs_epoch }
      in
      let entries =
        match Slots.find_opt ticket.serial state.facts.entries with
        | Some (Entry slot) ->
          (match same_ticket ticket slot.ticket with
           | Some Worker.Refl ->
             Slots.add
               ticket.serial
               (Entry { slot with sample_epoch = Some epoch })
               state.facts.entries
           | _ -> state.facts.entries)
        | _ -> state.facts.entries
      in
      changed
        { state with
          facts =
            { state.facts with
              entries
            ; observations =
                Observation_ids.add id (Observing value) state.facts.observations
            }
        }
        [])
  | _ -> unchanged state
;;

let complete_release_waiters facts session id =
  let entries =
    Slots.filter_map
      (fun _ (Entry slot as entry) ->
         match slot.ticket.query with
         | Operation (Worker.Release handle)
           when slot.result = None
                && Worker.equal_session session (Worker.observation_session handle)
                && Worker.equal_request_id id (Worker.observation_id handle) ->
           if slot.forgotten
           then None
           else Some (Entry { slot with result = Some (Worker.Answered (Ok ())) })
         | _ -> Some entry)
      facts.entries
  in
  { facts with entries }
;;

let release_observation_result state session id result =
  match Observation_ids.find_opt id state.facts.observations with
  | Some (Observing value)
    when value.obs_releasing
         && value.obs_release_inflight
         && Worker.equal_session session value.obs_session ->
    (match result with
     | Ok () ->
       let facts =
         { state.facts with
           observations = Observation_ids.remove id state.facts.observations
         ; retired_observations =
             Observation_ids.add id session state.facts.retired_observations
         ; retired_observation_count = state.facts.retired_observation_count + 1
         }
       in
       changed { state with facts = complete_release_waiters facts session id } []
     | Error error ->
       changed
         { state with
           facts =
             { state.facts with
               observations =
                 Observation_ids.add
                   id
                   (Observing
                      { value with
                        obs_release_inflight = false
                      ; obs_cleanup_error = Some error
                      })
                   state.facts.observations
             }
         }
         [])
  | _ -> unchanged state
;;

let cancel : type a. t -> a ticket -> bool -> transition =
  fun state ticket forget ->
  match Slots.find_opt ticket.serial state.facts.entries with
  | Some (Entry slot) ->
    (match same_ticket ticket slot.ticket with
     | Some Worker.Refl ->
       let forgotten = slot.forgotten || forget in
       let instructions =
         if slot.result = None && slot.admitted <> None && not slot.cancelled
         then [ Cancel_request ticket ]
         else []
       in
       let slot =
         if slot.result = None && not slot.dispatched
         then { slot with result = Some (Worker.Interrupted Worker.Cancelled) }
         else slot
       in
       let entries =
         if forgotten && slot.result <> None
         then Slots.remove ticket.serial state.facts.entries
         else
           Slots.add
             ticket.serial
             (Entry { slot with cancelled = true; forgotten })
             state.facts.entries
       in
       changed { state with facts = { state.facts with entries } } instructions
     | None -> unchanged state)
  | None -> unchanged state
;;

let step_base state event =
  match event with
  | Worker_bound binding when state.binding = None || state.lifecycle = Rebinding ->
    changed
      { state with
        binding = Some binding
      ; lifecycle = Running
      ; released = false
      ; release_pending = false
      ; registration_pending = true
      ; bootstrap_inflight = true
      ; bootstrap_mailbox = None
      ; active_handoff = None
      ; retired = Graphs.empty
      ; fenced = []
      ; facts =
          { state.facts with
            current = None
          ; bootstrap_state = Worker.Awaiting_baseline
          ; shutdown = Active
          ; retired_observations =
              (if state.lifecycle = Rebinding
               then Observation_ids.empty
               else state.facts.retired_observations)
          ; retired_observation_count =
              (if state.lifecycle = Rebinding
               then 0
               else state.facts.retired_observation_count)
          }
      }
      [ Bootstrap ]
  | Worker_bound _ -> unchanged state
  | Retry_bootstrap when state.lifecycle = Running -> retire state Retrying
  | Retry_bootstrap
    when state.lifecycle = Retrying && (not state.release_pending) && not state.released
    ->
    (match state.binding with
     | None -> unchanged state
     | Some binding ->
       changed { state with release_pending = true } [ Release_binding binding ])
  | Retry_bootstrap -> unchanged state
  | Shutdown_requested when state.lifecycle <> Finished && state.lifecycle <> Stopping ->
    retire state Stopping
  | Shutdown_requested -> unchanged state
  | Bootstrap_admitted (binding, id)
    when is_binding state binding && state.bootstrap_inflight ->
    (match state.bootstrap_mailbox with
     | None -> unchanged { state with bootstrap_mailbox = Some id }
     | Some _ -> unchanged state)
  | Bootstrap_not_admitted (binding, admission) when is_binding state binding ->
    let error =
      Worker.Service_failed "Worker is stopping; bootstrap cannot be admitted"
    in
    let bootstrap_state =
      match admission with
      | Worker.Stopping -> Worker.Bootstrap_failed error
      | _ -> Worker.Bootstrap_not_ready "Worker registration was not admitted"
    in
    let next =
      { state with
        registration_pending = admission = Worker.Stopping
      ; bootstrap_inflight = false
      ; bootstrap_mailbox = None
      }
    in
    if state.lifecycle = Running
    then
      dispatch_waiting
        ~publish:true
        { next with facts = { state.facts with bootstrap_state } }
        []
    else settle next []
  | Bootstrap_admitted _ | Bootstrap_not_admitted _ -> unchanged state
  | Bootstrap_received (binding, incoming) when is_binding state binding ->
    let state = { state with bootstrap_inflight = false; bootstrap_mailbox = None } in
    if state.lifecycle = Running
    then apply_baseline state binding incoming
    else settle state []
  | Bootstrap_received _ -> unchanged state
  | Projection_received p ->
    apply_baseline state (Worker.projection_binding p) (Worker.Ready p)
  | Binding_release_completed (binding, result)
    when is_binding state binding && state.lifecycle <> Running ->
    (match result with
     | Ok () ->
       let retired_observations =
         Observation_ids.fold
           (fun id (Observing value) retired ->
              Observation_ids.add id value.obs_session retired)
           state.facts.observations
           state.facts.retired_observations
       in
       let facts =
         { state.facts with
           observations = Observation_ids.empty
         ; retired_observations
         ; retired_observation_count =
             state.facts.retired_observation_count
             + Observation_ids.cardinal state.facts.observations
         }
       in
       let facts =
         Observation_ids.fold
           (fun id (Observing value) facts ->
              complete_release_waiters facts value.obs_session id)
           state.facts.observations
           facts
       in
       settle { state with facts; released = true; release_pending = false } []
     | Error error ->
       changed
         { state with
           release_pending = false
         ; facts =
             { state.facts with
               shutdown =
                 (if state.lifecycle = Stopping
                  then Shutdown_failed error
                  else state.facts.shutdown)
             }
         }
         [])
  | Binding_release_not_admitted (binding, Worker.Stopping) when is_binding state binding
    ->
    let error =
      Worker.Service_failed "Worker stopped before registration cleanup could be admitted"
    in
    changed
      { state with
        release_pending = false
      ; facts =
          { state.facts with
            shutdown =
              (if state.lifecycle = Stopping
               then Shutdown_failed error
               else state.facts.shutdown)
          ; bootstrap_state = Worker.Bootstrap_failed error
          }
      }
      []
  | Binding_release_not_admitted (binding, _) when is_binding state binding ->
    unchanged { state with release_pending = false }
  | Binding_release_completed _ | Binding_release_not_admitted _ -> unchanged state
  | Capacity_available | Drain ->
    (match state.binding, state.lifecycle with
     | Some binding, (Retrying | Stopping)
       when (not state.release_pending) && not state.released ->
       changed { state with release_pending = true } [ Release_binding binding ]
     | Some _, Running when not state.registration_pending ->
       changed
         { state with
           registration_pending = true
         ; bootstrap_inflight = true
         ; bootstrap_mailbox = None
         }
         [ Bootstrap ]
     | _, Running -> dispatch_waiting state []
     | _ -> unchanged state)
  | Admitted (ticket, id) ->
    (match Slots.find_opt ticket.serial state.facts.entries with
     | Some (Entry slot) ->
       (match same_ticket ticket slot.ticket with
        | Some Worker.Refl
          when slot.dispatched && slot.admitted = None && slot.result = None ->
          let early = slot.early in
          let slot = { slot with admitted = Some id; early = None } in
          let observations =
            match Observation_ids.find_opt ticket.id state.facts.observations with
            | Some (Observing value)
              when Worker.equal_request_id value.obs_initial.id ticket.id ->
              Observation_ids.add
                ticket.id
                (Observing { value with obs_admitted = true })
                state.facts.observations
            | _ -> state.facts.observations
          in
          let state = { state with facts = { state.facts with observations } } in
          let next =
            { state with
              facts =
                { state.facts with
                  entries = Slots.add ticket.serial (Entry slot) state.facts.entries
                }
            }
          in
          (match early with
           | Some result -> finish next ticket result true
           | None ->
             changed next (if slot.cancelled then [ Cancel_request ticket ] else []))
        | _ -> unchanged state)
     | None -> unchanged state)
  | Admission_refused (ticket, error) ->
    finish state ticket (Worker.Not_admitted error) false
  | Admission_failed (ticket, error) ->
    finish state ticket (Worker.Answered (Error error)) false
  | Completed (ticket, result) -> finish state ticket result true
  | Cancel ticket ->
    cancel { state with facts = cancel_observation state.facts ticket } ticket false
  | Forget ticket ->
    (match ticket.query with
     | Operation (Worker.Observe _) -> forget_observation state ticket
     | _ -> cancel state ticket true)
  | Handoff_completed (id, outcome)
    when Option.fold ~none:false ~some:(Worker.equal_handoff_id id) state.active_handoff
    ->
    changed
      { state with
        active_handoff =
          (match outcome with
           | Worker.Quiescing _ -> Some id
           | _ -> None)
      ; facts =
          { state.facts with
            handoffs =
              (id, outcome)
              :: List.filter
                   (fun (old, _) -> not (Worker.equal_handoff_id old id))
                   state.facts.handoffs
          }
      }
      []
  | Observation_registered (ticket, handle, epoch) ->
    retain_registration state ticket handle epoch
  | Observation_release_completed (session, id, result) ->
    release_observation_result state session id result
  | Observation_release_not_admitted (session, id, admission) ->
    (match Observation_ids.find_opt id state.facts.observations with
     | Some (Observing value)
       when Worker.equal_session session value.obs_session && value.obs_release_inflight
       ->
       let error =
         match admission with
         | Worker.Full -> None
         | _ -> Some (Worker.Service_failed "Observation cleanup not admitted")
       in
       changed
         { state with
           facts =
             { state.facts with
               observations =
                 Observation_ids.add
                   id
                   (Observing
                      { value with
                        obs_release_inflight = false
                      ; obs_cleanup_error = error
                      ; obs_cleanup_waiting = admission = Worker.Full
                      })
                   state.facts.observations
             }
         }
         []
     | _ -> unchanged state)
  | Release handle ->
    (match
       find_observation
         state.facts
         (Worker.observation_id handle)
         (Worker.observation_query handle)
     with
     | Some owned when observation_matches owned handle ->
       changed
         { state with
           facts = retire_observation state.facts owned.obs_session owned.obs_initial.id
         }
         []
     | _ -> unchanged state)
  | Observation_notice (Worker.Observation_invalidated notice)
    when is_binding state notice.binding ->
    (match Observation_ids.find_opt notice.id state.facts.observations with
     | Some (Observing value)
       when (not value.obs_releasing)
            && Worker.matches_scope value.obs_session notice.owner
            && Option.fold
                 ~none:true
                 ~some:(fun epoch ->
                   Worker.compare_observation_epoch notice.epoch epoch > 0)
                 value.obs_epoch ->
       let value = { value with obs_epoch = Some notice.epoch; obs_dirty = true } in
       changed
         { state with
           facts =
             { state.facts with
               observations =
                 Observation_ids.add notice.id (Observing value) state.facts.observations
             }
         }
         []
     | _ -> unchanged state)
  | Observation_notice (Worker.Observations_resync binding) when is_binding state binding
    ->
    let observations =
      Observation_ids.map
        (fun (Observing value) ->
           Observing { value with obs_dirty = not value.obs_releasing })
        state.facts.observations
    in
    changed { state with facts = { state.facts with observations } } []
  | Observation_notices_failed (binding, error) when is_binding state binding ->
    let observations =
      Observation_ids.map
        (fun (Observing value) -> Observing { value with obs_error = Some error })
        state.facts.observations
    in
    changed { state with facts = { state.facts with observations } } []
  | Observation_notice _ | Observation_notices_failed _ -> unchanged state
  | Observation_received value ->
    (match
       find_observation
         state.facts
         (Worker.observation_id value.observation)
         (Worker.observation_query value.observation)
     with
     | Some owned
       when owned.obs_admitted && owned.obs_registered && not owned.obs_releasing ->
       changed (retain_observed_value state value ~admitted:true ~cancelled:false) []
     | _ -> unchanged state)
  | Handoff_completed _ | Asset_received _ -> unchanged state
;;

let plan_refresh ?(internal = false) (state : t) session handle =
  let id = Worker.observation_id handle in
  match find_observation state.facts id (Worker.observation_query handle) with
  | Some owned
    when observation_matches owned handle
         && owned.obs_registered
         && (not owned.obs_releasing)
         && owned.obs_handle <> None ->
    if state.next = Int64.max_int
    then Error (Worker.Invalid_input "Request counter exhausted")
    else (
      let serial = Int64.succ state.next in
      let ticket =
        { id = Worker.request_id (identity state.client serial)
        ; serial
        ; kind = Observed (kind owned.obs_query)
        ; query = Operation (Worker.Refresh handle)
        ; target = Sealed (session, owned.obs_budget)
        }
      in
      let slot =
        { ticket
        ; dispatched = true
        ; admitted = None
        ; sample_epoch = None
        ; origin = Some (session, owned.obs_budget)
        ; result = None
        ; early = None
        ; cancelled = false
        ; forgotten = internal
        }
      in
      let facts =
        { state.facts with
          entries = Slots.add serial (Entry slot) state.facts.entries
        ; observations =
            Observation_ids.add
              id
              (Observing
                 { owned with
                   obs_dirty = false
                 ; obs_retry = false
                 ; obs_attempt = Some ticket.id
                 })
              state.facts.observations
        }
      in
      Ok
        ( ticket
        , changed
            { state with next = serial; facts }
            [ Send (ticket, session, Worker.Refresh handle) ] ))
  | _ -> Error Worker.Revoked_session
;;

let progress_observations ~retry transition =
  let state = transition.next in
  let instructions = ref [] in
  let count = ref 0 in
  let observations =
    Observation_ids.mapi
      (fun id (Observing value) ->
         let releasing =
           value.obs_releasing || validate_session state value.obs_session <> Ok ()
         in
         let value = { value with obs_releasing = releasing } in
         if
           releasing
           && state.lifecycle = Running
           && (not value.obs_release_inflight)
           && value.obs_cleanup_error = None
           && ((not value.obs_cleanup_waiting) || retry)
           && !count < 128
         then (
           incr count;
           instructions
           := Release_observation_registration (value.obs_session, id) :: !instructions;
           Observing
             { value with
               obs_release_inflight = true
             ; obs_cleanup_waiting = false
             ; obs_cleanup_error = None
             })
         else Observing value)
      state.facts.observations
  in
  let next = ref { state with facts = { state.facts with observations } } in
  let pending =
    Slots.fold
      (fun _ (Entry slot) pending ->
         match slot.ticket.query with
         | Operation (Worker.Refresh handle) when slot.result = None ->
           Observation_ids.add (Worker.observation_id handle) () pending
         | _ -> pending)
      state.facts.entries
      Observation_ids.empty
  in
  let slots = ref (Slots.cardinal state.facts.entries) in
  Observation_ids.iter
    (fun _ (Observing value) ->
       match value.obs_handle with
       | Some handle
         when (value.obs_dirty || (retry && value.obs_retry))
              && (not value.obs_releasing)
              && value.obs_admitted
              && (not (Observation_ids.mem value.obs_initial.id pending))
              && !count < 128
              && !slots < 256 ->
         (match plan_refresh ~internal:true !next value.obs_session handle with
          | Ok (_, planned) ->
            incr count;
            incr slots;
            next := planned.next;
            instructions
            := List.rev_append
                 (List.filter
                    (function
                      | Publish _ -> false
                      | _ -> true)
                    planned.instructions)
                 !instructions
          | Error _ -> ())
       | _ -> ())
    observations;
  if
    !instructions = []
    && Observation_ids.equal
         equal_observation_entry
         !next.facts.observations
         state.facts.observations
  then transition
  else
    changed
      !next
      (List.filter
         (function
           | Publish _ -> false
           | _ -> true)
         transition.instructions
       @ List.rev !instructions
       @ if !count = 128 then [ Schedule_drain ] else [])
;;

let step state event =
  progress_observations
    ~retry:
      (match event with
       | Capacity_available -> true
       | _ -> false)
    (step_base state event)
;;

let plan_mutation
      state
      session
      (operation : Worker.mutation_progress Worker.request)
      intent
      target
  =
  let key = intent_key intent in
  let bytes = Intents.fold (fun key _ n -> n + String.length key) state.facts.intents 0 in
  let valid =
    match operation with
    | Worker.Confirm (_, receipt) -> receipt_agrees state.facts intent receipt
    | _ -> true
  in
  if not (current_target state.facts target)
  then Error Worker.Revoked_session
  else if not valid
  then Error (Worker.Protocol_mismatch "Confirmation replaced original commit point")
  else if
    state.next = Int64.max_int
    || ((not (Intents.mem key state.facts.intents))
        && (Intents.cardinal state.facts.intents >= 256
            || bytes + String.length key > 4194304
            (* Reserve a full bounded readback before accepting each distinct
               intent. Known commits must never be dropped for a later budget. *)
            || bytes
               + String.length key
               + ((Intents.cardinal state.facts.intents + 1)
                  * Worker.Protocol.maximum_response_bytes)
               > 16777216))
  then Error (Worker.Invalid_input "Durable intent coordination capacity exhausted")
  else (
    let serial = Int64.succ state.next in
    let ticket =
      { id = Worker.request_id (identity state.client serial)
      ; serial
      ; kind = Mutation
      ; query = Operation operation
      ; target
      }
    in
    let slot =
      { ticket
      ; dispatched = true
      ; admitted = None
      ; sample_epoch = None
      ; origin = None
      ; result = None
      ; early = None
      ; cancelled = false
      ; forgotten = false
      }
    in
    let intents =
      if Intents.mem key state.facts.intents
      then state.facts.intents
      else
        Intents.add
          key
          (match operation with
           | Worker.Mutate _ -> Worker.Outcome_unknown
           | Worker.Confirm (_, receipt) -> Worker.Committed_pending_presentation receipt
           | _ -> assert false)
          state.facts.intents
    in
    let facts =
      { state.facts with
        entries = Slots.add serial (Entry slot) state.facts.entries
      ; intents
      }
    in
    Ok
      ( ticket
      , changed { state with next = serial; facts } [ Send (ticket, session, operation) ]
      ))
;;

let plan_observation (state : t) session budget query =
  if
    state.next = Int64.max_int
    || Observation_ids.cardinal state.facts.observations >= 256
    || state.facts.retired_observation_count
       + Observation_ids.cardinal state.facts.observations
       >= 8192
  then Error (Worker.Invalid_input "Observation ownership capacity exhausted")
  else (
    let serial = Int64.succ state.next in
    let ticket =
      { id = Worker.request_id (identity state.client serial)
      ; serial
      ; kind = Observed (kind query)
      ; query = Operation (Worker.Observe (budget, query))
      ; target = Sealed (session, budget)
      }
    in
    let slot =
      { ticket
      ; dispatched = true
      ; admitted = None
      ; sample_epoch = None
      ; origin = Some (session, budget)
      ; result = None
      ; early = None
      ; cancelled = false
      ; forgotten = false
      }
    in
    let observation =
      { obs_initial = ticket
      ; obs_session = session
      ; obs_budget = budget
      ; obs_query = query
      ; obs_handle = None
      ; obs_latest = None
      ; obs_registered = false
      ; obs_admitted = false
      ; obs_releasing = false
      ; obs_release_inflight = false
      ; obs_cleanup_waiting = false
      ; obs_attempt = None
      ; obs_cleanup_error = None
      ; obs_error = None
      ; obs_epoch = None
      ; obs_dirty = false
      ; obs_retry = false
      }
    in
    let facts =
      { state.facts with
        entries = Slots.add serial (Entry slot) state.facts.entries
      ; observations =
          Observation_ids.add ticket.id (Observing observation) state.facts.observations
      }
    in
    Ok
      ( ticket
      , changed
          { state with next = serial; facts }
          [ Send (ticket, session, Worker.Observe (budget, query)) ] ))
;;

let plan_release state session handle =
  let id = Worker.observation_id handle in
  let acknowledged =
    Option.exists
      (Worker.equal_session session)
      (Observation_ids.find_opt id state.facts.retired_observations)
  in
  let owned =
    match find_observation state.facts id (Worker.observation_query handle) with
    | Some value ->
      observation_matches value handle
      && Option.exists
           (fun actual -> Worker.same_observation actual handle <> None)
           value.obs_handle
    | _ -> false
  in
  if
    (not (Worker.equal_session session (Worker.observation_session handle)))
    || not (acknowledged || owned)
  then Error Worker.Revoked_session
  else if state.next = Int64.max_int || Slots.cardinal state.facts.entries >= 512
  then Error (Worker.Invalid_input "Observation cleanup waiter capacity exhausted")
  else (
    let serial = Int64.succ state.next in
    let ticket =
      { id = Worker.request_id (identity state.client serial)
      ; serial
      ; kind = Unit
      ; query = Operation (Worker.Release handle)
      ; target = Cleanup session
      }
    in
    let slot =
      { ticket
      ; dispatched = false
      ; admitted = None
      ; sample_epoch = None
      ; origin = None
      ; result = (if acknowledged then Some (Worker.Answered (Ok ())) else None)
      ; early = None
      ; cancelled = false
      ; forgotten = false
      }
    in
    let facts = retire_observation state.facts session id in
    let facts = { facts with entries = Slots.add serial (Entry slot) facts.entries } in
    Ok
      ( ticket
      , progress_observations ~retry:true (changed { state with next = serial; facts } [])
      ))
;;

let request
  : type a.
    t
    -> Worker.session
    -> a Worker.request
    -> (a ticket * transition, Worker.error) result
  =
  fun state session operation ->
  match operation with
  | Worker.Release handle -> plan_release state session handle
  | _ ->
    Result.bind (validate_session state session) (fun () ->
      if Slots.cardinal state.facts.entries >= 256
      then Error (Worker.Invalid_input "Release completed query tickets before admission")
      else
        Result.bind (Worker.validate_request session operation) (fun () ->
          let planned : (a ticket * transition, Worker.error) result =
            match operation with
            | Worker.Observe (budget, query) ->
              plan_observation state session budget query
            | Worker.Refresh handle -> plan_refresh state session handle
            | Worker.Query (budget, query) ->
              if state.next = Int64.max_int
              then Error (Worker.Invalid_input "Request counter exhausted")
              else (
                let serial = Int64.succ state.next in
                let ticket =
                  { id = Worker.request_id (identity state.client serial)
                  ; serial
                  ; kind = kind query
                  ; query = Read query
                  ; target = Sealed (session, budget)
                  }
                in
                let slot =
                  { ticket
                  ; dispatched = true
                  ; admitted = None
                  ; sample_epoch = None
                  ; origin = Some (session, budget)
                  ; result = None
                  ; early = None
                  ; cancelled = false
                  ; forgotten = false
                  }
                in
                let facts =
                  { state.facts with
                    entries = Slots.add serial (Entry slot) state.facts.entries
                  }
                in
                Ok
                  ( ticket
                  , changed
                      { state with next = serial; facts }
                      [ Send (ticket, session, operation) ] ))
            | Worker.Mutate intent ->
              plan_mutation state session operation intent (Direct session)
            | Worker.Confirm (presentation, receipt) ->
              plan_mutation
                state
                session
                operation
                (Worker.receipt_intent receipt)
                (Presentation presentation)
            | _ ->
              Error
                (Worker.Unsupported_operation
                   "Operation needs backend durability/resource conformance")
          in
          planned))
;;

let plan_query state ~owner ~maximum_items ~maximum_bytes query =
  let target = Expected (owner, maximum_items, maximum_bytes) in
  if state.lifecycle <> Running
  then Error Worker.Revoked_session
  else if List.exists (affected_target target) state.fenced
  then Error Worker.Host_change_in_progress
  else if
    maximum_items <= 0
    || maximum_bytes <= 0
    || maximum_bytes > Worker.Protocol.maximum_response_bytes
    || owner.graph_generation < 0
    || owner.startup.account_generation < 0
  then Error (Worker.Invalid_input "Invalid queued read bounds or owner")
  else if Slots.cardinal state.facts.entries >= 256 || state.next = Int64.max_int
  then Error (Worker.Invalid_input "Release completed query tickets before admission")
  else (
    let serial = Int64.succ state.next in
    let ticket =
      { id = Worker.request_id (identity state.client serial)
      ; serial
      ; kind = kind query
      ; query = Read query
      ; target
      }
    in
    let slot =
      { ticket
      ; dispatched = false
      ; admitted = None
      ; sample_epoch = None
      ; origin = None
      ; result = None
      ; early = None
      ; cancelled = false
      ; forgotten = false
      }
    in
    let facts =
      { state.facts with entries = Slots.add serial (Entry slot) state.facts.entries }
    in
    Ok (ticket, dispatch_waiting ~publish:true { state with next = serial; facts } []))
;;

let prepare_host_change state change =
  if state.active_handoff <> None
  then Error Worker.Host_change_in_progress
  else if state.binding = None || state.lifecycle <> Running
  then Error Worker.Revoked_session
  else if List.length state.facts.handoffs >= 64 || state.next = Int64.max_int
  then Error (Worker.Invalid_input "Handoff history limit reached")
  else (
    let serial = Int64.succ state.next in
    let id = Worker.handoff_id (identity state.client serial) in
    let facts =
      { state.facts with
        handoffs = (id, Worker.Quiescing change) :: state.facts.handoffs
      }
    in
    let facts, cancels =
      cancel_entries (fun target -> affected_target target change) facts
    in
    Ok
      ( id
      , progress_observations
          ~retry:false
          (changed
             { state with
               next = serial
             ; facts
             ; active_handoff = Some id
             ; fenced = change :: state.fenced
             }
             (cancels @ [ Quiesce (id, change) ])) ))
;;

module Response_ownership = struct
  module Ranges = Map.Make (Int64)

  type t = int64 Ranges.t

  let empty = Ranges.empty

  let mem history id =
    let id = Id.Request_id.to_int64 id in
    match Ranges.find_last_opt (fun start -> start <= id) history with
    | Some (_, finish) -> id <= finish
    | None -> false
  ;;

  let add history request_id =
    if mem history request_id
    then history
    else (
      let id = Id.Request_id.to_int64 request_id in
      let start, history =
        match Ranges.find_last_opt (fun start -> start <= id) history with
        | Some (start, finish) when finish <> Int64.max_int && Int64.succ finish = id ->
          start, Ranges.remove start history
        | _ -> id, history
      in
      let finish, history =
        match Ranges.find_first_opt (fun next -> next >= id) history with
        | Some (next, finish) when id <> Int64.max_int && Int64.succ id = next ->
          finish, Ranges.remove next history
        | _ -> id, history
      in
      Ranges.add start finish history)
  ;;

  let spans = Ranges.cardinal
end
