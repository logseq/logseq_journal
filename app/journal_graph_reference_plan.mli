module Graph = Logseq_db_types.Graph_types
module Protocol = Logseq_db_worker.Protocol

type lookup = Page_lookup | Outline_lookup
type read = { block_id : string; depth : int; lookup : lookup }
type source =
  | Block of Graph.block
  | Missing_outline of Graph.Uuid.t
  | Page of { page : Graph.page; detail_owner : bool }
  | Missing_page of Graph.Uuid.t
type known = { id : string; text : string option; page_kind : bool }
type change =
  | Block_changed of { id : string; journal_block_known : bool }
  | Page_changed of { id : string; detail_page_owned : unit -> bool }
type ports =
  { now : unit -> int64
  ; plan_read : source_epoch:int64 option -> read -> Protocol.command -> Protocol.request
  ; known_page : string -> Graph.page option
  }
type output =
  { requests : Protocol.request Rrbvec.t
  ; updates : (string * string option) Rrbvec.t
  }
type t

val create : localtime:(float -> Unix.tm) -> unit -> t
val reset : t -> unit
val fence : t -> now:(unit -> int64) -> string -> unit
val plan_change : t -> ports:ports -> change -> Protocol.request option
val resync : t -> ports:ports -> Protocol.request Rrbvec.t
val shared_read_failed : t -> ports:ports -> source_epoch:int64 -> block_id:string -> output
val read_failed : t -> ports:ports -> source_epoch:int64 -> block_id:string -> depth:int -> output
val receive_page : t -> ports:ports -> source_epoch:int64 -> read -> Protocol.v2_page_lookup -> output
val receive_outline : t -> ports:ports -> source_epoch:int64 -> read -> Protocol.v2_block_lookup -> output
val observe_fragment
  : t -> ports:ports -> source_epoch:int64 -> sources:source Rrbvec.t
  -> changes:known Rrbvec.t -> property_blocks:Graph.block Seq.t -> output
val abandon : t -> source_epoch:int64 -> read -> unit
