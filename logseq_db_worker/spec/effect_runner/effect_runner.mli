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
