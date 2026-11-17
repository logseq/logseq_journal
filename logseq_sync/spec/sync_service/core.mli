(** Persistent sync service; context and DSL are encapsulated. *)
type t
type config
type dependencies
type error
type status
type subscription

(** Success means the service has started, not that synchronization is complete.
    Subsequent errors are observable through status subscriptions.
    Failure cleans up resources acquired during startup. *)
val start :
  sw:Eio.Switch.t ->
  config:config ->
  dependencies:dependencies ->
  (t, error) result

(** Updates network permission; does not physically join ongoing work. *)
val set_network : t -> Sync_dsl.Core.network_gate -> (unit, error) result

(** Reports the current state and subsequent changes. Callbacks must be fast and
    nonblocking. The subscription lasts until [sw] ends or [unsubscribe] is called. *)
val subscribe :
  sw:Eio.Switch.t ->
  t ->
  on_change:(status -> unit) ->
  (subscription, error) result

(** Idempotent. *)
val unsubscribe : subscription -> unit

(** Suspends until retirement. Errors retain cleanup obligations; closing an
    already closed service is idempotent. *)
val close : t -> (unit, error) result
