(** Persistent service; contexts remain encapsulated. *)
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
(** Exact-runtime ingress follows Execute rules; rejection transfers nothing. Closing preserves delivery status/release, including failed cleanup. *)

type 'clock dependencies =
  { clock : 'clock Eio.Time.Mono.t
  ; database_owner : Execute.database_owner
  ; capabilities : Execute.capabilities
  ; bind_ingress : ingress -> unit }
(** Caller keeps database/Worker owners alive through retirement and owns account coordination. *)

type error = Sync_error of Dsl.error


exception Reentrant_close
exception Close_already_called
exception Close_failed of
  { error : error option
  ; cause : (exn * Printexc.raw_backtrace) option }
(** Preserve at least one diagnostic and all original causes/backtraces. *)

type lifecycle = Running | Closing | Closed
type status =
  { lifecycle : lifecycle
  ; observation : Execute.runtime_observation }
(** Online/idle does not mean synced. *)

(** Runs Dsl.sync_policy; Ok means started, not synced. Startup failure retains failed cleanup under sw.
    After Ok returns, bind_ingress runs once before on_change and policy inspection;
    neither callback runs on Error. Binding must install the durable postcommit invalidator;
    initial dirtiness covers earlier commits. Closing before binding suppresses policy start.
    Callbacks must be nonblocking; snapshots coalesce, with no history or handle-storage guarantee.
    Callback failure cleans up and propagates its original exception/backtrace to sw. *)
val start :
  sw:Eio.Switch.t ->
  config:config ->
  dependencies:'clock dependencies ->
  on_change:(status -> unit) ->
  (t, error) result

(** Closed immediately fences and schedules the exact-generation join; ACK is not join.
    Open fails fast until that join succeeds; failed joins retain obligations, without retry.
    Controls work during binding/Restore; Execute admission and initial-install rules apply.
    Rejected Open is never deferred or replayed; no sync flush. *)
val set_network : t -> Sync_dsl.Core.network_gate -> (unit, error) result

(** Own-callback calls raise Reentrant_close before effects, preserving the close right.
    First accepted call consumes it; all later calls immediately raise Close_already_called.
    Waits for retirement and callback quiescence, without upload/flush or requiring Open.
    Consumers must stop using revoked bytes and release deliveries/imported-file leases;
    keep independent release fibers and original owners alive. No forced lease timeout.
    Failure raises Close_failed and retains Closing/cleanup obligations; no automatic retry. *)
val close : t -> unit
