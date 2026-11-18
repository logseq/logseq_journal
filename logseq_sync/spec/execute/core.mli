(** Contexts are runtime-linear: rejection preserves one; each admitted outcome returns the sole next context. Install it before starting again. *)

module Dsl = Sync_dsl.Core

type t
type 'state graph_context
type context = Context : 'state Dsl.phase * 'state graph_context -> context
type ('after, 'value) outcome =
  | Completed of 'after graph_context * 'value
  | Failed of context * Dsl.error
type ('after, 'value) running

type effect_scope
(** Fresh invocation bound to runtime/owner/incarnation/context version. *)

val handoff : effect_scope -> Dsl.resource_reference Rrbvec.t
  -> (unit, Dsl.error) result
(** Atomic non-suspending masked handoff to reserved cleanup ledger: success transfers all references,
    rejection none; prior transfers persist. Exact repeated transfers are idempotent.
    Validate original owner/kind/metadata; revoked scopes accept original resources for cleanup only.
    ACK forbids producer use/release. Handoff must precede returning resources.
    Original owner records acquisitions before suspension, including raise/cancel before delivery;
    producer resolves untransferred resources. Resource-owned services survive invocation join until release.
    Charges persist through physical cleanup; consumer leases have independent lifetimes. *)

module Callback_bridge : sig
  type 'a producer =
    { start : deliver:(('a, Dsl.error) result -> (unit, Dsl.error) result)
        -> (unit, Dsl.error) result
    ; stop : unit -> (unit, Dsl.error) result
    ; await_stopped : deadline:float -> (unit, Dsl.error) result }
  val run : scope:effect_scope -> resources:('a -> Dsl.resource_reference Rrbvec.t)
    -> 'a producer -> ('a, Dsl.error) result
  (** Register producer and bounded terminal/cleanup capacity before start, even if start fails/raises.
      deliver is thread-safe/non-suspending: select one terminal, hand off resources before ACK.
      Error transfers nothing new; duplicate/late originals transfer only for cleanup, foreign remain producer-owned.
      resources is pure/total and lists every owned reference. Callback-before-start-return is legal.
      start/stop return promptly; await_stopped respects Execute's absolute monotonic cleanup deadline.
      Before return/cancel propagation, physically stop callbacks/native work and resolve untransferred resources.
      Failed/timed-out join retains producer/owner/charges, forces draining and reports all cleanup causes;
      no implicit repair retry. Cancellation is not rollback; uncertain writes retain IDs/Outcome_unknown. *)
end

val check_current : effect_scope -> (unit, Dsl.error) result
val admit_network : effect_scope -> (unit, Dsl.error) result
(** Check scope before irreversible work; admit_network registers one actual attempt after gate/epoch/cancel checks, never a reusable permit. Cleanup validates original ownership, not current authority. *)

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
(** Dispatch may suspend; return joins subfibers/producers except retained Cleanup_failure, which forces draining.
    Mask only bounded handoff/commit bookkeeping; resource returns require handoff before cancellation checks.
    External work uses Callback_bridge. Database mutations use the sole owner; Applied/Activated require commit.
    Deferred is domain data; lost commit response preserves durable IDs/Outcome_unknown, never fresh replay.
    Scoped crypto matches request IDs/counts/generation; stream snapshot verification within byte/item budgets,
    charging staging/scratch through cleanup. Validate producer row count/checksum/encryption before activation.
    Release snapshots on every path. Transport obeys Dsl matching/No_progress rules; policy stays in Dsl.
    Reject foreign identities/resources; preserve typed causes without secrets or adapter retry loops. *)

type websocket_liveness =
  | Peer_close_only
  | Ping_pong of { interval_seconds : float; timeout_seconds : float }
(** Finite positive monotonic timings; ping timeout is Network_lost. Peer_close_only has no silent-peer deadline. *)

type network_deadlines =
  { setup_seconds : float; tls_handshake_seconds : float
  ; http_response_seconds : float; download_seconds : float }
(** Finite positive monotonic deadlines: setup spans DNS/TCP addresses; TLS bounds each handshake.
    HTTP spans write/headers/body/redirects/one refresh; download spans the entire transfer. Progress never resets.
    Expiry cancels/joins; failed cleanup retains owners, unknown writes return Outcome_unknown.
    Read/setup expiry is Network_failure; certificate/protocol errors never become retryable timeouts. *)

type worker_network =
  { with_admission : 'a. (unit -> ('a, Dsl.error) result) -> ('a, Dsl.error) result }
(** Runtime-bound single attempt: register before callback, cancel on fence, join before return. No reusable permission or retry; dispatch cleanup rules apply. *)

module type WORKER_OWNER = sig
  type scope
  type imported_file
  val bind_runtime : identity:Dsl.identity -> database_owner:database_owner
    -> limits:Dsl.limits -> cleanup_seconds:float -> network:worker_network
    -> (unit, Dsl.error) result
  val with_scope : identity:Dsl.identity -> operation:Logseq_db_types.Graph_types.Uuid.t
    -> (scope -> ('a, Dsl.error) result) -> ('a, Dsl.error) result
  val crypto : scope -> 'a Dsl.crypto -> ('a, Dsl.error) result
  val prepare_import : scope -> Logseq_db_types.Asset_import.t
    -> (Logseq_db_types.Asset_upload_intent.t, Dsl.error) result
  (** Reserve original input before copying; journal Prepared proof before return.
      Exact input recovers original intent; changed input/owner rejects. *)
  val publish_import_preview : scope -> Logseq_db_types.Asset_upload_intent.t
    -> (unit, Dsl.error) result
  (** Preview is not remote publication. *)
  val persist_import : scope -> Logseq_db_types.Asset_upload_intent.t
    -> expected:int option -> (unit, Dsl.error) result
  (** Exact prior revision; None means absent. Uncertainty retains original proof/staging, never re-stages picker paths. *)
  val inspect_import : scope -> Logseq_db_types.Asset_upload_intent.t
    -> ([ `Import_absent | `Local_present | `Metadata_present
        | `Publication_acknowledged | `Entity_cancelled ], Dsl.error) result
  val apply_local_import : scope -> Logseq_db_types.Asset_upload_intent.t
    -> (unit, Dsl.error) result
  val put_import : scope -> Logseq_db_types.Asset_upload_intent.t
    -> (unit, Dsl.error) result
  (** ACK means storage, not metadata/publication. *)
  val apply_import_metadata : scope -> Logseq_db_types.Asset_upload_intent.t
    -> (unit, Dsl.error) result
  val await_import_publication : scope -> Logseq_db_types.Asset_upload_intent.t
    -> (unit, Dsl.error) result
  (** Local/metadata writes use the sole queue/original mutation IDs; inspect/wait require original proof, not matching content. *)
  val cancel_import : scope -> Logseq_db_types.Asset_upload_intent.t
    -> (unit, Dsl.error) result
  (** Cancellation preserves commits/unknown outcomes. *)
  val release_import_staging : scope -> Logseq_db_types.Asset_upload_intent.t
    -> (unit, Dsl.error) result
  (** Release only with terminal proof and no users. Decoded intent/path/operation ID grants no authority. *)
  val recover_import_inputs : scope -> after:int64 option
    -> maximum_items:int -> maximum_bytes:int
    -> (Logseq_db_types.Asset_import.Recovery.page, Dsl.error) result
  val confirm_import_input : scope -> string
    -> (Logseq_db_types.Asset_import.Recovery.item option, Dsl.error) result
  val acknowledge_import_input : scope -> input:string -> prepared:string
    -> (unit, Dsl.error) result
  (** Recovery is bounded/read-only; ACK matches original Prepared proof. Worker sequences durable phases. *)
  val cancel : scope -> (unit, Dsl.error) result
  val retain_imported_file : scope -> Logseq_db_types.Asset_upload_intent.t
    -> (imported_file option, Dsl.error) result
  val imported_file_path : imported_file -> string
  val release_imported_file : imported_file -> (unit, Dsl.error) result
  val fence : identity:Dsl.identity -> (unit, Dsl.error) result
  val await_quiescent : identity:Dsl.identity -> (unit, Dsl.error) result
end
(** One concrete owner shared by Worker and crypto/assets/database preparation; create binds after exclusive acquire.
    Before binding/after fence, scopes reject; no rebinding while obligations live. Failed create retires binding
    or retains failed cleanup under sw. Use supplied network admission for every remote attempt.
    Scope reserves capacity and exact operation/intent ownership before callback/I/O; one live scope per operation.
    Recheck generation/cancel after suspension and before commit; cancel/join tasks on every exit.
    Imported files retain separate original-owner leases beyond scope exit; paths grant no ownership.
    Release remains legal after fence/replacement, idempotent only after success; failed cleanup retains handles/causes.
    Fence forbids new work but never reclaims consumer bytes. Quiescence joins work and waits for leases;
    cleanup deadlines cannot force consumer release. Durable input/intents/staging survive restart;
    prune only proven unreferenced terminal staging. *)

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
  ; worker_owner : (module WORKER_OWNER)
  ; dispatch : dispatch
  ; observe : Dsl.identity -> (Dsl.observation, Dsl.error) result
  ; fence : Dsl.identity -> (unit, Dsl.error) result
  ; retire : Dsl.identity -> (unit, Dsl.error) result
  ; release_file : Dsl.identity -> Dsl.asset_file -> (unit, Dsl.error) result
  ; release_lease : Dsl.identity -> Dsl.asset_lease -> (unit, Dsl.error) result
  ; release_snapshot : Dsl.identity -> Dsl.snapshot -> (unit, Dsl.error) result }
(** Validate identity/configuration locally before acquire: exclusive writer, finite positive timings,
    exact owner budgets and bounded chunks/frames; mismatch is Invalid_input, never graph/file enumeration.
    Limits remain immutable; Restore accounts disk recovery incrementally. Authenticate each remote attempt,
    at most one checked refresh. fence_network is nonblocking; close_network physically joins all socket work.
    Gate closes even on fence error; failed join prevents reopen. authorize_network checks actual epoch each time.
    Validate original resource ledger even after revocation. Observe bounded atomic metadata, never graph scans.
    Fence failure stays draining; retire ACKs delegation/resources, not database close/deletion.
    No retirement with outstanding producers/leases/snapshots/cleanup; caller keeps original owners alive.
    Release failure retains exact handle/cause. No global cache or new durable store. *)

val database_owner : Dsl.Overlay.Database.t -> database_owner
val activation_owner : dependencies:Dsl.Overlay.Database.dependencies
  -> inspection:Dsl.Overlay.Database.mirror_inspection -> graph_name:string
  -> (database_owner, Dsl.error) result
val database : database_owner -> (Dsl.Overlay.Database.t, Dsl.error) result
(** Absent-mirror owner shares the sole queue; database fails Storage_failure until committed activation opens/installs it. Interrupted open recovers committed inspection locally; caller owns close. *)
(** All writes share the external transaction queue; revalidate generation/token after suspension. Never hold transactions across network/key/task/callback waits. *)

val create : sw:Eio.Switch.t -> clock:'clock Eio.Time.Mono.t
  -> database_owner:database_owner
  -> identity:Dsl.identity -> limits:Dsl.limits -> capabilities
  -> (t * Dsl.cold graph_context, Dsl.error) result
(** Validate locally before exclusive acquire; failure leaves no registration except retained cleanup obligations.
    Switches own structured runtime/control/task lifetimes; parent cancellation fences and joins owners.
    Finish checked retirement before releasing database/scheduling owners.
    Runtime-created contexts/handles/revisions are process-local; equal-identity client owners are foreign.
    Reserve/register bounded ledgers before delivery; Producer checks do not replace current authority checks.
    Runtime owns mechanics only; sync/retry policy remains pure Dsl. *)

val start : t -> 'before graph_context -> ('before, 'after, 'a) Dsl.program
  -> (('after, 'a) running, Dsl.error) result
val await : ('after, 'a) running -> ('after, 'a) outcome
(** One admitted program per runtime; atomically validate phase/identity/version/capacity before reserving version.
    Rejection has no effects. await is repeatable after joins or retained cleanup failure.
    Only joined ordinary failures enter declared continuations; unjoined producers fence and return actual
    draining context with Cleanup_failure/all causes. Durable uncertainty never permits fresh sends. *)

type network_retirement
val close_network : t -> (network_retirement, Dsl.error) result
val await_network_retirement : network_retirement -> (unit, Dsl.error) result
val open_network : t -> authorization_epoch:int64 -> (unit, Dsl.error) result
(** Close fences/cancels immediately; receipt is not join. Repeat close returns the same outstanding receipt/error.
    Await joins exact old generation; failure retains cause/obligations and Closed. Open checks actual epoch,
    rejecting without waiting/replay until join succeeds. Controls work during binding/Restore, including cold.
    Admission rejection has zero effects; admitted explicit attempts disable initial-install eligibility before
    semantic Open checks, even on rejection. Restore never resets eligibility/gate. Indexed Closed also joins. *)

val notify_outbox_changed : t -> owner:database_owner -> identity:Dsl.identity
  -> (unit, Dsl.error) result
(** Durable postcommit invalidation validates exact binding, coalescing in an independent dirty slot. Captured-epoch ACK preserves concurrent commits; notification failure never undoes/replays a user write. *)

type ingress_ack = Queued | Replaced
val submit_unlock : t -> identity:Dsl.identity -> valid_for:float
  -> Dsl.unlock_input -> (ingress_ack, Dsl.error) result
(** Wrapped-only active Run_task ingress, including Locked/Closed; otherwise Stale_context.
    valid_for is monotonic (0,300] seconds. Reserve before copy; one pending revision.
    Replacement invalidates unconsumed receipt, not admitted work; rejection retains old input/caller ownership.
    Expiry/stop/scope exit discards unconsumed payload. ACK means queued, not unlocked; never log secrets. *)

val update_demand : t -> Dsl.demand_change -> (ingress_ack, Dsl.error) result
val receive_demand : t -> (Dsl.demand_output, Dsl.error) result
type delivery_status = Current | Revoked
val demand_status : t -> Dsl.demand_delivery -> (delivery_status, Dsl.error) result
val release_demand : t -> Dsl.demand_delivery -> (unit, Dsl.error) result
(** One receiver; dequeue transfers existing use obligation, not a new lease. Cancel before dequeue transfers nothing.
    Caller retains/releases deliveries after revoke/stop/cancel; bytes require lease and remain until release ACK.
    Stale queued output is cleaned; empty scope exit wakes Cancelled. Revocation never reclaims consumer bytes.
    Release uses original owners, lease before file; ACK requires physical release. Failure retains handle/cause/charges;
    foreign rejects without cleanup, duplicate succeeds without double release. Keep owners until cleanup resolves. *)
val request_stop : t -> (unit, Dsl.error) result
(** Latest same-ID update replaces atomically; other IDs never drop. Rejection preserves accepted work/caller ownership.
    Charge active/pending interests until Finish; same-ID net descriptors, old cleanup remains charged.
    Foreground reserves/demotion ceilings apply before admission; dedup does not exempt distinct IDs.
    Live withdrawal uses control capacity; unknown withdrawal is idempotent. Dequeue reclaims no charges.
    Stop/gate have independent slots; one input consumer. Stop is idempotent graceful input, not forced drain.
    Run_task return joins scope and returns Ready; forced cancel fences and returns actual draining. *)

val cancel : t -> ('after, 'a) running -> (unit, Dsl.error) result
(** Cancel exact execution and fence; foreign has no effects, accepted repeats are idempotent, terminal rejects. Commits/cleanup persist without await; outcome retains actual phase and causes, not retirement. *)

val current : t -> (context, Dsl.error) result
(** Idle-only recovery returns the same phase/version; explicitly drain/join/retire. Cleanup failure retains draining/original obligations. *)

type observation_revision
type runtime_observation =
  { revision : observation_revision; state : Dsl.observation
  ; status : Dsl.service_status }
val observe_runtime : t -> (runtime_observation, Dsl.error) result
val await_observation : t -> after:observation_revision
  -> (runtime_observation, Dsl.error) result
(** Bounded coalesced latest snapshot; atomic compare/wait, one waiter, cancel consumes nothing. Foreign revisions reject; actual metadata overrides policy. Retired is readable; unchanged retired await fails Stale_context. *)

val identity : 's graph_context -> Dsl.identity
val phase : 's graph_context -> 's Dsl.phase
type version
val version : 's graph_context -> version
val equal_version : version -> version -> bool
(** Metadata grants no fresh authority; versions/contexts/resources never survive restart or serialize. *)
