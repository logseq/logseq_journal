module Protocol = Logseq_db_worker.Protocol
module Wire = Logseq_db_worker_contract.Mutation_pure_wire
module Service = Logseq_db_worker_lui.Logseq_db_worker_lui_service
module Import_wire=Logseq_db_types.Asset_import.Pure_intent

include Worker_pure_read

type request_id = Uuid.t
let request_id id = id
let equal_request_id = Uuid.equal
let compare_request_id = Uuid.compare

type presentation_generation = int64

type presentation =
  { session : session
  ; generation : presentation_generation
  ; host_generation : int
  }

type capabilities =
  { limits : Worker_pure_data.capability_limits
  ; atomic_append : bool
  ; durable_mutations : bool
  ; durable_import : bool
  ; observations : bool
  }

type append_intent = Wire.t

type mutation_command =
  | Save_block of
      { block : Uuid.t
      ; title : string
      ; preconditions : Worker_pure_data.preconditions
      }
  | Insert_blocks of
      { parent : Uuid.t
      ; roots : Worker_pure_data.block_tree list
      ; preconditions : Worker_pure_data.preconditions
      }
  | Delete_blocks of
      { root : Uuid.t
      ; preconditions : Worker_pure_data.preconditions
      }
  | Create_journal of
      { page : Uuid.t
      ; day : journal_day
      ; title : string
      ; preconditions : Worker_pure_data.preconditions
      }
  | Set_task_status of
      { block : Uuid.t
      ; status : Uuid.t
      ; preconditions : Worker_pure_data.preconditions
      }
  | Clear_task_status of
      { block : Uuid.t
      ; preconditions : Worker_pure_data.preconditions
      }
  | Set_asset_reference of
      { block : Uuid.t
      ; previous : Uuid.t option
      ; asset : Uuid.t
      ; preconditions : Worker_pure_data.preconditions
      }

type mutation_intent = Wire.t

type durable_intent =
  | Append_intent of append_intent
  | Mutation_intent of mutation_intent

let durable_wire = function Append_intent intent | Mutation_intent intent -> intent

type receipt =
  { intent : durable_intent
  ; generation : string
  ; before : string
  ; after : string
  }

type confirmed_target =
  | Confirmed_block of block_summary
  | Confirmed_page of Worker_pure_data.page_lookup
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
type recovered_mutation = { intent : durable_intent; progress : mutation_progress }
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
  ; notice : Worker_pure_data.changefeed_signal
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

type asset_file = { asset_owner:session; asset_consumer:asset_consumer; asset:Uuid.t; descriptor:Logseq_db_types.Asset_descriptor.t; source_handle:string }
type file_lease = {lease_owner:session;lease_id:request_id;lease_handle:string;lease_path:string;lease_type:string}
type upload_operation = { upload_owner:session; operation:Uuid.t }
type import_source_proof={source_operation:Uuid.t;source_fingerprint:string}
type imported = {import_owner:session;import_receipt:Logseq_db_worker.import_receipt;import_preview:file_lease option;source_proof:import_source_proof}
type asset_import_intent = Import_wire.t

type prepared_import_source={prepared_owner:session;prepared_intent:asset_import_intent;original_prepared:string;adoption:import_source_proof}
type recovered_import_input={intent:asset_import_intent;prepared:prepared_import_source option;acknowledged:bool}
type import_input_recovery_cursor={input_owner:session;input_after:int64;input_maximum_items:int;input_maximum_bytes:int}
type import_input_recovery={inputs:recovered_import_input Rrbvec.t;continuation:import_input_recovery_cursor option}

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
  | Acknowledge_intent : durable_intent -> unit request
  | Acknowledge_changes : change_batch -> change_ack request
  | Import : asset_import_intent -> import_progress request
  | Recover_import_inputs : {after:import_input_recovery_cursor option;maximum_items:int;maximum_bytes:int} -> import_input_recovery request
  | Confirm_import_source : asset_import_intent -> recovered_import_input option request
  | Acknowledge_import_source : prepared_import_source -> unit request

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
  ; account : int
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

let presentation_generation (p : presentation) = p.generation
let presentation_session (p : presentation) = p.session
let presentation_matches_scope (presentation:presentation) (scope:Service.timeline_scope) =
  matches_scope presentation.session scope
  && presentation.host_generation=scope.startup.presentation_generation
;;

let capabilities (s : session) =
  { limits = (For_worker.session_limits s)
  ; atomic_append = true
  ; durable_mutations = true
  ; durable_import = true
  ; observations = true
  }
;;

let unavailable feature =
  Error (Unsupported_operation (feature ^ " backend guarantee is not available"))
;;

let append_intent (session:session) ~mutation_id ~block_id ~day ~title ~task_status ~children =
  let root:Worker_pure_data.append_node={block_id;title;task_status;children} in
  if not(Worker_pure_data.valid_append_node root) then Error(Invalid_input "Invalid bounded Append tree")
  else
    let day=For_worker.journal_day_value day in
    let digits=Printf.sprintf "%08d" day in
    let page=Uuid.of_string(Printf.sprintf "00000001-%s-%s-0000-000000000000"
      (String.sub digits 0 4)(String.sub digits 4 4)) |> Result.get_ok in
    Wire.create ~origin:(Uri.of_string (For_worker.binding_origin (For_worker.session_binding session))) ~user:(For_worker.binding_user (For_worker.session_binding session)) ~graph:(graph_id session)
      (Protocol.V2_append_journal{mutation_id;page;journal_day=day;root})
    |> Result.map_error(fun message->Invalid_input message)
;;

let append_intent_id = Wire.mutation_id

let wire_command ~mutation_id = function
  | Save_block { block; title; preconditions } ->
    Protocol.V2_save_block { mutation_id; block; title; preconditions }
  | Insert_blocks { parent; roots; preconditions } ->
    Protocol.V2_insert_blocks { mutation_id; parent; roots; preconditions }
  | Delete_blocks { root; preconditions } ->
    Protocol.V2_delete_blocks { mutation_id; root; preconditions }
  | Create_journal { page; day; title; preconditions } ->
    Protocol.V2_create_journal_page
      { mutation_id; page; journal_day = For_worker.journal_day_value day; title; preconditions }
  | Set_task_status { block; status; preconditions } ->
    Protocol.V2_set_task_status { mutation_id; block; status; preconditions }
  | Clear_task_status { block; preconditions } ->
    Protocol.V2_clear_task_status { mutation_id; block; preconditions }
  | Set_asset_reference { block; previous; asset; preconditions } ->
    Protocol.V2_set_asset_reference { mutation_id; block; previous; asset; preconditions }
;;

let mutation_intent (session : session) ~mutation_id command =
  Wire.create
    ~origin:(Uri.of_string (For_worker.binding_origin (For_worker.session_binding session)))
    ~user:(For_worker.binding_user (For_worker.session_binding session))
    ~graph:(graph_id session)
    (wire_command ~mutation_id command)
  |> Result.map_error (fun message -> Invalid_input message)
;;

let mutation_intent_id = Wire.mutation_id
let durable_intent_id intent = Wire.mutation_id (durable_wire intent)
let encode_durable_intent intent = Bytes.of_string (Wire.encode (durable_wire intent))
let restore_durable_intent (session : session) bytes =
  Wire.restore
    ~origin:(Uri.of_string (For_worker.binding_origin (For_worker.session_binding session)))
    ~user:(For_worker.binding_user (For_worker.session_binding session))
    ~graph:(graph_id session)
    (Bytes.to_string bytes)
  |> Result.map (fun intent -> match Wire.command intent with
    | Protocol.V2_append_journal _ -> Append_intent intent
    | _ -> Mutation_intent intent)
  |> Result.map_error (fun message -> Invalid_input message)
;;

let validate_intent (session:session) intent =
  let namespace=Wire.namespace_for_owner ~origin:(Uri.of_string (For_worker.binding_origin (For_worker.session_binding session)))
    ~user:(For_worker.binding_user (For_worker.session_binding session)) ~graph:(graph_id session) in
  if String.equal namespace (Wire.namespace(durable_wire intent)) then Ok ()
  else Error(Invalid_input "Durable intent belongs to another logical graph")
;;

let receipt_intent (receipt:receipt) = receipt.intent
let receipt_mutation_id (receipt:receipt) = durable_intent_id receipt.intent
let receipt_revisions receipt = receipt.generation, receipt.before, receipt.after
let receipt_targets (receipt:receipt) = Wire.targets (durable_wire receipt.intent)

let decode_mutation_receipt session ~request_id ~intent response =
  Result.bind (validate_intent session intent) (fun () ->
    if Protocol.encoded_response_bytes response > (For_worker.session_limits session).response_budget_bytes
    then Error Response_budget_exceeded
    else
      Wire.committed_point (durable_wire intent) ~request_id response
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
      if Protocol.encoded_response_bytes response>(For_worker.session_limits session).response_budget_bytes
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

let decode_recovery session ~request_id ~after ~maximum_items ~maximum_bytes (page:Wire.recovery_page) : (mutation_recovery,error)result =
  Result.bind(validate_recovery session ~after ~maximum_items ~maximum_bytes)(fun()->
    if Rrbvec.length page.items>maximum_items || Wire.recovery_page_bytes page>maximum_bytes
    then Error Response_budget_exceeded
    else if Option.exists(fun next->next<=0L || Rrbvec.is_empty page.items
      || Option.exists(fun previous->next<=previous.after)after)page.next
    then Error(Protocol_mismatch "Durable recovery continuation did not advance")
    else
      let decoded=Rrbvec.fold_left(fun result (item:Wire.recovery_item)->
        Result.bind result (fun(items,seen)->
          Result.bind(restore_durable_intent session(Bytes.of_string item.intent))(fun intent->
            let id=durable_intent_id intent in
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
  let module Id=Journal_worker_ids in
  Printf.sprintf "journal-asset/v1:%Ld:%Ld:%Ld:%d:%Ld:%s:%d:"
    (Id.Runtime.Epoch.to_int64 (For_worker.worker_incarnation_runtime_epoch (binding_incarnation (For_worker.session_binding session))))
    (Id.Worker.Generation.to_int64 (For_worker.worker_incarnation_worker_generation (binding_incarnation (For_worker.session_binding session))))
    (For_worker.binding_serial (For_worker.session_binding session)) (For_worker.session_account session) (For_worker.session_lifecycle session) (Uuid.to_string (graph_id session)) (For_worker.session_generation session)
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
  ~origin:(Uri.of_string (For_worker.binding_origin (For_worker.session_binding session))) ~user:(For_worker.binding_user (For_worker.session_binding session)) ~graph:(graph_id session)
let import_wire_error=function Import_wire.Invalid message->Invalid_input message|Wrong_namespace->Revoked_session
let asset_import_intent session source=Import_wire.create ~namespace:(import_namespace session) source |> Result.map_error import_wire_error
let asset_import_intent_id=Import_wire.operation
let asset_import_title intent=(Import_wire.source intent).title
let encode_asset_import_intent intent=Bytes.of_string(Import_wire.encode intent)
let import_source_proof_matches intent proof=proof.source_operation=Import_wire.operation intent
  && proof.source_fingerprint=(Digestif.SHA256.digest_string(Import_wire.encode intent) |> Digestif.SHA256.to_hex)
let restore_asset_import_intent session bytes=Import_wire.restore ~namespace:(import_namespace session)(Bytes.to_string bytes)
  |> Result.map_error import_wire_error
;;

let asset_notice_session (x:asset_notice)=x.notice_owner
let changefeed_notice_scope (x:changefeed_notice)=(For_worker.session_asset_scope x.notice_session)
let asset_notice_scope (x:asset_notice)=(For_worker.session_asset_scope x.notice_owner)

let asset_notice_data (x:asset_notice)=x.notice_data

let asset_notice_consumer (x:asset_notice)=x.notice_consumer

let ready_asset_file (x:asset_notice)=match x.notice_consumer,x.notice_data with
  | Some consumer,Service.Asset_availability{asset;descriptor;availability=Ready handle;_}->
    Some{asset_owner=x.notice_owner;asset_consumer=consumer;asset;descriptor;source_handle=handle}
  | _->None
;;

let upload_operation (x:asset_notice)=match x.notice_data with
  | Service.Upload_status{operation;_}->Some{upload_owner=x.notice_owner;operation}
  | _->None
;;

let compare_projection_version = Int64.compare
let projection_incarnation (p : projection) = (binding_incarnation p.binding)
let projection_binding (p : projection) = p.binding
let projection_version (p : projection) = p.version
let residents (p : projection) = p.residents
let selected (p : projection) = p.selected
let local_deletion (p : projection) = p.deletion
let equal_projection (a : projection) (b : projection) = a = b

let scope_is_superseded ?previous (p : projection) (owner : Service.timeline_scope) =
  let at_or_after (session : session) =
    (For_worker.session_account session) = owner.startup.account_generation
    && Uuid.equal (graph_id session) owner.graph_id
    && (For_worker.session_generation session) >= owner.graph_generation
  in
  p.account > owner.startup.account_generation
  || (p.account = owner.startup.account_generation
      && List.exists
           (fun resident ->
              at_or_after resident.session
              && (For_worker.session_generation resident.session) > owner.graph_generation)
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
  |Graph_will_close id|Graph_will_remove(id,_)->Uuid.equal (graph_id session) id
;;
let host_change_plan (projection:projection) ~handoff_id ~change ~sessions =
  let binding=projection.binding in
  let valid (session:session)=(binding_incarnation (For_worker.session_binding session))=(binding_incarnation binding)
    && (For_worker.binding_origin (For_worker.session_binding session))=(For_worker.binding_origin binding) && (For_worker.binding_user (For_worker.session_binding session))=(For_worker.binding_user binding)
    && host_affected session change in
  if Rrbvec.length sessions>8192 || not(Rrbvec.fold_left(fun ok session->ok && valid session)true sessions)
  then Error(Invalid_input "The host plan contains a foreign or unbounded execution roster") else
  let change_wire=match change with
    |Graph_will_close id->Logseq_db_worker_pure_reducer.Core.Host_handoff.Close_graph id
    |Graph_will_remove(id,Ordinary)->Remove_graph(id,Normal)
    |Graph_will_remove(id,Force)->Remove_graph(id,Force)
    |Account_will_change->Replace_account|Connection_will_stop->Stop_connection in
  Ok{plan_binding=binding;plan_change=change;plan_sessions=sessions;
    plan_wire={version=projection.version;id=handoff_id;registration=(For_worker.binding_serial binding);
      owner=projection.host_owner;change=change_wire;expected=Rrbvec.map(fun session->(For_worker.session_asset_scope session))sessions}}
;;
let handoff_plan_id plan=plan.plan_wire.id
let handoff_plan_change plan=plan.plan_change
let handoff_plan_binding plan=plan.plan_binding
let handoff_plan_sessions plan=plan.plan_sessions
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
  let limit = (For_worker.read_budget_maximum_items budget) in
  match query with
  | Graph_info -> V2_graph_info
  | Admission -> V2_inspect_admission
  | Journal day ->
    V2_list_journals
      { from_day = For_worker.journal_day_value day; through_day = For_worker.journal_day_value day; limit = 1; cursor = None; revision = None }
  | Journals { from_day; through_day; revision; _ } ->
    V2_list_journals { from_day=For_worker.journal_day_value from_day; through_day=For_worker.journal_day_value through_day; revision; limit; cursor }
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
      when equal_session (For_worker.continuation_owner next) session
           && (For_worker.continuation_key next) = key
           && (For_worker.read_budget_maximum_items (For_worker.continuation_budget next)) = (For_worker.read_budget_maximum_items budget)
           && (For_worker.read_budget_maximum_bytes (For_worker.continuation_budget next)) = (For_worker.read_budget_maximum_bytes budget) -> Ok (Some (For_worker.continuation_cursor next))
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
  if not (equal_session (For_worker.read_budget_owner budget) session)
  then Error Revoked_session
  else if count > (For_worker.read_budget_maximum_items budget)
  then Error (Invalid_input "Lookup exceeds item budget")
  else Result.map (query_command budget query) cursor
;;

let supports_observation session query =
  let budget =
    (For_worker.read_budget ~owner:(session) ~maximum_items:(Worker_pure_data.maximum_page_size) ~maximum_bytes:((For_worker.session_limits session).response_budget_bytes))
  in
  match checked_command session budget query with
  | Ok command -> Protocol.is_observable_read command
  | Error _ -> false
;;

let equal_prepared_import_source a b=equal_session a.prepared_owner b.prepared_owner
  && Import_wire.encode a.prepared_intent=Import_wire.encode b.prepared_intent && a.original_prepared=b.original_prepared
let prepared_import_intent proof=proof.prepared_intent
let prepared_import_source_session proof=proof.prepared_owner
let prepared_import_adoption proof=proof.adoption
let import_input_wire_owner (session:session) : Logseq_db_types.Asset_import.Recovery.owner =
  {namespace=import_namespace session;origin=(For_worker.binding_origin (For_worker.session_binding session));account=(For_worker.binding_user (For_worker.session_binding session));graph=(graph_id session)}
;;
let validate_import_recovery session ~after ~maximum_items ~maximum_bytes =
  let module R=Logseq_db_types.Asset_import.Recovery in
  if maximum_items<1 || maximum_items>R.maximum_items || maximum_bytes<R.maximum_page_overhead || maximum_bytes>R.maximum_bytes
  then Error(Invalid_input "Invalid complete import input recovery budget") else
  match after with
  |None->Ok()
  |Some cursor when not(equal_session session cursor.input_owner)->Error Revoked_session
  |Some cursor when cursor.input_maximum_items<>maximum_items || cursor.input_maximum_bytes<>maximum_bytes->
    Error(Stale_read "Import input cursor budgets changed")
  |Some _->Ok()
;;
let decode_import_source session (row:Logseq_db_types.Asset_import.Recovery.item) =
  Result.map(fun(value:Logseq_db_types.Asset_import.Recovery.checked)->
    let prepared=Option.map(fun original_prepared->{prepared_owner=session;prepared_intent=value.input;original_prepared;
      adoption={source_operation=Import_wire.operation value.input;
        source_fingerprint=(Digestif.SHA256.digest_string(Import_wire.encode value.input) |> Digestif.SHA256.to_hex)}})value.evidence in
    ({intent=value.input;prepared;acknowledged=value.acknowledged}:recovered_import_input))
    (Logseq_db_types.Asset_import.Recovery.decode ~owner:(import_input_wire_owner session)row
     |> Result.map_error(fun message->Protocol_mismatch message))
;;
let decode_import_recovery session ~after ~maximum_items ~maximum_bytes (page:Logseq_db_types.Asset_import.Recovery.page) : (import_input_recovery,error)result =
  let module R=Logseq_db_types.Asset_import.Recovery in
  Result.bind(validate_import_recovery session ~after ~maximum_items ~maximum_bytes)(fun()->
    if List.compare_length_with page.items maximum_items>0 || R.page_encoded_bytes page>maximum_bytes
    then Error(Protocol_mismatch "Import input recovery exceeded its declared bounds") else
    let previous=Option.fold ~none:0L ~some:(fun cursor->cursor.input_after)after in
    let module Operations=Set.Make(Uuid) in
    let rec decode previous seen reversed=function
      |[]->
        if page.next<>None && (reversed=[] || page.next<>Some previous)
        then Error(Protocol_mismatch "Import input recovery continuation did not advance from its last item")
        else Ok{inputs=Rrbvec.of_list(List.rev reversed);continuation=Option.map(fun input_after->
          {input_owner=session;input_after;input_maximum_items=maximum_items;input_maximum_bytes=maximum_bytes})page.next}
      |(row:R.item)::rest->
        if row.R.sequence<=previous || row.acknowledged then Error(Protocol_mismatch "Import recovery order or pending membership is invalid") else
        Result.bind(decode_import_source session row)(fun value->
          let id=Import_wire.operation value.intent in
          if Operations.mem id seen then Error(Protocol_mismatch "Duplicate recovered complete import operation")
          else decode row.sequence(Operations.add id seen)(value::reversed)rest) in
    decode previous Operations.empty [] page.items)
;;

let rec validate_request : type a. session -> a request -> (unit, error) result =
  fun session -> function
  | Append intent ->
    if not(capabilities session).atomic_append then unavailable "Atomic Append"
    else validate_intent session (Append_intent intent)
  | Import intent|Confirm_import_source intent->Result.map(fun _->())(restore_asset_import_intent session(encode_asset_import_intent intent))
  | Recover_import_inputs{after;maximum_items;maximum_bytes}->validate_import_recovery session ~after ~maximum_items ~maximum_bytes
  | Acknowledge_import_source proof->if equal_session session proof.prepared_owner
      then Result.map(fun _->())(restore_asset_import_intent session(encode_asset_import_intent proof.prepared_intent))
      else Error Revoked_session
  | Acquire_imported_file imported->if equal_session session imported.import_owner then Ok() else Error Revoked_session
  | Release_file lease->if equal_session session lease.lease_owner then Ok() else Error Revoked_session
  | Mutate intent -> validate_intent session (Mutation_intent intent)
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
    else if List.length assets>Worker_pure_data.maximum_page_size
    then Error(Invalid_input "Asset demand exceeds the bounded member batch")
    else
      let limit=min (For_worker.session_limits session).response_budget_bytes Worker_pure_data.maximum_response_bytes in
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
      (fun cursor -> (For_worker.continuation ~owner:(session) ~budget ~key:(query_key budget query) ~cursor))
      cursor
  in
  let bounded items =
    if List.length items > (For_worker.read_budget_maximum_items budget)
    then Error Response_budget_exceeded
    else Ok items
  in
  let mismatch () = Error (Protocol_mismatch "Response does not match the typed query") in
  let page_matches uuid = function
    | Worker_pure_data.V2_present_page { page; _ } -> Uuid.equal page.uuid uuid
    | Worker_pure_data.V2_missing_page { uuid = actual; _ } -> Uuid.equal actual uuid
  in
  let block_matches uuid = function
    | Worker_pure_data.V2_present_block { value; _ } -> Uuid.equal value.block.uuid uuid
    | Worker_pure_data.V2_missing_block { uuid = actual; _ } -> Uuid.equal actual uuid
  in
  match outcome with
  | Protocol.V2_failed { code; message } ->
    Error
      (if code = "staleReadCursor"
       then Stale_read message
       else match Logseq_db_worker.Error.code_of_string code with
         | Some code ->
           (match Logseq_db_worker.Error.create ~code ~message ~details:[] with
            | Ok error -> Db_error error
            | Error _ -> Invalid_input "The query failure was not a valid database error.")
         | None -> Service_failed (code ^ ": " ^ message))
  | V2_resync_required { reason; _ } -> Error (Resync_required reason)
  | _ ->
    (match query, outcome with
     | Graph_info, Protocol.V2_graph_info_outcome i
       when Uuid.equal (graph_id session) i.graph_uuid ->
       Ok
         (For_worker.graph_info ~graph_uuid:(i.graph_uuid) ~graph_name:(i.graph_name) ~schema:(i.schema) ~admission_facts:(i.admission_facts) ~journal_title_format:(i.journal_title_format) ~limits:(i.limits) ~generation:(i.generation) ~projection_revision:(i.projection_revision))
     | Admission, V2_admission_outcome inspection -> Ok inspection
     | Journal day, V2_journals_outcome { items; next_cursor = None } ->
       (match items with
        | [] -> Ok None
        | [ item ] when item.journal_day = For_worker.journal_day_value day ->
          Ok (Some (For_worker.page ~data:(item.page) ~revision:(item.revision)))
        | _ -> mismatch ())
     | Journals _, V2_journals_outcome { items; next_cursor } ->
       Result.map (fun items -> ((For_worker.slice ~items ~next:(next next_cursor)) : _ slice)) (bounded items)
     | Page { uuid; _ }, V2_page_outcome lookup when page_matches uuid lookup -> Ok lookup
     | Outline_block { uuid; _ }, V2_block_outcome lookup when block_matches uuid lookup
       -> Ok lookup
     | Block_summary { block; _ }, V2_block_summary_outcome s
       when block_matches block s.lookup ->
       Result.map
         (fun items ->
            (For_worker.block_summary ~lookup:(s.lookup) ~page:(s.page) ~items ~next:(next s.next_cursor) ~scope_revision:(s.scope_revision) ~generation:(s.generation) ~projection_revision:(s.projection_revision)))
         (bounded s.items)
     | Children { parent; _ }, V2_children_outcome c
       when Uuid.equal parent c.parent && c.revision_scope = Worker_pure_data.V2_children_revision parent
       ->
       Result.map
         (fun items ->
            ((For_worker.slice ~items:(List.map
                  (fun (i : Worker_pure_data.child_member) ->
                     (For_worker.block ~data:(i.value) ~revision:(i.revision)))
                  items) ~next:(next c.next_cursor)) : block slice))
         (bounded c.items)
     | Child_members { parent; _ }, V2_children_outcome c
       when Uuid.equal parent c.parent && c.revision_scope = Worker_pure_data.V2_children_revision parent
       ->
       Result.map
         (fun items ->
            (For_worker.children ~parent ~revision_scope:(c.revision_scope) ~scope_revision:(c.scope_revision) ~items ~next:(next c.next_cursor)))
         (bounded c.items)
     | Tree { page; maximum_depth; _ }, V2_page_tree_outcome t
       when Uuid.equal page t.page && maximum_depth = t.maximum_depth ->
       Result.map (fun items -> ((For_worker.slice ~items ~next:(next t.next_cursor)) : _ slice)) (bounded t.items)
     | Favorites _, V2_favorites_outcome f ->
       Result.map
         (fun items ->
            (For_worker.favorites ~favorites_page:(f.favorites_page) ~generation:(f.generation) ~projection_revision:(f.projection_revision) ~items ~next:(next f.next_cursor)))
         (bounded f.items)
     | Task_statuses _, V2_task_statuses_outcome s ->
       Result.map
         (fun items ->
            (For_worker.task_status_catalog ~property_uuid:(s.property_uuid) ~default_status:(s.default_status) ~items ~next:(next s.next_cursor)))
         (bounded s.items)
     | Task_status_definitions ids, V2_task_status_definitions_outcome items
       when List.length ids = List.length items -> bounded items
     | Asset_descriptors _, V2_assets_outcome a when a.next_cursor = None ->
       Result.map
         (fun items ->
            (For_worker.asset_listing ~generation:(a.generation) ~projection_revision:(a.projection_revision) ~items ~next:(None)))
         (bounded a.items)
     | Assets _, V2_assets_outcome a ->
       Result.map
         (fun items ->
            (For_worker.asset_listing ~generation:(a.generation) ~projection_revision:(a.projection_revision) ~items ~next:(next a.next_cursor)))
         (bounded a.items)
     | Changes { generation; after }, V2_changes b
       when generation = b.generation && after = b.from_exclusive ->
       let rec chain seen previous = function
         | [] -> true
         | (window : Worker_pure_data.change_window) :: rest ->
           window.id <> ""
           && window.predecessor <> ""
           && window.successor <> ""
           && (not (List.mem window.id seen))
           && Option.fold ~none:true ~some:(String.equal window.predecessor) previous
           && chain (window.id :: seen) (Some window.successor) rest
       in
       let through_matches =
         match List.rev b.windows with
         | last :: _ -> b.through = last.Worker_pure_data.id
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
              (For_worker.change_batch ~change_owner:(session) ~generation ~from_exclusive:(b.from_exclusive) ~through:(b.through) ~windows ~next:(b.next)))
           (bounded b.windows)
     | _ -> mismatch ())
;;

let decode_confirmation session ~presentation receipt response =
  Result.bind (validate_confirmation session presentation receipt) (fun () ->
    let budget =
      (For_worker.read_budget ~owner:(session) ~maximum_items:(Worker_pure_data.default_page_size) ~maximum_bytes:((For_worker.session_limits session).response_budget_bytes))
    in
    let response_size = Protocol.encoded_response_bytes response in
    if response_size > (For_worker.read_budget_maximum_bytes budget)
    then Error Response_budget_exceeded
    else (
      match response with
      | Protocol.V2_response { api_version; outcome; _ }
        when api_version = Protocol.api_version ->
        let target =
          match Wire.command (durable_wire receipt.intent) with
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
              | Worker_pure_data.V2_missing_block { uuid; revision } ->
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
    || limits.response_budget_bytes > Worker_pure_data.maximum_response_bytes
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

