(** {1 TLDR}

    Interpret the coordinator's private instructions through the existing Worker
    client and its single host pump. {!create} borrows that client/account and
    queues binding/bootstrap events; success does not imply Ready. {!submit}
    performs scoped I/O, while {!on_event} routes actual mailbox completions.
    The host owns serialization, UI/business state and shared client lifetime.
    {!shutdown} returns [Draining], [Stopped] or [Shutdown_failed]; only [Stopped]
    proves this runner's cleanup has reached its terminal fence. *)

module Worker = Worker_api

type client = (Logseq_db_worker_lui.Logseq_db_worker_lui_service.request, Logseq_db_worker_lui.Logseq_db_worker_lui_service.response, Logseq_db_worker_lui.Logseq_db_worker_lui_service.push) Logseq_db_worker_lui.Journal_worker.client
type t
type disposition = Consumed | Unowned_response | Broadcast | Dropped_envelope
type delivery = private { disposition : disposition; error : Worker.error option }

type shutdown_state = Draining | Stopped | Shutdown_failed of Worker.error

(** {1 Minimal usage example}

    The caller supplies the existing [client], verified [managed_origin]/[user_id],
    [post] that queues serialized coordinator events, and the host's [publish]:
    {[
      match create ~client ~managed_origin ~user_id ~post ~publish with
      | Error error -> Error error
      | Ok runner -> Ok runner
    ]}
    Keep the returned runner in the host. For each coordinator transition install
    [next] first, then [List.iter (submit runner) transition.instructions]. Route
    the existing pump through [on_event] before legacy dispatch and honor its
    [disposition]. During retirement keep delivering real cleanup events and call
    [shutdown runner] after progress until [Stopped]; retain failures for retry.
    Closing the shared client also waits for every other owner. *)

(** {1 Construction and validation} *)

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

(** {1 Capability details} *)

val on_event : t -> (Logseq_db_worker_lui.Logseq_db_worker_lui_service.response, Logseq_db_worker_lui.Logseq_db_worker_lui_service.push) Logseq_db_worker_lui.Journal_worker.event -> delivery

(** One shared host router calls this BEFORE legacy response dispatch. Ownership
    is decided by the actual Accepted mailbox ID in the checked epoch/generation,
    not result shape or success/failure. Consumed includes owned errors, cancels,
    late terminal replies and malformed owned receipts, even when error is Some.
    Never fall through to the old Application generic Failed/Cancelled path.
    Inputs come from the existing Mailbox outlet, which filters duplicate terminal
    replies before invoking the host. Retain only actual in-flight ownership until
    that terminal arrives; completed IDs do not consume lifetime admission capacity.

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

(** Interpret an instruction emitted by Core. Private constructors preserve
    pattern matching but prevent callers from manufacturing a different Send. *)
val submit : t -> Worker_pure_coordinator.instruction -> unit

(** Directly submit scoped typed Service requests; never implicit-current
    Graph_request/Asset_command fallbacks. Track Accepted mailbox ID against typed
    ticket, request ID, owner, immutable intent and any acquired resource. Full/
    Not_ready/Stopping are Not_admitted; unsupported capabilities fail BEFORE send.
    Recheck session liveness and all nested scopes at admission and completion.

    Existing query families retain actual DTOs/budgets/cursors; their availability
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

(* Host consumption also enters only through Core's private Consume_handoff
    instruction. There is no public transport shortcut around its planned attempt.
    Admission is not an action ACK: only matching Host_change_applied permits host
    UI/auth/client continuation. Unknown outcomes retain their original permission
    and cleanup owner; they are never replayed with a fresh receipt. *)

(** {1 Lifecycle and recovery} *)

val shutdown : t -> shutdown_state

(** Nonblocking and idempotent. Revoke ordinary admission, cancel/reconcile owned
    work, release all registrations/demands/leases, and retain cleanup ACK delivery
    through on_event. Draining is not success; call again after pump progress.
    Stopped means no owned callbacks/resources can revive, with durable intents
    transferred to their explicit persistence/recovery owner. Failures remain
    retryable; never stop the shared client or discard another consumer's state.
    Host closes the pump/client only after ALL owners reach their terminal fence.
    Current Mailbox.cancel alone cannot prove this obligation. *)
