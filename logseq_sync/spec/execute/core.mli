(** {1 TLDR}

    Interpret [Sync_dsl.Core] programs for one graph using injected capabilities;
    own process-local execution, versioned contexts and checked physical retirement.
    The dependency points from this module to the pure program protocol, never
    back. The caller owns authorization, account coordination and database lifetime.
    No implementation or build registration is supplied by this proposal.

    Primary entry points (declared below):
    {[
      val create : sw:Eio.Switch.t -> clock:'clock Eio.Time.Mono.t
        -> database_owner:database_owner
        -> identity:Sync_dsl.Core.identity -> limits:Sync_dsl.Core.limits
        -> capabilities -> (t * Sync_dsl.Core.cold graph_context, Sync_dsl.Core.error) result
      val start : t -> 'before graph_context -> ('before, 'after, 'a) Sync_dsl.Core.t
        -> (('after, 'a) running, Sync_dsl.Core.error) result
      val await : ('after, 'a) running -> ('after, 'a) outcome
    ]}
    Admission consumes a context version at most once at runtime, not by OCaml
    linear types. Rejection leaves it unconsumed. Every admitted terminal outcome
    supplies the only current context, including failures and cancellation.
    Each adapter receives a typed [complete] bound to that single operation;
    capabilities are constructed without a runtime reference. Completion only
    admits a queued result, never reenters interpretation; its ack is not physical
    join. Cancellation and retirement retain original-owner cleanup obligations. *)

module Dsl = Sync_dsl.Core

type t
type 'state graph_context
type context = Context : 'state Dsl.phase * 'state graph_context -> context
type ('after, 'value) outcome =
  | Completed of 'after graph_context * 'value
  | Failed of context * Dsl.error
type ('after, 'value) running

(** {1 Minimal usage example}

    The caller supplies an Eio [sw], monotonic [clock], the shared [database_owner],
    validated [identity], [limits] and [capabilities], and [on_restored], a pure
    ready-to-ready continuation. All error values escape:
    {[
      match create ~sw ~clock ~database_owner ~identity ~limits capabilities with
      | Error cause -> Error (None, cause)
      | Ok (runtime, context) ->
        let program = Dsl.perform Dsl.restore
            ~success:on_restored ~failure:Dsl.abort in
        match start runtime context program with
        | Error cause ->
          Error (Some (runtime, Context (Dsl.Cold, context)), cause)
        | Ok running -> Ok (runtime, await running)
    ]}
    A rejected start retains the runtime and unconsumed context in the Error
    payload for explicit drain/retirement; the original cause is not discarded.
    The caller installs the returned context, even on [Failed], before submitting
    another program. It keeps capabilities and completion delivery alive, then
    executes [begin_drain] and [finish_retirement] with that actual phase before
    releasing its database and scheduling resources. Creating a runtime performs
    no remote work; restoration does not open the network gate.

    Adapter wiring needs no late mutable runtime reference. Here [owners] is a
    caller-built capabilities record, [read_head] is a synchronous owner operation,
    and [schedule_head] schedules that operation and returns a job. It passes
    [complete]'s result back to the producer: every ack/error must be handled under
    the completion ownership rules below, not discarded. Both owner operations
    receive the scope and identity and check network authority at actual execution;
    the scheduler also supports callback-before-return and cancellation delivery.
    The deliberately partial example rejects other transport operations explicitly:
    {[
      let sync_transport
          (read_head : scope:effect_scope -> identity:Dsl.identity
            -> Dsl.connection -> (Dsl.remote_head, Dsl.error) result)
          (type a) ~scope ~identity
          ~complete:(_ : a completion) (operation : a Dsl.transport) : a admission =
          match operation with
          | Dsl.On_connection (connection, Dsl.Head) ->
            Finished (read_head ~scope ~identity connection)
          | _ -> Finished (Error (Dsl.Protocol_failure "unsupported transport"))

      let async_transport
          (schedule_head : scope:effect_scope -> identity:Dsl.identity
            -> Dsl.connection -> complete:Dsl.remote_head completion -> job)
          (type a) ~scope ~identity
          ~(complete : a completion) (operation : a Dsl.transport) : a admission =
          match operation with
          | Dsl.On_connection (connection, Dsl.Head) ->
            Pending (schedule_head ~scope ~identity connection ~complete)
          | _ -> Finished (Error (Dsl.Protocol_failure "unsupported transport"))

      let connect ~sw ~clock ~database_owner owners schedule_head identity limits =
        let dispatch =
          { owners.dispatch with
            transport = (fun ~scope ~identity ~complete operation ->
              async_transport schedule_head ~scope ~identity ~complete operation) } in
        let capabilities = { owners with dispatch } in
        create ~sw ~clock ~database_owner ~identity ~limits capabilities
    ]}
    The same per-invocation completion contract applies to database, crypto,
    assets and restore, including partially acquired restoration resources. *)

(** {1 Construction and validation} *)

type completion_status = Applied | Duplicate | Obsolete | Foreign
type resource_handoff =
  | Producer_retains
  | Runtime_owns of Dsl.resource_reference Rrbvec.t
type completion_ack =
  { status : completion_status; resources : resource_handoff }
(** Applied means the exact terminal result was admitted to the serialized queue,
    not interpreted, committed or physically retired. Duplicate means a terminal
    result was already admitted for this invocation. Obsolete means its internal
    operation/identity/version binding is no longer current; it cannot resume a
    continuation. Foreign means the result's actual identity or resource producer
    failed validation; it grants no adoption or cleanup authority. These checks
    remain runtime obligations even though the operation binding is sealed inside
    the injected callback. Error reports the actual validation/admission failure;
    it never silently transfers resource ownership. The resources field is the
    exhaustive ownership ACK: Runtime_owns lists the exact validated references
    whose cleanup Execute has registered (including already-owned duplicates).
    All other resources remain with the producer. Producer_retains and Error
    transfer nothing. Foreign always uses Producer_retains. Duplicate/Obsolete
    may adopt newly returned original-owner resources solely for cleanup, without
    resuming business logic. Adoption reserves cleanup capacity before ACK; if
    unavailable, return Error Capacity_exceeded and leave producer ownership.
    The producer must release or retain/retry cleanup for every non-transferred
    resource, including cancellation/expiry/late delivery. It must not release
    references acknowledged Runtime_owns, nor resend them as new acquisitions.
    Resource-bearing success must use complete plus Pending, even if produced
    synchronously (callback-before-return is supported). Finished is permitted
    only for results without resource ownership, so it cannot bypass this ACK.
    An illegal resource-bearing Finished is a protocol failure and the original
    producer retains cleanup until a checked complete handoff or release.
    A joined producer cannot have unresolved producer-owned resources: join fails
    with Cleanup_failure until released or explicitly adopted. *)

type 'a completion = ('a, Dsl.error) result -> (completion_ack, Dsl.error) result
(** Execute creates [complete] separately for each adapter invocation, binding its
    result type and internal ticket to the exact runtime, operation, original owner,
    identity/incarnation and context version. Adapters need neither a runtime nor
    a public ticket; construct capabilities before calling [create]. Bindings are
    process-local and cannot be reconstructed from external IDs or reused for a
    different invocation. The callback may be called concurrently, including before
    admission returns; it only queues, never interprets or invokes continuations
    inline. Admission, terminal selection and queue insertion are atomic.

    Exactly one terminal result may win across [Finished] and callback delivery.
    Execute stages callback-before-return delivery until the admission is known;
    [Pending] installs its job before queued delivery is consumed. Returning
    [Finished] after calling [complete] is a protocol failure, not a second result;
    retain both cleanup obligations and fence to draining if producers remain.
    Repeated/concurrent callbacks do not replay a continuation or durable mutation.
    Duplicate/obsolete results still require checked original-producer cleanup of
    newly returned resources, without releasing a live resource twice; foreign
    resources remain with their actual producer and are never released by a
    mismatched owner. Queue admission reserves bounded terminal capacity before
    dispatch; saturation cannot drop a terminal result or its cleanup obligation.

    Keep the callback and original owner alive through terminal delivery and a
    successful job join. Join success promises no further producer calls; late
    misuse is still classified without reactivating the retired owner. A retained
    callback retains only bounded binding/classification metadata after join,
    not an unbounded job ledger. Rejected or foreign delivery leaves producer
    ownership intact; all unresolved cleanup is exposed with its original cause. *)

type job =
  { cancel : unit -> (unit, Dsl.error) result
  ; join : unit -> (unit, Dsl.error) result }
(** [cancel] only requests cancellation. [join] succeeds only after the operation,
    its resource-producing callbacks and further calls to [complete] have stopped.
    Failed cancel/join retain the job and original cause for explicit cleanup.
    Jobs are bounded by maximum_pending, never silently dropped on revocation. *)

type 'a admission = Finished of ('a, Dsl.error) result | Pending of job
(** Finished is synchronous terminal completion with no remaining producer.
    Pending requires exactly one eventual terminal [complete], including cancellation,
    plus a successful join. Callback-before-return races must be supported;
    callbacks enqueue delivery and never reenter interpretation on the same stack.
    If admission fails after uncertain external work it returns Outcome_unknown,
    not a false promise that nothing happened. *)

type effect_scope
val check_current : effect_scope -> (unit, Dsl.error) result
val admit_network : effect_scope -> (unit, Dsl.error) result
(** The runtime supplies one scope for the exact internal operation binding.
    Adapters check current authority immediately before database/crypto/asset
    irreversible work and call
    admit_network immediately before each actual remote admission, including
    delayed jobs. It atomically checks the runtime gate, cancellation and actual
    authorization epoch and registers the attempt for cancellation/join. Success
    is not a reusable network permit. Closed/revoked scopes cannot admit work;
    already admitted work may finish and must reconcile its original outcome.
    Original-owner cleanup does not require current network/account authority;
    cleanup database/asset requests must not use check_current to reject it. *)

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
(** The database adapter delegates only synchronization requests to the actual
    database owner. It cannot manufacture Activated/Applied before durable commit,
    collapse Deferred to success, execute user mutations or impersonate a host.
    For asynchronous delegation it preserves this invocation's [complete] through
    queueing, commit/deferral and terminal delivery. A commit followed by lost
    response is Outcome_unknown with retained durable identity, not permission
    for fresh replay.
    Database effects are composite sync transactions: their adapter performs the
    external owner's begin/protection-or-unprotection/apply protocol. It uses the
    same scoped crypto service as the crypto adapter, matching optional requests,
    item IDs, counts and prepared generation exactly before commit. Snapshot
    activation streams bounded unprotection batches and commits only after all
    requested plaintexts validate. No raw key is exposed to the program. A
    protected request cannot be satisfied by plaintext fallback or a different
    graph's key. Preparation cancellation releases its staging even if commit
    raced; committed receipts, not cancellation, decide the durable outcome.
    Domain Deferred is a completed call whose business barrier remains pending;
    Pending is an unfinished execution. Neither means physical join.

    Transport owns authenticated bounded framing and socket retirement. Crypto
    owns checked envelopes and scoped secret handles, never plaintext fallback.
    Assets own staging, durable publication/recovery and original resource cleanup.
    All adapters reject foreign identities and resources, preserve typed domain
    results, and retain original failure diagnostics without secrets. Injection
    changes the execution mechanism, not the pure synchronization decisions. *)

type capabilities =
  { validate_identity : Dsl.identity -> (unit, Dsl.error) result
  ; validate_limits : Dsl.limits -> (unit, Dsl.error) result
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
(** [validate_identity] checks actual origin/account/graph/generations, not merely
    equality with a caller record; all normal admissions and completions recheck.
    Caller serializes generation changes with fencing. [acquire] atomically
    reserves the exclusive graph writer registration: rejection leaves none;
    successful retirement releases it. Construction validates everything else
    first, including validate_limits against actual database/asset configuration
    without enumerating data. Outbox record and descriptor budgets must fit the
    DSL budgets before Inspect may allocate; no silent truncation. Limits remain
    immutable while acquired. fence_network is an atomic nonblocking adapter
    admission fence/cancel request, independently callable from the control fiber;
    it must not wait for a program, network result or physical join. The runtime
    closes its own gate first even if this callback fails. close_network, run in
    the retirement fiber after fencing, joins idle sockets and
    transport callback producers as well as admitted jobs. Failure keeps the gate
    Closed and original cleanup obligations; reopening waits for old connection
    retirement, even after cancelled setup. The runtime owns gate/count fields
    in observations and merges them with checked capability metadata atomically.
    [authorize_network] checks the actual caller-controlled epoch at gate
    opening and every network execution, not equality with a cached epoch.
    [validate_resource] checks real original producer ledger, identity, kind and
    immutable metadata before use or adoption; pure descriptors grant no power.
    Revocation prevents new work but cannot erase original cleanup ownership.
    Original-owner cleanup bypasses current identity/network authorization,
    never resource validation. [observe] is a bounded
    atomic sync-metadata read; it cannot scan the database or silently switch graph.
    [fence] forbids new writes/admissions on the exact original owner. A failed
    fence leaves the logical context draining, with physical fencing outstanding.
    [retire] acknowledges original database delegation/subscription/resource
    retirement, not database close/deletion. It cannot succeed while producers,
    outstanding leases, staged snapshots or unresolved cleanup remain.
    Release callbacks always target retained original owners, even after current
    authorization changes; failed release retains the same handle and error.

    No global cache, account registry or new durable journal is introduced here.
    Existing database/asset records supply crash recovery. The caller keeps old
    capability owners alive until retirement and coordinates account replacement,
    graph selection, local-copy deletion and explicit destructive confirmation. *)

val database_owner : Dsl.Overlay.Database.t -> database_owner
val database : database_owner -> Dsl.Overlay.Database.t
(** A process-local binding to the actual external database's sole transaction
    queue, not a second database or writer. The supplied database dispatcher must
    route every same-graph sync mutation through that owner; external user edits,
    asset publication metadata and snapshot activation share that very queue.
    The caller must bind the actual database owner, not create parallel owners.
    Each transaction checks graph generation, current sync token and business
    ordering at commit. Crypto preparation and asset/network I/O occur outside the
    transaction; after suspension revalidate the prepared generation/token or
    return the exact conflict. Never hold an owner transaction while waiting on
    network, another task, key access or a completion callback. Deferred results
    are explicit; no fallback parallel write or hidden business retry is allowed. *)

val create : sw:Eio.Switch.t -> clock:'clock Eio.Time.Mono.t
  -> database_owner:database_owner
  -> identity:Dsl.identity -> limits:Dsl.limits -> capabilities
  -> (t * Dsl.cold graph_context, Dsl.error) result
(** Validate bounded configuration and actual identity without opening transport.
    Create one runtime per graph incarnation. The caller prevents overlapping
    runtimes from acquiring the same physical writer; create validates that
    exclusive binding with the capability owner. Failure exposes its cause and
    leaves no acquired registration/resource behind.
    [sw] owns an Eio switch per runtime, a nested switch per admitted program and
    Task_scope, and fibers for children, control ingress and retirement. [clock]
    supplies monotonic Sleep. Start forks interpretation and returns without waiting
    for the service. Await suspends only its caller. Use Eio's cancellation and
    join semantics, not a custom fiber scheduler. Adapter Pending jobs bridge
    external producers via per-invocation completion/promises; their join is still
    required even after the Eio fiber is cancelled. Parent switch cancellation
    fences and joins all these owners; cleanup errors remain explicit, not proof
    of retirement. Callers must finish checked retirement before releasing the
    database owner. Bounded completion, control and ingress queues are runtime
    mechanisms only; connection retry, sync and asset scheduling remain EDSL. *)

(** {1 Capability details} *)

val start : t -> 'before graph_context -> ('before, 'after, 'a) Dsl.t
  -> (('after, 'a) running, Dsl.error) result
val await : ('after, 'a) running -> ('after, 'a) outcome
(** [start] atomically validates runtime identity, actual phase, current context
    version, capacity and absence of another execution, then reserves that version.
    Only one admitted program per runtime. Copies of the same OCaml value are
    invalid after reservation; equality of phantom states proves no freshness.
    Invalid/reused/foreign contexts cause rejection with no program effects.
    Pure continuations run serially; the returned state is installed before
    dispatching the next effect. Synchronous capability completion follows the
    same serialized rules as queued [complete] delivery. Exceptions become explicit
    failures, retaining actual state and resources rather than losing reservations.

    Every network effect checks the explicit gate and authorization epoch both
    before dispatch and at execution; restore/inspection do not acquire tokens
    or contact servers. Closed-gate rejection performs no network work. Closing
    is effective immediately for admission; only indexed Set_network Closed or
    await_network_retirement waits for admitted jobs and reports unknown outcomes.
    It does not undo committed remote/local work.
    Drain failure always returns draining, retirement failure stays draining.

    Injected [complete] preserves the operation's result type and validates the
    internal binding, original identity and terminal delivery exactly once. A stale
    completion cannot mutate the current graph; original cleanup and durable
    reconciliation still run. Duplicate terminal delivery cannot
    allocate a second lease or replay an outbox transition. [await] returns only
    after the program's admitted jobs have delivered and joined, or an explicit
    cleanup failure has been retained by the runtime. Its result is repeatable;
    repeating await does not mint another context version. Failed physical join
    or an unquiesced producer bypasses the ordinary indexed failure continuation:
    fence and return Failed with the actual draining context and all causes in
    Cleanup_failure. Only a joined ordinary effect failure can enter its declared
    failure branch; retained durable unknown outcomes are not fresh-send authority. *)

(** {1 Lifecycle and recovery} *)

type network_retirement
val close_network : t -> (network_retirement, Dsl.error) result
val await_network_retirement : network_retirement -> (unit, Dsl.error) result
val open_network : t -> authorization_epoch:int64 -> (unit, Dsl.error) result
(** Independent control plane, callable while start/await or any task is suspended.
    close_network atomically closes admission and requests cancellation of all
    network work, including setup, reader/writer and callback producers, without
    waiting for the program or physical joins. The returned receipt proves the
    fence took effect, not quiescence. Failure after fencing leaves Closed and
    retains cleanup obligations. Repeated close returns the same outstanding
    retirement receipt (or its retained fence error), never loses its join ledger.
    await_network_retirement joins the exact old
    network generation; failure retains its receipt and original diagnostics.
    Local database, unlock and asset lookup/release tasks remain usable in Ready.
    No implicit graph drain. open_network validates the actual authorization epoch
    and rejects until old physical retirement succeeds; it never waits hiddenly.
    The existing indexed Set_network Closed is a convenience fence-and-join;
    Set_network Open has the same checks. Close races cannot admit new bytes.
    Transport retirement and task cancellation are not graph retirement. *)

type ingress_ack = Queued | Replaced
val submit_unlock : t -> identity:Dsl.identity -> valid_for:float
  -> Dsl.unlock_input -> (ingress_ack, Dsl.error) result
(** Independent wrapped-only ingress while the service is running, including
    while Locked or the gate is Closed. Validate actual graph incarnation and
    reserve count/bytes before copying the bounded envelope. valid_for is finite
    monotonic seconds in (0, 300]; no wall-clock authority. There is one pending
    wrapped revision per runtime, counting against maximum_messages and shared
    maximum_message_bytes. Replacement invalidates even a delivered but unconsumed
    receipt, discards the old envelope and wakes the sole Next_input waiter with
    Unlock_requested. ACK means queued, never unlocked. Capacity rejection retains
    caller ownership and does not replace accepted input. Expiry removes payload
    and pending notice; delivered receipts fail Stale_context on consumption.
    Consume_unlock atomically removes the live envelope before dispatching Unlock;
    later replacement cannot alter already-admitted crypto work. Stop/scope exit,
    cancellation and graph replacement discard unconsumed envelopes; an old
    incarnation is never rebound to a new runtime. No plaintext secrets, envelopes
    or payload-derived diagnostics may enter logs, observations or notifications.
    Admission requires an active Run_task service scope; otherwise Stale_context.
    No transport or lifecycle reservation is acquired. *)

val update_demand : t -> Dsl.demand_change -> (ingress_ack, Dsl.error) result
val receive_demand : t -> (Dsl.demand_output, Dsl.error) result
type delivery_status = Current | Revoked
val demand_status : t -> Dsl.demand_delivery -> (delivery_status, Dsl.error) result
val release_demand : t -> Dsl.demand_delivery -> (unit, Dsl.error) result
(** receive_demand waits independently of await for explicit Publish_demand output;
    only one receiver may wait. Atomic dequeue rechecks revision/incarnation and
    transfers the delivery's use obligation to the receiver, not a second file or
    lease acquisition. Stale queued output is never returned; its original-owner
    cleanup remains registered. The receiver may use a received file only through
    its lease and must call release_demand, including after replacement, revocation,
    stop or cancellation. Each delivery remains charged to message/resource budgets
    until release succeeds; a slow consumer cannot create an unbounded ledger.
    demand_status reads bounded ledger metadata: replacement, withdrawal, scope
    exit or fencing makes a received delivery Revoked. This is not a reusable
    authorization check or permission to reclaim bytes before consumer release.
    Returning from receive_demand is the receipt ACK, not presentation or release.
    Cancellation before dequeue transfers nothing; after dequeue the caller must
    retain the returned delivery. Scope exit wakes an empty receiver with Cancelled.

    release_demand is independent running-time original-owner cleanup, also usable
    after fencing/graph replacement while this runtime drains. It joins/retries
    only unresolved original release obligations (lease before file), and returns
    Ok only after physical release ACK. Failure retains the exact delivery and
    cause for explicit retry, never frees its accounting slot. Foreign handles
    fail without cleanup; duplicates succeed idempotently without releasing twice.
    Bounded monotonic delivery watermarks classify duplicates after pruning; no
    unbounded tombstone set. Received deliveries cannot be auto-reclaimed merely
    because an interest was replaced; their caller must stop use and release.
    The runtime retains original owners until every received/unreceived delivery
    and cleanup obligation is resolved. No callback or shared mutable reference
    is an availability output, and await is not needed to receive or release it. *)
val request_stop : t -> (unit, Dsl.error) result
(** Independent ingress, not another start or an indexed context reservation.
    update_demand validates identity/version and bounded ID/descriptor bytes before
    atomic admission. Latest not-yet-consumed update per ID replaces the old one;
    Withdraw may coalesce with its pending Demand. Other IDs are never dropped.
    Capacity_exceeded means not admitted: caller retains the update for retry.
    Pending and consumed-but-active interests share maximum_demands accounting;
    the EDSL explicitly releases an interest with Dsl.Finish_demand.
    Stop and current network status have reserved slots independent of demand
    capacity, and wake Next_input even while asset/network children are suspended.
    request_stop is idempotent graceful input, not forced cancel or graph drain.
    Only one Next_input consumer may wait; another fails explicitly. Returning
    from Run_task cancels/joins its scope; a stopped service returns Ready and the
    outer program may then Begin_drain/Finish_retirement. Forced cancel instead
    fences the execution and returns its actual draining context. *)

(** {2 Running ingress and consumer examples}

    The caller has already started a Ready Run_task service (possibly restored
    Key_locked with Closed gate). Its single input loop uses Consume_unlock as in
    Dsl's example. These functions run in other Eio fibers, never await termination:
    {[
      let provide_unlock runtime identity wrapped =
        match Dsl.unlock_input ~wrapped_graph_key:wrapped with
        | Error cause -> Error cause
        | Ok input -> submit_unlock runtime ~identity ~valid_for:60. input

      let consume_asset runtime change use =
        match update_demand runtime change with
        | Error cause -> Error (None, cause)
        | Ok _queued ->
          match receive_demand runtime with
          | Error cause -> Error (None, cause)
          | Ok output ->
            let used = use output in
            match release_demand runtime output.delivery, used with
            | Ok (), Ok () -> Ok ()
            | Ok (), Error cause -> Error (None, cause)
            | Error cleanup, Ok () -> Error (Some output.delivery, cleanup)
            | Error cleanup, Error primary ->
              Error (Some output.delivery,
                Dsl.Cleanup_failure { primary = Some primary;
                  failures = Rrbvec.singleton cleanup })
    ]}
    [change] is a validated Demand; the task consumes Demand_changed, resolves its
    receipt, retains and explicitly publishes availability. [use] is caller-supplied,
    returns (unit, Dsl.error) result without raising, and ceases all lease use before
    return. It dispatches by output.id/revision, not by assuming the next result
    belongs to [change]; multiple interests require one consumer dispatcher, not
    competing receive calls. On release failure the caller retains output.delivery
    for original-owner cleanup retry through the Error payload, never dropping it.
    provide_unlock ACK is not crypto success: only Consume_unlock
    resumes the service with verified key_status or its exact error. *)

val cancel : t -> ('after, 'a) running -> (unit, Dsl.error) result
(** Request cancellation of this exact execution and fence subsequent program
    effects. The terminal outcome is Failed with Cancelled, Outcome_unknown or
    the original cleanup failure, plus the actual draining context. A request
    rejected as foreign has no effect. Repeated accepted cancellation is
    idempotent. Terminal executions reject new cancellation without changing
    their issued context. Already committed effects remain committed; cleanup jobs remain
    registered even if callers stop awaiting. Cancellation is not retirement. *)

val current : t -> (context, Dsl.error) result
(** Recovery after a caller loses its terminal result: return the current phase
    and same current version only while idle; an active execution is rejected.
    This does not mint authority or bypass a reservation. It is not crash recovery.
    The caller dispatches on the existential phase and explicitly drains cold,
    ready or draining states. Retirement joins all jobs and callback producers,
    then requires capabilities.retire acknowledgement. A cleanup failure retains
    a draining context and original obligations; no unconditional unit shutdown
    is promoted to proof of physical retirement. *)

(** {1 Observation and helpers} *)

val identity : 's graph_context -> Dsl.identity
val phase : 's graph_context -> 's Dsl.phase
type version
val version : 's graph_context -> version
val equal_version : version -> version -> bool
(** Metadata access never refreshes authority. Versions are fresh process-local
    tokens, not wrapping machine counters or serializable authority. Contexts,
    completion bindings, internal tickets, jobs, cancellation handles and retained
    files are process-local.
    Observation is through Dsl.observe on a checked context, with bounded
    invalidations managed by callers; no database user query API is provided. *)
