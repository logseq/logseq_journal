(** Interpret one graph incarnation with injected owners. Caller owns authorization,
    account coordination and database lifetime. Context versions are runtime-linear:
    rejection preserves one, each admitted terminal outcome returns the sole next
    context (including failure/cancel). Install it before another start. *)

module Dsl = Sync_dsl.Core

type t
type 'state graph_context
type context = Context : 'state Dsl.phase * 'state graph_context -> context
type ('after, 'value) outcome =
  | Completed of 'after graph_context * 'value
  | Failed of context * Dsl.error
type ('after, 'value) running

type effect_scope
(** Fresh per invocation; sealed to runtime, owner, incarnation and context version. *)

val handoff : effect_scope -> Dsl.resource_reference Rrbvec.t
  -> (unit, Dsl.error) result
(** Non-suspending, cancellation-masked atomic transfer into Execute's cleanup
    ledger, reserved before acquisition. Validate exact invocation/original owner,
    kind and immutable metadata. Success owns every reference; failure transfers
    no new references.
    Earlier successful transfers are never undone by a later rejection.
    Repeated transfer of the same registered references is idempotent; foreign
    references never transfer. Revoked scopes may accept original resources for
    cleanup only, never resume work. Charges survive return, cancellation and scope
    exit until physical release; received consumer leases have independent lives.
    Resource-owned services (e.g. socket reader) transfer with the reference into
    the retained original owner's ledger, not detached invocation fibers. Effect
    join ends acquisition; resource release/retirement joins those services.
    Install original-owner cleanup before any suspending acquisition; that owner
    records acquired resources even if acquisition raises/cancels before delivery.
    Protect only bounded registration/handoff, not acquisition I/O. On rejection/
    exception, finally resolves untransferred resources or retains cleanup failure.
    ACK forbids producer use/release of transferred references. Returning a resource
    requires successful handoff first; cancellation before return cannot leak it. *)

module Callback_bridge : sig
  type 'a producer =
    { start : deliver:(('a, Dsl.error) result -> (unit, Dsl.error) result)
        -> (unit, Dsl.error) result
    ; stop : unit -> (unit, Dsl.error) result
    ; await_stopped : deadline:float -> (unit, Dsl.error) result }
  val run : scope:effect_scope -> resources:('a -> Dsl.resource_reference Rrbvec.t)
    -> 'a producer -> ('a, Dsl.error) result
  (** Only for external callbacks/non-interruptible producers. Register producer
      and bounded terminal/cleanup capacity before start, including failed/raising
      start. deliver is thread-safe, non-suspending and never interprets inline;
      atomically select one terminal and hand off validated resources before ACK.
      Error ACK transfers no new references; earlier transfers remain owned.
      Producer cleans every untransferred reference.
      Duplicate/late original resources transfer for cleanup only; foreign remain
      producer-owned. No replay or double release; bounded identity watermarks.
      Callback-before-start-return is legal. start/stop must return promptly;
      await_stopped may suspend but must respect its absolute monotonic deadline.
      Execute derives deadlines from its clock and cleanup_seconds.
      resources is pure, total and lists every result-owned reference; no secrets.
      Before returning or propagating cancellation, stop as needed and confirm
      all callbacks/native work stopped and untransferred resources resolved.
      Never mask an unbounded wait.
      Failed/timed-out join retains producer, original owner and charges in the
      scope ledger, returns Cleanup_failure with primary/cleanup causes and forces
      actual draining; retirement/reopen cannot bypass it. Retained cleanup is
      retried explicitly by retirement, without a background dispatch loop.
      Cancellation is neither physical stop nor database rollback; uncertain writes
      retain durable identifiers and Outcome_unknown. Successful join forbids further
      callbacks; later misuse cannot reactivate a scope or abandon owner cleanup. *)
end

val check_current : effect_scope -> (unit, Dsl.error) result
val admit_network : effect_scope -> (unit, Dsl.error) result
(** Check current scope immediately before irreversible database/crypto/asset work.
    admit_network atomically rechecks gate/cancel/actual epoch and registers each
    actual remote attempt (also after suspension); success is not a reusable permit.
    Admitted outcomes still reconcile after revocation. Original-owner cleanup
    bypasses current authority checks, never original resource validation. *)

type database_owner

type dispatch =
  { database : 'a. owner:database_owner -> scope:effect_scope -> identity:Dsl.identity
      -> 'a Dsl.database -> ('a, Dsl.error) result
  ; transport : 'a. scope:effect_scope -> identity:Dsl.identity
      -> 'a Dsl.transport -> ('a, Dsl.error) result
  ; crypto : 'a. scope:effect_scope -> identity:Dsl.identity
      -> 'a Dsl.crypto -> ('a, Dsl.error) result
  ; assets : 'a. scope:effect_scope -> identity:Dsl.identity
      -> 'a Dsl.assets -> ('a, Dsl.error) result }
(** Execute forks effects in its Eio task/scope tree and joins on every exit.
    Functions may suspend; return means owned subfibers and producers are stopped,
    except retained Cleanup_failure obligations. Use finally/protect for cleanup;
    short masked handoffs/commit bookkeeping only, never unlimited masked I/O.
    Cleanup uses cleanup_seconds; failure retains original owner/handles/charges,
    reports Cleanup_failure and forces draining even for direct effects.
    Resource results use handoff; Execute installs return values without suspension
    before checking cancellation, preserving cleanup even if no continuation runs.
    External work uses Callback_bridge, not detached fibers or a second lifecycle.
    Database delegates only sync operations to the shared owner through commit/
    deferral. Never fabricate Activated/Applied before commit; Deferred is domain
    data, not unfinished execution. Cancellation cannot erase durable outcomes.
    Lost commit response is Outcome_unknown with durable identity, not fresh replay.
    Composite preparation uses the same scoped crypto owner; match optional request,
    IDs/counts/generation exactly. Snapshot unprotection streams bounded batches,
    validating all plaintext before commit; no raw keys or plaintext fallback.
    Cancel releases staging even when commit raced; durable receipts decide outcome.
    Transport matches Pull by generation/issued baseline through its sole reader;
    txs=[] yields No_progress with since from request ledger, through >= baseline.
    Empty/replayed pages never Apply_authoritative. Sync recovery/pacing is EDSL.
    Snapshot download enforces actual/declared artifact ceiling before each write;
    verification/activation independently reserve aggregate staging and scratch,
    charging both through cancellation/failed cleanup. Stream full checksum/row
    verification in maximum_bytes/items batches, never artifact-sized buffers.
    Bind expected rows in producer ledger; verify count/checksum/encryption on
    activation and release original snapshot on every path. Crypto checks scoped
    envelopes; assets own durable publication/recovery and original cleanup.
    All adapters reject foreign identities/resources and retain typed causes,
    without secrets or adapter business loops. *)

type websocket_liveness =
  | Peer_close_only
  | Ping_pong of { interval_seconds : float; timeout_seconds : float }
(** Finite positive monotonic values. Single socket owner reports ping/pong timeout
    as Network_lost, never Changed. Peer_close_only has no silent-peer deadline. *)

type network_deadlines =
  { setup_seconds : float; tls_handshake_seconds : float
  ; http_response_seconds : float; download_seconds : float }
(** Finite positive monotonic durations: setup covers DNS/TCP across addresses;
    each TLS handshake is bounded separately (also websocket). HTTP covers write,
    headers and complete body cumulatively across redirects/one refresh. Download
    covers entire transfer/setup/refresh/redirects; progress never resets deadlines.
    Liveness is separate. Expiry cancels/joins I/O/staging/callbacks; failed cleanup
    retains producers/resources and reports Cleanup_failure. Unknown writes report
    Outcome_unknown; ordinary setup/read expiry Network_failure with bounded stage.
    Certificate failure remains Authentication_failure, malformed data Protocol_failure;
    neither becomes retryable timeout. No rollback or unchanged security retry. *)

type capabilities =
  { validate_identity : Dsl.identity -> (unit, Dsl.error) result
  ; validate_limits : Dsl.limits -> (unit, Dsl.error) result
  ; websocket_liveness : websocket_liveness
  ; network_deadlines : network_deadlines
  ; cleanup_seconds : float
  ; acquire : Dsl.identity -> (unit, Dsl.error) result
  ; fence_network : Dsl.identity -> (unit, Dsl.error) result
  ; close_network : Dsl.identity -> (unit, Dsl.error) result
  ; authorize_network : Dsl.identity -> epoch:int64 -> (unit, Dsl.error) result
  ; validate_resource : Dsl.resource_reference -> (unit, Dsl.error) result
  ; restore : scope:effect_scope -> Dsl.identity
      -> (Dsl.restore_report, Dsl.error) result
  ; dispatch : dispatch
  ; observe : Dsl.identity -> (Dsl.observation, Dsl.error) result
  ; fence : Dsl.identity -> (unit, Dsl.error) result
  ; retire : Dsl.identity -> (unit, Dsl.error) result
  ; release_file : Dsl.identity -> Dsl.asset_file -> (unit, Dsl.error) result
  ; release_lease : Dsl.identity -> Dsl.asset_lease -> (unit, Dsl.error) result
  ; release_snapshot : Dsl.identity -> Dsl.snapshot -> (unit, Dsl.error) result }
(** Restore follows the dispatch ownership/cancellation contract, using local I/O.
    validate_identity checks actual origin/account/graph/generations on admissions/
    completions; caller serializes generation changes with fencing. acquire reserves
    exclusive graph writer atomically; failure leaves none, retire releases it.
    Validate configuration BEFORE acquire/allocation/enumeration: actual outbox
    records/descriptors must fit DSL bounds (no truncation); asset cache/file/pending
    and snapshot artifact/staging/scratch limits must exactly match configured owners.
    Chunks/batches/frames must fit small-memory limits; never substitute asset limits
    or a smaller artifact cap. Validation reads immutable configuration only;
    mismatch is Invalid_input. Restore incrementally accounts disk recovery.
    Validate finite positive cleanup_seconds and liveness/deadlines before acquire;
    install exact policy before Connect succeeds. Authenticate each actual HTTP/
    socket admission with current credentials; only one checked refresh, then explicit correction, no hidden loop.
    Limits stay immutable while acquired. fence_network is nonblocking admission
    fence/cancel, callable from control fiber; runtime closes its gate first even
    on error. close_network physically joins idle sockets and callback producers
    as well as effect fibers; failed cleanup keeps Closed, reopening waits for old join.
    authorize_network checks actual caller epoch at open and every execution.
    validate_resource checks original ledger/identity/kind/immutable metadata even
    for post-revocation cleanup; descriptors alone grant no access. observe is
    bounded atomic sync metadata, never graph scan/switch. Runtime owns gate/counts.
    fence forbids original-owner admissions/writes; failed fence remains draining.
    retire ACKs delegation/subscription/resource retirement, NOT database close or
    deletion; no success with producers/leases/snapshots/cleanup outstanding.
    Release targets retained original owners despite authority changes; failure
    retains exact handle/cause. Caller retains old owners through retirement and
    owns graph/account replacement/destruction. No global cache or new durable store. *)

val database_owner : Dsl.Overlay.Database.t -> database_owner
val activation_owner : dependencies:Dsl.Overlay.Database.dependencies
  -> inspection:Dsl.Overlay.Database.mirror_inspection -> graph_name:string
  -> (database_owner, Dsl.error) result
val database : database_owner -> (Dsl.Overlay.Database.t, Dsl.error) result
(** activation_owner binds an inspected absent mirror to the same sole queue;
    bounded validation, no network/second writer. Restore checkpoint is None and
    database fails Storage_failure until activation prepares/streams/commits then
    opens/installs the actual mirror before Activated. Interrupted open retains
    committed inspection for local recovery, never re-download/overwrite. Available
    mirrors use database_owner; caller still owns eventual close. *)
(** Bind the actual sole external transaction queue, shared with user writes,
    asset metadata and activation. Check generation/token/ordering at commit.
    Crypto/asset/network preparation is outside transactions; after suspension
    revalidate or return exact conflict. Never hold a transaction across network,
    task/key/callback waits; no parallel fallback writes or hidden business retry. *)

val create : sw:Eio.Switch.t -> clock:'clock Eio.Time.Mono.t
  -> database_owner:database_owner
  -> identity:Dsl.identity -> limits:Dsl.limits -> capabilities
  -> (t * Dsl.cold graph_context, Dsl.error) result
(** Validate actual identity/configuration locally before exclusive acquire; failed
    create leaves no registration/resource. One runtime per graph incarnation.
    Eio switches own runtime/program/task scopes and control/retirement fibers;
    start forks, await suspends its caller only. Fiber cancellation joins structured
    children; external producers additionally require bridge physical join. Parent
    cancellation fences all owners; bounded cleanup failure retains actual draining.
    Finish checked retirement before releasing database/scheduling owners.
    Execute privately creates Dsl.Producer.owner; allocate typed task promises
    after capacity reservation, binding child poll to the exact task. Task_join
    validates owner/live scope/registration before callback, waits on readiness,
    physically joins then forgets. Failed join retains scope/cleanup. Ingress,
    outbox, channels and outputs reserve/register operation ledgers before delivery;
    Producer checks never replace current revision/authority/resource validation.
    Client-created equal-identity owners are foreign: reject before callbacks/use.
    Context/version, running, effect_scope, database binding, network
    retirement and observation revisions are runtime-created process-local values;
    reads/repeated await return the same registered values, never fresh authority.
    Bounded queues are runtime mechanics; sync/retry/scheduling remain pure EDSL. *)

val start : t -> 'before graph_context -> ('before, 'after, 'a) Dsl.program
  -> (('after, 'a) running, Dsl.error) result
val await : ('after, 'a) running -> ('after, 'a) outcome
(** One admitted program per runtime. start atomically checks actual identity/phase,
    current version/capacity and reserves version once; rejected stale/foreign/
    copied contexts cause no effects. Serialize continuations and install state
    before next dispatch; exceptions preserve actual context/resources/causes.
    Network gate/actual epoch checked at dispatch AND execution; local restore/
    inspect never contacts server. Close fences immediately, indexed Close or
    await_network_retirement joins without rollback. Drain/retire failure stays
    draining. await is repeatable after admitted effect fibers return/join or cleanup
    failure is retained. Unjoined producers bypass indexed failure continuations:
    fence and return actual draining context with Cleanup_failure/all causes.
    Only joined ordinary failure enters its declared branch; durable unknown
    outcome never permits fresh send. *)

type network_retirement
val close_network : t -> (network_retirement, Dsl.error) result
val await_network_retirement : network_retirement -> (unit, Dsl.error) result
val open_network : t -> authorization_epoch:int64 -> (unit, Dsl.error) result
(** Independent control while programs suspend: close fences/cancels without join;
    receipt proves fence only. Failure stays Closed with cleanup owed; repeated
    close returns same outstanding receipt/error. await joins exact old generation,
    retaining receipt/cause on failure. Local Ready work continues; no graph drain.
    open checks actual epoch and rejects until old join, never waits hiddenly.
    Indexed Set_network Closed fences+joins; Open shares checks. No new bytes
    after fence; network/task cancellation is not graph retirement. *)

val notify_outbox_changed : t -> owner:database_owner -> identity:Dsl.identity
  -> (unit, Dsl.error) result
(** Actual database owner invalidates only after durable eligibility-changing commit.
    Validate full binding/incarnation; foreign/replaced/retired cannot wake another
    graph. Success marks an independent fixed dirty slot, not Inspect/upload ACK;
    coalesce even without waiter/service/Open or demand capacity. Preserve commits
    during Inspect using captured-epoch ACK, never unconditional clear. Slot lives
    until graph retirement. Initialize/activate/reopen dirty; Connected Resamples.
    Closed permits local inspection only. Notification error preserves durable
    success: report/rebind, never replay user write. Restart reconciles dirty outbox. *)

type ingress_ack = Queued | Replaced
val submit_unlock : t -> identity:Dsl.identity -> valid_for:float
  -> Dsl.unlock_input -> (ingress_ack, Dsl.error) result
(** Wrapped-only active-service ingress, also Locked/Closed. valid_for is finite
    monotonic (0,300] seconds. Validate incarnation/reserve shared message count/bytes
    before copy; one pending revision. Replacement invalidates delivered-unconsumed
    receipt and wakes sole input waiter; rejection retains caller ownership/old input.
    Expiry discards payload/notice; Consume_unlock consumes exact live envelope
    atomically before crypto. Replacement cannot change admitted work. Scope exit/
    stop/cancel/replacement discards unconsumed input. No secrets in diagnostics;
    ACK means queued, not unlocked. Without active Run_task return Stale_context. *)

val update_demand : t -> Dsl.demand_change -> (ingress_ack, Dsl.error) result
val receive_demand : t -> (Dsl.demand_output, Dsl.error) result
type delivery_status = Current | Revoked
val demand_status : t -> Dsl.demand_delivery -> (delivery_status, Dsl.error) result
val release_demand : t -> Dsl.demand_delivery -> (unit, Dsl.error) result
(** One receiver waits independently of await. Atomic dequeue checks revision/
    incarnation and transfers existing delivery use obligation, not a new lease.
    Stale queued output is cleaned, never returned. Received file use requires its
    lease; caller releases even after revoke/stop/cancel. Before dequeue cancel
    transfers nothing; after dequeue caller must retain delivery. Empty scope exit
    wakes Cancelled. Replacement/withdraw/scope exit/fence marks received Revoked,
    never reclaims bytes under consumer. Receipt ACK is not presentation/release.
    Count/message/resource charges persist until release ACK. release_demand works
    during drain/replacement via original owners, lease before file; success requires
    physical release. Failure retains exact delivery/cause/slots; foreign fails
    without cleanup, duplicate succeeds without double release. Bound duplicate
    classification by monotonic watermarks, not growing tombstones. Keep owners
    until all received/unreceived deliveries and cleanup resolve. *)
val request_stop : t -> (unit, Dsl.error) result
(** Independent ingress, no context reservation. Validate identity/revision/bounds
    before copy/admit. Latest unconsumed same-ID update replaces atomically; Withdraw
    coalesces, other IDs never drop. Capacity rejection preserves accepted update;
    caller retains rejected update. Active+pending interests count until Finish_demand;
    descriptor/foreground reservations apply before ingress, also with no foreground
    transfer. Same-ID net accounting charges one interest; old cleanup stays charged.
    Demotion checks background ceiling; dedup never exempts distinct IDs. Live
    withdrawal uses existing control slot; unknown withdrawal is idempotent without
    tombstones. Reclaim only at discard/Finish/release, not dequeue. No silent eviction.
    Stop/gate reserve independent slots and wake sole Next_input waiter; second
    consumer fails. request_stop is idempotent graceful input, not forced cancel/
    drain. Run_task return cancels/joins scope and returns Ready; forced cancel
    fences and returns actual draining context. *)

val cancel : t -> ('after, 'a) running -> (unit, Dsl.error) result
(** Cancel exact execution and fence effects; foreign has no effect, accepted repeats
    are idempotent, terminal rejects without changing context. Failed outcome carries
    actual draining phase and Cancelled/Outcome_unknown/original cleanup causes.
    Commits stay committed and cleanup remains registered without await. Not retirement. *)

val current : t -> (context, Dsl.error) result
(** Idle-only recovery returns same current phase/version, never new authority;
    active rejects. Explicitly drain actual phase, join all producers and require
    capabilities.retire ACK. Cleanup failure keeps draining/original obligations. *)

type observation_revision
type runtime_observation =
  { revision : observation_revision; state : Dsl.observation
  ; status : Dsl.service_status }
val observe_runtime : t -> (runtime_observation, Dsl.error) result
val await_observation : t -> after:observation_revision
  -> (runtime_observation, Dsl.error) result
(** Independent bounded latest snapshot on status/gate/key/checkpoint/count/cleanup/
    terminal changes. Atomic revision compare+wait loses no invalidation; one waiter,
    cancellation consumes nothing. Fresh runtime-bound revisions, foreign rejects.
    Coalesce, never log/scan/Inspect/network. Actual metadata/errors override optimistic
    policy. Retired remains readable; unchanged retired await fails Stale_context. *)

val identity : 's graph_context -> Dsl.identity
val phase : 's graph_context -> 's Dsl.phase
type version
val version : 's graph_context -> version
val equal_version : version -> version -> bool
(** Metadata never refreshes authority; fresh process-local versions do not wrap or
    serialize. Contexts/scopes/bridge producers/resources survive no restart. Observation
    is neither database user query nor presentation ACK. *)
