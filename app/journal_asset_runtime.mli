type t

val create
  :  send:(Logseq_db_worker_lui.Logseq_db_worker_lui_service.request -> bool)
  -> changed:
       (int option
        -> Journal_asset_policy.offline
        -> Journal_asset_policy.offline
        -> unit)
  -> t

(** Configure graph scope, day and offline settings. Repeating the same
    configuration preserves pending requests and completed enumerations. *)
val refresh
  :  t
  -> graph_generation:int
  -> today:int
  -> settings:Journal_asset_policy.settings
  -> unit

(** Observe only accepted, currently owned requests/responses. Issuance fences
    late responses; facts are discarded on graph replacement. *)
val observe_request : t -> Logseq_db_worker.Protocol.request -> unit

val forget_request : t -> request_id:Logseq_db_types.Graph_types.Uuid.t -> unit
val observe_response : t -> Logseq_db_worker.Protocol.response -> unit

(** Reconcile only dependency-intersecting bounded recursive root batches.
    Unknown holders use bounded point reads instead of invalidating all scans. *)
val changes : t -> Logseq_db_worker.Protocol.v2_change_window list -> unit

(** Explicit projection resync restarts the configured index enumerations. *)
val resync : t -> unit

val shutdown : t -> unit
val receive : t -> Logseq_db_worker.Protocol.response -> bool

val notice
  :  t
  -> Logseq_db_worker_lui.Logseq_db_worker_lui_service.asset_scope
  -> Logseq_db_worker_lui.Logseq_db_worker_lui_service.asset_notice
  -> unit

val pump : t -> unit
val reject : t -> request_id:Logseq_db_types.Graph_types.Uuid.t -> unit
