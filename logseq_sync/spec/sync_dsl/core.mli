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
  ; foreground_reserve : int }
val limits : maximum_items:int -> maximum_bytes:int -> maximum_pending:int
  -> maximum_resources:int -> steps_per_turn:int -> maximum_tasks:int
  -> maximum_messages:int -> maximum_message_bytes:int -> maximum_demands:int
  -> maximum_active_assets:int -> foreground_reserve:int -> (limits, error) result
(** Positive bounds: items <= 4096, bytes <= 16777216, pending <= 4096,
    resources <= 1024, steps_per_turn <= 65536, tasks <= 256, messages <= 4096,
    message_bytes <= 16777216, demands <= 4096, active_assets <= pending.
    Foreground reserve is in [1..maximum_active_assets]. Background admissions
    cannot consume that reserve. Active and pending demands both count against
    maximum_demands; one active transfer per exact asset version is shared.
    Require tasks >= 4 and pending >= active_assets + 4. Reserve three pending
    slots for receive, sync database and input, plus foreground_reserve for
    foreground assets; ordinary/background work cannot borrow these reservations.
    Queue/ingress descriptor bytes share maximum_message_bytes, including replaced
    and in-delivery values until ownership transfers; reject before allocation.
    steps_per_turn is a fair scheduling quantum, never a service lifetime limit.
    Validate before allocation. All retained
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
    recovery path. New submissions use Submit_group, never reconstructed retries. *)

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

type demand_availability =
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

type 'a wake = Input of service_input | Child_ready of 'a child

type notifications
type notification =
  | Connected of connection
  | Remote_received of received
  | Connection_retired of connection
(** A bounded scope-owned channel carries connection identity and remote hints
    from the sole receiver to sync/asset policy. It owns no socket or graph. *)

type _ task_effect =
  | Notifications : scope -> notifications task_effect
  | Notify : notifications * notification -> unit task_effect
  | Next_notification : notifications -> notification task_effect
  | Task_database : 'a database -> 'a task_effect
  | Task_transport : 'a transport -> 'a task_effect
  | Task_crypto : 'a crypto -> 'a task_effect
  | Task_assets : 'a assets -> 'a task_effect
  | Consume_unlock : unlock_receipt -> key_status task_effect
  | Publish_demand : demand_receipt * demand_availability -> unit task_effect
  | Download_demand : demand_receipt -> asset_result task_effect
  | Finish_demand : demand_receipt -> unit task_effect
  | Wait_network_open : unit task_effect
  | Next_input : service_input task_effect
  | Await_input_or_child : 'a child Rrbvec.t -> 'a wake task_effect
  | Sleep : float -> unit task_effect
  | Yield : unit task_effect
(** Sleep uses finite nonnegative monotonic seconds and is cancellable. All
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
    uses the ordinary Download adapter. A withdrawn/stale revision cannot start.
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
          | Demand_changed (receipt, Demand _) ->
            task_perform (Download_demand receipt) ~failure:task_fail
              ~success:(fun result ->
                let publish = match result with
                  | Available file -> publish_available receipt file
                  | Waiting_remote -> task_perform
                      (Publish_demand (receipt, Demand_waiting_remote))
                      ~success:task_return ~failure:task_fail
                  | Missing_local -> task_perform
                      (Publish_demand (receipt, Demand_missing_local))
                      ~success:task_return ~failure:task_fail in
                task_bind publish (fun () -> asset_service on_other))
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
