(** Pure programs; only the outer indexed program changes graph lifecycle.
    Indices prove neither runtime authority, linearity nor rollback. *)

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

val return : 'a -> ('s, 's, 'a) t
val abort : error -> ('s, 'final, 'a) t
val bind : ('before, 'middle, 'a) t -> ('a -> ('middle, 'after, 'b) t)
  -> ('before, 'after, 'b) t

val identity : origin:string -> account:string -> graph:string
  -> account_generation:int64 -> graph_generation:int64 -> (identity, error) result
(** Require canonical HTTPS origin, nonempty account/graph and nonnegative
    generations. Actual owner authority is rechecked on effects and completions. *)

type limits = private
  { maximum_items : int; maximum_bytes : int; maximum_pending : int
  ; maximum_resources : int; steps_per_turn : int
  ; maximum_tasks : int; maximum_messages : int; maximum_message_bytes : int
  ; maximum_demands : int; maximum_active_assets : int
  ; foreground_reserve : int
  ; foreground_demand_reserve : int; foreground_descriptor_reserve_bytes : int
  ; asset_cache_budget_bytes : int64; asset_maximum_file_bytes : int
  ; asset_pending_budget_bytes : int64
  ; snapshot_maximum_artifact_bytes : int64
  ; snapshot_staging_budget_bytes : int64; snapshot_scratch_budget_bytes : int64 }
val limits : maximum_items:int -> maximum_bytes:int -> maximum_pending:int
  -> maximum_resources:int -> steps_per_turn:int -> maximum_tasks:int
  -> maximum_messages:int -> maximum_message_bytes:int -> maximum_demands:int
  -> maximum_active_assets:int -> foreground_reserve:int
  -> foreground_demand_reserve:int -> foreground_descriptor_reserve_bytes:int
  -> asset_cache_budget_bytes:int64 -> asset_maximum_file_bytes:int
  -> asset_pending_budget_bytes:int64 -> snapshot_maximum_artifact_bytes:int64
  -> snapshot_staging_budget_bytes:int64 -> snapshot_scratch_budget_bytes:int64
  -> (limits, error) result
(** Positive bounds: items <= 4096, bytes <= 16777216, pending <= 4096,
    resources <= 1024, steps <= 65536, tasks <= 256, messages <= 4096,
    message_bytes <= 16777216, demands <= 4096, active_assets <= pending.
    Require tasks and pending >= active_assets + 4; reserve three pending slots
    for receive/database/input plus foreground_reserve for foreground assets.
    Foreground reserves: work in [1..active_assets], interests in [1..demands],
    descriptors in [1..message_bytes]; messages >= foreground_demand_reserve + 3
    for stop/gate/unlock. Background cannot borrow reserved work, task, message,
    interest or descriptor capacity. Foreground uses the total, not extra pools.
    Outbox dirty and latest observation each have an independent fixed slot.
    Active and pending interests count per ID; shared transfers count once.
    Same-ID replacement charges net descriptors atomically; rejection changes
    nothing. Demotion checks background capacity; withdrawal/stop/cleanup retain
    reserved control capacity. Reclassify shared foreground work before admission.
    Ingress, task-held, output and cleanup descriptors share message_bytes;
    ownership transfer/dequeue reclaims nothing. Finish_demand ends the interest;
    discard ends descriptor charges, physical cleanup ends resource/byte charges.
    Reserve before allocation/acquisition/writes with checked arithmetic;
    cancelled resources and failed cleanup remain charged; cleanup needs no new
    slot. Prune completed jobs with monotonic watermarks, not growing tombstones;
    terminal delivery cannot be dropped. steps_per_turn is a fair-turn quantum.
    Snapshot artifact/staging/scratch budgets are independent positive int64s:
    zero/negative is Invalid_input; staging below artifact is legal but may yield
    Capacity_exceeded. No 16 MiB artifact cap: 32 MiB and 1 GiB are legal totals.
    Reserve aggregate staging and scratch separately before writes/allocations;
    encrypted originals and plaintext intermediates coexist and both stay charged
    until cleanup. Stream complete checksum/row-count verification and activation;
    each chunk/decryption batch <= maximum_bytes and rows <= maximum_items.
    Metadata/frames obey small-message bounds; never buffer an entire artifact.
    Snapshot limits do not replace asset limits. Asset cache/pending budgets are
    nonnegative int64s, file bytes in [0..104857600]; zero disables that class.
    Cache includes pinned files; pending includes unreleased/recovered staging.
    Enforce actual file bytes even with false/absent size metadata. Pruning cannot
    delete pinned bytes or durable unpublished originals. Incremental recovery
    accounts existing files/orphans before admission; over-budget stores permit
    only bounded recovery/prune/release. Validation reads configuration, not files
    or graph data; exhaustion is explicit, never spinning or silent eviction. *)

type retry_policy = private
  { initial_seconds : float; maximum_seconds : float
  ; multiplier : float; maximum_attempts : int }
val retry_policy : initial_seconds:float -> maximum_seconds:float
  -> multiplier:float -> maximum_attempts:int -> (retry_policy, error) result
(** Finite positive delays; maximum >= initial, multiplier >= 1, attempts in
    [0..10] (zero disables retry). EDSL uses capped exponential Sleep; count actual
    admissions. Only network failures permit retry, never unchanged other errors. *)

type network_gate = Closed | Open of { authorization_epoch : int64 }
type key_status = Unencrypted | Key_locked | Key_available
type observation =
  { identity : identity; keys : key_status; network : network_gate
  ; checkpoint : Overlay.Types.server_cursor option
  ; pending_submissions : int; pending_assets : int; cleanup_pending : int
  ; last_failure : error option }

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
(** Shape-only process-local descriptor: the producer registers token/kind before
    delivery; execution checks its real original-owner ledger even after revocation. *)

type snapshot = private
  { resource : resource; through : Overlay.Types.server_cursor
  ; checksum : string; encrypted : bool }
val snapshot : resource:resource -> through:Overlay.Types.server_cursor
  -> checksum:string -> encrypted:bool -> (snapshot, error) result
(** Staged immutable bytes remain owed until checked release, even when stale.
    Activation checks actual producer metadata, baseline, checksum and encryption. *)

type _ database =
  | Inspect : Overlay.Types.sync_view database
  | Prepare_submission : Overlay.Types.sync_token * Overlay.Types.outbox_transition
      -> Overlay.Types.outbox_commit database
  | Apply_authoritative : Overlay.Types.sync_token * Overlay.Types.authoritative_batch
      -> authoritative_result database
  | Activate_snapshot : snapshot -> activation database
  | Release_snapshot : snapshot -> unit database

(** Inspect checks configured record/descriptor bounds before enumeration; never
    truncate. Prepare freezes durable wires before send; conflicts need fresh views.
    Acceptance retains intent until authoritative reconciliation. Deferred retains
    its original batch and waits for its exact submission outcome. Activation
    atomically checks generation/baseline/local intent; deferral is not activation.
    Cancellation preserves commits; reconcile uncertainty by original identifiers. *)

type remote_head =
  { through : Overlay.Types.server_cursor; snapshot_available : bool }
type pull_result =
  | Pulled of Overlay.Types.authoritative_batch
  | No_progress of
      { since : Overlay.Types.server_cursor; through : Overlay.Types.server_cursor }
(** Validate connection generation, pending Pull baseline and every wire cursor
    before filtering replays. Pulled is nonempty and advances that baseline;
    No_progress covers empty/replayed pages with matched since and through >= since.
    Neither advances local checkpoint; only Apply_authoritative commits Pulled.
    No_progress never applies/ACKs barriers: retain greatest remote target,
    re-inspect, prioritize Submitted recovery, then settle if caught up or Sleep
    a finite positive delay before re-pull. No hidden adapter loop or forged cursor. *)

type submission_reply =
  | Accepted of Overlay.Types.acceptance_barrier
  | Rejected of Overlay.Types.rejection_resolution

type connection
(** Connect produces a registered, fresh process-local token/generation; shape
    validation grants no authority. Every use checks its original producer;
    connection retirement invalidates it without retiring the graph. *)
val connection : owner:identity -> token:string -> generation:int64
  -> (connection, error) result

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
  | Pull : Overlay.Types.server_cursor -> pull_result transport
  | Push : Overlay.Types.submission_batch -> submission_reply transport

(** Validate framing/authentication/cursors/bounds/envelopes before delivery.
    Wrap Head/Fetch_snapshot/Pull/Push exactly once in On_connection, never
    connection management. One socket reader matches responses to bounded pending
    requests; no request-ID multiplexer: at most one unresolved response-family
    request (including Push). Match generation, baseline, frozen tx-id/barrier;
    ambiguity fails the connection and retains Submitted. pull/ok with txs=[]
    completes its Pull with No_progress, not Receive or a new wire field.
    Head uses existing hello/head state. One pending Receive per connection;
    overflow backpressures. Only Remote_changed hints coalesce by resampling,
    never responses/terminal messages/batches. Bound frames before allocation.
    Retire joins reader/writer/requests/callbacks; Connect rejects until old join.
    Only Remote_closed/Network_lost permit EDSL backoff, not local close or
    unchanged auth/protocol/crypto/storage rejection. Authentication uses injected
    credentials and one checked refresh; exhaustion waits for corrected authority.
    Recovery uses Inspect Submitted IDs then Retry_group with a fresh token;
    require the original batch ID, t_before and exact protected wires, not None.
    Push uses existing tx-batch t-before/tx-id/protected tx/outliner-op: no batch
    status endpoint or server batch-ID deduplication is implied. Stale is not
    proof of prior non-execution; Accept_group/Reject_group then Pull reconcile.
    New work uses Submit_group, never reconstruction of uncertain submissions.
    Rejection partitions frozen member order: success_tx_ids is an ordered prefix,
    failed_tx_id the next member, unexecuted_suffix the exact remainder. Omitted
    failed ID means first member only for an empty prefix. Nonempty prefix needs
    validated cursor/checksum barrier; empty prefix has None. Invalid partitions,
    duplicates/foreign IDs/missing barriers fail Protocol_failure, retaining wires.
    Empty_tx_data/Invalid_tx/Invalid_t_before -> Overlay.Invalid_request;
    Db_transact_failed with missing_block_uuids -> Missing_dependencies;
    other Db_transact_failed/Snapshot_upload_in_progress -> Operational_failure.
    Preserve bounded missing IDs/diagnostics. Stale needs an advancing cursor and
    maps to Overlay.Stale, never a definitive partition. Preserve real
    Permission_denied without inventing a wire reason. Remote_error is a scoped
    non-retryable protocol error, never an unmatched Push result or dropped hint;
    retain uncertain submissions. Presence is not sync; ping/pong is only liveness. *)

type unlock_input
val unlock_input : wrapped_graph_key:string -> (unlock_input, error) result
val wrapped_graph_key : unlock_input -> string
(** Wrapped material only; never log keys. Unlock verifies/installs this graph's
    key; still locked means Error Locked. Callers own key acquisition/coordination. *)
type _ crypto = Unlock : unlock_input -> key_status crypto

type asset = Logseq_db_types.Asset_descriptor.t

type asset_file = private { file : resource; asset : asset }
type asset_lease = private { lease : resource; source : asset_file }
val asset_file : resource -> asset -> (asset_file, error) result
val asset_lease : resource -> asset_file -> (asset_lease, error) result

type resource_reference = Snapshot_reference of snapshot
  | Connection_reference of connection
  | File_reference of asset_file | Lease_reference of asset_lease
type asset_result = Available of asset_file | Waiting_remote | Missing_local

type cache_report =
  { resident_bytes : int64; pending_bytes : int64; retained_bytes : int64
  ; cleanup_pending : int; over_budget : bool }
(** retained_bytes is already included in resident/pending, not an additive pool. *)

type _ assets =
  | Prune_cache : cache_report assets
  | Lookup : asset -> asset_file option assets
  | Download : asset -> asset_result assets
  | Upload : asset -> unit assets
  | Retain : asset_file -> asset_lease assets
  | Release_file : asset_file -> unit assets
  | Release_lease : asset_lease -> unit assets

(** Original-owner registered files/leases are process-local and generation-checked.
    Upload uses durable publication intent; success is verified remote publication,
    not a user edit. Download verifies encryption/checksum, never plaintext fallback.
    Lookup is offline: for Managed remote B/current A try original A then cached B;
    Managed None/current A checks A, whose miss is Waiting_remote (never GET A).
    Managed None without A waits for publication. Download only explicit remote B;
    External never enters managed transfers. Result asset preserves selection;
    registered metadata identifies actual bytes; Retain/Publish validate both.
    Lookup sharing binds full incarnation/UUID/current/remote checksum/file_type;
    transfer dedup binds incarnation/UUID/remote checksum/file_type, not demand ID.
    Each interest revalidates selection and retains its own lease before publish.
    spawn_asset binds revision: replacement cancels its obsolete interest; generic
    Lookup may return old selection but cannot publish to a changed receipt.
    Remote-version changes require explicit replacement Demand. Locked/missing
    versions wait, never fabricate successful bytes. Restore incrementally accounts
    existing staging/cache offline. Prune yields bounded batches, removing only
    unpinned cache/proven orphan staging; durable unpublished originals stay.
    Pressure waits for release/correction, never retries storage failures in a loop.
    Retain creates a separate bounded lease; release is idempotent only after
    success. Failed cleanup retains exact handles/paths/charges and concrete error. *)

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
(** Ingress-minted exact revision; replacement or scope exit invalidates it. *)
type unlock_receipt
(** Single-use graph/scope-bound wrapped revision; replacement, expiry or scope
    exit invalidates it. No restart persistence or printable key material. *)
type service_input =
  | Unlock_requested of unlock_receipt
  | Demand_changed of demand_receipt * demand_change
  | Network_changed of network_gate
  | Stop_requested
(** Demand IDs are nonempty <= 256 bytes. Replacement changes exact selection and
    priority; withdrawal cancels only that interest, not other shared users. *)

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
(** Joined result; attempts counts this invocation's actual scoped remote
    admissions (zero if none), never scheduled tasks. No implicit retry. Business
    failures are data; stale usage/unjoined cleanup remain task-effect errors. *)

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
(** Runtime-minted owner/incarnation/revision/scope binding; received delivery
    retains original cleanup obligation through revocation until release ACK. *)
type demand_output = private
  { delivery : demand_delivery
  ; id : demand_id
  ; demand : demand_receipt
  ; availability : demand_availability }

(** All availability states use delivery/release, even without resources.
    attempts >= 0; retry_scheduled requires an actual bounded network retry timer.
    Only network failures permit retry; locked/closed wait for correction, then
    fresh Lookup. Publish expected failures per interest without stopping unrelated
    sync work. Never change uncertain durable publication identity. *)

type outbox_check

type 'a wake = Input of service_input | Child_ready of 'a child

type notifications
type notification =
  | Policy_failure of error
  | Connected of connection
  | Remote_received of received
  | Connection_retired of connection

type service_status =
  | Service_idle
  | Service_connecting
  | Service_online
  | Service_waiting_network
  | Service_waiting_unlock
  | Service_backoff of { attempt : int; seconds : float; cause : error }
  | Service_blocked of error

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
(** Outbox is independent level-triggered dirtiness, retained without a waiter.
    One task owns await-to-ACK reservation; competitors fail Invalid_input.
    Start/restore/unlock/activation/reopen mark dirty; Connected calls Resample.
    Await captures epoch before Inspect; ACK clears only that epoch after installing
    a successful bounded plan. Commits during Inspect stay dirty; no wrap loss.
    Abandon/failure/cancel/scope exit releases reservation, never dirtiness;
    old/foreign/duplicate checks fail Stale_context. Inspect may run Closed;
    after waiting for Open re-inspect before preparing fresh wires. Absent mirror
    waits for activation, never spins. Resample marks dirty without I/O.
    Task_observe is local metadata; one publisher replaces latest status, bounded
    sibling Notifications forward causes. Actual gate/counts/cleanup override policy.
    Sleep is finite nonnegative monotonic/cancellable. Effects may suspend without
    blocking siblings, ingress or control. Database mutations share the external owner.
    Wait_network_open waits for authorized Open and old network join, not a permit;
    each admission rechecks. Consume_unlock atomically consumes live receipt before
    local crypto; stale/expired fails without crypto. Crypto failure needs fresh
    input; discard payload after joined crypto, never expose key diagnostics.
    Publish validates revision/selection/resources/capacity atomically: success
    transfers file+lease to runtime (task must not release/republish), failure
    transfers nothing. Available requires live Demand, Revoked live Withdraw;
    waiting/missing carry no resources. Reject duplicate transferred references.
    One unreceived publication per revision may be replaced; release superseded
    resources before reclaiming slots. Changed revisions invalidate queued output;
    received resources are only revoked, never reclaimed before release_demand ACK.
    Scope exit cleans unreceived output, retains received/failed cleanup and blocks
    retirement. Finish_demand cannot erase output/cleanup or newer revisions.
    Download_demand uses ordinary Download once after EDSL Lookup; no-version waits
    without remote admission; Closed/Locked report waiting causes with zero attempts.
    Count active work through physical join, including generic Download/Upload;
    background cannot borrow foreground reserve. Replacement reclassifies shared
    work before admission. Finish_demand follows joined children and transferred/
    released resources; stale revisions cannot finish newer interests.
    Notifications reserves a resource slot; queues share message count/bytes.
    Notify backpressures; only adjacent same-connection Remote_changed coalesce,
    never transitions. One consumer per channel; fan-out uses explicit channels.
    Scope exit joins children before queue release. Await_input_or_child uses
    readiness, not polling: unique live same-scope children <= maximum_tasks.
    Atomically consume winning input only; Child_ready is not join, cancellation
    consumes neither. Stop first, otherwise fair input/ready-child choice; shares
    Next_input's sole consumer reservation. *)

val task_return : 'a -> 'a task
val task_bind : 'a task -> ('a -> 'b task) -> 'b task
val task_fail : error -> 'a task
val task_perform : 'a task_effect -> success:('a -> 'b task)
  -> failure:(error -> 'b task) -> 'b task
val with_scope : (scope -> 'a task) -> 'a task
val spawn : scope -> 'a task -> ('a child, error) result task
val spawn_asset : scope -> demand_receipt -> 'a task -> ('a child, error) result task
(** spawn_asset binds current revision/priority; ordinary children cannot borrow
    foreground task slots. Replacement reclassifies before admission; cancellation
    holds slots through join. Schedule fair bounded foreground bursts with eventual
    background turns; wait on input/children for capacity, never busy-poll. *)
val equal_child : 'a child -> 'a child -> bool
val join : 'a child -> ('a, error) result task
val cancel_child : 'a child -> unit task

(** Scope exit cancels then joins children and producers on every path; completed
    children keep slots until one join consumes them. Foreign/expired/reused joins
    fail. Child cancel affects its subtree only. Report unobserved child failures;
    scope-caused Cancelled is not a new primary, but cleanup/unknown outcomes stay.
    Reserve task/terminal/queue capacity before spawn. Network_closed is an ordinary
    joined failure, not graph cancellation. *)

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
(** Pure total projection. Continuations must terminate without I/O; yield after
    steps_per_turn, fairly including completions/input, with no lifetime step cap.
    Bound retained tasks/waiters/ready queues and reserve terminal capacity. *)

(** Interpreter-only handle production, no I/O/policy. Execute keeps one private
    freshly allocated owner, never passes it to adapters/programs. Equal identity
    is not equal ownership. No handle survives restart. Foreign/closed checks fail
    Stale_context before allocation/callback; original cleanup remains legal.
    Execute reserves/registers bounded handles and checks current operation ledgers;
    construction proves neither admission, authority, revision nor resource ACK. *)
module Producer : sig
  type owner
  val create : identity -> owner
  val scope : owner -> scope
  val check_scope : owner -> scope -> (unit, error) result
  val close_scope : owner -> scope -> (unit, error) result
  (** Check exact live owner/scope. Original-owner close is idempotent, only after
      Execute cancels/joins producers; close itself does neither. Received delivery
      cleanup survives close. *)

  val child : owner -> scope -> 'a task
    -> poll:(unit -> ('a, error) result option) -> ('a child, error) result
  val check_child : owner -> scope -> 'a child -> (unit, error) result
  val child_result : owner -> scope -> 'a child
    -> (('a, error) result option, error) result
  val forget_child : owner -> scope -> 'a child -> (unit, error) result
  (** Execute reserves a slot and binds poll to the exact task's typed promise.
      Check owner/live scope/unconsumed registration before poll; None is unfinished,
      Some repeatable terminal data, not join. Foreign checks never invoke poll.
      forget follows physical join, drops callback/slot; repeated original forget
      is idempotent but consumed check/result fails Stale_context. Bound handles/
      callbacks without a second registry or growing tombstones; handles retain
      owner/validity after pruning. Producer cannot prove callback honesty. *)

  val demand_receipt : owner -> scope -> (demand_receipt, error) result
  val unlock_receipt : owner -> scope -> (unlock_receipt, error) result
  val outbox_check : owner -> scope -> (outbox_check, error) result
  val notifications : owner -> scope -> (notifications, error) result
  val check_demand_receipt : owner -> scope -> demand_receipt -> (unit, error) result
  val check_unlock_receipt : owner -> scope -> unlock_receipt -> (unit, error) result
  val check_outbox_check : owner -> scope -> outbox_check -> (unit, error) result
  val check_notifications : owner -> scope -> notifications -> (unit, error) result
  (** Fresh identities after reservation, registered before delivery. Execute binds
      demand selection/revision/priority, unlock envelope/expiry, outbox epoch and
      channel queue, checking currency/consumption atomically in addition to owner/
      live scope. No identity reuse, registration resurrection or growing tombstones. *)

  val demand_output : owner -> scope -> demand_receipt -> id:demand_id
    -> demand_availability -> (demand_output, error) result
  val check_delivery : owner -> demand_delivery -> (unit, error) result
  (** Execute checks live receipt ID/selection, publication legality/resources/
      capacity before atomic registration/enqueue. Producer only creates output,
      never validates leases or transfers ownership. check_delivery checks original
      owner after scope close; Execute still checks ledger/release watermarks. *)
end

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
(** Total pure projection including bind normalization; callbacks terminate without
    I/O/yield. Exceptions report actual phase, not the requested final phase. *)

val run_task : 'a task -> (ready, ready, ready, 'a) operation

val restore : (cold, ready, cold, restore_report) operation
val set_network : network_gate -> (ready, ready, ready, unit) operation
val database : 'a database -> (ready, ready, ready, 'a) operation
val transport : 'a transport -> (ready, ready, ready, 'a) operation
val crypto : 'a crypto -> (ready, ready, ready, 'a) operation
val assets : 'a assets -> (ready, ready, ready, 'a) operation
val observe : ('s, 's, 's, observation) operation
(** Ready need not mean activated/unlocked. Restore is local-only and leaves Closed;
    missing mirror succeeds with checkpoint None (Inspect fails until activation).
    Locked bases restore metadata without plaintext. Partial restore failure stays
    cold with cleanup owed. Open checks actual epoch; Close fences then joins,
    never rolls back unknown/committed work. Transport/Download/Upload check Open
    at admission and execution; local inspect/reconcile/unlock/release do not.
    Locked rejects protected work before bytes; ordinary failures retain ready
    with durable outcomes/resources visible in observation. *)

val begin_drain : 's drainable -> ('s, draining, draining, unit) operation
val finish_retirement : (draining, retired, draining, unit) operation
val release_file : asset_file -> ('s, 's, 's, unit) operation
val release_lease : asset_lease -> ('s, 's, 's, unit) operation
val release_snapshot : snapshot -> ('s, 's, 's, unit) operation
(** Drain irreversibly fences before cancel; failure stays draining. Retirement
    requires physical joins of all work/callbacks/delegations and resource cleanup;
    cancel or gate close is insufficient. Retain original owners after replacement.
    Retired permits only idempotent release/cached observation, never deletion or
    account replacement. Cancellation returns actual phase and concrete error. *)

val error_message : error -> string
(** Bounded sync metadata, not user queries, presentation ACK or physical completion.
    Restart uses a fresh incarnation and existing durable recovery records only. *)
