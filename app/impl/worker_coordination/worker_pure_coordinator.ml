module Worker = Worker_api
module Data = Worker.Data
module Id = Journal_worker_ids.Worker
module Intents = Map.Make (String)
module Slots = Map.Make (Int64)
module Graphs = Map.Make (Worker.Uuid)
module Sessions=Set.Make(struct type t=Worker.session let compare=Worker.compare_session end)
module Asset_consumers=Map.Make(struct type t=Worker.asset_consumer let compare=Worker.compare_asset_consumer end)
type asset_creation = Awaiting_admission | Creating | Finished | Not_created
type cleanup_phase = Releasing_resource | Finalizing_resource
type asset_registration={consumer:Worker.asset_consumer;assets:Logseq_db_types.Asset_descriptor.t list;
  creation:asset_creation;active:bool;notices:(Worker.asset_notice * Id.push_sequence) list}

module Observation_ids = Map.Make (struct
    type t = Worker.request_id

    let compare = Worker.compare_request_id
  end)

type _ kind =
  | Change_ack : Worker.change_ack kind
  | Unit : unit kind
  | Observed : 'a kind -> 'a Worker.observed kind
  | Mutation : Worker.mutation_progress kind
  | Recovery : Worker.mutation_recovery kind
  | Import_inputs : Worker.import_input_recovery kind
  | Import_source : Worker.request_id option -> Worker.recovered_import_input option kind
  | Import : Worker.import_progress kind
  | Lease : Worker.file_lease option kind
  | Info : Worker.graph_info kind
  | Admission : Worker_pure_data.admission_inspection kind
  | Journal : Worker.page option kind
  | Journals : Worker_pure_data.journal_item Worker.slice kind
  | Page : Worker_pure_data.page_lookup kind
  | Block : Worker_pure_data.block_lookup kind
  | Summary : Worker.block_summary kind
  | Children : Worker.block Worker.slice kind
  | Members : Worker.children kind
  | Tree : Worker_pure_data.tree_member Worker.slice kind
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
  | Change_ack, Change_ack -> Some Refl
  | Unit, Unit -> Some Refl
  | Mutation, Mutation -> Some Refl
  | Recovery, Recovery -> Some Refl
  | Import_inputs, Import_inputs -> Some Refl
  | Import_source _, Import_source _ -> Some Refl
  | Import, Import -> Some Refl
  | Lease, Lease -> Some Refl
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
  ; attempt : int
  ; kind : 'a kind
  ; query : 'a planned
  ; target : query_target
  ; planned_intent_epoch : int64
  ; planned_source_epoch : int64
  ; acknowledgement : (Worker.presentation * Worker.receipt option) option
  }

type 'a slot =
  { ticket : 'a ticket
  ; dispatched : bool
  ; wait_for_capacity : bool
  ; admitted : Id.request_id option
  ; change_version : int64
  ; sample_epoch : Worker.observation_epoch option
  ; origin : (Worker.session * Worker.read_budget) option
  ; result : 'a Worker.reply option
  ; early : 'a Worker.reply option
  ; cancelled : bool
  ; forgotten : bool
  ; retired_by_ack : bool
  ; rebind_pending : bool
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
  ; obs_creator_finished : bool
  ; obs_returned : bool
  ; obs_release_done : bool
  ; obs_release_inflight : bool
  ; obs_cleanup_waiting : bool
  ; obs_attempt : Worker.request_id option
  ; obs_cleanup_error : Worker.error option
  ; obs_error : Worker.error option
  ; obs_epoch : Worker.observation_epoch option
  ; obs_dirty : bool
  ; obs_retry : bool
  ; obs_error_recovered : bool
  }

type observation_entry = Observing : 'a observation_state -> observation_entry

type import_registration={import_intent:Worker.asset_import_intent;source_owner:Worker.session;source_adopted:bool;
  progress:Worker.import_progress option;failed_attempt:(Worker.request_id * Worker.error) option}

type cleanup_resource=Demand_resource of Worker.asset_consumer | Lease_resource of Worker.file_lease

type asset_cleanup =
  { resource:cleanup_resource
  ; creation:asset_creation
  ; phase:cleanup_phase
  ; returned:bool
  ; attempt:Worker.request_id option
  ; waiters:int64 list
  ; wait_for_capacity:bool
  ; error:Worker.error option
  }


type change_application =
  { application_id : Worker.request_id
  ; application_batch : Worker.change_batch
  }

type consumer_state =
  { consumer_expanded : bool
  ; consumer_applied : bool
  }

let waiting_consumer = { consumer_expanded = false; consumer_applied = false }

type application_state =
  { token : change_application
  ; pending_consumers : consumer_state Graphs.t
  ; issued_consumers : unit Graphs.t
  ; issued_count : int
  ; failed_consumers : Worker.error Graphs.t
  }

type shutdown_state =
  | Active
  | Draining
  | Stopped
  | Shutdown_failed of Worker.error

type host_confirmation={confirm_receipt:Worker.handoff_receipt;confirm_attempt:Worker.request_id;
  confirm_mailbox:Id.request_id option;confirm_early:(Id.request_id * (bool,Worker.error)result)option;confirm_waiting:bool}

type view =
  { bootstrap_state : Worker.bootstrap_state
  ; current : Worker.projection option
  ; retired_host_sessions : Sessions.t
  ; entries : entry Slots.t
  ; handoffs : (Worker.handoff_id * Worker.handoff_state) list
  ; restartable_handoffs : Worker.handoff_id list
  ; shutdown : shutdown_state
  ; intents : Worker.mutation_progress Intents.t
  ; intent_epoch : int64
  ; import_input_epoch : int64
  ; applications : application_state Graphs.t
  ; change_notices : (Worker.changefeed_notice * Id.push_sequence) Graphs.t
  ; change_projections : string Graphs.t
  ; change_versions : int64 Graphs.t
  ; change_batches : (Worker.change_batch * Worker.read_budget) Graphs.t
  ; change_acks : Worker.change_ack Graphs.t
  ; observations : observation_entry Observation_ids.t
  ; asset_consumers : asset_registration Asset_consumers.t
  ; asset_cleanup : asset_cleanup Observation_ids.t
  ; file_leases : Worker.file_lease Observation_ids.t
  ; imports : import_registration Graphs.t
  ; import_history : Worker.import_source_proof Graphs.t
  ; released_leases : Worker.session Observation_ids.t
  ; session_assets : (Worker.asset_notice * Id.push_sequence) list Graphs.t
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
  ; host_plan : Worker.handoff_plan option
  ; host_legacy_pending : bool
  ; host_quiesce_sent : bool
  ; host_candidate : Worker.handoff_receipt option
  ; host_confirmation : host_confirmation option
  ; host_consume_waiting : bool
  ; host_consume_attempt : Worker.request_id option
  ; host_consume_admitted : Id.request_id option
  ; host_consume_early : (Id.request_id * (unit,Worker.error)result)option
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
  ; host_plan=None;host_candidate=None;host_confirmation=None;host_legacy_pending=false;host_quiesce_sent=false;host_consume_waiting=false;host_consume_attempt=None;host_consume_admitted=None;host_consume_early=None
  ; retired = Graphs.empty
  ; fenced = []
  ; facts =
      { bootstrap_state = Worker.Awaiting_baseline
      ; current = None
      ; retired_host_sessions=Sessions.empty
      ; entries = Slots.empty
      ; handoffs = [];restartable_handoffs=[]
      ; shutdown = Active
      ; intents = Intents.empty
      ; intent_epoch = 0L;import_input_epoch=0L
      ; applications = Graphs.empty
      ; change_notices = Graphs.empty
      ; change_projections = Graphs.empty
      ; change_versions = Graphs.empty
      ; change_batches = Graphs.empty
      ; change_acks = Graphs.empty
      ; observations = Observation_ids.empty
      ; asset_consumers = Asset_consumers.empty
      ; asset_cleanup = Observation_ids.empty
      ; file_leases=Observation_ids.empty
      ; imports=Graphs.empty
      ; import_history=Graphs.empty
      ; released_leases=Observation_ids.empty
      ; session_assets = Graphs.empty
      }
  }
;;

let current_session facts session =
  not(Sessions.mem session facts.retired_host_sessions) && match facts.bootstrap_state, facts.current with
  | Worker.Ready _, Some p ->
    List.exists
      (fun r -> r.Worker.phase = Worker.Open && Worker.equal_session r.session session)
      (Worker.residents p)
  | _ -> false
;;

let change_version facts session =
  Option.value
    (Graphs.find_opt (Worker.graph_id session) facts.change_versions)
    ~default:0L
;;

let view t = t.facts
let bootstrap v = v.bootstrap_state
let projection v = v.current
let changefeed_updates ~previous view =
  Graphs.fold
    (fun graph (notice, sequence) updates ->
       let unchanged =
         match Option.bind previous (fun view -> Graphs.find_opt graph view.change_notices) with
         | Some (old, seen) ->
           Worker.equal_session old.Worker.notice_session notice.Worker.notice_session
           && Id.Push_sequence.compare seen sequence = 0
         | None -> false
       in
       if unchanged then updates else Rrbvec.push_back updates notice)
    view.change_notices
    Rrbvec.empty
;;
let shutdown_state v = v.shutdown
let intent_key intent = Bytes.to_string (Worker.encode_durable_intent intent)
let intent_progress view intent = Intents.find_opt (intent_key intent) view.intents
let adopt_import_source facts proof =
  let id=Worker.import_source_proof_id proof in
  let imports=match Graphs.find_opt id facts.imports with
    |Some saved when Worker.import_source_proof_matches saved.import_intent proof->
      Graphs.add id{saved with source_adopted=true;failed_attempt=None}facts.imports
    |_->facts.imports in
  let import_history=if Graphs.mem id facts.import_history || Graphs.cardinal facts.import_history<8192
    then Graphs.add id proof facts.import_history else facts.import_history in
  {facts with imports;import_history}
;;
let import_progress facts intent =
  let key=Worker.asset_import_intent_id intent in
  let progress=Option.bind(Graphs.find_opt key facts.imports)(fun saved->
    if Worker.encode_asset_import_intent saved.import_intent=Worker.encode_asset_import_intent intent then saved.progress else None) in
  Option.map(function
    | Worker.Imported imported as progress->
      (match Worker.import_preview imported with
       | Some lease when Observation_ids.mem(Worker.file_lease_id lease)facts.asset_cleanup
           || not(Observation_ids.mem(Worker.file_lease_id lease)facts.file_leases)->
         Worker.Imported(Worker.without_import_preview imported)
       | _->progress)
    | progress->progress)progress

let import_source_unsettled facts id saved=not saved.source_adopted && match saved.progress with
  |Some Worker.Import_unknown->true
  |Some(Worker.Imported _ | Import_rejected _)->false
  |None->Slots.exists(fun _ (Entry slot)->slot.result=None && match slot.ticket.query with
    |Operation(Worker.Import intent)->Worker.Uuid.equal(Worker.asset_import_intent_id intent)id
    |_->false)facts.entries
let pending_import_source_intents facts=
  (* An admitted Import is initially Unknown too. Its original handler must
     exit before an absent Prepared proof is a stable read, including cancel. *)
  let creating=Slots.fold(fun _ (Entry slot) creating->match slot.result,slot.ticket.query with
    |None,Operation(Worker.Import intent)->Graphs.add(Worker.asset_import_intent_id intent)()creating
    |_->creating)facts.entries Graphs.empty in
  Graphs.fold(fun id saved inputs->
    if not(Graphs.mem id creating) && import_source_unsettled facts id saved
    then Rrbvec.push_back inputs saved.import_intent else inputs)facts.imports Rrbvec.empty
;;
let import_sources_pending facts ~owner =
  Graphs.exists(fun id saved->Option.fold ~none:true ~some:(Worker.matches_scope saved.source_owner) owner
    && import_source_unsettled facts id saved)facts.imports
let import_source_pending facts ~operation =
  Option.exists(import_source_unsettled facts operation)(Graphs.find_opt operation facts.imports)
;;
let import_source_proof facts intent =
  let id=Worker.asset_import_intent_id intent in
  let proof=match Graphs.find_opt id facts.imports with
    |Some{progress=Some(Worker.Imported imported);_}->Some(Worker.import_source_proof imported)
    |_->Graphs.find_opt id facts.import_history in
  Option.bind proof(fun proof->if Worker.import_source_proof_matches intent proof then Some proof else None)
;;


let import_source_proof_consumed proof recipients =
  not(Rrbvec.exists(fun facts->Graphs.exists(fun id saved->
    import_source_unsettled facts id saved && Worker.import_source_proof_matches saved.import_intent proof)
    facts.imports)recipients)

let completed_import_source_proofs facts =
  Graphs.fold(fun _ proof values->Rrbvec.push_back values proof)facts.import_history Rrbvec.empty
;;

let handoff v id =
  List.find_map
    (fun (actual, value) ->
       if Worker.equal_handoff_id actual id then Some value else None)
    v.handoffs
;;

let handoff_restartable view id=List.exists(Worker.equal_handoff_id id)view.restartable_handoffs

let asset_notices facts consumer =
  if not(current_session facts(Worker.asset_consumer_session consumer)) then [] else
  match Asset_consumers.find_opt consumer facts.asset_consumers with
  | Some entry when entry.active->List.map fst entry.notices
  | _->[]
let session_asset_notices facts session =
  if not(current_session facts session) then [] else
    Option.value(Graphs.find_opt(Worker.graph_id session)facts.session_assets)~default:[]
    |> List.map fst
    |> List.filter(fun notice->Worker.equal_session session(Worker.asset_notice_session notice))
let ticket_id ticket = ticket.id
let ticket_acknowledgement ticket = ticket.acknowledgement

let same_ticket : type a b. a ticket -> b ticket -> (a, b) Worker.equality option =
  fun a b ->
  match same_kind a.kind b.kind with
  | Some Worker.Refl
    when Worker.equal_request_id a.id b.id && a.target = b.target && a.query = b.query
         && a.planned_intent_epoch=b.planned_intent_epoch && a.acknowledgement=b.acknowledgement ->
    Some Refl
  | _ -> None
;;

(* Business handles stay stable; asynchronous envelopes belong to one send. *)
let same_attempt : type a b. a ticket -> b ticket -> (a,b) Worker.equality option =
  fun a b -> if a.attempt=b.attempt then same_ticket a b else None
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

let owns_change_batch facts batch =
  match
    Graphs.find_opt
      (Worker.graph_id (Worker.change_batch_session batch))
      facts.change_batches
  with
  | Some (actual, _) -> actual = batch
  | _ -> false
;;

let application_for_batch facts batch =
  match
    Graphs.find_opt
      (Worker.graph_id (Worker.change_batch_session batch))
      facts.applications
  with
  | Some application when application.token.application_batch = batch -> Some application
  | _ -> None
;;

let change_application_started facts batch = application_for_batch facts batch <> None

let change_application_ready facts batch =
  match application_for_batch facts batch with
  | Some application ->
    Graphs.is_empty application.pending_consumers
    && Graphs.is_empty application.failed_consumers
  | _ -> false
;;

let change_application_error facts batch =
  Option.bind (application_for_batch facts batch) (fun application ->
    Option.map snd (Graphs.choose_opt application.failed_consumers))
;;

let equal_observation_entry (Observing a) (Observing b) =
  match same_kind (kind a.obs_query) (kind b.obs_query) with
  | Some Worker.Refl -> a = b
  | None -> false
;;

let equal_entry (Entry a) (Entry b) =
  match same_ticket a.ticket b.ticket with
  | Some Worker.Refl ->
    a.ticket.attempt = b.ticket.attempt
    && a.rebind_pending = b.rebind_pending
    && a.wait_for_capacity = b.wait_for_capacity
    && a.dispatched = b.dispatched
    && a.admitted = b.admitted
    && a.change_version = b.change_version
    && a.sample_epoch = b.sample_epoch
    && a.origin = b.origin
    && a.result = b.result
    && a.early = b.early
    && a.cancelled = b.cancelled
    && a.forgotten = b.forgotten
    && a.retired_by_ack = b.retired_by_ack
  | None -> false
;;

let equal_view a b =
  a == b
  || (a.bootstrap_state = b.bootstrap_state
      && a.current = b.current
      && Sessions.equal a.retired_host_sessions b.retired_host_sessions
      && a.handoffs = b.handoffs && a.restartable_handoffs=b.restartable_handoffs
      && a.shutdown = b.shutdown
      && a.intents = b.intents
      && a.intent_epoch = b.intent_epoch && a.import_input_epoch=b.import_input_epoch
      && Asset_consumers.equal(=)a.asset_consumers b.asset_consumers
      && Observation_ids.equal(=)a.asset_cleanup b.asset_cleanup
      && Observation_ids.equal(=)a.file_leases b.file_leases
      && Graphs.equal(=)a.imports b.imports
      && Graphs.equal(=)a.import_history b.import_history
      && Observation_ids.equal Worker.equal_session a.released_leases b.released_leases
      && Graphs.equal(=)a.session_assets b.session_assets
      && Graphs.equal ( = ) a.applications b.applications
      && Graphs.equal ( = ) a.change_notices b.change_notices
      && Graphs.equal String.equal a.change_projections b.change_projections
      && Graphs.equal Int64.equal a.change_versions b.change_versions
      && Graphs.equal ( = ) a.change_batches b.change_batches
      && Graphs.equal ( = ) a.change_acks b.change_acks
      && Observation_ids.equal equal_observation_entry a.observations b.observations
      && Slots.equal equal_entry a.entries b.entries)
;;

type event =
  | Worker_bound of Worker.binding
  | Retry_bootstrap
  | Binding_invalidated of Worker.binding
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
  | Changefeed_notice of
      Worker.changefeed_notice
      * Journal_worker_ids.Worker.push_sequence
  | Change_application_retired of change_application
  | Change_consumer_expanded of
      change_application * Worker.Uuid.t * Worker.Uuid.t Rrbvec.t
  | Change_consumer_applied of
      change_application * Worker.Uuid.t * (unit, Worker.error) result
  | Change_consumer_retired of change_application * Worker.Uuid.t
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
  | Import_source_reconciled of Worker.import_source_proof
  | Import_source_proof_returned of Worker.import_source_proof
  | Asset_received of Worker.asset_notice * Id.push_sequence
  | Cancel : 'a ticket -> event
  | Forget : 'a ticket -> event
  | Release : 'a Worker.observation -> event
  | Observation_returned : 'a Worker.observation -> event
  | File_lease_returned of Worker.file_lease
  | Observation_finalize_completed of Worker.session * Worker.request_id * (unit,Worker.error)result
  | Observation_finalize_not_admitted of Worker.session * Worker.request_id * Worker.admission_error
  | Legacy_handoff_completed of Worker.handoff_id * (unit,Worker.error)result
  | Handoff_completed of Worker.handoff_id * Worker.handoff_state
  | Handoff_applied of Worker.handoff_id * Worker.request_id * Id.request_id * (unit,Worker.error)result
  | Handoff_apply_admitted of Worker.handoff_id * Worker.request_id * Id.request_id
  | Handoff_apply_rejected of Worker.handoff_id * Worker.request_id * Worker.error
  | Handoff_apply_not_admitted of Worker.handoff_id * Worker.request_id * Worker.admission_error
  | Handoff_confirm_admitted of Worker.handoff_id * Worker.request_id * Id.request_id
  | Handoff_confirm_not_admitted of Worker.handoff_id * Worker.request_id * Worker.admission_error
  | Handoff_confirmed of Worker.handoff_id * Worker.request_id * Id.request_id option * (bool,Worker.error)result
  | Drain

type instruction =
  | Bootstrap
  | Release_binding of Worker.binding
  | Release_observation_registration of Worker.session * Worker.request_id
  | Finalize_observation_registration of Worker.session * Worker.request_id
  | Finalize_asset_demand of unit ticket * Worker.session * Worker.asset_consumer
  | Bind_replacement
  | Send : 'a ticket * Worker.session * 'a Worker.request -> instruction
  | Cancel_request : 'a ticket -> instruction
  | Quiesce of Worker.handoff_plan
  | Consume_handoff of Worker.handoff_receipt * Worker.request_id
  | Confirm_handoff of Worker.handoff_receipt * Worker.request_id
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

let host_change_blocks state ~owner =
  Sessions.exists(fun session->Worker.matches_scope session owner)state.facts.retired_host_sessions
  || Option.exists(fun projection->List.exists(fun(resident:Worker.resident)->
       Worker.matches_scope resident.session owner && List.exists(affected resident.session)state.fenced)
       (Worker.residents projection))state.facts.current
;;

let validate_session ?owner state session =
  if Option.exists (fun owner -> not (Worker.matches_scope session owner)) owner
  then Error Worker.Revoked_session
  else if List.exists (affected session) state.fenced
  then Error Worker.Host_change_in_progress
  else if state.lifecycle <> Running || not (current_session state.facts session)
  then Error Worker.Revoked_session
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

let current_presentation ?owner facts presentation =
  current_target facts (Presentation presentation)
  && Option.fold ~none:true ~some:(Worker.presentation_matches_scope presentation) owner

let asset_round_current facts consumer round =
  match Asset_consumers.find_opt consumer facts.asset_consumers with
  |Some entry->entry.active && Worker.asset_consumer_round entry.consumer=Some round
  |None->false
;;

let revalidate_reply : type a. view -> a ticket -> a Worker.reply -> a Worker.reply =
  fun facts ticket reply ->
  if (match ticket.query with Operation(Worker.Replace_asset_demand(consumer,_,_))->
    not(asset_round_current facts consumer ticket.id)|_->false)
  then Worker.Answered(Error Worker.Revoked_session) else match ticket.target,reply with
  | Presentation presentation,Worker.Answered(Ok _)
    when not(current_presentation facts presentation)->Worker.Answered(Error Worker.Revoked_session)
  | _->reply
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
  Slots.exists (fun _ (Entry slot) -> slot.result = None
    && (slot.dispatched || not slot.rebind_pending)) state.facts.entries
;;

let settle state instructions =
  if not(Observation_ids.is_empty state.facts.asset_cleanup) then
    let error=Observation_ids.fold(fun _ cleanup found->match found with
      | Some _->found|None->cleanup.error)state.facts.asset_cleanup None in
    let facts=match state.lifecycle,error with
      | Stopping,Some error->{state.facts with shutdown=Shutdown_failed error}
      | Retrying,Some error->{state.facts with bootstrap_state=Worker.Bootstrap_failed error}
      | _->state.facts in
    changed {state with facts} instructions
  else if state.released && (not state.bootstrap_inflight) && not (outstanding state)
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

let validate_change_query
  : type a.
    view
    -> Worker.session
    -> Worker.read_budget
    -> a Worker.query
    -> (unit, Worker.error) result
  =
  fun facts session budget query ->
  match query with
  | Worker.Changes { generation; after } ->
    let invalid () =
      Error
        (Worker.Invalid_input
           "The Changes cursor or budget is outside its owned unapplied chain")
    in
    (match Graphs.find_opt (Worker.graph_id session) facts.change_batches with
     | Some (batch, original_budget)
       when Worker.equal_session session (Worker.change_batch_session batch) ->
       if
         generation = batch.generation
         && ((after = batch.from_exclusive && budget = original_budget)
             || after = Some batch.through)
       then Ok ()
       else invalid ()
     | _ ->
       (match after, Graphs.find_opt (Worker.graph_id session) facts.change_acks with
        | None, _ -> Ok ()
        | Some through, Some ack
          when Worker.equal_session session (Worker.change_ack_session ack)
               && generation = Worker.change_ack_generation ack
               && through = Worker.change_ack_through ack -> Ok ()
        | _ -> invalid ()))
  | _ -> Ok ()
;;

let active_change_reads facts =
  Slots.fold
    (fun _ (Entry slot) owners ->
       match slot.ticket.query, slot.origin with
       | Read (Worker.Changes _), Some (session, _)
         when slot.dispatched && slot.result = None && current_session facts session ->
         Graphs.add (Worker.graph_id session) session owners
       | _ -> owners)
    facts.entries
    Graphs.empty
;;

let change_read_available owners session =
  match Graphs.find_opt (Worker.graph_id session) owners with
  | Some owner -> not (Worker.equal_session owner session)
  | None -> true
;;

let change_query_ready
  : type a. view -> Worker.session -> Worker.read_budget -> a Worker.query -> bool
  =
  fun facts session budget query ->
  match query with
  | Worker.Changes query ->
    (match Graphs.find_opt (Worker.graph_id session) facts.change_batches with
     | Some (batch, original_budget)
       when Worker.equal_session session (Worker.change_batch_session batch) ->
       query.generation = batch.generation
       && query.after = batch.from_exclusive
       && budget = original_budget
       && change_application_error facts batch <> None
     | _ -> true)
  | _ -> true
;;

let change_ack_known facts batch =
  let session = Worker.change_batch_session batch in
  match Graphs.find_opt (Worker.graph_id session) facts.change_acks with
  | Some ack ->
    Worker.equal_session session (Worker.change_ack_session ack)
    && Worker.change_ack_generation ack = batch.Worker.generation
    && Worker.change_ack_through ack = batch.through
  | _ -> false
;;

let dispatch_waiting ?(publish = false) ?(retry_full = false) state instructions =
  let sends = ref [] in
  let active = ref (active_change_reads state.facts) in
  let ready : type a. Worker.session -> Worker.read_budget -> a Worker.query -> bool =
    fun session budget query ->
    change_query_ready state.facts session budget query
    &&
    match query with
    | Worker.Changes _ -> change_read_available !active session
    | _ -> true
  in
  let mark : type a. Worker.session -> a Worker.request -> unit =
    fun session operation ->
    match operation with
    | Worker.Query (_, Worker.Changes _) ->
      active := Graphs.add (Worker.graph_id session) session !active
    | _ -> ()
  in
  let entries =
    Slots.map
      (fun (Entry slot as entry) ->
         if
           state.lifecycle <> Running
           || slot.dispatched
           || slot.result <> None
           || (slot.early = Some (Worker.Not_admitted Worker.Full) && not retry_full)
         then entry
         else (
           let reject error =
             Entry { slot with result = Some (Worker.Answered (Error error)) }
           in
           if slot.retired_by_ack then
             reject(Worker.Stale_read "This intent attempt predates its durable acknowledgement")
           else if
             slot.wait_for_capacity
             && slot.early = Some (Worker.Not_admitted Worker.Full)
             && Option.exists
                  (fun (session, _) -> validate_session state session <> Ok ())
                  slot.origin
           then reject Worker.Revoked_session
           else (
             match slot.ticket.query with
             | Operation (Worker.Acknowledge_intent _ as operation) ->
               (match slot.ticket.target with
                | Presentation presentation when current_target state.facts (Presentation presentation) ->
                  let session=Worker.presentation_session presentation in
                  (match validate_session state session with
                   | Error error->reject error
                   | Ok ()->
                     sends:=Send(slot.ticket,session,operation)::!sends;
                     Entry{slot with dispatched = true;early=None})
                | _->reject Worker.Revoked_session)
             | Operation (Worker.Confirm_import_source _ as operation) ->
               (match slot.ticket.target with
                |Direct session->(match validate_session state session with
                  |Error error->reject error
                  |Ok()->sends:=Send(slot.ticket,session,operation)::!sends;
                    Entry{slot with dispatched = true;early=None})
                |_->reject Worker.Revoked_session)
             | Operation (Worker.Acknowledge_changes batch) ->
               let session = Worker.change_batch_session batch in
               (match validate_session state session with
                | Error error -> reject error
                | Ok () ->
                  if
                    (slot.early <> Some (Worker.Not_admitted Worker.Full) || retry_full)
                    && (change_ack_known state.facts batch
                        || change_application_ready state.facts batch)
                  then (
                    sends
                    := Send (slot.ticket, session, Worker.Acknowledge_changes batch)
                       :: !sends;
                    Entry
                      { slot with
                        dispatched = true
                      ; early = None
                      ; change_version = change_version state.facts session
                      })
                  else (
                    match
                      Graphs.find_opt (Worker.graph_id session) state.facts.change_batches
                    with
                    | Some (actual, _) when actual = batch -> entry
                    | _ ->
                      reject
                        (Worker.Resync_required "The unapplied change batch was retired")))
             | Read (Worker.Changes _ as query)
               when match slot.ticket.target with
                    | Sealed _ -> true
                    | _ -> false ->
               (match slot.ticket.target with
                | Sealed (session, budget) ->
                  (match validate_session state session with
                   | Error error -> reject error
                   | Ok () ->
                     (match validate_change_query state.facts session budget query with
                      | Error _ ->
                        reject
                          (Worker.Stale_read
                             "The queued change cursor was superseded by an applied page")
                      | Ok () when ready session budget query ->
                        mark session (Worker.Query (budget, query));
                        sends
                        := Send (slot.ticket, session, Worker.Query (budget, query))
                           :: !sends;
                        Entry
                          { slot with
                            dispatched = true
                          ; early = None
                          ; origin = Some (session, budget)
                          ; change_version = change_version state.facts session
                          }
                      | Ok () -> entry))
                | _ -> entry)
             | _ ->
               (match
                  slot.ticket.target, state.facts.bootstrap_state, state.facts.current
                with
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
                              (min maximum_items Worker_pure_data.maximum_page_size)
                            ~maximum_bytes:
                              (min
                                 maximum_bytes
                                 (Worker.capabilities session).limits
                                   .response_budget_bytes))
                         (fun budget ->
                            match slot.ticket.query with
                            | Read query ->
                              Result.bind
                                (validate_change_query state.facts session budget query)
                                (fun () ->
                                   Result.map
                                     (fun () -> Worker.Query (budget, query))
                                     (Worker.validate_request
                                        session
                                        (Worker.Query (budget, query))))
                            | Operation _ ->
                              Error
                                (Worker.Invalid_input "An effect cannot wait as a read"))
                     in
                     (match planned with
                      | Error error ->
                        (match slot.ticket.query with
                         | Read (Worker.Changes _) ->
                           reject
                             (Worker.Stale_read
                                "The queued change cursor was superseded by an applied \
                                 page")
                         | _ -> reject error)
                      | Ok (Worker.Query (budget, query))
                        when not (ready session budget query) -> entry
                      | Ok operation ->
                        mark session operation;
                        sends := Send (slot.ticket, session, operation) :: !sends;
                        let origin =
                          match operation with
                          | Worker.Query (budget, _) -> Some (session, budget)
                          | _ -> None
                        in
                        Entry
                          { slot with
                            dispatched = true
                          ; rebind_pending = false
                          ; early = None
                          ; origin
                          ; change_version = change_version state.facts session
                          })
                   | Some { phase = Worker.Opening; _ } -> entry
                   | Some { phase = Worker.Failed error; _ } -> reject error
                   | Some { phase = Worker.Closing; _ } -> reject Worker.Revoked_session)
                | _, (Worker.Bootstrap_failed error | Binding_revoked error), _ ->
                  reject error
                | _ -> entry))))
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

let plan_intent_lifecycle
  : type a. t -> Worker.session -> a Worker.request -> a kind -> query_target
    -> (Worker.presentation * Worker.receipt option) option
    -> (a ticket * transition,Worker.error) result
  = fun state session operation kind target acknowledgement ->
  if state.next=Int64.max_int then Error(Worker.Invalid_input "Request counter exhausted") else
  let serial=Int64.succ state.next in
  let ticket={id=Worker.request_id(identity state.client serial);serial;attempt=0;kind;query=Operation operation;target;
    planned_intent_epoch=state.facts.intent_epoch;planned_source_epoch=state.facts.import_input_epoch;acknowledgement} in
  let slot={ticket;wait_for_capacity=false;dispatched = true;admitted=None;change_version=0L;
    sample_epoch=None;origin=None;result=None;early=None;cancelled=false;forgotten=false;retired_by_ack=false;rebind_pending=false} in
  let facts={state.facts with entries=Slots.add serial(Entry slot)state.facts.entries} in
  Ok(ticket,changed{state with next=serial;facts}[Send(ticket,session,operation)])
;;


let non_publications instructions=List.filter(function Publish _->false|_->true)instructions

let complete_asset_waiters facts waiters (result:unit Worker.reply) =
  let entries=List.fold_left(fun entries serial->match Slots.find_opt serial entries with
    | Some(Entry slot) when slot.result=None->
      (match same_kind slot.ticket.kind Unit with
       | Some Worker.Refl->if slot.forgotten then Slots.remove serial entries else
         Slots.add serial(Entry{slot with result=Some result})entries
       | None->entries)
    | _->entries)facts.entries waiters in
  {facts with entries}
;;
let queue_asset_cleanup facts consumer ?waiter () =
  match Worker.asset_consumer_round consumer with
  | None->facts
  | Some round->
    let cleanup=match Observation_ids.find_opt round facts.asset_cleanup with
      | Some old->
        let retained=List.filter(fun serial->match Slots.find_opt serial facts.entries with
          | Some(Entry slot)->slot.result=None && not slot.forgotten && not slot.cancelled
          | None->false)old.waiters in
        {old with error=None;wait_for_capacity=false;
          waiters=(match waiter with None->retained|Some serial->serial::retained)}
      | None->
        let creation=match Asset_consumers.find_opt consumer facts.asset_consumers with
          |Some entry when Worker.asset_consumer_round entry.consumer=Some round->entry.creation
          |_->Finished in
        {resource=Demand_resource consumer;creation;phase=Releasing_resource;returned=true;attempt=None;waiters=Option.to_list waiter;wait_for_capacity=false;error=None} in
    {facts with asset_cleanup=Observation_ids.add round cleanup facts.asset_cleanup}
;;

let queue_file_cleanup facts lease ?waiter ?(returned=false) () =
  let key=Worker.file_lease_id lease in
  let cleanup=match Observation_ids.find_opt key facts.asset_cleanup with
    | Some previous->
      let waiters=List.filter(fun serial->match Slots.find_opt serial facts.entries with
        |Some(Entry slot)->slot.result=None && not slot.cancelled && not slot.forgotten|_->false)previous.waiters in
      {previous with returned=previous.returned || returned;error=None;wait_for_capacity=false;waiters=(match waiter with None->waiters|Some id->id::waiters)}
    |None->{resource=Lease_resource lease;creation=Finished;phase=Releasing_resource;returned;attempt=None;waiters=Option.to_list waiter;wait_for_capacity=false;error=None} in
  {facts with asset_cleanup=Observation_ids.add key cleanup facts.asset_cleanup}
;;
let resource_release = function
  | Demand_resource consumer->Worker.asset_consumer_session consumer,Worker.Release_asset_demand consumer
  | Lease_resource lease->Worker.file_lease_session lease,Worker.Release_file lease
;;

let asset_creator facts consumer round creation =
  let asset_consumers=match Asset_consumers.find_opt consumer facts.asset_consumers with
    |Some entry when Worker.asset_consumer_round entry.consumer=Some round->
      Asset_consumers.add consumer {entry with creation} facts.asset_consumers
    |_->facts.asset_consumers in
  let asset_cleanup=match Observation_ids.find_opt round facts.asset_cleanup with
    |Some cleanup->Observation_ids.add round {cleanup with creation} facts.asset_cleanup
    |None->facts.asset_cleanup in
  {facts with asset_consumers;asset_cleanup}
;;

let progress_asset_cleanup ?(capacity=false) transition =
  let next=ref transition.next and effects=ref [] in
  Observation_ids.iter(fun round cleanup->
    if cleanup.attempt=None && cleanup.creation=Not_created then (
      let facts=complete_asset_waiters !next.facts cleanup.waiters (Worker.Answered(Ok())) in
      let asset_consumers=match cleanup.resource with
        |Demand_resource consumer->(match Asset_consumers.find_opt consumer facts.asset_consumers with
          |Some entry when Worker.asset_consumer_round entry.consumer=Some round && not entry.active->Asset_consumers.remove consumer facts.asset_consumers
          |_->facts.asset_consumers)
        |Lease_resource _->facts.asset_consumers in
      next:={!next with facts={facts with asset_consumers;asset_cleanup=Observation_ids.remove round facts.asset_cleanup}})
    else if cleanup.creation=Finished && cleanup.attempt=None && cleanup.error=None && (capacity || not cleanup.wait_for_capacity) then
      let session,operation=resource_release cleanup.resource in
      match plan_intent_lifecycle !next session operation Unit(Cleanup session)None with
      | Error error->next:={!next with facts={!next.facts with asset_cleanup=Observation_ids.add round {cleanup with error=Some error} !next.facts.asset_cleanup}}
      | Ok(ticket,planned)->
        let entries=match Slots.find_opt ticket.serial planned.next.facts.entries with
          | Some(Entry slot)->Slots.add ticket.serial(Entry{slot with forgotten=true})planned.next.facts.entries
          | None->assert false in
        next:={planned.next with facts={planned.next.facts with entries;
          asset_cleanup=Observation_ids.add round {cleanup with attempt=Some ticket.id;wait_for_capacity=false}planned.next.facts.asset_cleanup}};
        let commands=match cleanup.phase,cleanup.resource with
          |Finalizing_resource,Demand_resource consumer->[Finalize_asset_demand(ticket,session,consumer)]
          |_->non_publications planned.instructions in
        effects:=List.rev_append commands !effects)
    transition.next.facts.asset_cleanup;
  if !next==transition.next then transition else
    changed !next(non_publications transition.instructions @ List.rev !effects)
;;

let restart_read (slot : 'a slot) =
  { slot with ticket={slot.ticket with attempt=slot.ticket.attempt+1};
    dispatched=false;admitted=None;early=None;origin=None;result=None;
    cancelled=false;rebind_pending=true }
;;

let retire ?(retry_reads=false) state lifecycle =
  let facts, instructions = cancel_entries (fun _ -> true) state.facts in
  (* A binding handover retires an execution, not an otherwise-current business
     read. Keep its logical owner; resample only after old physical settlement.
     Sealed/session operations and effectful requests never enter this queue. *)
  let facts=if not retry_reads then facts else
    let entries=Slots.fold(fun serial (Entry slot) entries->
      let eligible=not slot.forgotten && not slot.cancelled && slot.ticket.attempt<max_int
        && match slot.ticket.target,slot.ticket.query with
          |Expected _,Read(Worker.Changes _)->false
          |Expected _,Read _->true|_->false in
      if not eligible then entries else
      let slot=if not slot.dispatched || slot.result<>None then restart_read slot
        else {slot with cancelled=true;rebind_pending=true} in
      Slots.add serial(Entry slot)entries)state.facts.entries facts.entries in
    {facts with entries} in
  let facts=Asset_consumers.fold(fun _ (entry:asset_registration) facts->queue_asset_cleanup facts entry.consumer ())facts.asset_consumers facts in
  let facts=Observation_ids.fold(fun _ lease facts->queue_file_cleanup facts lease ())facts.file_leases facts in
  let facts =
    { facts with
      asset_consumers=Asset_consumers.map(fun (entry:asset_registration)->{entry with active=false;notices=[]})facts.asset_consumers
    ; current = None
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
      let facts =
        { facts with
          change_notices =
            Graphs.filter
              (fun _ (notice, _) -> current_session facts notice.Worker.notice_session)
              facts.change_notices
        ; change_projections =
            Graphs.filter
              (fun graph _ ->
                 match Graphs.find_opt graph facts.change_acks with
                 | Some ack -> current_session facts (Worker.change_ack_session ack)
                 | None -> false)
              facts.change_projections
        ; applications =
            Graphs.filter
              (fun _ application ->
                 current_session
                   facts
                   (Worker.change_batch_session application.token.application_batch))
              facts.applications
        ; change_versions =
            Graphs.filter
              (fun graph _ ->
                 Option.fold
                   ~none:false
                   ~some:(fun p ->
                     List.exists
                       (fun resident ->
                          resident.Worker.phase = Worker.Open
                          && Worker.Uuid.equal graph (Worker.graph_id resident.session))
                       (Worker.residents p))
                   facts.current)
              facts.change_versions
        ; change_batches =
            Graphs.filter
              (fun _ (batch, _) ->
                 current_session facts (Worker.change_batch_session batch))
              facts.change_batches
        ; session_assets=Graphs.filter(fun _ values->List.exists(fun(notice,_)->
            current_session facts(Worker.asset_notice_session notice))values)facts.session_assets
        ; change_acks =
            Graphs.filter
              (fun _ ack -> current_session facts (Worker.change_ack_session ack))
              facts.change_acks
        }
      in
      let facts, instructions =
        cancel_entries
          ~waiting:false
          (fun target -> not (current_target facts target))
          facts
      in
      let facts=Asset_consumers.fold(fun _ (entry:asset_registration) facts->
        if entry.active && not(current_session facts(Worker.asset_consumer_session entry.consumer))
        then queue_asset_cleanup facts entry.consumer () else facts)facts.asset_consumers facts in
      let facts=Observation_ids.fold(fun _ lease facts->
        if not(current_session facts(Worker.file_lease_session lease)) then queue_file_cleanup facts lease () else facts)
        facts.file_leases facts in
      let asset_consumers=Asset_consumers.map(fun (entry:asset_registration)->
        if not(current_session facts(Worker.asset_consumer_session entry.consumer))
        then {entry with active=false;notices=[]}else entry)facts.asset_consumers in
      dispatch_waiting ~publish:true { state with facts={facts with asset_consumers}; retired } instructions))
;;

let known_receipt facts key =
  match Intents.find_opt key facts.intents with
  | Some (Worker.Committed_pending_presentation receipt) -> Some receipt
  | Some (Worker.Confirmed confirmation) ->
    Some (Worker.confirmation_receipt confirmation)
  | _ -> None
;;

let receipt_agrees facts key receipt =
  key = intent_key (Worker.receipt_intent receipt)
  && Option.fold
       ~none:true
       ~some:(fun original ->
         Worker.receipt_revisions original = Worker.receipt_revisions receipt)
       (known_receipt facts key)
;;

let retain_submission_result intents ~key ~admitted (result : Worker.mutation_progress Worker.reply) =
  let previous = Intents.find_opt key intents in
  let progress : Worker.mutation_progress option =
    match result with
    | Worker.Answered (Ok progress) -> Some progress
    | Worker.Not_admitted _ when not admitted -> previous
    | _ ->
      (match previous with
       | Some
           (Worker.Committed_pending_presentation _ | Confirmed _ | Rejected _)
         -> previous
       | _ -> Some Worker.Outcome_unknown)
  in
  (match previous, progress with
   | ( Some (Worker.Committed_pending_presentation _ | Confirmed _)
     , Some (Worker.Outcome_unknown | Rejected _) ) -> intents
   | Some (Worker.Confirmed _), Some (Worker.Committed_pending_presentation _)
     -> intents
   | Some (Worker.Rejected _), _ -> intents
   | _, None -> intents
   | _, Some progress -> Intents.add key progress intents)
;;

let intent_capacity intents =
  let bytes=Intents.fold(fun key _ total->total+String.length key)intents 0 in
  Intents.cardinal intents<=256 && bytes<=4194304
  && bytes+(Intents.cardinal intents*Worker_pure_data.maximum_response_bytes)<=16777216
;;

let recovered_intents facts session (page:Worker.mutation_recovery) =
  let merged=Rrbvec.fold_left(fun result (item:Worker.recovered_mutation)->
    Result.bind result(fun intents->
      Result.bind(Worker.validate_request session(match item.intent with Worker.Append_intent intent->Worker.Append intent|Mutation_intent intent->Worker.Mutate intent))(fun()->
        let key=intent_key item.intent in
        let old=Intents.find_opt key intents in
        let valid=match old,item.progress with
          | _,Worker.Confirmed _ -> false
          | Some(Worker.Rejected _),Worker.Committed_pending_presentation _ -> false
          | Some(Worker.Committed_pending_presentation _|Confirmed _),Worker.Rejected _ -> false
          | _,Worker.Committed_pending_presentation receipt -> receipt_agrees facts key receipt
          | _->true in
        if not valid then Error(Worker.Protocol_mismatch "Recovered intent replaced settled evidence") else
        let progress=match old,item.progress with
          | Some((Worker.Rejected _|Committed_pending_presentation _|Confirmed _) as known),Worker.Outcome_unknown->known
          | Some(Worker.Confirmed _ as known),Worker.Committed_pending_presentation _->known
          | _,progress->progress in
        Ok(Intents.add key progress intents))))(Ok facts.intents)page.items in
  Result.bind merged(fun intents->if intent_capacity intents then Ok intents
    else Error(Worker.Invalid_input "Recovered intent coordination capacity exhausted"))
;;

let retire_intent_attempts entries intent =
  let key=intent_key intent in
  let matches actual=intent_key actual=key in
  Slots.map(fun (Entry slot as entry)->
    let same_intent=match slot.ticket.query with
      | Operation(Worker.Mutate actual)->matches(Worker.Mutation_intent actual)
      | Operation(Worker.Append actual)->matches(Worker.Append_intent actual)
      | Operation(Worker.Acknowledge_intent actual)->matches actual
      | Operation(Worker.Confirm(_,receipt))->matches(Worker.receipt_intent receipt)
      | _->false in
    if slot.result=None && same_intent then Entry{slot with retired_by_ack=true} else entry)entries
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
  |Operation(Worker.Replace_asset_demand(consumer,_,_)),_
    when not(asset_round_current facts consumer ticket.id)->Worker.Answered(Error Worker.Revoked_session)
  | Operation(Worker.Recover_import_inputs _),Worker.Answered(Ok _)
      when ticket.planned_source_epoch<>facts.import_input_epoch->
    Worker.Answered(Error(Worker.Stale_read "Source recovery predates a settled source acknowledgement"))
  | Operation(Worker.Confirm_import_source _),Worker.Answered(Ok _)
      when ticket.planned_source_epoch<>facts.import_input_epoch->
    Worker.Answered(Error(Worker.Stale_read "Source confirmation predates a settled source acknowledgement"))
  | Operation(Worker.Recover_mutations parameters),Worker.Answered(Ok page)->
    if ticket.planned_intent_epoch<>facts.intent_epoch
    then Worker.Answered(Error(Worker.Stale_read "Recovery predates a settled intent acknowledgement"))
    else (match ticket.target with
      | Direct session->
        let valid=Worker.validate_request session(Worker.Recover_mutations
          {parameters with after=page.next}) in
        (match Result.bind valid(fun()->recovered_intents facts session page) with
         | Ok _->result|Error error->Worker.Answered(Error error))
      | _->Worker.Answered(Error(Worker.Protocol_mismatch "Recovery has no execution owner")))
  | Read (Worker.Changes _), Worker.Answered _
    when match Slots.find_opt ticket.serial facts.entries with
         | Some (Entry { origin = Some (session, _); change_version = sent; _ }) ->
           sent <> change_version facts session
         | _ -> true ->
    Worker.Answered
      (Error
         (Worker.Stale_read "The Changes request predates the current acknowledged chain"))
  | Read (Worker.Changes query), Worker.Answered (Ok batch) ->
    let origin =
      match Slots.find_opt ticket.serial facts.entries with
      | Some (Entry slot) -> slot.origin
      | _ -> None
    in
    (match origin with
     | Some (session, _)
       when Worker.equal_session session (Worker.change_batch_session batch)
            && query.generation = batch.generation
            && query.after = batch.from_exclusive ->
       let graph = Worker.graph_id session in
       let expected_projection =
         match Graphs.find_opt graph facts.change_acks with
         | Some ack when Worker.change_ack_generation ack = batch.generation ->
           Graphs.find_opt graph facts.change_projections
         | _ -> None
       in
       let held_conflict =
         match Graphs.find_opt graph facts.change_batches with
         | Some (current, _)
           when Worker.equal_session session (Worker.change_batch_session current) ->
           current <> batch
         | _ -> false
       in
       let gap =
         match batch.windows, expected_projection with
         | first :: _, Some predecessor ->
           first.Worker_pure_data.predecessor <> predecessor
         | [], _ ->
           (match Graphs.find_opt graph facts.change_acks with
            | Some ack when Worker.change_ack_generation ack = batch.generation ->
              batch.through <> Worker.change_ack_through ack
            | _ -> false)
         | _ -> false
       in
       if held_conflict || gap
       then
         Worker.Answered
           (Error (Worker.Resync_required "Changefeed projection continuity was lost"))
       else result
     | _ ->
       Worker.Answered
         (Error
            (Worker.Protocol_mismatch
               "Changes batch owner/chain differs from its exact ticket")))
  | Operation (Worker.Acknowledge_changes batch), Worker.Answered _
    when (not (change_ack_known facts batch))
         &&
         match Slots.find_opt ticket.serial facts.entries with
         | Some (Entry slot) ->
           slot.change_version <> change_version facts (Worker.change_batch_session batch)
         | None -> true ->
    Worker.Answered
      (Error (Worker.Stale_read "The ACK belongs to a retired change application epoch"))
  | Operation (Worker.Acknowledge_changes batch), Worker.Answered (Ok ack) ->
    if
      Worker.equal_session
        (Worker.change_batch_session batch)
        (Worker.change_ack_session ack)
      && batch.generation = Worker.change_ack_generation ack
      && batch.through = Worker.change_ack_through ack
    then result
    else
      Worker.Answered
        (Error (Worker.Protocol_mismatch "Changes ACK differs from its delivered batch"))
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
    if receipt_agrees facts (intent_key(Worker.Mutation_intent intent)) receipt then result else mismatch ()
  | Operation (Worker.Mutate _), Worker.Answered (Ok (Worker.Confirmed _)) -> mismatch ()
  | Operation (Worker.Append intent), Worker.Answered (Ok (Worker.Committed_pending_presentation receipt)) ->
    if receipt_agrees facts (intent_key(Worker.Append_intent intent)) receipt then result else mismatch ()
  | Operation (Worker.Append _), Worker.Answered (Ok (Worker.Confirmed _)) -> mismatch ()
  | ( Operation (Worker.Confirm (presentation, receipt))
    , Worker.Answered (Ok (Worker.Confirmed confirmation)) ) ->
    if
      Worker.confirmation_presentation confirmation = presentation
      && Worker.receipt_revisions receipt
         = Worker.receipt_revisions (Worker.confirmation_receipt confirmation)
      && receipt_agrees
           facts
           (intent_key (Worker.receipt_intent receipt))
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

let failed_observation_sample owned error =
  let recover=not owned.obs_error_recovered && match error with
    |Worker.Service_failed _->true
    |Worker.Db_error error->Logseq_db_worker_contract.Error.code error=Logseq_db_worker_contract.Error.Storage_busy
    |_->false in
  {owned with obs_error=Some error;obs_dirty=owned.obs_dirty || recover;
    obs_error_recovered=owned.obs_error_recovered || recover}
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
              (Observing (failed_observation_sample owned error))
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
                 (Observing (failed_observation_sample owned error))
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

let retire_change_proof state session =
  if not (current_session state.facts session)
  then state
  else (
    let facts = state.facts
    and graph = Worker.graph_id session in
    { state with
      facts =
        { facts with
          change_batches = Graphs.remove graph facts.change_batches
        ; applications = Graphs.remove graph facts.applications
        ; change_acks = Graphs.remove graph facts.change_acks
        ; change_projections = Graphs.remove graph facts.change_projections
        ; change_versions =
            Graphs.add
              graph
              (Int64.succ (change_version facts session))
              facts.change_versions
        }
    })
;;

let retain_change_result : type a. t -> a ticket -> a Worker.reply -> t =
  fun state ticket result ->
  let facts = state.facts in
  match ticket.query, result with
  | Read (Worker.Changes _), Worker.Answered (Ok batch)
    when current_session facts (Worker.change_batch_session batch) ->
    (match Slots.find_opt ticket.serial facts.entries with
     | Some (Entry { origin = Some (_, budget); _ }) ->
       { state with
         facts =
           { facts with
             change_batches =
               Graphs.add
                 (Worker.graph_id (Worker.change_batch_session batch))
                 (batch, budget)
                 facts.change_batches
           }
       }
     | _ -> state)
  | Operation (Worker.Acknowledge_changes batch), Worker.Answered (Ok ack)
    when current_session facts (Worker.change_ack_session ack) ->
    let graph = Worker.graph_id (Worker.change_ack_session ack) in
    let owned =
      match Graphs.find_opt graph facts.change_batches with
      | Some (current, _) -> current = batch
      | _ -> false
    in
    let repeated =
      match Graphs.find_opt graph facts.change_acks with
      | Some previous ->
        Worker.equal_session
          (Worker.change_ack_session previous)
          (Worker.change_ack_session ack)
        && Worker.change_ack_generation previous = Worker.change_ack_generation ack
        && Worker.change_ack_through previous = Worker.change_ack_through ack
      | _ -> false
    in
    if not (owned || repeated)
    then state
    else (
      let change_batches =
        if owned then Graphs.remove graph facts.change_batches else facts.change_batches
      in
      let version = change_version facts (Worker.change_ack_session ack) in
      let change_versions =
        if owned
        then Graphs.add graph (Int64.succ version) facts.change_versions
        else facts.change_versions
      in
      let applications =
        match Graphs.find_opt graph facts.applications with
        | Some application when application.token.application_batch = batch ->
          Graphs.remove graph facts.applications
        | _ -> facts.applications
      in
      let change_projections =
        match List.rev batch.windows with
        | last :: _ ->
          Graphs.add
            graph
            last.Worker_pure_data.successor
            facts.change_projections
        | [] ->
          (match Graphs.find_opt graph facts.change_acks with
           | Some previous
             when Worker.change_ack_generation previous = Worker.change_ack_generation ack
             -> facts.change_projections
           | _ -> Graphs.remove graph facts.change_projections)
      in
      { state with
        facts =
          { facts with
            change_batches
          ; change_versions
          ; change_projections
          ; applications
          ; change_acks = Graphs.add graph ack facts.change_acks
          }
      })
  | Read (Worker.Changes _), Worker.Answered (Error (Worker.Resync_required _)) ->
    (match Slots.find_opt ticket.serial facts.entries with
     | Some (Entry { origin = Some (session, _); _ }) -> retire_change_proof state session
     | _ -> state)
  | ( Operation (Worker.Acknowledge_changes batch)
    , Worker.Answered (Error (Worker.Resync_required _)) ) ->
    retire_change_proof state (Worker.change_batch_session batch)
  | ( Operation (Worker.Acknowledge_changes batch)
    , (Worker.Answered (Error _) | Worker.Interrupted _ | Worker.Not_admitted _) ) ->
    let graph = Worker.graph_id (Worker.change_batch_session batch) in
    (match
       Graphs.find_opt graph facts.change_batches, application_for_batch facts batch
     with
     | Some (actual, _), Some application
       when actual = batch && current_session facts (Worker.change_batch_session batch) ->
       let error =
         match result with
         | Worker.Answered (Error error) -> error
         | Worker.Interrupted _ ->
           Worker.Service_failed "The change acknowledgement was interrupted"
         | _ -> Worker.Service_failed "The change acknowledgement was not admitted"
       in
       let application =
         { application with
           failed_consumers =
             Graphs.add
               (match Graphs.choose_opt application.issued_consumers with
                | Some (id, _) -> id
                | None -> Worker.graph_id (Worker.change_batch_session batch))
               error
               application.failed_consumers
         }
       in
       { state with
         facts =
           { facts with applications = Graphs.add graph application facts.applications }
       }
     | _ -> state)
  | _ -> state
;;

let asset_cleanup_error = function
  | Worker.Answered(Error error)->error
  | Worker.Not_admitted _->Worker.Service_failed "Asset cleanup could not be admitted. Retry the same consumer."
  | Worker.Interrupted _->Worker.Service_failed "Asset cleanup was interrupted. Retry the same consumer."
  | Worker.Answered(Ok())->assert false

let finish_resource_release state (ticket:unit ticket) (result:unit Worker.reply) key =
    (match Option.bind key(fun round->
      Option.map(fun cleanup->round,cleanup)(Observation_ids.find_opt round state.facts.asset_cleanup)) with
     | Some(round,cleanup) when cleanup.attempt=Some ticket.id->
       (match result with
        | Worker.Not_admitted Worker.Full->{state with facts={state.facts with asset_cleanup=
            Observation_ids.add round {cleanup with attempt=None;wait_for_capacity=true}state.facts.asset_cleanup}}
        | _->
          let success=result=Worker.Answered(Ok()) in
          if success && cleanup.phase=Releasing_resource && (match cleanup.resource with Demand_resource _->true|_->false)
          then {state with facts={state.facts with asset_cleanup=Observation_ids.add round
            {cleanup with phase=Finalizing_resource;attempt=None;wait_for_capacity=false;error=None}state.facts.asset_cleanup}}
          else

          let error=if success then None else Some(asset_cleanup_error result) in
          let facts=complete_asset_waiters state.facts cleanup.waiters
            (match error with None->Worker.Answered(Ok())|Some error->Worker.Answered(Error error)) in
          let asset_consumers=match cleanup.resource with
            |Demand_resource consumer->(match Asset_consumers.find_opt consumer facts.asset_consumers with
              | Some entry when success && not entry.active && Worker.asset_consumer_round entry.consumer=Some round->Asset_consumers.remove consumer facts.asset_consumers
              | _->facts.asset_consumers)
            |Lease_resource _->facts.asset_consumers in
          let file_leases=if success then Observation_ids.remove round facts.file_leases else facts.file_leases in
          let released_leases=match success,cleanup.resource with true,Lease_resource lease when not cleanup.returned->
            Observation_ids.add round(Worker.file_lease_session lease)facts.released_leases|_->facts.released_leases in
          let asset_cleanup=if success then Observation_ids.remove round facts.asset_cleanup else
            Observation_ids.add round {cleanup with attempt=None;waiters=[];wait_for_capacity=false;error}facts.asset_cleanup in
          {state with facts={facts with asset_consumers;asset_cleanup;file_leases;released_leases}})
     | _->state)

;;
let retain_asset_command_result : type a. t -> a ticket -> a Worker.reply -> t =
  fun state ticket result->match ticket.query with
  | Operation(Worker.Release_asset_demand consumer)->finish_resource_release state ticket result(Worker.asset_consumer_round consumer)
  | Operation(Worker.Release_file lease)->finish_resource_release state ticket result(Some(Worker.file_lease_id lease))
  | _->state
;;

let asset_file_current facts file =
  let consumer=Worker.asset_file_consumer file in
  match Asset_consumers.find_opt consumer facts.asset_consumers with
  |Some entry when entry.active && Worker.asset_consumer_round consumer=Worker.asset_consumer_round entry.consumer->
    List.exists(fun(notice,_)->Worker.ready_asset_file notice=Some file)entry.notices
  |_->false
;;

let import_key intent=Worker.asset_import_intent_id intent
let adopt_file_result : type a. t -> a slot -> a Worker.reply -> t =
  fun state slot result->
  let orphan=slot.cancelled || slot.forgotten || state.lifecycle<>Running || not(current_target state.facts slot.ticket.target)
    || (match slot.ticket.query with Operation(Worker.Acquire_asset_file file)->not(asset_file_current state.facts file)|_->false) in
  let adopt facts lease=
    let facts={facts with file_leases=Observation_ids.add(Worker.file_lease_id lease)lease facts.file_leases} in
    if orphan then queue_file_cleanup facts lease ~returned:true () else facts in
  let facts=match slot.ticket.query,result with
    |Operation(Worker.Import intent),_->
      let key=import_key intent in
      let previous=Option.bind(Graphs.find_opt key state.facts.imports)(fun saved->saved.progress) in
      let progress=match result with
        |Worker.Answered(Ok progress)->Some progress
        |Worker.Not_admitted _ when slot.admitted=None->previous
        |_->(match previous with Some(Worker.Imported _ | Import_rejected _)->previous|_->Some Worker.Import_unknown) in
      let facts=match progress with Some(Worker.Imported imported)->
        Option.fold ~none:state.facts ~some:(adopt state.facts)(Worker.import_preview imported)|_->state.facts in
      let source_owner=match Graphs.find_opt key facts.imports with Some saved->saved.source_owner
        |None->(match slot.ticket.target with Direct session->session|_->assert false) in
      let failed_attempt=match result,progress with
        |Worker.Answered(Error(Worker.Service_failed _ as error)),Some Worker.Import_unknown
          when slot.admitted<>None && not slot.cancelled->Some(slot.ticket.id,error)
        |_->None in
      let imports=Graphs.add key {import_intent=intent;source_owner;progress;failed_attempt;source_adopted=(match progress with Some(Worker.Imported _)->true
          |_->Option.exists(fun saved->saved.source_adopted)(Graphs.find_opt key facts.imports))}facts.imports in
      {facts with imports}
    |Operation(Worker.Confirm_import_source intent),Worker.Answered(Ok recovered)->
      (match Option.bind recovered(fun recovered->recovered.Worker.prepared) with
       |Some proof->adopt_import_source state.facts(Worker.prepared_import_adoption proof)
       |None->
         let key=import_key intent in
         (match slot.ticket.kind,Graphs.find_opt key state.facts.imports with
          |Import_source(Some sampled),Some({failed_attempt=Some(attempt,error);_}as saved)
            when Worker.equal_request_id sampled attempt
              && not saved.source_adopted
              && Worker.encode_asset_import_intent intent=Worker.encode_asset_import_intent saved.import_intent
              && not(Slots.exists(fun _ (Entry active)->active.result=None && match active.ticket.query with
                |Operation(Worker.Import pending)->Worker.Uuid.equal(import_key pending)key|_->false)state.facts.entries)->
            {state.facts with imports=Graphs.add key{saved with progress=Some(Worker.Import_rejected error);failed_attempt=None}state.facts.imports}
          |_->state.facts))
    |Operation(Worker.Recover_import_inputs _),Worker.Answered(Ok page)->
      Rrbvec.fold_left(fun facts (recovered:Worker.recovered_import_input)->
        Option.fold ~none:facts ~some:(fun proof->adopt_import_source facts(Worker.prepared_import_adoption proof))recovered.prepared)
        state.facts page.inputs
    |Operation(Worker.Acquire_asset_file _),Worker.Answered(Ok(Some lease))->adopt state.facts lease
    |Operation(Worker.Acquire_imported_file _),Worker.Answered(Ok(Some lease))->adopt state.facts lease
    |_->state.facts in
  {state with facts}
;;

let finish : type a. t -> a ticket -> a Worker.reply -> bool -> transition =
  fun state ticket result require_admission ->
  match Slots.find_opt ticket.serial state.facts.entries with
  | Some (Entry slot) ->
    (match same_attempt ticket slot.ticket with
     | Some Worker.Refl
       when slot.result = None
            && (slot.early = None || not require_admission)
            && (require_admission || slot.admitted = None)
            && slot.dispatched ->
       let result = if slot.retired_by_ack
         then Worker.Answered(Error(Worker.Stale_read "This intent attempt predates its durable acknowledgement"))
         else checked_result state.facts ticket result in
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
         let facts=match ticket.query with
           |Operation(Worker.Observe _)->(match Observation_ids.find_opt ticket.id state.facts.observations with
             |Some(Observing value)->Observation_ids.add ticket.id
               (Observing{value with obs_creator_finished=true;
                 obs_returned=value.obs_returned || slot.cancelled || value.obs_handle=None;
                 obs_releasing=value.obs_releasing || slot.cancelled || value.obs_handle=None})state.facts.observations
             |None->state.facts.observations) |> fun observations->{state.facts with observations}
           |Operation(Worker.Replace_asset_demand(consumer,_,_))->
             asset_creator state.facts consumer ticket.id (if slot.admitted=None then Not_created else Finished)
           |_->state.facts in
         let state={state with facts} in
         let state=adopt_file_result state slot result in
         let state = retain_change_result state ticket result in
         let state = retain_asset_command_result state ticket result in
         let intents : Worker.mutation_progress Intents.t =
           if slot.retired_by_ack then state.facts.intents else match ticket.query with
           | Operation (Worker.Mutate intent) ->
             retain_submission_result state.facts.intents ~key:(intent_key(Worker.Mutation_intent intent))
               ~admitted:(slot.admitted<>None) result
           | Operation (Worker.Append intent) ->
             retain_submission_result state.facts.intents
               ~key:(intent_key(Worker.Append_intent intent))
               ~admitted:(slot.admitted<>None) result
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
           | Operation(Worker.Recover_mutations _)->
             (match result,ticket.target with
              | Worker.Answered(Ok page),Direct session
                when state.lifecycle=Running && current_target state.facts ticket.target ->
                (match recovered_intents state.facts session page with Ok intents->intents|Error _->state.facts.intents)
              | _->state.facts.intents)
           | Operation(Worker.Acknowledge_intent intent)->
             (match result with
              | Worker.Answered(Ok()) when state.lifecycle=Running && current_target state.facts ticket.target->
                Intents.remove(intent_key intent)state.facts.intents
              | _->state.facts.intents)
           | _ -> state.facts.intents
         in
         let intent_epoch=match ticket.query,result with
           | Operation(Worker.Acknowledge_intent intent),Worker.Answered(Ok())
             when Intents.mem(intent_key intent)state.facts.intents && not(Intents.mem(intent_key intent)intents)->
             Int64.succ state.facts.intent_epoch
           | _->state.facts.intent_epoch in
         let import_input_epoch=match ticket.query,result with
           |Operation(Worker.Acknowledge_import_source _),Worker.Answered(Ok()) when state.facts.import_input_epoch<Int64.max_int->
             Int64.succ state.facts.import_input_epoch
           |_->state.facts.import_input_epoch in
         let result =
           let cancelled_observe =
             match ticket.query with
             | Operation (Worker.Observe _ | Worker.Import _ | Worker.Acquire_asset_file _ | Worker.Acquire_imported_file _) -> slot.cancelled
             | _ -> false
           in
           if cancelled_observe
           then Worker.Interrupted Worker.Cancelled
           else if (match ticket.query with Operation(Worker.Acquire_asset_file file)->not(asset_file_current state.facts file)|_->false)
           then Worker.Answered(Error Worker.Revoked_session)
           else if (state.lifecycle = Running || match ticket.target with Cleanup _->true|_->false)
                   && current_target state.facts ticket.target
           then result
           else Worker.Answered (Error Worker.Revoked_session)
         in
         let previous_entries=match ticket.query with
           | Operation(Worker.Acknowledge_intent intent) when intent_epoch<>state.facts.intent_epoch->
             retire_intent_attempts state.facts.entries intent
           | _->state.facts.entries in
         let entries =
           if slot.forgotten
           then Slots.remove ticket.serial previous_entries
           else
             Slots.add
               ticket.serial
               (Entry (if slot.rebind_pending && state.lifecycle=Retrying
                  then restart_read slot else {slot with result=Some result;early=None}))
               previous_entries
         in
         settle { state with facts = { state.facts with entries; intents; intent_epoch;import_input_epoch } } [])
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
       ->
       let facts=retire_observation facts value.obs_session ticket.id in
       {facts with observations=Observation_ids.add ticket.id (Observing{value with
         obs_releasing=true;obs_returned=true;obs_cleanup_waiting=false;obs_cleanup_error=None})facts.observations}
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
      | _ -> .
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
         && not value.obs_release_done
         && Worker.equal_session session value.obs_session ->
    (match result with
     | Ok () ->
       let facts = {state.facts with observations=Observation_ids.add id
         (Observing{value with obs_release_done=true;obs_release_inflight=false;
           obs_registered=false;obs_latest=None;obs_cleanup_error=None;obs_cleanup_waiting=false})state.facts.observations}
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
             (Entry { slot with cancelled = true; forgotten; rebind_pending=false })
             state.facts.entries
       in
       changed { state with facts = { state.facts with entries } } instructions
     | None -> unchanged state)
  | None -> unchanged state
;;

let change_consumer state token operation =
  let batch = token.application_batch in
  let graph = Worker.graph_id (Worker.change_batch_session batch) in
  match Graphs.find_opt graph state.facts.applications with
  | Some application
    when Worker.equal_request_id application.token.application_id token.application_id
         && application.token.application_batch = token.application_batch
         && validate_session state (Worker.change_batch_session batch) = Ok () ->
    let next = operation application in
    let facts =
      { state.facts with applications = Graphs.add graph next state.facts.applications }
    in
    dispatch_waiting ~publish:true { state with facts } []
  | _ -> unchanged state
;;

type asset_fact_key = Asset_fact of Worker.Uuid.t | Demand_fact | Capacity_fact | Upload_fact of Worker.Uuid.t
module Asset_facts = Map.Make(struct type t=asset_fact_key let compare=Stdlib.compare end)
let asset_fact_key notice=match Worker.asset_notice_data notice with
  | Logseq_db_worker_lui.Logseq_db_worker_lui_service.Asset_availability{asset;_}->Asset_fact asset
  | Asset_demand_accepted _|Asset_backpressure _->Demand_fact
  | Asset_capacity_available->Capacity_fact
  | Upload_status{operation;_}->Upload_fact operation
let asset_updates ~previous facts =
  if Option.exists(fun previous->previous.asset_consumers == facts.asset_consumers
    && previous.session_assets == facts.session_assets) previous then Rrbvec.empty else
  let changed previous values updates =
    if previous == values then updates else
    let seen = List.fold_left(fun seen (notice,sequence)->
      Asset_facts.add (asset_fact_key notice) (notice,sequence) seen) Asset_facts.empty previous in
    List.fold_left(fun updates ((notice,sequence) as value)->
      if not(current_session facts (Worker.asset_notice_session notice)) then updates else
      let unchanged=match Asset_facts.find_opt (asset_fact_key notice) seen with
        |Some(old,seen)->Worker.equal_session (Worker.asset_notice_session old) (Worker.asset_notice_session notice)
          && Id.Push_sequence.compare seen sequence >= 0
        |None->false in
      if unchanged then updates else Rrbvec.push_back updates value) updates values
  in
  let updates = Asset_consumers.fold (fun consumer entry updates ->
    if not entry.active then updates else
    let previous = match Option.bind previous (fun view -> Asset_consumers.find_opt consumer view.asset_consumers) with
      | Some old when old.active && Worker.asset_consumer_round old.consumer = Worker.asset_consumer_round entry.consumer -> old.notices
      | _ -> [] in
    changed previous entry.notices updates) facts.asset_consumers Rrbvec.empty in
  let updates = Graphs.fold (fun graph values updates ->
    let previous = Option.bind previous (fun view -> Graphs.find_opt graph view.session_assets)
      |> Option.value ~default:[] in
    changed previous values updates) facts.session_assets updates in
  Rrbvec.sort (fun (_, a) (_, b) -> Id.Push_sequence.compare a b) updates
  |> Rrbvec.map fst
;;

let retain_asset_notice state notice sequence =
  let session=Worker.asset_notice_session notice in
  if validate_session state session<>Ok() then unchanged state else
  let replace values=
    let key=asset_fact_key notice in
    let previous=List.find_opt(fun(old,_)->asset_fact_key old=key)values in
    if Option.exists(fun(_,seen)->Id.Push_sequence.compare sequence seen<=0)previous then None
    else Some((notice,sequence)::List.filter(fun(old,_)->asset_fact_key old<>key)values) in
  match Worker.asset_notice_consumer notice with
  | Some consumer->
    (match Asset_consumers.find_opt consumer state.facts.asset_consumers with
     | Some entry when entry.active && Worker.asset_consumer_round consumer=Worker.asset_consumer_round entry.consumer->
       let owned=match Worker.asset_notice_data notice with
         | Logseq_db_worker_lui.Logseq_db_worker_lui_service.Asset_availability{asset;descriptor;_}->
           List.exists(fun expected->expected.Logseq_db_types.Asset_descriptor.uuid=asset
             && expected.source=descriptor.source && expected.current_checksum=descriptor.current_checksum)entry.assets
         | _->true in
       if not owned then unchanged state else
       (match replace entry.notices with None->unchanged state|Some notices->
       changed {state with facts={state.facts with asset_consumers=Asset_consumers.add consumer {entry with notices}state.facts.asset_consumers}}[])
     | _->unchanged state)
  | None->
    let graph=Worker.graph_id session in
    let previous=Option.value(Graphs.find_opt graph state.facts.session_assets)~default:[]
      |> List.filter(fun(old,_)->Worker.equal_session session(Worker.asset_notice_session old)) in
    (match replace previous with None->unchanged state|Some values->
      changed {state with facts={state.facts with session_assets=Graphs.add graph(List.take 256 values)state.facts.session_assets}}[])
;;

let matching_host_attempt state id attempt =
  Option.exists(Worker.equal_handoff_id id)state.active_handoff
  && Option.exists(fun actual->Worker.compare_request_id actual attempt=0)state.host_consume_attempt
;;
let finish_host_terminal state id result =
  match handoff state.facts id,state.host_plan with
  |Some(Worker.Applying_host_change receipt),Some plan when Worker.valid_handoff_receipt plan receipt->
    let outcome=match result with Ok()->Worker.Host_change_applied receipt
      |Error error->Worker.Handoff_failed(Worker.handoff_change receipt,error) in
    let next={state with host_consume_waiting=false;host_consume_attempt=None;host_consume_admitted=None;host_consume_early=None;
      facts={state.facts with handoffs=(id,outcome)::List.filter(fun(old,_)->not(Worker.equal_handoff_id old id))state.facts.handoffs}} in
    let next=match result with Error _->next|Ok()->{next with active_handoff=None;host_plan=None;host_candidate=None;
      fenced=List.filter((<>) (Worker.handoff_change receipt))state.fenced} in
    changed next []
  |_->unchanged state
;;
let account_host receipt=match Worker.handoff_change receipt with
  |Worker.Account_will_change|Connection_will_stop->true|_->false
;;
let plan_host_confirmation (state:t) receipt =
  if state.next=Int64.max_int then finish_host_terminal state (Worker.handoff_receipt_id receipt)
    (Error(Worker.Invalid_input "Host readback attempt counter exhausted")) else
  let serial=Int64.succ state.next in
  let attempt=Worker.request_id(identity state.client serial) in
  changed{state with next=serial;host_candidate=Some receipt;
    host_consume_attempt=None;host_consume_admitted=None;host_consume_early=None;host_consume_waiting=false;
    host_confirmation=Some{confirm_receipt=receipt;confirm_attempt=attempt;confirm_mailbox=None;confirm_early=None;confirm_waiting=false}}
    [Confirm_handoff(receipt,attempt)]
;;
let finish_host_action state id result =
  match result,handoff state.facts id with
  |Error _,Some(Worker.Applying_host_change receipt) when account_host receipt && state.host_consume_admitted<>None->
    plan_host_confirmation state receipt
  |_->
    let state=match result,handoff state.facts id with
      |Error _,Some(Worker.Applying_host_change receipt)when account_host receipt->
        {state with facts={state.facts with restartable_handoffs=id::state.facts.restartable_handoffs}}
      |_->state in
    finish_host_terminal state id result
;;
let finish_host_confirmation state id result =
  match state.host_confirmation with None->unchanged state|Some confirmation->
  let state={state with host_confirmation=None} in
  match result with
  |Ok true->finish_host_terminal state id(Ok())
  |Ok false->finish_host_terminal {state with facts={state.facts with restartable_handoffs=id::state.facts.restartable_handoffs}}
      id(Error(Worker.Service_failed "The original host permission was not consumed; release its binding before a new round"))
  |Error error->finish_host_terminal{state with host_candidate=Some confirmation.confirm_receipt}id(Error error)
;;
let matching_confirmation state id attempt=match state.host_confirmation with
  |Some confirmation when Option.exists(Worker.equal_handoff_id id)state.active_handoff
    && Worker.compare_request_id confirmation.confirm_attempt attempt=0->Some confirmation|_->None
;;
let plan_host_action_attempt (state:t) receipt =
  if state.next=Int64.max_int then Error(Worker.Invalid_input "Host action attempt counter exhausted")else
  let serial=Int64.succ state.next in
  let attempt=Worker.request_id(identity state.client serial) in
  Ok({state with next=serial;host_consume_attempt=Some attempt;host_consume_admitted=None;
    host_consume_early=None;host_consume_waiting=false},Consume_handoff(receipt,attempt))
;;

let step_base state event =
  match event with
  | Import_source_proof_returned proof ->
    let id=Worker.import_source_proof_id proof in
    (match Graphs.find_opt id state.facts.import_history with
     |Some held when held=proof->
       changed{state with facts={state.facts with import_history=Graphs.remove id state.facts.import_history}}[]
     |_->unchanged state)
  | Import_source_reconciled proof ->
    let id=Worker.import_source_proof_id proof in
    (match Graphs.find_opt id state.facts.imports with
     |Some saved when not saved.source_adopted && Worker.import_source_proof_matches saved.import_intent proof->
       let imports=Graphs.add id {saved with source_adopted=true;failed_attempt=None}state.facts.imports in
       changed{state with facts={state.facts with imports}}[]
     |_->unchanged state)
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
      ; host_plan=None;host_candidate=None;host_confirmation=None;host_legacy_pending=false;host_quiesce_sent=false;host_consume_waiting=false;host_consume_attempt=None;host_consume_admitted=None;host_consume_early=None
      ; retired = Graphs.empty
      ; fenced = []
      ; facts =
          { state.facts with
            current = None
          ; retired_host_sessions=Sessions.empty
          ; handoffs=[];restartable_handoffs=[]
          ; bootstrap_state = Worker.Awaiting_baseline
          ; shutdown = Active
          ; change_batches = Graphs.empty
          ; change_acks = Graphs.empty
          ; change_versions = Graphs.empty
          ; change_projections = Graphs.empty
          ; applications = Graphs.empty
          ; released_leases=(if state.lifecycle=Rebinding then Observation_ids.empty else state.facts.released_leases)
          ; import_history=(if state.lifecycle=Rebinding then Graphs.empty else state.facts.import_history)

          }
      }
      [ Bootstrap ]
  | Worker_bound _ -> unchanged state
  | Binding_invalidated binding when is_binding state binding && state.lifecycle = Running
    -> retire ~retry_reads:true state Retrying
  | Binding_invalidated _ -> unchanged state
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
  | Shutdown_requested when state.lifecycle=Stopping ->
    let facts={state.facts with shutdown=Draining;
      asset_cleanup=Observation_ids.map(fun cleanup->{cleanup with error=None;wait_for_capacity=false})state.facts.asset_cleanup} in
    (match state.binding with
     | Some binding when not state.release_pending && not state.released->
       changed {state with facts;release_pending=true}[Release_binding binding]
     | _->settle {state with facts}[])
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
       let facts = { state.facts with observations = Observation_ids.empty } in
       let facts =
         Observation_ids.fold
           (fun id (Observing value) facts ->
              complete_release_waiters facts value.obs_session id)
           state.facts.observations
           facts
       in
       (* Unregister's checked ACK covers every demand allocated by this
          binding. Independent release responses can still be in the mailbox;
          they retain their ticket fence but cannot revive these obligations. *)
       let facts=Observation_ids.fold(fun _ cleanup facts->match cleanup.resource with
         |Demand_resource _->complete_asset_waiters facts cleanup.waiters(Worker.Answered(Ok()))
         |Lease_resource _->facts)facts.asset_cleanup facts in
       let asset_cleanup=Observation_ids.filter(fun _ cleanup->match cleanup.resource with Lease_resource _->true|_->false)facts.asset_cleanup in
       let facts={facts with asset_cleanup;
         asset_consumers=Asset_consumers.empty;session_assets=Graphs.empty;
         shutdown=(if state.lifecycle=Stopping then Draining else facts.shutdown)} in
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
             ; bootstrap_state =
                 (if state.lifecycle=Retrying then Worker.Bootstrap_failed error
                  else state.facts.bootstrap_state)
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
     | _, Running -> dispatch_waiting ~retry_full:(event = Capacity_available) state []
     | _ -> unchanged state)
  | Admitted (ticket, id) ->
    (match Slots.find_opt ticket.serial state.facts.entries with
     | Some (Entry slot) ->
       (match same_attempt ticket slot.ticket with
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
          let imports=match ticket.query with
            |Operation(Worker.Import intent)->
              let key=import_key intent in
              let progress=match Graphs.find_opt key state.facts.imports with
                |Some{progress=Some progress;_}->progress|_->Worker.Import_unknown in
              let source_owner=match Graphs.find_opt key state.facts.imports with Some saved->saved.source_owner
                |None->(match slot.ticket.target with Direct session->session|_->assert false) in
              Graphs.add key{import_intent=intent;source_owner;progress=Some progress;
                failed_attempt=None;
                source_adopted=Option.exists(fun saved->saved.source_adopted)(Graphs.find_opt key state.facts.imports)}state.facts.imports
            |_->state.facts.imports in
          let facts={state.facts with observations;imports} in
          let facts=match ticket.query with
            |Operation(Worker.Replace_asset_demand(consumer,_,_))->asset_creator facts consumer ticket.id Creating
            |_->facts in
          let state = { state with facts } in
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
  | Admission_refused (ticket, Worker.Full) ->
    (match Slots.find_opt ticket.serial state.facts.entries with
     | Some (Entry slot) ->
       (match same_attempt ticket slot.ticket with
        | Some Worker.Refl
          when (slot.wait_for_capacity
                ||
                match slot.ticket.query with
                | Operation (Worker.Acknowledge_changes _ | Worker.Acknowledge_intent _ | Worker.Confirm_import_source _) -> true
                | _ -> false)
               && slot.dispatched
               && slot.admitted = None
               && slot.result = None
               && not slot.cancelled ->
          changed
            { state with
              facts =
                { state.facts with
                  entries =
                    Slots.add
                      ticket.serial
                      (Entry
                         { slot with
                           dispatched = false
                         ; early = Some (Worker.Not_admitted Worker.Full)
                         })
                      state.facts.entries
                }
            }
            []
        | _ -> finish state ticket (Worker.Not_admitted Worker.Full) false)
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
  |Legacy_handoff_completed(id,result) when Option.exists(Worker.equal_handoff_id id)state.active_handoff
      && state.host_legacy_pending && not state.host_quiesce_sent->
    (match result,handoff state.facts id with
     |Ok(),Some(Worker.Quiescing _)->changed{state with host_legacy_pending=false}[]
     |Error error,Some(Worker.Quiescing change)->changed{state with active_handoff=None;host_plan=None;host_candidate=None;host_confirmation=None;host_legacy_pending=false;
        facts={state.facts with handoffs=(id,Worker.Handoff_failed(change,error))::
          List.filter(fun(old,_)->not(Worker.equal_handoff_id old id))state.facts.handoffs}}[]
     |_->unchanged state)
  | Handoff_completed (id, outcome)
    when Option.fold ~none:false ~some:(Worker.equal_handoff_id id)state.active_handoff && state.host_quiesce_sent->
    (match state.host_plan,outcome with
     |Some plan,Worker.Safe_to_proceed receipt when Worker.valid_handoff_receipt plan receipt->
       changed{state with host_candidate=Some receipt}[]
     |_,Worker.Handoff_failed(change,error)->
       (match handoff state.facts id with
        |Some(Worker.Quiescing expected)when expected=change->
          changed{state with active_handoff=None;host_plan=None;host_candidate=None;
            facts={state.facts with handoffs=(id,Worker.Handoff_failed(change,error))::
              List.filter(fun(old,_)->not(Worker.equal_handoff_id old id))state.facts.handoffs}}[]
        |_->unchanged state)
     |_->unchanged state)
  |Handoff_apply_not_admitted(id,attempt,Worker.Full)
     when matching_host_attempt state id attempt && state.host_consume_admitted=None->
    (match handoff state.facts id with Some(Worker.Applying_host_change _)->
      changed{state with host_consume_waiting=true;host_consume_early=None}[]|_->unchanged state)
  |Handoff_apply_not_admitted(id,attempt,_)when matching_host_attempt state id attempt && state.host_consume_admitted=None->
    finish_host_action state id(Error(Worker.Service_failed "Worker unavailable before host action admission"))
  |Handoff_apply_rejected(id,attempt,error)when matching_host_attempt state id attempt && state.host_consume_admitted=None->
    finish_host_action state id(Error error)
  |Handoff_apply_admitted(id,attempt,mailbox)when matching_host_attempt state id attempt
     && state.host_consume_admitted=None && not state.host_consume_waiting->
    let next={state with host_consume_admitted=Some mailbox;host_consume_early=None} in
    (match state.host_consume_early with Some(actual,result)when Id.Request_id.equal mailbox actual->finish_host_action next id result
     |_->unchanged next)
  |Handoff_applied(id,attempt,mailbox,result)when matching_host_attempt state id attempt && not state.host_consume_waiting->
    (match state.host_consume_admitted with
     |Some actual when Id.Request_id.equal actual mailbox->finish_host_action state id result
     |None when state.host_consume_early=None->unchanged{state with host_consume_early=Some(mailbox,result)}
     |_->unchanged state)
  |Handoff_confirm_admitted(id,attempt,mailbox)->
    (match matching_confirmation state id attempt with
     |Some confirmation when confirmation.confirm_mailbox=None && not confirmation.confirm_waiting->
       let next={state with host_confirmation=Some{confirmation with confirm_mailbox=Some mailbox;confirm_early=None}} in
       (match confirmation.confirm_early with Some(actual,result)when Id.Request_id.equal actual mailbox->finish_host_confirmation next id result
        |_->unchanged next)
     |_->unchanged state)
  |Handoff_confirm_not_admitted(id,attempt,Worker.Full)->
    (match matching_confirmation state id attempt with Some confirmation when confirmation.confirm_mailbox=None->
      changed{state with host_confirmation=Some{confirmation with confirm_waiting=true;confirm_early=None}}[]|_->unchanged state)
  |Handoff_confirm_not_admitted(id,attempt,_)->
    (match matching_confirmation state id attempt with Some{confirm_mailbox=None;_}->
      finish_host_confirmation state id(Error(Worker.Service_failed "Original host consumption could not be read; outcome remains unknown"))
     |_->unchanged state)
  |Handoff_confirmed(id,attempt,mailbox,result)->
    (match matching_confirmation state id attempt,mailbox with
     |Some{confirm_mailbox=None;confirm_waiting=false;_},None when Result.is_error result->finish_host_confirmation state id result
     |Some{confirm_mailbox=Some actual;confirm_waiting=false;_},Some mailbox when Id.Request_id.equal actual mailbox->finish_host_confirmation state id result
     |Some({confirm_mailbox=None;confirm_waiting=false;confirm_early=None;_}as confirmation),Some mailbox->
       unchanged{state with host_confirmation=Some{confirmation with confirm_early=Some(mailbox,result)}}
     |_->unchanged state)
  | Changefeed_notice (notice, sequence) ->
    let session = notice.Worker.notice_session in
    let graph = Worker.graph_id session in
    let fresh =
      match Graphs.find_opt graph state.facts.change_notices with
      | Some (previous, seen) when Worker.equal_session previous.Worker.notice_session session ->
        Id.Push_sequence.compare sequence seen > 0
      | _ -> true
    in
    if (not (current_session state.facts session)) || not fresh
    then unchanged state
    else (
      let state =
        { state with
          facts =
            { state.facts with
              change_notices =
                Graphs.add graph (notice, sequence) state.facts.change_notices
            }
        }
      in
      let state =
        match notice.notice with
        | Data.Resync_required _ -> retire_change_proof state session
        | Data.Changes_available _ -> state
      in
      dispatch_waiting ~publish:true state [])
  | Change_application_retired token ->
    change_consumer state token (fun application ->
      { application with
        pending_consumers = Graphs.empty
      ; failed_consumers = Graphs.empty
      })
  | Change_consumer_expanded (token, parent, children) ->
    change_consumer state token (fun application ->
      match Graphs.find_opt parent application.pending_consumers with
      | Some parent_state when not parent_state.consumer_expanded ->
        let application =
          Rrbvec.fold_left
            (fun application child ->
               if Graphs.mem child application.issued_consumers
               then application
               else if application.issued_count >= 8192
               then
                 { application with
                   failed_consumers =
                     Graphs.add
                       parent
                       (Worker.Resync_required
                          "Change application consumer bound exceeded")
                       application.failed_consumers
                 }
               else
                 { application with
                   pending_consumers =
                     Graphs.add child waiting_consumer application.pending_consumers
                 ; issued_consumers = Graphs.add child () application.issued_consumers
                 ; issued_count = application.issued_count + 1
                 })
            application
            children
        in
        let pending_consumers =
          if
            parent_state.consumer_applied
            && not (Graphs.mem parent application.failed_consumers)
          then Graphs.remove parent application.pending_consumers
          else
            Graphs.add
              parent
              { parent_state with consumer_expanded = true }
              application.pending_consumers
        in
        { application with pending_consumers }
      | _ -> application)
  | Change_consumer_applied (token, consumer, result) ->
    change_consumer state token (fun application ->
      match Graphs.find_opt consumer application.pending_consumers with
      | None -> application
      | Some status ->
        (match result with
         | Ok () when not (Graphs.mem consumer application.failed_consumers) ->
           let pending_consumers =
             if status.consumer_expanded
             then Graphs.remove consumer application.pending_consumers
             else
               Graphs.add
                 consumer
                 { status with consumer_applied = true }
                 application.pending_consumers
           in
           { application with pending_consumers }
         | Ok () -> application
         | Error error ->
           { application with
             failed_consumers = Graphs.add consumer error application.failed_consumers
           }))
  | Change_consumer_retired (token, consumer) ->
    change_consumer state token (fun application ->
      { application with
        pending_consumers = Graphs.remove consumer application.pending_consumers
      ; failed_consumers = Graphs.remove consumer application.failed_consumers
      })
  | Observation_registered (ticket, handle, epoch) ->
    retain_registration state ticket handle epoch
  | Observation_release_completed (session, id, result) ->
    release_observation_result state session id result
  | Observation_release_not_admitted (session, id, admission) ->
    (match Observation_ids.find_opt id state.facts.observations with
     | Some (Observing value)
       when Worker.equal_session session value.obs_session && value.obs_release_inflight && not value.obs_release_done
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
  | Observation_returned handle ->
    (match find_observation state.facts (Worker.observation_id handle) (Worker.observation_query handle) with
     |Some owned when observation_matches owned handle->
       let facts=retire_observation state.facts owned.obs_session owned.obs_initial.id in
       let observations=Observation_ids.add owned.obs_initial.id (Observing{owned with
         obs_releasing=true;obs_returned=true;obs_cleanup_waiting=false;obs_cleanup_error=None})facts.observations in
       changed {state with facts={facts with observations}} []
     |_->unchanged state)
  | File_lease_returned lease ->
    let id=Worker.file_lease_id lease in
    let cleanup=Observation_ids.find_opt id state.facts.asset_cleanup in
    let asset_cleanup=match cleanup with
      |Some({resource=Lease_resource actual;_} as value)
        when Worker.equal_session (Worker.file_lease_session actual) (Worker.file_lease_session lease)->
          Observation_ids.add id {value with returned=true}state.facts.asset_cleanup
      |_->state.facts.asset_cleanup in
    let released_leases=match Observation_ids.find_opt id state.facts.released_leases with
      |Some session when Worker.equal_session session(Worker.file_lease_session lease)->Observation_ids.remove id state.facts.released_leases
      |_->state.facts.released_leases in
    changed {state with facts={state.facts with asset_cleanup;released_leases}} []
  | Observation_finalize_completed(session,id,result)->
    (match Observation_ids.find_opt id state.facts.observations with
     |Some(Observing value) when value.obs_release_done && value.obs_returned
       && value.obs_release_inflight && Worker.equal_session session value.obs_session->
       let observations=match result with
         |Ok()->Observation_ids.remove id state.facts.observations
         |Error error->Observation_ids.add id (Observing{value with obs_release_inflight=false;obs_cleanup_error=Some error})state.facts.observations in
       changed {state with facts={state.facts with observations}} []
     |_->unchanged state)
  | Observation_finalize_not_admitted(session,id,admission)->
    (match Observation_ids.find_opt id state.facts.observations with
     |Some(Observing value) when value.obs_release_done && value.obs_release_inflight
       && Worker.equal_session session value.obs_session->
       let error=if admission=Worker.Full then None else Some(Worker.Service_failed "Observation finalization not admitted") in
       let observations=Observation_ids.add id (Observing{value with obs_release_inflight=false;
         obs_cleanup_waiting=admission=Worker.Full;obs_cleanup_error=error})state.facts.observations in
       changed {state with facts={state.facts with observations}} []
     |_->unchanged state)
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
       let value = { value with obs_epoch = Some notice.epoch; obs_dirty = true; obs_error_recovered=false } in
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
           Observing { value with obs_dirty = not value.obs_releasing;obs_error_recovered=false })
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
  | Asset_received(notice,sequence)->retain_asset_notice state notice sequence
  | Legacy_handoff_completed _ | Handoff_completed _ | Handoff_applied _ | Handoff_apply_admitted _ | Handoff_apply_rejected _ | Handoff_apply_not_admitted _ -> unchanged state
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
        ; attempt = 0
        ; kind = Observed (kind owned.obs_query)
        ; planned_intent_epoch = state.facts.intent_epoch
        ; planned_source_epoch = state.facts.import_input_epoch
        ; acknowledgement = None
        ; query = Operation (Worker.Refresh handle)
        ; target = Sealed (session, owned.obs_budget)
        }
      in
      let slot =
        { ticket
        ; wait_for_capacity = false
        ; dispatched = true
        ; admitted = None
        ; change_version = 0L
        ; sample_epoch = None
        ; origin = Some (session, owned.obs_budget)
        ; result = None
        ; early = None
        ; cancelled = false
        ; forgotten = internal
        ; retired_by_ack = false;rebind_pending=false
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
    Observation_ids.filter_map
      (fun id (Observing value) ->
         let releasing =
           value.obs_releasing || validate_session state value.obs_session <> Ok ()
         in
         let value = { value with obs_releasing = releasing } in
         if releasing && value.obs_creator_finished && not value.obs_admitted
         then None
         else if
           releasing
           && value.obs_creator_finished
           && (not value.obs_release_done || value.obs_returned)
           && state.lifecycle = Running
           && (not value.obs_release_inflight)
           && value.obs_cleanup_error = None
           && ((not value.obs_cleanup_waiting) || retry)
           && !count < 128
         then (
           incr count;
           instructions
           := (if value.obs_release_done then Finalize_observation_registration(value.obs_session,id)
               else Release_observation_registration(value.obs_session,id)) :: !instructions;
           Some(Observing
             { value with
               obs_release_inflight = true
             ; obs_cleanup_waiting = false
             ; obs_cleanup_error = None
             }))
         else Some(Observing value))
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

let retire_completed_imports transition =
  let facts=transition.next.facts in
  let imports,import_history=Graphs.fold(fun id saved (active,history)->
    let live_ticket=Slots.exists(fun _ (Entry slot)->match slot.ticket.query with
      |Operation(Worker.Import intent)->Worker.Uuid.equal(Worker.asset_import_intent_id intent)id
      |_->false)facts.entries in
    let leased=match saved.progress with
      |Some(Worker.Imported imported)->Option.exists(fun lease->Observation_ids.mem(Worker.file_lease_id lease)facts.file_leases)
          (Worker.import_preview imported)
      |_->true in
    match saved.progress with
    |None|Some(Worker.Import_rejected _) when not live_ticket->Graphs.remove id active,history
    |Some(Worker.Imported imported) when not live_ticket && not leased->
      Graphs.remove id active,Graphs.add id(Worker.import_source_proof imported)history
    |_->active,history)facts.imports(facts.imports,facts.import_history) in
  if imports==facts.imports then transition else
  changed{transition.next with facts={facts with imports;import_history}}(non_publications transition.instructions)
;;

let host_sessions state change =
  let add session values=if affected session change then Sessions.add session values else values in
  let add_projection projection values=List.fold_left(fun values(resident:Worker.resident)->
    add resident.session values)values(Worker.residents projection) in
  let values=Option.fold ~none:Sessions.empty ~some:(fun projection->add_projection projection Sessions.empty)state.facts.current in
  let values=Slots.fold(fun _ (Entry slot) values->
    let session=match slot.ticket.target with Cleanup session|Direct session|Sealed(session,_)->Some session
      |Presentation value->Some(Worker.presentation_session value)|Expected _->Option.map fst slot.origin in
    Option.fold ~none:values ~some:(fun session->add session values)session)state.facts.entries values in
  let values=Observation_ids.fold(fun _ (Observing value) values->add value.obs_session values)state.facts.observations values in
  let values=Asset_consumers.fold(fun _ entry values->add(Worker.asset_consumer_session entry.consumer)values)state.facts.asset_consumers values in
  let values=Observation_ids.fold(fun _ lease values->add(Worker.file_lease_session lease)values)state.facts.file_leases values in
  let values=Observation_ids.fold(fun _ cleanup values->add(fst(resource_release cleanup.resource))values)state.facts.asset_cleanup values in
  let values=Graphs.fold(fun _ saved values->add saved.source_owner values)state.facts.imports values in
  Rrbvec.of_seq(Sessions.to_seq values)
;;
let terminal_bootstrap_error facts = match facts.bootstrap_state with
  |Worker.Bootstrap_failed error|Binding_revoked error->Some error
  |Awaiting_baseline|Bootstrap_not_ready _|Ready _->None
;;

let progress_host_handoff ?(capacity=false) transition =
  let state=transition.next in
  match state.active_handoff with
  |None->transition
  |Some id->
    let fail change error=changed{state with active_handoff=None;host_plan=None;host_candidate=None;host_consume_waiting=false;
      host_consume_attempt=None;host_consume_admitted=None;host_consume_early=None;
      facts={state.facts with handoffs=(id,Worker.Handoff_failed(change,error))::
        List.filter(fun(old,_)->not(Worker.equal_handoff_id old id))state.facts.handoffs}}(non_publications transition.instructions) in
    match state.host_confirmation with
    |Some confirmation when capacity && confirmation.confirm_waiting->
      let retry=plan_host_confirmation state confirmation.confirm_receipt in
      {retry with instructions=non_publications transition.instructions @ retry.instructions}
    |Some _->transition
    |None->
    match handoff state.facts id,state.host_plan,state.host_candidate with
    |Some(Worker.Quiescing change),_,_ when Option.is_some(terminal_bootstrap_error state.facts)->
      fail change (Option.get(terminal_bootstrap_error state.facts))
    |Some(Worker.Quiescing change),_,_ when state.lifecycle<>Running->fail change Worker.Revoked_session
    |Some(Worker.Safe_to_proceed receipt),_,_ when state.lifecycle<>Running->fail(Worker.handoff_change receipt)Worker.Revoked_session
    |Some(Worker.Quiescing change),Some plan,_
      when Option.exists(fun projection->not(Worker.valid_handoff_projection plan projection))state.facts.current->
      fail change Worker.Revoked_session
    |Some(Worker.Safe_to_proceed receipt),Some plan,_
      when not(Option.exists(Worker.valid_handoff_projection plan)state.facts.current)->
      fail(Worker.handoff_change receipt)Worker.Revoked_session
    |Some(Worker.Quiescing change),None,_->
      (match state.facts.current with
       |None->transition
       |Some projection->
         (match Worker.host_change_plan projection ~handoff_id:id ~change ~sessions:(host_sessions state change)with
          |Ok plan->
            let retired_host_sessions=Rrbvec.fold_left(fun values session->Sessions.add session values)
              state.facts.retired_host_sessions(host_sessions state change) in
            let sent=not state.host_legacy_pending in
            changed{state with host_plan=Some plan;host_quiesce_sent=sent;facts={state.facts with retired_host_sessions}}
              (non_publications transition.instructions @ if sent then [Quiesce plan] else [])
          |Error error->changed{state with active_handoff=None;
             facts={state.facts with handoffs=(id,Worker.Handoff_failed(change,error))::
               List.filter(fun(old,_)->not(Worker.equal_handoff_id old id))state.facts.handoffs}}(non_publications transition.instructions)))
    |Some(Worker.Quiescing change),Some plan,_ when not state.host_quiesce_sent && not state.host_legacy_pending->
      (match state.facts.current with None->transition|Some projection->
        match Worker.host_change_plan projection ~handoff_id:id ~change ~sessions:(Worker.handoff_plan_sessions plan) with
        |Error error->fail change error
        |Ok plan->changed{state with host_plan=Some plan;host_quiesce_sent=true}
          (non_publications transition.instructions @ [Quiesce plan]))
    |Some(Worker.Quiescing change),Some plan,Some receipt when Worker.valid_handoff_receipt plan receipt
       && Option.exists(Worker.valid_handoff_projection plan)state.facts.current->
      let pending=Observation_ids.exists(fun _ (Observing value)->not value.obs_release_done && affected value.obs_session change)state.facts.observations
        || Observation_ids.exists(fun _ lease->affected(Worker.file_lease_session lease)change)state.facts.file_leases
        || Observation_ids.exists(fun _ cleanup->affected(fst(resource_release cleanup.resource))change)state.facts.asset_cleanup in
      if pending then transition else changed{state with host_candidate=None;
        facts={state.facts with handoffs=(id,Worker.Safe_to_proceed receipt)::
          List.filter(fun(old,_)->not(Worker.equal_handoff_id old id))state.facts.handoffs}}(non_publications transition.instructions)
    |Some(Worker.Applying_host_change receipt),Some plan,_ when state.host_consume_waiting
      && (state.lifecycle<>Running || not(Option.exists(Worker.valid_handoff_projection plan)state.facts.current))->
      fail(Worker.handoff_change receipt)Worker.Revoked_session
    |Some(Worker.Applying_host_change receipt),Some plan,_ when capacity && state.host_consume_waiting
       && state.lifecycle=Running && Worker.valid_handoff_receipt plan receipt
       && Option.exists(Worker.valid_handoff_projection plan)state.facts.current->
      (match plan_host_action_attempt state receipt with
       |Ok(next,instruction)->changed next(non_publications transition.instructions @ [instruction])
       |Error error->fail(Worker.handoff_change receipt)error)
    |_->transition
;;

let step state event =
  progress_host_handoff ~capacity:(event=Capacity_available)(retire_completed_imports(progress_asset_cleanup ~capacity:(event=Capacity_available)
  (progress_observations
    ~retry:
      (match event with
       | Capacity_available -> true
       | _ -> false)
    (step_base state event))))
;;

let plan_mutation
      state
      session
      (operation : Worker.mutation_progress Worker.request)
      key
      target
  =
  let bytes = Intents.fold (fun key _ n -> n + String.length key) state.facts.intents 0 in
  let valid =
    match operation with
    | Worker.Confirm (_, receipt) -> receipt_agrees state.facts key receipt
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
                  * Worker_pure_data.maximum_response_bytes)
               > 16777216))
  then Error (Worker.Invalid_input "Durable intent coordination capacity exhausted")
  else (
    let serial = Int64.succ state.next in
    let ticket =
      { id = Worker.request_id (identity state.client serial)
      ; serial
        ; attempt = 0
      ; kind = Mutation
      ; planned_intent_epoch = state.facts.intent_epoch
        ; planned_source_epoch = state.facts.import_input_epoch
      ; acknowledgement = None
      ; query = Operation operation
      ; target
      }
    in
    let slot =
      { ticket
      ; wait_for_capacity = false
      ; dispatched = true
      ; admitted = None
      ; change_version = 0L
      ; sample_epoch = None
      ; origin = None
      ; result = None
      ; early = None
      ; cancelled = false
      ; retired_by_ack = false;rebind_pending=false
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
           | Worker.Mutate _ | Worker.Append _ -> Worker.Outcome_unknown
           | Worker.Confirm (_, receipt) -> Worker.Committed_pending_presentation receipt
           | _ -> .)
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

let asset_round_count facts =
  let rounds=Observation_ids.map(fun _->())facts.asset_cleanup in
  let rounds=Asset_consumers.fold(fun _ (entry:asset_registration) rounds->
    match Worker.asset_consumer_round entry.consumer with
    | None->rounds|Some round->Observation_ids.add round ()rounds)facts.asset_consumers rounds in
  Observation_ids.cardinal rounds
;;

let plan_asset_command state session operation consumer assets =
  if asset_round_count state.facts>=128
  then Error(Worker.Invalid_input "Settle asset demand rounds before admitting another replacement") else
  let facts=match Asset_consumers.find_opt consumer state.facts.asset_consumers with
    | None->state.facts
    | Some previous->queue_asset_cleanup state.facts previous.consumer () in
  Result.map(fun(ticket,transition)->
    let bound=Worker.bind_asset_consumer consumer ~round:ticket.id in
    let entry={consumer=bound;assets;creation=Awaiting_admission;active=true;notices=[]} in
    let next={transition.next with facts={transition.next.facts with
      asset_consumers=Asset_consumers.add consumer entry transition.next.facts.asset_consumers}} in
    progress_asset_cleanup(changed next(non_publications transition.instructions)) |> fun transition->ticket,transition)
    (plan_intent_lifecycle {state with facts} session operation Unit(Direct session)None)
;;

let plan_asset_release state session consumer =
  if not(Worker.equal_session session(Worker.asset_consumer_session consumer))
  then Error Worker.Revoked_session
  else if Slots.cardinal state.facts.entries>=512
  then Error(Worker.Invalid_input "Release completed cleanup tickets before adding another waiter") else
  let same_round bound=Worker.equal_asset_consumer consumer bound
    && (Worker.asset_consumer_round consumer=None || Worker.asset_consumer_round consumer=Worker.asset_consumer_round bound) in
  let bound=match Asset_consumers.find_opt consumer state.facts.asset_consumers with
    |Some entry when same_round entry.consumer->Some entry.consumer
    |_->Observation_ids.fold(fun _ cleanup found->match found with Some _->found|None->
        match cleanup.resource with Demand_resource bound when same_round bound->Some bound|_->None)
        state.facts.asset_cleanup None in
  if bound=None && Worker.asset_consumer_round consumer<>None then Error Worker.Revoked_session else
  let operation=Worker.Release_asset_demand(Option.value bound ~default:consumer) in
  Result.map(fun((ticket:unit ticket),planned)->
    let entries=match Slots.find_opt ticket.serial planned.next.facts.entries with
      | Some(Entry slot)->(match same_ticket ticket slot.ticket with
        | Some Worker.Refl->Slots.add ticket.serial(Entry{slot with dispatched=false;
            result=(if bound=None then Some(Worker.Answered(Ok())) else None)})planned.next.facts.entries
        | None->assert false)
      | None->assert false in
    let facts={planned.next.facts with entries} in
    let facts=match bound with
      | None->facts
      | Some bound->
        let asset_consumers=match Asset_consumers.find_opt consumer facts.asset_consumers with
          | Some entry when Worker.asset_consumer_round entry.consumer=Worker.asset_consumer_round bound->
            Asset_consumers.add consumer {entry with active=false;notices=[]}facts.asset_consumers
          | None|Some _->facts.asset_consumers in
        let asset_cleanup=Observation_ids.map(fun cleanup->
          match cleanup.resource with Demand_resource actual when Worker.equal_asset_consumer actual bound
            && Worker.asset_consumer_round actual=Worker.asset_consumer_round bound->{cleanup with error=None;wait_for_capacity=false}
          |_->cleanup)facts.asset_cleanup in
        queue_asset_cleanup {facts with asset_consumers;asset_cleanup} bound ~waiter:ticket.serial () in
    ticket,progress_asset_cleanup(changed {planned.next with facts}[]))
    (plan_intent_lifecycle state session operation Unit(Cleanup session)None)
;;

let plan_file_release state session lease =
  let key=Worker.file_lease_id lease in
  let known=Option.exists(fun actual->Worker.equal_session session(Worker.file_lease_session actual))
    (Observation_ids.find_opt key state.facts.file_leases) in
  let settled=Option.exists(Worker.equal_session session)(Observation_ids.find_opt key state.facts.released_leases) in
  if not(Worker.equal_session session(Worker.file_lease_session lease)) || not(known||settled)
  then Error Worker.Revoked_session
  else if Slots.cardinal state.facts.entries>=512 then Error(Worker.Invalid_input "Release completed cleanup waiters first") else
  Result.map(fun((ticket:unit ticket),planned)->
    let entries=match Slots.find_opt ticket.serial planned.next.facts.entries with
      |Some(Entry slot)->(match same_ticket ticket slot.ticket with
        |Some Worker.Refl->Slots.add ticket.serial(Entry{slot with dispatched=false;result=(if settled then Some(Worker.Answered(Ok()))else None)})planned.next.facts.entries
        |_->assert false)|_->assert false in
    let facts={planned.next.facts with entries} in
    let facts=if settled then facts else queue_file_cleanup facts lease ~waiter:ticket.serial () in
    ticket,progress_asset_cleanup(changed{planned.next with facts}[]))
    (plan_intent_lifecycle state session(Worker.Release_file lease)Unit(Cleanup session)None)
;;

let lease_ownership_full state =
  let pending=Slots.fold(fun _ (Entry slot) total->if slot.result<>None then total else match slot.ticket.query with
    |Operation(Worker.Import _ | Worker.Acquire_asset_file _ | Worker.Acquire_imported_file _)->total+1|_->total)state.facts.entries 0 in
  let retained=Observation_ids.cardinal state.facts.file_leases+pending in
  retained+Observation_ids.cardinal state.facts.released_leases>=256
;;

let plan_import state session intent operation =
  let key=import_key intent in
  let pending=Slots.exists(fun _ (Entry slot)->slot.result=None && match slot.ticket.query with
    |Operation(Worker.Import previous)->import_key previous=key|_->false)state.facts.entries in
  if pending then Error(Worker.Invalid_input "This exact import operation is already pending")
  else if Option.exists(fun proof->not(Worker.import_source_proof_matches intent proof))(Graphs.find_opt key state.facts.import_history)
  then Error(Worker.Invalid_input "This completed import operation owns different immutable bytes")
  else if Graphs.cardinal state.facts.import_history>=8192 && not(Graphs.mem key state.facts.import_history)
  then Error(Worker.Invalid_input "Return completed Import source proofs before admitting another operation")
  else if Option.exists(fun saved->Worker.encode_asset_import_intent saved.import_intent<>Worker.encode_asset_import_intent intent)
    (Graphs.find_opt key state.facts.imports)
  then Error(Worker.Invalid_input "This import operation already owns a different immutable source or target")
  else if Graphs.cardinal state.facts.imports>=128 && not(Graphs.mem key state.facts.imports)
  then Error(Worker.Invalid_input "Import recovery capacity is full")
  else
    let state=if Graphs.mem key state.facts.imports then state else
      {state with facts={state.facts with imports=Graphs.add key{import_intent=intent;source_owner=session;source_adopted=false;progress=None;failed_attempt=None}state.facts.imports}} in
    let state={state with facts={state.facts with imports=Graphs.update key
      (Option.map(fun saved->{saved with failed_attempt=None;
        progress=(match saved.progress with Some(Worker.Import_rejected _)->None|_->saved.progress)}))state.facts.imports}} in
    match import_progress state.facts intent with
    |Some(Worker.Imported imported as progress) when Worker.equal_session session(Worker.imported_session imported)->
      Result.map(fun((ticket:Worker.import_progress ticket),planned)->
        let entries=match Slots.find_opt ticket.serial planned.next.facts.entries with
          |Some(Entry slot)->(match same_ticket ticket slot.ticket with
            |Some Worker.Refl->Slots.add ticket.serial(Entry{slot with dispatched=false;result=Some(Worker.Answered(Ok progress))})planned.next.facts.entries
            |_->assert false)|_->assert false in
        ticket,changed{planned.next with facts={planned.next.facts with entries}}[])
        (plan_intent_lifecycle state session operation Import(Direct session)None)
    |_->if lease_ownership_full state then Error(Worker.Invalid_input "File lease ownership capacity is full")
      else plan_intent_lifecycle state session operation Import(Direct session)None
;;

let plan_recovery state session operation =
  let retained=Slots.exists(fun _ (Entry slot)->match slot.ticket.query with
    | Operation(Worker.Recover_mutations _)->true|_->false)state.facts.entries in
  if retained then Error(Worker.Invalid_input "Release the previous recovery ticket before paging")
  else plan_intent_lifecycle state session operation Recovery (Direct session) None
;;

let plan_intent_ack state session intent =
  if state.facts.intent_epoch=Int64.max_int then Error(Worker.Invalid_input "Intent lifecycle counter exhausted") else
  match Option.bind state.facts.current Worker.selected with
  | Some presentation when Worker.equal_session session(Worker.presentation_session presentation)->
    let proof=match Intents.find_opt(intent_key intent)state.facts.intents with
      | Some(Worker.Rejected _)->Ok None
      | Some(Worker.Confirmed confirmation)
        when Worker.confirmation_presentation confirmation=presentation->
        Ok(Some(Worker.confirmation_receipt confirmation))
      | _->Error(Worker.Invalid_input "Acknowledge only an applied rejection or current confirmation") in
    Result.bind proof(fun original->plan_intent_lifecycle state session(Worker.Acknowledge_intent intent)
      Unit (Presentation presentation)(Some(presentation,original)))
  | _->Error Worker.Revoked_session
;;

let plan_observation (state : t) session budget query =
  if
    state.next = Int64.max_int
    || Observation_ids.cardinal state.facts.observations >= 256
  then Error (Worker.Invalid_input "Observation ownership capacity exhausted")
  else (
    let serial = Int64.succ state.next in
    let ticket =
      { id = Worker.request_id (identity state.client serial)
      ; serial
        ; attempt = 0
      ; kind = Observed (kind query)
      ; planned_intent_epoch = state.facts.intent_epoch
        ; planned_source_epoch = state.facts.import_input_epoch
      ; acknowledgement = None
      ; query = Operation (Worker.Observe (budget, query))
      ; target = Sealed (session, budget)
      }
    in
    let slot =
      { ticket
      ; wait_for_capacity = false
      ; dispatched = true
      ; admitted = None
      ; change_version = 0L
      ; sample_epoch = None
      ; origin = Some (session, budget)
      ; result = None
      ; early = None
      ; cancelled = false
      ; retired_by_ack = false;rebind_pending=false
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
      ; obs_creator_finished = false
      ; obs_returned = false
      ; obs_release_done = false
      ; obs_release_inflight = false
      ; obs_cleanup_waiting = false
      ; obs_attempt = None
      ; obs_cleanup_error = None
      ; obs_error = None
      ; obs_epoch = None
      ; obs_dirty = false
      ; obs_retry = false
      ; obs_error_recovered = false
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
  let acknowledged = match find_observation state.facts id (Worker.observation_query handle) with
    |Some value when observation_matches value handle->value.obs_release_done
    |_->false in
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
        ; attempt = 0
      ; kind = Unit
      ; planned_intent_epoch = state.facts.intent_epoch
        ; planned_source_epoch = state.facts.import_input_epoch
      ; acknowledgement = None
      ; query = Operation (Worker.Release handle)
      ; target = Cleanup session
      }
    in
    let slot =
      { ticket
      ; wait_for_capacity = false
      ; dispatched = false
      ; admitted = None
      ; change_version = 0L
      ; sample_epoch = None
      ; origin = None
      ; result = (if acknowledged then Some (Worker.Answered (Ok ())) else None)
      ; early = None
      ; cancelled = false
      ; retired_by_ack = false;rebind_pending=false
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

let plan_change_ack state session batch =
  let graph = Worker.graph_id session in
  let owned =
    match Graphs.find_opt graph state.facts.change_batches with
    | Some (actual, _) -> actual = batch
    | _ -> false
  in
  let acknowledged =
    match Graphs.find_opt graph state.facts.change_acks with
    | Some ack ->
      Worker.equal_session session (Worker.change_ack_session ack)
      && Worker.change_ack_generation ack = batch.Worker.generation
      && Worker.change_ack_through ack = batch.through
    | _ -> false
  in
  if not (owned || acknowledged)
  then
    Error
      (Worker.Invalid_input
         "Only a coordinator-delivered Changes batch may be acknowledged")
  else if state.next = Int64.max_int
  then Error (Worker.Invalid_input "Request counter exhausted")
  else (
    let serial = Int64.succ state.next in
    let ticket =
      { id = Worker.request_id (identity state.client serial)
      ; serial
        ; attempt = 0
      ; kind = Change_ack
      ; planned_intent_epoch = state.facts.intent_epoch
        ; planned_source_epoch = state.facts.import_input_epoch
      ; acknowledgement = None
      ; query = Operation (Worker.Acknowledge_changes batch)
      ; target = Direct session
      }
    in
    let slot =
      { ticket
      ; wait_for_capacity = false
      ; dispatched = false
      ; admitted = None
      ; change_version = 0L
      ; sample_epoch = None
      ; origin = None
      ; result = None
      ; early = None
      ; cancelled = false
      ; retired_by_ack = false;rebind_pending=false
      ; forgotten = false
      }
    in
    let facts =
      { state.facts with entries = Slots.add serial (Entry slot) state.facts.entries }
    in
    Ok (ticket, dispatch_waiting ~publish:true { state with next = serial; facts } []))
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
  | Worker.Release_asset_demand consumer->plan_asset_release state session consumer
  | Worker.Release_file lease->plan_file_release state session lease
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
            | Worker.Acknowledge_changes batch -> plan_change_ack state session batch
            | Worker.Replace_asset_demand(consumer,_,assets)->plan_asset_command state session operation consumer assets
            | Worker.Import intent->plan_import state session intent operation
            | Worker.Acquire_asset_file file when not(asset_file_current state.facts file)->Error Worker.Revoked_session
            | Worker.Acquire_asset_file _->
              if lease_ownership_full state
              then Error(Worker.Invalid_input "File lease ownership capacity is full") else
              plan_intent_lifecycle state session operation Lease(Direct session)None
            | Worker.Acquire_imported_file _->
              if lease_ownership_full state
              then Error(Worker.Invalid_input "File lease ownership capacity is full") else
              plan_intent_lifecycle state session operation Lease(Direct session)None
            | Worker.Retry_asset _->plan_intent_lifecycle state session operation Unit(Direct session)None
            | Worker.Retry_upload _->plan_intent_lifecycle state session operation Unit(Direct session)None
            | Worker.Recover_import_inputs _ ->
              if Slots.exists(fun _ (Entry slot)->match slot.ticket.query with Operation(Worker.Recover_import_inputs _)->true|_->false)state.facts.entries
              then Error(Worker.Invalid_input "Release the previous import recovery ticket before paging")
              else plan_intent_lifecycle state session operation Import_inputs(Direct session)None
            | Worker.Confirm_import_source intent->
              (* Only a read planned after an actual terminal handler failure
                 can establish that its original input never became Prepared. *)
              let failed=Option.bind(Graphs.find_opt(import_key intent)state.facts.imports)(fun saved->
                if Worker.encode_asset_import_intent intent=Worker.encode_asset_import_intent saved.import_intent
                then Option.map fst saved.failed_attempt else None) in
              plan_intent_lifecycle state session operation (Import_source failed)(Direct session)None
            | Worker.Acknowledge_import_source _->
              if state.facts.import_input_epoch=Int64.max_int then Error(Worker.Invalid_input "Source lifecycle counter exhausted")
              else plan_intent_lifecycle state session operation Unit(Direct session)None
            | Worker.Recover_mutations _ -> plan_recovery state session operation
            | Worker.Acknowledge_intent intent -> plan_intent_ack state session intent
            | Worker.Query (budget, query) ->
              Result.bind
                (validate_change_query state.facts session budget query)
                (fun () ->
                   if state.next = Int64.max_int
                   then Error (Worker.Invalid_input "Request counter exhausted")
                   else (
                     let serial = Int64.succ state.next in
                     let ticket =
                       { id = Worker.request_id (identity state.client serial)
                       ; serial
        ; attempt = 0
                       ; kind = kind query
                       ; planned_intent_epoch = state.facts.intent_epoch
        ; planned_source_epoch = state.facts.import_input_epoch
                       ; acknowledgement = None
                       ; query = Read query
                       ; target = Sealed (session, budget)
                       }
                     in
                     let ready =
                       change_query_ready state.facts session budget query
                       &&
                       match query with
                       | Worker.Changes _ ->
                         change_read_available (active_change_reads state.facts) session
                       | _ -> true
                     in
                     let slot =
                       { ticket
                       ; wait_for_capacity = false
                       ; dispatched = ready
                       ; admitted = None
                       ; change_version = change_version state.facts session
                       ; sample_epoch = None
                       ; origin = (if ready then Some (session, budget) else None)
                       ; result = None
                       ; early = None
                       ; cancelled = false
                       ; retired_by_ack = false;rebind_pending=false
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
                           (if ready then [ Send (ticket, session, operation) ] else [])
                       )))
            | Worker.Append intent ->
              plan_mutation state session operation
                (intent_key(Worker.Append_intent intent)) (Direct session)
            | Worker.Mutate intent ->
              plan_mutation state session operation (intent_key(Worker.Mutation_intent intent)) (Direct session)
            | Worker.Confirm (presentation, receipt) ->
              plan_mutation
                state
                session
                operation
                (intent_key (Worker.receipt_intent receipt))
                (Presentation presentation)
            | _ ->
              Error
                (Worker.Unsupported_operation
                   "Operation needs backend durability/resource conformance")
          in
          planned))
;;

let reconcile_mutation state ~presentation intent =
  let session = Worker.presentation_session presentation in
  match Option.bind state.facts.current Worker.selected with
  | Some current when current = presentation ->
    let operation = match intent_progress (view state) intent with
      | Some (Worker.Committed_pending_presentation receipt) -> Worker.Confirm (presentation, receipt)
      | Some (Worker.Confirmed confirmation) ->
        Worker.Confirm (presentation, Worker.confirmation_receipt confirmation)
      | None | Some (Worker.Outcome_unknown | Worker.Rejected _) -> (match intent with Worker.Append_intent intent->Worker.Append intent|Mutation_intent intent->Worker.Mutate intent) in
    request state session operation
  | _ -> Error Worker.Revoked_session
;;

type mutation_settlement =
  | Acknowledgement of unit ticket
  | Reconciliation of Worker.mutation_progress ticket

let settle_applied_mutation state ~presentation ~applied_presentation intent =
  let current=applied_presentation=presentation && current_presentation (view state) presentation in
  let acknowledged=match intent_progress (view state) intent with
    | Some(Worker.Rejected _)->current
    | Some(Worker.Confirmed value)->current && Worker.confirmation_presentation value=presentation
    | _->false in
  if acknowledged then
    request state (Worker.presentation_session presentation)(Worker.Acknowledge_intent intent)
    |> Result.map(fun(ticket,transition)->Acknowledgement ticket,transition)
  else reconcile_mutation state ~presentation intent
    |> Result.map(fun(ticket,transition)->Reconciliation ticket,transition)
;;

let begin_change_application state batch ~root =
  let session = Worker.change_batch_session batch in
  let graph = Worker.graph_id session in
  Result.bind (validate_session state session) (fun () ->
    let owned =
      match Graphs.find_opt graph state.facts.change_batches with
      | Some (actual, _) -> actual = batch
      | _ -> false
    in
    if not owned
    then
      Error (Worker.Invalid_input "Change application requires an owned delivered batch")
    else if
      Option.exists
        (fun application -> Graphs.is_empty application.failed_consumers)
        (application_for_batch state.facts batch)
    then Error (Worker.Invalid_input "The change application attempt is already active")
    else if state.next = Int64.max_int
    then Error (Worker.Invalid_input "Change application counter exhausted")
    else (
      let serial = Int64.succ state.next in
      let token =
        { application_id = Worker.request_id (identity state.client serial)
        ; application_batch = batch
        }
      in
      let consumers = Graphs.singleton root waiting_consumer in
      let application =
        { token
        ; pending_consumers = consumers
        ; issued_consumers = Graphs.singleton root ()
        ; issued_count = 1
        ; failed_consumers = Graphs.empty
        }
      in
      let facts =
        { state.facts with
          applications = Graphs.add graph application state.facts.applications
        }
      in
      Ok (token, changed { state with next = serial; facts } [])))
;;

let plan_query_internal
      ~wait_for_capacity
      state
      ~owner
      ~maximum_items
      ~maximum_bytes
      query
  =
  let target = Expected (owner, maximum_items, maximum_bytes) in
  if state.lifecycle <> Running
  then Error Worker.Revoked_session
  else if List.exists (affected_target target) state.fenced
  then Error Worker.Host_change_in_progress
  else if
    maximum_items <= 0
    || maximum_bytes <= 0
    || maximum_bytes > Worker_pure_data.maximum_response_bytes
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
        ; attempt = 0
      ; kind = kind query
      ; planned_intent_epoch = state.facts.intent_epoch
        ; planned_source_epoch = state.facts.import_input_epoch
      ; acknowledgement = None
      ; query = Read query
      ; target
      }
    in
    let slot =
      { ticket
      ; wait_for_capacity
      ; dispatched = false
      ; admitted = None
      ; change_version = 0L
      ; sample_epoch = None
      ; origin = None
      ; result = None
      ; early = None
      ; cancelled = false
      ; retired_by_ack = false;rebind_pending=false
      ; forgotten = false
      }
    in
    let facts =
      { state.facts with entries = Slots.add serial (Entry slot) state.facts.entries }
    in
    Ok (ticket, dispatch_waiting ~publish:true { state with next = serial; facts } []))
;;

let prepare_host_change ?(legacy_pending=false) state change =
  match state.active_handoff with
  |Some id when (match handoff state.facts id,state.host_candidate with
     |Some(Worker.Handoff_failed(actual,_)),Some receipt->actual=change && account_host receipt
       && not(handoff_restartable state.facts id)|_->false)->
    let receipt=Option.get state.host_candidate in
    let state={state with facts={state.facts with handoffs=(id,Worker.Applying_host_change receipt)::
      List.filter(fun(old,_)->not(Worker.equal_handoff_id old id))state.facts.handoffs}} in
    Ok(id,plan_host_confirmation state receipt)
  |Some _->Error Worker.Host_change_in_progress
  |None->
  (* No active round remains: the next user attempt retires determined outcomes
     of earlier attempts. Unknown consumption/readback keeps active_handoff and
     cannot enter here. Resource and execution retirement facts are independent. *)
  let state={state with facts={state.facts with handoffs=[];restartable_handoffs=[]}} in
  if state.binding = None || state.lifecycle <> Running
  then Error Worker.Revoked_session
  else if Option.is_some(terminal_bootstrap_error state.facts)
  then Error(Option.get(terminal_bootstrap_error state.facts))
  else if state.next = Int64.max_int
  then Error (Worker.Invalid_input "Handoff request counter exhausted")
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
    let facts=Asset_consumers.fold(fun _ (entry:asset_registration) facts->
      if affected(Worker.asset_consumer_session entry.consumer)change
      then queue_asset_cleanup facts entry.consumer () else facts)facts.asset_consumers facts in
    let facts=Observation_ids.fold(fun _ lease facts->
      if affected(Worker.file_lease_session lease)change then queue_file_cleanup facts lease () else facts)facts.file_leases facts in
    let facts={facts with asset_consumers=Asset_consumers.map(fun (entry:asset_registration)->
      if affected(Worker.asset_consumer_session entry.consumer)change then {entry with active=false;notices=[]}else entry)facts.asset_consumers} in
    Ok
      ( id
      , progress_host_handoff(progress_asset_cleanup(progress_observations
          ~retry:false
          (changed
             { state with
               next = serial
             ; facts
             ; active_handoff = Some id
             ; host_plan=None;host_candidate=None;host_legacy_pending=legacy_pending;host_quiesce_sent=false
             ; host_consume_attempt=None;host_consume_admitted=None;host_consume_early=None;host_consume_waiting=false
             ; fenced = change :: state.fenced
             }
             cancels)))))
;;

let authorize_host_change state receipt =
  let id=Worker.handoff_receipt_id receipt in
  match state.lifecycle,state.active_handoff,state.host_plan,handoff state.facts id,state.facts.current with
  |Running,Some active,Some plan,Some(Worker.Safe_to_proceed actual),Some projection
    when Worker.equal_handoff_id active id && actual=receipt
      && Worker.valid_handoff_receipt plan receipt && Worker.valid_handoff_projection plan projection->
    let facts={state.facts with handoffs=(id,Worker.Applying_host_change receipt)::
      List.filter(fun(old,_)->not(Worker.equal_handoff_id old id))state.facts.handoffs} in
    Result.map(fun(next,instruction)->changed next[instruction])
      (plan_host_action_attempt {state with facts} receipt)
  |_->Error Worker.Revoked_session
;;

let plan_query state ~owner ~maximum_items ~maximum_bytes query =
  plan_query_internal
    ~wait_for_capacity:false
    state
    ~owner
    ~maximum_items
    ~maximum_bytes
    query
;;

let plan_query_when_available state ~owner ~maximum_items ~maximum_bytes query =
  plan_query_internal
    ~wait_for_capacity:true
    state
    ~owner
    ~maximum_items
    ~maximum_bytes
    query
;;
