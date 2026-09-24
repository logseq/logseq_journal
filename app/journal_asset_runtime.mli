type t

val create
  :  send:(Logseq_db_worker_lui.Logseq_db_worker_lui_service.request -> bool)
  -> changed:
       (int option
        -> Journal_asset_policy.offline
        -> Journal_asset_policy.offline
        -> unit)
  -> t

val refresh
  :  t
  -> graph_generation:int
  -> today:int
  -> settings:Journal_asset_policy.settings
  -> unit

val shutdown : t -> unit
val receive : t -> Logseq_db_worker.Protocol.response -> bool

val notice
  :  t
  -> Logseq_db_worker_lui.Logseq_db_worker_lui_service.asset_scope
  -> Logseq_db_worker_lui.Logseq_db_worker_lui_service.asset_notice
  -> unit

val visible : t -> consumer:string -> Logseq_db_types.Asset_descriptor.t list -> unit
val hidden : t -> consumer:string -> unit
val progress : t -> Journal_asset_policy.reason -> Journal_asset_policy.progress
val pump : t -> unit
val reject : t -> request_id:Logseq_db_types.Graph_types.Uuid.t -> unit
