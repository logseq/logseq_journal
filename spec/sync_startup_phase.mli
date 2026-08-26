(** Presentation-gated startup scopes and capabilities.

    This file is the canonical virtual-module contract. The production
    implementation must be selected through Dune [virtual_modules] and
    [(implements ...)] rather than by copying this interface. *)

type account
type graph
type connection

(** Immutable runtime scopes. Their representations are hidden so action callers
    cannot assemble identity and generation fields independently. *)
type account_scope

type graph_scope
type connection_scope

type account_scope_view = private
  { managed_sync_origin : Uri.t
  ; user_id : string
  ; account_generation : int
  ; presentation_generation : int
  ; permit_id : int64
  }

type graph_scope_view = private
  { account : account_scope_view
  ; graph_id : string
  ; graph_generation : int
  }

type connection_scope_view = private
  { graph : graph_scope_view
  ; connection_generation : int
  ; lifecycle_generation : int64
  }

(** Scope factories validate bounded identity fields and non-negative
    generations. [graph_id] must be a canonical UUID string. *)
val account_scope
  :  managed_sync_origin:Uri.t
  -> user_id:string
  -> account_generation:int
  -> presentation_generation:int
  -> permit_id:int64
  -> account_scope option

val graph_scope
  :  account_scope
  -> graph_id:string
  -> graph_generation:int
  -> graph_scope option

val connection_scope
  :  graph_scope
  -> connection_generation:int
  -> lifecycle_generation:int64
  -> connection_scope option

val account_scope_view : account_scope -> account_scope_view
val graph_scope_view : graph_scope -> graph_scope_view
val connection_scope_view : connection_scope -> connection_scope_view
val account_scope_of_graph : graph_scope -> account_scope
val graph_scope_of_connection : connection_scope -> graph_scope

type restoring
type presented
type _ witness

val begin_restore : graph_scope -> restoring witness
val witness_graph_scope : _ witness -> graph_scope

type timeline_ack =
  { account_generation : int
  ; graph_generation : int
  ; presentation_generation : int
  }

(** Returns [None] for a stale or mismatched frame acknowledgement. *)
val acknowledge_timeline : restoring witness -> timeline_ack -> presented witness option

(** Local prerequisite requests carry a hidden request nonce and the graph scope
    that authorized them. *)
type mirror

type wrapped_graph_key
type local_private_key
type graph_open
type 'kind local_request

val request_mirror : restoring witness -> mirror local_request
val request_wrapped_graph_key : restoring witness -> wrapped_graph_key local_request
val request_local_private_key : restoring witness -> local_private_key local_request
val request_graph_open : restoring witness -> graph_open local_request
val local_request_graph_scope : 'kind local_request -> graph_scope

(** Failure receipts are sealed evidence produced from a specific local request.
    The manager must not call [Local_completion] directly; source-boundary tests
    reserve it for the serialized local interpreter. *)
type 'kind failure_receipt

module Local_completion : sig
  val mirror_failed : mirror local_request -> diagnostic:string -> mirror failure_receipt

  val wrapped_graph_key_failed
    :  wrapped_graph_key local_request
    -> diagnostic:string
    -> wrapped_graph_key failure_receipt

  val local_private_key_failed
    :  local_private_key local_request
    -> diagnostic:string
    -> local_private_key failure_receipt

  val graph_open_failed
    :  graph_open local_request
    -> diagnostic:string
    -> graph_open failure_receipt
end

type recovery_reason =
  | Mirror_unavailable
  | Wrapped_graph_key_unavailable
  | Local_private_key_unavailable
  | Local_graph_open_failed of string

(** [online_recovery] contains the matching restore scope and a mutable one-shot
    consumption state. There is no operation that creates it from a caller-chosen
    [recovery_reason]. *)
type online_recovery

(** A cold start with no offline-ready graph candidate may recover at account
    scope so catalog discovery can select a graph. The ticket is sealed to its
    account scope and can be consumed only once. *)
type account_online_recovery

val recover : restoring witness -> 'kind failure_receipt -> online_recovery option
val recovery_reason : online_recovery -> recovery_reason
val begin_account_recovery : account_scope -> account_online_recovery

(** Network permits retain the complete sealed scope that authorized the work. *)
type _ network_permit

val permit_reconciliation : presented witness -> graph network_permit

(** Returns [Error] when the recovery ticket has already been consumed. *)
val permit_recovery
  :  online_recovery
  -> (graph network_permit, [ `Already_consumed ]) result

val permit_account_recovery
  :  account_online_recovery
  -> (account network_permit, [ `Already_consumed ]) result

val account_permit : 'level network_permit -> account network_permit

(** Connection work is bound to a validated connection scope below the graph
    permit. Returns [None] when the account or graph scopes differ. *)
val connection_permit
  :  graph network_permit
  -> connection_scope
  -> connection network_permit option

val permit_account_scope : 'level network_permit -> account_scope
val permit_graph_scope : graph network_permit -> graph_scope
val permit_connection_scope : connection network_permit -> connection_scope

(** Types prevent scope-field recombination. Runtime state still owns temporal
    freshness because an old capability value cannot be revoked by the OCaml type
    system after a generation changes. *)
val account_scope_matches
  :  account_scope
  -> account_generation:int
  -> presentation_generation:int
  -> bool

val graph_scope_matches
  :  graph_scope
  -> account_generation:int
  -> graph_generation:int
  -> presentation_generation:int
  -> bool

val connection_scope_matches
  :  connection_scope
  -> account_generation:int
  -> graph_generation:int
  -> connection_generation:int
  -> presentation_generation:int
  -> lifecycle_generation:int64
  -> bool
