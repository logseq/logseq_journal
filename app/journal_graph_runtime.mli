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
  | Source_mutation
  | Status_mutation
  | Delete_subtree_mutation

type payload =
  | Projection_changes of Logseq_db_worker.Protocol.v2_change_window list
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
      * Journal_graph_request.favorites_result
  | Favorites_failed of Journal_graph_request.favorites_request * bool * string
  | Favorites_invalidated
  | Graph_ready
  | Admission_inspected of
      { request : Journal_graph_request.admission_request
      ; observation : Logseq_db_worker.Protocol.v2_admission_inspection
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
  | Page_tree_reconciled of
      { page : Journal_graph_projection.page
      ; value : Journal_graph_projection.timeline_entry_page
      }
  | Projection_unavailable of [ `Detail_calendar | `Detail_time | `Detail ]
  | Children_reconciled of Journal_graph_projection.detail
  | Update_conflict of {block:Journal_graph_projection.block;timeline_entry_update:Journal_graph_projection.timeline_entry option}
  | Subtree_deleted of
      { block_id : string
      ; deleted_count : int
      ; parent : Journal_graph_projection.block option
      ; timeline_entry_update : Journal_graph_projection.timeline_entry option
      }
  | Delete_conflict of {block:Journal_graph_projection.block;timeline_entry_update:Journal_graph_projection.timeline_entry option}
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
  | Rejected of failure_source

type response = { payload : payload }
type t

type output =
  { requests : Logseq_db_worker.Protocol.request list
  ; responses : response list
  }

(** The host supplies the pure coordinator's current session/owner eligibility
    check for buffered Tree DTOs. Its default rejects execution provenance; tests
    can supply an explicit pure coordinator snapshot. *)
val create : ?localtime:(float -> Unix.tm) -> ?validate_session:(Journal_worker_coordination.Worker_api.session -> (unit, Journal_worker_coordination.Worker_api.error) result) -> unit -> t
val reset : t -> unit
val set_calendar : t -> Journal_calendar.t -> unit
val start : t -> Logseq_db_worker.Protocol.request
val submit : t -> Journal_graph_request.t -> output
val receive : t -> Logseq_db_worker.Protocol.response -> output
val fail_request : t -> Logseq_db_worker.Protocol.request -> message:string -> output
val abandon : t -> Logseq_db_worker.Protocol.request -> unit

val reconcile_push
  :  t
  -> request_generation:int64
  -> Logseq_db_worker.Protocol.push
  -> output

module Copy = Journal_copy

module Worker = Journal_worker_coordination.Worker_api

type worker_read_result =
  | Root_tree_read of {page:Logseq_db_types.Graph_types.Uuid.t;value:Logseq_db_worker.Protocol.v2_tree_member Worker.slice}
  | Child_members_read of Worker.children
  | Target_summary_read of Worker.block_summary
  | Journals_read of Logseq_db_worker.Protocol.v2_journal_item Worker.slice
  | Task_catalog_read of Worker.task_status_catalog
  | Ordinary_read of Logseq_db_worker.Protocol.v2_outcome
  | Favorites_read of
      { first_page : bool
      ; value : Journal_graph_request.favorites_result
      }

type worker_read =
  | Read :
      { query : 'a Worker.query
      ; maximum_items : int
      ; outcome : 'a -> worker_read_result
      }
      -> worker_read
  | Unowned_read of string

(** Business DTO interoperability. Favorites keeps its sealed continuation in
    the business operation/result; ordinary Worker transport IDs remain solely
    with the coordinator. No raw continuation extraction or cursor registry. *)
val worker_read : t -> Logseq_db_worker.Protocol.request -> worker_read option

val receive_worker_read : ?origin:(Worker.session * Worker.read_budget) -> t -> request_id:Worker.Uuid.t -> worker_read_result -> output
