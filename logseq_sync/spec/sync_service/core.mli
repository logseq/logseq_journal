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

type subscription_end =
  | Unsubscribed
  | Switch_ended
  | Service_retired
  | Callback_failed of exn * Printexc.raw_backtrace

type error =
  | Sync_error of Dsl.error
  | Subscription_ended of subscription_end
(** Preserve underlying diagnostics unchanged, including nested cleanup causes. *)

type lifecycle = Running | Closing | Closed
type status =
  { lifecycle : lifecycle
  ; observation : Execute.runtime_observation }
(** Runtime observation separates sync policy status from actual metadata and gate;
    neither online nor idle proves synchronization complete. *)

type subscription

(** Validate locally before acquisition under Execute's create contract; apply
    the configured network gate before admitting network work.
    Success means started, not synchronized. Subsequent runtime errors remain in
    observations. Startup failure cleans up acquired resources under [sw]; failed
    cleanup retains original owners/obligations and reports exact cleanup causes. *)
val start :
  sw:Eio.Switch.t ->
  config:config ->
  dependencies:'clock dependencies ->
  (t, error) result

(** Updates network permission; does not physically join ongoing work. *)
val set_network : t -> Sync_dsl.Core.network_gate -> (unit, error) result

(** Bounded latest snapshots, coalesced without graph scans or network reads.
    Reports current state and changes; callbacks must be fast and nonblocking.
    Ends on [sw] exit, service retirement or explicit unsubscribe.
    A callback exception atomically ends the subscription; preserve its exception
    and raw backtrace, safely clean up and propagate to the supplied [sw] without
    swallowing or retrying. Cleanup failure must not replace the callback cause.
    Failure blast radius follows switch organisation, not unconditional service death.
    Callback join and self-unsubscribe semantics remain unspecified. *)
val subscribe :
  sw:Eio.Switch.t ->
  t ->
  on_change:(status -> unit) ->
  (subscription, error) result

(** Explicit cancellation is atomic: only one call per subscription succeeds.
    Subsequent or concurrent attempts return [Error] without additional cancellation
    effects. Already-ended subscriptions return [Subscription_ended] with their
    original end cause; losing explicit calls report [Unsubscribed]. *)
val unsubscribe : subscription -> (unit, error) result

(** Suspends until retirement. Error retains original cleanup obligations and
    diagnostics in Closing; it is not permission to retry a non-network failure.
    No hidden retry; surface bugs for correction. Already Closed is idempotent. *)
val close : t -> (unit, error) result
