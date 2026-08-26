type payload =
  | Graph_ready of Logseq_db_worker.Graph_types.graph_info
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
      ; message : string
      }
  | Open_failed of Logseq_db_worker.Error.t
  | Rejected of string

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

val reconcile_invalidation
  :  t
  -> request_generation:int64
  -> Logseq_db_worker.Protocol.invalidation
  -> output
