(** Persistent sync service; execution contexts are encapsulated. *)
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
(** The caller retains database lifetime ownership under Execute's owner contract. *)

type error =
  | Sync_error of Dsl.error
  | Reentrant_close
(** Preserve underlying diagnostics unchanged, including nested cleanup causes. *)

type lifecycle = Running | Closing | Closed
type status =
  { lifecycle : lifecycle
  ; observation : Execute.runtime_observation }
(** Runtime observation separates sync policy status from actual metadata and gate;
    neither online nor idle proves synchronization complete. *)

(** Validate locally before acquisition under Execute's create contract; apply
    the configured network gate before admitting network work.
    Success means started, not synchronized. Subsequent runtime errors remain in
    observations. Startup failure cleans up acquired resources under [sw]; failed
    cleanup retains original owners/obligations and reports exact cleanup causes.

    [on_change] is the single fixed listener for the service lifetime. No callback
    runs before [start] returns [Ok]; returning [Error] produces no callbacks.
    Delivery is asynchronous after return, not a cross-domain guarantee that the
    caller has stored the handle. Reports current state and changes as bounded,
    coalesced latest snapshots, without full history, an unbounded queue, graph
    scans or network reads. Callbacks must be fast and nonblocking.
    Preserve a callback's original exception and raw backtrace, safely clean up
    and propagate to [sw] without swallowing or retrying. Cleanup failure must
    not replace the callback cause. Failure blast radius follows switch
    organisation, not unconditional service death. *)
val start :
  sw:Eio.Switch.t ->
  config:config ->
  dependencies:'clock dependencies ->
  on_change:(status -> unit) ->
  (t, error) result

(** Updates network permission; does not physically join ongoing work. *)
val set_network : t -> Sync_dsl.Core.network_gate -> (unit, error) result

(** From this service's own callback, immediately returns [Error Reentrant_close]
    without starting close or waiting. Otherwise suspends until retirement;
    success guarantees no executing or future callbacks.
    Cleanup error retains original owners, obligations and diagnostics in Closing;
    it is not permission to retry a non-network failure. No hidden retry; surface
    bugs for correction. Already Closed is idempotent. *)
val close : t -> (unit, error) result
