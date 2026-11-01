(** Target interpreter directly connected to the existing dbworker Service/client.
    No default implementation or runtime migration is provided by this spec. *)

module Worker = Worker_api
module Service = Logseq_db_worker_lui.Logseq_db_worker_lui_service
module Mailbox = Logseq_db_worker_lui.Journal_worker

type client = (Service.request, Service.response, Service.push) Mailbox.client
type t

(** Borrow the connected client owned by Application/Journal_worker_runtime.
    Derive the binding identity from [Mailbox.runtime_epoch]/[worker_generation],
    construct the validating [Worker.issuer], and post [Worker_coordinator.Worker_bound] before
    publishing its baseline. The verified local/online binding supplies origin/user.
    No WORKER functor, separate adapter, or second transport client is required.

    Application keeps its existing pump, event delivery, authentication/catalog
    handling and client lifetime. It forwards relevant real envelopes to [on_event].
    Creating this runner neither starts/stops that shared client nor silently
    registers another permanent Mailbox.on_event handler (there is no unsubscribe
    operation in that API). [post] queues a later Worker_coordinator turn; [publish] delivers the
    coordination view to its host without owning UI/navigation state. Creation
    does not claim a readable baseline is ready. *)
val create
  :  client:client
  -> managed_origin:string
  -> user_id:string
  -> post:(Worker_coordinator.event -> unit)
  -> publish:(Worker_coordinator.view -> unit)
  -> (t, Worker.error) result

(** Called on the App coordinator from the existing Mailbox.on_event/pump path.
    Validate envelope runtime epoch/worker generation and the tracked mailbox ID
    before interpreting Service responses/pushes with Worker.issuer. Retired/foreign
    envelopes are ignored. Publish typed Worker_coordinator completions/projections/observations
    through [post], never by calling [Worker_coordinator.step] inside a Worker callback.

    Today's independently coalesced session/graph pushes do not provide an atomic,
    versioned sample/subscription handshake. Establish registration plus a baseline
    or replay from its version at the Worker owner before claiming this contract;
    otherwise return Unsupported_operation to the host and publish no fabricated
    ready projection. The host must surface this error through its existing UI
    error/recovery path. These guarantees still require backend work and tests. *)
val on_event
  :  t
  -> (Service.response, Service.push) Mailbox.event
  -> (unit, Worker.error) result

(** Map exact typed instructions to scoped Service requests, using [Mailbox.send]
    and recording its Accepted mailbox ID against the Worker_coordinator ticket/protocol ID.
    Full/Not_ready/Stopping are Not_admitted; Unsupported target commands are
    Not_admitted(Unsupported_request ...) before any enqueue. Query/Append never
    fall back to the implicit-current Service.Graph_request entry point.

    Cancellation uses [Mailbox.cancel] with the owned Accepted mailbox ID; the
    cooperative terminal outcome cannot prove rollback. Mailbox.Failed remains
    Service_failed. Preserve available Error.t values; V2_failed only carries
    code/message, so decode those without inventing a lost causal trace. A write
    accepted before interruption stays unknown or committed pending reconciliation.

    Current create-page and insert commands do not implement atomic Append. The
    implementation must reject it until a durable idempotent backend operation
    exists; wrapping old calls is not sufficient. Observe/Refresh/Release similarly
    require a real registration/epoch/ack protocol, not invented completion facts.
    Release uses a unit ticket and retains cleanup after revocation. Schedule_drain
    posts Worker_coordinator.Drain on a later coordinator turn. Publish is delivered to the host
    without applying Worker_coordinator.step recursively. Final enriched reads retain byte limits. *)
val submit : t -> Worker_coordinator.instruction -> unit

(** Revoke this runner's data issuance and ignore subsequent ordinary callbacks.
    Only its tracked cancellation/Release/terminal-ACK path may finish cleanup;
    never stop the shared client or release another App consumer's resources.
    Return success only after owned callbacks/interests are quiescent. Existing
    Mailbox.cancel alone cannot prove a target writer stopped or release completed;
    backend acknowledgement/fencing is still required. Failures remain explicit
    and retryable; durable intents are preserved. *)
val shutdown : t -> (unit, Worker.error) result
