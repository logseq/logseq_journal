type worker_failure =
  { operation : string
  ; request_id : Logseq_db_types.Graph_types.Uuid.t
  ; error : Logseq_db_worker.Error.t
  }

type graph_info =
  { graph_uuid : Logseq_db_types.Graph_types.Uuid.t
  ; graph_name : string
  ; schema : Logseq_db_types.Graph_types.schema_version
  ; admission_facts : Logseq_db_types.Graph_types.admission_fact list
  ; generation : string
  ; projection_revision : string
  }

type failure_source =
  | Worker_failure of worker_failure
  | Projection_failure of string

type payload =
  | Graph_ready of graph_info
  | Block_captured of
      { block : Journal_graph_projection.block
      ; timeline_entry_update : Journal_graph_projection.timeline_entry option
      }
  | Child_created of
      { child : Journal_graph_projection.block
      ; parent_revision : int
      ; timeline_entry_update : Journal_graph_projection.timeline_entry
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
  | Children_reconciled of Journal_graph_projection.detail
  | Update_conflict of Journal_graph_projection.block
  | Subtree_deleted of
      { block_id : string
      ; deleted_count : int
      ; parent : Journal_graph_projection.block option
      ; timeline_entry_update : Journal_graph_projection.timeline_entry option
      }
  | Delete_conflict of Journal_graph_projection.block
  | Block_found of Journal_graph_projection.block option
  | Feed_loaded of
      { request_generation : int64
      ; feed : Journal_graph_projection.feed
      ; complete : bool
      }
  | Day_blocks_loaded of
      { request_generation : int64
      ; page : Journal_graph_projection.timeline_entry_page
      }
  | Detail_loaded of
      { request_generation : int64
      ; detail : Journal_graph_projection.detail
      }
  | Feed_failed of
      { request_generation : int64
      ; failure : failure_source
      }
  | Open_failed of worker_failure
  | Rejected of failure_source

type response =
  { basis : int64 option
  ; payload : payload
  }

type t

type output =
  { requests : Logseq_db_worker.Protocol.request list
  ; responses : response list
  }

val create : unit -> t
val reset : t -> unit
val set_calendar : t -> Journal_calendar.t -> unit
val start : t -> Logseq_db_worker.Protocol.request
val submit : t -> Journal_graph_request.t -> output
val receive : t -> Logseq_db_worker.Protocol.response -> output
val abandon : t -> Logseq_db_worker.Protocol.request -> unit

val reconcile_push
  :  t
  -> request_generation:int64
  -> Logseq_db_worker.Protocol.push
  -> output
