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

(** Invalidate configured scans after a projection change or resync. Unknown
    dependencies conservatively affect both scans; global projection cursors
    are discarded. Pending requests coalesce and retain their terminal owner. *)
val invalidate : t -> unit

val shutdown : t -> unit
val receive : t -> Logseq_db_worker.Protocol.response -> bool

val notice
  :  t
  -> Logseq_db_worker_lui.Logseq_db_worker_lui_service.asset_scope
  -> Logseq_db_worker_lui.Logseq_db_worker_lui_service.asset_notice
  -> unit

val pump : t -> unit
val reject : t -> request_id:Logseq_db_types.Graph_types.Uuid.t -> unit
