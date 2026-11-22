(** Indices express lifecycle, not runtime authority, linearity or rollback. *)

type cold
type ready
type draining
type retired

type _ phase =
  | Cold : cold phase
  | Ready : ready phase
  | Draining : draining phase
  | Retired : retired phase

type _ drainable =
  | Cold_context : cold drainable
  | Ready_context : ready drainable
  | Draining_context : draining drainable

type identity = private
  { origin : string
  ; account : string
  ; graph : string
  ; account_generation : int64
  ; graph_generation : int64
  }

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
  | Cleanup_failure of
      { primary : error option
      ; failures : error Rrbvec.t
      }
  | Capacity_exceeded of string
  | Sync_read_failure of Overlay.Types.sync_read_error
  | Outbox_failure of Overlay.Types.outbox_transition_error
  | Authoritative_failure of Overlay.Types.authoritative_transition_error
  | Activation_failure of Overlay.Types.snapshot_activation_error
  | Asset_failure of Logseq_db_types.Failure_diagnostic.t
  | Unexpected_failure of string

type ('before, 'after, 'value) program

val return : 'a -> ('s, 's, 'a) program
val abort : error -> ('s, 'final, 'a) program

val bind
  :  ('before, 'middle, 'a) program
  -> ('a -> ('middle, 'after, 'b) program)
  -> ('before, 'after, 'b) program

(** Canonical HTTPS origin, nonempty account/graph, nonnegative generations; effects recheck actual authority. *)
val identity
  :  origin:string
  -> account:string
  -> graph:string
  -> account_generation:int64
  -> graph_generation:int64
  -> (identity, error) result

type limits = private
  { maximum_items : int
  ; maximum_bytes : int
  ; maximum_pending : int
  ; maximum_resources : int
  ; steps_per_turn : int
  ; maximum_tasks : int
  ; maximum_messages : int
  ; maximum_message_bytes : int
  ; maximum_websocket_downlink_bytes : int
  ; maximum_demands : int
  ; maximum_active_assets : int
  ; foreground_reserve : int
  ; foreground_demand_reserve : int
  ; foreground_descriptor_reserve_bytes : int
  ; asset_cache_budget_bytes : int64
  ; asset_maximum_file_bytes : int
  ; asset_pending_budget_bytes : int64
  ; snapshot_maximum_artifact_bytes : int64
  ; snapshot_staging_budget_bytes : int64
  ; snapshot_scratch_budget_bytes : int64
  }

(** Positive bounds: items/pending/messages/demands <= 4096, bytes/message_bytes <= 16777216,
    resources <= 1024, steps <= 65536, tasks <= 256; active_assets <= pending.
    Tasks/pending >= active_assets + 4; reserve three pending control slots plus foreground work.
    Foreground reserves: work [1..active_assets], interests [1..demands], descriptors [1..message_bytes];
    messages >= foreground_demand_reserve + 3. Background cannot borrow reserves.
    Charge interests per ID, shared transfers once; replacement uses atomic net descriptors.
    Dequeue reclaims nothing; cancelled/failed cleanup remains charged through physical join.
    Reserve before acquisition; control/release need no new slot. Exhaustion never evicts accepted work.
    Snapshot artifact/staging/scratch budgets are independent positive int64s, without a 16 MiB artifact cap;
    staging below artifact is legal. Charge encrypted/plaintext coexistence until cleanup;
    stream verification/activation within maximum_bytes/items.
    Asset cache/pending budgets are nonnegative; file bytes [0..104857600]; zero disables that class.
    Count pinned/recovered files and actual sizes before admission; over-budget permits only recovery/prune/release.
    Never prune pinned bytes or durable unpublished originals. Validation reads configuration only. *)
val limits
  :  maximum_items:int
  -> maximum_bytes:int
  -> maximum_pending:int
  -> maximum_resources:int
  -> steps_per_turn:int
  -> maximum_tasks:int
  -> maximum_messages:int
  -> maximum_message_bytes:int
  -> maximum_demands:int
  -> maximum_active_assets:int
  -> foreground_reserve:int
  -> foreground_demand_reserve:int
  -> foreground_descriptor_reserve_bytes:int
  -> asset_cache_budget_bytes:int64
  -> asset_maximum_file_bytes:int
  -> asset_pending_budget_bytes:int64
  -> snapshot_maximum_artifact_bytes:int64
  -> snapshot_staging_budget_bytes:int64
  -> snapshot_scratch_budget_bytes:int64
  -> (limits, error) result

type retry_policy = private
  { initial_seconds : float
  ; maximum_seconds : float
  ; multiplier : float
  ; maximum_attempts : int
  }

(** Finite positive delays, maximum >= initial, multiplier >= 1, attempts [0..10].
    maximum_attempts counts actual retry admissions after the initial attempt; zero disables retry.
    Only network failures retry, using capped exponential monotonic Sleep. *)
val retry_policy
  :  initial_seconds:float
  -> maximum_seconds:float
  -> multiplier:float
  -> maximum_attempts:int
  -> (retry_policy, error) result

type network_gate =
  | Closed
  | Open of { authorization_epoch : int64 }

type key_status =
  | Unencrypted
  | Key_locked
  | Key_available

type observation =
  { identity : identity
  ; keys : key_status
  ; network : network_gate
  ; checkpoint : Overlay.Types.server_cursor option
  ; pending_submissions : int
  ; pending_assets : int
  ; cleanup_pending : int
  ; last_failure : error option
  }

type restore_report =
  { keys : key_status
  ; checkpoint : Overlay.Types.server_cursor option
  ; recovery_pending : bool
  }

type activation =
  | Activated of Overlay.Types.generation
  | Activation_deferred of string

type authoritative_result =
  | Applied of Overlay.Types.authoritative_commit
  | Deferred of Overlay.Types.authoritative_defer

type resource_release

type resource = private
  { owner : identity
  ; token : string
  ; release : resource_release
  }

(** Shape-only process-local descriptor; use/release checks the registered original-owner ledger, even after revocation. *)
val resource : owner:identity -> token:string -> (resource, error) result

type snapshot = private
  { resource : resource
  ; through : Overlay.Types.server_cursor
  ; checksum : string
  ; encrypted : bool
  }

(** Staged bytes remain owed until checked release; activation verifies producer metadata, baseline, checksum and encryption. *)
val snapshot
  :  resource:resource
  -> through:Overlay.Types.server_cursor
  -> checksum:string
  -> encrypted:bool
  -> (snapshot, error) result

type _ database =
  | Inspect : Overlay.Types.sync_view database
  | Verify_checksum :
      Overlay.Types.server_cursor * Overlay.Types.checksum
      -> unit database
  | Prepare_submission :
      Overlay.Types.sync_token * Overlay.Types.outbox_transition
      -> Overlay.Types.outbox_commit database
  | Apply_authoritative :
      Overlay.Types.sync_token * Overlay.Types.authoritative_batch
      -> authoritative_result database
  | Activate_snapshot : snapshot -> activation database
  | Release_snapshot : snapshot -> unit database

(** Inspect rejects oversized views, never truncates. Prepare durably freezes wires before send;
    conflicts need fresh tokens. Deferred retains the original batch and exact submission outcome.
    Activation checks generation/baseline/local intent atomically; cancellation preserves commits. *)

type remote_head =
  { through : Overlay.Types.server_cursor
  ; snapshot_available : bool
  ; expected_checksum : Overlay.Types.checksum option
  }

type pull_result =
  | Pulled of Overlay.Types.authoritative_batch
  | No_progress of
      { since : Overlay.Types.server_cursor
      ; through : Overlay.Types.server_cursor
      ; expected_checksum : Overlay.Types.checksum option
      }
  (** Validate generation, issued baseline and all cursors before filtering; Pulled advances baseline.
    No_progress matches since with through >= since; neither result advances checkpoint without apply.
    Retain greatest target, recover Submitted, then settle or delay before re-pull; never ACK a barrier. *)

type submission_reply =
  | Accepted of Overlay.Types.acceptance_barrier
  | Rejected of Overlay.Types.rejection_resolution

(** Fresh registered connection generation; every use checks its original producer. Retirement invalidates the connection, not the graph. *)
type connection

val connection
  :  owner:identity
  -> token:string
  -> generation:int64
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

type received =
  { connection : connection
  ; message : remote_message
  }

type _ transport =
  | Connect : connection transport
  | Receive : connection -> received transport
  | Retire_connection : connection -> unit transport
  | On_connection : connection * 'a transport -> 'a transport
  | Head : remote_head transport
  (** Metadata defines the baseline independently of WebSocket connections. *)
  | Fetch_snapshot : snapshot transport
  | Pull : Overlay.Types.server_cursor -> pull_result transport
  | Push : Overlay.Types.submission_batch -> submission_reply transport

(** Validate framing/authentication/cursors/bounds before delivery. Wrap only Head/Pull/Push
    once in On_connection; one unresolved response-family request and one Receive per connection.
    Match generation/baseline/frozen IDs/barriers; ambiguity fails the connection, retaining Submitted.
    Empty/replayed Pull returns No_progress. Only Remote_changed hints coalesce; overflow backpressures.
    Retire physically joins readers/writers/requests/callbacks before reconnect. Only remote network loss retries.
    Authentication allows one checked refresh, then requires corrected authority.
    Retry_group uses original batch ID, t_before and exact durable wires with a fresh Inspect token;
    unknown sends never become fresh submissions. Accept/Reject then Pull reconcile uncertain execution.
    Rejection validates exact ordered prefix/failed member/suffix and prefix barrier; invalid partitions retain wires.
    Omitted failed ID requires empty prefix; Stale needs advancing cursor, never proves non-execution.
    Preserve typed rejection causes/bounded diagnostics; Remote_error is non-retryable and retains uncertainty. *)

type unlock_input

val unlock_input : wrapped_graph_key:string -> (unlock_input, error) result

(** Wrapped material only; never log keys. Still-locked Unlock returns Locked; caller owns key acquisition. *)
val wrapped_graph_key : unlock_input -> string

type _ crypto =
  | Unlock : unlock_input -> key_status crypto
  | Encrypt_values : string Rrbvec.t -> (string * string) Rrbvec.t crypto
  | Decrypt_value : string -> string crypto
  | Protect :
      Overlay.Database.protection_request
      -> (Overlay.Types.crypto_item_id * string) list crypto
  | Unprotect :
      Overlay.Database.unprotection_request
      -> (Overlay.Types.crypto_item_id * string) list crypto
  (** Graph keys stay with their owner. Encrypt_values preserves order; Decrypt_value validates Transit.
    Protect/Unprotect preserve exact IDs/cardinality; bound all bytes/items, never plaintext fallback. *)

type asset = Logseq_db_types.Asset_descriptor.t

type asset_file = private
  { file : resource
  ; asset : asset
  }

type asset_lease = private
  { lease : resource
  ; source : asset_file
  }

val asset_file : resource -> asset -> (asset_file, error) result
val asset_lease : resource -> asset_file -> (asset_lease, error) result

type resource_reference =
  | Snapshot_reference of snapshot
  | Connection_reference of connection
  | File_reference of asset_file
  | Lease_reference of asset_lease

type asset_result =
  | Available of asset_file
  | Waiting_remote
  | Missing_local

(** retained_bytes is included in resident/pending, not additive. *)
type cache_report =
  { resident_bytes : int64
  ; pending_bytes : int64
  ; retained_bytes : int64
  ; cleanup_pending : int
  ; over_budget : bool
  }

type _ assets =
  | Prune_cache : cache_report assets
  (** Original owner proves retention from durable inputs/checkpoints, serialized with preparation. *)
  | Reconcile_staging : int assets
  | Lookup : asset -> asset_file option assets
  | Download : asset -> asset_result assets
  | Upload : asset -> unit assets
  | Retain : asset_file -> asset_lease assets
  | Release_file : asset_file -> unit assets
  | Release_lease : asset_lease -> unit assets

(** Registered files/leases are process-local and original-owner checked. Upload ACK means verified publication.
    Lookup is offline: Managed remote B/current A tries original A then cached B;
    Managed None/current A checks A, then waits (never GET A); External never transfers.
    Download requires explicit remote version and verifies encryption/checksum, without plaintext fallback.
    Results preserve selection; Retain/Publish check actual byte metadata. Sharing includes incarnation,
    UUID/checksums/file_type; transfer dedup omits demand ID, but each interest needs its own lease.
    Replacement invalidates old publication rights. Locked/missing versions wait for correction.
    Prune only unpinned cache/proven orphan staging; unpublished originals survive.
    Release is idempotent only after success; failed cleanup retains handles/paths/charges/causes. *)

type 'a task
type scope
type !'a child
type demand_id

val demand_id : string -> (demand_id, error) result
val compare_demand_id : demand_id -> demand_id -> int

type priority =
  | Foreground
  | Background

type demand_change =
  | Demand of
      { id : demand_id
      ; asset : asset
      ; priority : priority
      }
  | Withdraw of demand_id

(** Exact ingress revision; replacement/scope exit invalidates it. *)
type demand_receipt

(** Single-use wrapped revision; replacement/expiry/scope exit invalidates it. Never persists or prints keys. *)
type unlock_receipt

type service_input =
  | Unlock_requested of unlock_receipt
  | Demand_changed of demand_receipt * demand_change
  | Network_changed of network_gate
  | Stop_requested
  (** IDs are nonempty, <= 256 bytes; withdrawal cancels only its interest, not shared users. *)

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

(** Joined result; attempts counts actual scoped remote admissions, not tasks. No implicit retry; unjoined cleanup remains an effect error. *)
type demand_transfer =
  { result : (asset_result, asset_failure_reason) result
  ; attempts : int
  }

type demand_availability =
  | Demand_queued
  | Demand_downloading
  | Demand_waiting_network
  | Demand_waiting_unlock
  | Demand_failed of
      { reason : asset_failure_reason
      ; attempts : int
      ; retry_scheduled : bool
      }
  | Demand_available of asset_file * asset_lease
  | Demand_waiting_remote
  | Demand_missing_local
  | Demand_revoked

(** Received delivery retains original cleanup obligation through revocation until release ACK. *)
type demand_delivery

type demand_output = private
  { delivery : demand_delivery
  ; id : demand_id
  ; demand : demand_receipt
  ; availability : demand_availability
  }

(** Every state requires delivery release; retry_scheduled requires a bounded network timer. Locked/Closed wait, then fresh Lookup. *)

type outbox_check

(** Runtime-bound capacity revision. *)
type capacity_revision

type 'a wake =
  | Input of service_input
  | Child_ready of 'a child

type notifications

type notification =
  | Policy_failure of error
  | Connected of connection
  | Remote_received of received
  | Connection_retired of connection

type service_status =
  | Service_idle
  | Service_connecting
  | Service_pulling
  | Service_submitting
  | Service_online
  | Service_waiting_network
  | Service_waiting_unlock
  | Service_backoff of
      { attempt : int
      ; seconds : float
      ; cause : error
      }
  | Service_blocked of error

type _ task_operation =
  | Notifications : scope -> notifications task_operation
  | Notify : notifications * notification -> unit task_operation
  | Next_notification : notifications -> notification task_operation
  | Await_outbox_changed : outbox_check task_operation
  | Acknowledge_outbox_check : outbox_check -> unit task_operation
  | Abandon_outbox_check : outbox_check -> unit task_operation
  | Resample_outbox : unit task_operation
  | Capacity_revision : capacity_revision task_operation
  | Await_capacity_changed : capacity_revision -> unit task_operation
  | Task_observe : observation task_operation
  | Publish_status : service_status -> unit task_operation
  | Task_database : 'a database -> 'a task_operation
  | Task_transport : 'a transport -> 'a task_operation
  | Task_crypto : 'a crypto -> 'a task_operation
  | Task_assets : 'a assets -> 'a task_operation
  | Consume_unlock : unlock_receipt -> key_status task_operation
  | Publish_demand : demand_receipt * demand_availability -> unit task_operation
  | Download_demand : demand_receipt -> demand_transfer task_operation
  | Finish_demand : demand_receipt -> unit task_operation
  | Wait_network_open : unit task_operation
  | Next_input : service_input task_operation
  | Await_input_or_child : 'a child Rrbvec.t -> 'a wake task_operation
  | Sleep : float -> unit task_operation
  | Yield : unit task_operation
  (** Capture capacity revision before admission; atomically wait for change or join owned children, then recheck.
    Waiters cancel with scope; wakeup grants no capacity and cannot discard accepted work.
    Outbox dirtiness survives without waiters. One await-to-ACK owner captures epoch before Inspect;
    ACK only after bounded plan installation; concurrent commits stay dirty. Abandon/cancel releases reservation only.
    Start/restore/unlock/activation/reopen mark dirty; Connected resamples. Re-inspect after waiting for Open.
    Sleep is finite nonnegative, monotonic/cancellable; effects may suspend without blocking control.
    Wait_network_open also waits for old join but grants no permit; admission rechecks authority.
    Consume_unlock consumes live receipt before crypto; stale/expired performs no crypto. Failure needs fresh input.
    Publish atomically validates revision/selection/resources/capacity: success transfers file+lease,
    failure transfers nothing. Never release/republish transferred resources. Available needs live Demand;
    Revoked needs live Withdraw; waiting/missing carry none. Reject duplicate references.
    Replace unreceived output only after cleanup; received bytes remain until consumer release ACK.
    Scope exit retains received/failed cleanup, blocking retirement; Finish cannot erase it or newer revisions.
    Download_demand performs one Download after Lookup; Closed/Locked/no-version admits no remote attempt.
    Active work stays charged through join; replacement reclassifies shared priority before admission.
    Notifications share message budgets; Notify backpressures, coalescing only adjacent same-connection hints.
    One consumer per channel; exit joins children before queue release.
    Await_input_or_child requires unique live same-scope children; shares Next_input's sole consumer.
    Atomically consume only winning input; readiness is not join, cancellation consumes nothing.
    Stop wins, otherwise choice is fair. *)

val task_return : 'a -> 'a task
val task_bind : 'a task -> ('a -> 'b task) -> 'b task
val task_fail : error -> 'a task

val task_perform
  :  'a task_operation
  -> success:('a -> 'b task)
  -> failure:(error -> 'b task)
  -> 'b task

val with_scope : (scope -> 'a task) -> 'a task
val spawn : scope -> 'a task -> ('a child, error) result task

(** spawn_asset binds revision/priority; replacement reclassifies before admission. Slots remain charged through join; background eventually runs. *)
val spawn_asset : scope -> demand_receipt -> 'a task -> ('a child, error) result task

val equal_child : 'a child -> 'a child -> bool
val join : 'a child -> ('a, error) result task
val cancel_child : 'a child -> unit task

(** Scope exit cancels/joins all children/producers. One join consumes a completed child's slot;
    foreign/expired/reused joins fail. Report unobserved failures, retaining cleanup/unknown outcomes.
    Child cancellation affects only its subtree; Network_closed is not graph cancellation. *)

type _ task_node =
  | Task_return : 'a -> 'a task_node
  | Task_fail : error -> 'a task_node
  | Task_perform :
      'a task_operation * ('a -> 'b task) * (error -> 'b task)
      -> 'b task_node
  | Task_scope : (scope -> 'a task) -> 'a task_node
  | Task_spawn : scope * 'a task -> ('a child, error) result task_node
  | Task_spawn_asset :
      scope * demand_receipt * 'a task
      -> ('a child, error) result task_node
  | Task_join : 'a child -> ('a, error) result task_node
  | Task_cancel : 'a child -> unit task_node
  | Task_bind : 'a task * ('a -> 'b task) -> 'b task_node

(** Pure total projection; continuations terminate without I/O. Yield after steps_per_turn, fairly including input/completions. *)
val task_view : 'a task -> 'a task_node

(** Interpreter-only process-local handles, not authority or resource ACKs; equal identity is not equal ownership.
    Execute keeps its fresh owner private, reserves/registers before delivery and validates current ledgers.
    Foreign/closed checks fail before callbacks; original cleanup remains legal. *)
module Producer : sig
  type owner

  val create : identity -> owner
  val scope : owner -> scope
  val check_scope : owner -> scope -> (unit, error) result

  (** Exact live owner/scope; close is idempotent only after Execute joins producers. Received-delivery cleanup survives close. *)
  val close_scope : owner -> scope -> (unit, error) result

  val child
    :  owner
    -> scope
    -> 'a task
    -> poll:(unit -> ('a, error) result option)
    -> ('a child, error) result

  val check_child : owner -> scope -> 'a child -> (unit, error) result

  val child_result
    :  owner
    -> scope
    -> 'a child
    -> (('a, error) result option, error) result

  (** Bind poll to the exact typed task after reservation; check owner/live scope/unconsumed registration before polling.
      None is unfinished; repeatable Some is not join. Forget only after physical join;
      repeated original forget succeeds, consumed check/result fails. Prune callbacks without growing tombstones. *)
  val forget_child : owner -> scope -> 'a child -> (unit, error) result

  val demand_receipt : owner -> scope -> (demand_receipt, error) result
  val unlock_receipt : owner -> scope -> (unlock_receipt, error) result
  val outbox_check : owner -> scope -> (outbox_check, error) result
  val notifications : owner -> scope -> (notifications, error) result

  val capacity_revision
    :  owner
    -> scope
    -> sequence:int64
    -> (capacity_revision, error) result

  (** Validate owner/live scope, not latest-sequence equality; old captures remain valid atomic-wait baselines without a revision registry. *)
  val capacity_sequence : owner -> scope -> capacity_revision -> (int64, error) result

  val check_demand_receipt : owner -> scope -> demand_receipt -> (unit, error) result
  val check_unlock_receipt : owner -> scope -> unlock_receipt -> (unit, error) result
  val check_outbox_check : owner -> scope -> outbox_check -> (unit, error) result

  (** Fresh registered identities; Execute atomically checks current selection/revision/expiry/epoch/queue and consumption. Never resurrect handles. *)
  val check_notifications : owner -> scope -> notifications -> (unit, error) result

  val demand_output
    :  owner
    -> scope
    -> demand_receipt
    -> id:demand_id
    -> demand_availability
    -> (demand_output, error) result

  val check_delivery : owner -> demand_delivery -> (unit, error) result
  val delivery_released : owner -> demand_delivery -> (bool, error) result
  val acknowledge_delivery : owner -> demand_delivery -> (unit, error) result
  val same_reference_registration : resource_reference -> resource_reference -> bool

  val reference_state
    :  owner
    -> resource_reference
    -> ([ `Unregistered | `Retained | `Released ], error) result

  val register_reference : owner -> resource_reference -> (unit, error) result

  (** Execute reserves before registration and ACKs only physical release. Exact-owner/metadata ACKs
      stay on original handles, not owner tombstone lists; released references cannot be registered again.
      Producer constructs only; Execute validates publication/resources/capacity. Cleanup survives scope close. *)
  val acknowledge_reference : owner -> resource_reference -> (unit, error) result
end

type (_, _, _, _) operation =
  | Run_task : 'a task -> (ready, ready, ready, 'a) operation
  | Restore : (cold, ready, cold, restore_report) operation
  | Install_initial_network : network_gate -> (ready, ready, ready, unit) operation
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

val perform
  :  ('before, 'after, 'failed, 'a) operation
  -> success:('a -> ('after, 'final, 'b) program)
  -> failure:(error -> ('failed, 'final, 'b) program)
  -> ('before, 'final, 'b) program

type (_, _, _) node =
  | Return : 'a -> ('s, 's, 'a) node
  | Abort : error -> ('s, 'final, 'a) node
  | Perform :
      ('before, 'after, 'failed, 'a) operation
      * ('a -> ('after, 'final, 'b) program)
      * (error -> ('failed, 'final, 'b) program)
      -> ('before, 'final, 'b) node

(** Pure total projection; callbacks terminate without I/O/yield. Exceptions report actual phase. *)
val view : ('before, 'after, 'a) program -> ('before, 'after, 'a) node

val run_task : 'a task -> (ready, ready, ready, 'a) operation
val restore : (cold, ready, cold, restore_report) operation

(** Atomic one-shot install; admitted explicit controls supersede it, so later install is a no-op.
    Admission rejection has zero effects, including eligibility. Admitted install/control consumes eligibility
    before semantic Open epoch/old-generation-join checks, even on failure. Never queue or retry Open. *)
val install_initial_network : network_gate -> (ready, ready, ready, unit) operation

val set_network : network_gate -> (ready, ready, ready, unit) operation
val database : 'a database -> (ready, ready, ready, 'a) operation
val transport : 'a transport -> (ready, ready, ready, 'a) operation
val crypto : 'a crypto -> (ready, ready, ready, 'a) operation
val assets : 'a assets -> (ready, ready, ready, 'a) operation

(** Runtime starts Closed; local Restore preserves controls/eligibility. Missing mirror yields checkpoint None;
    Inspect waits for activation. Locked restore reads metadata only; partial failure stays cold with cleanup owed.
    Open checks actual epoch; Closed fences/joins without rollback. Remote effects recheck permission;
    local inspection/reconciliation/unlock/release need none. Protected work fails Locked before bytes. *)
val observe : ('s, 's, 's, observation) operation

val begin_drain : 's drainable -> ('s, draining, draining, unit) operation
val finish_retirement : (draining, retired, draining, unit) operation
val release_file : asset_file -> ('s, 's, 's, unit) operation
val release_lease : asset_lease -> ('s, 's, 's, unit) operation

(** Drain fences irreversibly; failure stays draining. Retirement requires physical joins and cleanup,
    retaining original owners after replacement. Retired allows release/cached observation only;
    cancellation reports actual phase/cause, never implies rollback. *)
val release_snapshot : snapshot -> ('s, 's, 's, unit) operation

type policy_config = private
  { sync_retry : retry_policy
  ; asset_retry : retry_policy
  ; no_progress_seconds : float
  }

(** Positive finite no-progress delay; no default retry counts/timings. *)
val policy_config
  :  sync_retry:retry_policy
  -> asset_retry:retry_policy
  -> no_progress_seconds:float
  -> (policy_config, error) result

(** Restore, Install_initial_network, then Run_task; never replay the initial gate. Stop joins and returns Ready,
    leaving retirement to the owner. Recover Submitted exact wires before fresh submissions; persist before Push.
    Unknown outcomes reconcile original IDs. Deferred retains exact batch/outcome ID, pauses Pull/fresh sends,
    then re-inspects/reapplies after settlement; scope exit drops only volatile bytes, preserving restart recovery.
    Without a checkpoint, activate the metadata baseline before Connect; restart reuses a checkpoint.
    No_progress uses configured delay; snapshots release on every path, deferred activation waits for change.
    Only Network_failure/Remote_closed/Network_lost/Asset_network retry; join old connection before reconnect.
    Retry Sleep cancels on stop/gate close. Reconnect budget resets after authoritative catch-up and Submitted
    recovery; request budget after matched success; asset budget after available bytes or selection replacement.
    Exhaustion retains cause until new authorized gate epoch; unlock restarts only key-blocked work.
    Closed/Locked consume no retries; other failures require repair, not unchanged hints/dirtiness.
    Capacity pressure retains plans/wires/batches/receipts; wait without blocking control/release.
    Permanent bound mismatch fails. Withdrawals cancel/join only their interest; no adapter policy loops. *)
val sync_policy
  :  policy_config
  -> initial_network:network_gate
  -> (cold, ready, unit) program

val error_message : error -> string
