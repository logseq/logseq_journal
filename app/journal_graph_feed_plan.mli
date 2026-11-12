(** {1 TLDR}

    Own bounded, process-local Timeline date/root/preview read plans and retained
    freshness receipts. The runtime executes typed Worker requests; this module
    performs no I/O or persistence. Install a combined projection only after one
    same-snapshot check of all its retained scopes, including empty End packets. *)

module Graph = Logseq_db_types.Graph_types
module Projection = Journal_graph_projection
module Worker = Journal_worker_coordination.Worker_api

type operation
type failure_scope = Feed of int64 | Day of { day : int; request_generation : int64 } | Reconciliation
type publication =
  | Loaded of { request_generation : int64; feed : Projection.feed; complete : bool }
  | Reconciled of { page : Projection.page; value : Projection.timeline_entry_page }
  | Failed of { scope : failure_scope; stale_cursor : bool; message : string; cause : Worker.error option }
type output = { requests : Graph.Uuid.t Rrbvec.t; publications : publication Rrbvec.t}
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
(** {1 Minimal usage example}

    The runtime supplies [ports] and executes returned requests in order. Replies
    must return through the original operation and query identity:
    {[
      let state = create () in
      let output = load_feed state ~ports ~cursor:None ~root_limit:30
          ~day_limit:7 ~request_generation:1L in
      execute output.requests;
      publish output.publications
    ]}
    [execute] and [publish] are runtime callbacks. Mutations of the plan state
    precede interpretation. Completions are queued for a later serialized turn. *)

(** {1 Capability details} *)

val receive
  :  ?session:Worker.session
  -> t
  -> ports:ports
  -> operation
  -> 'a Worker.query
  -> 'a
  -> output option

val failed : t -> ports:ports -> operation -> code:Logseq_db_worker.Error.code -> output option

val load_feed : t -> ports:ports -> cursor:Projection.feed_cursor option -> root_limit:int -> day_limit:int -> request_generation:int64 -> output
val load_day : t -> ports:ports -> page:Projection.page -> after:Projection.block_cursor option -> limit:int -> request_generation:int64 -> output
val refresh_initial : t -> ports:ports -> request_generation:int64 -> output option
val reconcile_page : t -> ports:ports -> page:Projection.page -> limit:int -> Graph.Uuid.t option

val validate_retained : t -> ports:ports -> request_generation:int64 -> refresh:bool -> output

(** {1 Lifecycle and recovery}

    Receipts and cursors belong to this owner and the retained window only.
    Reset revokes pending operations. The runtime's request identity rejects
    duplicate/cancelled replies; feed sessions and page epochs fence refreshes.
    Scope changes discard the affected prefix and restart at most twice.
    A stale day continuation reports a scoped stale-cursor failure so the UI
    replaces its published prefix through the existing recovery path.
    An invalid accumulated sibling restarts the bounded assembly with fresh
    data and proofs; independent retained windows remain owned separately.
    A coalesced changefeed epoch fences checks already in flight; independent
    retained pages recover separately. Concrete worker causes remain attached
    to scoped failures. The runtime supplies their original request identity.
    [validate_retained] is scheduled by the existing coalesced changefeed/resync, never by rendering.
    Retain one proof per loaded query, including empty/End scopes; preview scans
    retain at most three selected members plus the bounded current packet.
    Date-only refresh reuses a validated retained prefix by page identity and
    unchanged journal day, and
    does not revoke unchanged root/preview scopes. Reset drops all retained
    prefixes, proofs and owner identities. [refresh] preserves the existing
    initial-feed refresh demand after a successful retained-window check. *)

val reset : t -> unit
val is_current : t -> operation -> bool
val superseded : t -> ports:ports -> operation -> output

(** {1 Observation and helpers} *)
val failure_scope : operation -> failure_scope
val operation_name : operation -> string
val has_initial_feed : t -> bool
val has_retained : t -> bool
val retained_page : t -> string -> bool
