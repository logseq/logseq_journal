(** Eio interpreter for Worker requests and typed overlay transitions. *)

type t
type runtime
type sync_runner
type dependencies
type dependency_error = Invalid_dependency of string
type create_error = Invalid_create of string
type id_token_request
type id_token_cache

val id_token_request_id : id_token_request -> string

val id_token_cache
  :  wall_clock_s:(unit -> float)
  -> monotonic_ns:(unit -> int64)
  -> request:(id_token_request -> unit)
  -> id_token_cache

val acquire_id_token
  :  id_token_cache
  -> account:Logseq_sync_pure_reducer.Core.account_scope
  -> (string, string) result

val provide_id_token : id_token_cache -> id_token_request -> string -> unit
val reject_id_token : id_token_cache -> id_token_request -> string -> unit

val invalidate_id_token
  :  id_token_cache
  -> account:Logseq_sync_pure_reducer.Core.account_scope
  -> token:string
  -> unit

val reconcile_authenticated_user : id_token_cache -> user_id:string option -> unit
val shutdown_id_token_cache : id_token_cache -> unit

val runtime
  :  fork:(sw:Eio.Switch.t -> (unit -> unit) -> unit)
  -> sleep:(float -> unit)
  -> (runtime, dependency_error) result

val sync_runner
  :  submit:(Logseq_sync_pure_reducer.Core.runner_effect -> unit)
  -> shutdown:(unit -> unit)
  -> retire_account:(account:Logseq_sync_pure_reducer.Core.account_scope -> (unit,string)result)
  -> unit
  -> sync_runner

val dependencies
  :  runtime:runtime
  -> config:Logseq_db_worker_contract.Config.t
  -> overlay:Logseq_overlay_db.Database.dependencies
  -> sync_runner:sync_runner
  -> publish:(Logseq_db_worker_pure_reducer.Core.output -> unit)
  -> (dependencies, dependency_error) result

val create
  :  sw:Eio.Switch.t
  -> dependencies
  -> post:(Logseq_db_worker_pure_reducer.Core.event -> unit)
  -> recovery_current:(Logseq_db_worker_pure_reducer.Core.upload_recovery_ticket -> bool)
  -> upload_current:(Logseq_db_worker_pure_reducer.Asset_upload.ticket -> bool)
  -> asset_current:(Logseq_sync_pure_reducer.Asset_transfer.ticket -> bool)
  -> (t, create_error) result

val submit : t -> Logseq_db_worker_pure_reducer.Core.instruction -> unit

(** Accept a bounded diagnostic only for its live scoped asset request. The
    internal request identifier is used for correlation and is never displayed. *)
val report_asset_diagnostic
  :  t
  -> scope:Logseq_sync_pure_reducer.Core.graph_scope
  -> operation:string
  -> request_operation:string
  -> Logseq_db_types.Failure_diagnostic.t
  -> unit

val await_reply
  :  t
  -> id:Logseq_db_worker_pure_reducer.Core.request_id
  -> request:Logseq_db_worker_contract.Protocol.request
  -> post:(unit -> unit)
  -> Logseq_db_worker_contract.Protocol.response

val shutdown : t -> unit

val retain_asset_file
  :  t
  -> scope:Logseq_sync_pure_reducer.Core.graph_scope
  -> handle:string
  -> (string * string) option

val release_asset_file
  :  t
  -> scope:Logseq_sync_pure_reducer.Core.graph_scope
  -> handle:string
  -> unit

(** Success acknowledges this exact scoped physical release. Cancellation,
    retired scope and storage failure remain errors; callers retain cleanup
    ownership and retry the same handle rather than inventing an ACK. *)
val release_asset_file_checked
  : t -> scope:Logseq_sync_pure_reducer.Core.graph_scope -> handle:string
  -> (unit, string) result

(** Transfer a discarded successful acquisition to this actual resource owner.
    The first checked release is attempted before returning. Failed obligations
    remain in the pure retry ledger. All unsettled obligations gate acquisition;
    a retry owns
    its exact attempt and cannot be settled by an earlier ACK. Shutdown does not
    turn pending cleanup into a success. These counts are required by handoff. *)
val abandon_asset_file
  : t -> scope:Logseq_sync_pure_reducer.Core.graph_scope -> handle:string -> unit
val unsettled_orphan_retains : t -> int

(** Capture after the serial reducer has submitted the retiring effects. Await
    joins their IO and callback barrier, including stale-result release children;
    pending physical failures remain errors. New unrelated work is not a fence. *)
type asset_cleanup_snapshot
val asset_cleanup_snapshot : t -> scope:Logseq_sync_pure_reducer.Core.graph_scope -> asset_cleanup_snapshot
val await_asset_cleanup : t -> asset_cleanup_snapshot -> (unit,string) result

val prepare_import
  :  t
  -> context:Logseq_sync_pure_reducer.Core.asset_context
  -> Logseq_db_types.Asset_import.t
  -> current:(unit -> bool)
  -> (Logseq_db_types.Asset_upload_intent.t, string) result

val retain_imported_file
  :  t
  -> scope:Logseq_sync_pure_reducer.Core.graph_scope
  -> operation:Logseq_db_types.Graph_types.Uuid.t
  -> (string * string) option

(** Durable complete mutation bytes use the existing scoped database attachment.
    Rechecks authority before committing; accepted interruption remains unknown. *)
val durable_mutation : t -> scope:Logseq_sync_pure_reducer.Core.graph_scope
  -> request_id:Logseq_db_types.Graph_types.Uuid.t -> intent:string
  -> current:(unit -> bool) -> Logseq_db_worker_contract.Mutation_pure_wire.outcome

(** Read-only original-proof lookup and one bounded canonical snapshot read. *)
val confirm_mutation : t -> scope:Logseq_sync_pure_reducer.Core.graph_scope
  -> request_id:Logseq_db_types.Graph_types.Uuid.t -> intent:string
  -> original:(string * string * string) -> current:(unit -> bool)
  -> Logseq_db_worker_contract.Protocol.response

(** Read-only item/byte bounded recovery. Complete immutable intent bytes and
    original proofs are returned; pending work remains Unknown and is not run. *)
val recover_mutations : t -> scope:Logseq_sync_pure_reducer.Core.graph_scope
  -> request_id:Logseq_db_types.Graph_types.Uuid.t -> after:int64 option
  -> maximum_items:int -> maximum_bytes:int -> current:(unit -> bool)
  -> (Logseq_db_worker_contract.Mutation_pure_wire.recovery_page,string) result

(** Acknowledges only a stored rejection or the exact immutable commit proof.
    The caller admits committed ACK only after applying a confirmation in the
    current presentation. Proof and outbox contents are retained. *)
val acknowledge_mutation : t -> scope:Logseq_sync_pure_reducer.Core.graph_scope
  -> intent:string -> original:(string * string * string) option
  -> current:(unit -> bool) -> (unit,string) result

(** Actual paused-listener/predecessor-snapshot registration on the existing DB.
    A sampled V2_failed remains registered and can recover on the next
    invalidation/Refresh; only allocation or activation failure aborts registration.
    A repeated logical ID retains its original sample/epoch and rebinds only the
    response envelope to this RPC request_id. Refresh does not replace the
    listener. Release fences publication, removes the listener and joins admitted
    reads before returning its cleanup ACK. *)
val register_observation
  :  t
  -> registration:int64
  -> id:Logseq_db_types.Graph_types.Uuid.t
  -> scope:Logseq_sync_pure_reducer.Core.graph_scope
  -> request:Logseq_db_worker_contract.Protocol.request
  -> maximum_bytes:int
  -> current:(unit -> bool)
  -> notify:(epoch:int64 -> unit)
  -> (int64 * Logseq_db_worker_contract.Protocol.response, string) result

val refresh_observation
  :  t
  -> registration:int64
  -> id:Logseq_db_types.Graph_types.Uuid.t
  -> scope:Logseq_sync_pure_reducer.Core.graph_scope
  -> request_id:Logseq_db_types.Graph_types.Uuid.t
  -> (int64 * Logseq_db_worker_contract.Protocol.response, string) result

val release_observation
  :  t
  -> registration:int64
  -> id:Logseq_db_types.Graph_types.Uuid.t
  -> scope:Logseq_sync_pure_reducer.Core.graph_scope
  -> (unit, string) result

val release_observations : t -> registration:int64 -> unit
val release_observations_checked : t -> registration:int64 -> (unit,string) result

(** Retire only an unknown logical observation ID; no implicit-current graph or
    invented account lifecycle. A known physical allocation must use its owner. *)
val release_unallocated_observation
  : t -> registration:int64 -> id:Logseq_db_types.Graph_types.Uuid.t
  -> owner:Logseq_sync_pure_reducer.Core.timeline_scope -> (unit,string) result

val observation_scope
  :  t
  -> registration:int64
  -> id:Logseq_db_types.Graph_types.Uuid.t
  -> Logseq_sync_pure_reducer.Core.graph_scope option

(** Exclusive registered Changes/ACK on the actual scoped database. A pull retains
    its exact bounded batch until a matching physical ACK; legacy access is fenced. *)
val coordinated_changefeed
  : t -> registration:int64 -> scope:Logseq_sync_pure_reducer.Core.graph_scope
  -> request:Logseq_db_worker_contract.Protocol.request -> maximum_bytes:int
  -> current:(unit -> bool) -> (Logseq_db_worker_contract.Protocol.response,string) result
val retire_changefeed : t -> registration:int64 -> unit

(** Permanently stop new physical graph-operation admission for this incarnation,
    join already reserved protected tasks even if Service waiters canceled, then
    join their actual serial reducer callback barrier. This is only writer evidence;
    resources, exclusive local-copy ownership and host permits require further ACKs. *)
val quiesce_writers : t -> scope:Logseq_sync_pure_reducer.Core.graph_scope -> (unit,string) result

(** Join the Sync owner's captured ordinary/protected/timer/WebSocket/asset I/O
    and actual callback posting via its existing serial event channel. The caller
    first retires target producers; this function itself grants no admission or
    host permit and does not stop the shared client. *)
val await_sync_io : t -> scope:Logseq_sync_pure_reducer.Core.effect_scope -> (unit,string) result

(** Actual retained physical scope roster, including old failed cleanup owners.
    This is captured by the backend, never supplied by the host as a substitute
    for ownership. No admission or acknowledgement is implied. *)
val physical_host_scopes : t -> Logseq_sync_pure_reducer.Core.graph_scope Rrbvec.t

(** The caller has withdrawn producers and gated reopen. Joins real graph tasks,
    Sync callbacks, database/listener close and resource children; success also
    requires the actual scoped cache's checked close. A failed DB close remains
    a physical failure, even if its logical session has already retired. *)
val settle_host_scope : t -> scope:Logseq_sync_pure_reducer.Core.graph_scope -> (unit,string) result

(** Complete the real Sync account owner's checked secret/cache cleanup after
    the pure owner has fenced its lifecycle and all admitted IO has joined. *)
val retire_account:t -> account:Logseq_sync_pure_reducer.Core.account_scope -> (unit,string)result

(** Hold the existing exclusive prepared_mirror_deletion owner before issuing a
    removal receipt, including copies whose DB cannot be opened. Retry may rebind
    an unconsumed failed round's same held owner; it cannot borrow a deletion in
    progress. No namespace mutation or new identity-probe API is involved. *)
val prepare_host_copy:t -> registration:int64 -> handoff_id:Logseq_db_types.Graph_types.Uuid.t
  -> owner:Logseq_sync_pure_reducer.Core.account_scope -> graph_id:Logseq_db_types.Graph_types.Uuid.t
  -> (Logseq_overlay_db.Types.mirror_generation,string)result
val bind_host_copy:t -> handoff_id:Logseq_db_types.Graph_types.Uuid.t
  -> Logseq_sync_pure_reducer.Core.mirror_deletion -> (unit,Logseq_db_worker_pure_reducer.Core.effect_error)result
val release_host_copy:t -> registration:int64 -> (unit,string)result
