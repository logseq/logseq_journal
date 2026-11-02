module Graph = Logseq_db_types.Graph_types
module Uuid = Graph.Uuid
module Protocol = Logseq_db_worker.Protocol
module Wire = Logseq_db_worker_contract.Mutation_pure_wire
module Service = Logseq_db_worker_lui.Logseq_db_worker_lui_service
module Import_wire=Logseq_db_types.Asset_import.Pure_intent

type account_generation = int
type graph_generation = int
type presentation_generation = int64

type worker_incarnation =
  { runtime_epoch : Logseq_db_worker_lui.Journal_worker_ids.Runtime.epoch
  ; worker_generation : Logseq_db_worker_lui.Journal_worker_ids.Worker.generation
  }

type binding =
  { serial : int64
  ; incarnation : worker_incarnation
  ; origin : string
  ; user : string
  }

type session =
  { binding : binding
  ; graph : Uuid.t
  ; account : account_generation
  ; lifecycle : int64
  ; generation : graph_generation
  ; scope : Service.timeline_scope
  ; asset_scope : Service.asset_scope
  ; limits : Protocol.v2_capability_limits
  }

type presentation =
  { session : session
  ; generation : presentation_generation
  ; host_generation : int
  }

type error =
  | Revoked_session
  | Invalid_input of string
  | Response_budget_exceeded
  | Stale_read of string
  | Resync_required of string
  | Host_change_in_progress
  | Protocol_mismatch of string
  | Db_error of Logseq_db_worker.Error.t
  | Service_failed of string
  | Unsupported_operation of string

type request_id = Uuid.t

type capabilities =
  { limits : Protocol.v2_capability_limits
  ; atomic_append : bool
  ; durable_mutations : bool
  ; durable_import : bool
  ; observations : bool
  }

type read_budget =
  { owner : session
  ; maximum_items : int
  ; maximum_bytes : int
  }

type journal_day = int

type page =
  { data : Graph.page
  ; revision : string
  }

type block =
  { data : Protocol.v2_block_record
  ; revision : string
  }

type 'a continuation =
  { owner : session
  ; key : string
  ; budget : read_budget
  ; cursor : Graph.Cursor.t
  }

type 'a slice =
  { items : 'a list
  ; next : 'a continuation option
  }

type graph_info =
  { graph_uuid : Uuid.t
  ; graph_name : string
  ; schema : Graph.schema_version
  ; admission_facts : Graph.admission_fact list
  ; journal_title_format : string option
  ; limits : Protocol.v2_capability_limits
  ; generation : string
  ; projection_revision : string
  }

type block_summary =
  { lookup : Protocol.v2_block_lookup
  ; page : Protocol.v2_page_lookup option
  ; items : Protocol.v2_child_member list
  ; next : Protocol.v2_child_member continuation option
  ; scope_revision : string
  ; generation : string
  ; projection_revision : string
  }

type favorites =
  { favorites_page : Uuid.t option
  ; generation : string
  ; projection_revision : string
  ; items : Protocol.v2_favorite_item list
  ; next : Protocol.v2_favorite_item continuation option
  }

type task_status_catalog =
  { property_uuid : Uuid.t option
  ; default_status : Uuid.t option
  ; items : Graph.task_status_definition list
  ; next : Graph.task_status_definition continuation option
  }

type asset_listing =
  { generation : string
  ; projection_revision : string
  ; items : Logseq_db_types.Asset_descriptor.t list
  ; next : Logseq_db_types.Asset_descriptor.t continuation option
  }

type children =
  { parent : Uuid.t
  ; revision_scope : Protocol.v2_revision_scope
  ; scope_revision : string
  ; items : Protocol.v2_child_member list
  ; next : Protocol.v2_child_member continuation option
  }

type change_batch =
  { change_owner : session
  ; generation : string
  ; from_exclusive : string option
  ; through : string
  ; windows : Protocol.v2_change_window list
  ; next : string option
  }

type change_ack =
  { ack_owner : session
  ; generation : string
  ; through : string
  }

type _ query =
  | Graph_info : graph_info query
  | Admission : Protocol.v2_admission_inspection query
  | Journal : journal_day -> page option query
  | Journals :
      { from_day : journal_day
      ; through_day : journal_day
      ; revision : string option
      ; after : Protocol.v2_journal_item continuation option
      }
      -> Protocol.v2_journal_item slice query
  | Page :
      { uuid : Uuid.t
      ; revision : string option
      }
      -> Protocol.v2_page_lookup query
  | Outline_block :
      { uuid : Uuid.t
      ; revision : string option
      }
      -> Protocol.v2_block_lookup query
  | Block_summary :
      { block : Uuid.t
      ; after : Protocol.v2_child_member continuation option
      }
      -> block_summary query
  | Children :
      { parent : Uuid.t
      ; after : block continuation option
      }
      -> block slice query
  | Child_members :
      { parent : Uuid.t
      ; revision : string option
      ; after : Protocol.v2_child_member continuation option
      }
      -> children query
  | Tree :
      { page : Uuid.t
      ; maximum_depth : int
      ; revision : string option
      ; after : Protocol.v2_tree_member continuation option
      }
      -> Protocol.v2_tree_member slice query
  | Favorites : Protocol.v2_favorite_item continuation option -> favorites query
  | Task_statuses :
      Graph.task_status_definition continuation option
      -> task_status_catalog query
  | Task_status_definitions :
      Uuid.t list
      -> Graph.task_status_definition option list query
  | Asset_descriptors : Uuid.t list -> asset_listing query
  | Assets :
      { recursive : bool
      ; roots : Uuid.t list
      ; after : Logseq_db_types.Asset_descriptor.t continuation option
      }
      -> asset_listing query
  | Changes :
      { generation : string
      ; after : string option
      }
      -> change_batch query

type capture_node = Protocol.v2_append_node =
  { block_id : Uuid.t
  ; title : string
  ; task_status : Uuid.t option
  ; children : capture_node Rrbvec.t
  }

type append_intent = Wire.t

type mutation_command =
  | Save_block of
      { block : Uuid.t
      ; title : string
      ; preconditions : Protocol.v2_preconditions
      }
  | Insert_blocks of
      { parent : Uuid.t
      ; roots : Protocol.v2_block_tree list
      ; preconditions : Protocol.v2_preconditions
      }
  | Delete_blocks of
      { root : Uuid.t
      ; preconditions : Protocol.v2_preconditions
      }
  | Create_journal of
      { page : Uuid.t
      ; day : journal_day
      ; title : string
      ; preconditions : Protocol.v2_preconditions
      }
  | Set_task_status of
      { block : Uuid.t
      ; status : Uuid.t
      ; preconditions : Protocol.v2_preconditions
      }
  | Clear_task_status of
      { block : Uuid.t
      ; preconditions : Protocol.v2_preconditions
      }
  | Set_asset_reference of
      { block : Uuid.t
      ; previous : Uuid.t option
      ; asset : Uuid.t
      ; preconditions : Protocol.v2_preconditions
      }

type mutation_intent = Wire.t

type receipt =
  { intent : mutation_intent
  ; generation : string
  ; before : string
  ; after : string
  }

type confirmed_target =
  | Confirmed_block of block_summary
  | Confirmed_page of Protocol.v2_page_lookup
  | Confirmed_absence of
      { uuid : Uuid.t
      ; revision : string
      ; generation : string
      ; projection_revision : string
      }
[@@warning "-37"]

type confirmation =
  { receipt : receipt
  ; presentation : presentation
  ; primary : confirmed_target
  ; additional : confirmed_target Rrbvec.t
  }

type mutation_progress =
  | Rejected of error
  | Outcome_unknown
  | Committed_pending_presentation of receipt
  | Confirmed of confirmation

type mutation_recovery_cursor =
  { recovery_owner : session; after : int64; maximum_items : int; maximum_bytes : int }
type recovered_mutation = { intent : mutation_intent; progress : mutation_progress }
type mutation_recovery = { items : recovered_mutation Rrbvec.t; next : mutation_recovery_cursor option }

let maximum_mutation_recovery_bytes = Wire.maximum_recovery_bytes

type admission_error =
  | Full
  | Not_ready
  | Stopping
  | Unsupported_request of string

type interruption =
  | Cancelled
  | Transport_lost
  | Worker_stopped

type 'a reply =
  | Not_admitted of admission_error
  | Answered of ('a, error) result
  | Interrupted of interruption

type changefeed_notice =
  { notice_session : session
  ; notice : Protocol.push
  }

type observation_epoch = int64

type 'a observation =
  { observation_owner : session
  ; observation_key : request_id
  ; observation_budget : read_budget
  ; observation_query : 'a query
  }

type (_, _) equality = Refl : ('a, 'a) equality

type 'a observed =
  { observation : 'a observation
  ; epoch : observation_epoch
  ; value : 'a
  }

type observation_notice =
  | Observation_invalidated of
      { binding : binding
      ; owner : Service.timeline_scope
      ; id : request_id
      ; epoch : observation_epoch
      }
  | Observations_resync of binding

type asset_consumer =
  { session : session
  ; name : string
  ; round : request_id option
  }

type asset_file = { asset_owner:session; asset_consumer:asset_consumer; asset:Uuid.t; source_handle:string }
type file_lease = {lease_owner:session;lease_id:request_id;lease_handle:string;lease_path:string;lease_type:string}
type upload_operation = { upload_owner:session; operation:Uuid.t }
type import_source_proof={source_operation:Uuid.t;source_fingerprint:string}
type imported = {import_owner:session;import_receipt:Logseq_db_worker.import_receipt;import_preview:file_lease option;source_proof:import_source_proof}
type asset_import_intent = Import_wire.t

type import_progress =
  | Import_rejected of error
  | Import_unknown
  | Imported of imported

type asset_priority =
  | Foreground
  | Background

type asset_notice = { notice_owner:session; notice_consumer:asset_consumer option; notice_data:Service.asset_notice }

type _ request =
  | Query : read_budget * 'a query -> 'a request
  | Observe : read_budget * 'a query -> 'a observed request
  | Refresh : 'a observation -> 'a observed request
  | Release : 'a observation -> unit request
  | Append : append_intent -> mutation_progress request
  | Mutate : mutation_intent -> mutation_progress request
  | Confirm : presentation * receipt -> mutation_progress request
  | Recover_mutations :
      { after : mutation_recovery_cursor option; maximum_items : int; maximum_bytes : int }
      -> mutation_recovery request
  | Acknowledge_intent : mutation_intent -> unit request
  | Acknowledge_changes : change_batch -> change_ack request
  | Import : asset_import_intent -> import_progress request
  | Replace_asset_demand :
      asset_consumer * asset_priority * Logseq_db_types.Asset_descriptor.t list
      -> unit request
  | Release_asset_demand : asset_consumer -> unit request
  | Retry_asset : Uuid.t -> unit request
  | Retry_upload : upload_operation -> unit request
  | Acquire_asset_file : asset_file -> file_lease option request
  | Acquire_imported_file : imported -> file_lease option request
  | Release_file : file_lease -> unit request

type observation_update = Update : 'a observed -> observation_update
type projection_version = int64

type resident_phase =
  | Opening
  | Open
  | Closing
  | Failed of error

type network_phase =
  | Offline
  | Connecting
  | Current
  | Network_failed of error

type resident =
  { session : session
  ; phase : resident_phase
  ; network : network_phase
  }

type removal_mode =
  | Ordinary
  | Force

type removal_stage =
  | Closing_graph
  | Deleting_local
  | Clearing_selection

type local_deletion =
  | Removing of Uuid.t * removal_mode * removal_stage
  | Removal_failed of Uuid.t * removal_mode * removal_stage * error

type projection =
  { binding : binding
  ; host_owner : Service.account_scope
  ; account : account_generation
  ; version : projection_version
  ; residents : resident list
  ; selected : presentation option
  ; deletion : local_deletion option
  }

type bootstrap_state =
  | Awaiting_baseline
  | Bootstrap_not_ready of string
  | Ready of projection
  | Bootstrap_failed of error
  | Binding_revoked of error

type host_change =
  | Account_will_change
  | Graph_will_close of Uuid.t
  | Graph_will_remove of Uuid.t * removal_mode
  | Connection_will_stop

type cleanup_resource =
  | Observation
  | Asset_demand
  | File_lease
  | Pending_request
  | Durable_intent

type handoff_id = Uuid.t
type handoff_plan={plan_binding:binding;plan_wire:Logseq_db_worker.host_plan;plan_change:host_change;
  plan_sessions:session Rrbvec.t}
type handoff_receipt={host_plan:handoff_plan;host_receipt:Logseq_db_worker_pure_reducer.Core.Host_handoff.receipt}

type handoff_state =
  | Quiescing of host_change
  | Safe_to_proceed of handoff_receipt
  | Applying_host_change of handoff_receipt
  | Host_change_applied of handoff_receipt
  | Handoff_failed of host_change * error

module type ISSUER = sig
  val binding : binding
  val revoke : unit -> unit
  val release_binding_request : unit -> (Service.request, error) result
  val binding_released : Service.response -> (unit, error) result

  val handoff_request
    :  handoff_plan
    -> (Service.request, error) result

  val handoff_receipt
    :  handoff_plan
    -> Service.response
    -> (handoff_receipt, error) result

  val consume_handoff_request : handoff_receipt -> (Service.request,error)result
  val handoff_consumed : handoff_receipt -> Service.response -> (unit,error)result
  val bootstrap_request : unit -> (Service.request, error) result
  val bootstrap : Service.response -> (bootstrap_state, error) result

  val projection
    :  previous:projection option
    -> Service.push
    -> (projection, error) result

  val request
    :  session
    -> request_id:request_id
    -> 'a request
    -> (Service.request, error) result

  val acknowledge_mutation_request
    : session -> request_id:request_id -> presentation:presentation
    -> intent:mutation_intent -> original:receipt option -> (Service.request,error) result

  val reply
    :  session
    -> request_id:request_id
    -> 'a request
    -> Service.response
    -> ('a reply, error) result

  val observation
    :  session
    -> request_id:request_id
    -> 'a observation
    -> Service.response
    -> ('a observed, error) result

  val observation_registration
    :  session
    -> request_id:request_id
    -> 'a observed request
    -> Service.response
    -> ('a observation * observation_epoch, error) result

  val changefeed_notices : Service.push -> (changefeed_notice Rrbvec.t, error) result
  val observation_notices : Service.push -> (observation_notice Rrbvec.t, error) result

  val release_observation_registration
    :  session
    -> observation_id:request_id
    -> (Service.request, error) result

  val observation_registration_released
    :  session
    -> observation_id:request_id
    -> Service.response
    -> (unit, error) result

  val receipt
    :  session
    -> request_id:request_id
    -> intent:append_intent
    -> Protocol.response
    -> (receipt, error) result

  val mutation_receipt
    :  session
    -> request_id:request_id
    -> intent:mutation_intent
    -> Protocol.response
    -> (receipt, error) result

  val confirmation
    :  session
    -> presentation:presentation
    -> receipt
    -> Protocol.response
    -> (confirmation, error) result

  val asset_notice : session -> Service.asset_notice -> (asset_notice, error) result
end

let binding_incarnation (b : binding) = b.incarnation

let equal_binding (a : binding) (b : binding) =
  a.serial = b.serial
  && Logseq_db_worker_lui.Journal_worker_ids.Runtime.Epoch.equal
       a.incarnation.runtime_epoch
       b.incarnation.runtime_epoch
  && Logseq_db_worker_lui.Journal_worker_ids.Worker.Generation.equal
       a.incarnation.worker_generation
       b.incarnation.worker_generation
;;

let account_generation (s : session) = s.account
let graph_generation (s : session) = s.generation
let presentation_generation (p : presentation) = p.generation
let presentation_session (p : presentation) = p.session
let graph_id (s : session) = s.graph

let equal_session (a : session) (b : session) =
  equal_binding a.binding b.binding
  && a.account = b.account
  && a.lifecycle = b.lifecycle
  && a.generation = b.generation
  && Uuid.equal a.graph b.graph
;;

let compare_session (a:session)(b:session)=
  let key (s:session)=(s.binding.incarnation,s.binding.serial,s.binding.origin,s.binding.user,
    s.account,s.lifecycle,s.generation,s.graph) in
  Stdlib.compare(key a)(key b)
;;

let matches_asset_scope (session:session) (scope:Service.asset_scope)=
  let expected=session.asset_scope in
  expected.graph_id=scope.graph_id && expected.graph_generation=scope.graph_generation
  && expected.account.user_id=scope.account.user_id
  && Uri.equal expected.account.managed_sync_origin scope.account.managed_sync_origin
  && expected.account.account_generation=scope.account.account_generation
  && expected.account.lifecycle_generation=scope.account.lifecycle_generation
;;

let same_logical_graph (a : session) (b : session) =
  a.binding.origin = b.binding.origin
  && a.binding.user = b.binding.user
  && Uuid.equal a.graph b.graph
;;

let matches_scope (session : session) (scope : Service.timeline_scope) =
  session.account = scope.startup.account_generation
  && session.generation = scope.graph_generation
  && Uuid.equal session.graph scope.graph_id
;;

let presentation_matches_scope (presentation:presentation) (scope:Service.timeline_scope) =
  matches_scope presentation.session scope
  && presentation.host_generation=scope.startup.presentation_generation
;;

let worker_incarnation ~runtime_epoch ~worker_generation =
  { runtime_epoch; worker_generation }
;;

let request_id id = id
let equal_request_id = Uuid.equal
let compare_request_id = Uuid.compare

let capabilities (s : session) =
  { limits = s.limits
  ; atomic_append = true
  ; durable_mutations = true
  ; durable_import = true
  ; observations = true
  }
;;

let read_budget (owner : session) ~maximum_items ~maximum_bytes =
  if
    maximum_items <= 0
    || maximum_items > Protocol.maximum_page_size
    || maximum_bytes <= 0
    || maximum_bytes > owner.limits.response_budget_bytes
  then Error (Invalid_input "Read budget exceeds advertised limits")
  else Ok { owner; maximum_items; maximum_bytes }
;;

let journal_day day =
  let year = day / 10000
  and month = day / 100 mod 100
  and date = day mod 100 in
  let leap = year mod 400 = 0 || (year mod 4 = 0 && year mod 100 <> 0) in
  let days =
    match month with
    | 2 -> if leap then 29 else 28
    | 4 | 6 | 9 | 11 -> 30
    | _ -> 31
  in
  if year < 1 || year > 9999 || month < 1 || month > 12 || date < 1 || date > days
  then Error (Invalid_input "Invalid journal day")
  else Ok day
;;

let page_uuid (p : page) = p.data.uuid
let page_title (p : page) = p.data.title
let page_data (p : page) = p.data
let page_revision (p : page) = p.revision
let block_uuid (b : block) = b.data.block.uuid
let block_title (b : block) = b.data.block.title
let block_data (b : block) = b.data
let block_revision (b : block) = b.revision
let change_batch_session (batch : change_batch) = batch.change_owner
let change_ack_session (ack : change_ack) = ack.ack_owner
let change_ack_generation (a : change_ack) = a.generation
let change_ack_through (a : change_ack) = a.through

let unavailable feature =
  Error (Unsupported_operation (feature ^ " backend guarantee is not available"))
;;

let append_intent (session:session) ~mutation_id ~block_id ~day ~title ~task_status ~children =
  let root:Protocol.v2_append_node={block_id;title;task_status;children} in
  if not(Protocol.valid_append_node root) then Error(Invalid_input "Invalid bounded Append tree")
  else Result.bind(journal_day day)(fun day->
    let digits=Printf.sprintf "%08d" day in
    let page=Uuid.of_string(Printf.sprintf "00000001-%s-%s-0000-000000000000"
      (String.sub digits 0 4)(String.sub digits 4 4)) |> Result.get_ok in
    Wire.create ~origin:(Uri.of_string session.binding.origin) ~user:session.binding.user ~graph:session.graph
      (Protocol.V2_append_journal{mutation_id;page;journal_day=day;root})
    |> Result.map_error(fun message->Invalid_input message))
;;

let append_intent_id = Wire.mutation_id
let encode_append_intent intent = Bytes.of_string(Wire.encode intent)
let restore_append_intent (session:session) bytes =
  Result.bind(Wire.restore ~origin:(Uri.of_string session.binding.origin) ~user:session.binding.user
    ~graph:session.graph(Bytes.to_string bytes) |> Result.map_error(fun message->Invalid_input message))
    (fun intent->match Wire.command intent with
      | Protocol.V2_append_journal _->Ok intent
      | _->Error(Invalid_input "Stored intent is not an atomic Append"))
;;

let wire_command ~mutation_id = function
  | Save_block { block; title; preconditions } ->
    Protocol.V2_save_block { mutation_id; block; title; preconditions }
  | Insert_blocks { parent; roots; preconditions } ->
    Protocol.V2_insert_blocks { mutation_id; parent; roots; preconditions }
  | Delete_blocks { root; preconditions } ->
    Protocol.V2_delete_blocks { mutation_id; root; preconditions }
  | Create_journal { page; day; title; preconditions } ->
    Protocol.V2_create_journal_page
      { mutation_id; page; journal_day = day; title; preconditions }
  | Set_task_status { block; status; preconditions } ->
    Protocol.V2_set_task_status { mutation_id; block; status; preconditions }
  | Clear_task_status { block; preconditions } ->
    Protocol.V2_clear_task_status { mutation_id; block; preconditions }
  | Set_asset_reference { block; previous; asset; preconditions } ->
    Protocol.V2_set_asset_reference { mutation_id; block; previous; asset; preconditions }
;;

let mutation_intent (session : session) ~mutation_id command =
  Wire.create
    ~origin:(Uri.of_string session.binding.origin)
    ~user:session.binding.user
    ~graph:session.graph
    (wire_command ~mutation_id command)
  |> Result.map_error (fun message -> Invalid_input message)
;;

let mutation_intent_id = Wire.mutation_id
let encode_mutation_intent intent = Bytes.of_string (Wire.encode intent)

let restore_mutation_intent (session : session) bytes =
  Wire.restore
    ~origin:(Uri.of_string session.binding.origin)
    ~user:session.binding.user
    ~graph:session.graph
    (Bytes.to_string bytes)
  |> Result.map_error (fun message -> Invalid_input message)
;;

let validate_intent session intent =
  restore_mutation_intent session (encode_mutation_intent intent)
  |> Result.map (fun _ -> ())
;;

let receipt_intent (receipt:receipt) = receipt.intent
let receipt_mutation_id (receipt:receipt) = Wire.mutation_id receipt.intent
let receipt_revisions receipt = receipt.generation, receipt.before, receipt.after
let receipt_targets (receipt:receipt) = Wire.targets receipt.intent

let decode_mutation_receipt session ~request_id ~intent response =
  Result.bind (validate_intent session intent) (fun () ->
    if Protocol.encoded_response_bytes response > session.limits.response_budget_bytes
    then Error Response_budget_exceeded
    else
      Wire.committed_point intent ~request_id response
      |> Result.map (fun point ->
        { intent
        ; generation = point.Wire.generation
        ; before = point.before
        ; after = point.after
        })
      |> Result.map_error (fun message -> Protocol_mismatch message))
;;

let confirmation_primary confirmation = confirmation.primary
let confirmation_additional confirmation = confirmation.additional
let confirmation_receipt confirmation = confirmation.receipt
let confirmation_presentation confirmation = confirmation.presentation

let validate_confirmation session (presentation : presentation) (receipt:receipt) =
  if not (equal_session session presentation.session)
  then Error Revoked_session
  else validate_intent session receipt.intent
;;

let validate_recovery session ~after ~maximum_items ~maximum_bytes =
  if maximum_items<=0 || maximum_items>256 || maximum_bytes<=0
     || maximum_bytes>maximum_mutation_recovery_bytes
  then Error(Invalid_input "Invalid durable recovery budget")
  else match after with
  | None->Ok()
  | Some cursor when not(equal_session cursor.recovery_owner session)->Error Revoked_session
  | Some cursor when cursor.maximum_items<>maximum_items || cursor.maximum_bytes<>maximum_bytes->
    Error(Stale_read "Durable recovery cursor budgets changed")
  | Some _->Ok()
;;

let decode_mutation_progress session ~request_id ~intent outcome =
  Result.bind(validate_intent session intent)(fun()->match outcome with
    | Wire.Unknown->Ok Outcome_unknown
    | Wire.Committed response->decode_mutation_receipt session ~request_id ~intent response
      |> Result.map(fun receipt->Committed_pending_presentation receipt)
    | Wire.Rejected(Protocol.V2_response{api_version;request_id=actual;outcome=V2_failed{code;message}} as response)
      when api_version=Protocol.api_version && Uuid.equal actual request_id->
      if Protocol.encoded_response_bytes response>session.limits.response_budget_bytes
      then Error Response_budget_exceeded
      else (match Logseq_db_worker.Error.code_of_string code with
        | Some code ->
          (match Logseq_db_worker.Error.create ~code ~message ~details:[] with
           | Ok error->Ok(Rejected(Db_error error))
           | Error _->Error(Protocol_mismatch "Invalid known mutation error"))
        | None->Ok(Rejected(Service_failed(code^": "^message))))
    | _->Error(Protocol_mismatch "Invalid known mutation rejection"))
;;

module Mutation_ids=Set.Make(Uuid)

let decode_recovery session ~request_id ~after ~maximum_items ~maximum_bytes (page:Wire.recovery_page) =
  Result.bind(validate_recovery session ~after ~maximum_items ~maximum_bytes)(fun()->
    if Rrbvec.length page.items>maximum_items || Wire.recovery_page_bytes page>maximum_bytes
    then Error Response_budget_exceeded
    else if Option.exists(fun next->next<=0L || Rrbvec.is_empty page.items
      || Option.exists(fun previous->next<=previous.after)after)page.next
    then Error(Protocol_mismatch "Durable recovery continuation did not advance")
    else
      let decoded=Rrbvec.fold_left(fun result (item:Wire.recovery_item)->
        Result.bind result (fun(items,seen)->
          Result.bind(restore_mutation_intent session(Bytes.of_string item.intent))(fun intent->
            let id=Wire.mutation_id intent in
            if Mutation_ids.mem id seen then Error(Protocol_mismatch "Duplicate recovered intent identity") else
            Result.map(fun progress->Rrbvec.push_back items {intent;progress},Mutation_ids.add id seen)
              (decode_mutation_progress session ~request_id ~intent item.outcome))))
        (Ok(Rrbvec.empty,Mutation_ids.empty))page.items in
      Result.map(fun(items,_)->{items;next=Option.map(fun after->
        {recovery_owner=session;after;maximum_items;maximum_bytes})page.next})decoded)
;;

let compare_observation_epoch = Int64.compare
let observation_session value = value.observation_owner
let observation_id value = value.observation_key
let observation_budget value = value.observation_budget
let observation_query value = value.observation_query

let query_result_equality : type a b. a query -> b query -> (a, b) equality option =
  fun a b ->
  match a, b with
  | Graph_info, Graph_info -> Some Refl
  | Admission, Admission -> Some Refl
  | Journal _, Journal _ -> Some Refl
  | Journals _, Journals _ -> Some Refl
  | Page _, Page _ -> Some Refl
  | Outline_block _, Outline_block _ -> Some Refl
  | Block_summary _, Block_summary _ -> Some Refl
  | Children _, Children _ -> Some Refl
  | Child_members _, Child_members _ -> Some Refl
  | Tree _, Tree _ -> Some Refl
  | Favorites _, Favorites _ -> Some Refl
  | Task_statuses _, Task_statuses _ -> Some Refl
  | Task_status_definitions _, Task_status_definitions _ -> Some Refl
  | Asset_descriptors _, Asset_descriptors _ -> Some Refl
  | Assets _, Assets _ -> Some Refl
  | Changes _, Changes _ -> Some Refl
  | _ -> None
;;

let same_observation : type a b. a observation -> b observation -> (a, b) equality option =
  fun a b ->
  match query_result_equality a.observation_query b.observation_query with
  | Some Refl
    when equal_session a.observation_owner b.observation_owner
         && equal_request_id a.observation_key b.observation_key
         && a.observation_budget = b.observation_budget
         && a.observation_query = b.observation_query -> Some Refl
  | _ -> None
;;

let asset_consumer session ~name =
  if name = "" || String.length name > 128
  then Error (Invalid_input "Invalid asset consumer name")
  else Ok { session; name;round=None }
;;

let asset_consumer_session (c : asset_consumer) = c.session

let equal_asset_consumer (a : asset_consumer) (b : asset_consumer) =
  equal_session a.session b.session && a.name = b.name
;;

let asset_consumer_prefix (session:session) =
  let module Id=Logseq_db_worker_lui.Journal_worker_ids in
  Printf.sprintf "journal-asset/v1:%Ld:%Ld:%Ld:%d:%Ld:%s:%d:"
    (Id.Runtime.Epoch.to_int64 session.binding.incarnation.runtime_epoch)
    (Id.Worker.Generation.to_int64 session.binding.incarnation.worker_generation)
    session.binding.serial session.account session.lifecycle (Uuid.to_string session.graph) session.generation
let asset_consumer_key (consumer:asset_consumer)=asset_consumer_prefix consumer.session^consumer.name
let compare_asset_consumer a b=String.compare(asset_consumer_key a)(asset_consumer_key b)
let bind_asset_consumer consumer ~round={consumer with round=Some round}
let asset_consumer_round consumer=consumer.round
let asset_consumer_wire (consumer:asset_consumer)=match consumer.round with
  | Some round->Ok(asset_consumer_prefix consumer.session^Uuid.to_string round^":"^consumer.name)
  | None->Error(Invalid_input "Asset demand must use its pure registered round")
let decode_asset_consumer session wire =
  let prefix=asset_consumer_prefix session in
  if not(String.starts_with ~prefix wire) then Error Revoked_session else
    let suffix=String.sub wire(String.length prefix)(String.length wire-String.length prefix) in
    if String.length suffix<38 || suffix.[36]<>':' then Error(Protocol_mismatch "Asset demand round is absent") else
      match Uuid.of_string(String.sub suffix 0 36) with
      | Error _->Error(Protocol_mismatch "Asset demand round is invalid")
      | Ok round->Result.map(fun consumer->bind_asset_consumer consumer ~round)
          (asset_consumer session ~name:(String.sub suffix 37(String.length suffix-37)))

let asset_file_consumer (file:asset_file)=file.asset_consumer
let asset_file_asset (file:asset_file)=file.asset

let file_lease_session lease=lease.lease_owner
let file_lease_id lease=lease.lease_id
let imported_session imported=imported.import_owner
let file_path lease=lease.lease_path
let file_type lease=lease.lease_type
let import_data imported=imported.import_receipt
let import_preview imported=imported.import_preview
let import_source_proof imported=imported.source_proof
let import_source_proof_id proof=proof.source_operation
let without_import_preview imported={imported with import_preview=None;import_receipt={imported.import_receipt with preview=None}}

let import_namespace (session:session)=Wire.namespace_for_owner
  ~origin:(Uri.of_string session.binding.origin) ~user:session.binding.user ~graph:session.graph
let import_wire_error=function Import_wire.Invalid message->Invalid_input message|Wrong_namespace->Revoked_session
let asset_import_intent session source=Import_wire.create ~namespace:(import_namespace session) source |> Result.map_error import_wire_error
let asset_import_intent_id=Import_wire.operation
let encode_asset_import_intent intent=Bytes.of_string(Import_wire.encode intent)
let import_source_proof_matches intent proof=proof.source_operation=Import_wire.operation intent
  && proof.source_fingerprint=(Digestif.SHA256.digest_string(Import_wire.encode intent) |> Digestif.SHA256.to_hex)
let restore_asset_import_intent session bytes=Import_wire.restore ~namespace:(import_namespace session)(Bytes.to_string bytes)
  |> Result.map_error import_wire_error
;;

let asset_notice_session (x:asset_notice)=x.notice_owner

let asset_notice_data (x:asset_notice)=x.notice_data

let asset_notice_consumer (x:asset_notice)=x.notice_consumer

let ready_asset_file (x:asset_notice)=match x.notice_consumer,x.notice_data with
  | Some consumer,Service.Asset_availability{asset;availability=Ready handle;_}->
    Some{asset_owner=x.notice_owner;asset_consumer=consumer;asset;source_handle=handle}
  | _->None
;;

let upload_operation (x:asset_notice)=match x.notice_data with
  | Service.Upload_status{operation;_}->Some{upload_owner=x.notice_owner;operation}
  | _->None
;;

let compare_projection_version = Int64.compare
let projection_incarnation (p : projection) = p.binding.incarnation
let projection_binding (p : projection) = p.binding
let projection_version (p : projection) = p.version
let residents (p : projection) = p.residents
let selected (p : projection) = p.selected
let local_deletion (p : projection) = p.deletion
let equal_projection (a : projection) (b : projection) = a = b

let scope_is_superseded ?previous (p : projection) (owner : Service.timeline_scope) =
  let at_or_after (session : session) =
    session.account = owner.startup.account_generation
    && Uuid.equal session.graph owner.graph_id
    && session.generation >= owner.graph_generation
  in
  p.account > owner.startup.account_generation
  || (p.account = owner.startup.account_generation
      && List.exists
           (fun resident ->
              at_or_after resident.session
              && resident.session.generation > owner.graph_generation)
           p.residents)
  || Option.fold
       ~none:false
       ~some:(fun (old : projection) ->
         equal_binding old.binding p.binding
         && old.version < p.version
         && List.exists
              (fun resident ->
                 at_or_after resident.session
                 && not
                      (List.exists
                         (fun current -> equal_session current.session resident.session)
                         p.residents))
              old.residents)
       previous
;;

let removal_target = function
  | Removing (id, _, _) | Removal_failed (id, _, _, _) -> id
;;

let handoff_id id = id
let equal_handoff_id = Uuid.equal

let host_affected session = function
  |Account_will_change|Connection_will_stop->true
  |Graph_will_close id|Graph_will_remove(id,_)->Uuid.equal session.graph id
;;
let host_change_plan (projection:projection) ~handoff_id ~change ~sessions =
  let binding=projection.binding in
  let valid (session:session)=session.binding.incarnation=binding.incarnation
    && session.binding.origin=binding.origin && session.binding.user=binding.user
    && host_affected session change in
  if Rrbvec.length sessions>8192 || not(Rrbvec.fold_left(fun ok session->ok && valid session)true sessions)
  then Error(Invalid_input "The host plan contains a foreign or unbounded execution roster") else
  let change_wire=match change with
    |Graph_will_close id->Logseq_db_worker_pure_reducer.Core.Host_handoff.Close_graph id
    |Graph_will_remove(id,Ordinary)->Remove_graph(id,Normal)
    |Graph_will_remove(id,Force)->Remove_graph(id,Force)
    |Account_will_change->Replace_account|Connection_will_stop->Stop_connection in
  Ok{plan_binding=binding;plan_change=change;plan_sessions=sessions;
    plan_wire={version=projection.version;id=handoff_id;registration=binding.serial;
      owner=projection.host_owner;change=change_wire;expected=Rrbvec.map(fun session->session.asset_scope)sessions}}
;;
let handoff_plan_id plan=plan.plan_wire.id
let handoff_plan_change plan=plan.plan_change
let handoff_plan_binding plan=plan.plan_binding
let handoff_receipt_id receipt=receipt.host_plan.plan_wire.id
let handoff_binding receipt=receipt.host_plan.plan_binding
let handoff_sessions receipt=receipt.host_plan.plan_sessions
let handoff_change receipt=receipt.host_plan.plan_change
let handoff_pending _=[]
let valid_handoff_projection plan (projection:projection)=
  let expected=plan.plan_wire.owner and actual=projection.host_owner in
  equal_binding plan.plan_binding projection.binding
  && expected.user_id=actual.user_id && Uri.equal expected.managed_sync_origin actual.managed_sync_origin
  && expected.account_generation=actual.account_generation && expected.lifecycle_generation=actual.lifecycle_generation
  && List.for_all(fun(resident:resident)->not(host_affected resident.session plan.plan_change)
    || Rrbvec.fold_left(fun found session->found || equal_session session resident.session)false plan.plan_sessions)
      projection.residents
;;
let valid_handoff_receipt plan receipt=
  let module H=Logseq_db_worker_pure_reducer.Core.Host_handoff in
  let actual=H.receipt_request receipt.host_receipt in
  equal_binding plan.plan_binding receipt.host_plan.plan_binding
  && plan.plan_wire.id=actual.id && plan.plan_wire.registration=actual.registration
  && plan.plan_wire.version=actual.version && plan.plan_wire.change=actual.change
  && plan.plan_wire.owner=actual.owner
  && Rrbvec.length plan.plan_wire.expected=Rrbvec.length actual.expected
  && snd(Rrbvec.fold_left(fun(index,ok) scope->
    index+1,ok && scope=Rrbvec.nth actual.expected index)(0,true)plan.plan_wire.expected)
;;

let query_command
  : type a. read_budget -> a query -> Graph.Cursor.t option -> Protocol.command
  =
  fun budget query cursor ->
  let limit = budget.maximum_items in
  match query with
  | Graph_info -> V2_graph_info
  | Admission -> V2_inspect_admission
  | Journal day ->
    V2_list_journals
      { from_day = day; through_day = day; limit = 1; cursor = None; revision = None }
  | Journals { from_day; through_day; revision; _ } ->
    V2_list_journals { from_day; through_day; revision; limit; cursor }
  | Page { uuid; revision } -> V2_get_page { page = uuid; revision }
  | Outline_block { uuid; revision } -> V2_get_outline_block { block = uuid; revision }
  | Block_summary { block; _ } -> V2_get_outline_block_summary { block; limit; cursor }
  | Children { parent; _ } -> V2_get_children { parent; limit; cursor; revision = None }
  | Child_members { parent; revision; _ } ->
    V2_get_children { parent; limit; cursor; revision }
  | Tree { page; maximum_depth; revision; _ } ->
    V2_get_page_tree { page; maximum_depth; limit; cursor; revision }
  | Favorites _ -> V2_list_favorites { limit; cursor }
  | Task_statuses _ -> V2_list_task_statuses { limit; cursor }
  | Task_status_definitions statuses -> V2_get_task_status_definitions { statuses }
  | Asset_descriptors assets -> V2_get_asset_descriptors { assets }
  | Assets { recursive; roots; _ } -> V2_list_assets { recursive; roots; limit; cursor }
  | Changes { generation; after } -> V2_pull_changes { generation; after; limit }
;;

let dummy_id = Uuid.of_string "00000000-0000-4000-8000-000000000001" |> Result.get_ok

let query_key budget query =
  Protocol.request_to_yojson
    { api_version = Protocol.api_version
    ; request_id = dummy_id
    ; command = query_command budget query None
    }
  |> Yojson.Safe.to_string
;;

let checked_command
  : type a. session -> read_budget -> a query -> (Protocol.command, error) result
  =
  fun session budget query ->
  let key = query_key budget query in
  let check after =
    match after with
    | None -> Ok None
    | Some next
      when equal_session next.owner session
           && next.key = key
           && next.budget.maximum_items = budget.maximum_items
           && next.budget.maximum_bytes = budget.maximum_bytes -> Ok (Some next.cursor)
    | Some _ ->
      Error
        (Invalid_input "Continuation does not belong to this query, session and budget")
  in
  let cursor =
    match query with
    | Journals { after; _ } -> check after
    | Block_summary { after; _ } -> check after
    | Children { after; _ } -> check after
    | Child_members { after; _ } -> check after
    | Tree { after; _ } -> check after
    | Favorites after -> check after
    | Task_statuses after -> check after
    | Assets { after; _ } -> check after
    | _ -> Ok None
  in
  let count =
    match query with
    | Task_status_definitions ids -> List.length ids
    | Asset_descriptors ids -> List.length ids
    | _ -> 1
  in
  if not (equal_session budget.owner session)
  then Error Revoked_session
  else if count > budget.maximum_items
  then Error (Invalid_input "Lookup exceeds item budget")
  else Result.map (query_command budget query) cursor
;;

let supports_observation session query =
  let budget =
    { owner = session
    ; maximum_items = Protocol.maximum_page_size
    ; maximum_bytes = session.limits.response_budget_bytes
    }
  in
  match checked_command session budget query with
  | Ok command -> Protocol.is_observable_read command
  | Error _ -> false
;;

let rec validate_request : type a. session -> a request -> (unit, error) result =
  fun session -> function
  | Append intent ->
    if not(capabilities session).atomic_append then unavailable "Atomic Append"
    else Result.map(fun _->())(restore_append_intent session(encode_append_intent intent))
  | Import intent->Result.map(fun _->())(restore_asset_import_intent session(encode_asset_import_intent intent))
  | Acquire_imported_file imported->if equal_session session imported.import_owner then Ok() else Error Revoked_session
  | Release_file lease->if equal_session session lease.lease_owner then Ok() else Error Revoked_session
  | Mutate intent -> validate_intent session intent
  | Confirm (presentation, receipt) -> validate_confirmation session presentation receipt
  | Recover_mutations {after;maximum_items;maximum_bytes}->validate_recovery session ~after ~maximum_items ~maximum_bytes
  | Acknowledge_intent intent->validate_intent session intent
  | Observe (budget, query) ->
    if supports_observation session query
    then validate_request session (Query (budget, query))
    else unavailable "This observation query"
  | Refresh observation ->
    if not (equal_session session observation.observation_owner)
    then Error Revoked_session
    else
      validate_request
        session
        (Observe (observation.observation_budget, observation.observation_query))
  | Release observation ->
    if equal_session session observation.observation_owner
    then Ok ()
    else Error Revoked_session
  | Acknowledge_changes batch ->
    if equal_session session batch.change_owner then Ok () else Error Revoked_session
  | Replace_asset_demand(consumer,_,assets)->
    if not(equal_session session consumer.session) then Error Revoked_session
    else if List.length assets>Protocol.maximum_page_size
    then Error(Invalid_input "Asset demand exceeds the bounded member batch")
    else
      let limit=min session.limits.response_budget_bytes Protocol.maximum_response_bytes in
      let bytes=List.fold_left(fun bytes asset->if bytes>limit then bytes else
        bytes+1+String.length(Yojson.Safe.to_string(Logseq_db_types.Asset_descriptor.to_yojson asset)))2 assets in
      if bytes>limit then Error(Invalid_input "Asset demand exceeds the encoded payload bound") else Ok()
  | Release_asset_demand consumer->if equal_session session consumer.session then Ok() else Error Revoked_session
  | Retry_asset _->Ok()
  | Acquire_asset_file file->
    if not(equal_session session file.asset_owner) || not(equal_session session file.asset_consumer.session)
    then Error Revoked_session
    else if file.source_handle="" then Error(Protocol_mismatch "Ready asset omitted its file capability") else Ok()
  | Retry_upload operation->if equal_session session operation.upload_owner then Ok() else Error Revoked_session
  | Query (budget, query) ->
    Result.bind (checked_command session budget query) (fun command ->
      Protocol.request_of_yojson
        (Protocol.request_to_yojson
           { api_version = Protocol.api_version; request_id = dummy_id; command })
      |> Result.map (fun _ -> ())
      |> Result.map_error (fun error -> Db_error error))
  | _ -> .
;;

let decode
  : type a. session -> read_budget -> a query -> Protocol.v2_outcome -> (a, error) result
  =
  fun session budget query outcome ->
  let next cursor =
    Option.map
      (fun cursor -> { owner = session; budget; key = query_key budget query; cursor })
      cursor
  in
  let bounded items =
    if List.length items > budget.maximum_items
    then Error Response_budget_exceeded
    else Ok items
  in
  let mismatch () = Error (Protocol_mismatch "Response does not match the typed query") in
  let page_matches uuid = function
    | Protocol.V2_present_page { page; _ } -> Uuid.equal page.uuid uuid
    | V2_missing_page { uuid = actual; _ } -> Uuid.equal actual uuid
  in
  let block_matches uuid = function
    | Protocol.V2_present_block { value; _ } -> Uuid.equal value.block.uuid uuid
    | V2_missing_block { uuid = actual; _ } -> Uuid.equal actual uuid
  in
  match outcome with
  | Protocol.V2_failed { code; message } ->
    Error
      (if code = "staleReadCursor"
       then Stale_read (code ^ ": " ^ message)
       else if code = "responseTooLarge"
       then Response_budget_exceeded
       else Service_failed (code ^ ": " ^ message))
  | V2_resync_required { reason; _ } -> Error (Resync_required reason)
  | _ ->
    (match query, outcome with
     | Graph_info, Protocol.V2_graph_info_outcome i
       when Uuid.equal session.graph i.graph_uuid ->
       Ok
         { graph_uuid = i.graph_uuid
         ; graph_name = i.graph_name
         ; schema = i.schema
         ; admission_facts = i.admission_facts
         ; journal_title_format = i.journal_title_format
         ; limits = i.limits
         ; generation = i.generation
         ; projection_revision = i.projection_revision
         }
     | Admission, V2_admission_outcome inspection -> Ok inspection
     | Journal day, V2_journals_outcome { items; next_cursor = None } ->
       (match items with
        | [] -> Ok None
        | [ item ] when item.journal_day = day ->
          Ok (Some { data = item.page; revision = item.revision })
        | _ -> mismatch ())
     | Journals _, V2_journals_outcome { items; next_cursor } ->
       Result.map (fun items -> ({ items; next = next next_cursor } : _ slice)) (bounded items)
     | Page { uuid; _ }, V2_page_outcome lookup when page_matches uuid lookup -> Ok lookup
     | Outline_block { uuid; _ }, V2_block_outcome lookup when block_matches uuid lookup
       -> Ok lookup
     | Block_summary { block; _ }, V2_block_summary_outcome s
       when block_matches block s.lookup ->
       Result.map
         (fun items ->
            { lookup = s.lookup
            ; page = s.page
            ; items
            ; next = next s.next_cursor
            ; scope_revision = s.scope_revision
            ; generation = s.generation
            ; projection_revision = s.projection_revision
            })
         (bounded s.items)
     | Children { parent; _ }, V2_children_outcome c
       when Uuid.equal parent c.parent && c.revision_scope = V2_children_revision parent
       ->
       Result.map
         (fun items ->
            ({ items =
                List.map
                  (fun (i : Protocol.v2_child_member) ->
                     { data = i.value; revision = i.revision })
                  items
            ; next = next c.next_cursor
            } : block slice))
         (bounded c.items)
     | Child_members { parent; _ }, V2_children_outcome c
       when Uuid.equal parent c.parent && c.revision_scope = V2_children_revision parent
       ->
       Result.map
         (fun items ->
            { parent
            ; revision_scope = c.revision_scope
            ; scope_revision = c.scope_revision
            ; items
            ; next = next c.next_cursor
            })
         (bounded c.items)
     | Tree { page; maximum_depth; _ }, V2_page_tree_outcome t
       when Uuid.equal page t.page && maximum_depth = t.maximum_depth ->
       Result.map (fun items -> ({ items; next = next t.next_cursor } : _ slice)) (bounded t.items)
     | Favorites _, V2_favorites_outcome f ->
       Result.map
         (fun items ->
            { favorites_page = f.favorites_page
            ; generation = f.generation
            ; projection_revision = f.projection_revision
            ; items
            ; next = next f.next_cursor
            })
         (bounded f.items)
     | Task_statuses _, V2_task_statuses_outcome s ->
       Result.map
         (fun items ->
            { property_uuid = s.property_uuid
            ; default_status = s.default_status
            ; items
            ; next = next s.next_cursor
            })
         (bounded s.items)
     | Task_status_definitions ids, V2_task_status_definitions_outcome items
       when List.length ids = List.length items -> bounded items
     | Asset_descriptors _, V2_assets_outcome a when a.next_cursor = None ->
       Result.map
         (fun items ->
            { generation = a.generation
            ; projection_revision = a.projection_revision
            ; items
            ; next = None
            })
         (bounded a.items)
     | Assets _, V2_assets_outcome a ->
       Result.map
         (fun items ->
            { generation = a.generation
            ; projection_revision = a.projection_revision
            ; items
            ; next = next a.next_cursor
            })
         (bounded a.items)
     | Changes { generation; after }, V2_changes b
       when generation = b.generation && after = b.from_exclusive ->
       let rec chain seen previous = function
         | [] -> true
         | (window : Protocol.v2_change_window) :: rest ->
           window.id <> ""
           && window.predecessor <> ""
           && window.successor <> ""
           && (not (List.mem window.id seen))
           && Option.fold ~none:true ~some:(String.equal window.predecessor) previous
           && chain (window.id :: seen) (Some window.successor) rest
       in
       let through_matches =
         match List.rev b.windows with
         | last :: _ -> b.through = last.Protocol.id
         | [] -> Option.fold ~none:(b.through <> "") ~some:(String.equal b.through) after
       in
       if
         generation = ""
         || (not through_matches)
         || (not (chain [] None b.windows))
         ||
         match b.next with
         | None -> false
         | Some next -> next <> b.through || b.windows = []
       then Error (Protocol_mismatch "Changefeed window chain or continuation mismatch")
       else
         Result.map
           (fun windows ->
              { change_owner = session
              ; generation
              ; from_exclusive = b.from_exclusive
              ; through = b.through
              ; windows
              ; next = b.next
              })
           (bounded b.windows)
     | _ -> mismatch ())
;;

let decode_confirmation session ~presentation receipt response =
  Result.bind (validate_confirmation session presentation receipt) (fun () ->
    let budget =
      { owner = session
      ; maximum_items = Protocol.default_page_size
      ; maximum_bytes = session.limits.response_budget_bytes
      }
    in
    let response_size = Protocol.encoded_response_bytes response in
    if response_size > budget.maximum_bytes
    then Error Response_budget_exceeded
    else (
      match response with
      | Protocol.V2_response { api_version; outcome; _ }
        when api_version = Protocol.api_version ->
        let target =
          match Wire.command receipt.intent with
          | Protocol.V2_create_journal_page { page; _ } ->
            decode session budget (Page { uuid = page; revision = None }) outcome
            |> Result.map (fun page -> Confirmed_page page)
          | command ->
            let primary =
              match command with
              | Protocol.V2_append_journal{root;_}->root.block_id
              | Protocol.V2_insert_blocks { roots = root :: _; _ } -> root.uuid
              | V2_save_block { block; _ }
              | V2_set_task_status { block; _ }
              | V2_clear_task_status { block; _ }
              | V2_set_asset_reference { block; _ } -> block
              | V2_delete_blocks { root; _ } -> root
              | _ -> assert false
            in
            decode
              session
              budget
              (Block_summary { block = primary; after = None })
              outcome
            |> Result.map (fun summary ->
              match summary.lookup with
              | Protocol.V2_missing_block { uuid; revision } ->
                Confirmed_absence
                  { uuid
                  ; revision
                  ; generation = summary.generation
                  ; projection_revision = summary.projection_revision
                  }
              | _ -> Confirmed_block summary)
        in
        Result.map
          (fun primary -> { receipt; presentation; primary; additional = Rrbvec.empty })
          target
      | _ -> Error (Protocol_mismatch "Invalid canonical confirmation response")))
;;

let validate_baseline (b : Service.coordination_baseline) =
  let invalid message = Error (Protocol_mismatch message) in
  let state = b.baseline.state
  and limits = b.limits in
  let all_limits =
    [ limits.response_budget_bytes
    ; limits.outbox_max_records
    ; limits.outbox_max_bytes
    ; limits.change_max_items
    ; limits.change_max_bytes
    ; limits.dispatcher_capacity
    ; limits.wire_batch_max_bytes
    ]
  in
  let ids =
    List.map (fun ((scope : Service.asset_scope), _) -> scope.graph_id) state.residents
  in
  let distinct ids = List.length (List.sort_uniq Stdlib.compare ids) = List.length ids in
  let same_ids a b = List.sort Stdlib.compare a = List.sort Stdlib.compare b in
  if b.baseline.version < 0L || b.baseline.presentation < 0L
  then invalid "Negative baseline version"
  else if
    List.exists (fun n -> n <= 0) all_limits
    || limits.response_budget_bytes > Protocol.maximum_response_bytes
    || limits.wire_batch_max_bytes > limits.outbox_max_bytes
  then invalid "Invalid baseline capability limits"
  else if
    List.length ids > 3
    || (not (distinct ids))
    || (not (distinct state.sync.desired_residents))
    || not (same_ids ids state.sync.desired_residents)
  then invalid "Inconsistent resident identities"
  else if List.map fst state.sync.residents <> List.map fst state.residents
  then invalid "Resident phases do not share one snapshot"
  else (
    match state.sync.account with
    | None when ids <> [] || state.sync.selected <> None || state.sync.deletion <> None ->
      invalid "Resident authority without an account"
    | None -> Ok ()
    | Some account ->
      let account_matches (scope : Service.asset_scope) =
        scope.account.user_id = account.user_id
        && scope.account.account_generation = account.account_generation
        && Uri.equal scope.account.managed_sync_origin account.managed_sync_origin
      in
      if
        not
          (List.for_all
             (fun ((scope : Service.asset_scope), (graph : Logseq_db_worker.graph_state)) ->
                account_matches scope
                && scope.graph_generation = graph.generation
                &&
                match graph.graph_id, graph.phase with
                | None, Logseq_db_worker.Graph_closed -> true
                | Some id, _ -> Uuid.equal id scope.graph_id
                | _ -> false)
             state.residents)
      then invalid "Resident account or physical generation mismatch"
      else if
        not
          (Option.fold
             ~none:true
             ~some:(fun (owner : Service.timeline_scope) ->
               owner.startup.account_generation = account.account_generation
               && List.exists
                    (fun ((scope : Service.asset_scope), _) ->
                       owner.graph_id = scope.graph_id
                       && owner.graph_generation = scope.graph_generation)
                    state.residents)
             state.sync.selected)
      then invalid "Selection has no matching resident"
      else if
        not
          (Option.fold
             ~none:true
             ~some:(fun (scope, _) -> account_matches scope)
             state.sync.deletion)
      then invalid "Deletion belongs to another account"
      else Ok ())
;;

let next_binding = Atomic.make 0
let predecessors : (int64 * int64, bool ref) Hashtbl.t = Hashtbl.create 4

let issuer ~managed_origin ~user_id ~runtime_epoch ~worker_generation =
  let origin = Uri.of_string managed_origin in
  if
    user_id = ""
    || Uri.host origin = None
    || (not (List.mem (Uri.scheme origin) [ Some "https"; Some "http" ]))
    || Uri.userinfo origin <> None
  then Error (Invalid_input "A verified account and managed origin are required")
  else (
    let key =
      ( Logseq_db_worker_lui.Journal_worker_ids.Runtime.Epoch.to_int64 runtime_epoch
      , Logseq_db_worker_lui.Journal_worker_ids.Worker.Generation.to_int64
          worker_generation )
    in
    Option.iter (fun revoked -> revoked := true) (Hashtbl.find_opt predecessors key);
    let serial = Atomic.fetch_and_add next_binding 1 in
    if serial = max_int then failwith "Worker binding counter exhausted";
    let revoked = ref false in
    Hashtbl.replace predecessors key revoked;
    let binding =
      { serial = Int64.of_int (serial + 1)
      ; incarnation = worker_incarnation ~runtime_epoch ~worker_generation
      ; origin = managed_origin
      ; user = user_id
      }
    in
    let latest = ref None
    and last_seen = ref None
    and last_bootstrap = ref Awaiting_baseline in
    let module I = struct
      let binding = binding
      let revoke () = revoked := true
      let release_binding_request () = Ok (Service.Release_coordination binding.serial)

      let binding_released = function
        | Service.Coordination_released id when id = binding.serial ->
          if
            Option.fold
              ~none:false
              ~some:(fun other -> other == revoked)
              (Hashtbl.find_opt predecessors key)
          then Hashtbl.remove predecessors key;
          Ok ()
        | _ -> Error (Protocol_mismatch "Unexpected registration release ACK")
      ;;

      let handoff_request plan=
        if !revoked || not(equal_binding binding plan.plan_binding) then Error Revoked_session
        else Ok(Service.Coordination_prepare_host_change plan.plan_wire)
      let handoff_receipt plan=function
        |Service.Coordination_host_prepared actual when not !revoked
           && equal_binding binding plan.plan_binding->
          let receipt={host_plan=plan;host_receipt=actual} in
          if valid_handoff_receipt plan receipt then Ok receipt
          else Error(Protocol_mismatch "The physical handoff receipt does not match its immutable plan")
        |_->Error(Protocol_mismatch "Unexpected physical host handoff response")
      let consume_handoff_request receipt=
        if !revoked || not(equal_binding binding(handoff_binding receipt)) then Error Revoked_session
        else Ok(Service.Coordination_apply_host_change receipt.host_receipt)
      let handoff_consumed receipt=function
        |Service.Coordination_host_applied id when id=handoff_receipt_id receipt
           && equal_binding binding(handoff_binding receipt)->Ok()
        |_->Error(Protocol_mismatch "The host action did not acknowledge its exact consumed permission")

      let bootstrap_request () =
        if !revoked
        then Error Revoked_session
        else Ok (Service.Register_coordination binding.serial)
      ;;

      let bootstrap response =
        match response with
        | Service.Coordination_registered b when b.registration = binding.serial ->
          if !revoked
          then Ok (Binding_revoked Revoked_session)
          else if
            Option.fold
              ~none:false
              ~some:(fun version -> b.baseline.version < version)
              !last_seen
          then Ok !last_bootstrap
          else
            Result.bind (validate_baseline b) (fun () ->
              let result =
                match b.authority_user with
                | Some None ->
                  revoke ();
                  Ok (Binding_revoked Revoked_session)
                | Some (Some actual) when actual <> user_id ->
                  revoke ();
                  Ok (Binding_revoked Revoked_session)
                | _ ->
                  (match b.baseline.state.sync.account with
                   | None ->
                     if !latest = None
                     then
                       Ok (Bootstrap_not_ready "The local account has not been restored")
                     else (
                       revoke ();
                       Ok (Binding_revoked Revoked_session))
                   | Some account
                     when account.user_id <> user_id
                          || not (Uri.equal account.managed_sync_origin origin) ->
                     if !latest = None
                     then
                       Ok
                         (Bootstrap_not_ready "Waiting for the verified account baseline")
                     else (
                       revoke ();
                       Ok (Binding_revoked Revoked_session))
                   | Some account ->
                     let state = b.baseline.state in
                     if
                       List.length state.sync.desired_residents
                       <> List.length state.residents
                     then
                       Ok
                         (Bootstrap_not_ready "Waiting for resident lifecycle identities")
                     else if List.length state.residents > 3
                     then Error (Protocol_mismatch "Too many residents")
                     else if
                       b.limits.response_budget_bytes <= 0
                       || b.limits.response_budget_bytes > Protocol.maximum_response_bytes
                     then Error (Protocol_mismatch "Invalid baseline response limit")
                     else (
                       let residents =
                         List.map
                           (fun ( (scope : Service.asset_scope)
                                , (graph : Logseq_db_worker.graph_state) ) ->
                              let session =
                                { binding
                                ; graph = scope.graph_id
                                ; account = scope.account.account_generation
                                ; lifecycle = scope.account.lifecycle_generation
                                ; generation = scope.graph_generation
                                ; limits = b.limits
                                ; asset_scope = scope
                                ; scope =
                                    { startup =
                                        { account_generation =
                                            scope.account.account_generation
                                        ; presentation_generation =
                                            scope.account.presentation_generation
                                        }
                                    ; graph_id = scope.graph_id
                                    ; graph_generation = scope.graph_generation
                                    }
                                }
                              in
                              let phase =
                                match graph.phase with
                                | Logseq_db_worker.Graph_open -> Open
                                | Graph_opening -> Opening
                                | Graph_closed | Graph_closing -> Closing
                                | Graph_failed ->
                                  Failed
                                    (Option.fold
                                       ~none:(Service_failed "Graph failed")
                                       ~some:(fun e -> Db_error e)
                                       graph.error)
                              in
                              let network =
                                match Service.coordination_network b scope with
                                | Some (Service.Offline | Paused) | None -> Offline
                                | Some (Connecting | Pulling | Submitting) -> Connecting
                                | Some Current -> Current
                                | Some Failed ->
                                  Network_failed
                                    (Service_failed "Network synchronization failed")
                              in
                              { session; phase; network })
                           state.residents
                       in
                       let selected =
                         Option.bind
                           state.sync.selected
                           (fun (owner : Service.timeline_scope) ->
                              List.find_map
                                (fun r ->
                                   if
                                     r.session.graph = owner.graph_id
                                     && r.session.generation = owner.graph_generation
                                   then
                                     Some
                                       { session = r.session
                                       ; generation = b.baseline.presentation
                                       ; host_generation = owner.startup.presentation_generation
                                       }
                                   else None)
                                residents)
                       in
                       let deletion =
                         Option.map
                           (fun ((scope : Service.asset_scope), phase) ->
                              let stage = function
                                | Service.Closing_graph -> Closing_graph
                                | Deleting_mirror -> Deleting_local
                                | Clearing_selection -> Clearing_selection
                              in
                              match phase with
                              | Service.Deletion_in_progress s ->
                                Removing (scope.graph_id, Ordinary, stage s)
                              | Deletion_failed s ->
                                Removal_failed
                                  ( scope.graph_id
                                  , Ordinary
                                  , stage s
                                  , Service_failed "Local removal failed" ))
                           state.sync.deletion
                       in
                       let projection =
                         { binding
                         ; host_owner=account
                         ; account = account.account_generation
                         ; version = b.baseline.version
                         ; residents
                         ; selected
                         ; deletion
                         }
                       in
                       let projection =
                         match !latest with
                         | Some old when old.version > projection.version -> old
                         | _ -> projection
                       in
                       latest := Some projection;
                       ignore account;
                       Ok (Ready projection)))
              in
              Result.map
                (fun state ->
                   last_seen := Some b.baseline.version;
                   last_bootstrap := state;
                   state)
                result)
        | _ -> Error (Protocol_mismatch "Unexpected bootstrap response")
      ;;

      let projection ~previous:_ push =
        match push with
        | Service.Coordination_updates updates ->
          (match
             List.find_opt
               (function
                 | Service.Coordination_snapshot b -> b.registration = binding.serial
                 | Coordination_revoked (id, _) -> id = binding.serial)
               updates
           with
           | Some (Coordination_snapshot b) ->
             Result.bind (bootstrap (Service.Coordination_registered b)) (function
               | Ready p -> Ok p
               | Binding_revoked e | Bootstrap_failed e -> Error e
               | _ -> Error (Service_failed "Baseline not ready"))
           | Some (Coordination_revoked _) ->
             revoke ();
             Error Revoked_session
           | None -> Error (Protocol_mismatch "Unowned baseline update"))
        | _ -> Error (Protocol_mismatch "Not a baseline update")
      ;;

      let live (session : session) =
        (not !revoked)
        && equal_binding session.binding binding
        && Option.fold
             ~none:false
             ~some:(fun p ->
               List.exists
                 (fun r -> r.phase = Open && equal_session r.session session)
                 p.residents)
             !latest
      ;;

      let presentation_live (presentation : presentation) =
        live presentation.session
        && Option.fold
             ~none:false
             ~some:(fun projection -> projection.selected = Some presentation)
             !latest
      ;;

      let release_observation_registration (session : session) ~observation_id =
        if not (equal_binding session.binding binding)
        then Error Revoked_session
        else
          Ok
            (Service.Coordination_release_observation
               { registration = binding.serial; owner = session.scope; observation_id })
      ;;

      let observation_registration_released (session : session) ~observation_id = function
        | Service.Coordination_observation_released
            { registration; owner; observation_id = actual }
          when equal_binding session.binding binding
               && registration = binding.serial
               && matches_scope session owner
               && equal_request_id actual observation_id -> Ok ()
        | _ -> Error (Protocol_mismatch "Observation cleanup acknowledgement mismatch")
      ;;

      let observation_registration
        : type a.
          session
          -> request_id:request_id
          -> a observed request
          -> Service.response
          -> (a observation * observation_epoch, error) result
        =
        fun session ~request_id operation response ->
        let handle =
          match operation with
          | Observe (budget, query) ->
            Result.map
              (fun () ->
                 { observation_owner = session
                 ; observation_key = request_id
                 ; observation_budget = budget
                 ; observation_query = query
                 })
              (validate_request session operation)
          | Refresh observation ->
            Result.map (fun () -> observation) (validate_request session operation)
          | _ -> .
        in
        Result.bind handle (fun observation ->
          match response with
          | Service.Coordination_observed
              { registration
              ; owner
              ; observation_id
              ; epoch
              ; response = Protocol.V2_response raw
              }
            when equal_binding session.binding binding
                 && registration = binding.serial
                 && matches_scope session owner
                 && equal_request_id observation_id observation.observation_key
                 && raw.api_version = Protocol.api_version
                 && equal_request_id raw.request_id request_id
                 && epoch >= 0L -> Ok (observation, epoch)
          | _ ->
            Error
              (Protocol_mismatch "Observation registration/epoch/correlation mismatch"))
      ;;

      let observation session ~request_id observation response =
        if not (live session)
        then Error Revoked_session
        else
          Result.bind
            (observation_registration session ~request_id (Refresh observation) response)
            (fun (actual, epoch) ->
               match same_observation observation actual, response with
               | ( Some Refl
                 , Service.Coordination_observed
                     { response = Protocol.V2_response raw as packet; _ } ) ->
                 if
                   Protocol.encoded_response_bytes packet
                   > observation.observation_budget.maximum_bytes
                 then Error Response_budget_exceeded
                 else
                   Result.map
                     (fun value -> { observation; epoch; value })
                     (decode
                        session
                        observation.observation_budget
                        observation.observation_query
                        raw.outcome)
               | _ -> Error (Protocol_mismatch "Observation value owner mismatch"))
      ;;

      let observation_notices = function
        | Service.Coordination_observations values ->
          if Rrbvec.length values > 512
          then Error (Protocol_mismatch "Observation notice bound exceeded")
          else
            Rrbvec.fold_left
              (fun result signal ->
                 Result.bind result (fun notices ->
                   match signal with
                   | Service.Observations_resync ->
                     Ok (Rrbvec.push_back notices (Observations_resync binding))
                   | Observation_invalidated value
                     when value.registration_id <> binding.serial -> Ok notices
                   | Observation_invalidated value
                     when value.epoch < 0L
                          || value.owner.startup.account_generation < 0
                          || value.owner.graph_generation < 0 ->
                     Error (Protocol_mismatch "Invalid observation notice identity/epoch")
                   | Observation_invalidated value ->
                     Ok
                       (Rrbvec.push_back
                          notices
                          (Observation_invalidated
                             { binding
                             ; owner = value.owner
                             ; id = request_id value.observation_id
                             ; epoch = value.epoch
                             }))))
              (Ok Rrbvec.empty)
              values
        | _ -> Error (Protocol_mismatch "Not an observation notice batch")
      ;;

      let changefeed_notices = function
        | Service.Graph_pushes notices ->
          if List.length notices > 128
          then Error (Protocol_mismatch "Scoped change notice bound exceeded")
          else if !revoked
          then Ok Rrbvec.empty
          else (
            let residents = Option.fold ~none:[] ~some:(fun p -> p.residents) !latest in
            List.fold_left
              (fun result ((scope : Service.asset_scope), push) ->
                 Result.bind result (fun notices ->
                   let owner =
                     List.find_opt
                       (fun resident ->
                          let session = resident.session in
                          resident.phase = Open
                          && session.graph = scope.graph_id
                          && session.generation = scope.graph_generation
                          && session.account = scope.account.account_generation
                          && session.lifecycle = scope.account.lifecycle_generation
                          && binding.user = scope.account.user_id
                          && Uri.equal
                               (Uri.of_string binding.origin)
                               scope.account.managed_sync_origin)
                       residents
                   in
                   match owner with
                   | None -> Ok notices
                   | Some resident ->
                     let version =
                       match push with
                       | Protocol.V2_changes_available value -> value.api_version
                       | V2_resync_required_push value -> value.api_version
                     in
                     if version <> Protocol.api_version
                     then
                       Error
                         (Protocol_mismatch "Scoped change notice API version mismatch")
                     else
                       Ok
                         (Rrbvec.push_back
                            notices
                            { notice_session = resident.session; notice = push })))
              (Ok Rrbvec.empty)
              notices)
        | _ -> Ok Rrbvec.empty
      ;;

      let acknowledge_mutation_request session ~request_id ~(presentation:presentation) ~intent ~original =
        if not(live session && presentation_live presentation)
           || not(equal_session session presentation.session)
        then Error Revoked_session
        else Result.bind(validate_intent session intent)(fun()->
          let proof=match original with
            | None->Ok None
            | Some (receipt:receipt) when Wire.encode receipt.intent=Wire.encode intent->
              Result.map(fun()->Some(receipt_revisions receipt))(validate_confirmation session presentation receipt)
            | Some _->Error(Protocol_mismatch "Acknowledgement replaced the immutable intent") in
          Result.map(fun original->Service.Coordination_acknowledge_mutation
            {registration=binding.serial;owner=session.scope;presentation=presentation.generation;
             request_id;intent=Wire.encode intent;original})proof)
      ;;

      let request
        : type a.
          session -> request_id:request_id -> a request -> (Service.request, error) result
        =
        fun session ~request_id operation ->
        match operation with
        | Release_file lease->
          if not(equal_binding session.binding binding) || not(equal_session session lease.lease_owner)
          then Error Revoked_session else Ok(Service.Release_asset_file{scope=session.asset_scope;handle=lease.lease_handle})
        | Release_asset_demand consumer->
          if not(equal_binding session.binding binding) then Error Revoked_session else
          Result.bind(validate_request session operation)(fun()->
            Result.map(fun consumer->Service.Coordination_release_asset_demand
              {registration=binding.serial;owner=session.asset_scope;request_id;consumer})
              (asset_consumer_wire consumer))
        | Release observation ->
          Result.bind (validate_request session operation) (fun () ->
            release_observation_registration
              session
              ~observation_id:observation.observation_key)
        | _ ->
          if not (live session)
          then Error Revoked_session
          else (
            match operation with
            | Observe (budget, query) ->
              Result.bind (validate_request session operation) (fun () ->
                Result.map
                  (fun command ->
                     Service.Coordination_observe
                       { registration = binding.serial
                       ; owner = session.scope
                       ; observation_id = request_id
                       ; request =
                           { Protocol.api_version = Protocol.api_version
                           ; request_id
                           ; command
                           }
                       ; maximum_bytes = budget.maximum_bytes
                       })
                  (checked_command session budget query))
            | Refresh observation ->
              Result.map
                (fun () ->
                   Service.Coordination_refresh_observation
                     { registration = binding.serial
                     ; owner = session.scope
                     ; observation_id = observation.observation_key
                     ; request_id
                     })
                (validate_request session operation)
            | Query (budget, query) ->
              Result.bind (validate_request session operation) (fun () ->
                Result.bind (checked_command session budget query) (fun command ->
                  let request =
                    { Protocol.api_version = Protocol.api_version; request_id; command }
                  in
                  Protocol.request_of_yojson (Protocol.request_to_yojson request)
                  |> Result.map_error (fun e -> Db_error e)
                  |> Result.map (fun request ->
                    Service.Coordination_query
                      { registration = binding.serial
                      ; owner = session.scope
                      ; request
                      ; response_budget_bytes = budget.maximum_bytes
                      })))
            | Acknowledge_changes batch ->
              Result.map
                (fun () ->
                   Service.Coordination_query
                     { registration = binding.serial
                     ; owner = session.scope
                     ; response_budget_bytes = session.limits.response_budget_bytes
                     ; request =
                         { Protocol.api_version = Protocol.api_version
                         ; request_id
                         ; command =
                             Protocol.V2_ack_changes
                               { generation = batch.generation; through = batch.through }
                         }
                     })
                (validate_request session operation)
            | Confirm (presentation, receipt) ->
              if not (presentation_live presentation)
              then Error Revoked_session
              else
                Result.map
                  (fun () ->
                     Service.Coordination_confirm
                       { registration = binding.serial
                       ; owner = session.scope
                       ; presentation = presentation.generation
                       ; request_id
                       ; intent = Wire.encode receipt.intent
                       ; original = receipt_revisions receipt
                       })
                  (validate_confirmation session presentation receipt)
            | Mutate intent | Append intent ->
              Result.map
                (fun () ->
                   Service.Coordination_mutation
                     { registration = binding.serial
                     ; owner = session.scope
                     ; request_id
                     ; intent = Wire.encode intent
                     })
                (validate_intent session intent)
            | Import intent->Result.map(fun()->Service.Coordination_import{registration=binding.serial;owner=session.asset_scope;request_id;source=(Import_wire.source intent)})(validate_request session operation)
            | Acquire_imported_file imported->Result.map(fun()->Service.Acquire_imported_file{scope=session.asset_scope;operation=imported.import_receipt.operation})
                (validate_request session operation)
            | Replace_asset_demand(consumer,priority,assets)->
              Result.bind(validate_request session operation)(fun()->
              Result.map(fun consumer->Service.Coordination_asset_demand
                {registration=binding.serial;owner=session.scope;request_id;consumer;
                 priority=(match priority with Foreground->Service.Asset.Foreground|Background->Background);
                 assets})(asset_consumer_wire(bind_asset_consumer consumer ~round:request_id)))
            | Retry_asset asset->Ok(Service.Asset_command_at(session.scope,Retry_asset asset))
            | Retry_upload upload->Result.map(fun()->Service.Asset_command_at(session.scope,Retry_upload upload.operation))
                (validate_request session operation)
            | Recover_mutations {after;maximum_items;maximum_bytes}->
              Result.map(fun()->Service.Coordination_recover_mutations
                {registration=binding.serial;owner=session.scope;request_id;
                 after=Option.map(fun cursor->cursor.after)after;maximum_items;maximum_bytes})
                (validate_recovery session ~after ~maximum_items ~maximum_bytes)
            | _ -> unavailable "This operation's resource/durability")
      ;;

      let reply
        : type a.
          session
          -> request_id:request_id
          -> a request
          -> Service.response
          -> (a reply, error) result
        =
        fun session ~request_id operation response ->
        match operation with
        | Release_file lease->
          if not(equal_binding session.binding binding) || not(equal_session session lease.lease_owner) then Error Revoked_session else
          (match response with Service.Client_command_completed->Ok(Answered(Ok()))
           | _->Error(Protocol_mismatch "File release did not acknowledge actual checked release"))
        | Import intent->
          if not(equal_binding session.binding binding)
            || Result.is_error(restore_asset_import_intent session(encode_asset_import_intent intent))
          then Error Revoked_session else
          (match response with
           | Service.Coordination_imported{registration;owner;request_id=actual;result=Error message}
             when registration=binding.serial && actual=request_id && matches_asset_scope session owner->Ok(Answered(Error(Service_failed message)))
           | Service.Coordination_imported{registration;owner;request_id=actual;result=Ok receipt}
             when registration=binding.serial && actual=request_id && matches_asset_scope session owner && matches_asset_scope session receipt.scope
               && receipt.graph_generation=session.generation && receipt.operation=(Import_wire.source intent).operation
               && receipt.target=(Import_wire.source intent).target && receipt.asset.uuid=(Import_wire.source intent).asset
               && receipt.file_type=(Import_wire.source intent).file_type && receipt.asset.current_checksum<>None->
             let preview=Option.map(fun(handle,path)->{lease_owner=session;lease_id=request_id;lease_handle=handle;lease_path=path;lease_type=receipt.file_type})receipt.preview in
             if Option.exists(fun lease->lease.lease_handle="" || lease.lease_path="")preview
             then Error(Protocol_mismatch "Imported preview omitted its acquired file capability") else
             Ok(Answered(Ok(Imported{import_owner=session;import_receipt=receipt;import_preview=preview;
               source_proof={source_operation=(Import_wire.source intent).operation;
                 source_fingerprint=(Digestif.SHA256.digest_string (Import_wire.encode intent) |> Digestif.SHA256.to_hex)}})))
           | _->Error(Protocol_mismatch "Import receipt changed its exact owner or immutable identity"))
        | Acquire_imported_file imported->
          if not(equal_binding session.binding binding) || not(equal_session session imported.import_owner) then Error Revoked_session else
          (match response with
           | Service.Asset_file None->Ok(Answered(Ok None))
           | Service.Asset_file(Some(handle,path)) when handle<>"" && path<>""->
             Ok(Answered(Ok(Some{lease_owner=session;lease_id=request_id;lease_handle=handle;lease_path=path;lease_type=imported.import_receipt.file_type})))
           | _->Error(Protocol_mismatch "Imported acquire omitted its actual lease capability"))
        | Release_asset_demand consumer->
          if not(equal_binding session.binding binding)
             || not(equal_asset_consumer consumer {consumer with session}) then Error Revoked_session else
          (match response,asset_consumer_wire consumer with
           | Service.Coordination_asset_demand_released value,Ok expected
             when value.registration=binding.serial && value.request_id=request_id
               && value.consumer=expected && matches_asset_scope session value.owner->Ok(Answered(Ok()))
           | _->Error(Protocol_mismatch "Asset cleanup did not acknowledge actual scoped settlement"))
        | Release observation ->
          observation_registration_released
            session
            ~observation_id:observation.observation_key
            response
          |> Result.map (fun () -> Answered (Ok ()))
        | _ ->
          if not (live session)
          then Error Revoked_session
          else (
            match operation, response with
            | Observe _, _ ->
              Result.map
                (fun (handle, _) ->
                   Answered (observation session ~request_id handle response))
                (observation_registration session ~request_id operation response)
            | Refresh _, _ ->
              Result.map
                (fun (handle, _) ->
                   Answered (observation session ~request_id handle response))
                (observation_registration session ~request_id operation response)
            | Replace_asset_demand _,Service.Coordination_asset_demand_accepted value
              when value.request_id=request_id->Ok(Answered(Ok()))
            | Retry_asset _,Service.Client_command_completed->Ok(Answered(Ok()))
            | Retry_upload _,Service.Client_command_completed->Ok(Answered(Ok()))
            | ( Query (budget, query)
              , Service.Graph_response (Protocol.V2_response r as response) )
              when r.api_version = Protocol.api_version
                   && Uuid.equal request_id r.request_id ->
              if
                String.length
                  (Yojson.Safe.to_string (Protocol.response_to_yojson response))
                > budget.maximum_bytes
              then Ok (Answered (Error Response_budget_exceeded))
              else Ok (Answered (decode session budget query r.outcome))
            | ( Acknowledge_changes batch
              , Service.Graph_response (Protocol.V2_response raw as packet) )
              when raw.api_version = Protocol.api_version
                   && equal_request_id raw.request_id request_id
                   && equal_session session batch.change_owner ->
              if
                Protocol.encoded_response_bytes packet
                > session.limits.response_budget_bytes
              then Ok (Answered (Error Response_budget_exceeded))
              else (
                match raw.outcome with
                | Protocol.V2_changes_acknowledged ack
                  when ack.generation = batch.generation && ack.through = batch.through ->
                  Ok
                    (Answered
                       (Ok
                          { ack_owner = session
                          ; generation = ack.generation
                          ; through = ack.through
                          }))
                | V2_resync_required { reason; _ } ->
                  Ok (Answered (Error (Resync_required reason)))
                | V2_failed { code; message } ->
                  Ok (Answered (Error (Service_failed (code ^ ": " ^ message))))
                | _ ->
                  Error
                    (Protocol_mismatch "Changefeed ACK owner/generation/window mismatch"))
            | ( Confirm (presentation, receipt)
              , Service.Graph_response (Protocol.V2_response response as raw) )
              when response.api_version = Protocol.api_version
                   && Uuid.equal response.request_id request_id ->
              if not (presentation_live presentation)
              then Error Revoked_session
              else
                decode_confirmation session ~presentation receipt raw
                |> Result.map (fun confirmation -> Answered (Ok (Confirmed confirmation)))
            | (Recover_mutations {after;maximum_items;maximum_bytes},
               Service.Coordination_mutations_recovered{request_id=actual;page})
              when Uuid.equal actual request_id->
              decode_recovery session ~request_id ~after ~maximum_items ~maximum_bytes page
              |> Result.map(fun page->Answered(Ok page))
            | Acknowledge_intent _,Service.Coordination_mutation_acknowledged{request_id=actual}
              when Uuid.equal actual request_id->Ok(Answered(Ok()))
            | ( Mutate intent
              , Service.Coordination_mutation_result { request_id = actual; outcome } )
              when Uuid.equal request_id actual ->
              decode_mutation_progress session ~request_id ~intent outcome
              |> Result.map(fun progress->Answered(Ok progress))
            | ( Append intent
              , Service.Coordination_mutation_result { request_id = actual; outcome } )
              when Uuid.equal request_id actual ->
              decode_mutation_progress session ~request_id ~intent outcome
              |> Result.map(fun progress->Answered(Ok progress))
            | _ -> Error (Protocol_mismatch "Unexpected owned query receipt"))
      ;;

      let receipt session ~request_id ~intent response = decode_mutation_receipt session ~request_id ~intent response
      let mutation_receipt = decode_mutation_receipt

      let confirmation session ~presentation receipt response =
        if not (presentation_live presentation)
        then Error Revoked_session
        else decode_confirmation session ~presentation receipt response
      ;;

      let asset_notice session data =
        if not(live session) then Error Revoked_session else
        let consumer wire make=Result.map(fun consumer->
          {notice_owner=session;notice_consumer=Some consumer;notice_data=make consumer.name})
          (decode_asset_consumer session wire) in
        match data with
        | Service.Asset_availability value->consumer value.consumer(fun name->
            Service.Asset_availability{value with consumer=name})
        | Asset_demand_accepted wire->consumer wire(fun name->Service.Asset_demand_accepted name)
        | Asset_backpressure wire->consumer wire(fun name->Service.Asset_backpressure name)
        | Asset_capacity_available|Upload_status _->
          Ok{notice_owner=session;notice_consumer=None;notice_data=data}
    end
    in
    Ok (module I : ISSUER))
;;
