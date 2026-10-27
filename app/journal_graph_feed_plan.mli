module Graph = Logseq_db_types.Graph_types
module Protocol = Logseq_db_worker.Protocol
module Projection = Journal_graph_projection

type operation
type failure_scope = Feed of int64 | Day of { day : int; request_generation : int64 } | Reconciliation
type publication =
  | Loaded of { request_generation : int64; feed : Projection.feed; complete : bool }
  | Reconciled of { page : Projection.page; value : Projection.timeline_entry_page }
  | Failed of { scope : failure_scope; stale_cursor : bool; message : string }
type output = { requests : Protocol.request Rrbvec.t; publications : publication Rrbvec.t }
type packet = Dates of Protocol.v2_journal_item Seq.t | Roots of Protocol.v2_tree_member Seq.t
  | Preview of Protocol.v2_child_member Seq.t
type fragment = { page : Projection.page; members : Projection.tree_member Rrbvec.t
  ; entries : Projection.timeline_entry Rrbvec.t }
type context = { today : int option; time_context : (Projection.time_context, string) result }
type ports =
  { now : unit -> int64
  ; plan_read : operation -> Protocol.command -> Protocol.request
  ; context : unit -> context
  ; tag_titles : Graph.Uuid.t -> string list
  ; project_journal_page : Graph.page -> Projection.page option
  ; retain_root_interest : Projection.page -> minimum_limit:int -> unit
  ; retained_anchor : page_id:string -> (string * string) option
  ; observe_packet : packet -> unit
  ; remember_fragment : fragment -> unit
  ; report : string -> (string * Yojson.Safe.t) list -> unit
  }
type t
val create : unit -> t
val reset : t -> now:(unit -> int64) -> unit
val failure_scope : operation -> failure_scope
val operation_name : operation -> string
val is_current : t -> operation -> bool
val superseded : t -> operation -> output
val receive : t -> ports:ports -> operation -> Protocol.v2_outcome -> output option
val load_feed : t -> ports:ports -> cursor:Projection.feed_cursor option -> root_limit:int -> day_limit:int -> request_generation:int64 -> output
val load_day : t -> ports:ports -> page:Projection.page -> after:Projection.block_cursor option -> limit:int -> request_generation:int64 -> output
val refresh_initial : t -> ports:ports -> request_generation:int64 -> output option
val has_initial_feed : t -> bool
val reconcile_retained : t -> ports:ports -> page:Projection.page -> limit:int -> Protocol.request option
