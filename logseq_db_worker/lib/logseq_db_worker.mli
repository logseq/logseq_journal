module Config = Logseq_db_worker_contract.Config
module Error = Logseq_db_worker_contract.Error
module Protocol = Logseq_db_worker_contract.Protocol
module Pure_reducer = Logseq_db_worker_pure_reducer.Core
module Effect_runner = Logseq_db_worker_effect_runner.Effect_runner

type graph_phase = Pure_reducer.graph_phase =
  | Graph_closed
  | Graph_opening
  | Graph_open
  | Graph_closing
  | Graph_failed

type graph_state = Pure_reducer.graph_state =
  { generation : int
  ; graph_id : Logseq_db_types.Graph_types.Uuid.t option
  ; phase : graph_phase
  ; error : Error.t option
  }

type t
type create_error = Invalid_create of string

val create
  :  sw:Eio.Switch.t
  -> config:Pure_reducer.config
  -> runner_dependencies:Effect_runner.dependencies
  -> (t, create_error) result

val post : t -> Pure_reducer.event -> unit

(** Diagnostic-only receipt for an exact active asset operation. Retired or
    unknown operations are ignored; the normal completion owns publication. *)
val report_asset_diagnostic
  :  t
  -> scope:Logseq_sync_pure_reducer.Core.graph_scope
  -> operation:string
  -> request_operation:string
  -> Logseq_db_types.Failure_diagnostic.t
  -> unit

val view : t -> Pure_reducer.view
val graph_state : t -> graph_state

(** Waits for the exact local deletion flight's terminal result. The caller has
    confirmed discard of unsynchronized local content; current and unauthorized
    graphs, stale accounts and overlapping requests are rejected. *)
val delete_local_copy
  :  t
  -> account_generation:int
  -> graph_id:Logseq_db_types.Graph_types.Uuid.t
  -> (unit, string) result

val request : t -> Protocol.request -> Protocol.response
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

val release_asset_file_checked
  : t -> scope:Logseq_sync_pure_reducer.Core.graph_scope -> handle:string
  -> (unit, string) result

(** Backend ownership of an unpublished retained resource, including retries. *)
val abandon_asset_file : t -> scope:Logseq_sync_pure_reducer.Core.graph_scope -> handle:string -> unit
val unsettled_orphan_retains : t -> int

(** Typed demand registration and checked retirement on the existing serial
    Worker entry. Release joins actual retiring IO/callbacks before success. *)
val replace_coordinated_asset_demand : t -> registration:int64
  -> scope:Logseq_sync_pure_reducer.Core.graph_scope -> consumer:string
  -> priority:Logseq_sync_pure_reducer.Asset_transfer.priority
  -> assets:Logseq_db_types.Asset_descriptor.t list -> (unit,string) result
val release_coordinated_asset_demand : t -> registration:int64
  -> scope:Logseq_sync_pure_reducer.Core.graph_scope -> consumer:string -> (unit,string) result

type import_receipt =
  { operation : Logseq_db_types.Graph_types.Uuid.t
  ; graph_generation : int
  ; scope : Logseq_sync_pure_reducer.Core.graph_scope
  ; target : Logseq_db_types.Graph_types.Uuid.t
  ; asset : Logseq_db_types.Asset_descriptor.t
  ; file_type : string
  ; preview : (string * string) option
  }

val import_asset
  :  ?scope:Logseq_sync_pure_reducer.Core.graph_scope
  -> ?current:(unit -> bool)
  -> t
  -> graph_generation:int
  -> Logseq_db_types.Asset_import.t
  -> (import_receipt, string) result

val retain_imported_file
  :  t
  -> scope:Logseq_sync_pure_reducer.Core.graph_scope
  -> operation:Logseq_db_types.Graph_types.Uuid.t
  -> (string * string) option

(** Optional byte overrides apply only to ordinary snapshot reads and are capped
    by the configured limit. Invalid budgets or effect commands with an override
    fail before dispatch; legacy callers without an override retain their path. *)
val request_for_scope : ?response_budget_bytes:int -> t -> scope:Logseq_sync_pure_reducer.Core.graph_scope -> Protocol.request -> Protocol.response
val durable_mutation_for_scope : t -> scope:Logseq_sync_pure_reducer.Core.graph_scope
  -> request_id:Logseq_db_types.Graph_types.Uuid.t -> intent:string
  -> current:(unit -> bool) -> Logseq_db_worker_contract.Mutation_pure_wire.outcome
val graph_scopes : t -> Logseq_sync_pure_reducer.Core.graph_scope list
val graph_state_for_scope : t -> scope:Logseq_sync_pure_reducer.Core.graph_scope -> graph_state option

type coordination_snapshot =
  { version : int64
  ; presentation : int64
  ; state : Pure_reducer.coordination_state
  }

(** Register and sample on the serial Worker domain without yielding. A single
    binding borrows this coordination outlet. Increasing caller-known identities
    replace predecessors; release fences older delayed registration attempts.
    Notification runs after state assignment, before effects, and must not yield. *)
val register_coordination
  : t -> registration:int64 -> notify:(coordination_snapshot -> unit)
  -> (coordination_snapshot, string) result
val release_coordination : t -> registration:int64 -> (unit,string) result
val coordination_current : t -> registration:int64 -> bool
val revoke_coordination : t -> unit

val coordination_presentation_current : t -> registration:int64 -> presentation:int64
  -> owner:Logseq_sync_pure_reducer.Core.timeline_scope -> bool
val confirm_mutation_for_scope : t -> scope:Logseq_sync_pure_reducer.Core.graph_scope
  -> request_id:Logseq_db_types.Graph_types.Uuid.t -> intent:string
  -> original:(string * string * string) -> current:(unit -> bool) -> Protocol.response

val recover_mutations_for_scope : t -> scope:Logseq_sync_pure_reducer.Core.graph_scope
  -> request_id:Logseq_db_types.Graph_types.Uuid.t -> after:int64 option
  -> maximum_items:int -> maximum_bytes:int -> current:(unit -> bool)
  -> (Logseq_db_worker_contract.Mutation_pure_wire.recovery_page,string) result
val acknowledge_mutation_for_scope : t -> scope:Logseq_sync_pure_reducer.Core.graph_scope
  -> intent:string -> original:(string * string * string) option
  -> current:(unit -> bool) -> (unit,string) result

(** Query registrations share the real scoped DB owner. Initial sampling uses
    the listener's predecessor snapshot; callbacks only report epoch invalidation.
    Cleanup remains allowed for the original retired binding/scope and waits for
    admitted snapshots before returning. *)
val register_observation
  :  t
  -> registration:int64
  -> id:Logseq_db_types.Graph_types.Uuid.t
  -> scope:Logseq_sync_pure_reducer.Core.graph_scope
  -> request:Protocol.request
  -> maximum_bytes:int
  -> current:(unit -> bool)
  -> notify:(epoch:int64 -> unit)
  -> (int64 * Protocol.response, string) result

val refresh_observation
  :  t
  -> registration:int64
  -> id:Logseq_db_types.Graph_types.Uuid.t
  -> scope:Logseq_sync_pure_reducer.Core.graph_scope
  -> request_id:Logseq_db_types.Graph_types.Uuid.t
  -> (int64 * Protocol.response, string) result

val release_observation
  :  t
  -> registration:int64
  -> id:Logseq_db_types.Graph_types.Uuid.t
  -> scope:Logseq_sync_pure_reducer.Core.graph_scope
  -> (unit, string) result

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

(** Writer-only actual I/O/callback barrier. No resource settlement or host permit
    is implied; the scope remains fenced until its execution incarnation retires. *)
val quiesce_writers : t -> registration:int64 -> scope:Logseq_sync_pure_reducer.Core.graph_scope -> (unit,string) result

(** Host plans pin the authoritative baseline and client-known execution owners.
    Physical resource scopes are captured by the backend, not by this request. *)
type host_plan={version:int64;id:Logseq_db_types.Graph_types.Uuid.t;registration:int64;
  owner:Logseq_sync_pure_reducer.Core.account_scope;change:Pure_reducer.Host_handoff.change;
  expected:Logseq_sync_pure_reducer.Core.graph_scope Rrbvec.t}
val prepare_host_change:t -> host_plan -> (Pure_reducer.Host_handoff.receipt,string)result
val apply_host_change:t -> Pure_reducer.Host_handoff.receipt -> (unit,string)result

val confirm_host_change:t -> Pure_reducer.Host_handoff.receipt -> (bool,string)result

val recover_import_inputs_for_scope:t -> scope:Logseq_sync_pure_reducer.Core.graph_scope
  -> after:int64 option -> maximum_items:int -> maximum_bytes:int -> current:(unit -> bool)
  -> (Logseq_db_types.Asset_import.Recovery.page,string)result
val confirm_import_input_for_scope:t -> scope:Logseq_sync_pure_reducer.Core.graph_scope
  -> input:string -> current:(unit -> bool) -> (Logseq_db_types.Asset_import.Recovery.item option,string)result
val acknowledge_import_input_for_scope:t -> scope:Logseq_sync_pure_reducer.Core.graph_scope
  -> input:string -> prepared:string -> current:(unit -> bool) -> (unit,string)result
