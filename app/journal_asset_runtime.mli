module Worker = Journal_worker_coordination.Worker_api

type read_result

type read_request = private
  | Read :
      { request_id : Logseq_db_types.Graph_types.Uuid.t
      ; maximum_items : int
      ; query : 'a Worker.query
      ; outcome : 'a -> read_result
      }
      -> read_request

type t

val create
  :  ?release_consumer:(Worker.asset_consumer -> bool)
  -> ?read_planned:(Logseq_db_types.Graph_types.Uuid.t -> unit)
  -> ?read_retired:(Logseq_db_types.Graph_types.Uuid.t -> unit)
  -> read:(read_request -> bool)
  -> send:(Logseq_db_worker_lui.Logseq_db_worker_lui_service.request -> bool)
  -> changed:
       (int option
        -> Journal_asset_policy.offline
        -> Journal_asset_policy.offline
        -> unit)
  -> unit
  -> t

val receive_read
  :  t
  -> request_id:Logseq_db_types.Graph_types.Uuid.t
  -> read_result
  -> bool

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

val forget_request : t -> request_id:Logseq_db_types.Graph_types.Uuid.t -> unit

(** Reconcile only dependency-intersecting bounded recursive root batches.
    Unknown holders use bounded point reads instead of invalidating all scans. *)
val changes : t -> Worker_pure_data.change_window list -> unit

val owns_read : t -> Logseq_db_types.Graph_types.Uuid.t -> bool
val projection_read_error : t -> string option
val change_application_error : t -> Worker_pure_data.change_window list -> string option

(** Only demand notices which may plan a deferred read carry these bounded
    business obligations. Availability/download completion is not a read ACK. *)
val notice_reads : t -> Logseq_db_worker_lui.Logseq_db_worker_lui_service.asset_scope
  -> Logseq_db_worker_lui.Logseq_db_worker_lui_service.asset_notice
  -> Logseq_db_types.Graph_types.Uuid.t list

(** Explicit projection resync restarts the configured index enumerations. *)
val resync : t -> unit

val shutdown : t -> unit

val notice
  :  t
  -> Logseq_db_worker_lui.Logseq_db_worker_lui_service.asset_scope
  -> Logseq_db_worker_lui.Logseq_db_worker_lui_service.asset_notice
  -> unit

val pump : t -> unit
val reject : t -> request_id:Logseq_db_types.Graph_types.Uuid.t -> unit
val idle : t -> bool

val consumer_names : t -> string Seq.t

val bind_consumer : t -> name:string -> Worker.asset_consumer -> unit

val retire_coordinated_resources : t -> unit
val bind_coordinated_resources : t -> Worker.binding -> unit

val demand_backpressured : t -> string -> unit

(** The original accepted query and value retain fact issuance and ownership. *)
val observe_query : t -> request_id:Worker.Uuid.t -> 'a Worker.query -> unit
val observe_query_result : t -> request_id:Worker.Uuid.t -> 'a Worker.query -> 'a -> unit
