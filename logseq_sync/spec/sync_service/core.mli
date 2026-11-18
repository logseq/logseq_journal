(** Persistent service; execution contexts stay encapsulated. *)
module Dsl = Sync_dsl.Core
module Execute = Execute.Core

type t
type config =
  { identity : Dsl.identity
  ; limits : Dsl.limits
  ; network : Dsl.network_gate
  ; policy : Dsl.policy_config }

type ingress =
  { outbox_committed : owner:Execute.database_owner -> identity:Dsl.identity
      -> (unit, Dsl.error) result
  ; submit_unlock : identity:Dsl.identity -> valid_for:float -> Dsl.unlock_input
      -> (Execute.ingress_ack, Dsl.error) result
  ; update_demand : Dsl.demand_change -> (Execute.ingress_ack, Dsl.error) result
  ; receive_demand : unit -> (Dsl.demand_output, Dsl.error) result
  ; demand_status : Dsl.demand_delivery -> (Execute.delivery_status, Dsl.error) result
  ; release_demand : Dsl.demand_delivery -> (unit, Dsl.error) result }
(** Bound to the exact runtime and database owner; Execute ingress rules apply.
    Rejection transfers nothing; outbox rejection never undoes a durable commit.
    Closing rejects new work and wakes receivers, but status/release remain usable
    for original deliveries, including retained cleanup after close failure. *)

type 'clock dependencies =
  { clock : 'clock Eio.Time.Mono.t
  ; database_owner : Execute.database_owner
  ; capabilities : Execute.capabilities
  ; bind_ingress : ingress -> unit }
(** Caller retains database and concrete Worker owner lifetimes through retirement.
    Account authentication/key acquisition, catalog, selection, mirror deletion and
    account cleanup remain caller-owned, not per-graph policy. *)

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

(** Validate locally before acquisition under Execute's create contract; apply
    the initial-only gate contract before policy network work. Ok means started, not synced;
    later runtime errors remain observable. Failed startup cleans up under [sw];
    failed cleanup retains original owners/obligations and exact causes.

    Runs Dsl.sync_policy config.policy ~initial_network:config.network, never
    Execute business policy. The gate is an initial-only install, not a replay:
    only properly bound admitted explicit set_network attempts during binding/
    Restore supersede it, including Open rejected by semantic epoch/old-generation
    join checks. Admission rejection preserves eligibility under Execute's zero-effect
    contract. Restore preserves controls; installation is atomic under Execute's
    one-shot eligibility contract.
    [bind_ingress] runs once asynchronously after Ok returns, before on_change;
    neither callback runs on startup Error or before start returns. Binding installs
    the exact owner's durable postcommit invalidator before returning; commits
    before installation are covered by initial dirtiness. Policy Inspect/Run_task
    starts only after binding completes, so no commit-to-subscription gap is lost.
    Binding is nonblocking and installs/stores capabilities, not a service receiver
    loop. Pre-Run_task ingress may reject Stale_context without taking ownership.
    Ingress may pass to database/Worker consumers, never be rebound to another
    incarnation. Closing before binding suppresses it and prevents policy start.
    Both callbacks share failure supervision and own-callback close protection.

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

(** Closed immediately fences permission and schedules one internal exact-generation
    join, independent of policy suspension. Return ACKs fence, not join; join
    failure retains Closed/cause/obligations, with no automatic cleanup retry.
    Open checks current authority and rejects until that exact old join succeeds;
    it is not retained, deferred or secretly retried. A later explicit Open may
    succeed. Controls apply immediately during binding/Restore after target runtime/
    owner and applicable context/version/lifecycle admission. Foreign, stale, copied
    or revoked calls have no effects, including on initial-install eligibility;
    Closing/Closed reject changes with no effects. Only properly bound admitted
    attempts consume eligibility before semantic Open epoch/old-generation join
    checks, even if those checks reject Open. No captured Open is replayed after
    the join. No adapter reconnect or network flush. *)
val set_network : t -> Sync_dsl.Core.network_gate -> (unit, error) result

(** Own-callback calls immediately raise Reentrant_close before side effects,
    preserving the close right. The first accepted call atomically consumes it;
    calls during/after close immediately raise Close_already_called: no joining,
    shared close, idempotency or retry.
    Returns only after safe stopping/retirement and callback quiescence (none
    executing or future). No pending-data upload/sync flush or network permission
    prerequisite; Open may close.
    Fence new ingress/Worker scopes, stop policy, join children/producers and clean
    queued deliveries. Received deliveries are revoked, not forcibly reclaimed;
    callers stop using bytes and release through the retained ingress while close
    waits. Independent release fibers/owners must remain alive. Likewise wait for
    Worker imported-file leases before checked owner retirement; lease-use waits
    are not cleanup timeouts. Only then release registrations and join callbacks.
    No bounded wait may fake a consumer release or discard failed cleanup.
    Failure is a bug: raise Close_failed, never Error or false Closed; retain
    unresolved cleanup owners/obligations in Closing. No automatic retry. *)
val close : t -> unit
