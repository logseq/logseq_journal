module Graph = Logseq_db_types.Graph_types
module Projection = Journal_graph_projection
module Worker = Journal_worker_coordination.Worker_api

type operation
type failure_scope = Feed of int64 | Day of { day : int; request_generation : int64 } | Reconciliation
type publication =
  | Loaded of { request_generation : int64; feed : Projection.feed; complete : bool }
  | Reconciled of { page : Projection.page; value : Projection.timeline_entry_page }
  | Failed of { scope : failure_scope; stale_cursor : bool; message : string }
type cached
type output = { requests : Graph.Uuid.t Rrbvec.t; publications : publication Rrbvec.t; cached : cached option }
type packet = Dates of Worker_pure_data.journal_item Seq.t | Roots of Worker_pure_data.tree_member Seq.t
  | Preview of Worker_pure_data.child_member Seq.t
type fragment = { page : Projection.page; members : Projection.tree_member Rrbvec.t
  ; entries : Projection.timeline_entry Rrbvec.t }
type context = { today : int option; time_context : (Projection.time_context, string) result }
type ports =
  { now : unit -> int64
  ; validate_session : Worker.session -> (unit, Worker.error) result
  ; plan_read : 'a. maximum_items:int -> operation -> 'a Worker.query -> Graph.Uuid.t
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
val superseded : t -> ports:ports -> operation -> output
val receive
  :  t
  -> ports:ports
  -> ?origin:(Worker.session * Worker.read_budget)
  -> operation
  -> 'a Worker.query
  -> 'a
  -> output option

val failed : t -> ports:ports -> operation -> code:Logseq_db_worker.Error.code -> output option

val load_feed : t -> ports:ports -> cursor:Projection.feed_cursor option -> root_limit:int -> day_limit:int -> request_generation:int64 -> output
val load_day : t -> ports:ports -> page:Projection.page -> after:Projection.block_cursor option -> limit:int -> request_generation:int64 -> output
val refresh_initial : t -> ports:ports -> request_generation:int64 -> output option
val has_initial_feed : t -> bool
val reconcile_page : t -> ports:ports -> page:Projection.page -> limit:int -> Graph.Uuid.t option

(** Business replay of a bounded already-read packet. Eligibility and epoch are
    checked before projection; this does not synthesize a Worker completion. *)
val resume_cached : t -> ports:ports -> cached -> output
