(** Interpreter/adapter obligations for the target App spec. No default or stub
    implementation is supplied; today's Service is not silently coerced into it. *)

module Worker = Worker_api

module type WORKER = sig
  type t

  (** Bind once before sampling/subscribing. The runner supplies a verified,
      connection/account-bound issuer; the adapter uses its validating functions
      to turn raw Worker messages into sealed values. A failed bind is explicit.
      Revocation invalidates this issuer as well as callbacks from the old binding. *)
  val bind : t -> issuer:(module Worker.ISSUER) -> (unit, Worker.error) result

  (** Only this trusted adapter issues sessions/projections after validating the
      real Worker connection, account, graph and local incarnation. *)
  val projection : t -> Worker.projection

  (** Use the bound issuer's request encoder before dispatching to the real Worker.
      Report Not_admitted only before reservation. After acceptance, issue one
      terminal callback, preserving uncertainty if cancellation races a commit.
      Check response kind, all envelope IDs and receipt ownership before callback.
      Append and outbox/receipt persistence have one durable outcome; retries of
      the same intent/payload are idempotent across process restarts. Final encoded
      read bytes are bounded after enrichment, not only before it. *)
  val send
    :  t
    -> request_id:Worker.request_id
    -> Worker.session
    -> 'a Worker.request
    -> ('a Worker.reply -> unit)
    -> unit

  (** Encode only a tracked cancellation through the bound issuer. *)
  val cancel : t -> request_id:Worker.request_id -> unit

  (** Registration must not lose changes between the sampled version and the
      first callback. A projection contains membership and phase together;
      observations include empty results and maintain their own epochs. *)
  val subscribe
    :  t
    -> projection:(Worker.projection -> unit)
    -> observation:(Worker.observation_update -> unit)
    -> (unit -> unit)
end

type dependencies

val dependencies
  :  managed_origin:string
  -> user_id:string
  -> worker_incarnation:Worker.worker_incarnation
  -> worker:(module WORKER with type t = 'worker)
  -> handle:'worker
  -> dependencies

type t

(** Construct [Worker.issuer] from the verified binding, bind the adapter, then
    post [Core.Worker_bound] before its baseline/projection callbacks. Failures
    are returned; no fabricated baseline or silently unbound Worker is usable. *)
val create : dependencies -> post:(Core.event -> unit) -> (t, Worker.error) result

(** Dispatch only the exact ticket/session/request, posting all completions back
    to the serialized Core owner. Never call [Core.step] from a callback. Stop
    admission immediately on revocation. Release joins affected observation
    callbacks before its unit ACK; graph removal joins/fences target writers
    before reporting cleanup complete. A failed join is an explicit failure.
    The type system alone does not prove thread, network or filesystem atomicity.
    [Core.Schedule_drain] posts [Core.Drain] on a later coordinator turn without
    calling [Core.step] inline. *)
val submit : t -> Core.instruction -> unit

(** Revoke data issuance/callbacks/admission, retaining only the old binding's
    tracked cancellation/Release/terminal-ACK cleanup path. Release owned
    observations without admitting a new query/write or resurrecting the session.
    Return success only
    after their resources are quiescent; failures remain visible/retryable and do
    not erase durable intents or imply that accepted writes were rolled back. *)
val shutdown : t -> (unit, Worker.error) result
