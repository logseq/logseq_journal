(** {1 TLDR}

    Pure, typed programs and synchronization policy for one graph incarnation.
    Programs describe effects; they neither perform I/O nor own database handles.
    [Execute] interprets them, owns versioned graph contexts and injects capabilities.
    This module does not depend on that interpreter. Account selection, access
    authorization, database user reads/writes and destructive local-copy permission
    belong to callers. The outer indexed [t] alone owns graph lifecycle; inner
    ['a task] describes bounded structured concurrency, waits and restricted
    effects, exposed to Execute through [task_view]. [run_task] embeds a service
    in Ready without granting child tasks graph retirement authority. Independent
    Execute control/demand ingress remains live while the service is suspended.
    The external database owner invalidates outbox inspection independently of
    asset queues; Await_outbox_changed/Inspect/checked ACK preserve concurrent
    commits. Tasks explicitly publish revision-bound demand states and policy
    status; Execute exposes these without waiting for service termination.
    Foreground ingress/work and disk bytes have separately validated reservations.
    This proposal is not yet registered in the build.

    Primary entry points (declared below):
    {[
      val return : 'a -> ('s, 's, 'a) t
      val perform : ('before, 'after, 'failed, 'a) operation
        -> success:('a -> ('after, 'final, 'b) t)
        -> failure:(error -> ('failed, 'final, 'b) t)
        -> ('before, 'final, 'b) t
      val run_task : 'a task -> (ready, ready, ready, 'a) operation
    ]}
    State indices constrain ordinary continuations, not identity, linearity,
    cancellation or rollback. Failures retain their actual post-effect context. *)

type cold
type ready
type draining
type retired
type _ phase = Cold : cold phase | Ready : ready phase
  | Draining : draining phase | Retired : retired phase
type _ drainable = Cold_context : cold drainable | Ready_context : ready drainable
  | Draining_context : draining drainable

type identity = private
  { origin : string; account : string; graph : string
  ; account_generation : int64; graph_generation : int64 }
module Overlay = Logseq_overlay_db

type error =
  | Invalid_input of string
  | Identity_mismatch of string
  | Stale_context
  | Network_closed
  | Network_failure of string
  | Authentication_failure of string
  | Locked
  | Crypto_failure of string
  | Protocol_failure of string
  | Storage_failure of string
  | Cancelled
  | Outcome_unknown of string
  | Cleanup_failure of { primary : error option; failures : error Rrbvec.t }
  | Capacity_exceeded of string
  | Sync_read_failure of Overlay.Types.sync_read_error
  | Outbox_failure of Overlay.Types.outbox_transition_error
  | Authoritative_failure of Overlay.Types.authoritative_transition_error
  | Activation_failure of Overlay.Types.snapshot_activation_error
  | Asset_failure of Logseq_db_types.Failure_diagnostic.t
  | Unexpected_failure of string

type ('before, 'after, 'value) t

(** Programs remain abstract; {!view} exposes one pure interpreter step. *)
val return : 'a -> ('s, 's, 'a) t
val abort : error -> ('s, 'final, 'a) t
val bind : ('before, 'middle, 'a) t -> ('a -> ('middle, 'after, 'b) t)
  -> ('before, 'after, 'b) t

(** {1 Minimal usage example}

    The caller supplies [on_restored], a pure continuation producing a ready-to-ready
    program, and later submits [program] with a cold context to the interpreter:
    {[
      let program =
        perform restore
          ~success:on_restored
          ~failure:(fun cause -> abort cause)
    ]}
    Restoration is local-only, including encrypted offline recovery. An explicit
    network gate and available graph keys are separate prerequisites for remote
    work. [abort] stops interpretation without pretending the expected final
    phase was reached; the interpreter returns the actual context existentially. *)

(** {1 Construction and validation} *)

val identity : origin:string -> account:string -> graph:string
  -> account_generation:int64 -> graph_generation:int64 -> (identity, error) result
(** Require canonical HTTPS origin, nonempty account/graph and nonnegative
    generations. Runtime authority is checked against the injected owner on every
    effect and completion; this record alone grants no authority. *)

type limits = private
  { maximum_items : int; maximum_bytes : int; maximum_pending : int
  ; maximum_resources : int; steps_per_turn : int
  ; maximum_tasks : int; maximum_messages : int; maximum_message_bytes : int
  ; maximum_demands : int; maximum_active_assets : int
  ; foreground_reserve : int
  ; foreground_demand_reserve : int; foreground_descriptor_reserve_bytes : int
  ; asset_cache_budget_bytes : int64; asset_maximum_file_bytes : int
  ; asset_pending_budget_bytes : int64 }
val limits : maximum_items:int -> maximum_bytes:int -> maximum_pending:int
  -> maximum_resources:int -> steps_per_turn:int -> maximum_tasks:int
  -> maximum_messages:int -> maximum_message_bytes:int -> maximum_demands:int
  -> maximum_active_assets:int -> foreground_reserve:int
  -> foreground_demand_reserve:int -> foreground_descriptor_reserve_bytes:int
  -> asset_cache_budget_bytes:int64 -> asset_maximum_file_bytes:int
  -> asset_pending_budget_bytes:int64 -> (limits, error) result
(** Positive bounds: items <= 4096, bytes <= 16777216, pending <= 4096,
    resources <= 1024, steps_per_turn <= 65536, tasks <= 256, messages <= 4096,
    message_bytes <= 16777216, demands <= 4096, active_assets <= pending.
    Foreground reserve is in [1..maximum_active_assets]. Background admissions
    cannot consume that reserve. Active and pending demands both count against
    maximum_demands; one active transfer per exact asset version is shared.
    foreground_demand_reserve is in [1..maximum_demands]; descriptor reserve is
    in [1..maximum_message_bytes]. Background interests may use at most
    maximum_demands - foreground_demand_reserve entries and descriptor bytes at
    most maximum_message_bytes - foreground_descriptor_reserve_bytes. Foreground
    may use the total budget, not an additional pool. These reservations apply
    before ingress, including delivered-but-active interests and obsolete values
    still retained for cleanup. Same-ID replacement computes the net new charge
    atomically, without charging two live interests; retained old resources still
    count. A rejected replacement changes neither revision nor accounting. Shared
    transfers count once as work but each demand ID counts as an interest.
    Promotion checks total capacity; demotion also checks the background ceiling.
    Withdraw/stop/cleanup acknowledgements need reserved control capacity and may
    not be rejected just because background descriptors fill their permitted pool.
    Background/ordinary ingress, notification and output values also cannot consume
    foreground_demand_reserve message slots or reserved foreground descriptor bytes.
    Require maximum_messages >= foreground_demand_reserve + 3; three additional
    fixed control slots cover stop, gate and unlock notice. The outbox dirty slot
    and latest observation slot are separate fixed runtime metadata. A foreground
    demand can use the reserved message slots as well as its entry/byte reservation;
    otherwise a full shared message queue would defeat the ingress guarantee.
    A background transfer shared with a foreground interest is reclassified before
    admission; generic asset operations cannot claim foreground reservations.
    Release descriptor charges only when actually discarded, including task-held
    active selections and superseded cleanup metadata; moving them from ingress to
    a task is not reclamation. Interest charges end at Finish_demand, never merely
    at dequeue. Capacity pressure is explicit
    and callers retry admission only after reclaim, without spinning.
    Asset cache/pending byte budgets are nonnegative int64; single-file bytes are
    in [0..104857600], matching the real asset store's configuration. Zero disables
    that storage class, not its accounting. Cache bytes include all resident files,
    including pinned files; pending bytes include staging, cancelled work awaiting
    cleanup and recovered pending originals. Reserve actual bytes before writing,
    stream with a hard single-file ceiling even when advertised size is absent or
    false, and reject with Capacity_exceeded before crossing any byte ceiling.
    Count/resource limits do not replace these disk limits. Pruning cannot remove
    pinned files or durable unpublished originals; inability to reclaim is explicit
    pressure, not deletion of user intent. Recovery accounts existing durable files
    and orphan staging before admitting new writes; over-budget stores allow only
    bounded recovery/pruning/release until within limits. No new durable store is
    required and validation itself never enumerates files.
    Require tasks >= active_assets + 4 and pending >= active_assets + 4. Reserve three pending
    slots for receive, sync database and input, plus foreground_reserve for
    foreground assets; ordinary/background work cannot borrow these reservations.
    Queue/ingress and active descriptor bytes share maximum_message_bytes, including
    replaced and in-delivery values while retained by tasks/output/cleanup ledgers;
    reject before allocation and never reclaim merely on internal ownership transfer.
    steps_per_turn is a fair scheduling quantum, never a service lifetime limit.
    Validate before allocation. All retained
    files/leases/staging, including cancelled deliveries, count toward resources;
    reserve before acquisition. Failure retains its slot; cleanup needs no new
    slot. Completed jobs are pruned using monotonic ticket watermarks, not an
    unbounded set of tombstones. Queued notifications coalesce to resampling;
    terminal delivery is never dropped. Validation performs no graph scan. *)

type retry_policy = private
  { initial_seconds : float; maximum_seconds : float
  ; multiplier : float; maximum_attempts : int }
val retry_policy : initial_seconds:float -> maximum_seconds:float
  -> multiplier:float -> maximum_attempts:int -> (retry_policy, error) result
(** Finite positive delays, maximum >= initial, multiplier >= 1 and attempts in
    [0..10]. Zero disables automatic retry. Pure EDSL policy uses capped exponential
    delays with Sleep; attempts count actual admissions, not waiting turns. Only
    network failures are retryable; no unchanged auth/protocol/storage/crypto retry.
    Policy is supplied to task builders, not an adapter-owned business loop. *)

type network_gate = Closed | Open of { authorization_epoch : int64 }
type key_status = Unencrypted | Key_locked | Key_available
type observation =
  { identity : identity; keys : key_status; network : network_gate
  ; checkpoint : Overlay.Types.server_cursor option
  ; pending_submissions : int; pending_assets : int; cleanup_pending : int
  ; last_failure : error option }

(** {1 Capability details} *)

(** Database effects concern synchronization only. [Overlay.Types] is the real
    external synchronization database boundary, not a renamed execution owner. *)
type restore_report =
  { keys : key_status; checkpoint : Overlay.Types.server_cursor option
  ; recovery_pending : bool }
type activation =
  | Activated of Overlay.Types.generation
  | Activation_deferred of string
type authoritative_result =
  | Applied of Overlay.Types.authoritative_commit
  | Deferred of Overlay.Types.authoritative_defer

type resource = private { owner : identity; token : string }
val resource : owner:identity -> token:string -> (resource, error) result
(** A bounded, process-local producer reference, not a path or authority. The
    trusted adapter registers the token in its original owner's resource ledger
    before delivery. Pure construction validates shape only; execution checks
    actual producer ownership and resource kind, including after revocation. *)

type snapshot = private
  { resource : resource; through : Overlay.Types.server_cursor
  ; checksum : string; encrypted : bool }
val snapshot : resource:resource -> through:Overlay.Types.server_cursor
  -> checksum:string -> encrypted:bool -> (snapshot, error) result
(** Descriptor of immutable staged bytes, never proof of verification. Activation
    validates actual producer metadata, checksum, encryption mode and baseline.
    The producer retains bytes until checked release/retirement, including stale
    downloads. An arbitrary descriptor cannot substitute a native path. *)

type _ database =
  | Inspect : Overlay.Types.sync_view database
  | Prepare_submission : Overlay.Types.sync_token * Overlay.Types.outbox_transition
      -> Overlay.Types.outbox_commit database
  | Apply_authoritative : Overlay.Types.sync_token * Overlay.Types.authoritative_batch
      -> authoritative_result database
  | Activate_snapshot : snapshot -> activation database
  | Release_snapshot : snapshot -> unit database

(** Inspection is bounded metadata, not user data reads. Before enumerating any
    descriptors, construction checks that the external database's configured
    outbox_max_records fits maximum_items and its descriptor byte bound fits
    maximum_bytes. Incompatible budgets are rejected without enumeration; never
    truncate a sync_view or acknowledge an invisible submission. Submission preparation
    atomically freezes durable wires before transmission; token conflicts require
    a fresh view, not blind replay. Accepted transport responses do not remove
    durable intent until authoritative reconciliation. Deferred application keeps
    the original batch and waits for its exact submission outcome. Activation
    verifies graph generation, baseline and pending local intent atomically;
    deferral cannot be reported as activation. Durable commit outcomes survive
    cancellation; uncertainty is reconciled by exact identifiers, never resubmitted
    as a fresh mutation. No new persistent store or persistence format is implied. *)

type remote_head =
  { through : Overlay.Types.server_cursor; snapshot_available : bool }
type submission_reply =
  | Accepted of Overlay.Types.acceptance_barrier
  | Rejected of Overlay.Types.rejection_resolution

type connection
(** Process-local authenticated connection identity including a fresh, non-reused
    connection generation. Created by Connect, validated on every use; never
    serializable. Retirement invalidates it without retiring the graph. *)
val connection : owner:identity -> token:string -> generation:int64
  -> (connection, error) result
(** Trusted producer registers a fresh token/generation before constructing its
    descriptor. Construction checks bounded shape, not authority; Execute validates
    the actual original producer and immutable generation on Connect completion. *)

type connection_end =
  | Remote_closed
  | Network_lost of string
  | Access_revoked of string
  | Invalid_protocol of string
  | Locally_closed

type remote_message =
  | Remote_error of string
  | Remote_changed of remote_head
  | Connection_ended of connection_end

type received = { connection : connection; message : remote_message }

type _ transport =
  | Connect : connection transport
  | Receive : connection -> received transport
  | Retire_connection : connection -> unit transport
  | On_connection : connection * 'a transport -> 'a transport
  | Head : remote_head transport
  | Fetch_snapshot : Overlay.Types.server_cursor -> snapshot transport
  | Pull : Overlay.Types.server_cursor -> Overlay.Types.authoritative_batch transport
  | Push : Overlay.Types.submission_batch -> submission_reply transport

(** Wire framing, authentication, cursor ordering, bounds and encryption envelopes
    are validated before typed responses are delivered. Empty/incomplete pages
    cannot advance a checkpoint. Remote head and snapshot download are not local
    activation. Push uncertainty retains the frozen batch; only network failures
    are eligible for timed retry. Rejection/authentication/protocol/crypto/storage
    failures need explicit correction, not an unchanged automatic retry.
    Head/Fetch_snapshot/Pull/Push must be wrapped exactly once in On_connection;
    nested wrappers and wrappers around connection-management operations fail.
    The adapter owns exactly one physical socket reader per connection. It matches
    responses to bounded pending requests and routes unsolicited changes to the
    bounded Receive source; request tasks never read the socket themselves.
    The real hello/pull/tx-batch protocol has no generic request-ID multiplexer:
    allow at most one unresolved request per response family, including one Push,
    and validate frozen mutation tx-id, baseline and acceptance barrier. Ambiguous
    replies fail the connection and retain Submitted, never guess an owner. Head
    reads the validated hello/head state; no new server endpoint is implied.
    Receive suspends and completes once with one message, including connection
    identity. Repeat Receive in the EDSL to subscribe continuously. Only one
    Receive may be pending per connection. Overflow backpressures the reader;
    only Remote_changed hints may coalesce by resampling head, never responses,
    terminal messages or authoritative batches. Count and byte bounds apply before
    frame allocation; oversized frames fail the connection, not silently drop data.
    Retire_connection cancels and joins reader, writer, matching requests and
    callback producers before success. Connect rejects while an earlier connection
    is unretired. Remote_closed/Network_lost permit EDSL timed backoff; access and
    protocol failures require explicit correction. Local close is not a retry cause.

    Restart recovery reads Submitted IDs from Inspect and performs
    Prepare_submission (fresh_token, Retry_group original_id). The real Overlay
    commit returns the original submission_batch, including ID, t_before and exact
    protected wires; None or changed bytes is a protocol error, never fresh-send
    permission. Push uses the existing tx-batch wire with original t-before,
    mutation tx-id, protected tx and outliner-op; the local batch ID does not imply
    a server batch-status endpoint or batch-ID deduplication guarantee. Accepted/Stale responses feed
    Accept_group/Reject_group and authoritative Pull; Stale alone does not prove
    earlier non-execution. No old-process failure witness is required for this
    recovery path. New submissions use Submit_group, never reconstructed retries.

    Normalize wire rejection against the exact frozen submitted member order:
    success_tx_ids must be an ordered prefix, failed_tx_id must be its next
    member, and unexecuted_suffix is exactly the remaining suffix. Only when the
    accepted prefix is empty may an omitted failed ID denote the first member,
    as in the existing wire contract. A nonempty accepted prefix requires both
    validated cursor and checksum acceptance_barrier; an empty prefix has None.
    Reject duplicates, foreign IDs, reordered prefixes, missing barriers and
    impossible partitions as Protocol_failure, retaining the frozen submission.
    Empty_tx_data/Invalid_tx/Invalid_t_before map to Overlay.Invalid_request;
    Db_transact_failed with missing_block_uuids maps to Missing_dependencies;
    other Db_transact_failed and Snapshot_upload_in_progress map to
    Operational_failure. Preserve bounded missing IDs and diagnostic detail.
    Stale requires its advancing cursor and yields Overlay.Stale, never a
    fabricated definitive partition or proof of a previous attempt's outcome.
    Preserve Overlay's Permission_denied when a real source supplies it, but do
    not invent a wire reason. Rejected resolutions flow through Reject_group;
    its durable commit and subsequent authoritative pull decide reconciliation.

    Remote_error carries the real server Error message, scoped to its connection,
    and must be handled by the connection/sync policy as a non-retryable protocol
    error, retaining uncertain submissions. It cannot be discarded as a hint or
    arbitrarily attached to an unmatched Push. Presence/online-users are not sync
    inputs. Ping/pong is physical connection liveness, not an outbox wake or commit.
    Authentication acquisition/one checked refresh belong to injected transport;
    exhaustion returns Authentication_failure/Access_revoked, never timed reconnect
    with the unchanged rejected credential. No account/key-package API is added. *)

type unlock_input
val unlock_input : wrapped_graph_key:string -> (unlock_input, error) result
val wrapped_graph_key : unlock_input -> string
(** Validated wrapped material, never a raw key. Secret acquisition and account
    key-package coordination are caller responsibilities. The accessor exposes
    only the supplied wrapped envelope, never a raw key. Unlock succeeds only
    after verifying and installing the key for this exact graph; a still-locked
    result is Error Locked, not successful key access. Never log key material. *)
type _ crypto = Unlock : unlock_input -> key_status crypto

(** Assets are explicit bounded demands, not a graph-wide discovery service. *)
type asset = Logseq_db_types.Asset_descriptor.t
(** Shared validated graph metadata retains source, checksum, file type and remote
    version. External URLs are not managed-sync downloads. *)
type asset_file = private { file : resource; asset : asset }
type asset_lease = private { lease : resource; source : asset_file }
val asset_file : resource -> asset -> (asset_file, error) result
val asset_lease : resource -> asset_file -> (asset_lease, error) result
(** Adapter-created descriptors validated against its real registered resources;
    pure constructors neither retain bytes nor confer native access. *)
type resource_reference = Snapshot_reference of snapshot
  | Connection_reference of connection
  | File_reference of asset_file | Lease_reference of asset_lease
type asset_result = Available of asset_file | Waiting_remote | Missing_local

type cache_report =
  { resident_bytes : int64; pending_bytes : int64; retained_bytes : int64
  ; cleanup_pending : int; over_budget : bool }
(** Bounded totals, not an inventory; retained bytes are pinned/unpublished bytes
    already included in resident/pending totals, not a third additive pool. *)

type _ assets =
  | Prune_cache : cache_report assets
  | Lookup : asset -> asset_file option assets
  | Download : asset -> asset_result assets
  | Upload : asset -> unit assets
  | Retain : asset_file -> asset_lease assets
  | Release_file : asset_file -> unit assets
  | Release_lease : asset_lease -> unit assets

(** Files and leases are process-local, minted by the original asset owner and
    runtime-checked against exact graph generation. Upload uses an existing durable
    publication intent; success means verified remote publication, not a user
    database edit. Downloads verify envelope/checksum before publication; malformed
    encryption never falls back to plaintext. Locked assets wait for unlock and
    missing remote versions remain waiting, not empty successful downloads.
    Lookup is local-only and recreates a registered handle for matching cached
    bytes after restart; None is absence of those exact bytes, not remote absence.
    For Managed (Some remote B) with current_checksum A, Lookup first checks the
    local original A, then cached B on a miss; it may return either only with
    validated actual content identity. This also works with Closed network or locked
    keys when verified local plaintext is already available. Managed None with A
    checks A offline; its miss means Waiting_remote, not permission to invent a
    file type/version or GET A. Managed None without A waits for publication.
    External sources never enter managed Download/Upload. Download uses only the
    explicit Managed remote version B after a local miss; it never substitutes A
    as a remote version. Result asset_file.asset describes the original selection
    descriptor, while its registered file metadata records the actual chosen bytes;
    Retain and Publish validate that relationship, not equality of A and B.
    Lookup completion is fenced by incarnation and the full selection (UUID,
    current_checksum, optional remote checksum/file_type). A demand-bound child
    created by spawn_asset additionally binds its exact receipt; replacement
    invalidates that child interest and cleans stale results. Generic Lookup has
    no implicit demand binding: it may return an old selection to its original
    task, but Publish_demand must reject it against a changed receipt and the task
    releases it through the original owner. Neither path can publish stale bytes.
    Local lookup sharing uses that full selection; remote transfers deduplicate
    by incarnation, UUID, remote checksum and file_type, never checksum alone or
    demand ID. Distinct local interests may share B's download, but each must
    revalidate its own current selection before publishing a separately retained
    lease. A remote-version publication is an explicit replacement Demand, not a
    network-change heuristic that fabricates new graph metadata.
    Local source staging, durable import recovery, publication and pruning are
    owned by the injected asset capability under existing persistence rules.
    Restore performs bounded/incremental accounting and recovery of existing cache
    and staging metadata before asset admission, without remote work. Prune_cache
    is a cancellable local incremental sweep using bounded batches and yielding to
    foreground work; it removes only unpinned cache and proven orphan staging.
    It reports actual remaining bytes/pressure, never claims durable originals were
    uploaded merely to reclaim space. Cleanup failures retain paths under their
    original owner and return their concrete error. The EDSL may request pruning
    after Capacity_exceeded, then wait for release/correction when retained bytes
    prevent progress; it must not loop retrying a storage failure. Database import
    remains the external owner's user API, not a DSL operation.
    Retain creates a separately bounded native lease; release failure retains
    the original resource. Duplicate successful release is idempotent. Leases
    cannot be abandoned by claiming physical release. *)

(** {2 Structured business tasks}

    The outer indexed program alone changes graph lifecycle. Inner tasks are pure
    descriptions with restricted capabilities, not host closures executing I/O.
    Long-lived policy is ordinary recursive task construction, waits, timers and
    continuation-local state. There is no controller step or hidden adapter policy. *)
type 'a task
type scope
type !'a child

type demand_id
val demand_id : string -> (demand_id, error) result
val compare_demand_id : demand_id -> demand_id -> int
type priority = Foreground | Background
type demand_change =
  | Demand of { id : demand_id; asset : asset; priority : priority }
  | Withdraw of demand_id

type demand_receipt
(** Process-local exact demand revision, minted by ingress; invalid after a newer
    revision or scope exit. It is not an asset file or lifecycle authority. *)
type unlock_receipt
(** Runtime-minted, single-use wrapped-input revision bound to this graph
    incarnation and service scope. Replacement, expiry or scope exit invalidates
    it. It contains no printable material and survives no restart. *)
type service_input =
  | Unlock_requested of unlock_receipt
  | Demand_changed of demand_receipt * demand_change
  | Network_changed of network_gate
  | Stop_requested
(** Inputs are supplied through Execute's independent bounded ingress. Demand IDs
    are bounded nonempty strings (<= 256 bytes). Updating an ID replaces its exact
    asset version and priority; withdrawing cancels its interest, not other users'
    shared download. The EDSL owns scheduling policy and resource release. *)

type asset_failure_reason =
  | Asset_network of string
  | Asset_network_closed
  | Asset_not_found
  | Asset_checksum_mismatch
  | Asset_authentication of string
  | Asset_locked
  | Asset_storage_full
  | Asset_missing_source
  | Asset_size_rejected
  | Asset_revoked_access
  | Asset_cancelled
  | Asset_invalid_content of string
  | Asset_other of error

type demand_transfer =
  { result : (asset_result, asset_failure_reason) result; attempts : int }
(** Joined Download_demand result with the actual admitted remote-attempt count
    for this invocation (zero if none). The interpreter reports facts from its
    scoped network admission ledger, not a guessed count of scheduled tasks.
    Business transfer failure is data; stale receipts, invalid usage and unjoined
    cleanup remain task-effect errors. No automatic retry occurs in this effect. *)

type demand_availability =
  | Demand_queued
  | Demand_downloading
  | Demand_waiting_network
  | Demand_waiting_unlock
  | Demand_failed of
      { reason : asset_failure_reason; attempts : int; retry_scheduled : bool }
  | Demand_available of asset_file * asset_lease
  | Demand_waiting_remote
  | Demand_missing_local
  | Demand_revoked

type demand_delivery
(** Runtime-minted publication identity, bound to one original owner, graph
    incarnation, demand revision and scope. Not constructible from a demand ID.
    A received delivery retains its original cleanup binding until release ACK. *)
type demand_output = private
  { delivery : demand_delivery
  ; id : demand_id
  ; demand : demand_receipt
  ; availability : demand_availability }
(** The bounded external result of explicit Publish_demand, not an adapter
    callback or program termination. Demand_available must pair an exact asset
    file with its validated lease; publication never manufactures a lease. *)

(** Every state uses the same revision/delivery/release protocol, including states
    with no resources. attempts is the number of admitted remote attempts, >= 0;
    retry_scheduled is true only while a bounded network retry timer actually exists.
    Not-found, checksum, authentication, locked, storage and invalid-content causes
    are not automatic retry permission. Locked/network-closed become waiting states;
    correction or a new demand revision triggers a fresh local Lookup. Expected
    transfer failures are published for the affected interest and handled locally,
    not escalated to stop unrelated sync/connection tasks. Retrying never changes
    the identity of an uncertain durable publication. Diagnostics remain bounded. *)

type outbox_check
(** Opaque scope-owned inspection epoch for this exact runtime/incarnation. Created
    by Await_outbox_changed before Inspect; not a database token or durable receipt. *)

type 'a wake = Input of service_input | Child_ready of 'a child

type notifications
type notification =
  | Policy_failure of error
  | Connected of connection
  | Remote_received of received
  | Connection_retired of connection
(** A bounded scope-owned channel carries connection identity and remote hints
    from the sole receiver to sync/asset policy. It owns no socket or graph. *)

type service_status =
  | Service_idle
  | Service_connecting
  | Service_online
  | Service_waiting_network
  | Service_waiting_unlock
  | Service_backoff of { attempt : int; seconds : float; cause : error }
  | Service_blocked of error
(** Pure policy status, not authority or proof of durable synchronization. Concrete
    causes are retained; transient failures need not terminate the service. *)

type _ task_effect =
  | Notifications : scope -> notifications task_effect
  | Notify : notifications * notification -> unit task_effect
  | Next_notification : notifications -> notification task_effect
  | Await_outbox_changed : outbox_check task_effect
  | Acknowledge_outbox_check : outbox_check -> unit task_effect
  | Abandon_outbox_check : outbox_check -> unit task_effect
  | Resample_outbox : unit task_effect
  | Task_observe : observation task_effect
  | Publish_status : service_status -> unit task_effect
  | Task_database : 'a database -> 'a task_effect
  | Task_transport : 'a transport -> 'a task_effect
  | Task_crypto : 'a crypto -> 'a task_effect
  | Task_assets : 'a assets -> 'a task_effect
  | Consume_unlock : unlock_receipt -> key_status task_effect
  | Publish_demand : demand_receipt * demand_availability -> unit task_effect
  | Download_demand : demand_receipt -> demand_transfer task_effect
  | Finish_demand : demand_receipt -> unit task_effect
  | Wait_network_open : unit task_effect
  | Next_input : service_input task_effect
  | Await_input_or_child : 'a child Rrbvec.t -> 'a wake task_effect
  | Sleep : float -> unit task_effect
  | Yield : unit task_effect
(** Await_outbox_changed is an independent level-triggered bounded invalidation,
    not a Next_input/asset notification. Exactly one task per service owns the
    inspection reservation, held from await through acknowledgement; competing
    consumers fail Invalid_input rather than stealing a wake. No waiter is needed
    for notification retention. Runtime starts dirty; restoration, successful
    unlock/activation and every successful reopen also request a check. Connection
    policy requests a reconnect check with Resample_outbox after Connected.
    Resample_outbox explicitly marks dirty (for example after Connected); it does
    not inspect or send anything. Await captures the dirty epoch before Inspect.
    Acknowledge_outbox_check clears only that captured epoch, after successful
    inspection and installation of its bounded plan. A newer commit during Inspect
    stays dirty and makes the next await immediately ready. Implement by a checked
    epoch or equivalent two-bit dirty/in-flight protocol without counter wrap loss.
    Abandon_outbox_check releases the reservation without acknowledging dirty work;
    use it after failed inspection/planning before waiting for correction. Task
    termination/cancellation also abandons it. The next consumer inspects afresh.
    A failed Inspect itself does not implicitly clear or consume the check.
    Old/foreign/duplicate checks
    fail Stale_context. Scope exit invalidates checks without discarding dirtiness.
    Closed network still permits Inspect and local planning; it never authorizes
    Push. Keep the plan while waiting for Open, then inspect again before preparing
    a submission against a fresh sync token. Network reopen cannot depend solely
    on a commit arriving after the waiter was installed. Inspect failure on absent
    mirror waits for activation; it must not spin or erase pending local intent.
    Task_observe is the local checked Observe capability usable during Run_task.
    Publish_status replaces one bounded policy-status slot observed independently
    through Execute.observe_runtime/await_observation; it neither queues unbounded
    history nor transfers resources. The service designates one status publisher
    (siblings forward causes through bounded Notifications rather than racing).
    Runtime gate/counts and actual retained cleanup override optimistic policy;
    Service_online is not acknowledgement of an outbox commit.

    Sleep uses finite nonnegative monotonic seconds and is cancellable. All
    effects may suspend without blocking siblings, ingress or control. Database
    mutations still serialize at the single external database owner.
    Wait_network_open is a cancellable wait for an authorized Open gate with old
    network retirement complete, not a timer retry or a reusable permit; each
    subsequent actual admission must recheck. It does not consume Next_input.
    Consume_unlock atomically checks/consumes the exact live receipt and executes
    the ordinary Unlock capability locally, even with Closed network admission.
    Expired/replaced/foreign receipts fail without invoking crypto; failure after
    consumption exposes the original crypto error and requires fresh input.
    Its wrapped payload is discarded after consumption and joined crypto work;
    neither receipt diagnostics nor observations/logs contain key material.

    Publish_demand checks the exact current revision, asset and original resource
    ledger atomically before enqueueing. Success transfers the supplied file and
    lease references from the task to the runtime output ledger, not to a consumer;
    the task must not release or republish them. Failure transfers nothing, so the
    task retains both references for explicit release. Output count and bytes share
    maximum_messages/maximum_message_bytes; resources share maximum_resources.
    Capacity_exceeded is immediate and recoverable in the task, not silent loss.
    Available is legal only for a live Demand, Revoked only for its live Withdraw;
    waiting/missing results carry no resources. Duplicate publication of transferred
    references is rejected without minting another delivery or lease. Reservations
    include superseded cleanup until physical release succeeds; failed cleanup is
    retained with its original cause, never hidden by replacement success.
    One unreceived publication per revision may be replaced atomically; superseded
    unreceived resources are released by their original owner before reclaiming
    their slots. Replacement/withdrawal invalidates queued old availability and
    schedules its original-owner cleanup. Received resources are never silently
    released under a consumer: their delivery becomes revoked and remains owed
    until Execute.release_demand ACK. Demand_revoked is an explicit task publication
    for a live withdrawal receipt; it carries no resources. Late publication fails
    Stale_context and leaves task ownership intact. Scope exit cancels receivers,
    cleans unreceived output and retains received deliveries and failed cleanup
    in the runtime ledger; retirement cannot succeed while any remain.
    Finish_demand cannot erase outstanding output/cleanup or a newer revision.
    No shared mutable callback or notification side channel publishes availability.

    Download_demand resolves the exact current asset/priority from its receipt and
    uses the ordinary Download adapter once, reporting its joined result and actual
    scoped admission count as demand_transfer. It neither performs local Lookup
    nor silently retries; the EDSL must Lookup first, publish queued/waiting states
    and choose whether to download. A withdrawn/stale revision cannot start.
    No-version Download returns Waiting_remote without network admission. Closed
    and Locked reject remote admission and report Asset_network_closed/Asset_locked with
    zero attempts, allowing policy to publish waiting states; concrete network
    failure after admission preserves its diagnostic and nonzero attempt count.
    Active assets are bounded by maximum_active_assets, background admissions by
    maximum_active_assets - foreground_reserve, including generic Download/Upload.
    Capacity failure is explicit; EDSL waits/yields and selects the next demand.
    Updates cancel obsolete interest and reclassify shared work before further
    admissions; physical cancellation/join still consumes the active slot.
    Finish_demand releases that revision's interest only after its children joined
    and resources were transferred or released; stale receipts cannot erase newer
    demand. Transfer deduplication is by exact asset version, not demand ID.
    Notifications reserves a channel slot from maximum_resources; all channels
    share maximum_messages/maximum_message_bytes. Notify suspends under pressure;
    only adjacent Remote_changed hints for the same connection may coalesce.
    Connection transitions never coalesce. Next_notification is single-consumer;
    fan-out requires separate bounded channels and explicit Notify in the EDSL.
    Scope exit cancels waiters and releases queues after all children join.
    Await_input_or_child suspends on ingress and the supplied live children using
    Eio readiness, not polling. The vector is bounded by maximum_tasks, contains
    no duplicates and belongs to the current scope. Selection atomically consumes
    only a winning input; Child_ready does not consume its join. Cancellation
    consumes neither input nor child result. Stop has priority; otherwise choose
    fairly between input and ready children, so finished transfers are joined and
    slots reclaimed even if no new demand arrives. It shares Next_input's single
    consumer reservation, not another unbounded queue. *)

val task_return : 'a -> 'a task
val task_bind : 'a task -> ('a -> 'b task) -> 'b task
val task_fail : error -> 'a task
val task_perform : 'a task_effect -> success:('a -> 'b task)
  -> failure:(error -> 'b task) -> 'b task
val with_scope : (scope -> 'a task) -> 'a task
val spawn : scope -> 'a task -> ('a child, error) result task
val spawn_asset : scope -> demand_receipt -> 'a task -> ('a child, error) result task
(** Like spawn, but binds the child to a current demand's priority for admission.
    Ordinary/background children cannot consume foreground_reserve task slots;
    spawn_asset for a live foreground receipt can. Replacement reclassifies shared
    interest before new admissions; cancellation/join still holds its slot. Require
    maximum_tasks >= maximum_active_assets + 4 so coordination and the foreground
    task reservation coexist. A stale receipt starts no task. The EDSL chooses
    runnable demands fairly, with bounded foreground bursts and eventual background
    turns when resources/network allow; foreground reservation is not starvation
    permission. No busy polling for capacity: await/join a live child or wait input. *)
val equal_child : 'a child -> 'a child -> bool
val join : 'a child -> ('a, error) result task
val cancel_child : 'a child -> unit task

(** Every scope owns all spawned children. Normal return, failure and cancellation
    cancel then join remaining children and their operation producers before exit.
    Completed children retain their bounded slot until join; join consumes it once.
    Foreign/expired scopes and reused child joins fail explicitly at runtime.
    Cancellation of a child affects only its subtree, not siblings or graph phase.
    Failure is observed by join, not silently lost; scope exit reports unobserved
    child failures as well. Expected Cancelled caused solely by that scope's own
    shutdown is not a new primary failure; cleanup failures and unknown durable
    outcomes always propagate and retain original owners. Spawn reserves task,
    terminal and queue capacity before starting; exhaustion returns
    Capacity_exceeded without starting a producer.
    Tasks cannot invoke Restore, Set_network, Begin_drain or Finish_retirement.
    Network_closed is a joined ordinary task failure, not whole-graph cancellation. *)

type _ task_node =
  | Task_return : 'a -> 'a task_node
  | Task_fail : error -> 'a task_node
  | Task_perform : 'a task_effect * ('a -> 'b task)
      * (error -> 'b task) -> 'b task_node
  | Task_scope : (scope -> 'a task) -> 'a task_node
  | Task_spawn : scope * 'a task -> ('a child, error) result task_node
  | Task_spawn_asset : scope * demand_receipt * 'a task
      -> ('a child, error) result task_node
  | Task_join : 'a child -> ('a, error) result task_node
  | Task_cancel : 'a child -> unit task_node
  | Task_bind : 'a task * ('a -> 'b task) -> 'b task_node
val task_view : 'a task -> 'a task_node
(** Total pure one-node projection for Execute. Scope/child handles are minted by
    the interpreter, never manufactured by the program. Execute uses Eio switches,
    fibers, promises and cancellation contexts; this view is not a second general
    fiber scheduler. Runnable continuations yield after steps_per_turn reductions;
    fair turns include queued completions and input, with no cumulative step cap.
    Every continuation must terminate; arbitrary nonterminating OCaml cannot be
    preempted by this contract. Retained tasks, waiters and ready queues are bounded
    by maximum_tasks/maximum_pending; terminal capacity is reserved at admission. *)

(** A service can run connection, sync and assets independently. Caller-supplied
    [connection_loop], [sync_loop] and [asset_loop] are pure task builders; the
    connection loop repeats Receive and retires before timed reconnect, the sync
    loop inspects/commits exact tokens, and the asset loop consumes Next_input and
    spawns bounded transfers rather than awaiting Download inline. For example:
    {[
      let admit scope task continue =
        task_bind (spawn scope task) (function
          | Error cause -> task_fail cause
          | Ok child -> continue child)

      let service connection_loop sync_loop asset_loop =
        with_scope (fun scope ->
          task_perform (Notifications scope) ~failure:task_fail
            ~success:(fun notices ->
              admit scope (connection_loop notices) (fun _connection ->
              admit scope (sync_loop notices) (fun _sync ->
              admit scope (asset_loop scope) (fun assets ->
              task_bind (join assets) (function
                | Error cause -> task_fail cause
                | Ok () -> task_return ()))))))

      let spawn_after_reclaim scope work running on_pressure =
        task_bind (spawn scope work) (function
          | Ok child -> task_return child
          | Error (Capacity_exceeded _ as cause) ->
            task_bind (on_pressure cause) (fun () ->
              task_bind (join running) (function
                | Error cause -> task_fail cause
                | Ok () ->
                  task_bind (spawn scope work) (function
                    | Ok child -> task_return child
                    | Error cause -> task_fail cause)))
          | Error cause -> task_fail cause)

      let rec unlock_service on_unlock_error () =
        task_perform Next_input ~failure:task_fail ~success:(function
          | Unlock_requested receipt ->
            task_perform (Consume_unlock receipt)
              ~failure:(fun cause ->
                task_bind (on_unlock_error cause)
                  (fun () -> unlock_service on_unlock_error ()))
              ~success:(fun _keys -> unlock_service on_unlock_error ())
          | Stop_requested -> task_return ()
          | _ -> unlock_service on_unlock_error ())

      let publish_available receipt file =
        task_perform (Task_assets (Retain file)) ~failure:task_fail
          ~success:(fun lease ->
            task_perform (Publish_demand (receipt, Demand_available (file, lease)))
              ~success:(fun () -> task_return ())
              ~failure:(fun primary ->
                task_perform (Task_assets (Release_lease lease))
                  ~failure:(fun cleanup -> task_fail
                    (Cleanup_failure { primary = Some primary;
                      failures = Rrbvec.singleton cleanup }))
                  ~success:(fun () ->
                    task_perform (Task_assets (Release_file file))
                      ~success:(fun () -> task_fail primary)
                      ~failure:(fun cleanup -> task_fail
                        (Cleanup_failure { primary = Some primary;
                          failures = Rrbvec.singleton cleanup })))))

      let rec asset_service on_other =
        task_perform Next_input ~failure:task_fail ~success:(function
          | Demand_changed (receipt, Demand {asset; _}) ->
            let publish state = task_perform (Publish_demand (receipt, state))
              ~success:task_return ~failure:task_fail in
            let downloaded report = match report.result with
              | Ok (Available file) -> publish_available receipt file
              | Ok Waiting_remote -> publish Demand_waiting_remote
              | Ok Missing_local -> publish Demand_missing_local
              | Error Asset_network_closed -> publish Demand_waiting_network
              | Error Asset_locked -> publish Demand_waiting_unlock
              | Error reason -> publish (Demand_failed
                  {reason; attempts = report.attempts; retry_scheduled = false}) in
            let lookup_failed cause = publish (Demand_failed
              {reason = Asset_other cause; attempts = 0; retry_scheduled = false}) in
            let work = task_bind (publish Demand_queued) (fun () ->
              task_perform (Task_assets (Lookup asset)) ~failure:lookup_failed
                ~success:(function
                  | Some file -> publish_available receipt file
                  | None ->
                    task_bind (publish Demand_downloading) (fun () ->
                      task_perform (Download_demand receipt)
                        ~failure:lookup_failed ~success:downloaded))) in
            task_bind work (fun () -> asset_service on_other)
          | Stop_requested -> task_return ()
          | input -> task_bind (on_other input)
              (fun () -> asset_service on_other))
    ]}
    [on_unlock_error] receives the exact expiry/replacement Stale_context or crypto
    cause as a pure task, then the locked service waits for fresh external input;
    it never retries an expired envelope or logs its material. This dedicated
    unlock-only example has no asset interests; the combined service dispatches
    every input through its single consumer instead of dropping demand changes.
    [on_pressure] is a pure task builder that exposes the capacity cause to local
    scheduling policy before waiting for [running] to join; rejected [work] has not
    run. [on_other] handles unlock, withdrawal and gate inputs with the same sole
    input consumer. The small asset_service illustrates the publication path only;
    the production asset_loop spawns transfers so ingress remains responsive.
    Failed Retain leaves the file in the original runtime cleanup ledger; failed
    releases retain their exact original handles and slots, including on scope exit.
    asset_loop is the single Next_input consumer: it forwards network changes to
    its local policy and Stop_requested returns, cancelling/joining sibling work
    through the scope. Connection-to-sync hints use Notify/Next_notification,
    never racing multiple Receive readers. Demand updates remain consumable
    while transfers run as children. No child has lifecycle authority. *)

(** {2 Outbox inspection and upload example}

    This complete single-member planner uses only public types. The caller supplies
    [with_connection], a pure task builder that waits for an authenticated current
    connection, and [on_error], which exposes the exact cause and waits for explicit
    correction for non-network errors. It does not return immediately to a failing
    Inspect loop. Submitted recovery and authoritative Pull remain the sibling sync
    policy described above; this example only chooses fresh eligible Queued work.
    The inspected view itself is the installed bounded local plan; after waiting
    for network it is discarded and inspected again before freezing any wires.
    {[
      let submit_one connection view mutation_id =
        let token = Overlay.Types.sync_view_token view in
        task_perform
          (Task_database (Prepare_submission
            (token, Overlay.Types.Submit_group [mutation_id])))
          ~failure:task_fail ~success:(fun commit ->
            match commit.Overlay.Types.submission_batch with
            | None -> task_fail (Protocol_failure "missing frozen submission")
            | Some batch ->
              task_perform (Task_transport (On_connection (connection, Push batch)))
                ~failure:task_fail ~success:(fun reply ->
                  let batch_id = Overlay.Types.submission_batch_id batch in
                  let transition = match reply with
                    | Accepted barrier -> Overlay.Types.Accept_group {batch_id; barrier}
                    | Rejected resolution ->
                      Overlay.Types.Reject_group {batch_id; resolution} in
                  task_perform (Task_database (Prepare_submission
                    (commit.sync_token, transition)))
                    ~failure:task_fail ~success:(fun _commit ->
                      task_perform Resample_outbox
                        ~failure:task_fail ~success:task_return)))

      let queued view =
        List.find_opt (fun (item : Overlay.Types.submission_descriptor) ->
          item.dependency_eligible && item.state = Overlay.Types.Queued)
          (Overlay.Types.sync_view_submissions view)

      let rec outbox_service with_connection on_error =
        let recover cause =
          task_bind (on_error cause) (fun () ->
            outbox_service with_connection on_error) in
        task_perform Await_outbox_changed ~failure:recover ~success:(fun check ->
          let abandon primary =
            task_perform (Abandon_outbox_check check)
              ~success:(fun () -> recover primary)
              ~failure:(fun cleanup -> task_fail (Cleanup_failure
                { primary = Some primary; failures = Rrbvec.singleton cleanup })) in
          task_perform (Task_database Inspect) ~failure:abandon ~success:(fun view ->
            let candidate = queued view in
            task_perform (Acknowledge_outbox_check check) ~failure:recover
              ~success:(fun () -> match candidate with
                | None -> outbox_service with_connection on_error
                | Some _ ->
                  task_perform Wait_network_open ~failure:recover ~success:(fun () ->
                    task_bind (with_connection ()) (fun connection ->
                      task_perform (Task_database Inspect) ~failure:recover
                        ~success:(fun fresh ->
                          let work = match queued fresh with
                            | None -> task_return ()
                            | Some item -> submit_one connection fresh item.mutation_id in
                          let joined = with_scope (fun scope ->
                            task_bind (spawn scope work) (function
                              | Error cause -> task_return (Error cause)
                              | Ok child -> join child)) in
                          task_bind joined (function
                            | Error cause -> recover cause
                            | Ok () -> outbox_service with_connection on_error)))))))
    ]}
    The external owner calls Execute.notify_outbox_changed after its durable
    commit. A notification arriving before await or between Inspect and ACK remains
    observable. Only this loop owns the check reservation. Stop is delivered to
    the service's single input owner, whose return cancels/joins this sibling.
    A Push or follow-up database conflict cannot be repaired by rebuilding a fresh
    batch; the parent re-inspects original durable Submitted/accepted state. *)

(** {2 Snapshot acquisition and cleanup example}

    With an authenticated [connection] and advertised [through], fetch stages
    bytes, activation delegates bounded decryption to the graph's scoped crypto
    owner, and every result releases the original staged resource. The graph may
    remain Ready with no mirror when activation is deferred; callers expose that
    reason and await the relevant local correction, never claim activation.
    {[
      let acquire_snapshot connection through =
        task_perform
          (Task_transport (On_connection (connection, Fetch_snapshot through)))
          ~failure:task_fail ~success:(fun snapshot ->
            let release result =
              task_perform (Task_database (Release_snapshot snapshot))
                ~success:(fun () -> match result with
                  | Ok activation -> task_return activation
                  | Error cause -> task_fail cause)
                ~failure:(fun cleanup -> task_fail (Cleanup_failure
                  { primary = (match result with Ok _ -> None | Error e -> Some e);
                    failures = Rrbvec.singleton cleanup })) in
            task_perform (Task_database (Activate_snapshot snapshot))
              ~success:(fun activation -> release (Ok activation))
              ~failure:(fun cause -> release (Error cause)))
    ]}
    Fetch_snapshot verifies bounded metadata/declared cursor and actual artifact;
    the producer ledger also binds parsed expected row count required by Overlay
    activation. Activation validates that count, checksum and real encryption mode
    before publishing. Snapshot resource bytes have their own maximum_bytes bound
    and cannot bypass maximum_resources; encrypted staging/decryption scratch is
    accounted before allocation. These snapshot bounds are independent of asset
    cache budgets. Failed release remains owed in the runtime cleanup ledger. *)

type (_, _, _, _) operation =
  | Run_task : 'a task -> (ready, ready, ready, 'a) operation
  | Restore : (cold, ready, cold, restore_report) operation
  | Set_network : network_gate -> (ready, ready, ready, unit) operation
  | Database : 'a database -> (ready, ready, ready, 'a) operation
  | Transport : 'a transport -> (ready, ready, ready, 'a) operation
  | Crypto : 'a crypto -> (ready, ready, ready, 'a) operation
  | Assets : 'a assets -> (ready, ready, ready, 'a) operation
  | Observe : ('s, 's, 's, observation) operation
  | Begin_drain : 's drainable -> ('s, draining, draining, unit) operation
  | Finish_retirement : (draining, retired, draining, unit) operation
  | Release_file : asset_file -> ('s, 's, 's, unit) operation
  | Release_lease : asset_lease -> ('s, 's, 's, unit) operation
  | Release_snapshot : snapshot -> ('s, 's, 's, unit) operation

val perform : ('before, 'after, 'failed, 'a) operation
  -> success:('a -> ('after, 'final, 'b) t)
  -> failure:(error -> ('failed, 'final, 'b) t)
  -> ('before, 'final, 'b) t

type (_, _, _) node =
  | Return : 'a -> ('s, 's, 'a) node
  | Abort : error -> ('s, 'final, 'a) node
  | Perform : ('before, 'after, 'failed, 'a) operation
      * ('a -> ('after, 'final, 'b) t)
      * (error -> ('failed, 'final, 'b) t)
      -> ('before, 'final, 'b) node
val view : ('before, 'after, 'a) t -> ('before, 'after, 'a) node
(** A total one-step pure projection, including normalization of [bind]. Branch
    callbacks must terminate without I/O or yielding. Interpretation bounds the
    reductions per fair turn, not total service lifetime; a callback exception
    fails with the actual current phase. *)

val run_task : 'a task -> (ready, ready, ready, 'a) operation

val restore : (cold, ready, cold, restore_report) operation
val set_network : network_gate -> (ready, ready, ready, unit) operation
val database : 'a database -> (ready, ready, ready, 'a) operation
val transport : 'a transport -> (ready, ready, ready, 'a) operation
val crypto : 'a crypto -> (ready, ready, ready, 'a) operation
val assets : 'a assets -> (ready, ready, ready, 'a) operation
val observe : ('s, 's, 's, observation) operation
(** Ready means a bound graph workspace, not necessarily an activated mirror or
    unlocked keys. A missing local base is a successful restore with checkpoint
    None; Inspect then fails explicitly until activation. Locked encrypted bases
    restore metadata without plaintext access. Restoration uses only durable
    local metadata/mirror/wrapped keys and leaves the gate Closed. Partial failed
    restoration remains cold with retained cleanup
    obligations; it may be drained. Opening the gate rechecks authorization epoch.
    Closing fences new network admissions and waits for admitted transport work;
    an unknown prior outcome remains durable and visible, not rolled back.
    Transport, Download and Upload require Open at admission and execution;
    Inspect, local reconciliation, unlock and resource release do not. Locked keys
    reject protected work before sending bytes, but do not block metadata restore.
    Ordinary effect failures leave ready, with durable outcomes and retained
    resources reflected by observation rather than hidden by the phase index. *)

(** {1 Lifecycle and recovery} *)

val begin_drain : 's drainable -> ('s, draining, draining, unit) operation
val finish_retirement : (draining, retired, draining, unit) operation
val release_file : asset_file -> ('s, 's, 's, unit) operation
val release_lease : asset_lease -> ('s, 's, 's, unit) operation
val release_snapshot : snapshot -> ('s, 's, 's, unit) operation
(** Drain irreversibly fences ordinary work, including cancelled setup, before
    requesting cancellation. Its failure is still draining. Physical retirement
    requires joined transport/crypto/snapshot/asset work, callback producers,
    database delegations and all retained resources; cleanup failure stays draining.
    Merely cancelling fibers or closing the gate proves none of these joins.
    Original owners remain addressable after account/graph replacement for checked
    release. Retired is terminal except idempotent release/cached observation;
    retirement does not authorize database deletion or account replacement.
    Cancellation may interrupt any program: the interpreter reports its actual
    state and error, never fabricating the program's desired final phase. *)

(** {1 Observation and helpers} *)

val error_message : error -> string
(** Observations contain bounded synchronization metadata only. Caller-owned
    UI/query subscriptions, delivery windows and presentation acknowledgements
    are not synchronization completion. External database deferral and physical
    completion are described by the interpreter protocol, not polling a boolean.
    After restart obtain a new incarnation and restore from existing durable
    checkpoint/outbox/key/asset records. No context or resource token survives. *)
