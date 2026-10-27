module Graph = Logseq_db_types.Graph_types
module Protocol = Logseq_db_worker.Protocol

type purpose =
  | Captured of { block_id : string }
  | Updated of { block_id : string }
  | Update_conflict_refresh of { block_id : string }
  | Delete_conflict_refresh of { block_id : string }

type read
type confirmation =
  { purpose : purpose; block_id : string; value : Protocol.v2_block_record
  ; revision : string; page : Graph.page; page_revision : string
  ; scope_revision : string; children : Protocol.v2_child_member Rrbvec.t }
type planning = (Protocol.request, string) result
type step = Continue of planning | Confirmed of confirmation | Failed of string
type ports =
  { now : unit -> int64
  ; plan_read : source_epoch:int64 -> read -> Protocol.command -> Protocol.request }
type t
val create : unit -> t
val reset : t -> unit
val current : t -> read -> bool
val start : t -> ports:ports -> purpose -> planning
val retry_stale : t -> ports:ports -> read -> planning option
val receive_summary : t -> ports:ports -> read -> lookup:Protocol.v2_block_lookup
  -> page:Protocol.v2_page_lookup option -> items:Protocol.v2_child_member list
  -> next_cursor:Graph.Cursor.t option -> scope_revision:string -> generation:string
  -> projection_revision:string -> step
val reference_fragment : read -> target:Protocol.v2_block_record
  -> final_children:Protocol.v2_child_member list -> Protocol.v2_block_record Rrbvec.t
