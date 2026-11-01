(** Direct interpreter against the existing dbworker Service/client. No adapter,
    second Worker client is introduced; the host selects its implementation explicitly. *)
module Worker = Worker_api
module Service = Logseq_db_worker_lui.Logseq_db_worker_lui_service
module Mailbox = Logseq_db_worker_lui.Journal_worker

type client = (Service.request, Service.response, Service.push) Mailbox.client
type t
val create
  : client:client -> managed_origin:string -> user_id:string
  -> post:(Worker_pure_coordinator.event -> unit)
  -> publish:(Worker_pure_coordinator.view -> unit)
  -> (t, Worker.error) result

(** Borrow the host's verified client/account. Derive real mailbox epoch/generation,
    revoke any predecessor, queue Worker_bound before any baseline. The pure
    coordinator emits Bootstrap, executed by submit. Creation succeeds without
    claiming Ready. Registration not-ready/failure/revocation posts typed bootstrap
    states; the pure coordinator waits for old registration release and in-flight
    completion before requesting a fresh binding.

    Host keeps its existing pump, single Mailbox.on_event registration, auth/token/
    catalog/startup and client lifetime. This function does not install a second
    permanent handler (Mailbox has no unsubscribe). post queues serialized later
    turns; publish does not own UI/business state. Ready comes only from the
    correlated registered Service baseline, never from independent legacy pushes. *)

type disposition = Consumed | Unowned_response | Broadcast | Dropped_envelope
type delivery = private { disposition : disposition; error : Worker.error option }
val on_event : t -> (Service.response, Service.push) Mailbox.event -> delivery

(** One shared host router calls this BEFORE legacy response dispatch. Ownership
    is decided by the actual Accepted mailbox ID in the checked epoch/generation,
    not result shape or success/failure. Consumed includes owned errors, cancels,
    duplicate/retired/late replies and malformed owned receipts, even when error is
    Some. Never fall through to the old Application generic Failed/Cancelled path.
    Retain bounded tombstones until the Worker lifetime/fence proves no late reply.

    Unowned_response is permitted only for a response from the same live channel
    not owned by this runner; host forwards it to its OTHER REGISTERED request owner,
    never an unknown-ID generic error fallback. Foreign/stale envelopes are
    Dropped_envelope, not legacy work. Terminal and push are Broadcast; the host
    delivers them to interested owners exactly once (this runner has already
    processed its share), preserving coalescing/version/replay rules. An error
    cannot erase routing disposition. A new consumer of a broadcast must not
    independently ACK or rebuild an interest still owned by the legacy runtime.

    Mailbox.send and owner registration occur on the same App turn before the next
    pump drain. All callbacks queue typed events; no recursive step. Host continues
    forwarding terminal cleanup responses after revocation and while draining. *)

val submit : t -> Worker_pure_coordinator.instruction -> unit

(** Directly encode scoped Service/Protocol requests; never implicit-current
    Graph_request/Asset_command fallbacks. Track Accepted mailbox ID against typed
    ticket, protocol ID, owner, immutable intent and any acquired resource. Full/
    Not_ready/Stopping are Not_admitted; unsupported capabilities fail BEFORE send.
    Recheck session liveness and all nested scopes at admission and completion.

    Existing V2 query families retain actual DTOs/budgets/cursors; their availability
    depends on a valid bootstrap, not a fabricated session. Existing non-atomic
    create/insert/status calls cannot implement atomic Append. Durable mutation/
    import replay requires persistent outcome evidence, not just process caches.
    Observe/Refresh/Release require real registration/replay/epoch/release ACK.
    Until backend contracts exist reject just those unsupported capabilities and
    expose their reason; do not declare the entire layer migrated by rejecting all.

    Cancel uses the owned Mailbox Accepted ID and cannot assert rollback. Preserve
    committed/unknown outcomes, orphan-resource cleanup and available Error.t.
    Confirmation reads never turn a local commit into rejection. Late import/file
    acquisition adopts/releases all preview/lease retains even if UI has retired.
    Quiesce waits for actual target writer/callback fences and resource ownership
    handoff, then posts exact Handoff_completed. It never executes graph deletion,
    signs out, or stops the shared client. Host must also join legacy owners.
    Schedule_drain queues a later turn; Publish goes to host without recursive step. *)

val authorize_host_change : t -> Worker.handoff_receipt -> (unit, Worker.error) result

(** Nonblocking one-shot consume of this runner's current safe receipt. Verify ID,
    binding/account, exact affected resident/local-copy generations, target change
    and no renewed admission; reject stale/already-consumed/foreign receipts. Host
    calls immediately before dispatching its actual lifecycle action on the same
    serialized turn, after joining legacy owners and obtaining any confirmation.
    Backend admission independently rechecks ownership/generation. If dispatch
    fails or the outcome is unknown, inspect the actual owner before a fresh
    prepare/retry; never reuse this permission for a different/reopened copy. *)

type shutdown_state = Draining | Stopped | Shutdown_failed of Worker.error
val shutdown : t -> shutdown_state

(** Nonblocking and idempotent. Revoke ordinary admission, cancel/reconcile owned
    work, release all registrations/demands/leases, and retain cleanup ACK delivery
    through on_event. Draining is not success; call again after pump progress.
    Stopped means no owned callbacks/resources can revive, with durable intents
    transferred to their explicit persistence/recovery owner. Failures remain
    retryable; never stop the shared client or discard another consumer's state.
    Host closes the pump/client only after ALL owners reach their terminal fence.
    Current Mailbox.cancel alone cannot prove this obligation. *)
