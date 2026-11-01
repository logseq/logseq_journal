module Graph = Logseq_db_types.Graph_types
module Uuid = Graph.Uuid
module Protocol = Logseq_db_worker.Protocol
module Wire = Logseq_db_worker_contract.Mutation_pure_wire
module Service = Logseq_db_worker_lui.Logseq_db_worker_lui_service

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
  ; generation : graph_generation
  ; scope : Service.timeline_scope
  ; limits : Protocol.v2_capability_limits
  }

type presentation =
  { session : session
  ; generation : presentation_generation
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
  { generation : string
  ; from_exclusive : string option
  ; through : string
  ; windows : Protocol.v2_change_window list
  ; next : string option
  }

type change_ack =
  { generation : string
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

type capture_node =
  { block_id : Uuid.t
  ; title : string
  ; task_status : Uuid.t option
  ; children : capture_node Rrbvec.t
  }

type append_intent = |

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
  }

type asset_file = |
type file_lease = |
type upload_operation = |
type imported = |
type asset_import_intent = |

type import_progress =
  | Import_rejected of error
  | Import_unknown
  | Imported of imported

type asset_priority =
  | Foreground
  | Background

type asset_notice = |

type _ request =
  | Query : read_budget * 'a query -> 'a request
  | Observe : read_budget * 'a query -> 'a observed request
  | Refresh : 'a observation -> 'a observed request
  | Release : 'a observation -> unit request
  | Append : append_intent -> mutation_progress request
  | Mutate : mutation_intent -> mutation_progress request
  | Confirm : presentation * receipt -> mutation_progress request
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
type handoff_receipt = |

type handoff_state =
  | Quiescing of host_change
  | Safe_to_proceed of handoff_receipt
  | Handoff_failed of host_change * error

module type ISSUER = sig
  val binding : binding
  val revoke : unit -> unit
  val release_binding_request : unit -> (Service.request, error) result
  val binding_released : Service.response -> (unit, error) result

  val handoff_request
    :  handoff_id:handoff_id
    -> host_change
    -> (Service.request, error) result

  val handoff_receipt
    :  handoff_id:handoff_id
    -> host_change
    -> Service.response
    -> (handoff_receipt, error) result

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
  && a.generation = b.generation
  && Uuid.equal a.graph b.graph
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

let worker_incarnation ~runtime_epoch ~worker_generation =
  { runtime_epoch; worker_generation }
;;

let request_id id = id
let equal_request_id = Uuid.equal
let compare_request_id = Uuid.compare

let capabilities (s : session) =
  { limits = s.limits
  ; atomic_append = false
  ; durable_mutations = true
  ; durable_import = false
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
let change_ack_generation (a : change_ack) = a.generation
let change_ack_through (a : change_ack) = a.through

let unavailable feature =
  Error (Unsupported_operation (feature ^ " backend guarantee is not available"))
;;

let append_intent _ ~mutation_id:_ ~block_id:_ ~day:_ ~title:_ ~task_status:_ ~children:_ =
  unavailable "Atomic Append"
;;

let append_intent_id (x : append_intent) =
  match x with
  | _ -> .
;;

let encode_append_intent (x : append_intent) =
  match x with
  | _ -> .
;;

let restore_append_intent _ _ = unavailable "Atomic Append recovery"

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

let receipt_intent receipt = receipt.intent
let receipt_mutation_id receipt = Wire.mutation_id receipt.intent
let receipt_revisions receipt = receipt.generation, receipt.before, receipt.after
let receipt_targets receipt = Wire.targets receipt.intent

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

let validate_confirmation session (presentation : presentation) receipt =
  if not (equal_session session presentation.session)
  then Error Revoked_session
  else validate_intent session receipt.intent
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
  else Ok { session; name }
;;

let asset_consumer_session (c : asset_consumer) = c.session

let equal_asset_consumer (a : asset_consumer) (b : asset_consumer) =
  equal_session a.session b.session && a.name = b.name
;;

let file_lease_session (x : file_lease) =
  match x with
  | _ -> .
;;

let imported_session (x : imported) =
  match x with
  | _ -> .
;;

let file_path (x : file_lease) =
  match x with
  | _ -> .
;;

let file_type (x : file_lease) =
  match x with
  | _ -> .
;;

let import_data (x : imported) =
  match x with
  | _ -> .
;;

let import_preview (x : imported) =
  match x with
  | _ -> .
;;

let asset_import_intent _ _ = unavailable "Durable import recovery"

let asset_import_intent_id (x : asset_import_intent) =
  match x with
  | _ -> .
;;

let encode_asset_import_intent (x : asset_import_intent) =
  match x with
  | _ -> .
;;

let restore_asset_import_intent _ _ = unavailable "Durable import recovery"

let asset_notice_session (x : asset_notice) =
  match x with
  | _ -> .
;;

let asset_notice_data (x : asset_notice) =
  match x with
  | _ -> .
;;

let asset_notice_consumer (x : asset_notice) =
  match x with
  | _ -> .
;;

let ready_asset_file (x : asset_notice) =
  match x with
  | _ -> .
;;

let upload_operation (x : asset_notice) =
  match x with
  | _ -> .
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

let handoff_receipt_id (x : handoff_receipt) =
  match x with
  | _ -> .
;;

let handoff_binding (x : handoff_receipt) =
  match x with
  | _ -> .
;;

let handoff_sessions (x : handoff_receipt) =
  match x with
  | _ -> .
;;

let handoff_change (x : handoff_receipt) =
  match x with
  | _ -> .
;;

let handoff_pending (x : handoff_receipt) =
  match x with
  | _ -> .
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
  | Mutate intent -> validate_intent session intent
  | Confirm (presentation, receipt) -> validate_confirmation session presentation receipt
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
  | Query (_, Changes _) -> unavailable "Changefeed ownership transfer"
  | Query (budget, query) ->
    Result.bind (checked_command session budget query) (fun command ->
      Protocol.request_of_yojson
        (Protocol.request_to_yojson
           { api_version = Protocol.api_version; request_id = dummy_id; command })
      |> Result.map (fun _ -> ())
      |> Result.map_error (fun error -> Db_error error))
  | _ -> unavailable "This operation's resource/durability"
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
       Result.map (fun items -> { items; next = next next_cursor }) (bounded items)
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
            { items =
                List.map
                  (fun (i : Protocol.v2_child_member) ->
                     { data = i.value; revision = i.revision })
                  items
            ; next = next c.next_cursor
            })
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
       Result.map (fun items -> { items; next = next t.next_cursor }) (bounded t.items)
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
       Result.map
         (fun windows ->
            { generation
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

      let handoff_request ~handoff_id:_ _ = unavailable "Writer and local-copy fencing"
      let handoff_receipt ~handoff_id:_ _ _ = unavailable "Writer and local-copy fencing"

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
                                ; generation = scope.graph_generation
                                ; limits = b.limits
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

      let request
        : type a.
          session -> request_id:request_id -> a request -> (Service.request, error) result
        =
        fun session ~request_id operation ->
        match operation with
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
            | Mutate intent ->
              Result.map
                (fun () ->
                   Service.Coordination_mutation
                     { registration = binding.serial
                     ; owner = session.scope
                     ; request_id
                     ; intent = Wire.encode intent
                     })
                (validate_intent session intent)
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
            | ( Confirm (presentation, receipt)
              , Service.Graph_response (Protocol.V2_response response as raw) )
              when response.api_version = Protocol.api_version
                   && Uuid.equal response.request_id request_id ->
              if not (presentation_live presentation)
              then Error Revoked_session
              else
                decode_confirmation session ~presentation receipt raw
                |> Result.map (fun confirmation -> Answered (Ok (Confirmed confirmation)))
            | ( Mutate intent
              , Service.Coordination_mutation_result { request_id = actual; outcome } )
              when Uuid.equal request_id actual ->
              (match outcome with
               | Wire.Unknown -> Ok (Answered (Ok Outcome_unknown))
               | Wire.Committed response ->
                 decode_mutation_receipt session ~request_id ~intent response
                 |> Result.map (fun receipt ->
                   Answered (Ok (Committed_pending_presentation receipt)))
               | Wire.Rejected
                   (Protocol.V2_response
                      { api_version
                      ; request_id = actual
                      ; outcome = V2_failed { code; message }
                      })
                 when api_version = Protocol.api_version && Uuid.equal actual request_id
                 -> Ok (Answered (Ok (Rejected (Service_failed (code ^ ": " ^ message)))))
               | _ -> Error (Protocol_mismatch "Invalid known mutation rejection"))
            | _ -> Error (Protocol_mismatch "Unexpected owned query receipt"))
      ;;

      let receipt _ ~request_id:_ ~intent:_ _ = unavailable "Atomic Append receipt"
      let mutation_receipt = decode_mutation_receipt

      let confirmation session ~presentation receipt response =
        if not (presentation_live presentation)
        then Error Revoked_session
        else decode_confirmation session ~presentation receipt response
      ;;

      let asset_notice _ _ = unavailable "Asset resource/notification ownership"
    end
    in
    Ok (module I : ISSUER))
;;
