type worker_failure =
  { operation : string
  ; request_id : Logseq_db_types.Graph_types.Uuid.t
  ; error : Logseq_db_worker.Error.t
  }

type failure_source =
  | Worker_failure of worker_failure
  | Projection_failure of string

type mutation_kind =
  | Capture_mutation
  | Status_mutation
  | Delete_subtree_mutation

type payload =
  | Child_projection_ready of
      { root : Logseq_db_types.Graph_types.Uuid.t; round : int64;
        command : Journal_graph_projection.create_child;
        presentation : Journal_worker_coordination.Worker_api.presentation;
        result : payload; failure : Journal_worker_coordination.Worker_api.error option }
  | Child_not_admitted of {command:Journal_graph_projection.create_child;message:string}
  | Child_waiting of {command:Journal_graph_projection.create_child;message:string}
  | Child_projection_settled of
      { command : Journal_graph_projection.create_child; presentation : Journal_worker_coordination.Worker_api.presentation option; result : payload;
        failure : Journal_worker_coordination.Worker_api.error option; insert_rejected : bool }
  | Capture_projection_ready of
      {root:Logseq_db_types.Graph_types.Uuid.t;round:int64;command:Journal_graph_projection.capture;
       presentation:Journal_worker_coordination.Worker_api.presentation;result:payload;
       failure:Journal_worker_coordination.Worker_api.error option}
  | Capture_not_admitted of {command:Journal_graph_projection.capture;message:string}
  | Capture_waiting of {command:Journal_graph_projection.capture;message:string}
  | Capture_projection_settled of
      {command:Journal_graph_projection.capture;presentation:Journal_worker_coordination.Worker_api.presentation option;
       result:payload;failure:Journal_worker_coordination.Worker_api.error option;insert_rejected:bool}
  | Mutation_settled of Journal_worker_coordination.Worker_api.durable_intent * Journal_worker_coordination.Worker_api.presentation * payload
  | Mutation_waiting of { mutation_id:string; block_id:string; message:string }
  | Projection_changes of Worker_pure_data.change_window list
  | Projection_resync
  | Task_statuses_changed of
      { items : Logseq_db_types.Graph_types.task_status_definition Rrbvec.t
      ; default_status : Logseq_db_types.Graph_types.Uuid.t option
      ; complete : bool
      ; error : string option
      }
  | Reference_sources_changed of (string * string option) list
  | Favorites_loaded of
      Journal_graph_request.favorites_request
      * Journal_worker_coordination.Worker_api.favorites
  | Favorites_failed of Journal_graph_request.favorites_request * bool * string
  | Favorites_invalidated
  | Graph_ready
  | Admission_inspected of
      { request : Journal_graph_request.admission_request
      ; observation : Worker_pure_data.admission_inspection
      }
  | Admission_unavailable of Journal_graph_request.admission_request
  | Block_captured of
      { block : Journal_graph_projection.block
      ; timeline_entry_update : Journal_graph_projection.timeline_entry option
      }
  | Child_failed of
      { mutation_id : string
      ; block_id : string
      ; failure : failure_source
      }
  | Child_created of
      { child : Journal_graph_projection.block
      ; parent : Journal_graph_projection.block
      ; timeline_entry_update : Journal_graph_projection.timeline_entry option
      }
  | Block_updated of
      { block : Journal_graph_projection.block
      ; timeline_entry_update : Journal_graph_projection.timeline_entry option
      }
  | Block_removed of { block_id : string }
  | Block_observed_missing of { block_id : string }
  | Page_tree_reconciled of
      { page : Journal_graph_projection.page
      ; value : Journal_graph_projection.timeline_entry_page
      }
  | Projection_unavailable of [ `Detail_calendar | `Detail_time | `Detail ]
  | Children_reconciled of Journal_graph_projection.detail
  | Update_conflict of {block:Journal_graph_projection.block;timeline_entry_update:Journal_graph_projection.timeline_entry option}
  | Subtree_deleted of
      { block_id : string
      ; deleted_count : int option (* None: committed, exact subtree cardinality unavailable. *)
      ; parent : Journal_graph_projection.block option
      ; timeline_entry_update : Journal_graph_projection.timeline_entry option
      }
  | Delete_conflict of {block:Journal_graph_projection.block;timeline_entry_update:Journal_graph_projection.timeline_entry option}
  | Delete_reappeared of {block:Journal_graph_projection.block;timeline_entry_update:Journal_graph_projection.timeline_entry option}
  | Block_found of Journal_graph_projection.block option
  | Feed_refresh_started of { request_generation : int64 }
  | Feed_loaded of
      { request_generation : int64
      ; feed : Journal_graph_projection.feed
      ; complete : bool
      }
  | Day_blocks_failed of
      { day : int
      ; request_generation : int64
      ; stale_cursor : bool
      ; failure : failure_source
      }
  | Detail_loaded of
      { request_generation : int64
      ; detail : Journal_graph_projection.detail
      }
  | Detail_failed of
      { request_generation : int64
      ; block_id : string
      ; missing : bool
      ; stale_cursor : bool
      ; failure : failure_source
      }
  | Feed_failed of
      { request_generation : int64
      ; failure : failure_source
      }
  | Open_failed of worker_failure
  | Mutation_failed of
      { kind : mutation_kind
      ; mutation_id : string
      ; block_id : string
      ; failure : failure_source
      }
  | Diagnostic of worker_failure
  | Rejected of failure_source

type response = { payload : payload }
type t

type output =
  { requests : Logseq_db_types.Graph_types.Uuid.t list
  ; responses : response list
  }

(** The host supplies the pure coordinator's current session/owner eligibility
    check for buffered Tree DTOs. Its default rejects execution provenance; tests
    can supply an explicit pure coordinator snapshot. *)
val create : ?on_change:(Journal_worker_coordination.Worker_pure_coordinator.event -> unit) -> ?on_projection_changes:(Worker_pure_data.change_window list -> unit) -> ?localtime:(float -> Unix.tm) -> ?validate_session:(Journal_worker_coordination.Worker_api.session -> (unit, Journal_worker_coordination.Worker_api.error) result) -> unit -> t
val reset : t -> unit
(** Retire absent Timeline ownership before interpreting further completions.
    Deliver the returned output: surviving reads may need a replacement check.
    Removed reads release their business payloads and retire change consumers. *)
val retire_timeline : t -> before:Journal_timeline_state.t -> after:Journal_timeline_state.t -> output
val set_calendar : t -> Journal_calendar.t -> unit
val start : t -> Logseq_db_types.Graph_types.Uuid.t
val submit : ?capture_chain:Journal_graph_mutation_confirmation.Pure_insertion.t ->
  ?child_chain:Journal_graph_mutation_confirmation.Pure_insertion.t -> t -> Journal_graph_request.t -> output
val fail_request : ?error:Logseq_db_worker.Error.t -> t -> Logseq_db_types.Graph_types.Uuid.t -> message:string -> output
val abandon : t -> Logseq_db_types.Graph_types.Uuid.t -> unit

val reconcile_signal
  :  t
  -> request_generation:int64
  -> Worker_pure_data.changefeed_signal
  -> output


module Worker = Journal_worker_coordination.Worker_api

type worker_read_result =
  | Query_result : 'a Worker.query * 'a -> worker_read_result
  | Read_failed of { code : Logseq_db_worker.Error.code; message : string }
  | Read_error of Logseq_db_worker.Error.t
  | Changes_resync of string
  | Changes_retired
  | Changes_acknowledged of Worker.change_ack

type worker_read =
  | Confirm_readback of {intent:Worker.durable_intent;presentation:Worker.presentation;query:Worker.block_summary Worker.query}
  | Read :
      { query : 'a Worker.query
      ; maximum_items : int
      }
      -> worker_read
  | Acknowledge of {batch:Worker.change_batch}

(** Business DTO interoperability. Favorites keeps its sealed continuation in
    the business operation/result; ordinary Worker transport IDs remain solely
    with the coordinator. No raw continuation extraction or cursor registry. *)
val worker_read : t -> Logseq_db_types.Graph_types.Uuid.t -> worker_read option

(** The token only associates a business request with its pure application
    ledger. It never grants a new session or advances the ACK chain. *)
val application_for_request : t -> request_id:Worker.Uuid.t -> Journal_worker_coordination.Worker_pure_coordinator.change_application option
val set_change_application : t -> request_id:Worker.Uuid.t -> Journal_worker_coordination.Worker_pure_coordinator.change_application -> bool

val receive_worker_read : ?resync_generation:int64 -> ?origin:(Worker.session * Worker.read_budget) -> t -> request_id:Worker.Uuid.t -> worker_read_result -> output

(** Called at business planning time, including queued reads. The active Changes
    delivery supplies the exact causal token; no latest-application inference. *)
val register_external_read : t -> request_id:Worker.Uuid.t -> unit

(** Retire an explicitly discarded business read, also removing an expansion
    which has not yet been emitted. This grants no transport/resource release. *)
val retire_external_read : t -> request_id:Worker.Uuid.t -> unit

(** Collect actual descendant reads while applying this request's DTO. The host
    publishes applied/failed only after its resulting UI projection commits. *)
val with_external_read : t -> request_id:Worker.Uuid.t -> f:(unit -> 'a)
  -> 'a * Journal_worker_coordination.Worker_pure_coordinator.change_application option

(** Shared DTO observers may plan external reads before the business reducer
    consumes this same request. Preserve those descendants for its one expansion. *)
val with_read_projection : t -> request_id:Worker.Uuid.t -> f:(unit -> 'a) -> 'a

(** Record an actual failed business interest in the currently delivering batch.
    A later successful parent completion cannot erase this failure. *)
val report_projection_failure : t -> Worker.error -> unit

(** Explicit business Retry only. Re-read the same owned failed batch through the
    existing Changes path; no synthetic notice, cursor advancement or ACK. *)
val retry_failed_change_application : t
  -> view:Journal_worker_coordination.Worker_pure_coordinator.view
  -> request_generation:int64 -> output

val worker_intent : t -> Worker.Uuid.t -> Worker.session ->
  (Worker.durable_intent, Worker.error) result
val bind_mutation : t -> Logseq_db_types.Graph_types.Uuid.t ->
  presentation:Journal_worker_coordination.Worker_api.presentation ->
  intent:Journal_worker_coordination.Worker_api.durable_intent -> bool
val pending_mutation : t -> mutation_id:string -> Logseq_db_types.Graph_types.Uuid.t option
val mutation_waiting : t -> Logseq_db_types.Graph_types.Uuid.t -> string -> output
val receive_mutation : t -> Logseq_db_types.Graph_types.Uuid.t ->
  Journal_worker_coordination.Worker_api.mutation_progress -> output

val mutation_presentation : t -> Logseq_db_types.Graph_types.Uuid.t ->
  Journal_worker_coordination.Worker_api.presentation option

val acknowledge_mutation : t -> Journal_worker_coordination.Worker_api.durable_intent -> unit
val begin_mutation_acknowledgement : t -> Journal_worker_coordination.Worker_api.durable_intent -> bool
val finish_mutation_acknowledgement : t -> Journal_worker_coordination.Worker_api.durable_intent -> unit
val claim_mutation_ack_recovery : t -> Journal_worker_coordination.Worker_api.durable_intent
  -> presentation:Journal_worker_coordination.Worker_api.presentation -> bool

val worker_child_ack : t -> Logseq_db_types.Graph_types.Uuid.t ->
  (Journal_worker_coordination.Worker_api.durable_intent * Journal_worker_coordination.Worker_api.presentation) option
val rebind_child_ack : t -> Logseq_db_types.Graph_types.Uuid.t ->
  presentation:Journal_worker_coordination.Worker_api.presentation -> bool
val receive_child_ack : t -> Logseq_db_types.Graph_types.Uuid.t -> (unit,string) result -> output
val child_projection_applied : t -> root:Logseq_db_types.Graph_types.Uuid.t -> round:int64
  -> presentation:Journal_worker_coordination.Worker_api.presentation -> output

val capture_chain : t -> command:Journal_graph_projection.capture ->
  Journal_graph_mutation_confirmation.Pure_insertion.t option

val capture_snapshot : t -> Logseq_db_types.Graph_types.Uuid.t ->
  (Journal_graph_projection.capture * Journal_graph_mutation_confirmation.Pure_insertion.t) option

val child_snapshot : t -> Logseq_db_types.Graph_types.Uuid.t ->
  (Journal_graph_projection.create_child * Journal_graph_mutation_confirmation.Pure_insertion.t) option
val retained_child_chains : t ->
  (Journal_graph_projection.create_child * Journal_graph_mutation_confirmation.Pure_insertion.t) Rrbvec.t

val changed_child_chains : t -> output ->
  (Journal_graph_projection.create_child * Journal_graph_mutation_confirmation.Pure_insertion.t) Rrbvec.t

val detail_observation_input : t -> Logseq_db_types.Graph_types.Uuid.t -> (int64 * int) option
val plan_observed_block : t -> root:Logseq_db_types.Graph_types.Uuid.t -> Logseq_db_types.Graph_types.Uuid.t
val plan_observed_detail : t -> generation:int64 -> limit:int -> root:Logseq_db_types.Graph_types.Uuid.t ->
  Logseq_db_types.Graph_types.Uuid.t

val owns_read : t -> Logseq_db_types.Graph_types.Uuid.t -> bool

val take_insertion_recoveries : t -> (Logseq_db_types.Graph_types.Uuid.t * Journal_graph_mutation_confirmation.Pure_insertion.recovery) Rrbvec.t
val resume_insertion_recovery : t -> root:Logseq_db_types.Graph_types.Uuid.t
  -> Journal_graph_mutation_confirmation.Pure_insertion.recovery -> output
