(** {1 TLDR}

    Pure, typed programs and synchronization policy for one graph incarnation.
    Programs describe effects; they neither perform I/O nor own database handles.
    [Execute] interprets them, owns versioned graph contexts and injects capabilities.
    This module does not depend on that interpreter. Account selection, access
    authorization, database user reads/writes and destructive local-copy permission
    belong to callers. This proposal is not yet registered in the build.

    Primary entry points (declared below):
    {[
      val return : 'a -> ('s, 's, 'a) t
      val perform : ('before, 'after, 'failed, 'a) operation
        -> success:('a -> ('after, 'final, 'b) t)
        -> failure:(error -> ('failed, 'final, 'b) t)
        -> ('before, 'final, 'b) t
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
  ; maximum_resources : int; maximum_steps : int }
val limits : maximum_items:int -> maximum_bytes:int -> maximum_pending:int
  -> maximum_resources:int -> maximum_steps:int -> (limits, error) result
(** Positive bounds: items <= 4096, bytes <= 16777216, pending <= 4096,
    resources <= 1024, steps <= 65536. Validate before allocation. All retained
    files/leases/staging, including cancelled deliveries, count toward resources;
    reserve before acquisition. Failure retains its slot; cleanup needs no new
    slot. Completed jobs are pruned using monotonic ticket watermarks, not an
    unbounded set of tombstones. Queued notifications coalesce to resampling;
    terminal delivery is never dropped. Validation performs no graph scan. *)

type network_gate = Closed | Open of { authorization_epoch : int64 }
type key_status = Unencrypted | Key_locked | Key_available
type observation =
  { identity : identity; keys : key_status; network : network_gate
  ; checkpoint : Overlay.Types.server_cursor option
  ; pending_submissions : int; pending_assets : int; cleanup_pending : int }

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

type _ transport =
  | Head : remote_head transport
  | Fetch_snapshot : Overlay.Types.server_cursor -> snapshot transport
  | Pull : Overlay.Types.server_cursor -> Overlay.Types.authoritative_batch transport
  | Push : Overlay.Types.submission_batch -> submission_reply transport

(** Wire framing, authentication, cursor ordering, bounds and encryption envelopes
    are validated before typed responses are delivered. Empty/incomplete pages
    cannot advance a checkpoint. Remote head and snapshot download are not local
    activation. Push uncertainty retains the frozen batch; only network failures
    are eligible for timed retry. Rejection/authentication/protocol/crypto/storage
    failures need explicit correction, not an unchanged automatic retry. A
    retry decision is only a proposal: execution verifies its exact original
    classified network cause and frozen batch, not caller-supplied eligibility. *)

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
  | File_reference of asset_file | Lease_reference of asset_lease
type asset_result = Available of asset_file | Waiting_remote | Missing_local

type _ assets =
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
    Local source staging, durable import recovery, publication and pruning are
    owned by the injected asset capability under existing persistence rules.
    Retain creates a separately bounded native lease; release failure retains
    the original resource. Duplicate successful release is idempotent. Leases
    cannot be abandoned by claiming physical release. *)

type sync_action = Fetch_head | Fetch_base
  | Pull_after of Overlay.Types.server_cursor
  | Prepare_group of Overlay.Types.Graph.Uuid.t Rrbvec.t
  | Retry_frozen of Overlay.Types.submission_batch_id
  | Await_outcome of Overlay.Types.submission_batch_id | Idle
val next_sync : limits:limits -> base_present:bool -> keys:key_status -> network:network_gate
  -> view:Overlay.Types.sync_view option -> remote:remote_head option
  -> in_flight:Overlay.Types.submission_batch_id Rrbvec.t
  -> retry_network_failure:Overlay.Types.submission_batch_id option
  -> (sync_action, error) result
(** Pure bounded policy: closed gate or locked keys yields Idle; absent remote
    metadata yields Fetch_head. Without an activated base fetch a snapshot only
    when advertised, otherwise report Protocol_failure. Existing local intent
    cannot be overwritten. Submitted in-flight work yields Await_outcome, not a
    second send. Retry_frozen requires the exact caller-supplied network failure
    and uses Retry_group's frozen bytes/identity; unknown outcomes after restart
    require explicit durable reconciliation, not inferred timed retry. Accepted
    and stale-rejected batches permit pulls through their authoritative barriers;
    they must not deadlock waiting for outbox removal before pulling. Otherwise
    pull beyond the durable checkpoint, then prepare bounded dependency-eligible
    queued groups (deletions are singletons), or Idle. Inputs inconsistent with
    the durable token/batch state fail explicitly. The caller composes decisions
    into programs; this function performs no I/O, clocks or account selection. *)

type (_, _, _, _) operation =
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
    number of steps; a callback exception fails with the actual current phase. *)

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
