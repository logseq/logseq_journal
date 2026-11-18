(** Persistent service; execution contexts stay encapsulated. *)
module Dsl = Sync_dsl.Core
module Execute = Execute.Core

type t
type config =
  { identity : Dsl.identity
  ; limits : Dsl.limits
  ; network : Dsl.network_gate }

type 'clock dependencies =
  { clock : 'clock Eio.Time.Mono.t
  ; database_owner : Execute.database_owner
  ; capabilities : Execute.capabilities }
(** Caller retains database lifetime ownership under Execute's contract. *)

type error = Sync_error of Dsl.error
(** Preserve original diagnostics, including nested cleanup causes. *)

exception Reentrant_close
exception Close_already_called
exception Close_failed of
  { error : error option
  ; cause : (exn * Printexc.raw_backtrace) option }
(** At least one diagnostic; preserve all original DSL/cleanup causes and
    exception/backtrace when present. *)

type lifecycle = Running | Closing | Closed
type status =
  { lifecycle : lifecycle
  ; observation : Execute.runtime_observation }
(** Policy, actual metadata and gate remain distinct; online/idle is not synced. *)

(** Validate locally before acquisition under Execute's create contract; install
    the configured gate before network work. Ok means started, not synced;
    later runtime errors remain observable. Failed startup cleans up under [sw];
    failed cleanup retains original owners/obligations and exact causes.

    [on_change] is fixed for life: asynchronous delivery only after Ok returns,
    none on Error; no guarantee another domain has stored the handle.
    Current state/changes use bounded, coalesced latest snapshots: no history,
    unbounded queue, graph scans or network reads. Callbacks must be fast/nonblocking.
    Callback failure cleans up safely and propagates its original exception/raw
    backtrace to [sw], without swallowing, retry or replacement by cleanup failure.
    Failure scope follows switch organisation, not unconditional service death. *)
val start :
  sw:Eio.Switch.t ->
  config:config ->
  dependencies:'clock dependencies ->
  on_change:(status -> unit) ->
  (t, error) result

(** Updates network permission; does not physically join ongoing work. *)
val set_network : t -> Sync_dsl.Core.network_gate -> (unit, error) result

(** Own-callback calls immediately raise Reentrant_close before side effects,
    preserving the close right. The first accepted call atomically consumes it;
    calls during/after close immediately raise Close_already_called: no joining,
    shared close, idempotency or retry.
    Returns only after safe stopping/retirement and callback quiescence (none
    executing or future). No pending-data upload/sync flush or network permission
    prerequisite; Open may close.
    Failure is a bug: raise Close_failed, never Error or false Closed; retain
    unresolved cleanup owners/obligations in Closing. No automatic retry. *)
val close : t -> unit
