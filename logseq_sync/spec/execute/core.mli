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

type completion_status = Applied | Duplicate | Obsolete | Foreign
type resource_handoff =
  | Producer_retains
  | Runtime_owns of Dsl.resource_reference Rrbvec.t
type completion_ack =
  { status : completion_status; resources : resource_handoff }
(** Applied ACKs queued terminal admission, not interpretation/commit/join.
    Duplicate never replays; Obsolete cannot resume; Foreign transfers nothing.
    Runtime_owns lists exactly validated cleanup references, including duplicates;
    all unlisted references, Producer_retains and Error remain producer-owned.
    Duplicate/Obsolete may adopt original-owner resources only for cleanup.
    Reserve cleanup capacity before ACK or return Error Capacity_exceeded.
    Producer releases/retains every untransferred resource, never releases or
    reacquires transferred ones. Resource-bearing results MUST use complete+Pending
    even synchronously; illegal Finished retains producer cleanup and fails protocol.
    Join fails Cleanup_failure while producer-owned resources remain unresolved. *)

type 'a completion = ('a, Dsl.error) result -> (completion_ack, Dsl.error) result
(** Per-invocation sealed callback binds runtime/operation/original owner/incarnation/
    context version. Concurrent calls only enqueue, never interpret/reenter inline.
    Terminal selection/insertion is atomic; reserve capacity before dispatch so
    no terminal/cleanup is dropped. Stage callback-before-return until Pending
    installs its job; complete then Finished is Protocol_failure, retaining both
    cleanup obligations and draining if producers remain. Validate identity and
    resource producer: stale/duplicate cannot replay or release twice, foreign
    remains with producer. Keep original owner/callback through delivery and join;
    successful join promises no future calls. Later misuse is classified without
    reactivation; retain only bounded classification metadata, not growing jobs. *)

type job =
  { cancel : unit -> (unit, Dsl.error) result
  ; join : unit -> (unit, Dsl.error) result }
(** cancel requests only; join proves operation and all resource/callback producers
    stopped calling complete. Failure retains job/cause; maximum_pending bounds jobs. *)

type 'a admission = Finished of ('a, Dsl.error) result | Pending of job
(** Finished has no resources or remaining producer. Pending owes one terminal
    complete (also on cancellation) and physical join. Uncertain external admission
    returns Outcome_unknown, never claims no effect. *)

type effect_scope
val check_current : effect_scope -> (unit, Dsl.error) result
val admit_network : effect_scope -> (unit, Dsl.error) result
(** Check current scope immediately before irreversible database/crypto/asset work.
    admit_network atomically rechecks gate/cancel/actual epoch and registers each
    actual remote attempt (also delayed jobs); success is not a reusable permit.
    Admitted outcomes still reconcile after revocation. Original-owner cleanup
    bypasses current authority checks, never original resource validation. *)

type database_owner

type dispatch =
  { database : 'a. owner:database_owner -> scope:effect_scope -> identity:Dsl.identity
      -> complete:'a completion -> 'a Dsl.database -> 'a admission
  ; transport : 'a. scope:effect_scope -> identity:Dsl.identity
      -> complete:'a completion -> 'a Dsl.transport -> 'a admission
  ; crypto : 'a. scope:effect_scope -> identity:Dsl.identity
      -> complete:'a completion -> 'a Dsl.crypto -> 'a admission
  ; assets : 'a. scope:effect_scope -> identity:Dsl.identity
      -> complete:'a completion -> 'a Dsl.assets -> 'a admission }
(** Database delegates only sync operations to the shared owner, preserving complete
    through commit/deferral. Never fabricate Activated/Applied before commit;
    domain Deferred differs from execution Pending and neither proves join.
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
    retains jobs/resources and reports Cleanup_failure. Unknown writes report
    Outcome_unknown; ordinary setup/read expiry Network_failure with bounded stage.
    Certificate failure remains Authentication_failure, malformed data Protocol_failure;
    neither becomes retryable timeout. No rollback or unchanged security retry. *)

type capabilities =
  { validate_identity : Dsl.identity -> (unit, Dsl.error) result
  ; validate_limits : Dsl.limits -> (unit, Dsl.error) result
  ; websocket_liveness : websocket_liveness
  ; network_deadlines : network_deadlines
  ; acquire : Dsl.identity -> (unit, Dsl.error) result
  ; fence_network : Dsl.identity -> (unit, Dsl.error) result
  ; close_network : Dsl.identity -> (unit, Dsl.error) result
  ; authorize_network : Dsl.identity -> epoch:int64 -> (unit, Dsl.error) result
  ; validate_resource : Dsl.resource_reference -> (unit, Dsl.error) result
  ; restore : scope:effect_scope -> Dsl.identity
      -> complete:Dsl.restore_report completion -> Dsl.restore_report admission
  ; dispatch : dispatch
  ; observe : Dsl.identity -> (Dsl.observation, Dsl.error) result
  ; fence : Dsl.identity -> (unit, Dsl.error) result
  ; retire : Dsl.identity -> (unit, Dsl.error) result
  ; release_file : Dsl.identity -> Dsl.asset_file -> (unit, Dsl.error) result
  ; release_lease : Dsl.identity -> Dsl.asset_lease -> (unit, Dsl.error) result
  ; release_snapshot : Dsl.identity -> Dsl.snapshot -> (unit, Dsl.error) result }
(** validate_identity checks actual origin/account/graph/generations on admissions/
    completions; caller serializes generation changes with fencing. acquire reserves
    exclusive graph writer atomically; failure leaves none, retire releases it.
    Validate configuration BEFORE acquire/allocation/enumeration: actual outbox
    records/descriptors must fit DSL bounds (no truncation); asset cache/file/pending
    and snapshot artifact/staging/scratch limits must exactly match configured owners.
    Chunks/batches/frames must fit small-memory limits; never substitute asset limits
    or a smaller artifact cap. Validation reads immutable configuration only;
    mismatch is Invalid_input. Restore incrementally accounts disk recovery.
    Validate liveness/deadlines before acquire and install exact policy before
    Connect succeeds. Authenticate each actual HTTP/socket admission with current
    credentials; only one checked refresh, then explicit correction, no hidden loop.
    Limits stay immutable while acquired. fence_network is nonblocking admission
    fence/cancel, callable from control fiber; runtime closes its gate first even
    on error. close_network physically joins idle sockets and callback producers
    as well as jobs; failed cleanup keeps Closed, reopening waits for old join.
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
    start forks, await suspends its caller only. Pending producers still require
    explicit join after fiber cancel; parent cancellation fences/joins all owners.
    Finish checked retirement before releasing database/scheduling owners.
    Execute privately creates Dsl.Producer.owner; allocate typed task promises
    after capacity reservation, binding child poll to the exact task. Task_join
    validates owner/live scope/registration before callback, waits on readiness,
    physically joins then forgets. Failed join retains scope/cleanup. Ingress,
    outbox, channels and outputs reserve/register operation ledgers before delivery;
    Producer checks never replace current revision/authority/resource validation.
    Client-created equal-identity owners are foreign: reject before callbacks/use.
    Context/version, running, effect_scope/completion, database binding, network
    retirement and observation revisions are runtime-created process-local values;
    reads/repeated await return the same registered values, never fresh authority.
    Bounded queues are runtime mechanics; sync/retry/scheduling remain pure EDSL. *)

val start : t -> 'before graph_context -> ('before, 'after, 'a) Dsl.t
  -> (('after, 'a) running, Dsl.error) result
val await : ('after, 'a) running -> ('after, 'a) outcome
(** One admitted program per runtime. start atomically checks actual identity/phase,
    current version/capacity and reserves version once; rejected stale/foreign/
    copied contexts cause no effects. Serialize continuations and install state
    before next dispatch; exceptions preserve actual context/resources/causes.
    Network gate/actual epoch checked at dispatch AND execution; local restore/
    inspect never contacts server. Close fences immediately, indexed Close or
    await_network_retirement joins without rollback. Drain/retire failure stays
    draining. await is repeatable after admitted jobs deliver/join or cleanup
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
    serialize. Contexts/completions/jobs/resources survive no restart. Observation
    is neither database user query nor presentation ACK. *)
